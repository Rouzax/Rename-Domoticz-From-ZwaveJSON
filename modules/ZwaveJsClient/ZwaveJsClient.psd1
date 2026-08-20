@{
    RootModule        = 'ZwaveJsClient.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'c2a9e7d4-4b1f-4e93-9a86-1f5c3d8b7e20'
    Author            = 'Rouzax'
    Description       = 'Reads Z-Wave node data live from a zwave-js-ui instance over its socket.io API (engine.io v4 HTTP long-polling).'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Get-ZwaveJsNodes')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
