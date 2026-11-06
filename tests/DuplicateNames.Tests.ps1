#Requires -Version 7.0

<#
.SYNOPSIS
    Integration tests for the reporting of device names that are still shared
    once a run has finished.

.DESCRIPTION
    Collision detection only looks at a name that is changing, so two devices
    already holding the name their rules propose are both "unchanged" and never
    reach it. A Z-Wave node exposing one thing through two command classes ends
    up that way: Binary Switch and Multilevel Switch each get a "Current value"
    entry and the rules strip that label from both.

    These tests pin that such a pair is REPORTED, that the report describes the
    end state of the run rather than its start, and that reporting changes
    neither the database nor the exit code.

    Run with:  Invoke-Pester -Path ./tests

    The tests build and read fixture databases through the same SQLite engine
    the tool uses, provisioned by setup.ps1 into ./lib. If ./lib is absent they
    skip cleanly (run "pwsh ./setup.ps1" first).
#>

$EngineAvailable = Test-Path -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Microsoft.Data.Sqlite.dll')

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path $script:RepoRoot 'Rename-Domoticz-From-ZwaveJSON.ps1'
    $script:LibDir = Join-Path $script:RepoRoot 'lib'

    Import-Module (Join-Path $script:RepoRoot 'modules/DomoticzSqlite/DomoticzSqlite.psd1') -Force -ErrorAction Stop
    Initialize-SqliteEngine -LibDir $script:LibDir

    $script:RulesJson = @'
{
  "description": "duplicate-reporting test rules",
  "rules": [
    { "name": "Multilevel", "pattern": "38-[01]-currentValue$", "replace": " - Current value$", "with": "", "description": "strip the label" },
    { "name": "Binary", "pattern": "37-[01]-currentValue$", "replace": " - Current value$", "with": "", "description": "strip the label" }
  ]
}
'@

    function New-TestDatabase {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper writing a throwaway fixture database; nothing to confirm.')]
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][hashtable[]]$Rows
        )
        $conn = Open-SqliteDatabase -Path $Path -CreateIfMissing
        try {
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'CREATE TABLE DeviceStatus (DeviceID TEXT, Name TEXT, SwitchType INTEGER, CustomImage INTEGER, Type INTEGER, Used INTEGER, LastUpdate TEXT, Unit INTEGER)')
            foreach ($row in $Rows) {
                $unit = if ($row.ContainsKey('Unit')) { $row.Unit } else { 1 }
                [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'INSERT INTO DeviceStatus (DeviceID, Name, SwitchType, CustomImage, Type, Used, LastUpdate, Unit) VALUES (@id, @name, 0, 0, 0, @used, @lastUpdate, @unit)' -Parameters @{ id = $row.DeviceID; name = $row.Name; used = $row.Used; lastUpdate = '2026-01-02 03:04:05'; unit = $unit })
            }
        }
        finally { $conn.Close() }
    }

    function Get-DeviceNameList {
        param([Parameter(Mandatory)][string]$Path)
        $conn = Open-SqliteDatabase -Path $Path
        try {
            return @(Invoke-SqliteReader -Connection $conn -Sql 'SELECT DeviceID, Unit, Name FROM DeviceStatus ORDER BY DeviceID, Unit' | ForEach-Object { "$($_.DeviceID)|$($_.Unit)|$($_.Name)" })
        }
        finally { $conn.Close() }
    }
}

Describe 'Names still shared when the run ends' -Skip:(-not $EngineAvailable) {
    BeforeAll {
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("renamer-duplicate-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

        # Node 5: one curtain exposed as CC37 and CC38, already carrying the name
        #         both rules propose.
        # Node 6: two devices sharing an old name; this run renames them apart.
        # Node 7: one multi-unit device whose rows agree on a name.
        # Node 8: a Z-Wave device sharing its name with another hardware type.
        $json = @'
[
  {
    "id": 5, "loc": "Zone Alpha", "name": "Curtain",
    "hassDevices": { "a": { "discovery_payload": { "name": "x", "unique_id": "test_5-37-0-currentValue", "device": { "identifiers": ["test_node5"] } } } },
    "values": [
      { "id": "5-37-0-currentValue", "label": "Current value" },
      { "id": "5-38-0-currentValue", "label": "Current value" }
    ]
  },
  {
    "id": 6, "loc": "Zone Beta", "name": "Fan",
    "values": [
      { "id": "6-37-0-currentValue", "label": "Current value" },
      { "id": "6-50-0-value-65537", "label": "Power" }
    ]
  },
  {
    "id": 7, "loc": "Zone Gamma", "name": "Remote",
    "values": [ { "id": "7-91-0-scene-001", "label": "Scene" } ]
  },
  {
    "id": 8, "loc": "Zone Delta", "name": "Sensor",
    "values": [ { "id": "8-37-0-currentValue", "label": "Current value" } ]
  }
]
'@
        $rows = @(
            @{ DeviceID = 'test_5-37-0-currentValue'; Name = 'Zone Alpha - Curtain'; Used = 0 }
            @{ DeviceID = 'test_5-38-0-currentValue'; Name = 'Zone Alpha - Curtain'; Used = 1 }
            @{ DeviceID = 'test_6-37-0-currentValue'; Name = 'Shared Old Name'; Used = 1 }
            @{ DeviceID = 'test_6-50-0-value-65537'; Name = 'Shared Old Name'; Used = 1 }
            @{ DeviceID = 'test_7-91-0-scene-001'; Name = 'Zone Gamma - Remote - Scene'; Used = 1; Unit = 1 }
            @{ DeviceID = 'test_7-91-0-scene-001'; Name = 'Zone Gamma - Remote - Scene'; Used = 1; Unit = 2 }
            @{ DeviceID = 'test_8-37-0-currentValue'; Name = 'Zone Delta - Sensor'; Used = 1 }
            @{ DeviceID = 'othervendor_1'; Name = 'Zone Delta - Sensor'; Used = 1 }
            @{ DeviceID = 'othertwin_1'; Name = 'Rain'; Used = 1 }
            @{ DeviceID = 'othertwin_2'; Name = 'Rain'; Used = 0 }
        )

        $db = Join-Path $script:WorkDir 'db.db'
        $nodes = Join-Path $script:WorkDir 'nodes.json'
        $rules = Join-Path $script:WorkDir 'rules.json'
        Set-Content -LiteralPath $nodes -Value $json -Encoding utf8
        Set-Content -LiteralPath $rules -Value $script:RulesJson -Encoding utf8
        New-TestDatabase -Path $db -Rows $rows

        # Run as a child process so the script's `exit` calls do not stop Pester.
        $script:Output = & pwsh -NoProfile -File $script:ScriptPath -JsonFile $nodes -DbPath $db -RulesFile $rules -Force -NoBackup 2>&1 | Out-String
        $script:ExitCode = $LASTEXITCODE
        $script:Names = Get-DeviceNameList -Path $db

        $reportFile = Get-ChildItem -LiteralPath $script:WorkDir -Filter 'rename_report-*.html' | Select-Object -First 1
        $script:Report = if ($reportFile) { Get-Content -LiteralPath $reportFile.FullName -Raw } else { '' }
    }

    AfterAll {
        if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
            Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports two devices that already share the name their rules propose' {
        $script:Output | Should -Match "'Zone Alpha - Curtain'"
        $script:Output | Should -Match 'test_5-37-0-currentValue'
        $script:Output | Should -Match 'test_5-38-0-currentValue'
    }

    It 'shows Used and last update so the redundant device can be picked out' {
        $script:Output | Should -Match 'test_5-37-0-currentValue \(Used=0, last update 2026-01-02 03:04:05\)'
    }

    It 'counts them in the summary without calling them collisions' {
        $script:Output | Should -Match 'Duplicates\s*:?\s*2'
        $script:Output | Should -Match 'Collisions\s*:?\s*0'
    }

    It 'leaves both duplicates named as they were' {
        $script:Names | Should -Contain 'test_5-37-0-currentValue|1|Zone Alpha - Curtain'
        $script:Names | Should -Contain 'test_5-38-0-currentValue|1|Zone Alpha - Curtain'
    }

    It 'does not report a duplicate this run resolves' {
        $script:Names | Should -Contain 'test_6-37-0-currentValue|1|Zone Beta - Fan'
        $script:Output | Should -Not -Match "'Shared Old Name'"
    }

    It 'does not treat the rows of one multi-unit device as duplicates' {
        $script:Output | Should -Not -Match "'Zone Gamma - Remote - Scene'"
    }

    It 'reports a Z-Wave device sharing its name with another hardware type' {
        $script:Output | Should -Match "'Zone Delta - Sensor'"
        $script:Output | Should -Match 'othervendor_1'
    }

    It 'ignores a duplicate with no Z-Wave device in it' {
        $script:Output | Should -Not -Match 'othertwin'
        $script:Report | Should -Not -Match 'othertwin'
    }

    It 'lists the duplicates in the HTML report' {
        $script:Report | Should -Match 'Zone Alpha - Curtain'
        $script:Report | Should -Match 'test_5-38-0-currentValue'
        $script:Report | Should -Match 'Duplicate names'
    }

    It 'still exits with the code the changes call for' {
        $script:ExitCode | Should -Be 0
    }
}

Describe 'A run with duplicates and nothing to change' -Skip:(-not $EngineAvailable) {
    BeforeAll {
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("renamer-duplicate-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

        $json = @'
[
  {
    "id": 5, "loc": "Zone Alpha", "name": "Curtain",
    "hassDevices": { "a": { "discovery_payload": { "name": "x", "unique_id": "test_5-37-0-currentValue", "device": { "identifiers": ["test_node5"] } } } },
    "values": [
      { "id": "5-37-0-currentValue", "label": "Current value" },
      { "id": "5-38-0-currentValue", "label": "Current value" }
    ]
  }
]
'@
        $db = Join-Path $script:WorkDir 'db.db'
        $nodes = Join-Path $script:WorkDir 'nodes.json'
        $rules = Join-Path $script:WorkDir 'rules.json'
        Set-Content -LiteralPath $nodes -Value $json -Encoding utf8
        Set-Content -LiteralPath $rules -Value $script:RulesJson -Encoding utf8
        New-TestDatabase -Path $db -Rows @(
            @{ DeviceID = 'test_5-37-0-currentValue'; Name = 'Zone Alpha - Curtain'; Used = 0 }
            @{ DeviceID = 'test_5-38-0-currentValue'; Name = 'Zone Alpha - Curtain'; Used = 1 }
        )

        $script:Output = & pwsh -NoProfile -File $script:ScriptPath -JsonFile $nodes -DbPath $db -RulesFile $rules -DryRun 2>&1 | Out-String
        $script:ExitCode = $LASTEXITCODE
    }

    AfterAll {
        if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
            Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports them in a dry run' {
        $script:Output | Should -Match 'Duplicates\s*:?\s*1'
    }

    It 'keeps the no-changes exit code' {
        $script:ExitCode | Should -Be 2
    }
}
