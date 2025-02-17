# ⚠️ WARNING: USE AT YOUR OWN RISK

This script modifies the **Domoticz database** to rename devices based on a **Zwave JS JSON export**. Improper use may lead to data loss or unintended changes.

Before running the script:
1. **Backup your Domoticz database** – The script automatically creates a timestamped backup before making any changes.
2. **Review the renaming logic** – Ensure it aligns with your device naming conventions.
3. **Test in a safe environment** – If possible, test on a separate instance before running on your production setup.

## 📥 Requirements

- **PowerShell 7+**
- **PSSQLite Module** (Install with `Install-Module -Name PSSQLite`)
- **Zwave JS UI** with JSON export

## 🔄 How to Export the JSON from Zwave JS UI

1. Navigate to **Zwave JS UI**.
2. Open the **General Actions** menu.
3. Click **Dump → EXPORT** to download a full JSON export of all nodes.
4. Save the file for use with this script.

## ⚙️ Script Parameters

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db"
```

### Parameters:
- `-JsonFile` → Path to the exported JSON file from Zwave JS UI.
- `-DbPath` → Path to your **Domoticz database** (`domoticz.db`).
- `-LogFile` (optional) → Path to store debug logs (defaults to script directory).
- `-CsvFile` (optional) → Path to store renaming summary in CSV format.

## 🏗️ Naming Scheme

Device names are constructed using:
```
[Room Name] - [Device Name] - [Property Label]
```
- `Room Name` → Extracted from `loc` in JSON.
- `Device Name` → Extracted from `name` in JSON.
- `Property Label` → Extracted from `label` in JSON.

### 🔄 Renaming Rules
1. **Standard Naming:**
   - Example:
     - JSON: `{ "loc": "Room A", "name": "Light", "label": "Current Value" }`
     - New Name: **`Room A - Light - Current Value`**

2. **Remove "Current Value" from Specific IDs:**
   - If the device ID ends in `-currentValue`, remove "- Current value" from the name.
   - Example:
     - JSON: `{ "loc": "Room A", "name": "Ceiling Light", "label": "Current Value" }`
     - New Name: **`Room A - Ceiling Light`**

3. **Electric Consumption Formatting:**
   - `-50-1-value-66049` → `[W]`
   - `-50-1-value-65537` → `[kWh]`
   - Example:
     - JSON: `{ "loc": "Room B", "name": "Lamp", "label": "Electric Consumption [W]" }`
     - New Name: **`Room B - Lamp [W]`**

4. **Temperature & Light Sensors:**
   - `-49-0-Air_temperature` → Rename "Air temperature" → "Temp"
   - `-49-0-Illuminance` → Rename "Illuminance" → "Lux"
   - Example:
     - JSON: `{ "loc": "Outdoor", "name": "Sensor", "label": "Air temperature" }`
     - New Name: **`Outdoor - Sensor - Temp`**

5. **Motion Sensor Formatting:**
   - `-113-0-Home_Security-Motion_sensor_status` → Rename "Motion sensor status" → "Motion"
   - Example:
     - JSON: `{ "loc": "Outdoor", "name": "Sensor", "label": "Motion sensor status" }`
     - New Name: **`Outdoor - Sensor - Motion`**

6. **Preserve `$` Prefix in Old Names:**
   - If an existing name in the **Domoticz database** starts with `$`, ensure the new name **also starts with `$`**.
   - Example:
     - Old Name: `$Living Room - Lights`
     - New Name: `$Living Room - Lights - Brightness`

7. **Fix Spaces in DeviceID Lookups:**
   - Domoticz replaces spaces with underscores (`_`).
   - Example:
     - Looking up `zwavejs2mqtt_XXXXXXXX_42-49-0-Air temperature`
     - Search instead for: `zwavejs2mqtt_XXXXXXXX_42-49-0-Air_temperature`

## 📊 Output

### Logging
- The script logs all rename actions to a **log file** (default: `rename_log.txt`).
- The log contains:
  - Database connection details
  - Base identifier lookup
  - Rename actions (success/failure)

### CSV Report
- The script generates a **CSV file** with renamed devices.
- Example CSV format:

```
DeviceID,OldName,NewName
zwavejs2mqtt_XXXXXXXX_42-49-0-Air_temperature,"Outdoor - Sensor - Air temperature","Outdoor - Sensor - Temp"
zwavejs2mqtt_XXXXXXXX_50-1-value-66049,"Room B - Lamp - Electric Consumption [W]","Room B - Lamp [W]"
```

## 🛠️ Database Backup
- Before making changes, the script **creates a backup** of `domoticz.db`.
- Backup is stored in the **same folder as the original database** with a timestamp:
  - Example: `domoticz-2025.02.17-14.30.45.db`

## 🏁 Running the Script

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "C:\Domoticz\domoticz.db" -LogFile "C:\Logs\rename_log.txt" -CsvFile "C:\Reports\renaming_summary.csv"
```

## 🔄 Reverting Changes
If something goes wrong, you can **restore the backup** created by the script:
```powershell
Copy-Item -Path "C:\Domoticz\domoticz-2025.02.17-14.30.45.db" -Destination "C:\Domoticz\domoticz.db" -Force
```

## ❓ Troubleshooting
- **"PSSQLite module missing"** → Run `Install-Module -Name PSSQLite` in PowerShell.
- **"DeviceID not found"** → Check if spaces are replaced with underscores in the database.
- **"Base Identifier not found"** → Ensure your JSON export contains valid `identifiers` under `hassDevices`.

---

⚠️ **DISCLAIMER:** This script modifies your database. Use it at your own risk! Always keep a backup of your Domoticz database before running. 🚀

