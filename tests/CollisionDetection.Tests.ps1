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
    { "name": "CC48 Any",       "pattern": "48-\\d+-Any$",                                   "replace": " - Sensor state \\(Any\\)$",    "with": " - Motion (Binary)", "description": "unique rename, no collision" }
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
    }

    # Domoticz device Type per DeviceID (82 = Temp+Humidity). Others default to 0.
    $script:DeviceTypes = @{ 'test_node5' = 82 }

    function New-TestDatabase {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper writing a throwaway fixture database; nothing to confirm.')]
        param([Parameter(Mandatory)][string]$Path)
        $conn = Open-SqliteDatabase -Path $Path -CreateIfMissing
        try {
            [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'CREATE TABLE DeviceStatus (DeviceID TEXT, Name TEXT, SwitchType INTEGER, CustomImage INTEGER, Type INTEGER)')
            foreach ($id in $script:OriginalNames.Keys) {
                $type = if ($script:DeviceTypes.ContainsKey($id)) { $script:DeviceTypes[$id] } else { 0 }
                [void](Invoke-SqliteNonQuery -Connection $conn -Sql 'INSERT INTO DeviceStatus (DeviceID, Name, SwitchType, CustomImage, Type) VALUES (@id, @name, 8, 0, @type)' -Parameters @{ id = $id; name = $script:OriginalNames[$id]; type = $type })
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

        $db    = Join-Path $script:WorkDir 'db.db'
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

    It 'leaves no duplicate device names in the end state' {
        $duplicates = $script:Names.Values |
            Group-Object |
            Where-Object { $_.Count -gt 1 } |
            ForEach-Object { $_.Name }
        $duplicates | Should -BeNullOrEmpty
    }
}
