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

Export-ModuleMember -Function Get-ZwaveJsNodes
