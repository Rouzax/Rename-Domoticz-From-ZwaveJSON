#Requires -Version 7.0

<#
.SYNOPSIS
    Integration tests for the reporting of Domoticz devices that have no
    counterpart in the Z-Wave node source.

.DESCRIPTION
    These tests build a tiny, self-contained SQLite database and Z-Wave JSON
    export (no dependency on the gitignored _temp/ fixtures) and run the
    renamer against them.

    They pin the behaviour that such a device is REPORTED rather than silently
    passed over. The tool builds its rename candidates from node.values alone,
    so a DeviceStatus row keyed on something that is not a live Z-Wave value is
    never visited. That is correct (renaming a dead row would only make it look
    healthy) but it used to be invisible, which made a missing rename
    indistinguishable from a bug in the tool.

    Two causes are told apart, because the fix differs:
      - zwave-js-ui still advertises a Home Assistant discovery entry for the
        device while the Z-Wave value behind it is gone. Domoticz keeps
        (re)creating the device from that entry, so the discovery entry has to
        be cleared in zwave-js-ui before deleting the device helps.
      - the device is in neither node.values nor node.hassDevices, so nothing
        will ever revive it and it can simply be deleted in Domoticz.

    Run with:  Invoke-Pester -Path ./tests

    These tests build and read fixture databases through the same SQLite engine
    the tool uses, provisioned by setup.ps1 into ./lib. If ./lib is absent they
    skip cleanly (run "pwsh ./setup.ps1" first).
#>

# Discovery-time: decide whether the SQLite engine is present so the Describe
# block below can be skipped without failing.
$EngineAvailable = Test-Path -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Microsoft.Data.Sqlite.dll')

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path $script:RepoRoot 'Rename-Domoticz-From-ZwaveJSON.ps1'
    $script:LibDir = Join-Path $script:RepoRoot 'lib'

    Import-Module (Join-Path $script:RepoRoot 'modules/DomoticzSqlite/DomoticzSqlite.psd1') -Force -ErrorAction Stop
    Initialize-SqliteEngine -LibDir $script:LibDir

    # One node, modelled on a real Fibaro roller shutter that was re-interviewed:
    # its meter values came back on a different endpoint, so the values the
    # discovery entries were built from no longer exist.
    #
    #   5-37-0-currentValue     live value, renames normally
    #   5-50-0-value-65536      live value, no Domoticz device (Domoticz never
    #                           saw a discovery entry for this endpoint)
    #
    # hassDevices still advertises 5-50-1-value-66048, an endpoint-1 meter that
    # node.values no longer has. The base identifier 'test' is derived from the
    # first hassDevices entry's identifier ('test_node5' with '_node5' stripped).
    $script:NodesJson = @'
[
  {
    "id": 5, "loc": "Zone Alpha", "name": "Lamp", "productLabel": "TESTDIM",
    "hassDevices": {
      "switch_position_0": {
        "discovery_payload": {
          "name": "Zone Alpha - Lamp - Current value",
          "unique_id": "test_5-37-0-currentValue",
          "device": { "identifiers": ["test_node5"] }
        }
      },
      "sensor_electric_w_value_1_1": {
        "discovery_payload": {
          "name": "Zone Alpha - Lamp - Electric [W]",
          "unique_id": "test_5-50-1-value-66048",
          "device": { "identifiers": ["test_node5"] }
        }
      }
    },
    "values": [
      { "id": "5-37-0-currentValue", "label": "Current value" },
      { "id": "5-50-0-value-65536", "label": "Electric [kWh]" }
    ]
  }
]
'@

    $script:RulesJson = @'
{
  "description": "orphan-reporting test rules",
  "rules": [
    { "name": "Switch", "pattern": "37-\\d+-currentValue$", "replace": " - Current value$", "with": "", "description": "a live device that renames normally" }
  ]
}
'@

    # DeviceID -> Name, Used, LastUpdate. Mirrors the real DeviceStatus schema.
    $script:Rows = @(
        # Live: has a Z-Wave value, renames to 'Zone Alpha - Lamp'.
        @{ DeviceID = 'test_5-37-0-currentValue'; Name = 'Zone Alpha - Lamp - Current value'; Used = 1; LastUpdate = '2026-01-01 00:00:00' }

        # Orphan, discovery kind: zwave-js-ui still advertises it, the value is
        # gone. Domoticz created it from the discovery entry, hence the raw name.
        @{ DeviceID = 'test_5-50-1-value-66048'; Name = 'Zone Alpha-Lamp (Zone Alpha - Lamp - Electric [W])'; Used = 0; LastUpdate = '2026-02-03 04:05:06' }

        # Orphan, gone kind: in neither node.values nor node.hassDevices.
        @{ DeviceID = 'test_5-113-1-System-Hardware_status'; Name = 'Zone Alpha - Lamp - Hardware'; Used = 0; LastUpdate = '2020-03-04 05:06:07' }

        # Another vendor's device. Domoticz holds devices from every hardware
        # type it talks to; none of them belong in this report.
        @{ DeviceID = 'othervendor_1-2-3'; Name = 'Some Other Hardware Device'; Used = 1; LastUpdate = '2026-01-01 00:00:00' }
    )

    function New-TestDatabase {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper writing a throwaway fixture database; nothing to confirm.')]
        param([Parameter(Mandatory)][string]$Path)
        $conn = Open-SqliteDatabase -Path $Path -CreateIfMissing
        try {
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'CREATE TABLE DeviceStatus (DeviceID TEXT, Name TEXT, SwitchType INTEGER, CustomImage INTEGER, Type INTEGER, Used INTEGER, LastUpdate TEXT, Unit INTEGER)')
            foreach ($row in $script:Rows) {
                [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'INSERT INTO DeviceStatus (DeviceID, Name, SwitchType, CustomImage, Type, Used, LastUpdate, Unit) VALUES (@id, @name, 8, 0, 0, @used, @lastUpdate, 0)' -Parameters @{ id = $row.DeviceID; name = $row.Name; used = $row.Used; lastUpdate = $row.LastUpdate })
            }
        }
        finally { $conn.Close() }
    }

    function Get-DeviceNameMap {
        param([Parameter(Mandatory)][string]$Path)
        $conn = Open-SqliteDatabase -Path $Path
        try {
            $rows = Invoke-SqliteReader -Connection $conn -Sql 'SELECT DeviceID, Name FROM DeviceStatus'
        }
        finally { $conn.Close() }
        $map = @{}
        foreach ($row in $rows) { $map[[string]$row.DeviceID] = [string]$row.Name }
        return $map
    }
}

Describe 'Devices in Domoticz with no counterpart in the node source' -Skip:(-not $EngineAvailable) {
    BeforeAll {
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("renamer-orphan-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

        $script:DbPath = Join-Path $script:WorkDir 'db.db'
        $json  = Join-Path $script:WorkDir 'nodes.json'
        $rules = Join-Path $script:WorkDir 'rules.json'

        Set-Content -LiteralPath $json  -Value $script:NodesJson -Encoding utf8
        Set-Content -LiteralPath $rules -Value $script:RulesJson -Encoding utf8
        New-TestDatabase -Path $script:DbPath

        # Run as a child process so the script's `exit` calls do not stop Pester.
        $script:Output = & pwsh -NoProfile -File $script:ScriptPath -JsonFile $json -DbPath $script:DbPath -RulesFile $rules -Force -NoBackup 2>&1 | Out-String
        $script:Names = Get-DeviceNameMap -Path $script:DbPath

        $reportFile = Get-ChildItem -LiteralPath $script:WorkDir -Filter 'rename_report-*.html' | Select-Object -First 1
        $script:Report = if ($reportFile) { Get-Content -LiteralPath $reportFile.FullName -Raw } else { '' }
    }

    AfterAll {
        if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
            Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'still renames the device that does have a Z-Wave value' {
        # Guards the reporting from swallowing the run: orphans are reported,
        # everything else goes on renaming as before.
        $script:Names['test_5-37-0-currentValue'] | Should -Be 'Zone Alpha - Lamp'
    }

    It 'leaves both orphaned devices untouched' {
        $script:Names['test_5-50-1-value-66048'] | Should -Be 'Zone Alpha-Lamp (Zone Alpha - Lamp - Electric [W])'
        $script:Names['test_5-113-1-System-Hardware_status'] | Should -Be 'Zone Alpha - Lamp - Hardware'
    }

    It 'reports a device whose discovery entry outlived its Z-Wave value' {
        $script:Output | Should -Match 'test_5-50-1-value-66048'
        $script:Output | Should -Match 'discovery entry'
    }

    It 'reports a device that is in neither the values nor the discovery entries' {
        $script:Output | Should -Match 'test_5-113-1-System-Hardware_status'
    }

    It 'names how long each orphaned device has been idle so a dead one can be told from a live one' {
        $script:Output | Should -Match '2026-02-03 04:05:06'
        $script:Output | Should -Match '2020-03-04 05:06:07'
    }

    It 'does not report devices belonging to other hardware' {
        # Domoticz holds devices from every hardware type it talks to. Only rows
        # under this Z-Wave base identifier are this tool's business.
        $script:Output | Should -Not -Match 'othervendor'
    }

    It 'lists the orphaned devices in the HTML report' {
        $script:Report | Should -Not -BeNullOrEmpty
        $script:Report | Should -Match 'test_5-50-1-value-66048'
        $script:Report | Should -Match 'test_5-113-1-System-Hardware_status'
        $script:Report | Should -Not -Match 'othervendor'
    }

    It 'counts the orphaned devices in the summary box' {
        $script:Output | Should -Match 'Orphaned\s*:?\s*2'
    }
}
