#Requires -Version 7.0

<#
    ZwaveJsClient - read Z-Wave node data live from zwave-js-ui.

    The manual nodes_dump.json export is just the frontend's node list. That
    list is delivered over zwave-js-ui's socket.io API. This module fetches it
    with engine.io v4 HTTP long-polling (no WebSocket, no dependency) and
    returns the same node array shape the dump has.

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

function Split-EngineIoPayload {
    <#
    .SYNOPSIS
        Splits an engine.io v4 polling body into individual packets.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)

    if ($Body.Length -eq 0) { return , @() }
    # EIO4 polling separates packets with the record separator U+001E.
    return , @($Body.Split([char]0x1e))
}

function ConvertFrom-SocketIoPacket {
    <#
    .SYNOPSIS
        Parses one engine.io/socket.io packet (default namespace, no ack id).
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
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $clean = $Value -replace '[\x00-\x1f\x7f]', ' '
    if ($clean.Length -gt 300) { $clean = $clean.Substring(0, 300) }
    return $clean.Trim()
}

function Get-SocketIoEventArgs {
    <#
    .SYNOPSIS
        Returns the args of the first matching socket.io EVENT among parsed packets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packets,
        [Parameter(Mandatory)][string]$Event
    )
    foreach ($parsed in $Packets) {
        if ($parsed.Event -eq $Event) { return , $parsed.Args }
    }
    return $null
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

function Invoke-EngineIoRequest {
    <#
    .SYNOPSIS
        One engine.io polling HTTP request. Returns the raw response body string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Body,
        [switch]$SkipCertificateCheck,
        [int]$TimeoutSec = 10,
        [int]$MaxBytes = 25MB
    )
    $p = @{ Method = $Method; Uri = $Uri; TimeoutSec = $TimeoutSec }
    if ($SkipCertificateCheck) { $p.SkipCertificateCheck = $true }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $p.Body = $Body
        $p.ContentType = 'text/plain;charset=UTF-8'
    }
    $resp = Invoke-WebRequest @p
    $content = [string]$resp.Content
    if ($content.Length -gt $MaxBytes) {
        throw "zwave-js-ui response exceeded $MaxBytes bytes; refusing to parse."
    }
    return $content
}

function Get-ZwaveJsNodes {
    <#
    .SYNOPSIS
        Fetches the Z-Wave node array from a zwave-js-ui instance over socket.io.
    .DESCRIPTION
        Uses engine.io v4 HTTP long-polling. Returns the same node array shape as
        a manual nodes_dump.json export. Read-only. Throws a specific error on
        any failure so the caller can abort before touching the database.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Token,
        [switch]$SkipCertificateCheck,
        [int]$TimeoutSec = 20
    )

    $base = $Url.TrimEnd('/')
    $isHttps = $base -like 'https://*'

    # The token is a secret: never send it over a plaintext channel.
    if ($Token -and -not $isHttps) {
        throw "Refusing to send -ZwaveJsToken over a non-https URL ($base). Use an https:// zwave-js-ui URL so the token is not transmitted in cleartext."
    }
    if ($Token -and $SkipCertificateCheck) {
        Write-Warning "-SkipCertificateCheck disables TLS validation; a token sent to an unverified server can be intercepted."
    }

    $sio = "$base/socket.io/"
    $nonce = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString()
    $req = @{ SkipCertificateCheck = $SkipCertificateCheck }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    function private:RemainingSec { [int][Math]::Max(1, [Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)) }

    # 1. Handshake
    try {
        $openBody = Invoke-EngineIoRequest @req -Method GET -Uri "$sio`?EIO=4&transport=polling&t=$nonce" -TimeoutSec 10
    }
    catch {
        $m = $_.Exception.Message
        if ($m -match 'certificate|SSL|TLS') {
            $hint = if ($Token) { 'Use a trusted certificate' } else { 'pass -SkipCertificateCheck for a self-signed certificate' }
            throw "TLS certificate not trusted for $base - $hint. ($m)"
        }
        throw "Could not reach zwave-js-ui at $base ($m)"
    }
    $open = ConvertFrom-EngineIoOpen -Body $openBody
    $poll = "$sio`?EIO=4&transport=polling&sid=$($open.Sid)"

    # 2-4. Connect, request state, poll. Map HTTP 401/403 to the auth message.
    try {
        $connectPacket = if ($Token) { '40' + (@{ token = $Token } | ConvertTo-Json -Compress) } else { '40' }
        Invoke-EngineIoRequest @req -Method POST -Uri $poll -Body $connectPacket -TimeoutSec 10 | Out-Null

        $body = Invoke-EngineIoRequest @req -Method GET -Uri $poll -TimeoutSec (RemainingSec)
        Invoke-EngineIoRequest @req -Method POST -Uri $poll -Body '42["INIT"]' -TimeoutSec 10 | Out-Null

        $stateArgs = $null
        while ($null -eq $stateArgs -and [DateTime]::UtcNow -lt $deadline) {
            $rawPackets = Split-EngineIoPayload -Body $body
            $packets = @(foreach ($rp in $rawPackets) { ConvertFrom-SocketIoPacket -Packet $rp })

            $connErr = Get-SocketIoConnectError -Packets $packets
            if ($connErr) { throw [System.Management.Automation.RuntimeException]::new("zwave-js-ui requires authentication - pass -ZwaveJsToken. ($connErr)") }

            $stateArgs = Get-SocketIoEventArgs -Packets $packets -Event 'INITED'
            if ($null -ne $stateArgs) { break }

            # Answer a server ping to keep the session alive, then back off and re-poll.
            if ($packets | Where-Object { $_.EioType -eq '2' }) {
                try { Invoke-EngineIoRequest @req -Method POST -Uri $poll -Body '3' -TimeoutSec 10 | Out-Null } catch { Write-Verbose "pong failed: $_" }
            }
            Start-Sleep -Milliseconds 200
            try {
                $body = Invoke-EngineIoRequest @req -Method GET -Uri $poll -TimeoutSec (RemainingSec)
            }
            catch {
                # A poll timeout is expected on a held long-poll; continue until the deadline.
                if ([DateTime]::UtcNow -ge $deadline) { break }
                $body = ''
            }
        }
    }
    catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        $code = [int]$_.Exception.Response.StatusCode
        if ($code -eq 401 -or $code -eq 403) {
            throw "zwave-js-ui requires authentication - pass -ZwaveJsToken. (HTTP $code)"
        }
        throw "zwave-js-ui request failed (HTTP $code)."
    }

    if ($null -eq $stateArgs) { throw "Connected to zwave-js-ui but received no node state within $TimeoutSec s." }

    $state = @($stateArgs)[0]
    if ($null -eq $state -or 'nodes' -notin $state.PSObject.Properties.Name -or $null -eq $state.nodes) {
        throw "zwave-js-ui returned no nodes."
    }

    # Disconnect (best-effort)
    try { Invoke-EngineIoRequest @req -Method POST -Uri $poll -Body '41' -TimeoutSec 5 | Out-Null } catch { Write-Verbose "zwave-js disconnect failed: $_" }

    return @($state.nodes)
}

Export-ModuleMember -Function Get-ZwaveJsNodes
