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
    #   node 9  - a Central Scene remote whose value carries NO states array.
    #             Domoticz keys its three key states as ONE DeviceID with three
    #             Unit rows, and the user has named each one differently. With
    #             nothing to say which unit means what, renaming would collapse
    #             all three, so the device must be left alone.
    #   node 10 - a Central Scene remote whose value DOES carry a states array,
    #             stored as three identically named rows. Each unit takes its
    #             own name from its state text.
    #   node 11 - the same, but with three differently named rows. Used by the
    #             undo-recovery tests: each row must get its own name, and the
    #             undo script must put each original name back on its own row.
    #   node 12 - a Central Scene remote with THREE rows but only TWO states.
    #             The mapping cannot be established, so the fallback applies.
    #   node 13 - three rows and three states, but one state's `value` is null.
    #             It would cast to 0 and map unit 0 to the wrong state text.
    #   node 14 - three rows and three states whose `value` is a non-numeric
    #             string. Casting it to int throws, and under
    #             $ErrorActionPreference = 'Stop' that would abort the run.
    #   node 15 - three rows that SHARE one name, where unit 0's computed name
    #             equals that name. Units 1 and 2 move away; the shared name is
    #             still held by unit 0 and must stay unavailable.
    #   node 16 - a device on another endpoint that wants exactly the name node
    #             15's unit 0 keeps. It must be disambiguated, not silently
    #             allowed to duplicate that name.
    #   node 17 - three rows and three states, but one state's `text` is null.
    #             Casting it to [string] would silently succeed as "", mapping
    #             a unit to a blank label and leaving its device name ending
    #             in a bare " - " instead of falling back.
    #   node 18 - three rows and three states, but one state's `text` is a
    #             single space (whitespace-only, not empty). IsNullOrEmpty
    #             would let it through, since only the base name is
    #             whitespace-normalized and not this suffix, leaving a
    #             device name with a stray trailing space.
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
  },
  {
    "id": 10, "loc": "Zone Foxtrot", "name": "Remote", "productLabel": "TESTREM2",
    "values": [
      { "id": "10-91-0-scene-001", "label": "Scene 001",
        "states": [
          { "value": 0, "text": "KeyPressed" },
          { "value": 1, "text": "KeyReleased" },
          { "value": 2, "text": "KeyHeldDown" }
        ]
      }
    ]
  },
  {
    "id": 11, "loc": "Zone Golf", "name": "Remote", "productLabel": "TESTREM3",
    "values": [
      { "id": "11-91-0-scene-002", "label": "Scene 002",
        "states": [
          { "value": 0, "text": "KeyPressed" },
          { "value": 1, "text": "KeyReleased" },
          { "value": 2, "text": "KeyHeldDown" }
        ]
      }
    ]
  },
  {
    "id": 12, "loc": "Zone Hotel", "name": "Remote", "productLabel": "TESTREM4",
    "values": [
      { "id": "12-91-0-scene-003", "label": "Scene 003",
        "states": [
          { "value": 0, "text": "KeyPressed" },
          { "value": 1, "text": "KeyReleased" }
        ]
      }
    ]
  },
  {
    "id": 13, "loc": "Zone India", "name": "Remote", "productLabel": "TESTREM5",
    "values": [
      { "id": "13-91-0-scene-004", "label": "Scene 004",
        "states": [
          { "value": null, "text": "KeyHeldDown" },
          { "value": 1, "text": "KeyReleased" },
          { "value": 2, "text": "KeyPressed" }
        ]
      }
    ]
  },
  {
    "id": 14, "loc": "Zone Juliet", "name": "Remote", "productLabel": "TESTREM6",
    "values": [
      { "id": "14-91-0-scene-005", "label": "Scene 005",
        "states": [
          { "value": "zero", "text": "KeyPressed" },
          { "value": "one", "text": "KeyReleased" },
          { "value": "two", "text": "KeyHeldDown" }
        ]
      }
    ]
  },
  {
    "id": 15, "loc": "Zone Kilo", "name": "Remote", "productLabel": "TESTREM7",
    "values": [
      { "id": "15-91-0-scene-006", "label": "Scene 006",
        "states": [
          { "value": 0, "text": "KeyPressed" },
          { "value": 1, "text": "KeyReleased" },
          { "value": 2, "text": "KeyHeldDown" }
        ]
      }
    ]
  },
  {
    "id": 16, "loc": "Zone Kilo", "name": "Remote", "productLabel": "TESTSENS",
    "values": [
      { "id": "16-49-1-Custom", "label": "Scene 006 - Short" }
    ]
  },
  {
    "id": 17, "loc": "Zone Lima", "name": "Remote", "productLabel": "TESTREM9",
    "values": [
      { "id": "17-91-0-scene-007", "label": "Scene 007",
        "states": [
          { "value": 0, "text": "KeyPressed" },
          { "value": 1, "text": null },
          { "value": 2, "text": "KeyHeldDown" }
        ]
      }
    ]
  },
  {
    "id": 18, "loc": "Zone Mike", "name": "Remote", "productLabel": "TESTREM10",
    "values": [
      { "id": "18-91-0-scene-008", "label": "Scene 008",
        "states": [
          { "value": 0, "text": "KeyPressed" },
          { "value": 1, "text": " " },
          { "value": 2, "text": "KeyHeldDown" }
        ]
      }
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
    { "name": "Scene KeyPressed",  "pattern": "91-\\d+-scene-\\d+$",     "replace": " - KeyPressed$",                "with": " - Short",       "description": "mirrors the bundled Central Scene rules" },
    { "name": "Scene KeyReleased", "pattern": "91-\\d+-scene-\\d+$",     "replace": " - KeyReleased$",               "with": " - Released",    "description": "shares a pattern with the rule above; only the replace differs" },
    { "name": "Scene KeyHeldDown", "pattern": "91-\\d+-scene-\\d+$",     "replace": " - KeyHeldDown$",               "with": " - Held",        "description": "shares a pattern with the rules above" },
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
        'test_10-91-0-scene-001'                          = 'Zone Foxtrot - Remote - Scene 001'          # three units, all identically named
        'test_11-91-0-scene-002'                          = 'Zone Golf - Remote - Tap'                   # three units, each named differently
        'test_12-91-0-scene-003'                          = 'Zone Hotel - Remote - Push'                 # three units, two states: unmappable
        'test_13-91-0-scene-004'                          = 'Zone India - Remote - A'                    # three units, one state value is null
        'test_14-91-0-scene-005'                          = 'Zone Juliet - Remote - A'                   # three units, state values are not numbers
        'test_15-91-0-scene-006'                          = 'Zone Kilo - Remote - Scene 006 - Short'     # three units sharing one name; unit 0 keeps it
        'test_16-49-1-Custom'                             = 'Zone Kilo - Remote - Old Y'                 # wants the name unit 0 of node 15 keeps
        'test_17-91-0-scene-007'                          = 'Zone Lima - Remote - A'                     # three units, one state text is null
        'test_18-91-0-scene-008'                          = 'Zone Mike - Remote - A'                     # three units, one state text is whitespace-only
    }

    # Additional DeviceStatus rows that share a DeviceID with an entry above but
    # carry a different name, as Domoticz does for a multi-unit device whose
    # units the user renamed individually.
    $script:ExtraRows = @(
        @{ DeviceID = 'test_9-91-0-scene-001'; Name = 'Zone Echo - Remote - Scene 1 Held';     Unit = 1 }
        @{ DeviceID = 'test_9-91-0-scene-001'; Name = 'Zone Echo - Remote - Scene 1 Released'; Unit = 2 }
        @{ DeviceID = 'test_10-91-0-scene-001'; Name = 'Zone Foxtrot - Remote - Scene 001'; Unit = 1 }
        @{ DeviceID = 'test_10-91-0-scene-001'; Name = 'Zone Foxtrot - Remote - Scene 001'; Unit = 2 }
        @{ DeviceID = 'test_11-91-0-scene-002'; Name = 'Zone Golf - Remote - Let go';        Unit = 1 }
        @{ DeviceID = 'test_11-91-0-scene-002'; Name = 'Zone Golf - Remote - Long hold';     Unit = 2 }
        @{ DeviceID = 'test_12-91-0-scene-003'; Name = 'Zone Hotel - Remote - Let go';       Unit = 1 }
        @{ DeviceID = 'test_12-91-0-scene-003'; Name = 'Zone Hotel - Remote - Hold';         Unit = 2 }
        @{ DeviceID = 'test_13-91-0-scene-004'; Name = 'Zone India - Remote - B';            Unit = 1 }
        @{ DeviceID = 'test_13-91-0-scene-004'; Name = 'Zone India - Remote - C';            Unit = 2 }
        @{ DeviceID = 'test_14-91-0-scene-005'; Name = 'Zone Juliet - Remote - B';           Unit = 1 }
        @{ DeviceID = 'test_14-91-0-scene-005'; Name = 'Zone Juliet - Remote - C';           Unit = 2 }
        @{ DeviceID = 'test_15-91-0-scene-006'; Name = 'Zone Kilo - Remote - Scene 006 - Short'; Unit = 1 }
        @{ DeviceID = 'test_15-91-0-scene-006'; Name = 'Zone Kilo - Remote - Scene 006 - Short'; Unit = 2 }
        @{ DeviceID = 'test_17-91-0-scene-007'; Name = 'Zone Lima - Remote - B';             Unit = 1 }
        @{ DeviceID = 'test_17-91-0-scene-007'; Name = 'Zone Lima - Remote - C';             Unit = 2 }
        @{ DeviceID = 'test_18-91-0-scene-008'; Name = 'Zone Mike - Remote - B';             Unit = 1 }
        @{ DeviceID = 'test_18-91-0-scene-008'; Name = 'Zone Mike - Remote - C';             Unit = 2 }
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

    function Get-UnitNameList {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$DeviceID
        )
        $conn = Open-SqliteDatabase -Path $Path
        try {
            $rows = Invoke-SqliteReader -Connection $conn -Sql 'SELECT Name FROM DeviceStatus WHERE DeviceID = @id ORDER BY Unit' -Parameters @{ id = $DeviceID }
        }
        finally { $conn.Close() }
        return @($rows | ForEach-Object { [string]$_.Name })
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

    It 'shows the unit number in the HTML report for a multi-unit device row' {
        $report = Get-ChildItem -LiteralPath $script:WorkDir -Filter 'rename_report-*.html' | Select-Object -First 1
        $html = Get-Content -LiteralPath $report.FullName -Raw

        $html | Should -Match 'test_10-91-0-scene-001 \(unit 0\)'
        $html | Should -Match 'test_10-91-0-scene-001 \(unit 1\)'
        $html | Should -Match 'test_10-91-0-scene-001 \(unit 2\)'
    }

    It 'does not show a unit number for a single-row device' {
        # test_7 has one Domoticz row, so its device-id must render exactly as
        # before: no "(unit N)" suffix.
        $report = Get-ChildItem -LiteralPath $script:WorkDir -Filter 'rename_report-*.html' | Select-Object -First 1
        $html = Get-Content -LiteralPath $report.FullName -Raw

        $html | Should -Not -Match 'test_7-48-0-Any \(unit'
    }

    It 'gives each unit of a Central Scene device its own name' {
        $conn = Open-SqliteDatabase -Path $script:DbPath
        try {
            $rows = Invoke-SqliteReader -Connection $conn -Sql "SELECT Unit, Name FROM DeviceStatus WHERE DeviceID = 'test_10-91-0-scene-001' ORDER BY Unit"
        }
        finally { $conn.Close() }

        $names = @($rows | ForEach-Object { [string]$_.Name })
        $names[0] | Should -Be 'Zone Foxtrot - Remote - Scene 001 - Short'
        $names[1] | Should -Be 'Zone Foxtrot - Remote - Scene 001 - Released'
        $names[2] | Should -Be 'Zone Foxtrot - Remote - Scene 001 - Held'
    }

    It 'falls back to skipping when the row count does not match the state count' {
        # test_12 has three rows but its value declares only two states, so the
        # mapping cannot be established and the v2.11 guard must still apply.
        # (test_9 covers the other fallback: a value with no states array at all.)
        $conn = Open-SqliteDatabase -Path $script:DbPath
        try {
            $rows = Invoke-SqliteReader -Connection $conn -Sql "SELECT Name FROM DeviceStatus WHERE DeviceID = 'test_12-91-0-scene-003' ORDER BY Unit"
        }
        finally { $conn.Close() }

        $names = @($rows | ForEach-Object { [string]$_.Name })
        $names[0] | Should -Be 'Zone Hotel - Remote - Push'
        $names[1] | Should -Be 'Zone Hotel - Remote - Let go'
        $names[2] | Should -Be 'Zone Hotel - Remote - Hold'
    }

    It 'falls back to skipping when a state value is not a whole number' {
        # A null state value passes a bare property check and casts to 0, which
        # would map unit 0 to the wrong state text; a non-numeric one throws on
        # the cast and, with $ErrorActionPreference = 'Stop', would abort the
        # entire run. Both are doubt, so both must fall back to the skip.
        $conn = Open-SqliteDatabase -Path $script:DbPath
        try {
            $nullValued = Invoke-SqliteReader -Connection $conn -Sql "SELECT Name FROM DeviceStatus WHERE DeviceID = 'test_13-91-0-scene-004' ORDER BY Unit"
            $textValued = Invoke-SqliteReader -Connection $conn -Sql "SELECT Name FROM DeviceStatus WHERE DeviceID = 'test_14-91-0-scene-005' ORDER BY Unit"
        }
        finally { $conn.Close() }

        @($nullValued | ForEach-Object { [string]$_.Name }) | Should -Be @(
            'Zone India - Remote - A', 'Zone India - Remote - B', 'Zone India - Remote - C')
        @($textValued | ForEach-Object { [string]$_.Name }) | Should -Be @(
            'Zone Juliet - Remote - A', 'Zone Juliet - Remote - B', 'Zone Juliet - Remote - C')
    }

    It 'falls back to skipping when a state text is null or empty' {
        # A null state text passes the property check (the property exists, its
        # value is $null) and casts to "" via [string], which would map a unit
        # to a blank label and leave its device name ending in a bare " - ".
        $conn = Open-SqliteDatabase -Path $script:DbPath
        try {
            $rows = Invoke-SqliteReader -Connection $conn -Sql "SELECT Name FROM DeviceStatus WHERE DeviceID = 'test_17-91-0-scene-007' ORDER BY Unit"
        }
        finally { $conn.Close() }

        @($rows | ForEach-Object { [string]$_.Name }) | Should -Be @(
            'Zone Lima - Remote - A', 'Zone Lima - Remote - B', 'Zone Lima - Remote - C')
    }

    It 'falls back to skipping when a state text is whitespace-only' {
        # A single-space state text is not null or empty, so IsNullOrEmpty would
        # let it through and IsNullOrWhiteSpace is required to catch it. Only
        # the base name is whitespace-normalized, not this suffix, so letting
        # it through would write a name ending in a bare " - " (the label
        # collapses to nothing visible) rather than falling back to the skip.
        $conn = Open-SqliteDatabase -Path $script:DbPath
        try {
            $rows = Invoke-SqliteReader -Connection $conn -Sql "SELECT Name FROM DeviceStatus WHERE DeviceID = 'test_18-91-0-scene-008' ORDER BY Unit"
        }
        finally { $conn.Close() }

        $names = @($rows | ForEach-Object { [string]$_.Name })
        @($names) | Should -Be @(
            'Zone Mike - Remote - A', 'Zone Mike - Remote - B', 'Zone Mike - Remote - C')
        $names | Where-Object { $_ -match ' - $' } | Should -BeNullOrEmpty
    }

    It 'completes the run instead of aborting on an unusable state value' {
        # The fallback is only a fallback if the run survives it.
        $script:Output | Should -Match 'Summary'
        $script:Output | Should -Not -Match 'Cannot convert'
    }

    It 'keeps a name that another unit of the same device still holds' {
        # Three rows share one name and unit 0's computed name equals it, so
        # unit 0 keeps it while units 1 and 2 move away. Freeing the shared name
        # when unit 1 moved would let another device claim a name unit 0 still
        # holds, which is the duplicate collision detection exists to prevent.
        $conn = Open-SqliteDatabase -Path $script:DbPath
        try {
            $rows = Invoke-SqliteReader -Connection $conn -Sql "SELECT Name FROM DeviceStatus WHERE DeviceID = 'test_15-91-0-scene-006' ORDER BY Unit"
        }
        finally { $conn.Close() }

        $names = @($rows | ForEach-Object { [string]$_.Name })
        $names[0] | Should -Be 'Zone Kilo - Remote - Scene 006 - Short'
        $names[1] | Should -Be 'Zone Kilo - Remote - Scene 006 - Released'
        $names[2] | Should -Be 'Zone Kilo - Remote - Scene 006 - Held'

        # The device that wanted that name sits on another endpoint, so it is
        # disambiguated rather than being allowed to duplicate the name.
        $script:Names['test_16-49-1-Custom'] | Should -Be 'Zone Kilo - Remote - Scene 006 - Short - EP1'
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

    It 'writes an undo statement per unit, carrying that unit own old name' {
        $undo = Get-ChildItem -LiteralPath $script:WorkDir -Filter 'undo_rename-*.sql' | Select-Object -First 1
        $undo | Should -Not -BeNullOrEmpty
        $sql = Get-Content -LiteralPath $undo.FullName -Raw

        # Every generated UPDATE must scope to a single row. A statement matching
        # on DeviceID alone would rewrite every unit of a multi-unit device.
        $updates = [regex]::Matches($sql, 'UPDATE DeviceStatus SET .*?;')
        $updates.Count | Should -BeGreaterThan 0
        foreach ($u in $updates) {
            $u.Value | Should -Match 'AND Unit = \d+;$'
        }
    }
}

Describe 'Undo restores every unit its own name' -Skip:(-not $EngineAvailable) {
    # Regression test for the data loss fixed in v2.11 and made structurally
    # impossible in v2.12: a device whose rows were named individually used to
    # be renamed through a DeviceID-only UPDATE, and the generated undo script
    # matched on DeviceID alone too, so running it overwrote all three rows with
    # whichever single name had been captured. The documented recovery path
    # destroyed the evidence.
    #
    # This runs against its own fixture database so the restored names cannot
    # disturb the end-state assertions in the Describe above.
    BeforeAll {
        $script:UndoWorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("renamer-undo-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:UndoWorkDir -Force | Out-Null

        $script:UndoDbPath = Join-Path $script:UndoWorkDir 'db.db'
        $json  = Join-Path $script:UndoWorkDir 'nodes.json'
        $rules = Join-Path $script:UndoWorkDir 'rules.json'

        Set-Content -LiteralPath $json  -Value $script:NodesJson -Encoding utf8
        Set-Content -LiteralPath $rules -Value $script:RulesJson -Encoding utf8
        New-TestDatabase -Path $script:UndoDbPath

        $null = & pwsh -NoProfile -File $script:ScriptPath -JsonFile $json -DbPath $script:UndoDbPath -RulesFile $rules -Force -NoBackup 2>&1

        # The three rows of test_11 start out named differently and are renamed
        # per unit, which is exactly the case a DeviceID-only undo cannot undo.
        $script:RenamedNames = @(Get-UnitNameList -Path $script:UndoDbPath -DeviceID 'test_11-91-0-scene-002')

        $undoFile = Get-ChildItem -LiteralPath $script:UndoWorkDir -Filter 'undo_rename-*.sql' | Select-Object -First 1
        $script:UndoSql = if ($undoFile) { Get-Content -LiteralPath $undoFile.FullName -Raw } else { $null }
        if ($script:UndoSql) {
            $conn = Open-SqliteDatabase -Path $script:UndoDbPath
            try {
                foreach ($line in ($script:UndoSql -split "`r?`n")) {
                    $stmt = $line.Trim()
                    if ($stmt -eq '' -or $stmt.StartsWith('--')) { continue }
                    [void](Invoke-SqliteNonQuery -Connection $conn -Sql $stmt)
                }
            }
            finally { $conn.Close() }
        }
        $script:RestoredNames = @(Get-UnitNameList -Path $script:UndoDbPath -DeviceID 'test_11-91-0-scene-002')
    }

    AfterAll {
        if ($script:UndoWorkDir -and (Test-Path -LiteralPath $script:UndoWorkDir)) {
            Remove-Item -LiteralPath $script:UndoWorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'renamed all three differently named rows to their own state names first' {
        # Without this the recovery assertion below would pass vacuously against
        # a run that never touched the device.
        $script:RenamedNames[0] | Should -Be 'Zone Golf - Remote - Scene 002 - Short'
        $script:RenamedNames[1] | Should -Be 'Zone Golf - Remote - Scene 002 - Released'
        $script:RenamedNames[2] | Should -Be 'Zone Golf - Remote - Scene 002 - Held'
    }

    It 'puts every original name back on its own unit' {
        # A DeviceID-only undo would leave all three rows holding one name.
        $script:RestoredNames[0] | Should -Be 'Zone Golf - Remote - Tap'
        $script:RestoredNames[1] | Should -Be 'Zone Golf - Remote - Let go'
        $script:RestoredNames[2] | Should -Be 'Zone Golf - Remote - Long hold'
    }

    It 'restores three distinct names, not three copies of one' {
        @($script:RestoredNames | Sort-Object -Unique).Count | Should -Be 3
    }
}
