# ⚠️ WARNING: USE AT YOUR OWN RISK

This script modifies the **Domoticz database** to rename devices based on a **Z-Wave JS JSON export**. Improper use may lead to data loss or unintended changes.

Before running the script:

1. **Backup your Domoticz database** — The script automatically creates a timestamped backup before making any changes.
2. **Review the renaming logic** — Ensure it aligns with your device naming conventions.
3. **Test with DryRun first** — Use `-DryRun` to preview changes without modifying the database.

---

## 📥 Requirements

* **PowerShell 7.0+** (required for emoji support and System.Web.HttpUtility)
* **PSSQLite Module** (Install with `Install-Module -Name PSSQLite`)
* **Z-Wave JS UI** with JSON export

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
| `-LogFile` | Path to store the debug log | `<script folder>\rename_log.txt` |
| `-CsvFile` | Path to store the renaming summary CSV | `<script folder>\rename_summary.csv` |
| `-RulesFile` | Path to custom renaming rules JSON file | Built-in rules |
| `-HtmlReport` | Path to save an HTML report | None |
| `-UndoFile` | Path to save SQL undo script | `<db folder>\undo_rename-<timestamp>.sql` |
| `-ExcludeDeviceIds` | Array of DeviceIDs to exclude | None |
| `-ExcludePattern` | Regex pattern to exclude DeviceIDs | None |
| `-DryRun` | Preview changes without modifying database | `$false` |
| `-Force` | Skip confirmation prompts | `$false` |
| `-NoBackup` | Skip database backup (use with caution) | `$false` |

---

## 🆕 New Features in v2.0

### 🔍 DryRun / WhatIf Mode

Preview all changes without modifying the database:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" -DryRun
```

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

The script now detects when two different devices would end up with the same name and warns you before making changes. Collisions are skipped automatically.

### ↩️ Undo Script Generation

An SQL undo script is automatically generated, allowing you to revert changes:

```bash
sqlite3 domoticz.db < undo_rename-25.01.30-14.30.45.sql
```

### 🌐 HTML Report

Generate a visual HTML report:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" `
    -HtmlReport "rename_report.html"
```

### 🔒 Database Lock Detection

The script checks if the database is locked by another process (e.g., Domoticz) before making changes.

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

---

## 📊 Output Files

### Console Output

```
╔═══════════════════════════════════════════╗
║              Summary                      ║
╠═══════════════════════════════════════════╣
║   Renamed:         75                     ║
║   Unchanged:       454                    ║
║   Missing:         4113                   ║
║   Excluded:        12                     ║
║   Collisions:      0                      ║
║   Errors:          0                      ║
╚═══════════════════════════════════════════╝

  Total time: 2.3s
  📄 Log:  C:\TEMP\rename_log.txt
  📊 CSV:  C:\TEMP\rename_summary.csv
  ↩️  Undo: C:\TEMP\undo_rename-25.01.30-14.30.45.sql
```

### Log File

Detailed log with timestamps:

```
[2025-01-30 14:30:45] [INFO] PSSQLite module imported successfully
[2025-01-30 14:30:45] [SUCCESS] Connected to SQLite database: C:\Domoticz\domoticz.db
[2025-01-30 14:30:46] [SUCCESS] Loaded 529 DeviceStatus rows into memory
[2025-01-30 14:30:46] [INFO] Using Base Identifier: zwavejs2mqtt_XXXXXXXX
[2025-01-30 14:30:47] [INFO] RENAMING: zwavejs2mqtt_XXXXXXXX_42-49-0-Air_temperature | Old: 'Outdoor - Sensor - Air temperature' -> New: 'Outdoor - Sensor - Temp'
[2025-01-30 14:30:47] [SUCCESS] Updated zwavejs2mqtt_XXXXXXXX_42-49-0-Air_temperature to 'Outdoor - Sensor - Temp'
```

### CSV Summary

Only includes devices that were actually renamed:

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
    -CsvFile "D:\Reports\rename_summary.csv" `
    -RulesFile "D:\Config\custom_rules.json" `
    -HtmlReport "D:\Reports\rename_report.html" `
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
| **"PSSQLite module missing"** | Run: `Install-Module -Name PSSQLite -Scope CurrentUser` |
| **"Database is locked"** | Stop Domoticz before running, or use `-Force` to continue |
| **"DeviceID not found"** | Check that JSON IDs match Domoticz DB IDs (spaces → underscores) |
| **"Base Identifier not found"** | Verify your JSON export has `identifiers` under `hassDevices` |
| **"Name collision detected"** | Review the collision report; devices with conflicts are skipped |
| **Logs/CSV not where expected** | Check console output for actual paths; falls back: Script → DB → TEMP |

---

## 📁 File Structure

```
├── Rename-Domoticz-From-ZwaveJSON.ps1   # Main script
├── rename_rules.json                     # Optional: Custom renaming rules
├── README.md                             # This documentation
│
├── Output files (auto-generated):
│   ├── rename_log.txt                    # Detailed operation log
│   ├── rename_summary.csv                # CSV of renamed devices
│   ├── undo_rename-<timestamp>.sql       # SQL script to revert changes
│   ├── rename_report.html                # Visual HTML report
│   └── domoticz-<timestamp>.db           # Database backup
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
      "description": "Optional description"
    }
  ]
}
```

### Rules Processing

1. Rules are processed in order; first matching rule wins.
2. `pattern` is matched against the **DeviceID**.
3. `replace` is matched against the **device name**.
4. Use `\\[` and `\\]` to escape brackets in JSON.

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

---

## 📜 Version History

| Version | Changes |
|---------|---------|
| 2.0 | Major rewrite: DryRun mode, external rules config, exclusions, collision detection, undo scripts, HTML reports, ETA progress, exit codes, database lock detection, backup verification |
| 1.7 | Atomic transactions, fallback paths, whitespace normalization |
| 1.0 | Initial release |

---

⚠️ **DISCLAIMER:** This script modifies your database. Use it at your own risk! Always keep a backup of your Domoticz database before running. 🚀
