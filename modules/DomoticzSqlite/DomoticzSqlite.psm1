#Requires -Version 7.0

<#
    DomoticzSqlite - a thin SQLite data-access layer over Microsoft.Data.Sqlite.

    The renamer used to depend on the PSSQLite module, whose bundled native
    SQLite is x86/x64 only, so it could not run on ARM (Raspberry Pi). This
    module instead loads the managed Microsoft.Data.Sqlite / SQLitePCLRaw
    assemblies plus a per-runtime native SQLite that setup.ps1 places in ./lib,
    which covers linux-arm64, linux-arm, linux-x64, win-x64, osx-arm64, and more.

    Call Initialize-SqliteEngine once, then Open-SqliteDatabase and the
    Invoke-Sqlite* helpers. Parameters are always passed as a hashtable of
    @name -> value and bound as real SQLite parameters (never string-formatted).
#>

Set-StrictMode -Version Latest

$script:EngineReady = $false

function Initialize-SqliteEngine {
    <#
    .SYNOPSIS
        Loads the vendored SQLite assemblies and registers the native provider.
    .PARAMETER LibDir
        Directory populated by setup.ps1 (managed DLLs + native e_sqlite3).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LibDir
    )

    if ($script:EngineReady) { return }

    $nativeName = if ($IsWindows) { 'e_sqlite3.dll' } elseif ($IsMacOS) { 'libe_sqlite3.dylib' } else { 'libe_sqlite3.so' }
    $required = @(
        'SQLitePCLRaw.core.dll',
        'SQLitePCLRaw.provider.e_sqlite3.dll',
        'Microsoft.Data.Sqlite.dll',
        $nativeName
    )
    $missing = $required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $LibDir $_)) }
    if ($missing) {
        throw ("SQLite assemblies are missing from '$LibDir': {0}. Run setup.ps1 first (pwsh ./setup.ps1)." -f ($missing -join ', '))
    }

    # Load managed assemblies in dependency order. The native e_sqlite3 sits in
    # the same directory and is resolved automatically by the .NET native loader.
    foreach ($dll in 'SQLitePCLRaw.core.dll', 'SQLitePCLRaw.provider.e_sqlite3.dll', 'Microsoft.Data.Sqlite.dll') {
        [System.Reflection.Assembly]::LoadFrom((Join-Path $LibDir $dll)) | Out-Null
    }

    # Register the e_sqlite3 provider (equivalent to Batteries_V2.Init()).
    [SQLitePCL.raw]::SetProvider([SQLitePCL.SQLite3Provider_e_sqlite3]::new())

    $script:EngineReady = $true
    Write-Verbose "SQLite engine initialised from $LibDir (native $nativeName)."
}

function Assert-EngineReady {
    if (-not $script:EngineReady) {
        throw 'SQLite engine not initialised. Call Initialize-SqliteEngine -LibDir <dir> first.'
    }
}

function Open-SqliteDatabase {
    <#
    .SYNOPSIS
        Opens (and returns) a Microsoft.Data.Sqlite connection to a database file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        # By default a missing file is an error (the tool operates on an existing
        # Domoticz database). Opt in to creation, e.g. when building a fixture.
        [switch]$CreateIfMissing
    )
    Assert-EngineReady

    $builder = [Microsoft.Data.Sqlite.SqliteConnectionStringBuilder]::new()
    $builder.DataSource = $Path
    $builder.Mode = if ($CreateIfMissing) {
        [Microsoft.Data.Sqlite.SqliteOpenMode]::ReadWriteCreate
    } else {
        [Microsoft.Data.Sqlite.SqliteOpenMode]::ReadWrite
    }

    $conn = [Microsoft.Data.Sqlite.SqliteConnection]::new($builder.ConnectionString)
    $conn.Open()
    return $conn
}

function New-SqliteCommand {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory SqliteCommand; no external state to confirm.')]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Sql,
        [hashtable]$Parameters
    )
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Sql
    if ($Parameters) {
        foreach ($key in $Parameters.Keys) {
            $name = if ($key.StartsWith('@')) { $key } else { "@$key" }
            $value = $Parameters[$key]
            if ($null -eq $value) { $value = [System.DBNull]::Value }
            [void]$cmd.Parameters.AddWithValue($name, $value)
        }
    }
    return $cmd
}

function Invoke-SqliteReader {
    <#
    .SYNOPSIS
        Runs a query and returns each row as a PSCustomObject keyed by column name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Sql,
        [hashtable]$Parameters
    )
    Assert-EngineReady

    $cmd = New-SqliteCommand -Connection $Connection -Sql $Sql -Parameters $Parameters
    try {
        $reader = $cmd.ExecuteReader()
        try {
            $rows = [System.Collections.Generic.List[psobject]]::new()
            while ($reader.Read()) {
                $row = [ordered]@{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $value = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
                    $row[$reader.GetName($i)] = $value
                }
                $rows.Add([pscustomobject]$row)
            }
            return $rows.ToArray()
        }
        finally { $reader.Dispose() }
    }
    finally { $cmd.Dispose() }
}

function Invoke-SqliteNonQuery {
    <#
    .SYNOPSIS
        Executes a statement (DDL/DML/transaction control) and returns rows affected.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Sql,
        [hashtable]$Parameters
    )
    Assert-EngineReady

    $cmd = New-SqliteCommand -Connection $Connection -Sql $Sql -Parameters $Parameters
    try {
        return $cmd.ExecuteNonQuery()
    }
    finally { $cmd.Dispose() }
}

function Test-DatabaseInUse {
    <#
    .SYNOPSIS
        Best-effort, cross-platform check for whether another process (e.g. a
        running Domoticz) currently has the database file open.
    .DESCRIPTION
        Returns an object { InUse; Holders = @({ Pid; Name }); Method }.

        This is a GUARDRAIL, not a guarantee. SQLite locks are transient, so a
        running-but-idle Domoticz holds no lock; and on Linux we can only see
        file handles owned by processes visible to the current user. Always stop
        Domoticz before applying changes regardless of what this reports, because
        Domoticz caches device rows in memory and can overwrite the new names.

        Detection method by platform:
          Linux   - scan /proc/<pid>/fd for an open handle to the DB or its
                    -wal/-shm/-journal sidecars (no external tools needed)
          Windows - attempt an exclusive (FileShare.None) open
          macOS   - 'lsof' if available
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $holders = [System.Collections.Generic.List[psobject]]::new()
    $method = 'unknown'

    $full = try { (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath } catch { [System.IO.Path]::GetFullPath($Path) }
    $targets = [System.Collections.Generic.HashSet[string]]::new([string[]]@($full, "$full-wal", "$full-shm", "$full-journal"))

    if ($IsLinux) {
        $method = 'proc'
        foreach ($fdDir in [System.IO.Directory]::EnumerateDirectories('/proc')) {
            $leaf = [System.IO.Path]::GetFileName($fdDir)
            if ($leaf -notmatch '^\d+$') { continue }
            if ([int]$leaf -eq $PID) { continue }
            try { $entries = [System.IO.Directory]::EnumerateFileSystemEntries([System.IO.Path]::Combine($fdDir, 'fd')) }
            catch { continue }   # process gone, or its /proc is not readable by us
            foreach ($entry in $entries) {
                $link = try { [System.IO.File]::ResolveLinkTarget($entry, $true) } catch { $null }
                if ($link -and $targets.Contains($link.FullName)) {
                    $name = try { ([System.IO.File]::ReadAllText("/proc/$leaf/comm")).Trim() } catch { 'unknown' }
                    $holders.Add([pscustomobject]@{ Pid = [int]$leaf; Name = $name })
                    break
                }
            }
        }
    }
    elseif ($IsWindows) {
        $method = 'fileshare'
        try {
            $stream = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $stream.Dispose()
        }
        catch [System.IO.IOException] {
            $holders.Add([pscustomobject]@{ Pid = $null; Name = 'another process' })
        }
        catch {
            # Any other error (missing file, access denied) is not evidence of
            # another process holding the file; treat as not-in-use.
            Write-Verbose "Test-DatabaseInUse (fileshare): $_"
        }
    }
    elseif ($IsMacOS) {
        $lsof = Get-Command lsof -ErrorAction SilentlyContinue
        if ($lsof) {
            $method = 'lsof'
            foreach ($procId in (& $lsof.Source -t -- $full 2>$null)) {
                if ($procId -notmatch '^\d+$' -or [int]$procId -eq $PID) { continue }
                $name = try { (& ps -p $procId -o comm= 2>$null | Out-String).Trim() } catch { 'unknown' }
                $holders.Add([pscustomobject]@{ Pid = [int]$procId; Name = $name })
            }
        }
        else { $method = 'unavailable' }
    }

    $unique = @($holders | Sort-Object -Property Pid -Unique)
    return [pscustomobject]@{
        InUse   = [bool]($unique.Count -gt 0)
        Holders = $unique
        Method  = $method
    }
}

Export-ModuleMember -Function Initialize-SqliteEngine, Open-SqliteDatabase, Invoke-SqliteReader, Invoke-SqliteNonQuery, Test-DatabaseInUse
