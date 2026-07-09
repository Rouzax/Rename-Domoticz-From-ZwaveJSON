#Requires -Version 7.0

<#
.SYNOPSIS
    Unit tests for the DomoticzSqlite data-access module.

.DESCRIPTION
    Exercises the module against throwaway databases: engine initialisation,
    connection open (including fail-fast on a missing file), parameterised
    reads and writes, NULL handling, and transaction commit/rollback.

    Requires the SQLite engine provisioned by setup.ps1 into ./lib; skips
    cleanly if absent.
#>

$EngineAvailable = Test-Path -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Microsoft.Data.Sqlite.dll')

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:LibDir = Join-Path $script:RepoRoot 'lib'
    Import-Module (Join-Path $script:RepoRoot 'modules/DomoticzSqlite/DomoticzSqlite.psd1') -Force -ErrorAction Stop
    Initialize-SqliteEngine -LibDir $script:LibDir

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dsqlite-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'DomoticzSqlite' -Skip:(-not $EngineAvailable) {

    It 'reports a usable SQLite version once initialised' {
        $db = Join-Path $script:WorkDir 'ver.db'
        $conn = Open-SqliteDatabase -Path $db -CreateIfMissing
        try {
            $rows = Invoke-SqliteReader -Connection $conn -Sql 'SELECT sqlite_version() AS v'
            $rows[0].v | Should -Match '^\d+\.\d+'
        }
        finally { $conn.Close() }
    }

    It 'fails fast when opening a database that does not exist' {
        $missing = Join-Path $script:WorkDir 'nope.db'
        { Open-SqliteDatabase -Path $missing } | Should -Throw
        Test-Path -LiteralPath $missing | Should -BeFalse
    }

    It 'round-trips parameterised writes and reads, including NULL' {
        $db = Join-Path $script:WorkDir 'rt.db'
        $conn = Open-SqliteDatabase -Path $db -CreateIfMissing
        try {
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'CREATE TABLE t (id INTEGER, name TEXT)')
            $affected = Invoke-SqliteNonQuery -Connection $conn -Sql 'INSERT INTO t (id, name) VALUES (@id, @name)' -Parameters @{ id = 1; name = "a'b - c" }
            $affected | Should -Be 1
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'INSERT INTO t (id, name) VALUES (@id, @name)' -Parameters @{ id = 2; name = $null })

            $rows = Invoke-SqliteReader -Connection $conn -Sql 'SELECT id, name FROM t ORDER BY id'
            $rows.Count | Should -Be 2
            $rows[0].name | Should -Be "a'b - c"   # parameter binding, no injection
            $rows[1].name | Should -BeNullOrEmpty   # NULL surfaces as $null
        }
        finally { $conn.Close() }
    }

    It 'commits and rolls back transactions' {
        $db = Join-Path $script:WorkDir 'tx.db'
        $conn = Open-SqliteDatabase -Path $db -CreateIfMissing
        try {
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'CREATE TABLE t (id INTEGER)')

            # Commit path
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'BEGIN IMMEDIATE TRANSACTION;')
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'INSERT INTO t VALUES (1)')
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'COMMIT;')
            (Invoke-SqliteReader -Connection $conn -Sql 'SELECT COUNT(*) AS c FROM t')[0].c | Should -Be 1

            # Rollback path
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'BEGIN IMMEDIATE TRANSACTION;')
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'INSERT INTO t VALUES (2)')
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'ROLLBACK;')
            (Invoke-SqliteReader -Connection $conn -Sql 'SELECT COUNT(*) AS c FROM t')[0].c | Should -Be 1
        }
        finally { $conn.Close() }
    }
}
