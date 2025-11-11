# ⚠️ WARNING: USE AT YOUR OWN RISK

This script modifies the **Domoticz database** to rename devices based on a **Z-Wave JS JSON export**. Improper use may lead to data loss or unintended changes.

Before running the script:

1. **Backup your Domoticz database** – The script automatically creates a timestamped backup before making any changes.
2. **Review the renaming logic** – Ensure it aligns with your device naming conventions.
3. **Test in a safe environment** – If possible, test on a separate instance before running on your production setup.

---

## 📥 Requirements

* **PowerShell 5.1+**
* **PSSQLite Module** (Install with `Install-Module -Name PSSQLite`)
* **Z-Wave JS UI** with JSON export

---

## 🔄 How to Export the JSON from Z-Wave JS UI

1. Open **Z-Wave JS UI**.
2. Go to **General Actions**.
3. Choose **Dump → EXPORT** to download a full JSON export of all nodes.
4. Save the file for use with this script.

---

## ⚙️ Script Parameters

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db"
```

### Parameters

* `-JsonFile` → Path to the exported JSON file from Z-Wave JS UI. **(Required)**
* `-DbPath` → Path to your **Domoticz database** (`domoticz.db`). **(Required)**
* `-LogFile` (optional) → Path to store the debug log.
  Default: script folder `\rename_log.txt`, else **DB folder** if script folder isn’t available; on failure the script falls back to **system TEMP**.
* `-CsvFile` (optional) → Path to store the **renaming summary (only actual changes)**.
  Default: script folder `\rename_summary.csv`, else **DB folder** if script folder isn’t available; on failure the script falls back to **system TEMP**.

---

## 🏗️ Naming Scheme

Device names are constructed using:

```
[Room Name] - [Device Name] - [Property Label]
```

* `Room Name` → From `loc` in JSON.
* `Device Name` → From `name` in JSON.
* `Property Label` → From `label` in JSON.

### 🔄 Renaming Rules

1. **Standard Naming Example**

   ```json
   { "loc": "Room A", "name": "Light", "label": "Current Value" }
   ```

   → **`Room A - Light - Current Value`**

2. **Remove “Current Value” for specific IDs**

   * IDs ending in `38-1-currentValue` or `37-0-currentValue`

   ```json
   { "loc": "Room A", "name": "Ceiling Light", "label": "Current Value" }
   ```

   → **`Room A - Ceiling Light`**

3. **Electric Consumption Formatting**

   * `-50-1-value-66049` → `[W]`
   * `-50-1-value-65537` → `[kWh]`

   ```json
   { "loc": "Room B", "name": "Lamp", "label": "Electric Consumption [W]" }
   ```

   → **`Room B - Lamp [W]`**

4. **Temperature & Light Sensors**

   * `-49-0-Air_temperature` → “Air temperature” → “Temp”
   * `-49-0-Illuminance` → “Illuminance” → “Lux”

   ```json
   { "loc": "Outdoor", "name": "Sensor", "label": "Air temperature" }
   ```

   → **`Outdoor - Sensor - Temp`**

5. **Motion Sensor Formatting**

   * `-113-0-Home_Security-Motion_sensor_status` → “Motion sensor status” → “Motion”

   ```json
   { "loc": "Outdoor", "name": "Sensor", "label": "Motion sensor status" }
   ```

   → **`Outdoor - Sensor - Motion`**

6. **Preserve `$` Prefix**
   If the old name in Domoticz starts with `$`, the new name **also** starts with `$`.
   Example:

   * Old: `$Living Room - Lights`
   * New: `$Living Room - Lights - Brightness`

7. **DeviceID Spaces → Underscores**
   Domoticz replaces spaces with underscores in `DeviceID`.
   Example:

   * JSON: `zwavejs2mqtt_XXXXXXXX_42-49-0-Air temperature`
   * DB:   `zwavejs2mqtt_XXXXXXXX_42-49-0-Air_temperature`

---

## 📊 Output

### Console

* Progress bar during processing.
* Final summary with counts and paths:

```
Summary: Renamed=75; Unchanged=454; Missing=4113; Errors=0
Log: C:\TEMP\rename_log.txt
CSV: C:\TEMP\rename_summary.csv
```

### Logging

* The script logs all rename actions to a **log file** (default: `rename_log.txt`).
* The log includes:

  * Database backup location
  * Database connection info
  * Base identifier used
  * UNCHANGED / Renaming / SUCCESS / ERROR lines
  * Transaction commit/rollback details
  * Final counts

### CSV Report

* Generated **only if devices were actually renamed**.
* CSV format:

```csv
DeviceID,OldName,NewName
zwavejs2mqtt_XXXXXXXX_42-49-0-Air_temperature,"Outdoor - Sensor - Air temperature","Outdoor - Sensor - Temp"
zwavejs2mqtt_XXXXXXXX_50-1-value-66049,"Room B - Lamp - Electric Consumption [W]","Room B - Lamp [W]"
```

---

## 🛠️ Database Backup

Before making changes, the script **creates a backup** of `domoticz.db`.

* Stored in the **same folder as the original DB**
* Filename format:

  ```
  domoticz-yy.MM.dd-HH.mm.ss.db
  ```

---

## 🏁 Running the Script

Basic run:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "C:\Domoticz\domoticz.db"
```

With custom output locations:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 `
  -JsonFile "nodes_dump.json" `
  -DbPath   "C:\Domoticz\domoticz.db" `
  -LogFile  "C:\Logs\rename_log.txt" `
  -CsvFile  "C:\Reports\renaming_summary.csv"
```

---

## 🔄 Reverting Changes

If something goes wrong, restore the backup created by the script:

```powershell
Copy-Item -Path "C:\Domoticz\domoticz-25.09.29-14.30.45.db" -Destination "C:\Domoticz\domoticz.db" -Force
```

---

## ❓ Troubleshooting

* **“PSSQLite module missing”** → Run:

  ```powershell
  Install-Module -Name PSSQLite -Scope CurrentUser
  ```
* **“DeviceID not found”** → Check that JSON IDs match Domoticz DB IDs (spaces replaced with underscores).
* **“Base Identifier not found”** → Verify your JSON export has `identifiers` under `hassDevices`.
* **Logs/CSV not where expected** → The script auto-falls back: Script folder → DB folder → `%TEMP%`.
  See the console summary for actual paths.

---

⚠️ **DISCLAIMER:** This script modifies your database. Use it at your own risk! Always keep a backup of your Domoticz database before running. 🚀
