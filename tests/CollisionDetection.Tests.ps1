#Requires -Version 7.0

<#
.SYNOPSIS
    Integration tests for the device-name collision detection in
    Rename-Domoticz-From-ZwaveJSON.ps1.

.DESCRIPTION
    These tests build a tiny, self-contained SQLite database and Z-Wave JSON
    export (no dependency on the gitignored _temp/ fixtures), run the renamer
    against them, and assert on the resulting end-state device names.

    They pin the behaviour that a rename must never silently create a duplicate
    name: a proposed name is checked against the FULL end state (every device
    that keeps its name), not only against other pending renames.

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

    # Minimal Z-Wave export using synthetic English placeholder names that do
    # not correspond to any real installation. The base identifier 'test' is
    # derived from the first node's hassDevices identifier ('test_node5' with
    # '_node5' stripped).
    #
    #   node 5  - a PIR exposing motion on BOTH the modern Notification CC (113,
    #             already correctly named) and the legacy Binary Sensor CC (48).
    #             A rule that renames the CC48 device to '- Motion' collides with
    #             the unchanged CC113 device on the same endpoint (0).
    #   node 6  - a two-channel switch whose endpoints 1 and 2 both reduce to the
    #             same base name -> auto-resolvable by endpoint suffix.
    #   node 7  - a PIR whose CC48 device renames uniquely (no collision).
    #   node 8  - a dimmer reporting its meter on endpoint 0. Domoticz still
    #             holds a device for endpoint 1 from before the value moved
    #             endpoint; that stale device is absent from this export but
    #             still owns the clean name, so the live endpoint-0 device can
    #             only be renamed with an endpoint suffix.
    #   node 9  - a Central Scene remote. Domoticz keys its three key states as
    #             ONE DeviceID with three Unit rows, and the user has named each
    #             one differently. A single Z-Wave value cannot supply three
    #             names, and every write matches on DeviceID alone, so renaming
    #             would collapse all three and the undo could not restore them.
    $script:NodesJson = @'
[
  {
    "id": 5, "loc": "Zone Alpha", "name": "PIR", "productLabel": "TESTPIR",
    "hassDevices": { "x": { "discovery_payload": { "device": { "identifiers": ["test_node5"] } } } },
    "values": [
      { "id": "5-113-0-Home Security-Motion sensor status", "label": "Motion sensor status" },
      { "id": "5-48-0-Motion", "label": "Sensor state (Motion)" }
    ]
  },
  {
    "id": 6, "loc": "Zone Bravo", "name": "Lamp", "productLabel": "TESTSW",
    "values": [
      { "id": "6-37-1-currentValue", "label": "Current value" },
      { "id": "6-37-2-currentValue", "label": "Current value" }
    ]
  },
  {
    "id": 7, "loc": "Zone Charlie", "name": "PIR", "productLabel": "TESTPIR2",
    "values": [
      { "id": "7-48-0-Any", "label": "Sensor state (Any)" }
    ]
  },
  {
    "id": 8, "loc": "Zone Delta", "name": "Lamp", "productLabel": "TESTDIM",
    "values": [
      { "id": "8-50-0-value-66049", "label": "Electric Consumption [W]" }
    ]
  },
  {
    "id": 9, "loc": "Zone Echo", "name": "Remote", "productLabel": "TESTREM",
    "values": [
      { "id": "9-91-0-scene-001", "label": "Scene 001" }
    ]
  }
]
'@

    $script:RulesJson = @'
{
  "description": "collision-detection test rules",
  "rules": [
    { "name": "Motion Sensor",  "pattern": "113-\\d+-Home_Security-Motion_sensor_status$", "replace": " - Motion sensor status$",  "with": " - Motion",          "description": "keeps CC113 device at its existing name" },
    { "name": "CC48 Motion",    "pattern": "48-\\d+-Motion$",                                "replace": " - Sensor state \\(Motion\\)$", "with": " - Motion",      "description": "forces a collision with the unchanged CC113 device" },
    { "name": "Switch EP",      "pattern": "37-\\d+-currentValue$",                          "replace": " - Current value$",             "with": "",               "description": "both endpoints reduce to the same base name" },
    { "name": "CC48 Any",       "pattern": "48-\\d+-Any$",                                   "replace": " - Sensor state \\(Any\\)$",    "with": " - Motion (Binary)", "description": "unique rename, no collision" },
    { "name": "Scene",          "pattern": "91-\\d+-scene-\\d+$",                          "replace": " - Scene 001$",                 "with": " - Scene 1",     "description": "would collapse three differently named Domoticz rows into one" },
    { "name": "Electric Watts", "pattern": "50-\\d+-value-66049$",                           "replace": " - Electric Consumption \\[W\\]$", "with": " [W]",         "description": "collides with a stale device Domoticz kept from another endpoint" }
  ]
}
'@

    # Original device names, keyed by DeviceID. The renamer builds DeviceIDs as
    # {baseIdentifier}_{value.id} with spaces -> '_' and '/' -> '-'.
    $script:OriginalNames = @{
        'test_5-113-0-Home_Security-Motion_sensor_status' = 'Zone Alpha - PIR - Motion'                  # already correct
        'test_5-48-0-Motion'                              = 'Zone Alpha - PIR - Sensor state (Motion)'   # would collide
        'test_6-37-1-currentValue'                        = 'Zone Bravo - Lamp - Current value'          # pending, endpoint 1
        'test_6-37-2-currentValue'                        = 'Zone Bravo - Lamp - Current value'          # pending, endpoint 2
        'test_7-48-0-Any'                                 = 'Zone Charlie - PIR - Sensor state (Any)'    # clean rename
        'test_node5'                                      = 'Zone Alpha-PIR'                             # node-level combined Temp+Hum device
        'test_8-50-0-value-66049'                         = 'Zone Delta-Lamp (Zone Delta - Lamp - Electric Consumption [W])'  # live, badly named
        'test_8-50-1-value-66049'                         = 'Zone Delta - Lamp [W]'                      # stale, holds the clean name
        'test_9-91-0-scene-001'                           = 'Zone Echo - Remote - Scene 1 Pressed'       # one of three disagreeing rows
    }

    # Additional DeviceStatus rows that share a DeviceID with an entry above but
    # carry a different name, as Domoticz does for a multi-unit device whose
    # units the user renamed individually.
    $script:ExtraRows = @(
        @{ DeviceID = 'test_9-91-0-scene-001'; Name = 'Zone Echo - Remote - Scene 1 Held';     Unit = 1 }
        @{ DeviceID = 'test_9-91-0-scene-001'; Name = 'Zone Echo - Remote - Scene 1 Released'; Unit = 2 }
    )

    # Domoticz device Type per DeviceID (82 = Temp+Humidity). Others default to 0.
    $script:DeviceTypes = @{ 'test_node5' = 82 }

    # Used / LastUpdate per DeviceID, for devices that should not look healthy.
    # The stale endpoint-1 meter is what a device left behind by Domoticz looks
    # like: dropped from the dashboard, and not updated for days.
    $script:DeviceMeta = @{
        'test_8-50-1-value-66049' = @{ Used = 0; LastUpdate = '2020-03-04 05:06:07' }
    }

    function New-TestDatabase {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper writing a throwaway fixture database; nothing to confirm.')]
        param([Parameter(Mandatory)][string]$Path)
        $conn = Open-SqliteDatabase -Path $Path -CreateIfMissing
        try {
            # Used and LastUpdate mirror the real Domoticz DeviceStatus schema.
            # The renamer reads them to describe a device that is holding a
            # contested name; without them the fixture no longer matches reality.
            # Unit mirrors the real Domoticz schema: DeviceID is NOT unique, and
            # a multi-unit device is several rows sharing one DeviceID.
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'CREATE TABLE DeviceStatus (DeviceID TEXT, Name TEXT, SwitchType INTEGER, CustomImage INTEGER, Type INTEGER, Used INTEGER, LastUpdate TEXT, Unit INTEGER)')
            foreach ($id in $script:OriginalNames.Keys) {
                $type = if ($script:DeviceTypes.ContainsKey($id)) { $script:DeviceTypes[$id] } else { 0 }
                $meta = if ($script:DeviceMeta.ContainsKey($id)) { $script:DeviceMeta[$id] } else { @{ Used = 1; LastUpdate = '2026-01-01 00:00:00' } }
                [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'INSERT INTO DeviceStatus (DeviceID, Name, SwitchType, CustomImage, Type, Used, LastUpdate, Unit) VALUES (@id, @name, 8, 0, @type, @used, @lastUpdate, 0)' -Parameters @{ id = $id; name = $script:OriginalNames[$id]; type = $type; used = $meta.Used; lastUpdate = $meta.LastUpdate })
            }
            foreach ($extra in $script:ExtraRows) {
                [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'INSERT INTO DeviceStatus (DeviceID, Name, SwitchType, CustomImage, Type, Used, LastUpdate, Unit) VALUES (@id, @name, 8, 0, 0, 1, ''2026-01-01 00:00:00'', @unit)' -Parameters @{ id = $extra.DeviceID; name = $extra.Name; unit = $extra.Unit })
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

Describe 'Collision detection against the end state' -Skip:(-not $EngineAvailable) {
    BeforeAll {
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("renamer-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

        $script:DbPath = Join-Path $script:WorkDir 'db.db'
        $db    = $script:DbPath
        $json  = Join-Path $script:WorkDir 'nodes.json'
        $rules = Join-Path $script:WorkDir 'rules.json'

        Set-Content -LiteralPath $json  -Value $script:NodesJson -Encoding utf8
        Set-Content -LiteralPath $rules -Value $script:RulesJson -Encoding utf8
        New-TestDatabase -Path $db

        # Run as a child process so the script's `exit` calls do not stop Pester.
        $script:Output = & pwsh -NoProfile -File $script:ScriptPath -JsonFile $json -DbPath $db -RulesFile $rules -Force -NoBackup 2>&1 | Out-String
        $script:Names = Get-DeviceNameMap -Path $db
    }

    AfterAll {
        if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
            Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not rename a device onto a name another device keeps' {
        # The CC48 device must be left untouched because renaming it to
        # 'Zone Alpha - PIR - Motion' would duplicate the unchanged CC113 device.
        $script:Names['test_5-48-0-Motion'] | Should -Be 'Zone Alpha - PIR - Sensor state (Motion)'
        $script:Names['test_5-113-0-Home_Security-Motion_sensor_status'] | Should -Be 'Zone Alpha - PIR - Motion'
    }

    It 'reports the unresolvable collision to the user' {
        $script:Output | Should -Match 'COLLISION'
        $script:Output | Should -Match 'unresolvable name collision'
    }

    It 'auto-resolves two pending renames on different endpoints with endpoint suffixes' {
        $script:Names['test_6-37-1-currentValue'] | Should -Be 'Zone Bravo - Lamp - EP1'
        $script:Names['test_6-37-2-currentValue'] | Should -Be 'Zone Bravo - Lamp - EP2'
    }

    It 'applies a rename that does not collide' {
        $script:Names['test_7-48-0-Any'] | Should -Be 'Zone Charlie - PIR - Motion (Binary)'
    }

    It 'renames a node-level Temp+Humidity device to "{loc} - {name} - Climate"' {
        # test_node5 (Domoticz Type 82) has no Z-Wave value; it is renamed via the
        # synthetic node-level target, with a Climate label for Temp+Humidity.
        $script:Names['test_node5'] | Should -Be 'Zone Alpha - PIR - Climate'
    }

    It 'disambiguates a live device blocked by a stale device Domoticz kept' {
        # The stale endpoint-1 meter is not in the export, so it is never visited
        # and keeps its name. The live endpoint-0 meter therefore cannot have the
        # clean name and is disambiguated with its own endpoint instead.
        $script:Names['test_8-50-1-value-66049'] | Should -Be 'Zone Delta - Lamp [W]'
        $script:Names['test_8-50-0-value-66049'] | Should -Be 'Zone Delta - Lamp [W] - EP0'
    }

    It 'names the stale device that blocked the clean name' {
        # Without this the endpoint suffix is unexplainable: the report has to say
        # WHICH device holds the name and that the node source no longer knows it,
        # otherwise the only fix (delete that device) is undiscoverable.
        $script:Output | Should -Match 'no longer in the node source'
        $script:Output | Should -Match 'test_8-50-1-value-66049'
        $script:Output | Should -Match 'Used=0'
        $script:Output | Should -Match '2020-03-04 05:06:07'
    }

    It 'explains the disambiguation in the HTML report' {
        $report = Get-ChildItem -LiteralPath $script:WorkDir -Filter 'rename_report-*.html' | Select-Object -First 1
        $report | Should -Not -BeNullOrEmpty
        $html = Get-Content -LiteralPath $report.FullName -Raw

        $html | Should -Match 'Names Disambiguated'
        $html | Should -Match 'test_8-50-1-value-66049'
        $html | Should -Match 'not in node source'
        # The live device must NOT be reported as stale.
        $html | Should -Match 'blame-status live'
    }

    It 'does not skip a device whose collision was auto-resolved' {
        # Auto-resolved collisions are tracked separately from unresolvable ones
        # precisely because the unresolvable list drives the skip filter. If the
        # two were merged, these devices would silently keep their old names.
        $script:Names['test_6-37-1-currentValue'] | Should -Not -Match 'Current value'
        $script:Names['test_8-50-0-value-66049'] | Should -Not -Match '^Zone Delta-Lamp'
    }

    It 'does not collapse a DeviceID whose Domoticz rows disagree' {
        # One Z-Wave value cannot supply three names, and both the UPDATE and the
        # undo statement match on DeviceID alone. Renaming here would overwrite
        # all three rows with one name and the undo could not put them back, so
        # the device must be left untouched.
        $conn = Open-SqliteDatabase -Path $script:DbPath
        try {
            $rows = Invoke-SqliteReader -Connection $conn -Sql "SELECT Name FROM DeviceStatus WHERE DeviceID = 'test_9-91-0-scene-001' ORDER BY Unit"
        }
        finally { $conn.Close() }

        $names = @($rows | ForEach-Object { [string]$_.Name })
        $names.Count | Should -Be 3
        $names[0] | Should -Be 'Zone Echo - Remote - Scene 1 Pressed'
        $names[1] | Should -Be 'Zone Echo - Remote - Scene 1 Held'
        $names[2] | Should -Be 'Zone Echo - Remote - Scene 1 Released'
    }

    It 'tells the user why the ambiguous device was skipped' {
        $script:Output | Should -Match 'skipped'
        $script:Output | Should -Match 'test_9-91-0-scene-001'
        $script:Output | Should -Match 'Ambiguous'
    }

    It 'does not let another device take a name held by a non-primary row' {
        # Only one row per DeviceID is loaded into memory, so the names on the
        # other rows would be invisible to collision detection unless seeded
        # explicitly. Every distinct name in the table must be treated as taken.
        $conn = Open-SqliteDatabase -Path $script:DbPath
        try {
            $rows = Invoke-SqliteReader -Connection $conn -Sql "SELECT Name, COUNT(*) AS n FROM DeviceStatus GROUP BY Name HAVING COUNT(*) > 1"
        }
        finally { $conn.Close() }

        # The only legitimately repeated name belongs to the three rows of the
        # ambiguous device itself, which were left alone. Nothing else may share.
        @($rows) | Should -BeNullOrEmpty
    }

    It 'leaves no duplicate device names in the end state' {
        $duplicates = $script:Names.Values |
            Group-Object |
            Where-Object { $_.Count -gt 1 } |
            ForEach-Object { $_.Name }
        $duplicates | Should -BeNullOrEmpty
    }
}
