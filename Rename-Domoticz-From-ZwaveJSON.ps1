<#
.SYNOPSIS
    Renames Domoticz devices based on Z-Wave JSON data—skipping unchanged names.

.DESCRIPTION
    Reads a JSON file containing Z-Wave device information, constructs a new name
    for each device (Location - DeviceName - Label), and updates the name in a
    Domoticz SQLite database.

    Features:
      - Bulk-loads Domoticz DeviceStatus once for speed.
      - Performs all updates in a single transaction (atomic; rolls back on error).
      - Normalizes whitespace when comparing old vs new names.
      - Applies renaming rules to normalize common labels.
      - Preserves a leading "$" in existing Domoticz names.
      - Skips updates when the existing name already matches the new name.
      - Records only true renames in a CSV summary.
      - Logs detailed progress, shows progress bar, and prints a final summary.
      - If LogFile/CsvFile are not provided (or writing fails), falls back to the
        DB folder, and then to the system TEMP folder.

.PARAMETER JsonFile
    Path to the JSON file containing Z-Wave data.

.PARAMETER DbPath
    Path to the Domoticz SQLite database.

.PARAMETER LogFile
    Path to save the debug/rename log file.
    Default: <script folder>\rename_log.txt (falls back to <db folder>\rename_log.txt)

.PARAMETER CsvFile
    Path to save the renaming summary (only rows that actually changed).
    Default: <script folder>\rename_summary.csv (falls back to <db folder>\rename_summary.csv)

.EXAMPLE
    .\Rename-Domoticz-From-ZwaveJSON.ps1 `
        -JsonFile "D:\nodes_dump.json" `
        -DbPath   "D:\domoticz.db" `
        -LogFile  "D:\rename_log.txt"

.NOTES
    Author:  Rouzax
    Version: 1.7
    Requires: PowerShell 5.1+ and PSSQLite module
    Encoding: Save as UTF-8 (no BOM) if you prefer that style.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$JsonFile,

    [Parameter(Mandatory = $true)]
    [string]$DbPath,

    # Defaults point to script folder, but we’ll safely fall back to DB folder if needed.
    [string]$LogFile = "$PSScriptRoot\rename_log.txt",
    [string]$CsvFile = "$PSScriptRoot\rename_summary.csv"
)

# Initialize debug log
$Script:DebugLog = @()

# Simple counters for a quick summary at the end
$Stats = @{
    Renamed   = 0
    Unchanged = 0
    Missing   = 0
    Errors    = 0
}

# Ensure PSSQLite module is installed
if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
    Write-Host "ERROR: PSSQLite module is missing! Install it with:" -ForegroundColor Red
    Write-Host "       Install-Module -Name PSSQLite" -ForegroundColor Yellow
    exit 1
}

# Validate input files early
if (-not (Test-Path -LiteralPath $DbPath)) {
    Write-Host "ERROR: Database file not found: $DbPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $JsonFile)) {
    Write-Host "ERROR: JSON file not found: $JsonFile" -ForegroundColor Red
    exit 1
}

# Timestamps and handy paths
$DbFolder = Split-Path -Parent $DbPath
$Timestamp = Get-Date -Format "yy.MM.dd-HH.mm.ss"
$BackupPath = Join-Path $DbFolder "domoticz-$Timestamp.db"

# If the caller didn't pass Log/Csv paths (or $PSScriptRoot is empty), default beside the DB
$scriptRootEmpty = [string]::IsNullOrWhiteSpace($PSScriptRoot)
if (-not $PSBoundParameters.ContainsKey('LogFile') -or [string]::IsNullOrWhiteSpace($LogFile) -or $scriptRootEmpty) {
    $LogFile = Join-Path $DbFolder "rename_log.txt"
}
if (-not $PSBoundParameters.ContainsKey('CsvFile') -or [string]::IsNullOrWhiteSpace($CsvFile) -or $scriptRootEmpty) {
    $CsvFile = Join-Path $DbFolder "rename_summary.csv"
}

# Helper: ensure directory exists for a file path
function Ensure-ParentDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        } catch {
            throw "Failed to create directory '$dir'. $_"
        }
    }
}

# Helper: best-effort file write with simple fallbacks
function Write-SafeFile {
    param(
        [Parameter(Mandatory)][string]$PrimaryPath,
        [Parameter(Mandatory)][string]$FallbackDbPath,
        [Parameter(Mandatory)][string]$FallbackTempPath,
        [Parameter(Mandatory)][ScriptBlock]$Writer,  # must be: param([string]$Path) <body>
        [Parameter(Mandatory)][string]$What
    )

    foreach ($target in @($PrimaryPath, $FallbackDbPath, $FallbackTempPath)) {
        try {
            Ensure-ParentDirectory -Path $target
            & $Writer $target   # call like: { param([string]$Path) <write> } $target
            Write-Host "$What saved to: $target"
            return $target
        } catch {
            Write-Host "ERROR: Failed to write $($What): $target" -ForegroundColor Red
            Write-Host $_
        }
    }
    return $null
}

# Create a backup of the database
try {
    Copy-Item -Path $DbPath -Destination $BackupPath -ErrorAction Stop
    $Script:DebugLog += "Backup created: $BackupPath"
} catch {
    Write-Host "ERROR: Failed to create database backup! $_" -ForegroundColor Red
    exit 1
}

# Open SQLite database
$DbConn = $null
try {
    $DbConn = New-SQLiteConnection -DataSource $DbPath
    $Script:DebugLog += "Connected to SQLite database: $DbPath"
} catch {
    Write-Host "ERROR: Could not open SQLite database: $DbPath`n$_" -ForegroundColor Red
    exit 1
}

# Bulk-read DeviceStatus once for speed
$allDevices = @{}
try {
    $rows = Invoke-SqliteQuery -Query "SELECT DeviceID, Name FROM DeviceStatus" -SQLiteConnection $DbConn
    foreach ($r in $rows) {
        $allDevices[[string]$r.DeviceID] = [string]$r.Name 
    }
    $Script:DebugLog += "Loaded $($allDevices.Count) DeviceStatus rows into memory."
} catch {
    Write-Host "ERROR: Failed to load DeviceStatus table. $_" -ForegroundColor Red
    if ($DbConn) {
        try {
            $DbConn.Close() | Out-Null 
        } catch {
        } 
    }
    exit 1
}

# Load JSON data
try {
    $ZwaveData = Get-Content -LiteralPath $JsonFile -Raw | ConvertFrom-Json
    if (-not $ZwaveData) {
        throw "JSON parsed but returned no data."
    }
} catch {
    Write-Host "ERROR: Failed to load/parse JSON file: $JsonFile`n$_" -ForegroundColor Red
    if ($DbConn) {
        try {
            $DbConn.Close() | Out-Null 
        } catch {
        } 
    }
    exit 1
}

# Initialize Base Identifier
$BaseIdentifier = $null

# Loop through devices to find a valid identifier (strip trailing _nodeX)
foreach ($Device in $ZwaveData) {
    if ($Device.PSObject.Properties["hassDevices"]) {
        foreach ($HassDevice in $Device.hassDevices.PSObject.Properties.Value) {
            if ($HassDevice.PSObject.Properties["discovery_payload"] -and 
                $HassDevice.discovery_payload.PSObject.Properties["device"] -and 
                $HassDevice.discovery_payload.device.PSObject.Properties["identifiers"]) {

                $Identifiers = $HassDevice.discovery_payload.device.identifiers
                if ($Identifiers -is [System.Array] -and $Identifiers.Count -gt 0) {
                    $BaseIdentifier = $Identifiers[0] -replace "_node\d+$", ""
                    break
                }
            }
        }
    }
    if ($BaseIdentifier) {
        break 
    }
}

if (-not $BaseIdentifier) {
    Write-Host "ERROR: Could not determine Base Identifier from JSON (no device identifiers found)." -ForegroundColor Red
    if ($DbConn) {
        try {
            $DbConn.Close() | Out-Null 
        } catch {
        } 
    }
    exit 1
}

$Script:DebugLog += "Using Base Identifier: $BaseIdentifier"

# Function to apply renaming rules
function Apply-RenameRules {
    param (
        [Parameter(Mandatory = $true)][string]$DeviceID,
        [Parameter(Mandatory = $true)][string]$NewName
    )

    if ($DeviceID -match "38-1-currentValue$") {
        $NewName = $NewName -replace " - Current value$", "" 
    } elseif ($DeviceID -match "37-0-currentValue$") {
        $NewName = $NewName -replace " - Current value$", "" 
    } elseif ($DeviceID -match "50-[01]-value-66049$") {
        $NewName = $NewName -replace " - Electric Consumption \[W\]$", " [W]" 
    } elseif ($DeviceID -match "50-[01]-value-65537$") {
        $NewName = $NewName -replace " - Electric Consumption \[kWh\]$", " [kWh]" 
    } elseif ($DeviceID -match "49-0-Air_temperature$") {
        $NewName = $NewName -replace " - Air temperature$", " - Temp" 
    } elseif ($DeviceID -match "49-0-Illuminance$") {
        $NewName = $NewName -replace " - Illuminance$", " - Lux" 
    } elseif ($DeviceID -match "113-0-Home_Security-Motion_sensor_status$") {
        $NewName = $NewName -replace " - Motion sensor status$", " - Motion"
    }

    return $NewName
}

# Calculate total items for progress
$total = 0
foreach ($d in $ZwaveData) {
    if ($d.values) {
        $total += [int]$d.values.Count 
    } 
}
$idx = 0

# Process devices & perform updates inside a single transaction (atomic)
$RenameList = @()
$transactionBegun = $false
$anyUpdateError = $false

try {
    Invoke-SqliteQuery -Query "BEGIN IMMEDIATE TRANSACTION;" -SQLiteConnection $DbConn
    $transactionBegun = $true

    foreach ($Device in $ZwaveData) {
        # Defensive checks in case fields are missing
        $Location = if ($Device.PSObject.Properties["loc"]) {
            [string]$Device.loc 
        } else {
            "" 
        }
        $DeviceName = if ($Device.PSObject.Properties["name"]) {
            [string]$Device.name 
        } else {
            "" 
        }

        if (-not $Device.PSObject.Properties["values"]) {
            continue 
        }

        foreach ($Value in $Device.values) {
            $idx++
            if ($idx -and $total -gt 0 -and ($idx % 50 -eq 0 -or $idx -eq $total)) {
                $pct = [math]::Round(($idx / $total) * 100, 2)
                Write-Progress -Activity "Renaming devices" -Status "$idx / $total processed" -PercentComplete $pct
            }

            if (-not $Value) {
                continue 
            }
            if (-not $Value.PSObject.Properties["id"]) {
                continue 
            }
            if (-not $Value.PSObject.Properties["label"]) {
                continue 
            }

            $PropertyID = [string]$Value.id
            $Label = [string]$Value.label

            # Compose Domoticz DeviceID as seen in DB (strip spaces -> underscores)
            $DeviceID = "${BaseIdentifier}_${PropertyID}" -replace " ", "_"

            # Build candidate new name from non-empty parts
            $parts = @($Location, $DeviceName, $Label) | Where-Object { $_ -and $_.Trim() -ne "" }
            $NewName = ($parts -join " - ").Trim()
            $NewName = $NewName -replace '\s{2,}', ' '
            $NewName = Apply-RenameRules -DeviceID $DeviceID -NewName $NewName

            # Current name from bulk-loaded dictionary
            $OldName = $allDevices[$DeviceID]
            if ($null -eq $OldName) {
                $Script:DebugLog += "WARNING: DeviceID not found in Domoticz: $DeviceID"
                $Stats.Missing++
                continue
            }

            # Preserve "$" prefix if present in the old name
            if ($OldName -match '^\$' -and $NewName -notmatch '^\$') {
                $NewName = "`$" + $NewName
            }

            # Normalize whitespace for comparison
            $OldNameNorm = ($OldName -replace '\s{2,}', ' ').Trim()
            $NewNameNorm = ($NewName -replace '\s{2,}', ' ').Trim()

            if ($OldNameNorm -eq $NewNameNorm) {
                # No change — skip update
                $Script:DebugLog += "UNCHANGED: $DeviceID | Name remains '$OldNameNorm'"
                $Stats.Unchanged++
                continue
            }

            $Script:DebugLog += "RENAMING: $DeviceID | Old: '$OldName' -> New: '$NewName'"

            # Store only real renames for the CSV
            $RenameList += [PSCustomObject]@{
                DeviceID = $DeviceID
                OldName  = $OldName
                NewName  = $NewName
            }

            # Update device name ONLY if different (extra safety in SQL)
            try {
                Invoke-SqliteQuery -Query @"
UPDATE DeviceStatus
SET Name = @NewName
WHERE DeviceID = @DeviceID AND Name <> @NewName
"@ -SQLiteConnection $DbConn -SqlParameters @{ NewName = $NewName; DeviceID = $DeviceID }

                # Reflect change in memory to keep consistency if seen again
                $allDevices[$DeviceID] = $NewName

                $Script:DebugLog += "SUCCESS: Updated $DeviceID to '$NewName'"
                $Stats.Renamed++
            } catch {
                $Script:DebugLog += "ERROR: Failed to update $DeviceID to '$NewName' | $_"
                $Stats.Errors++
                $anyUpdateError = $true
                throw  # abort entire transaction to keep atomicity
            }
        }
    }

    if (-not $anyUpdateError) {
        Invoke-SqliteQuery -Query "COMMIT;" -SQLiteConnection $DbConn
        $Script:DebugLog += "Transaction committed."
    }
} catch {
    if ($transactionBegun) {
        try {
            Invoke-SqliteQuery -Query "ROLLBACK;" -SQLiteConnection $DbConn
            $Script:DebugLog += "Transaction rolled back due to error."
        } catch {
            $Script:DebugLog += "WARNING: ROLLBACK failed: $_"
        }
    }
    # Already logged inner errors; add a top-level marker
    $Script:DebugLog += "ERROR: Transaction failed. No changes were committed."
} finally {
    # Close connection regardless
    if ($DbConn) {
        try {
            $DbConn.Close() | Out-Null 
        } catch {
            $Script:DebugLog += "WARNING: Failed to close SQLite connection cleanly. $_" 
        }
        $Script:DebugLog += "SQLite connection closed."
    }
    # Complete the progress bar
    Write-Progress -Activity "Renaming devices" -Completed
}

# Write summary line
$Script:DebugLog += "Summary: Renamed=$($Stats.Renamed); Unchanged=$($Stats.Unchanged); Missing=$($Stats.Missing); Errors=$($Stats.Errors)"

# === Write outputs with safe fallbacks (Primary -> DB folder -> TEMP) ===

$LogPrimary = $LogFile
$LogDbFallback = Join-Path $DbFolder ("rename_log-{0}.txt" -f $Timestamp)
$LogTempFallback = Join-Path $env:TEMP ("rename_log-{0}.txt" -f $Timestamp)

$CsvPrimary = $CsvFile
$CsvDbFallback = Join-Path $DbFolder ("rename_summary-{0}.csv" -f $Timestamp)
$CsvTempFallback = Join-Path $env:TEMP ("rename_summary-{0}.csv" -f $Timestamp)

# 1) Debug log
$finalLogPath = Write-SafeFile -PrimaryPath $LogPrimary -FallbackDbPath $LogDbFallback -FallbackTempPath $LogTempFallback -What "Debug log" -Writer {
    param([string]$Path)
    $Script:DebugLog | Out-File -FilePath $Path -Encoding utf8
}

# 2) Renaming summary to CSV (only if any changes were made)
$finalCsvPath = $null
if ($RenameList.Count -gt 0) {
    $finalCsvPath = Write-SafeFile -PrimaryPath $CsvPrimary -FallbackDbPath $CsvDbFallback -FallbackTempPath $CsvTempFallback -What "Renaming summary" -Writer {
        param([string]$Path)
        $RenameList | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    }
} else {
    Write-Host "No devices were renamed (all unchanged or missing)."
}

# Final report to console
Write-Host ("`nSummary: Renamed={0}; Unchanged={1}; Missing={2}; Errors={3}" -f $Stats.Renamed, $Stats.Unchanged, $Stats.Missing, $Stats.Errors)
if ($finalLogPath) {
    Write-Host "Log: $finalLogPath" 
}
if ($finalCsvPath) {
    Write-Host "CSV: $finalCsvPath" 
}

Write-Host "Device renaming complete!"
