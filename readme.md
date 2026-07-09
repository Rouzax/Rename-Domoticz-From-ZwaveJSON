# Domoticz Device Renamer for Z-Wave JS

Automatically rename your Domoticz devices based on the room and device names configured in Z-Wave JS UI.

**The problem:** When Z-Wave JS creates devices in Domoticz via MQTT Auto-Discovery, they get generic names like `zwavejs2mqtt_0xc15d8aa6_42-49-0-Air_temperature`. Finding the right device becomes a nightmare.

**The solution:** This script reads your Z-Wave JS export and renames devices to friendly names like `Living Room - Motion Sensor - Motion`, matching your Z-Wave JS configuration. It can also fix device types (so smoke detectors get a Reset button, motion sensors show the right icon, etc.).

<img width="987" height="830" alt="image" src="https://github.com/user-attachments/assets/5cba8a2c-f18f-4c16-8404-54a58ab996e0" />

---

## ⚠️ Important: Use with Care

This script modifies the **Domoticz database** directly. While it includes safety features, improper use may lead to unintended changes.

**Before running:**

1. **Stop Domoticz before applying changes** — Domoticz caches device rows in memory and periodically writes them back, so it can overwrite your renames while it runs, and new names only appear after a restart anyway. `-DryRun` is safe to run at any time. The script warns you (cross-platform) if the database is still in use, but you should stop Domoticz regardless.
2. **Test with `-DryRun` first** — Preview changes without modifying anything
3. **Let it create a backup** — The script automatically backs up your database
4. **Review the HTML report** — Check the changes look correct before running live

---

## 📥 Requirements

* **PowerShell 7.0+** (required for emoji support and System.Web.HttpUtility)
* **SQLite assemblies** provisioned by `setup.ps1` (see below). No system SQLite or PSSQLite module is needed.
* **Z-Wave JS UI** with JSON export
* **Internet access on first setup** (to download the SQLite assemblies once)

---

## 🧰 First-Time Setup

The script talks to the Domoticz database through **Microsoft.Data.Sqlite** plus a
native SQLite library. Run the setup script once per machine to download the
pinned, checksum-verified assemblies into a local `lib/` folder:

```powershell
pwsh ./setup.ps1
```

`setup.ps1` detects your CPU/OS and fetches the matching native SQLite. This is
what lets the tool run on **ARM (Raspberry Pi), x64, and Apple Silicon** alike:
supported runtimes include `linux-x64`, `linux-arm64`, `linux-arm`, `win-x64`,
and `osx-arm64`. The download is a one-time step; re-run it (or `setup.ps1 -Force`)
only after upgrading the pinned versions. The `lib/` folder is not committed to
git.

> **Raspberry Pi note:** the older PSSQLite module shipped only x86/x64 native
> SQLite and could not run on ARM. This setup replaces it and works natively on
> Pi OS (64-bit `linux-arm64` recommended; 32-bit `linux-arm` also supported).

---

## 📄 How to Export the JSON from Z-Wave JS UI

1. Open **Z-Wave JS UI**.
2. Go to **General Actions**.
3. Choose **Dump → EXPORT** to download a full JSON export of all nodes.
4. Save the file for use with this script.

---

## ⚙️ Script Parameters

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db"
```

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `-JsonFile` | Path to the exported JSON file from Z-Wave JS UI |
| `-DbPath` | Path to your Domoticz database (`domoticz.db`) |

### Optional Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-LogFile` | Path to store the debug log | `<db folder>\rename_log-<timestamp>.txt` |
| `-CsvFile` | Path to store the renaming summary CSV | None (only generated when specified) |
| `-RulesFile` | Path to custom renaming rules JSON file | Auto-loads `rename_rules.json` from script folder if present; otherwise built-in rules |
| `-HtmlReport` | Path to save the HTML report | `<db folder>\rename_report-<timestamp>.html` |
| `-UndoFile` | Path to save SQL undo script | `<db folder>\undo_rename-<timestamp>.sql` |
| `-ExcludeDeviceIds` | Array of DeviceIDs to exclude | None |
| `-ExcludePattern` | Regex pattern to exclude DeviceIDs | None |
| `-DryRun` | Preview changes without modifying database | `$false` |
| `-Force` | Skip confirmation prompts | `$false` |
| `-NoBackup` | Skip database backup (use with caution) | `$false` |

---

## 🆕 New Features in v2.0

### 🔍 DryRun Mode

Preview all changes without modifying the database:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" -DryRun
```

### 📂 Auto-Loading Rules

The repository includes a `rename_rules.json` with 29 rules covering common Z-Wave device types (smoke detectors, motion sensors, door contacts, battery alerts, etc.), including `switchType` and `customImage` settings.

When you run the script from the repository directory and don't specify `-RulesFile`, this file is loaded automatically. If you download only the `.ps1` file, the script falls back to 7 built-in rules that cover basic label shortening.

To customize, copy `rename_rules.json`, edit it, and either keep it next to the script (auto-loaded) or point to it with `-RulesFile`.

### 📋 Custom Renaming Rules

Create a JSON file with your own renaming rules:

```json
{
  "rules": [
    {
      "name": "Shorten Humidity Label",
      "pattern": "49-0-Humidity$",
      "replace": " - Humidity$",
      "with": " - RH%",
      "description": "Shortens humidity sensor label"
    }
  ]
}
```

Then use it:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" -RulesFile "my_rules.json"
```

### 🔧 Setting Device Types (v2.1+)

Rules can optionally set `switchType` and `customImage` to configure the correct Domoticz device type:

```json
{
  "rules": [
    {
      "name": "Smoke Alarm Sensor",
      "pattern": "113-\\d+-Smoke_Alarm-Sensor_status$",
      "replace": " - Sensor status$",
      "with": " - Smoke Alarm",
      "switchType": 5,
      "description": "Sets smoke sensor to Smoke Detector type with Reset button"
    },
    {
      "name": "Motion Sensor",
      "pattern": "113-\\d+-Home_Security-Motion_sensor_status$",
      "replace": " - Motion sensor status$",
      "with": " - Motion",
      "switchType": 8,
      "description": "Sets to Motion Sensor type"
    }
  ]
}
```

#### SwitchType Reference

| Value | Type | Use Case |
|-------|------|----------|
| 0 | On/Off | Standard switches |
| 2 | Contact | Alarm contacts (can't be UI-toggled) |
| 5 | Smoke Detector | Smoke/heat alarms (adds Reset button) |
| 7 | Dimmer | Dimmable lights |
| 8 | Motion Sensor | PIR motion sensors |
| 11 | Door Contact | Door/window sensors |
| 12 | Dusk Sensor | Light level sensors |

#### CustomImage Reference

You can also set `customImage` to change the device icon:

```json
{
  "name": "Overcurrent Status",
  "pattern": "113-\\d+-Power_Management-Over-current_status$",
  "replace": " - Over-current status$",
  "with": " - Overcurrent",
  "switchType": 2,
  "customImage": 13,
  "description": "Sets Contact type with Alarm icon"
}
```

Common built-in icons (values may vary by Domoticz version):
| Value | Icon |
|-------|------|
| 0 | Default for SwitchType |
| 9 | Fire |
| 13 | Alarm |

To find icon values in your Domoticz: query `SELECT DISTINCT CustomImage, Name FROM DeviceStatus WHERE CustomImage > 0;`

### 🚫 Device Exclusions

Exclude specific devices by ID:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" `
    -ExcludeDeviceIds @("zwavejs2mqtt_xxx_42-49-0-Air_temperature", "zwavejs2mqtt_xxx_50-1-value-66049")
```

Exclude devices matching a pattern:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" `
    -ExcludePattern "test_.*|debug_.*"
```

### ⚠️ Name Collision Detection

The script detects when a rename would collide with **any** device in the final state, including devices that keep their current name, not just clashes between two proposed renames. Collisions on different endpoints are auto-resolved by appending the endpoint number (e.g. ` - EP2`, ` - EP3`). Collisions on the same endpoint (or against a device that keeps its name) are reported and skipped, so the script never writes a duplicate name.

### ↩️ Undo Script Generation

An SQL undo script is automatically generated, allowing you to revert changes:

```bash
sqlite3 domoticz.db < undo_rename-25.01.30-14.30.45.sql
```

### 🌐 HTML Report

An interactive HTML report is now **generated by default** in the database folder. The report features:

- Expandable device cards with change details
- Search and filter functionality
- Color-coded badges for Name, SwitchType, and CustomImage changes
- Human-readable descriptions for switch types and icons

To specify a custom path:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" `
    -HtmlReport "D:\Reports\rename_report.html"
```

### 🔒 Database Usage Detection

Before making changes, the script checks whether another process (typically a running Domoticz) has the database open, and warns you with the process name. This check is **cross-platform**:

- **Linux** (incl. Raspberry Pi): scans `/proc` for a process holding the DB or its `-wal`/`-journal` files open (no extra tools needed).
- **Windows**: attempts an exclusive open.
- **macOS**: uses `lsof` when available.

It is best-effort, not a guarantee: SQLite locks are transient, and on Linux it can only see handles owned by processes visible to the current user. **Always stop Domoticz before applying changes** (see below).

### ⏱️ Progress Bar with ETA

Progress display now includes estimated time remaining.

### 📊 Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error |
| 2 | No changes needed |
| 3 | Partial success (some errors occurred) |
| 4 | User cancelled |

---

## 🗝️ Naming Scheme

Device names are constructed using:

```
[Room Name] - [Device Name] - [Property Label]
```

* `Room Name` → From `loc` in JSON.
* `Device Name` → From `name` in JSON.
* `Property Label` → From `label` in JSON.

### 🔄 Default Renaming Rules

| ID Pattern | Original Label | New Label |
|------------|----------------|-----------|
| `38-[01]-currentValue` | `Current Value` | *(removed)* |
| `37-[01]-currentValue` | `Current Value` | *(removed)* |
| `50-[01]-value-66049` | `Electric Consumption [W]` | `[W]` |
| `50-[01]-value-65537` | `Electric Consumption [kWh]` | `[kWh]` |
| `49-0-Air_temperature` | `Air temperature` | `Temp` |
| `49-0-Illuminance` | `Illuminance` | `Lux` |
| `113-0-Home_Security-Motion_sensor_status` | `Motion sensor status` | `Motion` |

### Special Behaviors

1. **Preserve `$` Prefix** — If the old name starts with `$`, the new name also starts with `$`.
2. **DeviceID Spaces → Underscores** — Domoticz replaces spaces with underscores in `DeviceID`.
3. **DeviceID Slashes → Hyphens** — Domoticz replaces forward slashes with hyphens in `DeviceID`.

---

## 📊 Output Files

### Console Output

```
╔═══════════════════════════════════════════╗
║              Summary                      ║
╠═══════════════════════════════════════════╣
║   Renamed:         75                     ║
║   TypeChanged:     23                     ║
║   ImageChanged:    18                     ║
║   Unchanged:       454                    ║
║   Excluded:        12                     ║
║   Collisions:      0                      ║
║   Errors:          0                      ║
╚═══════════════════════════════════════════╝

  Total time: 2.3s
  📄 Log:  C:\Domoticz\rename_log-25.01.30-14.30.45.txt
  ↩️  Undo: C:\Domoticz\undo_rename-25.01.30-14.30.45.sql
  🌐 HTML: C:\Domoticz\rename_report-25.01.30-14.30.45.html
```

### Log File

Detailed log with timestamps:

```
[2025-01-30 14:30:45] [INFO] SQLite engine initialised from ./lib
[2025-01-30 14:30:45] [SUCCESS] Connected to SQLite database: C:\Domoticz\domoticz.db
[2025-01-30 14:30:46] [SUCCESS] Loaded 529 DeviceStatus rows into memory
[2025-01-30 14:30:46] [INFO] Using Base Identifier: zwavejs2mqtt_XXXXXXXX
[2025-01-30 14:30:47] [INFO] RENAMING: zwavejs2mqtt_XXXXXXXX_42-49-0-Air_temperature | Old: 'Outdoor - Sensor - Air temperature' -> New: 'Outdoor - Sensor - Temp'
[2025-01-30 14:30:47] [SUCCESS] Updated zwavejs2mqtt_XXXXXXXX_42-49-0-Air_temperature to 'Outdoor - Sensor - Temp'
```

### CSV Summary (Optional)

Generated only when `-CsvFile` is specified. Includes devices that were actually renamed:

```csv
DeviceID,OldName,NewName
zwavejs2mqtt_XXXXXXXX_42-49-0-Air_temperature,"Outdoor - Sensor - Air temperature","Outdoor - Sensor - Temp"
zwavejs2mqtt_XXXXXXXX_50-1-value-66049,"Room B - Lamp - Electric Consumption [W]","Room B - Lamp [W]"
```

### Undo SQL Script

```sql
-- Undo script generated by Rename-Domoticz-From-ZwaveJSON.ps1
-- Generated: 2025-01-30 14:30:45
-- Database: C:\Domoticz\domoticz.db

BEGIN TRANSACTION;

UPDATE DeviceStatus SET Name = 'Outdoor - Sensor - Air temperature' WHERE DeviceID = 'zwavejs2mqtt_XXXXXXXX_42-49-0-Air_temperature';
UPDATE DeviceStatus SET Name = 'Room B - Lamp - Electric Consumption [W]' WHERE DeviceID = 'zwavejs2mqtt_XXXXXXXX_50-1-value-66049';

COMMIT;
```

---

## 🛠️ Database Backup

Before making changes, the script **creates a backup** of `domoticz.db`.

* Stored in the **same folder as the original DB**
* Filename format: `domoticz-yy.MM.dd-HH.mm.ss.db`
* Backup is verified (size check) after creation
* Use `-NoBackup` to skip (not recommended)

---

## ▶ Running the Script

### Basic Usage

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "C:\Domoticz\domoticz.db"
```

### Preview Changes First (Recommended)

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "C:\Domoticz\domoticz.db" -DryRun
```

### Full Example with All Options

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 `
    -JsonFile "D:\Export\nodes_dump.json" `
    -DbPath "D:\Domoticz\domoticz.db" `
    -LogFile "D:\Logs\rename_log.txt" `
    -RulesFile "D:\Config\custom_rules.json" `
    -CsvFile "D:\Reports\rename_summary.csv" `
    -ExcludePattern "test_.*" `
    -Force
```

### Automation / CI Usage

```powershell
# Returns exit code for automation
$result = .\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" -Force
exit $LASTEXITCODE
```

---

## 🔄 Reverting Changes

### Option 1: Restore Backup

```powershell
Copy-Item -Path "C:\Domoticz\domoticz-25.01.30-14.30.45.db" -Destination "C:\Domoticz\domoticz.db" -Force
```

### Option 2: Run Undo Script

```bash
sqlite3 C:\Domoticz\domoticz.db < C:\Domoticz\undo_rename-25.01.30-14.30.45.sql
```

---

## ❓ Troubleshooting

| Issue | Solution |
|-------|----------|
| **"SQLite engine unavailable"** | Run `pwsh ./setup.ps1` to download the SQLite assemblies into `lib/` |
| **"No native SQLite for '<rid>'"** | Your platform is not in the pinned native package; open an issue with the reported runtime identifier |
| **"Database is open by ..."** | Stop Domoticz before applying changes (it can overwrite renames from its in-memory cache); `-DryRun` is always safe |
| **"DeviceID not found"** | Check that JSON IDs match Domoticz DB IDs (spaces → underscores) |
| **"Base Identifier not found"** | Verify your JSON export has `identifiers` under `hassDevices` |
| **"Name collision detected"** | Multi-endpoint collisions are auto-resolved with endpoint numbers; unresolvable collisions are skipped |
| **Logs/CSV not where expected** | Check console output for actual paths; falls back: Script → DB → TEMP |

---

## 📁 File Structure

```
├── Rename-Domoticz-From-ZwaveJSON.ps1   # Main script
├── setup.ps1                             # One-time: fetch pinned SQLite assemblies into lib/
├── rename_rules.json                     # Extended renaming rules (auto-loaded when present)
├── README.md                             # This documentation
├── modules/DomoticzSqlite/               # SQLite data-access module (Microsoft.Data.Sqlite)
├── tests/                                # Pester tests (Invoke-Pester -Path ./tests)
├── lib/                                  # SQLite assemblies (git-ignored; created by setup.ps1)
│
├── Output files (auto-generated in DB folder):
│   ├── rename_log-<timestamp>.txt        # Detailed operation log
│   ├── rename_report-<timestamp>.html    # Interactive HTML report
│   ├── undo_rename-<timestamp>.sql       # SQL script to revert changes
│   └── domoticz-<timestamp>.db           # Database backup
│
├── Optional output (when -CsvFile specified):
│   └── rename_summary.csv                # CSV of renamed devices
```

---

## 🔧 Custom Rules JSON Schema

```json
{
  "rules": [
    {
      "name": "Rule display name",
      "pattern": "regex pattern to match DeviceID$",
      "replace": "regex pattern to match in device name$",
      "with": "replacement string",
      "nodeMatch": { "productLabel": "regex to match product label" },
      "description": "Optional description"
    }
  ]
}
```

### Rules Processing

1. Rules are processed in order; first matching rule wins.
2. If `nodeMatch` is specified, the rule only applies when **all** specified node properties match their regex patterns. Available properties: `productLabel`, `productDescription`, `manufacturer`. Rules without `nodeMatch` apply to all devices.
3. `pattern` is matched against the **DeviceID**.
4. `replace` is matched against the **device name**.
5. Use `\\[` and `\\]` to escape brackets in JSON.

### Endpoint Pattern Reference

Z-Wave devices use endpoints to distinguish channels. The endpoint number appears in the DeviceID (e.g., `37-0-currentValue`, `37-1-currentValue`, `37-2-currentValue`).

| Pattern | Matches | Use Case |
|---------|---------|----------|
| `[01]` | Endpoint 0 or 1 | Primary channel(s) only - **default** |
| `\\d+` | Any endpoint | All channels (may cause collisions on multi-channel devices) |
| `0` | Endpoint 0 only | Single-endpoint devices only |
| `1` | Endpoint 1 only | First channel of multi-endpoint devices |
| `[012]` | Endpoints 0, 1, or 2 | First three channels |

### Customization Examples

**Remove suffix from ALL endpoints** (use with caution - may cause name collisions):
```json
{
  "pattern": "37-\\d+-currentValue$",
  "replace": " - Current value$",
  "with": ""
}
```

**Remove suffix from endpoint 0 only**:
```json
{
  "pattern": "37-0-currentValue$",
  "replace": " - Current value$",
  "with": ""
}
```

**Scope a rule to a specific device type** (e.g., RGBW controller only):
```json
{
  "name": "RGBW Red Channel",
  "pattern": "38-2-currentValue$",
  "replace": " - Current value$",
  "with": " - Red",
  "nodeMatch": { "productLabel": "FGRGBW" },
  "description": "Only matches Fibaro RGBW controllers, not regular dimmers"
}
```

Without `nodeMatch`, this rule would match endpoint 2 on every device with CC38 (dimmers, blinds, etc.). The `nodeMatch` field restricts it to nodes whose `productLabel` matches the regex `FGRGBW`.

---

## 📜 Version History

| Version | Changes |
|---------|---------|
| 2.7 | **ARM / Raspberry Pi support**: replaced the PSSQLite module with Microsoft.Data.Sqlite + SQLitePCLRaw, provisioned by a new pinned, checksum-verified `setup.ps1` that selects the native SQLite for your platform (`linux-arm64`, `linux-arm`, `linux-x64`, `win-x64`, `osx-arm64`, ...). Extracted the data layer into a `DomoticzSqlite` module with Pester tests. **Cross-platform database-in-use detection** (Linux `/proc` scan, Windows exclusive-open, macOS `lsof`) replaces the previous Windows-only lock check and names the holding process. **Collision detection** now checks a proposed name against the full end state (including devices that keep their name), so it can no longer silently create a duplicate |
| 2.6 | **Node-scoped rules**: New optional `nodeMatch` field lets rules target specific device types by matching Z-Wave node properties (`productLabel`, `productDescription`, `manufacturer`). Added RGBW color channel rules for Fibaro FGRGBW-442 using `nodeMatch` to avoid affecting regular dimmers |
| 2.5 | **UX improvements**: Summary box fields now display in consistent order. Log file defaults to DB folder with timestamp (matching other output files). Malformed rules files now error instead of silently falling back to defaults. `rename_rules.json` is auto-loaded from script directory when present (29 rules vs 7 built-in). Exit code now considers TypeChanged/ImageChanged. Removed non-actionable "Missing" count from summary. Consolidated MISSING log entries into one summary line. Confirmation prompt now shows actual change counts after analysis |
| 2.4 | **Collision auto-resolution**: Multi-endpoint collisions are now resolved automatically by appending endpoint numbers (EP2, EP3, etc.) instead of being skipped. **Robustness fixes**: Cross-platform temp directory support (Linux/macOS), removed WhatIf parameter (use DryRun instead), early ExcludePattern regex validation, transaction failure reporting, explicit error handling on all database calls |
| 2.3 | **HTML report now default**: Interactive HTML report generated automatically in DB folder. **CSV now optional**: Only generated when `-CsvFile` is specified. **Improved HTML readability**: Device cards now show sensor type suffix (e.g., "› Heat Alarm") for easy identification; human-readable SwitchType/CustomImage descriptions; search and filter functionality |
| 2.2 | **ImageChanged tracking**: Now shows CustomImage changes separately in stats and reports |
| 2.1 | **SwitchType/CustomImage support**: Rules can now optionally set `switchType` and `customImage` to configure correct device types (e.g., Smoke Detector with Reset button, Motion Sensor, Door Contact) |
| 2.0 | Major rewrite: DryRun mode, external rules config, exclusions, collision detection, undo scripts, HTML reports, ETA progress, exit codes, database lock detection, backup verification |
| 1.7 | Atomic transactions, fallback paths, whitespace normalization |
| 1.0 | Initial release |

---

⚠️ **DISCLAIMER:** This script modifies your database. Use it at your own risk! Always keep a backup of your Domoticz database before running. 🚀
