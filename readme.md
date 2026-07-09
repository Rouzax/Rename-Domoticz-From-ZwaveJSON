# Domoticz Device Renamer for Z-Wave JS

Automatically rename your Domoticz devices based on the room and device names configured in Z-Wave JS UI.

**The problem:** When Z-Wave JS creates devices in Domoticz via MQTT Auto-Discovery, they get generic names like `zwavejs2mqtt_0xc15d8aa6_42-49-0-Air_temperature`. Finding the right device becomes a nightmare.

**The solution:** This script reads your Z-Wave JS node data, either from a JSON export or directly from a running zwave-js-ui instance, and renames devices to friendly names like `Living Room - Motion Sensor - Motion`, matching your Z-Wave JS configuration. It can also fix device types (so smoke detectors get a Reset button, motion sensors show the right icon, etc.).

<img width="987" height="830" alt="image" src="https://github.com/user-attachments/assets/5cba8a2c-f18f-4c16-8404-54a58ab996e0" />

---

## 🚀 Quick Start

1. **Run setup once per machine** to download the required SQLite assemblies:

   ```powershell
   pwsh ./setup.ps1
   ```

2. **Preview the changes** without touching the database:

   ```powershell
   .\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" -DryRun
   ```

3. **Review the HTML report**, then apply the changes for real:

   ```powershell
   .\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db"
   ```

---

## ⚠️ Important: Use with Care

This script modifies the **Domoticz database** directly. While it includes safety features, improper use may lead to unintended changes.

**Before running:**

1. **Stop Domoticz before applying changes:** Domoticz caches device rows in memory and periodically writes them back, so it can overwrite your renames while it runs, and new names only appear after a restart anyway. `-DryRun` is safe to run at any time. The script warns you (cross-platform) if the database is still in use, but you should stop Domoticz regardless.
2. **Test with `-DryRun` first:** Preview changes without modifying anything
3. **Let it create a backup:** The script automatically backs up your database
4. **Review the HTML report:** Check the changes look correct before running live

---

## 📥 Requirements

* **PowerShell 7.0+** (required for emoji support and System.Web.HttpUtility)
* **SQLite assemblies** provisioned by `setup.ps1` (see below). No system SQLite or PSSQLite module is needed.
* **Z-Wave JS UI**, with either a JSON export or a live instance the script can read from directly (see below); a manual export is no longer required
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

## 🔌 Read Directly from zwave-js-ui (no manual export)

Instead of exporting `nodes_dump.json`, point the script at your running
zwave-js-ui instance. It reads the same node data live over zwave-js-ui's
socket.io API (read-only; nothing in zwave-js-ui is modified):

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "https://your-host:8091" -DbPath "domoticz.db" -DryRun
```

- Default zwave-js-ui port is `8091`.
- **Authentication:** if your instance requires login, pass `-ZwaveJsToken`.
  The token is a credential. Over `http://` it is sent in cleartext, which is
  normally fine on a trusted LAN (or localhost); the script allows it but prints
  a warning. Prefer `https://` if the traffic could be observed. Pass the token
  via an environment variable, not inline, to keep it out of shell history and
  the process argument list, e.g.:

  ```powershell
  .\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://your-host:8091" -ZwaveJsToken $env:ZWAVEJS_TOKEN -DbPath "domoticz.db" -DryRun
  ```

  Obtain a token by logging into zwave-js-ui and copying its JWT. The script
  never logs or stores the token.
- **Self-signed HTTPS:** add `-SkipCertificateCheck`. Avoid combining it with a
  token (an unverified server can intercept the token); prefer a trusted cert.
- Requires Hass/MQTT discovery to be enabled in zwave-js-ui (it is, if Domoticz
  received these devices via MQTT auto-discovery), because the base device
  identifier comes from the discovery payload.

---

## ⚙️ Script Parameters

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db"
```

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `-JsonFile` | Path to the exported JSON file from Z-Wave JS UI (one of `-JsonFile` or `-ZwaveJsUrl` required) |
| `-ZwaveJsUrl` | Base URL of a running zwave-js-ui instance (e.g. `https://host:8091`). Alternative to `-JsonFile` (one of `-JsonFile` or `-ZwaveJsUrl` required) |
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
| `-ZwaveJsToken` | Auth token, only if your zwave-js-ui has authentication enabled. Over `http://` it is sent in cleartext (allowed, with a warning); prefer `https://` on untrusted networks | None |
| `-SkipCertificateCheck` | Skip TLS validation for a self-signed https zwave-js-ui | `$false` |

---

## Features

### 🔍 DryRun Mode

Preview all changes without modifying the database. See Quick Start above for an example.

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

An interactive HTML report is generated by default in the database folder. The report features:

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

It is best-effort, not a guarantee: SQLite locks are transient, and on Linux it can only see handles owned by processes visible to the current user. **Always stop Domoticz before applying changes** (see above).

### ⏱️ Progress Bar with ETA

Progress display includes estimated time remaining.

### 📊 Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error |
| 2 | No changes needed |
| 3 | Partial success (some errors occurred) |
| 4 | User cancelled |

---

## 🗝️ Renaming Rules

### Naming Scheme

Device names are constructed using:

```
[Room Name] - [Device Name] - [Property Label]
```

* `Room Name` → From `loc` in JSON.
* `Device Name` → From `name` in JSON.
* `Property Label` → From `label` in JSON.

#### Default Renaming Rules

| ID Pattern | Original Label | New Label |
|------------|----------------|-----------|
| `38-[01]-currentValue` | `Current Value` | *(removed)* |
| `37-[01]-currentValue` | `Current Value` | *(removed)* |
| `50-[01]-value-66049` | `Electric Consumption [W]` | `[W]` |
| `50-[01]-value-65537` | `Electric Consumption [kWh]` | `[kWh]` |
| `49-0-Air_temperature` | `Air temperature` | `Temp` |
| `49-0-Illuminance` | `Illuminance` | `Lux` |
| `113-0-Home_Security-Motion_sensor_status` | `Motion sensor status` | `Motion` |

#### Special Behaviors

1. **Preserve `$` Prefix:** If the old name starts with `$`, the new name also starts with `$`.
2. **DeviceID Spaces → Underscores:** Domoticz replaces spaces with underscores in `DeviceID`.
3. **DeviceID Slashes → Hyphens:** Domoticz replaces forward slashes with hyphens in `DeviceID`.

### Bundled and Custom Rules

The repository includes a `rename_rules.json` with 38 rules covering common Z-Wave device types (smoke detectors, motion sensors, door contacts, battery alerts, etc.), including `switchType` and `customImage` settings.

When you run the script from the repository directory and don't specify `-RulesFile`, this file is loaded automatically. If you download only the `.ps1` file, the script falls back to a small set of built-in rules that cover basic label shortening.

To customize, copy `rename_rules.json`, edit it, and either keep it next to the script (auto-loaded) or point to it with `-RulesFile`:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" -RulesFile "my_rules.json"
```

### Rule JSON Schema

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

### How Rules Work

1. Rules are processed in order; the first matching rule wins.
2. `pattern` is matched against the **DeviceID**.
3. `replace` is matched against the **device name**; the matched text is replaced with `with`.
4. `nodeMatch` (optional) is an object of regex patterns matched against Z-Wave node properties: `productLabel`, `productDescription`, `manufacturer`. **All** specified properties must match for the rule to apply. Rules without `nodeMatch` apply to all devices.
5. `switchType` (optional) sets the Domoticz SwitchType (see reference table below).
6. `customImage` (optional) sets the Domoticz CustomImage icon (see reference table below).
7. Use `\\[` and `\\]` to escape brackets in JSON.

Example rules that set `switchType` to configure the correct Domoticz device type:

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
| **"DeviceID not found"** | Check that JSON IDs match Domoticz DB IDs (spaces → underscores). In live mode (`-ZwaveJsUrl`), this usually means Hass/MQTT discovery is not enabled in zwave-js-ui |
| **"Base Identifier not found"** | Verify your JSON export has `identifiers` under `hassDevices`. In live mode (`-ZwaveJsUrl`), this means Hass/MQTT discovery must be enabled in zwave-js-ui, since the base identifier comes from the discovery payload |
| **"Name collision detected"** | Multi-endpoint collisions are auto-resolved with endpoint numbers; unresolvable collisions are skipped |
| **Logs/CSV not where expected** | Check console output for actual paths; falls back: Script → DB → TEMP |

---

## 📁 File Structure

```
├── Rename-Domoticz-From-ZwaveJSON.ps1   # Main script
├── setup.ps1                             # One-time: fetch pinned SQLite assemblies into lib/
├── rename_rules.json                     # Extended renaming rules (auto-loaded when present)
├── readme.md                              # This documentation
├── CHANGELOG.md                          # Version history
├── modules/DomoticzSqlite/               # SQLite data-access module (Microsoft.Data.Sqlite)
├── modules/ZwaveJsClient/                # Live zwave-js-ui reader (socket.io / engine.io v4)
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

## 📜 Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full version history, or the
[GitHub Releases page](https://github.com/Rouzax/Rename-Domoticz-From-ZwaveJSON/releases)
for release notes.

---

⚠️ **DISCLAIMER:** This script modifies your database. Use it at your own risk! Always keep a backup of your Domoticz database before running. 🚀
