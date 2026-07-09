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

Export-ModuleMember -Function Get-ZwaveJsNodes
