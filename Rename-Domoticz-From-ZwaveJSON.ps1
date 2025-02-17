<#
.SYNOPSIS
    Renames Domoticz devices based on Zwave JSON data.

.DESCRIPTION
    Reads a JSON file containing Z-Wave device information, constructs a new name for each device based on location, device name, and label, and updates the name in a Domoticz SQLite database.
    A backup of the database is created before modifications.

.PARAMETER JsonFile
    Path to the JSON file containing Z-Wave data.

.PARAMETER DbPath
    Path to the Domoticz SQLite database.

.PARAMETER LogFile
    Path to save the rename log file.

.PARAMETER CsvFile
    Path to save the renaming summary in CSV format.

.EXAMPLE
    .\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "D:\nodes_dump.json" -DbPath "D:\domoticz.db" -LogFile "D:\rename_log.txt"

.NOTES
    Author: Rouzax
    Version: 1.3
    Requires: PowerShell 5.1+, PSSQLite module
#>

param (
    [string]$JsonFile,
    [string]$DbPath,
    [string]$LogFile = "$PSScriptRoot\rename_log.txt",
    [string]$CsvFile = "$PSScriptRoot\rename_summary.csv"
)

# Initialize debug log
$Script:DebugLog = @()

# Ensure PSSQLite module is installed
if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
    Write-Host "ERROR: PSSQLite module is missing! Install it with 'Install-Module -Name PSSQLite'" -ForegroundColor Red
    exit 1
}

# Create a backup of the database
$DbFolder = Split-Path -Parent $DbPath
$Timestamp = Get-Date -Format "yy.MM.dd-HH.mm.ss"
$BackupPath = "$DbFolder\domoticz-$Timestamp.db"

try {
    Copy-Item -Path $DbPath -Destination $BackupPath -ErrorAction Stop
    $Script:DebugLog += "Backup created: $BackupPath"
} catch {
    Write-Host "ERROR: Failed to create database backup!" -ForegroundColor Red
    exit 1
}

# Open SQLite database
$DbConn = New-SQLiteConnection -DataSource $DbPath
$Script:DebugLog += "Connected to SQLite database: $DbPath"

# Load JSON data
try {
    $ZwaveData = Get-Content $JsonFile | ConvertFrom-Json
} catch {
    Write-Host "ERROR: Failed to load JSON file: $JsonFile" -ForegroundColor Red
    exit 1
}

# Initialize Base Identifier
$BaseIdentifier = $null

# Loop through devices to find a valid identifier
foreach ($Device in $ZwaveData) {
    if ($Device.PSObject.Properties["hassDevices"]) {
        foreach ($HassDevice in $Device.hassDevices.PSObject.Properties.Value) {
            # Check if 'discovery_payload' exists and has a 'device' entry
            if ($HassDevice.PSObject.Properties["discovery_payload"] -and 
                $HassDevice.discovery_payload.PSObject.Properties["device"] -and 
                $HassDevice.discovery_payload.device.PSObject.Properties["identifiers"]) {

                $Identifiers = $HassDevice.discovery_payload.device.identifiers
                if ($Identifiers -is [System.Array] -and $Identifiers.Count -gt 0) {
                    # Extract identifier and clean up (remove _nodeX suffix)
                    $BaseIdentifier = $Identifiers[0] -replace "_node\d+$", ""
                    break
                }
            }
        }
    }
    if ($BaseIdentifier) { break }
}

if (-not $BaseIdentifier) {
    Write-Host "ERROR: Could not determine Base Identifier." -ForegroundColor Red
    exit 1
}

$Script:DebugLog += "Using Base Identifier: $BaseIdentifier"

# Function to apply renaming rules
function Apply-RenameRules {
    param (
        [string]$DeviceID,
        [string]$NewName
    )

    if ($DeviceID -match "38-1-currentValue$") {
        $NewName = $NewName -replace " - Current value$", ""
    }
    elseif ($DeviceID -match "37-0-currentValue$") {
        $NewName = $NewName -replace " - Current value$", ""
    }
    elseif ($DeviceID -match "50-[01]-value-66049$") {
        $NewName = $NewName -replace " - Electric Consumption \[W\]$", " [W]"
    }
    elseif ($DeviceID -match "50-[01]-value-65537$") {
        $NewName = $NewName -replace " - Electric Consumption \[kWh\]$", " [kWh]"
    }
    elseif ($DeviceID -match "49-0-Air_temperature$") {
        $NewName = $NewName -replace " - Air temperature$", " - Temp"
    }
    elseif ($DeviceID -match "49-0-Illuminance$") {
        $NewName = $NewName -replace " - Illuminance$", " - Lux"
    }
    elseif ($DeviceID -match "113-0-Home_Security-Motion_sensor_status$") {
        $NewName = $NewName -replace " - Motion sensor status$", " - Motion"
    }

    return $NewName
}

# Process devices
$RenameList = @()
foreach ($Device in $ZwaveData) {
    $Location = $Device.loc
    $DeviceName = $Device.name

    foreach ($Value in $Device.values) {
        $PropertyID = $Value.id
        $Label = $Value.label
        $DeviceID = "${BaseIdentifier}_${PropertyID}"

        # Format DeviceID for Domoticz (replace spaces with underscores)
        $DeviceID = $DeviceID -replace " ", "_"

        # Construct new name
        $NewName = "$Location - $DeviceName - $Label"
        $NewName = Apply-RenameRules -DeviceID $DeviceID -NewName $NewName

        # Check if this device exists in Domoticz
        $ExistingDevice = Invoke-SqliteQuery -Query "SELECT ID, Name FROM DeviceStatus WHERE DeviceID = @DeviceID" -SqliteConnection $DbConn -SqlParameters @{ DeviceID = $DeviceID }

        if ($ExistingDevice) {
            $OldName = $ExistingDevice.Name

            # Preserve "$" prefix if present in the old name
            if ($OldName -match "^\$") {
                if ($NewName -notmatch "^\$") {
                    $NewName = "`$" + $NewName
                }
            }

            $Script:DebugLog += "Renaming: $DeviceID | Old: '$OldName' -> New: '$NewName'"

            # Store rename for review
            $RenameList += [PSCustomObject]@{
                DeviceID = $DeviceID
                OldName  = $OldName
                NewName  = $NewName
            }

            # Update device name
            try {
                Invoke-SqliteQuery -Query "UPDATE DeviceStatus SET Name = @NewName WHERE DeviceID = @DeviceID" -SqliteConnection $DbConn -SqlParameters @{ NewName = $NewName; DeviceID = $DeviceID }
                $Script:DebugLog += "SUCCESS: Updated $DeviceID to '$NewName'"
            } catch {
                $Script:DebugLog += "ERROR: Failed to update $DeviceID to '$NewName' | $_"
            }
        } else {
            $Script:DebugLog += "WARNING: DeviceID not found: $DeviceID"
        }
    }
}

# Close SQLite connection
$DbConn.Close()
$Script:DebugLog += "SQLite connection closed."

# Write debug log to file
$Script:DebugLog | Out-File -FilePath $LogFile -Encoding utf8
Write-Host "Debug log saved to: $LogFile"

# Write renaming summary to CSV
if ($RenameList.Count -gt 0) {
    $RenameList | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8
    Write-Host "Renaming summary saved to: $CsvFile"
} else {
    Write-Host "No devices were renamed."
}

Write-Host "Device renaming complete!"