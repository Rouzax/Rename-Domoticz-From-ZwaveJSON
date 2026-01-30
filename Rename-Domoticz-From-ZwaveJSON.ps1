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
      - Applies renaming rules to normalize common labels (configurable via JSON).
      - Preserves a leading "$" in existing Domoticz names.
      - Skips updates when the existing name already matches the new name.
      - Records only true renames in a CSV summary.
      - Logs detailed progress, shows progress bar with ETA, and prints a final summary.
      - Supports WhatIf/DryRun mode for previewing changes without modifying the database.
      - Detects name collisions before applying changes.
      - Generates undo SQL scripts for easy rollback.
      - Optionally generates HTML reports for easier review.
      - Supports device exclusion by ID or pattern.
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

.PARAMETER RulesFile
    Path to an optional JSON file containing custom renaming rules.
    If not provided, uses built-in default rules.

.PARAMETER HtmlReport
    Path to save an optional HTML report with visual summary.

.PARAMETER UndoFile
    Path to save the SQL undo script. Default: auto-generated in DB folder.

.PARAMETER ExcludeDeviceIds
    Array of DeviceIDs to exclude from renaming.

.PARAMETER ExcludePattern
    Regex pattern to exclude DeviceIDs matching this pattern.

.PARAMETER DryRun
    Preview changes without modifying the database. Alias: -WhatIf

.PARAMETER Force
    Skip confirmation prompt before making changes.

.PARAMETER NoBackup
    Skip database backup (use with caution).

.EXAMPLE
    .\Rename-Domoticz-From-ZwaveJSON.ps1 `
        -JsonFile "D:\nodes_dump.json" `
        -DbPath   "D:\domoticz.db"

.EXAMPLE
    .\Rename-Domoticz-From-ZwaveJSON.ps1 `
        -JsonFile "D:\nodes_dump.json" `
        -DbPath   "D:\domoticz.db" `
        -DryRun

.EXAMPLE
    .\Rename-Domoticz-From-ZwaveJSON.ps1 `
        -JsonFile "D:\nodes_dump.json" `
        -DbPath   "D:\domoticz.db" `
        -RulesFile "D:\custom_rules.json" `
        -HtmlReport "D:\report.html" `
        -ExcludePattern "test_.*"

.NOTES
    Author:  Rouzax
    Version: 2.0
    Requires: PowerShell 7.0+ and PSSQLite module
    Encoding: Save as UTF-8 (no BOM) if you prefer that style.
#>

#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = "Path to the Z-Wave JSON export file")]
    [ValidateNotNullOrEmpty()]
    [string]$JsonFile,

    [Parameter(Mandatory = $true, Position = 1, HelpMessage = "Path to the Domoticz SQLite database")]
    [ValidateNotNullOrEmpty()]
    [string]$DbPath,

    [Parameter(HelpMessage = "Path to save the debug log file")]
    [string]$LogFile,

    [Parameter(HelpMessage = "Path to save the renaming summary CSV")]
    [string]$CsvFile,

    [Parameter(HelpMessage = "Path to custom renaming rules JSON file")]
    [string]$RulesFile,

    [Parameter(HelpMessage = "Path to save HTML report")]
    [string]$HtmlReport,

    [Parameter(HelpMessage = "Path to save SQL undo script")]
    [string]$UndoFile,

    [Parameter(HelpMessage = "DeviceIDs to exclude from renaming")]
    [string[]]$ExcludeDeviceIds = @(),

    [Parameter(HelpMessage = "Regex pattern to exclude DeviceIDs")]
    [string]$ExcludePattern,

    [Parameter(HelpMessage = "Preview changes without modifying the database")]
    [switch]$DryRun,

    [Parameter(HelpMessage = "Skip confirmation prompt")]
    [switch]$Force,

    [Parameter(HelpMessage = "Skip database backup")]
    [switch]$NoBackup
)

# Enable strict mode for better error detection
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Exit Codes
$Script:ExitCodes = @{
    Success        = 0
    Error          = 1
    NoChanges      = 2
    PartialSuccess = 3
    UserCancelled  = 4
}
#endregion

#region Initialize Collections (Using List<T> for performance)
$Script:DebugLog = [System.Collections.Generic.List[string]]::new()
$Script:RenameList = [System.Collections.Generic.List[PSCustomObject]]::new()
$Script:UndoStatements = [System.Collections.Generic.List[string]]::new()
$Script:NameCollisions = [System.Collections.Generic.List[PSCustomObject]]::new()

# Statistics tracking
$Script:Stats = @{
    Renamed   = 0
    Unchanged = 0
    Missing   = 0
    Errors    = 0
    Excluded  = 0
    Collisions = 0
}

# Timing for ETA calculation
$Script:Stopwatch = $null
#endregion

#region Helper Functions

function Write-Log {
    <#
    .SYNOPSIS
        Adds a message to the debug log with timestamp.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    $Script:DebugLog.Add($logEntry)

    # Also write verbose output for real-time monitoring
    switch ($Level) {
        'ERROR'   { Write-Verbose $logEntry }
        'WARNING' { Write-Verbose $logEntry }
        'SUCCESS' { Write-Verbose $logEntry }
        default   { Write-Verbose $logEntry }
    }
}

function Test-DatabaseLocked {
    <#
    .SYNOPSIS
        Checks if the SQLite database is locked by another process.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        # Try to open with exclusive access
        $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $stream.Close()
        $stream.Dispose()
        return $false
    }
    catch [System.IO.IOException] {
        return $true
    }
    catch {
        # Other errors - assume not locked but log warning
        Write-Log "Could not determine lock status: $_" -Level WARNING
        return $false
    }
}

function New-ParentDirectoryIfMissing {
    <#
    .SYNOPSIS
        Ensures the parent directory exists for a given file path.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Log "Created directory: $dir" -Level DEBUG
        }
        catch {
            throw "Failed to create directory '$dir': $_"
        }
    }
}

function Write-SafeFile {
    <#
    .SYNOPSIS
        Writes content to file with fallback locations.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$PrimaryPath,

        [Parameter(Mandatory)]
        [string]$FallbackDbPath,

        [Parameter(Mandatory)]
        [string]$FallbackTempPath,

        [Parameter(Mandatory)]
        [scriptblock]$Writer,

        [Parameter(Mandatory)]
        [string]$Description
    )

    foreach ($target in @($PrimaryPath, $FallbackDbPath, $FallbackTempPath)) {
        if ([string]::IsNullOrWhiteSpace($target)) { continue }

        try {
            New-ParentDirectoryIfMissing -Path $target
            & $Writer $target
            Write-Host "$Description saved to: " -NoNewline
            Write-Host $target -ForegroundColor Cyan
            return $target
        }
        catch {
            Write-Log "Failed to write $Description to '$target': $_" -Level WARNING
        }
    }

    Write-Host "ERROR: Could not save $Description to any location" -ForegroundColor Red
    return $null
}

function Get-DefaultRenamingRules {
    <#
    .SYNOPSIS
        Returns the default renaming rules as a PowerShell object.
    #>
    return @(
        @{
            Name        = "Remove Current Value for Switch Multilevel"
            Pattern     = "38-[01]-currentValue$"
            Replace     = " - Current value$"
            With        = ""
            Description = "Removes 'Current Value' suffix for dimmer/multilevel switch devices (endpoint 0 or 1)"
        },
        @{
            Name        = "Remove Current Value for Switch Binary"
            Pattern     = "37-[01]-currentValue$"
            Replace     = " - Current value$"
            With        = ""
            Description = "Removes 'Current Value' suffix for binary switch devices (endpoint 0 or 1)"
        },
        @{
            Name        = "Electric Consumption Watts"
            Pattern     = "50-[01]-value-66049$"
            Replace     = " - Electric Consumption \[W\]$"
            With        = " [W]"
            Description = "Shortens wattage consumption label"
        },
        @{
            Name        = "Electric Consumption kWh"
            Pattern     = "50-[01]-value-65537$"
            Replace     = " - Electric Consumption \[kWh\]$"
            With        = " [kWh]"
            Description = "Shortens kilowatt-hour consumption label"
        },
        @{
            Name        = "Air Temperature"
            Pattern     = "49-0-Air_temperature$"
            Replace     = " - Air temperature$"
            With        = " - Temp"
            Description = "Shortens temperature sensor label"
        },
        @{
            Name        = "Illuminance"
            Pattern     = "49-0-Illuminance$"
            Replace     = " - Illuminance$"
            With        = " - Lux"
            Description = "Shortens light sensor label"
        },
        @{
            Name        = "Motion Sensor"
            Pattern     = "113-0-Home_Security-Motion_sensor_status$"
            Replace     = " - Motion sensor status$"
            With        = " - Motion"
            Description = "Shortens motion sensor label"
        }
    )
}

function Import-RenamingRules {
    <#
    .SYNOPSIS
        Loads renaming rules from a JSON file or returns defaults.
    #>
    [CmdletBinding()]
    param (
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Log "Using default renaming rules" -Level INFO
        return Get-DefaultRenamingRules
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Rules file not found: $Path - using defaults" -Level WARNING
        return Get-DefaultRenamingRules
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $rules = @()

        foreach ($rule in $content.rules) {
            $rules += @{
                Name        = $rule.name
                Pattern     = $rule.pattern
                Replace     = $rule.replace
                With        = $rule.with
                Description = $rule.description
            }
        }

        Write-Log "Loaded $($rules.Count) custom renaming rules from: $Path" -Level INFO
        return $rules
    }
    catch {
        Write-Log "Failed to parse rules file: $_ - using defaults" -Level WARNING
        return Get-DefaultRenamingRules
    }
}

function Get-TransformedDeviceName {
    <#
    .SYNOPSIS
        Applies renaming rules to transform a device name.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$DeviceID,

        [Parameter(Mandatory)]
        [string]$NewName,

        [Parameter(Mandatory)]
        [array]$Rules
    )

    foreach ($rule in $Rules) {
        if ($DeviceID -match $rule.Pattern) {
            $transformed = $NewName -replace $rule.Replace, $rule.With
            if ($transformed -ne $NewName) {
                Write-Log "Applied rule '$($rule.Name)' to $DeviceID" -Level DEBUG
            }
            return $transformed
        }
    }

    return $NewName
}

function Test-DeviceExcluded {
    <#
    .SYNOPSIS
        Checks if a device should be excluded from renaming.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$DeviceID,

        [Parameter()]
        [string[]]$ExcludeIds,

        [Parameter()]
        [string]$ExcludePattern
    )

    # Check explicit exclusion list
    if ($ExcludeIds -contains $DeviceID) {
        return $true
    }

    # Check pattern exclusion
    if (-not [string]::IsNullOrWhiteSpace($ExcludePattern)) {
        if ($DeviceID -match $ExcludePattern) {
            return $true
        }
    }

    return $false
}

function Format-Duration {
    <#
    .SYNOPSIS
        Formats a TimeSpan as a human-readable string.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [TimeSpan]$Duration
    )

    if ($Duration.TotalHours -ge 1) {
        return "{0:0}h {1:0}m {2:0}s" -f $Duration.Hours, $Duration.Minutes, $Duration.Seconds
    }
    elseif ($Duration.TotalMinutes -ge 1) {
        return "{0:0}m {1:0}s" -f $Duration.Minutes, $Duration.Seconds
    }
    else {
        return "{0:0.0}s" -f $Duration.TotalSeconds
    }
}

function Write-ProgressWithEta {
    <#
    .SYNOPSIS
        Writes progress with estimated time remaining.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [int]$Current,

        [Parameter(Mandatory)]
        [int]$Total,

        [Parameter(Mandatory)]
        [System.Diagnostics.Stopwatch]$Stopwatch,

        [Parameter()]
        [string]$Activity = "Processing"
    )

    if ($Total -le 0) { return }

    $percent = [math]::Round(($Current / $Total) * 100, 1)
    $elapsed = $Stopwatch.Elapsed

    $eta = "Calculating..."
    if ($Current -gt 0 -and $elapsed.TotalSeconds -gt 0) {
        $rate = $Current / $elapsed.TotalSeconds
        $remaining = ($Total - $Current) / $rate
        $eta = Format-Duration -Duration ([TimeSpan]::FromSeconds($remaining))
    }

    $status = "$Current / $Total ($percent%) - ETA: $eta"
    Write-Progress -Activity $Activity -Status $status -PercentComplete $percent
}

function ConvertTo-SqlLiteral {
    <#
    .SYNOPSIS
        Escapes a string for use in SQL statements.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Value
    )

    return "'" + ($Value -replace "'", "''") + "'"
}

function Write-ColoredBox {
    <#
    .SYNOPSIS
        Writes a colored box with title and content to the console.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [hashtable]$Content,

        [Parameter()]
        [ConsoleColor]$BorderColor = 'Cyan',

        [Parameter()]
        [int]$Width = 45
    )

    $innerWidth = $Width - 4

    # Top border
    Write-Host ("╔" + ("═" * ($Width - 2)) + "╗") -ForegroundColor $BorderColor

    # Title
    $titlePadded = $Title.PadLeft([math]::Floor(($innerWidth + $Title.Length) / 2)).PadRight($innerWidth)
    Write-Host "║ " -NoNewline -ForegroundColor $BorderColor
    Write-Host $titlePadded -NoNewline -ForegroundColor White
    Write-Host " ║" -ForegroundColor $BorderColor

    # Separator
    Write-Host ("╠" + ("═" * ($Width - 2)) + "╣") -ForegroundColor $BorderColor

    # Content
    foreach ($key in $Content.Keys) {
        $value = $Content[$key]
        $line = "  {0,-15} {1}" -f "${key}:", $value
        $linePadded = $line.PadRight($innerWidth)
        if ($linePadded.Length -gt $innerWidth) {
            $linePadded = $linePadded.Substring(0, $innerWidth)
        }

        Write-Host "║ " -NoNewline -ForegroundColor $BorderColor

        # Color code based on key
        $valueColor = switch -Regex ($key) {
            'Renamed'   { 'Green' }
            'Unchanged' { 'Yellow' }
            'Missing'   { 'DarkGray' }
            'Errors'    { if ($value -gt 0) { 'Red' } else { 'Green' } }
            'Excluded'  { 'DarkYellow' }
            'Collisions' { if ($value -gt 0) { 'Red' } else { 'Green' } }
            default     { 'White' }
        }

        Write-Host $linePadded -NoNewline -ForegroundColor $valueColor
        Write-Host " ║" -ForegroundColor $BorderColor
    }

    # Bottom border
    Write-Host ("╚" + ("═" * ($Width - 2)) + "╝") -ForegroundColor $BorderColor
}

function New-HtmlReport {
    <#
    .SYNOPSIS
        Generates an HTML report of the renaming operation.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [hashtable]$Stats,

        [Parameter()]
        [System.Collections.Generic.List[PSCustomObject]]$RenameList,

        [Parameter()]
        [System.Collections.Generic.List[PSCustomObject]]$Collisions,

        [Parameter()]
        [string]$BackupPath,

        [Parameter()]
        [bool]$WasDryRun
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $mode = if ($WasDryRun) { "DRY RUN (No changes made)" } else { "LIVE" }
    $modeClass = if ($WasDryRun) { "warning" } else { "success" }

    $renameTableRows = ""
    if ($RenameList -and $RenameList.Count -gt 0) {
        foreach ($item in $RenameList) {
            $renameTableRows += @"
            <tr>
                <td><code>$([System.Web.HttpUtility]::HtmlEncode($item.DeviceID))</code></td>
                <td>$([System.Web.HttpUtility]::HtmlEncode($item.OldName))</td>
                <td>$([System.Web.HttpUtility]::HtmlEncode($item.NewName))</td>
            </tr>
"@
        }
    }
    else {
        $renameTableRows = "<tr><td colspan='3' class='no-data'>No devices were renamed</td></tr>"
    }

    $collisionSection = ""
    if ($Collisions -and $Collisions.Count -gt 0) {
        $collisionRows = ""
        foreach ($collision in $Collisions) {
            $collisionRows += @"
            <tr>
                <td>$([System.Web.HttpUtility]::HtmlEncode($collision.NewName))</td>
                <td><code>$([System.Web.HttpUtility]::HtmlEncode($collision.DeviceID1))</code></td>
                <td><code>$([System.Web.HttpUtility]::HtmlEncode($collision.DeviceID2))</code></td>
            </tr>
"@
        }

        $collisionSection = @"
        <h2>⚠️ Name Collisions Detected</h2>
        <table>
            <thead>
                <tr>
                    <th>New Name</th>
                    <th>Device ID 1</th>
                    <th>Device ID 2</th>
                </tr>
            </thead>
            <tbody>
                $collisionRows
            </tbody>
        </table>
"@
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Domoticz Device Rename Report</title>
    <style>
        :root {
            --bg-primary: #1a1a2e;
            --bg-secondary: #16213e;
            --bg-card: #0f3460;
            --text-primary: #eaeaea;
            --text-secondary: #a0a0a0;
            --accent: #e94560;
            --success: #4ecca3;
            --warning: #ffc107;
            --error: #dc3545;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Segoe UI', system-ui, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
            padding: 2rem;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 {
            color: var(--accent);
            margin-bottom: 0.5rem;
            font-size: 2rem;
        }
        h2 {
            color: var(--text-primary);
            margin: 2rem 0 1rem;
            padding-bottom: 0.5rem;
            border-bottom: 2px solid var(--accent);
        }
        .meta {
            color: var(--text-secondary);
            margin-bottom: 2rem;
        }
        .mode-badge {
            display: inline-block;
            padding: 0.25rem 0.75rem;
            border-radius: 4px;
            font-weight: bold;
            margin-left: 1rem;
        }
        .mode-badge.warning { background: var(--warning); color: #000; }
        .mode-badge.success { background: var(--success); color: #000; }
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 1rem;
            margin-bottom: 2rem;
        }
        .stat-card {
            background: var(--bg-card);
            padding: 1.5rem;
            border-radius: 8px;
            text-align: center;
        }
        .stat-card .value {
            font-size: 2.5rem;
            font-weight: bold;
        }
        .stat-card .label {
            color: var(--text-secondary);
            text-transform: uppercase;
            font-size: 0.8rem;
            letter-spacing: 1px;
        }
        .stat-card.renamed .value { color: var(--success); }
        .stat-card.unchanged .value { color: var(--warning); }
        .stat-card.missing .value { color: var(--text-secondary); }
        .stat-card.errors .value { color: var(--error); }
        .stat-card.excluded .value { color: #9b59b6; }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-bottom: 2rem;
            background: var(--bg-secondary);
            border-radius: 8px;
            overflow: hidden;
        }
        th, td {
            padding: 0.75rem 1rem;
            text-align: left;
            border-bottom: 1px solid var(--bg-card);
        }
        th {
            background: var(--bg-card);
            font-weight: 600;
            text-transform: uppercase;
            font-size: 0.8rem;
            letter-spacing: 1px;
        }
        tr:hover { background: rgba(233, 69, 96, 0.1); }
        code {
            background: var(--bg-card);
            padding: 0.2rem 0.4rem;
            border-radius: 4px;
            font-size: 0.9em;
        }
        .no-data {
            text-align: center;
            color: var(--text-secondary);
            font-style: italic;
        }
        .backup-info {
            background: var(--bg-card);
            padding: 1rem;
            border-radius: 8px;
            margin-bottom: 2rem;
        }
        .backup-info code {
            color: var(--success);
        }
        footer {
            margin-top: 3rem;
            padding-top: 1rem;
            border-top: 1px solid var(--bg-card);
            color: var(--text-secondary);
            font-size: 0.9rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🏠 Domoticz Device Rename Report</h1>
        <p class="meta">
            Generated: $timestamp
            <span class="mode-badge $modeClass">$mode</span>
        </p>

        $(if ($BackupPath) { @"
        <div class="backup-info">
            📁 <strong>Backup:</strong> <code>$BackupPath</code>
        </div>
"@ })

        <div class="stats-grid">
            <div class="stat-card renamed">
                <div class="value">$($Stats.Renamed)</div>
                <div class="label">Renamed</div>
            </div>
            <div class="stat-card unchanged">
                <div class="value">$($Stats.Unchanged)</div>
                <div class="label">Unchanged</div>
            </div>
            <div class="stat-card missing">
                <div class="value">$($Stats.Missing)</div>
                <div class="label">Missing</div>
            </div>
            <div class="stat-card excluded">
                <div class="value">$($Stats.Excluded)</div>
                <div class="label">Excluded</div>
            </div>
            <div class="stat-card errors">
                <div class="value">$($Stats.Errors)</div>
                <div class="label">Errors</div>
            </div>
        </div>

        $collisionSection

        <h2>📝 Renamed Devices</h2>
        <table>
            <thead>
                <tr>
                    <th>Device ID</th>
                    <th>Old Name</th>
                    <th>New Name</th>
                </tr>
            </thead>
            <tbody>
                $renameTableRows
            </tbody>
        </table>

        <footer>
            Generated by Rename-Domoticz-From-ZwaveJSON.ps1 v2.0
        </footer>
    </div>
</body>
</html>
"@

    $html | Out-File -FilePath $OutputPath -Encoding utf8
}

#endregion

#region Main Script

# Start timing
$Script:Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Domoticz Device Renamer from Z-Wave JSON Export v2.0     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "  ⚠️  DRY RUN MODE - No changes will be made to the database" -ForegroundColor Yellow
    Write-Host ""
}

# Ensure PSSQLite module is available
Write-Host "  Checking prerequisites..." -ForegroundColor Gray

$psSqliteModule = Get-Module -ListAvailable -Name PSSQLite
if (-not $psSqliteModule) {
    Write-Host "  ❌ ERROR: PSSQLite module is missing!" -ForegroundColor Red
    Write-Host "     Install it with: " -NoNewline
    Write-Host "Install-Module -Name PSSQLite" -ForegroundColor Yellow
    exit $Script:ExitCodes.Error
}

try {
    Import-Module PSSQLite -ErrorAction Stop
    Write-Log "PSSQLite module imported successfully (version: $($psSqliteModule.Version))" -Level INFO
    Write-Host "  ✓ PSSQLite module loaded" -ForegroundColor Green
}
catch {
    Write-Host "  ❌ ERROR: Failed to import PSSQLite module: $_" -ForegroundColor Red
    exit $Script:ExitCodes.Error
}

# Validate input files
if (-not (Test-Path -LiteralPath $DbPath)) {
    Write-Host "  ❌ ERROR: Database file not found: $DbPath" -ForegroundColor Red
    exit $Script:ExitCodes.Error
}
Write-Host "  ✓ Database file found" -ForegroundColor Green

if (-not (Test-Path -LiteralPath $JsonFile)) {
    Write-Host "  ❌ ERROR: JSON file not found: $JsonFile" -ForegroundColor Red
    exit $Script:ExitCodes.Error
}
Write-Host "  ✓ JSON file found" -ForegroundColor Green

# Check if database is locked
Write-Host "  Checking database lock status..." -ForegroundColor Gray
if (Test-DatabaseLocked -Path $DbPath) {
    Write-Host "  ⚠️  WARNING: Database appears to be locked by another process!" -ForegroundColor Yellow
    Write-Host "     Please ensure Domoticz is stopped or not actively writing to the database." -ForegroundColor Yellow

    if (-not $Force -and -not $DryRun) {
        $response = Read-Host "     Continue anyway? (y/N)"
        if ($response -notmatch '^[Yy]') {
            Write-Host "  Operation cancelled by user." -ForegroundColor Yellow
            exit $Script:ExitCodes.UserCancelled
        }
    }
}
else {
    Write-Host "  ✓ Database is not locked" -ForegroundColor Green
}

# Setup paths
$DbFolder = Split-Path -Parent $DbPath
$Timestamp = Get-Date -Format "yy.MM.dd-HH.mm.ss"
$BackupPath = Join-Path $DbFolder "domoticz-$Timestamp.db"

# Set default paths if not provided
$scriptRootEmpty = [string]::IsNullOrWhiteSpace($PSScriptRoot)
$defaultFolder = if ($scriptRootEmpty) { $DbFolder } else { $PSScriptRoot }

if (-not $PSBoundParameters.ContainsKey('LogFile') -or [string]::IsNullOrWhiteSpace($LogFile)) {
    $LogFile = Join-Path $defaultFolder "rename_log.txt"
}
if (-not $PSBoundParameters.ContainsKey('CsvFile') -or [string]::IsNullOrWhiteSpace($CsvFile)) {
    $CsvFile = Join-Path $defaultFolder "rename_summary.csv"
}
if (-not $PSBoundParameters.ContainsKey('UndoFile') -or [string]::IsNullOrWhiteSpace($UndoFile)) {
    $UndoFile = Join-Path $DbFolder "undo_rename-$Timestamp.sql"
}

Write-Host ""

# Load renaming rules
$RenamingRules = Import-RenamingRules -Path $RulesFile
Write-Host "  ✓ Loaded $($RenamingRules.Count) renaming rules" -ForegroundColor Green

# Create backup (unless skipped or dry run)
if (-not $DryRun -and -not $NoBackup) {
    Write-Host "  Creating database backup..." -ForegroundColor Gray
    try {
        Copy-Item -Path $DbPath -Destination $BackupPath -ErrorAction Stop

        # Verify backup
        $backupSize = (Get-Item $BackupPath).Length
        $originalSize = (Get-Item $DbPath).Length

        if ($backupSize -eq 0) {
            throw "Backup file is empty!"
        }

        if ($backupSize -ne $originalSize) {
            Write-Log "Backup size ($backupSize) differs from original ($originalSize) - may indicate issue" -Level WARNING
        }

        Write-Log "Backup created: $BackupPath (Size: $backupSize bytes)" -Level SUCCESS
        Write-Host "  ✓ Backup created: " -NoNewline -ForegroundColor Green
        Write-Host $BackupPath -ForegroundColor Cyan
    }
    catch {
        Write-Host "  ❌ ERROR: Failed to create database backup: $_" -ForegroundColor Red
        exit $Script:ExitCodes.Error
    }
}
elseif ($DryRun) {
    Write-Host "  ⏭️  Skipping backup (dry run mode)" -ForegroundColor Gray
    $BackupPath = $null
}
else {
    Write-Host "  ⏭️  Skipping backup (--NoBackup specified)" -ForegroundColor Yellow
    $BackupPath = $null
}

# Open database connection
$DbConn = $null
try {
    $DbConn = New-SQLiteConnection -DataSource $DbPath
    Write-Log "Connected to SQLite database: $DbPath" -Level SUCCESS
    Write-Host "  ✓ Database connection established" -ForegroundColor Green
}
catch {
    Write-Host "  ❌ ERROR: Could not open SQLite database: $_" -ForegroundColor Red
    exit $Script:ExitCodes.Error
}

# Bulk-read DeviceStatus
$allDevices = @{}
try {
    Write-Host "  Loading device data from database..." -ForegroundColor Gray
    $rows = Invoke-SqliteQuery -Query "SELECT DeviceID, Name FROM DeviceStatus" -SQLiteConnection $DbConn
    foreach ($r in $rows) {
        $allDevices[[string]$r.DeviceID] = [string]$r.Name
    }
    Write-Log "Loaded $($allDevices.Count) DeviceStatus rows into memory" -Level SUCCESS
    Write-Host "  ✓ Loaded $($allDevices.Count) devices from database" -ForegroundColor Green
}
catch {
    Write-Host "  ❌ ERROR: Failed to load DeviceStatus table: $_" -ForegroundColor Red
    if ($DbConn) {
        try { $DbConn.Close() } catch { Write-Log "Failed to close connection: $_" -Level WARNING }
    }
    exit $Script:ExitCodes.Error
}

# Load JSON data
$ZwaveData = $null
try {
    Write-Host "  Parsing JSON file..." -ForegroundColor Gray
    $ZwaveData = Get-Content -LiteralPath $JsonFile -Raw | ConvertFrom-Json
    if (-not $ZwaveData) {
        throw "JSON parsed but returned no data"
    }
    Write-Log "JSON file loaded successfully" -Level SUCCESS
    Write-Host "  ✓ JSON parsed successfully ($($ZwaveData.Count) nodes)" -ForegroundColor Green
}
catch {
    Write-Host "  ❌ ERROR: Failed to load/parse JSON file: $_" -ForegroundColor Red
    if ($DbConn) {
        try { $DbConn.Close() } catch { Write-Log "Failed to close connection: $_" -Level WARNING }
    }
    exit $Script:ExitCodes.Error
}

# Find Base Identifier
$BaseIdentifier = $null
foreach ($Device in $ZwaveData) {
    if ($Device.PSObject.Properties["hassDevices"] -and $null -ne $Device.hassDevices) {
        foreach ($HassDeviceProp in $Device.hassDevices.PSObject.Properties) {
            $HassDevice = $HassDeviceProp.Value
            if ($null -eq $HassDevice) { continue }
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
    if ($BaseIdentifier) { break }
}

if (-not $BaseIdentifier) {
    Write-Host "  ❌ ERROR: Could not determine Base Identifier from JSON" -ForegroundColor Red
    if ($DbConn) {
        try { $DbConn.Close() } catch { Write-Log "Failed to close connection: $_" -Level WARNING }
    }
    exit $Script:ExitCodes.Error
}

Write-Log "Using Base Identifier: $BaseIdentifier" -Level INFO
Write-Host "  ✓ Base Identifier: " -NoNewline -ForegroundColor Green
Write-Host $BaseIdentifier -ForegroundColor Cyan

Write-Host ""

# Calculate total items for progress
$total = 0
foreach ($d in $ZwaveData) {
    if ($d.values) {
        $total += [int]$d.values.Count
    }
}

# Confirmation prompt (unless Force or DryRun)
if (-not $Force -and -not $DryRun) {
    Write-Host "  Ready to process $total value entries from $($ZwaveData.Count) Z-Wave nodes." -ForegroundColor White
    Write-Host "  This will modify your Domoticz database." -ForegroundColor Yellow
    Write-Host ""
    $response = Read-Host "  Proceed with renaming? (y/N)"
    if ($response -notmatch '^[Yy]') {
        Write-Host "  Operation cancelled by user." -ForegroundColor Yellow
        if ($DbConn) {
            try { $DbConn.Close() } catch { }
        }
        exit $Script:ExitCodes.UserCancelled
    }
    Write-Host ""
}

# Track proposed names for collision detection
$proposedNames = @{}

# First pass: collect all proposed renames and detect collisions
Write-Host "  Phase 1: Analyzing proposed changes..." -ForegroundColor Cyan
$idx = 0
$processingStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($Device in $ZwaveData) {
    $Location = if ($Device.PSObject.Properties["loc"]) { [string]$Device.loc } else { "" }
    $DeviceName = if ($Device.PSObject.Properties["name"]) { [string]$Device.name } else { "" }

    if (-not $Device.PSObject.Properties["values"]) { continue }

    foreach ($Value in $Device.values) {
        $idx++

        if ($idx % 100 -eq 0 -or $idx -eq $total) {
            Write-ProgressWithEta -Current $idx -Total $total -Stopwatch $processingStopwatch -Activity "Analyzing devices"
        }

        if (-not $Value) { continue }
        if (-not $Value.PSObject.Properties["id"]) { continue }
        if (-not $Value.PSObject.Properties["label"]) { continue }

        $PropertyID = [string]$Value.id
        $Label = [string]$Value.label
        $DeviceID = "${BaseIdentifier}_${PropertyID}" -replace " ", "_"

        # Check exclusions
        if (Test-DeviceExcluded -DeviceID $DeviceID -ExcludeIds $ExcludeDeviceIds -ExcludePattern $ExcludePattern) {
            Write-Log "EXCLUDED: $DeviceID (matched exclusion rule)" -Level DEBUG
            $Script:Stats.Excluded++
            continue
        }

        # Build new name
        $parts = @($Location, $DeviceName, $Label) | Where-Object { $_ -and $_.Trim() -ne "" }
        $NewName = ($parts -join " - ").Trim()
        $NewName = $NewName -replace '\s{2,}', ' '
        $NewName = Get-TransformedDeviceName -DeviceID $DeviceID -NewName $NewName -Rules $RenamingRules

        # Check if device exists
        $OldName = $allDevices[$DeviceID]
        if ($null -eq $OldName) {
            Write-Log "MISSING: DeviceID not found in Domoticz: $DeviceID" -Level DEBUG
            $Script:Stats.Missing++
            continue
        }

        # Preserve "$" prefix
        if ($OldName -match '^\$' -and $NewName -notmatch '^\$') {
            $NewName = "`$" + $NewName
        }

        # Normalize for comparison
        $OldNameNorm = ($OldName -replace '\s{2,}', ' ').Trim()
        $NewNameNorm = ($NewName -replace '\s{2,}', ' ').Trim()

        if ($OldNameNorm -eq $NewNameNorm) {
            Write-Log "UNCHANGED: $DeviceID | Name remains '$OldNameNorm'" -Level DEBUG
            $Script:Stats.Unchanged++
            continue
        }

        # Check for name collision
        if ($proposedNames.ContainsKey($NewNameNorm)) {
            $existingDeviceId = $proposedNames[$NewNameNorm]
            $Script:NameCollisions.Add([PSCustomObject]@{
                NewName   = $NewNameNorm
                DeviceID1 = $existingDeviceId
                DeviceID2 = $DeviceID
            })
            $Script:Stats.Collisions++
            Write-Log "COLLISION: '$NewNameNorm' would be assigned to both $existingDeviceId and $DeviceID" -Level WARNING
        }
        else {
            $proposedNames[$NewNameNorm] = $DeviceID
        }

        # Add to rename list
        $Script:RenameList.Add([PSCustomObject]@{
            DeviceID = $DeviceID
            OldName  = $OldName
            NewName  = $NewName
        })

        # Generate undo statement
        $escapedOldName = ConvertTo-SqlLiteral -Value $OldName
        $escapedDeviceId = ConvertTo-SqlLiteral -Value $DeviceID
        $Script:UndoStatements.Add("UPDATE DeviceStatus SET Name = $escapedOldName WHERE DeviceID = $escapedDeviceId;")
    }
}

Write-Progress -Activity "Analyzing devices" -Completed
$processingStopwatch.Stop()

Write-Host "  ✓ Analysis complete in $(Format-Duration $processingStopwatch.Elapsed)" -ForegroundColor Green
Write-Host ""

# Report collisions
if ($Script:NameCollisions.Count -gt 0) {
    Write-Host "  ⚠️  WARNING: $($Script:NameCollisions.Count) name collision(s) detected!" -ForegroundColor Red
    Write-Host "     The following names would be assigned to multiple devices:" -ForegroundColor Yellow

    foreach ($collision in $Script:NameCollisions | Select-Object -First 5) {
        Write-Host "       - '$($collision.NewName)'" -ForegroundColor Yellow
        Write-Host "         → $($collision.DeviceID1)" -ForegroundColor Gray
        Write-Host "         → $($collision.DeviceID2)" -ForegroundColor Gray
    }

    if ($Script:NameCollisions.Count -gt 5) {
        Write-Host "       ... and $($Script:NameCollisions.Count - 5) more" -ForegroundColor Gray
    }

    Write-Host ""

    if (-not $Force -and -not $DryRun) {
        $response = Read-Host "  Continue anyway? Collisions will be skipped. (y/N)"
        if ($response -notmatch '^[Yy]') {
            Write-Host "  Operation cancelled by user." -ForegroundColor Yellow
            if ($DbConn) {
                try { $DbConn.Close() } catch { }
            }
            exit $Script:ExitCodes.UserCancelled
        }
    }
}

# Filter out collision devices from rename list
if ($Script:NameCollisions.Count -gt 0) {
    $collisionDevices = @()
    foreach ($c in $Script:NameCollisions) {
        $collisionDevices += $c.DeviceID1
        $collisionDevices += $c.DeviceID2
    }

    $filteredList = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($item in $Script:RenameList) {
        if ($item.DeviceID -notin $collisionDevices) {
            $filteredList.Add($item)
        }
    }
    $Script:RenameList = $filteredList
}

# Phase 2: Apply changes
if ($Script:RenameList.Count -eq 0) {
    Write-Host "  ℹ️  No devices need to be renamed." -ForegroundColor Yellow
}
else {
    Write-Host "  Phase 2: " -NoNewline -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "Simulating changes (dry run)..." -ForegroundColor Yellow
    }
    else {
        Write-Host "Applying changes..." -ForegroundColor Cyan
    }

    $transactionBegun = $false
    $anyUpdateError = $false
    $updateStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        if (-not $DryRun) {
            Invoke-SqliteQuery -Query "BEGIN IMMEDIATE TRANSACTION;" -SQLiteConnection $DbConn
            $transactionBegun = $true
            Write-Log "Transaction started" -Level DEBUG
        }

        $updateIdx = 0
        foreach ($item in $Script:RenameList) {
            $updateIdx++

            if ($updateIdx % 50 -eq 0 -or $updateIdx -eq $Script:RenameList.Count) {
                Write-ProgressWithEta -Current $updateIdx -Total $Script:RenameList.Count -Stopwatch $updateStopwatch -Activity "Updating devices"
            }

            Write-Log "RENAMING: $($item.DeviceID) | Old: '$($item.OldName)' -> New: '$($item.NewName)'" -Level INFO

            if (-not $DryRun) {
                try {
                    Invoke-SqliteQuery -Query @"
UPDATE DeviceStatus
SET Name = @NewName
WHERE DeviceID = @DeviceID AND Name <> @NewName
"@ -SQLiteConnection $DbConn -SqlParameters @{ NewName = $item.NewName; DeviceID = $item.DeviceID }

                    $allDevices[$item.DeviceID] = $item.NewName
                    Write-Log "SUCCESS: Updated $($item.DeviceID) to '$($item.NewName)'" -Level SUCCESS
                    $Script:Stats.Renamed++
                }
                catch {
                    Write-Log "ERROR: Failed to update $($item.DeviceID): $_" -Level ERROR
                    $Script:Stats.Errors++
                    $anyUpdateError = $true
                    throw
                }
            }
            else {
                Write-Log "DRY-RUN: Would update $($item.DeviceID) to '$($item.NewName)'" -Level INFO
                $Script:Stats.Renamed++
            }
        }

        if (-not $DryRun -and -not $anyUpdateError) {
            Invoke-SqliteQuery -Query "COMMIT;" -SQLiteConnection $DbConn
            Write-Log "Transaction committed successfully" -Level SUCCESS
        }
    }
    catch {
        if ($transactionBegun) {
            try {
                Invoke-SqliteQuery -Query "ROLLBACK;" -SQLiteConnection $DbConn
                Write-Log "Transaction rolled back due to error" -Level WARNING
            }
            catch {
                Write-Log "ROLLBACK failed: $_" -Level ERROR
            }
        }
        Write-Log "Transaction failed: $_" -Level ERROR
    }
    finally {
        Write-Progress -Activity "Updating devices" -Completed
        $updateStopwatch.Stop()
    }

    Write-Host "  ✓ Updates complete in $(Format-Duration $updateStopwatch.Elapsed)" -ForegroundColor Green
}

# Close database connection
if ($DbConn) {
    try {
        $DbConn.Close()
        Write-Log "Database connection closed" -Level DEBUG
    }
    catch {
        Write-Log "Warning: Failed to close database connection cleanly: $_" -Level WARNING
    }
}

Write-Host ""

# Add final summary to log
Write-Log "Summary: Renamed=$($Script:Stats.Renamed); Unchanged=$($Script:Stats.Unchanged); Missing=$($Script:Stats.Missing); Excluded=$($Script:Stats.Excluded); Collisions=$($Script:Stats.Collisions); Errors=$($Script:Stats.Errors)" -Level INFO

# Write output files
$LogPrimary = $LogFile
$LogDbFallback = Join-Path $DbFolder ("rename_log-{0}.txt" -f $Timestamp)
$LogTempFallback = Join-Path $env:TEMP ("rename_log-{0}.txt" -f $Timestamp)

$CsvPrimary = $CsvFile
$CsvDbFallback = Join-Path $DbFolder ("rename_summary-{0}.csv" -f $Timestamp)
$CsvTempFallback = Join-Path $env:TEMP ("rename_summary-{0}.csv" -f $Timestamp)

# Write debug log
$finalLogPath = Write-SafeFile -PrimaryPath $LogPrimary -FallbackDbPath $LogDbFallback -FallbackTempPath $LogTempFallback -Description "Debug log" -Writer {
    param([string]$Path)
    $Script:DebugLog.ToArray() | Out-File -FilePath $Path -Encoding utf8
}

# Write CSV (only if changes were made)
$finalCsvPath = $null
if ($Script:RenameList.Count -gt 0) {
    $finalCsvPath = Write-SafeFile -PrimaryPath $CsvPrimary -FallbackDbPath $CsvDbFallback -FallbackTempPath $CsvTempFallback -Description "Renaming summary" -Writer {
        param([string]$Path)
        $Script:RenameList.ToArray() | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    }
}

# Write undo script (only if changes were made and not dry run)
$finalUndoPath = $null
if (-not $DryRun -and $Script:UndoStatements.Count -gt 0) {
    $UndoDbFallback = Join-Path $DbFolder ("undo_rename-{0}.sql" -f $Timestamp)
    $UndoTempFallback = Join-Path $env:TEMP ("undo_rename-{0}.sql" -f $Timestamp)

    $finalUndoPath = Write-SafeFile -PrimaryPath $UndoFile -FallbackDbPath $UndoDbFallback -FallbackTempPath $UndoTempFallback -Description "Undo script" -Writer {
        param([string]$Path)
        $header = @"
-- Undo script generated by Rename-Domoticz-From-ZwaveJSON.ps1
-- Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
-- Database: $DbPath
-- To revert changes, run: sqlite3 domoticz.db < $([System.IO.Path]::GetFileName($Path))

BEGIN TRANSACTION;

"@
        $footer = @"

COMMIT;
"@
        ($header + ($Script:UndoStatements.ToArray() -join "`n") + $footer) | Out-File -FilePath $Path -Encoding utf8
    }
}

# Write HTML report (if requested)
$finalHtmlPath = $null
if (-not [string]::IsNullOrWhiteSpace($HtmlReport)) {
    $HtmlDbFallback = Join-Path $DbFolder ("rename_report-{0}.html" -f $Timestamp)
    $HtmlTempFallback = Join-Path $env:TEMP ("rename_report-{0}.html" -f $Timestamp)

    $finalHtmlPath = Write-SafeFile -PrimaryPath $HtmlReport -FallbackDbPath $HtmlDbFallback -FallbackTempPath $HtmlTempFallback -Description "HTML report" -Writer {
        param([string]$Path)
        New-HtmlReport -OutputPath $Path -Stats $Script:Stats -RenameList $Script:RenameList -Collisions $Script:NameCollisions -BackupPath $BackupPath -WasDryRun $DryRun
    }
}

$Script:Stopwatch.Stop()

Write-Host ""

# Final summary box
$summaryContent = [ordered]@{
    Renamed   = $Script:Stats.Renamed
    Unchanged = $Script:Stats.Unchanged
    Missing   = $Script:Stats.Missing
    Excluded  = $Script:Stats.Excluded
    Collisions = $Script:Stats.Collisions
    Errors    = $Script:Stats.Errors
}

$boxTitle = if ($DryRun) { "Summary (DRY RUN)" } else { "Summary" }
Write-ColoredBox -Title $boxTitle -Content $summaryContent

Write-Host ""
Write-Host "  Total time: $(Format-Duration $Script:Stopwatch.Elapsed)" -ForegroundColor Gray

if ($finalLogPath) { Write-Host "  📄 Log:  $finalLogPath" -ForegroundColor Gray }
if ($finalCsvPath) { Write-Host "  📊 CSV:  $finalCsvPath" -ForegroundColor Gray }
if ($finalUndoPath) { Write-Host "  ↩️  Undo: $finalUndoPath" -ForegroundColor Gray }
if ($finalHtmlPath) { Write-Host "  🌐 HTML: $finalHtmlPath" -ForegroundColor Gray }

Write-Host ""

if ($DryRun) {
    Write-Host "  ✅ Dry run complete! Run without -DryRun to apply changes." -ForegroundColor Green
}
else {
    Write-Host "  ✅ Device renaming complete!" -ForegroundColor Green
}

Write-Host ""

# Determine exit code
if ($Script:Stats.Errors -gt 0) {
    exit $Script:ExitCodes.PartialSuccess
}
elseif ($Script:Stats.Renamed -eq 0) {
    exit $Script:ExitCodes.NoChanges
}
else {
    exit $Script:ExitCodes.Success
}

#endregion