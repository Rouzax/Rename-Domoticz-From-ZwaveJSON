#Requires -Version 7.0

<#
    ZwaveJsClient - read Z-Wave node data live from zwave-js-ui.

    The manual nodes_dump.json export is just the frontend's node list. That
    list is delivered over zwave-js-ui's socket.io API. This module fetches it
    over a WebSocket (engine.io v4) and returns the same node array shape the
    dump has.

    WebSocket, not HTTP long-polling: the full node state is several MB (well
    over the 1 MB engine.io polling maxPayload), so it only travels over the
    WebSocket transport. The request is a single socket.io emit of the event
    named 'INITED' (with an ack), and the state comes back as the ack payload.

    Only Get-ZwaveJsNodes is public. The parsing helpers are internal and
    covered by tests via InModuleScope.
#>

Set-StrictMode -Version Latest

function ConvertFrom-EngineIoOpen {
    <#
    .SYNOPSIS
        Parses an engine.io v4 "open" packet ('0{...}') into its fields.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)

    if ($Body.Length -eq 0 -or $Body[0] -ne '0') {
        throw "Unexpected socket.io handshake; expected an engine.io v4 open packet starting with '0'. Is this a zwave-js-ui instance?"
    }
    $obj = $Body.Substring(1) | ConvertFrom-Json
    $props = $obj.PSObject.Properties.Name
    if ('sid' -notin $props) { throw "engine.io open packet is missing 'sid'." }

    [pscustomobject]@{
        Sid          = [string]$obj.sid
        PingInterval = if ('pingInterval' -in $props) { [int]$obj.pingInterval } else { 25000 }
        PingTimeout  = if ('pingTimeout'  -in $props) { [int]$obj.pingTimeout }  else { 20000 }
    }
}

function ConvertFrom-SocketIoPacket {
    <#
    .SYNOPSIS
        Parses one engine.io/socket.io packet (default namespace).
    .DESCRIPTION
        Handles EVENT (42[...]), CONNECT (40{...}), CONNECT_ERROR (44{...}) and
        ACK (43<ackid>[...]). For ACK, Args holds the ack payload; the leading
        ack id digits are stripped before JSON parsing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Packet)

    $result = [pscustomobject]@{ EioType = $null; SioType = $null; Event = $null; Args = @() }
    if ($Packet.Length -eq 0) { return $result }

    $result.EioType = [string]$Packet[0]
    if ($Packet[0] -ne '4' -or $Packet.Length -lt 2) { return $result }  # only engine.io MESSAGE carries socket.io

    $result.SioType = [string]$Packet[1]
    $rest = $Packet.Substring(2)
    if ($rest.Length -eq 0) { return $result }

    switch ($Packet[1]) {
        '2' {   # EVENT: ["name", arg1, ...]
            $arr = $rest | ConvertFrom-Json
            if (@($arr).Count -ge 1) {
                $result.Event = [string]@($arr)[0]
                $result.Args = @($arr | Select-Object -Skip 1)
            }
        }
        '3' {   # ACK: <ackid>[arg1, ...]
            $body = $rest.TrimStart('0', '1', '2', '3', '4', '5', '6', '7', '8', '9')
            if ($body.Length -gt 0) { $result.Args = @(($body | ConvertFrom-Json)) }
        }
        '0' { $result.Args = @(($rest | ConvertFrom-Json)) }  # CONNECT
        '4' { $result.Args = @(($rest | ConvertFrom-Json)) }  # CONNECT_ERROR
        default { }
    }
    return $result
}

function Get-SafeServerString {
    <#
    .SYNOPSIS
        Sanitizes an untrusted server-supplied string for printing (strips
        control/escape characters, caps length).
    #>
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $clean = $Value -replace '[\x00-\x1f\x7f]', ' '
    if ($clean.Length -gt 300) { $clean = $clean.Substring(0, 300) }
    return $clean.Trim()
}

function Get-SocketIoConnectError {
    <#
    .SYNOPSIS
        Returns the sanitized CONNECT_ERROR message among parsed packets, or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packets)

    foreach ($parsed in $Packets) {
        if ($parsed.EioType -eq '4' -and $parsed.SioType -eq '4') {
            $obj = @($parsed.Args)[0]
            if ($null -ne $obj -and 'message' -in $obj.PSObject.Properties.Name) {
                return Get-SafeServerString ([string]$obj.message)
            }
            return 'connection rejected'
        }
    }
    return $null
}

function Send-WsText {
    <#
    .SYNOPSIS
        Sends one UTF-8 text frame on a WebSocket.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$WebSocket,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)]$CancellationToken
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $seg = [System.ArraySegment[byte]]::new($bytes)
    [void]$WebSocket.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $CancellationToken).GetAwaiter().GetResult()
}

function Receive-WsMessage {
    <#
    .SYNOPSIS
        Receives one full WebSocket text message (assembling continuation
        frames), bounded by MaxBytes.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns one message; noun is a message.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$WebSocket,
        [Parameter(Mandatory)]$CancellationToken,
        [Parameter(Mandatory)][int]$MaxBytes
    )
    $ms = [System.IO.MemoryStream]::new()
    try {
        $buf = [byte[]]::new(65536)
        do {
            $seg = [System.ArraySegment[byte]]::new($buf)
            $r = $WebSocket.ReceiveAsync($seg, $CancellationToken).GetAwaiter().GetResult()
            if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw "zwave-js-ui closed the WebSocket connection."
            }
            $ms.Write($buf, 0, $r.Count)
            if ($ms.Length -gt $MaxBytes) {
                throw "zwave-js-ui response exceeded $MaxBytes bytes; refusing to parse."
            }
        } while (-not $r.EndOfMessage)
        return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    }
    finally { $ms.Dispose() }
}

function Get-ZwaveJsNodes {
    <#
    .SYNOPSIS
        Fetches the Z-Wave node array from a zwave-js-ui instance over WebSocket.
    .DESCRIPTION
        Connects to zwave-js-ui's socket.io endpoint over a WebSocket (engine.io
        v4), emits the 'INITED' event, and returns the node array from the ack
        payload - the same node-array shape as a manual nodes_dump.json export.
        Read-only. Throws a specific error on any failure so the caller can abort
        before touching the database.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Public function name is fixed; it returns the node collection.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Token,
        [switch]$SkipCertificateCheck,
        [int]$TimeoutSec = 30
    )

    $u = try { [Uri]$Url } catch { throw "Invalid zwave-js-ui URL: $Url" }
    $wsScheme = switch ($u.Scheme) {
        'https' { 'wss' }
        'http'  { 'ws' }
        default { throw "zwave-js-ui URL must be http:// or https:// ($Url)." }
    }

    # The token is a credential. Over http it travels in cleartext, which is
    # usually fine on a trusted LAN (the common case) but risky on an open
    # network, so warn rather than refuse.
    if ($Token -and $wsScheme -eq 'ws') {
        Write-Warning "Sending -ZwaveJsToken to $Url over http: the token is transmitted in cleartext. Fine on a trusted LAN; use https:// if the traffic could be observed."
    }
    if ($Token -and $SkipCertificateCheck) {
        Write-Warning "-SkipCertificateCheck disables TLS validation; a token sent to an unverified server can be intercepted."
    }

    $wsUri = [Uri]("{0}://{1}/socket.io/?EIO=4&transport=websocket" -f $wsScheme, $u.Authority)
    $maxBytes = 64MB

    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    $tok = $cts.Token
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    if ($SkipCertificateCheck) {
        # Accept any certificate (the callback's four delegate args are ignored).
        $ws.Options.RemoteCertificateValidationCallback = { $true }
    }

    try {
        # Connect
        try {
            [void]$ws.ConnectAsync($wsUri, $tok).GetAwaiter().GetResult()
        }
        catch {
            $m = $_.Exception.Message
            if ($m -match 'certificate|SSL|TLS') {
                $hint = if ($Token) { 'Use a trusted certificate' } else { 'pass -SkipCertificateCheck for a self-signed certificate' }
                throw "TLS certificate not trusted for $Url - $hint. ($m)"
            }
            throw "Could not reach zwave-js-ui at $Url ($m)"
        }

        # 1. engine.io open
        [void](ConvertFrom-EngineIoOpen -Body (Receive-WsMessage -WebSocket $ws -CancellationToken $tok -MaxBytes $maxBytes))

        # 2. socket.io connect (+ optional auth)
        $connect = if ($Token) { '40' + (@{ token = $Token } | ConvertTo-Json -Compress) } else { '40' }
        Send-WsText -WebSocket $ws -Text $connect -CancellationToken $tok

        # 3. connect ack / error
        $ackPkt = ConvertFrom-SocketIoPacket -Packet (Receive-WsMessage -WebSocket $ws -CancellationToken $tok -MaxBytes $maxBytes)
        $connErr = Get-SocketIoConnectError -Packets @($ackPkt)
        if ($connErr) { throw "zwave-js-ui requires authentication - pass -ZwaveJsToken. ($connErr)" }

        # 4. request state: emit the 'INITED' event (data true, ack id 0)
        Send-WsText -WebSocket $ws -Text '420["INITED",true]' -CancellationToken $tok

        # 5. read until the ack carrying state, answering pings
        $state = $null
        while ($null -eq $state) {
            $msg = Receive-WsMessage -WebSocket $ws -CancellationToken $tok -MaxBytes $maxBytes
            if ($msg -eq '2') { Send-WsText -WebSocket $ws -Text '3' -CancellationToken $tok; continue }  # ping -> pong
            $pkt = ConvertFrom-SocketIoPacket -Packet $msg
            $connErr = Get-SocketIoConnectError -Packets @($pkt)
            if ($connErr) { throw "zwave-js-ui rejected the connection. ($connErr)" }
            if ($pkt.EioType -eq '4' -and $pkt.SioType -eq '3') { $state = @($pkt.Args)[0] }  # ACK
        }

        if ($null -eq $state -or 'nodes' -notin $state.PSObject.Properties.Name -or $null -eq $state.nodes) {
            throw "zwave-js-ui returned no nodes."
        }

        # In the live socket state each node's 'values' is a map keyed by value
        # id; a nodes_dump.json export flattens it to an array. Normalize to the
        # array shape so the rest of the tool (which iterates node.values) matches
        # the dump exactly. Each value object already carries its own .id/.label.
        $nodes = @($state.nodes)
        foreach ($node in $nodes) {
            if ($node.PSObject.Properties['values'] -and $null -ne $node.values -and $node.values -isnot [System.Array]) {
                $node.values = @($node.values.PSObject.Properties | ForEach-Object { $_.Value })
            }
        }
        return $nodes
    }
    catch [System.OperationCanceledException] {
        throw "Timed out talking to zwave-js-ui at $Url after $TimeoutSec s."
    }
    finally {
        # Best-effort graceful close, bounded so a peer that does not complete the
        # close handshake cannot hang the client (we already have the data).
        try {
            if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $closeCts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(5))
                [void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $closeCts.Token).GetAwaiter().GetResult()
            }
        }
        catch { Write-Verbose "zwave-js WebSocket close failed: $_" }
        $ws.Dispose()
    }
}

Export-ModuleMember -Function Get-ZwaveJsNodes
