@{
    RootModule        = 'DomoticzSqlite.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = 'b6f3a1d2-9c47-4e58-8a1f-2d7c9e0b4f31'
    Author            = 'Rouzax'
    Description       = 'Thin SQLite data-access layer over Microsoft.Data.Sqlite / SQLitePCLRaw, with per-runtime native SQLite (ARM-capable) provisioned by setup.ps1.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Initialize-SqliteEngine',
        'Open-SqliteDatabase',
        'Invoke-SqliteReader',
        'Invoke-SqliteNonQuery',
        'Test-DatabaseInUse'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
