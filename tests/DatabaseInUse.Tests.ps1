#Requires -Version 7.0

<#
.SYNOPSIS
    Tests for Test-DatabaseInUse (cross-platform "is the DB open elsewhere?" check).

.DESCRIPTION
    Does not require the SQLite engine (./lib) - only the module functions. The
    positive-detection test spawns a helper process that holds the file open and
    is Linux-specific (relies on the /proc scan); the negative test runs anywhere.
#>

$OnLinux = $IsLinux

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:RepoRoot 'modules/DomoticzSqlite/DomoticzSqlite.psd1') -Force -ErrorAction Stop

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("inuse-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Test-DatabaseInUse' {

    It 'reports not-in-use for a file no process holds open' {
        $db = Join-Path $script:WorkDir 'idle.db'
        Set-Content -LiteralPath $db -Value 'x' -NoNewline
        $result = Test-DatabaseInUse -Path $db
        $result.InUse | Should -BeFalse
        $result.Holders | Should -BeNullOrEmpty
    }

    It 'detects the process that holds the database open' -Skip:(-not $OnLinux) {
        $db = Join-Path $script:WorkDir 'busy.db'
        Set-Content -LiteralPath $db -Value 'x' -NoNewline

        # Spawn a helper that opens the file and keeps it open.
        $holderScript = "`$f=[System.IO.File]::Open('$db',[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::ReadWrite); Start-Sleep -Seconds 30"
        $holder = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -ArgumentList @('-NoProfile', '-Command', $holderScript)
        try {
            # Wait for the child to actually open the handle.
            $result = $null
            foreach ($attempt in 1..25) {
                $result = Test-DatabaseInUse -Path $db
                if ($result.InUse) { break }
                Start-Sleep -Milliseconds 200
            }
            $result.InUse | Should -BeTrue
            @($result.Holders.Pid) | Should -Contain $holder.Id
            $result.Method | Should -Be 'proc'
        }
        finally {
            Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'ignores the current process holding its own handle' -Skip:(-not $OnLinux) {
        $db = Join-Path $script:WorkDir 'self.db'
        $stream = [System.IO.File]::Open($db, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
        try {
            # The current PID is excluded, so our own open handle must not count.
            (Test-DatabaseInUse -Path $db).InUse | Should -BeFalse
        }
        finally { $stream.Dispose() }
    }
}
