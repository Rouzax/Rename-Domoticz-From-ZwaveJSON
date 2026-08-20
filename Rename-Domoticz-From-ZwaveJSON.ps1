<#
.SYNOPSIS
    Renames Domoticz devices from Z-Wave JS node data, skipping unchanged names.

.DESCRIPTION
    Reads Z-Wave node data, constructs a new name for each device
    (Location - DeviceName - Label), and updates the name in a Domoticz SQLite
    database. Can also update SwitchType and CustomImage based on rules.

    Node data comes from one of two sources. Reading live from a running
    zwave-js-ui instance with -ZwaveJsUrl is the preferred route: it needs no
    manual export and is always current. -JsonFile reads a nodes_dump.json
    export instead, for when the instance is not reachable or you want a
    frozen snapshot.

    Features:
      - Bulk-loads Domoticz DeviceStatus once for speed.
      - Performs all updates in a single transaction (atomic; rolls back on error).
      - Normalizes whitespace when comparing old vs new names.
      - Applies renaming rules to normalize common labels (configurable via JSON).
      - Rules can optionally specify SwitchType and CustomImage to set correct device types.
      - Preserves a leading "$" in existing Domoticz names.
      - Skips updates when the existing name already matches the new name.
      - Records only true renames in a CSV summary.
      - Logs detailed progress, shows progress bar with ETA, and prints a final summary.
      - Supports -DryRun for previewing changes without modifying the database.
      - Detects name collisions before applying changes.
      - Generates undo SQL scripts for easy rollback.
      - Optionally generates HTML reports for easier review.
      - Supports device exclusion by ID or pattern.
      - If LogFile/CsvFile are not provided (or writing fails), falls back to the
        DB folder, and then to the system TEMP folder.

.PARAMETER ZwaveJsUrl
    Base URL of a running zwave-js-ui instance (e.g. https://host:8091).
    The preferred way to supply node data: read live over zwave-js-ui's
    socket.io API, no manual export needed. Read-only.
    Mandatory: one of -ZwaveJsUrl or -JsonFile.

.PARAMETER JsonFile
    Path to a nodes_dump.json export from Z-Wave JS UI. Use this when the
    instance is not reachable from here, or when you want a frozen snapshot.
    Mandatory: one of -ZwaveJsUrl or -JsonFile.

.PARAMETER ZwaveJsToken
    Optional auth token for a zwave-js-ui with authentication enabled. Over http
    it is sent in cleartext (allowed, with a warning); prefer https on untrusted
    networks. Prefer passing via an environment variable rather than inline.

.PARAMETER SkipCertificateCheck
    Skip TLS validation for a self-signed https zwave-js-ui.

.PARAMETER DbPath
    Path to the Domoticz SQLite database.

.PARAMETER LogFile
    Path to save the debug/rename log file.
    Default: <db folder>\rename_log-<timestamp>.txt

.PARAMETER CsvFile
    Optional path to save the renaming summary CSV. Only generated when specified.

.PARAMETER RulesFile
    Path to a JSON file containing custom renaming rules.
    If not provided, auto-loads rename_rules.json from the script directory if present.
    Falls back to built-in default rules when no rules file is found.

.PARAMETER HtmlReport
    Path to save the HTML report. Default: auto-generated in DB folder.

.PARAMETER UndoFile
    Path to save the SQL undo script. Default: auto-generated in DB folder.

.PARAMETER ExcludeDeviceIds
    Array of DeviceIDs to exclude from renaming.

.PARAMETER ExcludePattern
    Regex pattern to exclude DeviceIDs matching this pattern.

.PARAMETER DryRun
    Preview changes without modifying the database. No changes are written and
    no backup is taken.

.PARAMETER Force
    Skip confirmation prompt before making changes.

.PARAMETER NoBackup
    Skip database backup (use with caution).

.EXAMPLE
    .\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://zwave-host:8091" -DbPath "domoticz.db" -DryRun

    Preferred route: preview the changes, reading node data live from a running
    zwave-js-ui instance. Always run a preview first.

.EXAMPLE
    .\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://zwave-host:8091" -DbPath "domoticz.db"

    Apply the changes. Stop Domoticz first: it caches device rows in memory and
    can overwrite renames on shutdown.

.EXAMPLE
    .\Rename-Domoticz-From-ZwaveJSON.ps1 `
        -JsonFile "D:\nodes_dump.json" `
        -DbPath   "D:\domoticz.db" `
        -DryRun

    Same preview, from a nodes_dump.json export instead of a live instance.

.EXAMPLE
    .\Rename-Domoticz-From-ZwaveJSON.ps1 `
        -JsonFile "D:\nodes_dump.json" `
        -DbPath   "D:\domoticz.db" `
        -RulesFile "D:\custom_rules.json" `
        -HtmlReport "D:\report.html" `
        -ExcludePattern "test_.*"

.NOTES
    Author:  Rouzax
    Version: 2.11
    Requires: PowerShell 7.0+ and the SQLite assemblies from setup.ps1 (./lib)
    Encoding: Save as UTF-8 (no BOM) if you prefer that style.
#>

#Requires -Version 7.0

[CmdletBinding(DefaultParameterSetName = 'FromFile')]
param (
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'FromFile',
        HelpMessage = "Path to the exported JSON file from Z-Wave JS UI")]
    [ValidateNotNullOrEmpty()]
    [string]$JsonFile,

    [Parameter(Mandatory, Position = 0, ParameterSetName = 'FromZwaveJs',
        HelpMessage = "Base URL of a running zwave-js-ui instance, e.g. https://host:8091")]
    [ValidateNotNullOrEmpty()]
    [string]$ZwaveJsUrl,

    [Parameter(ParameterSetName = 'FromZwaveJs',
        HelpMessage = "Auth token if zwave-js-ui has authentication enabled. Over http it is sent in cleartext (allowed, with a warning). Prefer passing via an environment variable, not inline.")]
    [string]$ZwaveJsToken,

    [Parameter(ParameterSetName = 'FromZwaveJs',
        HelpMessage = "Skip TLS validation for a self-signed https zwave-js-ui")]
    [switch]$SkipCertificateCheck,

    [Parameter(Mandatory = $true, Position = 1, HelpMessage = "Path to the Domoticz SQLite database")]
    [ValidateNotNullOrEmpty()]
    [string]$DbPath,

    [Parameter(HelpMessage = "Path to save the debug log file")]
    [string]$LogFile,

    [Parameter(HelpMessage = "Path to save the renaming summary CSV")]
    [string]$CsvFile,

    [Parameter(HelpMessage = "Path to custom renaming rules JSON file")]
    [string]$RulesFile,

    [Parameter(HelpMessage = "Path to save HTML report (default: auto-generated in DB folder)")]
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

# DeviceIDs backed by several DeviceStatus rows (same DeviceID, different Unit)
# whose rows do not agree on Name, SwitchType or CustomImage. Domoticz creates
# these for multi-unit devices such as Central Scene remotes, and a user can
# name each unit differently. The tool cannot improve on that: one Z-Wave value
# yields one label, so there is no information to give several units several
# names. Writing would collapse them all to one name, and because both the
# UPDATE and the undo statement match on DeviceID alone, the undo script could
# not restore the originals either. These are skipped instead.
$Script:AmbiguousDevices = [System.Collections.Generic.List[PSCustomObject]]::new()

# Collisions that WERE auto-resolved with an endpoint suffix. Kept separate from
# $Script:NameCollisions on purpose: that list drives the skip filter, so a
# resolved collision must never land in it or the device it resolved would be
# dropped from the rename. This list is report-only.
$Script:ResolvedCollisions = [System.Collections.Generic.List[PSCustomObject]]::new()

# Statistics tracking
$Script:Stats = @{
    Renamed      = 0
    TypeChanged  = 0
    ImageChanged = 0
    Unchanged    = 0
    Missing      = 0
    Errors       = 0
    Excluded     = 0
    Collisions   = 0
    Ambiguous    = 0
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

# Note: detecting whether the database is in use is handled cross-platform by
# Test-DatabaseInUse in the DomoticzSqlite module (Linux /proc scan, Windows
# exclusive-open, macOS lsof).

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
        Write-Host "  ❌ ERROR: Rules file not found: $Path" -ForegroundColor Red
        exit $Script:ExitCodes.Error
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "  ❌ ERROR: Failed to parse rules file: $Path" -ForegroundColor Red
        Write-Host "     $($_.Exception.Message)" -ForegroundColor Red
        exit $Script:ExitCodes.Error
    }

    if (-not $content.PSObject.Properties['rules'] -or $null -eq $content.rules) {
        Write-Host "  ❌ ERROR: Rules file missing 'rules' array: $Path" -ForegroundColor Red
        exit $Script:ExitCodes.Error
    }

    $rules = @()
    foreach ($rule in $content.rules) {
        $ruleObj = @{
            Name        = $rule.name
            Pattern     = $rule.pattern
            Replace     = $rule.replace
            With        = $rule.with
            Description = $rule.description
        }

        if ($rule.PSObject.Properties['switchType'] -and $null -ne $rule.switchType) {
            $ruleObj.SwitchType = [int]$rule.switchType
        }

        if ($rule.PSObject.Properties['customImage'] -and $null -ne $rule.customImage) {
            $ruleObj.CustomImage = [int]$rule.customImage
        }

        if ($rule.PSObject.Properties['nodeMatch'] -and $null -ne $rule.nodeMatch) {
            $nodeMatchObj = @{}
            foreach ($prop in $rule.nodeMatch.PSObject.Properties) {
                $propName = $prop.Name
                if ($propName -notin @('productLabel', 'productDescription', 'manufacturer')) {
                    Write-Host "  ⚠️  WARNING: Unknown nodeMatch property '$propName' in rule '$($rule.name)' (ignored)" -ForegroundColor Yellow
                    Write-Log "Unknown nodeMatch property '$propName' in rule '$($rule.name)'" -Level WARNING
                    continue
                }
                if (-not [string]::IsNullOrWhiteSpace($prop.Value)) {
                    try {
                        [void]([regex]::new($prop.Value))
                    }
                    catch {
                        Write-Host "  ❌ ERROR: Invalid regex in nodeMatch.$propName for rule '$($rule.name)': $($prop.Value)" -ForegroundColor Red
                        Write-Host "     $($_.Exception.Message)" -ForegroundColor Red
                        exit $Script:ExitCodes.Error
                    }
                    $nodeMatchObj[$propName] = $prop.Value
                }
            }
            if ($nodeMatchObj.Count -gt 0) {
                $ruleObj.NodeMatch = $nodeMatchObj
            }
        }

        $rules += $ruleObj
    }

    if ($rules.Count -eq 0) {
        Write-Host "  ❌ ERROR: Rules file contains no rules: $Path" -ForegroundColor Red
        exit $Script:ExitCodes.Error
    }

    Write-Log "Loaded $($rules.Count) custom renaming rules from: $Path" -Level INFO
    return $rules
}

function Get-TransformedDeviceName {
    <#
    .SYNOPSIS
        Applies renaming rules to transform a device name.
        Returns the transformed name and any matched rule's switchType/customImage.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$DeviceID,

        [Parameter(Mandatory)]
        [string]$NewName,

        [Parameter(Mandatory)]
        [array]$Rules,

        [Parameter()]
        [hashtable]$NodeData = @{}
    )

    $result = @{
        Name        = $NewName
        SwitchType  = $null
        CustomImage = $null
        RuleName    = $null
    }

    foreach ($rule in $Rules) {
        if ($rule.ContainsKey('NodeMatch') -and $rule.NodeMatch.Count -gt 0) {
            $nodeMatched = $true
            foreach ($key in $rule.NodeMatch.Keys) {
                $nodeValue = if ($NodeData.ContainsKey($key)) { $NodeData[$key] } else { '' }
                if ($nodeValue -notmatch $rule.NodeMatch[$key]) {
                    $nodeMatched = $false
                    break
                }
            }
            if (-not $nodeMatched) { continue }
        }

        if ($DeviceID -match $rule.Pattern) {
            $transformed = $NewName -replace $rule.Replace, $rule.With
            if ($transformed -ne $NewName) {
                Write-Log "Applied rule '$($rule.Name)' to $DeviceID" -Level DEBUG
            }
            $result.Name = $transformed
            $result.RuleName = $rule.Name

            # Capture SwitchType if defined in the rule
            if ($rule.ContainsKey('SwitchType')) {
                $result.SwitchType = $rule.SwitchType
            }

            # Capture CustomImage if defined in the rule
            if ($rule.ContainsKey('CustomImage')) {
                $result.CustomImage = $rule.CustomImage
            }

            return $result
        }
    }

    return $result
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

function Get-CollisionBlame {
    <#
    .SYNOPSIS
        Describes a device involved in a name collision, so the report can
        explain WHY a rename was disambiguated or skipped.
    .DESCRIPTION
        When a Z-Wave value moves endpoint or disappears, Domoticz keeps the old
        DeviceStatus row forever. That stale row never shows up in the node
        source again, but it still owns its name, so the live device that wants
        that name gets an endpoint suffix instead. Reporting whether the holder
        is still present in the node source, and when it last updated, turns an
        unexplained " - EP0" into an obvious "delete this stale device".

        InSource is the signal that matters. Note it is not proof of death on its
        own: zwave-js only materializes some values (notification, battery and
        smoke sub-values) after the node first reports them, so a healthy but
        quiet device can be absent from the source. LastUpdate and Used are
        carried alongside so a human can make the call.
    .OUTPUTS
        PSCustomObject with DeviceID, Name, InSource, Used and LastUpdate.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$DeviceID,

        [Parameter(Mandatory)]
        [hashtable]$AllDevices,

        [Parameter(Mandatory)]
        [System.Collections.Generic.HashSet[string]]$SourceIds
    )

    $device = $AllDevices[$DeviceID]

    [PSCustomObject]@{
        DeviceID   = $DeviceID
        Name       = if ($device) { [string]$device.Name } else { '' }
        InSource   = $SourceIds.Contains($DeviceID)
        Used       = if ($device -and $device.ContainsKey('Used')) { [int]$device.Used } else { 0 }
        LastUpdate = if ($device -and $device.ContainsKey('LastUpdate')) { [string]$device.LastUpdate } else { '' }
    }
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
        $Content,

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
            'Renamed'      { 'Green' }
            'TypeChanged'  { 'Cyan' }
            'ImageChanged' { 'Magenta' }
            'Unchanged'    { 'Yellow' }
            'Errors'       { if ($value -gt 0) { 'Red' } else { 'Green' } }
            'Excluded'     { 'DarkYellow' }
            'Collisions'   { if ($value -gt 0) { 'Red' } else { 'Green' } }
            default        { 'White' }
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
        Generates an HTML report of the renaming operation with improved readability.
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
        [System.Collections.Generic.List[PSCustomObject]]$ResolvedCollisions,

        [Parameter()]
        [System.Collections.Generic.List[PSCustomObject]]$AmbiguousDevices,

        [Parameter()]
        [string]$BackupPath,

        [Parameter()]
        [bool]$WasDryRun
    )

    # SwitchType descriptions for human-readable output
    $switchTypeNames = @{
        0  = "On/Off"
        1  = "Doorbell"
        2  = "Contact"
        3  = "Blinds"
        4  = "X10 Siren"
        5  = "Smoke Detector"
        6  = "Blinds Inverted"
        7  = "Dimmer"
        8  = "Motion Sensor"
        9  = "Push On Button"
        10 = "Push Off Button"
        11 = "Door Contact"
        12 = "Dusk Sensor"
        13 = "Blinds Percentage"
        14 = "Venetian Blinds US"
        15 = "Venetian Blinds EU"
        16 = "Blinds Percentage Inverted"
        17 = "Media Player"
        18 = "Selector"
        19 = "Door Lock"
        20 = "Door Lock Inverted"
    }

    # CustomImage descriptions
    $customImageNames = @{
        0  = "Default"
        1  = "Light"
        2  = "Fan"
        9  = "Computer"
        10 = "Phone"
        13 = "Alarm"
        17 = "Speaker"
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $mode = if ($WasDryRun) { "Dry Run" } else { "Live" }
    $modeClass = if ($WasDryRun) { "warning" } else { "success" }
    $modeIcon = if ($WasDryRun) { "⚡" } else { "✓" }

    # Helper function to extract friendly name (location + device) from full name
    function Get-FriendlyName {
        param([string]$FullName)
        # Remove leading $ if present, then extract everything before the last " - "
        $cleanName = $FullName.TrimStart('$')
        $lastDash = $cleanName.LastIndexOf(' - ')
        if ($lastDash -gt 0) {
            return $cleanName.Substring(0, $lastDash)
        }
        return $cleanName
    }

    # Helper function to extract just the suffix that changed
    function Get-NameSuffix {
        param([string]$FullName)
        $cleanName = $FullName.TrimStart('$')
        $lastDash = $cleanName.LastIndexOf(' - ')
        if ($lastDash -gt 0 -and $lastDash -lt $cleanName.Length - 3) {
            return $cleanName.Substring($lastDash + 3)
        }
        return $cleanName
    }

    # Build device items HTML
    $deviceItemsHtml = ""
    if ($RenameList -and $RenameList.Count -gt 0) {
        foreach ($item in $RenameList) {
            $deviceId = [System.Web.HttpUtility]::HtmlEncode($item.DeviceID)
            $friendlyName = [System.Web.HttpUtility]::HtmlEncode((Get-FriendlyName $item.NewName))
            $newSuffix = [System.Web.HttpUtility]::HtmlEncode((Get-NameSuffix $item.NewName))

            # Build data-changes attribute for filtering
            $changeTypes = @()
            if ($item.NameChanged) { $changeTypes += "name" }
            if ($item.SwitchTypeChanged) { $changeTypes += "switchtype" }
            if ($item.CustomImageChanged) { $changeTypes += "customimage" }
            $dataChanges = $changeTypes -join " "

            # Build badges for header
            $badges = ""
            if ($item.NameChanged) {
                $badges += '<span class="change-badge name">Name</span>'
            }
            if ($item.SwitchTypeChanged) {
                $badges += "<span class=""change-badge switchtype"">Type → $($item.NewSwitchType)</span>"
            }
            if ($item.CustomImageChanged) {
                $badges += "<span class=""change-badge customimage"">Image → $($item.NewCustomImage)</span>"
            }

            # Build detail sections
            $details = ""
            if ($item.NameChanged) {
                # Show the FULL old and new name here. The collapsed header
                # abbreviates to "<friendly> > <last segment>", which is
                # unreadable when the two names have different shapes (a
                # Domoticz auto-generated name vs. a rule-built one), so the
                # expanded detail must always spell both out in full.
                $oldFull = [System.Web.HttpUtility]::HtmlEncode($item.OldName)
                $newFull = [System.Web.HttpUtility]::HtmlEncode($item.NewName)
                $details += @"
                    <div class="change-detail">
                        <div class="change-label">Name</div>
                        <div class="change-values">
                            <span class="old-value">$oldFull</span>
                            <span class="arrow">→</span>
                            <span class="new-value">$newFull</span>
                        </div>
                    </div>
"@
            }
            if ($item.SwitchTypeChanged) {
                $oldTypeName = if ($switchTypeNames.ContainsKey([int]$item.OldSwitchType)) { $switchTypeNames[[int]$item.OldSwitchType] } else { "Unknown" }
                $newTypeName = if ($switchTypeNames.ContainsKey([int]$item.NewSwitchType)) { $switchTypeNames[[int]$item.NewSwitchType] } else { "Unknown" }
                $details += @"
                    <div class="change-detail">
                        <div class="change-label">SwitchType</div>
                        <div class="change-values">
                            <span class="old-value">$($item.OldSwitchType) ($oldTypeName)</span>
                            <span class="arrow">→</span>
                            <span class="new-value">$($item.NewSwitchType) ($newTypeName)</span>
                        </div>
                    </div>
"@
            }
            if ($item.CustomImageChanged) {
                $oldImgName = if ($customImageNames.ContainsKey([int]$item.OldCustomImage)) { $customImageNames[[int]$item.OldCustomImage] } else { "Custom" }
                $newImgName = if ($customImageNames.ContainsKey([int]$item.NewCustomImage)) { $customImageNames[[int]$item.NewCustomImage] } else { "Custom" }
                $details += @"
                    <div class="change-detail">
                        <div class="change-label">CustomImage</div>
                        <div class="change-values">
                            <span class="old-value">$($item.OldCustomImage) ($oldImgName)</span>
                            <span class="arrow">→</span>
                            <span class="new-value">$($item.NewCustomImage) ($newImgName)</span>
                        </div>
                    </div>
"@
            }

            $deviceItemsHtml += @"
            <div class="device-item" data-changes="$dataChanges">
                <div class="device-header" onclick="toggleDevice(this)">
                    <span class="expand-icon">▶</span>
                    <div class="device-name">
                        <div class="friendly-name" title="$([System.Web.HttpUtility]::HtmlEncode($item.NewName))">$friendlyName <span class="name-suffix">› $newSuffix</span></div>
                        <div class="device-id">$deviceId</div>
                    </div>
                    <div class="changes">
                        $badges
                    </div>
                </div>
                <div class="device-details">
$details
                </div>
            </div>
"@
        }
    }
    else {
        $deviceItemsHtml = '<div class="no-data">No devices were updated</div>'
    }

    # Renders one side of a collision: which device it is, whether the node
    # source still knows about it, and how stale it looks. This is what turns an
    # unexplained endpoint suffix into an actionable "delete that device".
    function Get-BlameRowHtml {
        param([string]$Role, [PSCustomObject]$Blame)

        if ($null -eq $Blame) { return "" }

        $enc = { param($t) [System.Web.HttpUtility]::HtmlEncode([string]$t) }
        if ($Blame.InSource) {
            $statusClass = "live"
            $statusText = "in node source"
        }
        else {
            $statusClass = "stale"
            $details = @("not in node source", "Used=$($Blame.Used)")
            if ($Blame.LastUpdate) { $details += "last update $($Blame.LastUpdate)" }
            $statusText = $details -join " · "
        }

        return @"
                <div class="blame-row">
                    <span class="blame-role">$(& $enc $Role)</span>
                    <code>$(& $enc $Blame.DeviceID)</code>
                    <span class="blame-status $statusClass">$(& $enc $statusText)</span>
                    <span class="blame-current">$(& $enc $Blame.Name)</span>
                </div>
"@
    }

    # Build auto-resolved collision section. These are NOT failures (every device
    # still got renamed), but each one means a device was denied the clean name
    # it asked for, which is invisible otherwise and reads as an inexplicable
    # " - EP0" appearing in the rename list.
    $resolvedSection = ""
    if ($ResolvedCollisions -and $ResolvedCollisions.Count -gt 0) {
        $resolvedItems = ""
        foreach ($resolved in $ResolvedCollisions) {
            $hint = ""
            if ($resolved.Held -and -not $resolved.Held.InSource) {
                $hint = @"
                <div class="collision-hint">The device holding this name is no longer reported by the node source. If it is genuinely gone, delete it in Domoticz (Setup &rarr; Devices) and re-run to get the clean name.</div>
"@
            }
            $resolvedItems += @"
            <div class="collision-item resolved">
                <div class="collision-name">$([System.Web.HttpUtility]::HtmlEncode($resolved.ContestedName))</div>
                <div class="collision-resolution">$([System.Web.HttpUtility]::HtmlEncode($resolved.Resolution))</div>
$(Get-BlameRowHtml -Role "wanted by" -Blame $resolved.Wanted)
$(Get-BlameRowHtml -Role "held by" -Blame $resolved.Held)
$hint
            </div>
"@
        }

        $resolvedSection = @"
        <h2>🔀 Names Disambiguated <span class="count">($($ResolvedCollisions.Count) auto-resolved)</span></h2>
        <p class="section-note">Two devices wanted the same name. Each device below was still renamed, but with an endpoint suffix appended so no duplicate name is created.</p>
        <div class="collision-list">
            $resolvedItems
        </div>
"@
    }

    # Build ambiguous-device section. These were skipped, not failed: several
    # Domoticz rows share one DeviceID and disagree, so renaming would collapse
    # deliberately distinct names and the undo script could not restore them.
    $ambiguousSection = ""
    if ($AmbiguousDevices -and $AmbiguousDevices.Count -gt 0) {
        $ambiguousItems = ""
        foreach ($amb in $AmbiguousDevices) {
            $nameRows = ""
            foreach ($n in $amb.Names) {
                $nameRows += @"
                <div class="blame-row"><span class="blame-current">$([System.Web.HttpUtility]::HtmlEncode($n))</span></div>
"@
            }
            $ambiguousItems += @"
            <div class="collision-item resolved">
                <div class="collision-name">$([System.Web.HttpUtility]::HtmlEncode($amb.DeviceID))</div>
                <div class="collision-resolution">Skipped: $($amb.RowCount) Domoticz rows share this DeviceID and do not agree</div>
$nameRows
                <div class="collision-hint">Domoticz keys multi-unit devices (a Central Scene remote, for example) as one DeviceID with several Unit rows, and every write here matches on DeviceID alone. Renaming would give all of them the same name, and the undo script could not put the originals back, so the device is left untouched. Rename these in Domoticz if you want them changed.</div>
            </div>
"@
        }

        $ambiguousSection = @"
        <h2>⏭️ Skipped: ambiguous devices <span class="count">($($AmbiguousDevices.Count) devices)</span></h2>
        <p class="section-note">One DeviceID, several Domoticz rows, different values. The tool cannot give them different names (a single Z-Wave value yields a single label), so it leaves them alone rather than collapsing them.</p>
        <div class="collision-list">
            $ambiguousItems
        </div>
"@
    }

    # Build collision section
    $collisionSection = ""
    if ($Collisions -and $Collisions.Count -gt 0) {
        $collisionItems = ""
        foreach ($collision in $Collisions) {
            $hint = ""
            if ($collision.Held -and -not $collision.Held.InSource) {
                $hint = @"
                <div class="collision-hint">The device holding this name is no longer reported by the node source. If it is genuinely gone, delete it in Domoticz (Setup &rarr; Devices) and re-run.</div>
"@
            }
            $collisionItems += @"
            <div class="collision-item">
                <div class="collision-name">$([System.Web.HttpUtility]::HtmlEncode($collision.NewName))</div>
                <div class="collision-resolution">Both devices skipped, names left unchanged</div>
$(Get-BlameRowHtml -Role "wanted by" -Blame $collision.Wanted)
$(Get-BlameRowHtml -Role "held by" -Blame $collision.Held)
$hint
            </div>
"@
        }

        $collisionSection = @"
        <h2>⚠️ Name Collisions Detected <span class="count">($($Collisions.Count) collisions)</span></h2>
        <p class="section-note">These could not be auto-resolved (same endpoint, no endpoint in the DeviceID, or the disambiguated name was itself taken), so both devices were skipped.</p>
        <div class="collision-list">
            $collisionItems
        </div>
"@
    }

    # Build backup info section
    $backupSection = ""
    if ($BackupPath) {
        $backupSection = @"
        <div class="backup-info">
            📁 <strong>Backup:</strong> <code>$([System.Web.HttpUtility]::HtmlEncode($BackupPath))</code>
        </div>
"@
    }

    $deviceCount = if ($RenameList) { $RenameList.Count } else { 0 }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Domoticz Device Rename Report</title>
    <style>
        :root {
            --bg-primary: #0f0f17;
            --bg-secondary: #1a1a28;
            --bg-card: #242438;
            --bg-hover: #2d2d45;
            --text-primary: #f0f0f5;
            --text-secondary: #8888a0;
            --text-muted: #5a5a70;
            --accent: #e94560;
            --success: #4ecca3;
            --warning: #ffc857;
            --error: #ff6b6b;
            --info: #64b5f6;
            --purple: #b388ff;
            --border: #3a3a50;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
            padding: 2rem;
            font-size: 14px;
        }
        .container { max-width: 1400px; margin: 0 auto; }
        
        header {
            margin-bottom: 2rem;
            padding-bottom: 1.5rem;
            border-bottom: 1px solid var(--border);
        }
        h1 {
            color: var(--text-primary);
            margin-bottom: 0.5rem;
            font-size: 1.75rem;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 0.75rem;
        }
        h1 .icon { font-size: 1.5rem; }
        .meta {
            color: var(--text-secondary);
            font-size: 0.875rem;
            display: flex;
            align-items: center;
            gap: 1rem;
            flex-wrap: wrap;
        }
        .mode-badge {
            display: inline-flex;
            align-items: center;
            gap: 0.375rem;
            padding: 0.25rem 0.625rem;
            border-radius: 4px;
            font-weight: 600;
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        .mode-badge.warning { background: var(--warning); color: #1a1a28; }
        .mode-badge.success { background: var(--success); color: #1a1a28; }
        
        h2 {
            color: var(--text-primary);
            margin: 2.5rem 0 1rem;
            font-size: 1.125rem;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        h2 .count {
            font-size: 0.8rem;
            color: var(--text-muted);
            font-weight: 400;
        }
        
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
            gap: 0.75rem;
            margin-bottom: 2rem;
        }
        .stat-card {
            background: var(--bg-secondary);
            padding: 1rem 1.25rem;
            border-radius: 8px;
            border: 1px solid var(--border);
            text-align: center;
        }
        .stat-card .value {
            font-size: 2rem;
            font-weight: 700;
            line-height: 1.2;
        }
        .stat-card .label {
            color: var(--text-secondary);
            text-transform: uppercase;
            font-size: 0.65rem;
            letter-spacing: 0.75px;
            margin-top: 0.25rem;
        }
        .stat-card.renamed .value { color: var(--success); }
        .stat-card.type-changed .value { color: var(--info); }
        .stat-card.image-changed .value { color: var(--purple); }
        .stat-card.unchanged .value { color: var(--warning); }
        .stat-card.missing .value { color: var(--text-muted); }
        .stat-card.errors .value { color: var(--error); }
        .stat-card.excluded .value { color: var(--purple); }
        
        .device-list {
            display: flex;
            flex-direction: column;
            gap: 0.5rem;
        }
        .device-item {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 8px;
            overflow: hidden;
            transition: border-color 0.15s;
        }
        .device-item:hover {
            border-color: var(--accent);
        }
        .device-header {
            padding: 0.875rem 1rem;
            display: flex;
            align-items: flex-start;
            gap: 1rem;
            cursor: pointer;
        }
        .device-header:hover {
            background: var(--bg-hover);
        }
        .device-name {
            flex: 1;
            min-width: 0;
        }
        .device-name .friendly-name {
            font-weight: 600;
            color: var(--text-primary);
            font-size: 0.9375rem;
            word-break: break-word;
        }
        .device-name .friendly-name .name-suffix {
            color: var(--text-secondary);
            font-weight: 500;
        }
        .device-name .device-id {
            font-family: 'SF Mono', 'Monaco', 'Consolas', monospace;
            font-size: 0.7rem;
            color: var(--text-muted);
            margin-top: 0.25rem;
            word-break: break-all;
        }
        
        .changes {
            display: flex;
            flex-wrap: wrap;
            gap: 0.5rem;
            align-items: flex-start;
        }
        .change-badge {
            display: inline-flex;
            align-items: center;
            gap: 0.375rem;
            padding: 0.375rem 0.625rem;
            border-radius: 6px;
            font-size: 0.75rem;
            font-weight: 500;
            white-space: nowrap;
        }
        .change-badge.name {
            background: rgba(78, 204, 163, 0.15);
            color: var(--success);
            border: 1px solid rgba(78, 204, 163, 0.3);
        }
        .change-badge.switchtype {
            background: rgba(100, 181, 246, 0.15);
            color: var(--info);
            border: 1px solid rgba(100, 181, 246, 0.3);
        }
        .change-badge.customimage {
            background: rgba(179, 136, 255, 0.15);
            color: var(--purple);
            border: 1px solid rgba(179, 136, 255, 0.3);
        }
        
        .device-details {
            display: none;
            padding: 1rem;
            padding-top: 0;
            border-top: 1px solid var(--border);
            background: var(--bg-card);
        }
        .device-item.expanded .device-details {
            display: block;
        }
        .device-item.expanded .device-header {
            background: var(--bg-hover);
        }
        .change-detail {
            padding: 0.75rem 0;
            border-bottom: 1px solid var(--border);
        }
        .change-detail:last-child {
            border-bottom: none;
            padding-bottom: 0;
        }
        .change-detail:first-child {
            padding-top: 0.5rem;
        }
        .change-label {
            font-size: 0.7rem;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            color: var(--text-muted);
            margin-bottom: 0.375rem;
            font-weight: 600;
        }
        .change-values {
            display: flex;
            align-items: center;
            gap: 0.75rem;
            flex-wrap: wrap;
        }
        .old-value {
            color: var(--text-secondary);
            text-decoration: line-through;
            opacity: 0.7;
            overflow-wrap: anywhere;
        }
        .arrow {
            color: var(--accent);
            font-weight: bold;
        }
        .new-value {
            color: var(--text-primary);
            font-weight: 500;
            overflow-wrap: anywhere;
        }
        
        .expand-icon {
            color: var(--text-muted);
            font-size: 0.875rem;
            transition: transform 0.2s;
            flex-shrink: 0;
        }
        .device-item.expanded .expand-icon {
            transform: rotate(90deg);
        }
        
        .toolbar {
            display: flex;
            gap: 1rem;
            margin-bottom: 1rem;
            flex-wrap: wrap;
            align-items: center;
        }
        .search-box {
            flex: 1;
            min-width: 200px;
            max-width: 400px;
        }
        .search-box input {
            width: 100%;
            padding: 0.625rem 1rem;
            border: 1px solid var(--border);
            border-radius: 6px;
            background: var(--bg-secondary);
            color: var(--text-primary);
            font-size: 0.875rem;
        }
        .search-box input:focus {
            outline: none;
            border-color: var(--accent);
        }
        .search-box input::placeholder {
            color: var(--text-muted);
        }
        .filter-buttons {
            display: flex;
            gap: 0.5rem;
            flex-wrap: wrap;
        }
        .filter-btn {
            padding: 0.5rem 0.875rem;
            border: 1px solid var(--border);
            border-radius: 6px;
            background: var(--bg-secondary);
            color: var(--text-secondary);
            font-size: 0.75rem;
            cursor: pointer;
            transition: all 0.15s;
        }
        .filter-btn:hover {
            border-color: var(--text-secondary);
            color: var(--text-primary);
        }
        .filter-btn.active {
            background: var(--accent);
            border-color: var(--accent);
            color: white;
        }
        
        .collision-list {
            display: flex;
            flex-direction: column;
            gap: 0.5rem;
            margin-bottom: 2rem;
        }
        .collision-item {
            background: var(--bg-secondary);
            border: 1px solid var(--error);
            border-radius: 8px;
            padding: 1rem;
        }
        .collision-item.resolved {
            border-color: var(--warning);
        }
        .collision-name {
            font-weight: 600;
            color: var(--error);
            margin-bottom: 0.25rem;
            overflow-wrap: anywhere;
        }
        .collision-item.resolved .collision-name {
            color: var(--warning);
        }
        .collision-resolution {
            font-size: 0.8rem;
            color: var(--text-secondary);
            margin-bottom: 0.5rem;
        }
        .section-note {
            font-size: 0.8rem;
            color: var(--text-muted);
            margin: -0.5rem 0 0.75rem 0;
        }
        .blame-row {
            display: flex;
            align-items: baseline;
            flex-wrap: wrap;
            gap: 0.5rem;
            padding: 0.125rem 0;
        }
        .blame-role {
            font-size: 0.7rem;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            color: var(--text-muted);
            min-width: 5.5rem;
        }
        .blame-row code {
            font-family: 'SF Mono', 'Monaco', 'Consolas', monospace;
            font-size: 0.75rem;
            color: var(--text-secondary);
            overflow-wrap: anywhere;
        }
        .blame-status {
            font-size: 0.7rem;
            border-radius: 4px;
            padding: 0.1rem 0.4rem;
            white-space: nowrap;
        }
        .blame-status.live {
            background: rgba(78, 204, 163, 0.15);
            color: var(--success);
        }
        .blame-status.stale {
            background: rgba(255, 107, 107, 0.15);
            color: var(--error);
        }
        .blame-current {
            font-size: 0.75rem;
            color: var(--text-muted);
            overflow-wrap: anywhere;
        }
        .collision-hint {
            font-size: 0.75rem;
            color: var(--text-muted);
            margin-top: 0.5rem;
            padding-top: 0.5rem;
            border-top: 1px solid var(--border);
        }
        
        footer {
            margin-top: 3rem;
            padding-top: 1rem;
            border-top: 1px solid var(--border);
            color: var(--text-muted);
            font-size: 0.8rem;
        }
        
        .no-data {
            text-align: center;
            color: var(--text-secondary);
            font-style: italic;
            padding: 2rem;
        }
        .backup-info {
            background: var(--bg-secondary);
            padding: 0.875rem 1rem;
            border-radius: 6px;
            border: 1px solid var(--border);
            margin-bottom: 1.5rem;
            font-size: 0.875rem;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        .backup-info code {
            color: var(--success);
            font-family: 'SF Mono', 'Monaco', 'Consolas', monospace;
            font-size: 0.8rem;
        }
        
        @media (max-width: 640px) {
            body { padding: 1rem; }
            .device-header { flex-direction: column; gap: 0.75rem; }
            .changes { width: 100%; }
            .stats-grid { grid-template-columns: repeat(3, 1fr); }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1><span class="icon">🏠</span> Domoticz Device Rename Report</h1>
            <p class="meta">
                <span>Generated: $timestamp</span>
                <span class="mode-badge $modeClass">$modeIcon $mode</span>
            </p>
        </header>

        $backupSection

        <div class="stats-grid">
            <div class="stat-card renamed">
                <div class="value">$($Stats.Renamed)</div>
                <div class="label">Renamed</div>
            </div>
            <div class="stat-card type-changed">
                <div class="value">$($Stats.TypeChanged)</div>
                <div class="label">Type Changed</div>
            </div>
            <div class="stat-card image-changed">
                <div class="value">$($Stats.ImageChanged)</div>
                <div class="label">Image Changed</div>
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

        $resolvedSection

        $ambiguousSection

        <h2>📝 Updated Devices <span class="count">($deviceCount devices)</span></h2>
        
        <div class="toolbar">
            <div class="search-box">
                <input type="text" id="search" placeholder="Filter devices..." autocomplete="off">
            </div>
            <div class="filter-buttons">
                <button class="filter-btn active" data-filter="all">All</button>
                <button class="filter-btn" data-filter="name">Name</button>
                <button class="filter-btn" data-filter="switchtype">SwitchType</button>
                <button class="filter-btn" data-filter="customimage">CustomImage</button>
            </div>
        </div>

        <div class="device-list" id="deviceList">
$deviceItemsHtml
        </div>

        <footer>
            Generated by Rename-Domoticz-From-ZwaveJSON.ps1 v2.11
        </footer>
    </div>

    <script>
        function toggleDevice(header) {
            header.closest('.device-item').classList.toggle('expanded');
        }

        document.getElementById('search').addEventListener('input', function(e) {
            const query = e.target.value.toLowerCase();
            document.querySelectorAll('.device-item').forEach(item => {
                const text = item.textContent.toLowerCase();
                item.style.display = text.includes(query) ? '' : 'none';
            });
        });

        document.querySelectorAll('.filter-btn').forEach(btn => {
            btn.addEventListener('click', function() {
                const filter = this.dataset.filter;
                
                document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
                this.classList.add('active');

                document.querySelectorAll('.device-item').forEach(item => {
                    if (filter === 'all') {
                        item.style.display = '';
                    } else {
                        const changes = item.dataset.changes || '';
                        item.style.display = changes.includes(filter) ? '' : 'none';
                    }
                });
            });
        });

        document.querySelector('h2').addEventListener('dblclick', function() {
            const items = document.querySelectorAll('.device-item');
            const allExpanded = [...items].every(i => i.classList.contains('expanded'));
            items.forEach(item => {
                if (allExpanded) {
                    item.classList.remove('expanded');
                } else {
                    item.classList.add('expanded');
                }
            });
        });
    </script>
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
Write-Host "║     Domoticz Device Renamer from Z-Wave JSON Export v2.11    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "  ⚠️  DRY RUN MODE - No changes will be made to the database" -ForegroundColor Yellow
    Write-Host ""
}

# Ensure the SQLite engine is available. Microsoft.Data.Sqlite plus a native
# SQLite build live in ./lib and are provisioned by setup.ps1, which selects the
# native library for this machine's CPU, so ARM (Raspberry Pi) is supported.
Write-Host "  Checking prerequisites..." -ForegroundColor Gray

try {
    Import-Module (Join-Path $PSScriptRoot 'modules/DomoticzSqlite/DomoticzSqlite.psd1') -Force -ErrorAction Stop
    Initialize-SqliteEngine -LibDir (Join-Path $PSScriptRoot 'lib') -ErrorAction Stop
    Write-Log "SQLite engine initialised from ./lib" -Level INFO
    Write-Host "  ✓ SQLite engine loaded" -ForegroundColor Green
}
catch {
    Write-Host "  ❌ ERROR: SQLite engine unavailable: $_" -ForegroundColor Red
    Write-Host "     Run " -NoNewline
    Write-Host "pwsh ./setup.ps1" -ForegroundColor Yellow -NoNewline
    Write-Host " to download the required SQLite assemblies." -ForegroundColor Gray
    exit $Script:ExitCodes.Error
}

# Validate input files
if (-not (Test-Path -LiteralPath $DbPath)) {
    Write-Host "  ❌ ERROR: Database file not found: $DbPath" -ForegroundColor Red
    exit $Script:ExitCodes.Error
}
Write-Host "  ✓ Database file found" -ForegroundColor Green

if ($PSCmdlet.ParameterSetName -eq 'FromFile') {
    if (-not (Test-Path -LiteralPath $JsonFile)) {
        Write-Host "  ❌ ERROR: JSON file not found: $JsonFile" -ForegroundColor Red
        exit $Script:ExitCodes.Error
    }
    Write-Host "  ✓ JSON file found" -ForegroundColor Green
}

# Acquire node data from the selected source BEFORE any backup or DB work,
# so a failed fetch/parse leaves the database and filesystem untouched.
$ZwaveData = $null
if ($PSCmdlet.ParameterSetName -eq 'FromZwaveJs') {
    Write-Host "  Reading nodes from zwave-js-ui at $ZwaveJsUrl..." -ForegroundColor Gray
    try {
        Import-Module (Join-Path $PSScriptRoot 'modules/ZwaveJsClient/ZwaveJsClient.psd1') -Force -ErrorAction Stop
        $ZwaveData = Get-ZwaveJsNodes -Url $ZwaveJsUrl -Token $ZwaveJsToken -SkipCertificateCheck:$SkipCertificateCheck
    }
    catch {
        Write-Host "  ❌ ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit $Script:ExitCodes.Error
    }
    Write-Log "Loaded $(@($ZwaveData).Count) nodes from zwave-js-ui" -Level SUCCESS
    Write-Host "  ✓ Read $(@($ZwaveData).Count) nodes from zwave-js-ui" -ForegroundColor Green
}
else {
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
        exit $Script:ExitCodes.Error
    }
}

# Check whether another process (typically a running Domoticz) has the database
# open. Best-effort and cross-platform; see Test-DatabaseInUse. Always stop
# Domoticz before applying changes: it caches device rows in memory and can
# overwrite the new names, and the changes only appear after a restart anyway.
Write-Host "  Checking database usage..." -ForegroundColor Gray
$dbUsage = Test-DatabaseInUse -Path $DbPath
if ($dbUsage.InUse) {
    $who = if ($dbUsage.Holders) {
        ($dbUsage.Holders | ForEach-Object { if ($_.Pid) { "$($_.Name) (PID $($_.Pid))" } else { $_.Name } }) -join ', '
    } else { 'another process' }
    Write-Host "  ⚠️  WARNING: The database is open by $who." -ForegroundColor Yellow
    Write-Host "     Stop Domoticz before applying changes - it caches device names in memory and" -ForegroundColor Yellow
    Write-Host "     can overwrite your renames (and changes only show after a restart)." -ForegroundColor Yellow
    Write-Log "Database in use (method=$($dbUsage.Method)): $who" -Level WARNING

    if (-not $Force -and -not $DryRun) {
        $response = Read-Host "     Continue anyway? (y/N)"
        if ($response -notmatch '^[Yy]') {
            Write-Host "  Operation cancelled by user." -ForegroundColor Yellow
            exit $Script:ExitCodes.UserCancelled
        }
    }
}
else {
    Write-Host "  ✓ Database not held by another process" -ForegroundColor Green
}

# Setup paths
$DbFolder = Split-Path -Parent $DbPath
$Timestamp = Get-Date -Format "yy.MM.dd-HH.mm.ss"
$TempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { [System.IO.Path]::GetTempPath() }
$BackupPath = Join-Path $DbFolder "domoticz-$Timestamp.db"

# Set default paths if not provided
if (-not $PSBoundParameters.ContainsKey('LogFile') -or [string]::IsNullOrWhiteSpace($LogFile)) {
    $LogFile = Join-Path $DbFolder ("rename_log-{0}.txt" -f $Timestamp)
}
if (-not $PSBoundParameters.ContainsKey('CsvFile') -or [string]::IsNullOrWhiteSpace($CsvFile)) {
    $CsvFile = $null
}
if (-not $PSBoundParameters.ContainsKey('HtmlReport') -or [string]::IsNullOrWhiteSpace($HtmlReport)) {
    $HtmlReport = Join-Path $DbFolder ("rename_report-{0}.html" -f $Timestamp)
}
if (-not $PSBoundParameters.ContainsKey('UndoFile') -or [string]::IsNullOrWhiteSpace($UndoFile)) {
    $UndoFile = Join-Path $DbFolder "undo_rename-$Timestamp.sql"
}

# Validate ExcludePattern regex if provided
if (-not [string]::IsNullOrWhiteSpace($ExcludePattern)) {
    try {
        [void]([regex]::new($ExcludePattern))
    }
    catch {
        Write-Host "  ❌ ERROR: Invalid ExcludePattern regex: $ExcludePattern" -ForegroundColor Red
        Write-Host "     $($_.Exception.Message)" -ForegroundColor Red
        exit $Script:ExitCodes.Error
    }
}

Write-Host ""

# Load renaming rules
$effectiveRulesFile = $RulesFile
if ([string]::IsNullOrWhiteSpace($effectiveRulesFile) -and -not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $autoRulesPath = Join-Path $PSScriptRoot "rename_rules.json"
    if (Test-Path -LiteralPath $autoRulesPath) {
        $effectiveRulesFile = $autoRulesPath
        Write-Host "  ✓ Found rename_rules.json next to script" -ForegroundColor Green
    }
}
$RenamingRules = Import-RenamingRules -Path $effectiveRulesFile
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
    $DbConn = Open-SqliteDatabase -Path $DbPath
    Write-Log "Connected to SQLite database: $DbPath" -Level SUCCESS
    Write-Host "  ✓ Database connection established" -ForegroundColor Green
}
catch {
    Write-Host "  ❌ ERROR: Could not open SQLite database: $_" -ForegroundColor Red
    exit $Script:ExitCodes.Error
}

# Bulk-read DeviceStatus (including SwitchType and CustomImage)
$allDevices = @{}
try {
    Write-Host "  Loading device data from database..." -ForegroundColor Gray
    # Used and LastUpdate are not needed to rename anything; they are carried so
    # a name collision can report whether the device holding the contested name
    # is still alive (see Get-CollisionBlame).
    $rows = Invoke-SqliteReader -Connection $DbConn -Sql "SELECT DeviceID, Name, SwitchType, CustomImage, Type, Used, LastUpdate FROM DeviceStatus"

    # A DeviceID is not unique in DeviceStatus: Domoticz keys multi-unit devices
    # (Central Scene remotes, for example) as one DeviceID with several Unit
    # rows. Keeping only the last row read would hide the others, while every
    # write matches on DeviceID alone and therefore hits all of them. Track each
    # DeviceID's full row set so disagreements can be detected rather than
    # silently flattened, and so collision detection knows every name in use.
    $allNamesInUse = [System.Collections.Generic.HashSet[string]]::new()
    $ambiguousDetails = @{}
    $rowsById = @{}
    foreach ($r in $rows) {
        $rid = [string]$r.DeviceID
        $entry = @{
            Name        = [string]$r.Name
            SwitchType  = [int]$r.SwitchType
            CustomImage = [int]$r.CustomImage
            Type        = [int]$r.Type
            Used        = [int]$r.Used
            LastUpdate  = [string]$r.LastUpdate
        }
        $allDevices[$rid] = $entry
        [void]$allNamesInUse.Add((([string]$r.Name) -replace '\s{2,}', ' ').Trim())
        if (-not $rowsById.ContainsKey($rid)) { $rowsById[$rid] = [System.Collections.Generic.List[hashtable]]::new() }
        $rowsById[$rid].Add($entry)
    }

    foreach ($rid in $rowsById.Keys) {
        $set = $rowsById[$rid]
        if ($set.Count -lt 2) { continue }
        $distinctNames = @($set.Name | Sort-Object -Unique)
        $distinctTypes = @($set.SwitchType | Sort-Object -Unique)
        $distinctImages = @($set.CustomImage | Sort-Object -Unique)
        if ($distinctNames.Count -le 1 -and $distinctTypes.Count -le 1 -and $distinctImages.Count -le 1) { continue }
        # Recorded, not reported. Only the ones the analysis loop actually
        # reaches are surfaced: a Domoticz database holds devices from other
        # hardware whose rows may well disagree, and this tool never renames
        # them, so reporting them would be noise.
        $ambiguousDetails[$rid] = [PSCustomObject]@{
            DeviceID = $rid
            RowCount = $set.Count
            Names    = $distinctNames
        }
    }
    Write-Log "Loaded $($allDevices.Count) DeviceStatus rows into memory" -Level SUCCESS
    Write-Host "  ✓ Loaded $($allDevices.Count) devices from database" -ForegroundColor Green

    if ($ambiguousDetails.Count -gt 0) {
        Write-Log "$($ambiguousDetails.Count) DeviceID(s) in the database map to several DeviceStatus rows that disagree; any that this run would otherwise rename will be skipped" -Level INFO
    }
}
catch {
    Write-Host "  ❌ ERROR: Failed to load DeviceStatus table: $_" -ForegroundColor Red
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

# Calculate total items for progress, and record every DeviceID the node source
# knows about. The full set has to exist BEFORE Phase 1 starts: a collision can
# name a device that Phase 1 has not reached yet, so building the set as we go
# would report a live device as missing purely because of iteration order.
$total = 0
$sourceDeviceIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($d in $ZwaveData) {
    # StrictMode-safe: some nodes (e.g. the controller) omit 'values' entirely
    # in a live zwave-js-ui state, unlike a JSON dump which includes an empty array.
    if ($d.PSObject.Properties['values'] -and $d.values) {
        $total += [int]$d.values.Count
        foreach ($v in $d.values) {
            if ($null -eq $v -or -not $v.PSObject.Properties['id']) { continue }
            # Assign first: inside a method call the comma in `-replace "/", "-"`
            # would be parsed as an argument separator, not as the replacement.
            $vdid = ("${BaseIdentifier}_$([string]$v.id)" -replace " ", "_") -replace "/", "-"
            [void]$sourceDeviceIds.Add($vdid)
        }
        # +1 for the node-level device (e.g. a combined Temp+Humidity device
        # Domoticz creates and keys as {base}_node<id>) when one exists.
        if ($d.PSObject.Properties['id']) {
            $ndid = ("${BaseIdentifier}_node$([string]$d.id)" -replace " ", "_") -replace "/", "-"
            [void]$sourceDeviceIds.Add($ndid)
            if ($allDevices.ContainsKey($ndid)) { $total++ }
        }
    }
}

# Track proposed names for collision detection.
#
# Seed with the current name of every existing device so a rename that would
# collide with a device KEEPING its name (not just with another pending
# rename) is detected against the true end state. Without this seed, a rename
# landing on an already-correctly-named device slipped through undetected and
# silently created duplicate names.
#
# $pendingNames marks names owned by an actual pending rename; those may be
# auto-disambiguated with endpoint suffixes. Seeded names belong to devices
# that keep their current name and must never be silently renamed.
$proposedNames = @{}
$pendingNames = [System.Collections.Generic.HashSet[string]]::new()
foreach ($seedId in $allDevices.Keys) {
    $seedName = ([string]$allDevices[$seedId].Name -replace '\s{2,}', ' ').Trim()
    if (-not $proposedNames.ContainsKey($seedName)) {
        $proposedNames[$seedName] = $seedId
    }
}

# $allDevices holds one row per DeviceID, so the loop above misses names owned
# by the other rows of a multi-unit device. Seed those too: a name is taken even
# when its row is not the one representing that DeviceID, and renaming another
# device onto it would create exactly the duplicate this detection exists to
# prevent. The DeviceID recorded is only used for reporting.
foreach ($usedName in $allNamesInUse) {
    if (-not $proposedNames.ContainsKey($usedName)) {
        $proposedNames[$usedName] = '(another unit of a multi-row device)'
    }
}

# First pass: collect all proposed renames and detect collisions
Write-Host "  Phase 1: Analyzing proposed changes..." -ForegroundColor Cyan
$idx = 0
$processingStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($Device in $ZwaveData) {
    $Location = if ($Device.PSObject.Properties["loc"]) { [string]$Device.loc } else { "" }
    $DeviceName = if ($Device.PSObject.Properties["name"]) { [string]$Device.name } else { "" }

    $nodeData = @{
        productLabel       = if ($Device.PSObject.Properties['productLabel']) { [string]$Device.productLabel } else { '' }
        productDescription = if ($Device.PSObject.Properties['productDescription']) { [string]$Device.productDescription } else { '' }
        manufacturer       = if ($Device.PSObject.Properties['manufacturer']) { [string]$Device.manufacturer } else { '' }
    }

    if (-not $Device.PSObject.Properties["values"]) { continue }

    # Domoticz may create a node-level device (e.g. a combined Temp+Humidity
    # device) keyed as {base}_node<id> that has no Z-Wave value behind it, so it
    # is never matched by the value loop below. Process it as a synthetic target:
    # its name is "{loc} - {name}", with a " - Climate" label for Temp+Humidity
    # (Domoticz Type 82) and Temp+Humidity+Baro (Type 84) devices.
    $valueTargets = @($Device.values)
    if ($Device.PSObject.Properties["id"]) {
        $nodeDeviceId = ("${BaseIdentifier}_node$([string]$Device.id)" -replace " ", "_") -replace "/", "-"
        if ($allDevices.ContainsKey($nodeDeviceId)) {
            $nodeType = if ($allDevices[$nodeDeviceId].ContainsKey('Type')) { [int]$allDevices[$nodeDeviceId].Type } else { 0 }
            $nodeLabel = if ($nodeType -in 82, 84) { 'Climate' } else { '' }
            $valueTargets = @([pscustomobject]@{ id = "node$([string]$Device.id)"; label = $nodeLabel }) + $valueTargets
        }
    }

    foreach ($Value in $valueTargets) {
        $idx++

        if ($idx % 100 -eq 0 -or $idx -eq $total) {
            Write-ProgressWithEta -Current $idx -Total $total -Stopwatch $processingStopwatch -Activity "Analyzing devices"
        }

        if (-not $Value) { continue }
        if (-not $Value.PSObject.Properties["id"]) { continue }
        if (-not $Value.PSObject.Properties["label"]) { continue }

        $PropertyID = [string]$Value.id
        $Label = [string]$Value.label
        $DeviceID = ("${BaseIdentifier}_${PropertyID}" -replace " ", "_") -replace "/", "-"

        # Check exclusions
        if (Test-DeviceExcluded -DeviceID $DeviceID -ExcludeIds $ExcludeDeviceIds -ExcludePattern $ExcludePattern) {
            Write-Log "EXCLUDED: $DeviceID (matched exclusion rule)" -Level DEBUG
            $Script:Stats.Excluded++
            continue
        }

        # Skip devices whose DeviceStatus rows disagree. Renaming would collapse
        # several deliberately distinct names into one, and the undo statement
        # matches on DeviceID alone so it could not put them back.
        if ($ambiguousDetails.ContainsKey($DeviceID)) {
            Write-Log "SKIPPED (ambiguous): $DeviceID | several DeviceStatus rows disagree; renaming would collapse them" -Level WARNING
            $Script:AmbiguousDevices.Add($ambiguousDetails[$DeviceID])
            $Script:Stats.Ambiguous++
            continue
        }

        # Build new name
        $parts = @($Location, $DeviceName, $Label) | Where-Object { $_ -and $_.Trim() -ne "" }
        $NewName = ($parts -join " - ").Trim()
        $NewName = $NewName -replace '\s{2,}', ' '

        # Get transformed name and any switchType/customImage from matched rule
        $transformResult = Get-TransformedDeviceName -DeviceID $DeviceID -NewName $NewName -Rules $RenamingRules -NodeData $nodeData
        $NewName = $transformResult.Name
        $NewSwitchType = $transformResult.SwitchType
        $NewCustomImage = $transformResult.CustomImage

        # Check if device exists
        $deviceData = $allDevices[$DeviceID]
        if ($null -eq $deviceData) {
            $Script:Stats.Missing++
            continue
        }

        $OldName = $deviceData.Name
        $OldSwitchType = $deviceData.SwitchType
        $OldCustomImage = $deviceData.CustomImage

        # Preserve "$" prefix
        if ($OldName -match '^\$' -and $NewName -notmatch '^\$') {
            $NewName = "`$" + $NewName
        }

        # Normalize for comparison
        $OldNameNorm = ($OldName -replace '\s{2,}', ' ').Trim()
        $NewNameNorm = ($NewName -replace '\s{2,}', ' ').Trim()

        # Check what needs to change
        $nameChanged = ($OldNameNorm -ne $NewNameNorm)
        $switchTypeChanged = ($null -ne $NewSwitchType -and $OldSwitchType -ne $NewSwitchType)
        $customImageChanged = ($null -ne $NewCustomImage -and $OldCustomImage -ne $NewCustomImage)

        # Skip if nothing changed
        if (-not $nameChanged -and -not $switchTypeChanged -and -not $customImageChanged) {
            Write-Log "UNCHANGED: $DeviceID | No changes needed" -Level DEBUG
            $Script:Stats.Unchanged++
            continue
        }

        # Check for name collision (only if the name is actually changing).
        #
        # Because $proposedNames is seeded with every existing device name, this
        # catches a rename landing on a device that keeps its name, not only a
        # clash between two pending renames.
        if ($nameChanged) {
            if ($proposedNames.ContainsKey($NewNameNorm)) {
                $existingDeviceId = $proposedNames[$NewNameNorm]
                $existingIsPending = $pendingNames.Contains($NewNameNorm)
                $baseIdEscaped = [regex]::Escape($BaseIdentifier)

                # Extract endpoint numbers from both DeviceIDs
                $currentSuffix = $DeviceID -replace "^${baseIdEscaped}_", ""
                $existingSuffix = $existingDeviceId -replace "^${baseIdEscaped}_", ""
                $currentEndpoint = if ($currentSuffix -match '^\d+-\d+-(\d+)') { $Matches[1] } else { $null }
                $existingEndpoint = if ($existingSuffix -match '^\d+-\d+-(\d+)') { $Matches[1] } else { $null }

                $endpointsDiffer = ($null -ne $currentEndpoint -and $null -ne $existingEndpoint -and $currentEndpoint -ne $existingEndpoint)
                $disambiguatedNorm = "$NewNameNorm - EP$currentEndpoint"

                # Snapshot the contested name before the branches below reassign
                # $NewNameNorm to the disambiguated form. Stripping the suffix
                # back off afterwards would corrupt a real name ending in "EP<n>".
                $contestedName = $NewNameNorm

                if ($endpointsDiffer -and $existingIsPending) {
                    # Both sides are pending renames on different endpoints:
                    # disambiguate BOTH by appending their endpoint numbers.
                    foreach ($item in $Script:RenameList) {
                        if ($item.DeviceID -eq $existingDeviceId -and $item.NameChanged) {
                            $item.NewName = "$($item.NewName) - EP$existingEndpoint"
                            break
                        }
                    }

                    # Update tracking: remove base name, add disambiguated existing name
                    $proposedNames.Remove($NewNameNorm)
                    [void]$pendingNames.Remove($NewNameNorm)
                    $proposedNames["$NewNameNorm - EP$existingEndpoint"] = $existingDeviceId
                    [void]$pendingNames.Add("$NewNameNorm - EP$existingEndpoint")

                    # Free this device's old name and register its disambiguated name
                    if ($proposedNames[$OldNameNorm] -eq $DeviceID) { $proposedNames.Remove($OldNameNorm); [void]$pendingNames.Remove($OldNameNorm) }
                    $NewName = "$NewName - EP$currentEndpoint"
                    $NewNameNorm = $disambiguatedNorm
                    $proposedNames[$NewNameNorm] = $DeviceID
                    [void]$pendingNames.Add($NewNameNorm)

                    $Script:ResolvedCollisions.Add([PSCustomObject]@{
                        ContestedName = $contestedName
                        Resolution    = "Endpoint suffixes EP$existingEndpoint and EP$currentEndpoint appended"
                        Wanted        = Get-CollisionBlame -DeviceID $DeviceID -AllDevices $allDevices -SourceIds $sourceDeviceIds
                        Held          = Get-CollisionBlame -DeviceID $existingDeviceId -AllDevices $allDevices -SourceIds $sourceDeviceIds
                    })
                    $Script:Stats.Collisions++
                    Write-Log "COLLISION RESOLVED: Disambiguated with EP$existingEndpoint and EP$currentEndpoint for $existingDeviceId and $DeviceID" -Level INFO
                }
                elseif ($endpointsDiffer -and -not $proposedNames.ContainsKey($disambiguatedNorm)) {
                    # Existing owner keeps its name (not a pending rename). Leave it
                    # alone and disambiguate only THIS device with its endpoint.
                    if ($proposedNames[$OldNameNorm] -eq $DeviceID) { $proposedNames.Remove($OldNameNorm); [void]$pendingNames.Remove($OldNameNorm) }
                    $NewName = "$NewName - EP$currentEndpoint"
                    $NewNameNorm = $disambiguatedNorm
                    $proposedNames[$NewNameNorm] = $DeviceID
                    [void]$pendingNames.Add($NewNameNorm)

                    $Script:ResolvedCollisions.Add([PSCustomObject]@{
                        ContestedName = $contestedName
                        Resolution    = "Endpoint suffix EP$currentEndpoint appended"
                        Wanted        = Get-CollisionBlame -DeviceID $DeviceID -AllDevices $allDevices -SourceIds $sourceDeviceIds
                        Held          = Get-CollisionBlame -DeviceID $existingDeviceId -AllDevices $allDevices -SourceIds $sourceDeviceIds
                    })
                    $Script:Stats.Collisions++
                    Write-Log "COLLISION RESOLVED: Disambiguated $DeviceID with EP$currentEndpoint (conflicted with $existingDeviceId)" -Level INFO
                }
                else {
                    # Cannot auto-resolve (same endpoint, missing endpoints, or the
                    # disambiguated name is itself taken). Report and skip both.
                    $Script:NameCollisions.Add([PSCustomObject]@{
                        NewName   = $NewNameNorm
                        DeviceID1 = $existingDeviceId
                        DeviceID2 = $DeviceID
                        Held      = Get-CollisionBlame -DeviceID $existingDeviceId -AllDevices $allDevices -SourceIds $sourceDeviceIds
                        Wanted    = Get-CollisionBlame -DeviceID $DeviceID -AllDevices $allDevices -SourceIds $sourceDeviceIds
                    })
                    $Script:Stats.Collisions++
                    Write-Log "COLLISION: '$NewNameNorm' would be assigned to both $existingDeviceId and $DeviceID" -Level WARNING
                }
            }
            else {
                # Free this device's old name (it is moving) and claim the new one.
                if ($proposedNames[$OldNameNorm] -eq $DeviceID) { $proposedNames.Remove($OldNameNorm); [void]$pendingNames.Remove($OldNameNorm) }
                $proposedNames[$NewNameNorm] = $DeviceID
                [void]$pendingNames.Add($NewNameNorm)
            }
        }

        # Build change description for logging
        $changes = @()
        if ($nameChanged) { $changes += "Name" }
        if ($switchTypeChanged) { $changes += "SwitchType($OldSwitchType->$NewSwitchType)" }
        if ($customImageChanged) { $changes += "CustomImage($OldCustomImage->$NewCustomImage)" }
        Write-Log "CHANGE: $DeviceID | $($changes -join ', ')" -Level DEBUG

        # Add to rename list
        $Script:RenameList.Add([PSCustomObject]@{
            DeviceID          = $DeviceID
            OldName           = $OldName
            NewName           = if ($nameChanged) { $NewName } else { $null }
            OldSwitchType     = $OldSwitchType
            NewSwitchType     = if ($switchTypeChanged) { $NewSwitchType } else { $null }
            OldCustomImage    = $OldCustomImage
            NewCustomImage    = if ($customImageChanged) { $NewCustomImage } else { $null }
            NameChanged       = $nameChanged
            SwitchTypeChanged = $switchTypeChanged
            CustomImageChanged = $customImageChanged
        })

        # Generate undo statement (only include fields that changed)
        $undoParts = @()
        if ($nameChanged) {
            $escapedOldName = ConvertTo-SqlLiteral -Value $OldName
            $undoParts += "Name = $escapedOldName"
        }
        if ($switchTypeChanged) {
            $undoParts += "SwitchType = $OldSwitchType"
        }
        if ($customImageChanged) {
            $undoParts += "CustomImage = $OldCustomImage"
        }
        $escapedDeviceId = ConvertTo-SqlLiteral -Value $DeviceID
        $Script:UndoStatements.Add("UPDATE DeviceStatus SET $($undoParts -join ', ') WHERE DeviceID = $escapedDeviceId;")
    }
}

Write-Progress -Activity "Analyzing devices" -Completed
$processingStopwatch.Stop()

Write-Host "  ✓ Analysis complete in $(Format-Duration $processingStopwatch.Elapsed)" -ForegroundColor Green
if ($Script:Stats.Missing -gt 0) {
    Write-Log "$($Script:Stats.Missing) Z-Wave values had no matching Domoticz device (skipped)" -Level INFO
}
Write-Host ""

# Report collisions
if ($Script:AmbiguousDevices.Count -gt 0) {
    Write-Host "  ⚠️  $($Script:AmbiguousDevices.Count) device(s) skipped: several Domoticz rows share the DeviceID and disagree" -ForegroundColor Yellow
    Write-Host "     Renaming would collapse them into one name, and the undo script could not restore them." -ForegroundColor Gray
    foreach ($amb in $Script:AmbiguousDevices | Select-Object -First 5) {
        Write-Host "       - $($amb.DeviceID) ($($amb.RowCount) rows)" -ForegroundColor Yellow
        foreach ($n in $amb.Names) { Write-Host "         '$n'" -ForegroundColor Gray }
    }
    if ($Script:AmbiguousDevices.Count -gt 5) {
        Write-Host "       ... and $($Script:AmbiguousDevices.Count - 5) more (see the HTML report)" -ForegroundColor Gray
    }
    Write-Host ""
}

$autoResolved = $Script:ResolvedCollisions.Count
if ($autoResolved -gt 0) {
    Write-Host "  ✓ $autoResolved name collision(s) auto-resolved with endpoint numbers" -ForegroundColor Green

    # A resolved collision still means a device did NOT get the clean name it
    # asked for. Call out the ones caused by a device that is no longer in the
    # node source, because deleting that stale device is the actual fix.
    $staleBlockers = @($Script:ResolvedCollisions | Where-Object { -not $_.Held.InSource })
    if ($staleBlockers.Count -gt 0) {
        Write-Host "     $($staleBlockers.Count) of those blocked by a device no longer in the node source:" -ForegroundColor Yellow
        foreach ($blocked in $staleBlockers | Select-Object -First 5) {
            Write-Host "       - '$($blocked.ContestedName)' → $($blocked.Resolution)" -ForegroundColor Yellow
            Write-Host "         held by $($blocked.Held.DeviceID) (Used=$($blocked.Held.Used), last update $($blocked.Held.LastUpdate))" -ForegroundColor Gray
        }
        if ($staleBlockers.Count -gt 5) {
            Write-Host "       ... and $($staleBlockers.Count - 5) more (see the HTML report)" -ForegroundColor Gray
        }
        Write-Host "       Delete those in Domoticz to free the name, then re-run." -ForegroundColor Gray
    }
}

if ($Script:NameCollisions.Count -gt 0) {
    Write-Host "  ⚠️  WARNING: $($Script:NameCollisions.Count) unresolvable name collision(s) detected!" -ForegroundColor Red
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
                try { $DbConn.Close() } catch { Write-Log "Failed to close connection: $_" -Level WARNING }
            }
            exit $Script:ExitCodes.UserCancelled
        }
    }
}

# Filter out unresolvable collision devices and no-op renames (where collision
# resolution produced a name matching the existing name)
$filteredList = [System.Collections.Generic.List[PSCustomObject]]::new()
$collisionDevices = @()
if ($Script:NameCollisions.Count -gt 0) {
    foreach ($c in $Script:NameCollisions) {
        $collisionDevices += $c.DeviceID1
        $collisionDevices += $c.DeviceID2
    }
}

foreach ($item in $Script:RenameList) {
    if ($item.DeviceID -in $collisionDevices) { continue }

    # Re-check if name actually changed after collision resolution
    if ($item.NameChanged -and $null -ne $item.NewName) {
        $oldNorm = ($item.OldName -replace '\s{2,}', ' ').Trim()
        $newNorm = ($item.NewName -replace '\s{2,}', ' ').Trim()
        if ($oldNorm -eq $newNorm) {
            $item.NameChanged = $false
            $item.NewName = $null
            if (-not $item.SwitchTypeChanged -and -not $item.CustomImageChanged) {
                $Script:Stats.Unchanged++
                continue
            }
        }
    }

    $filteredList.Add($item)
}
$Script:RenameList = $filteredList

# Count proposed changes
$renameCount = @($Script:RenameList | Where-Object { $_.NameChanged }).Count
$typeCount = @($Script:RenameList | Where-Object { $_.SwitchTypeChanged }).Count
$imageCount = @($Script:RenameList | Where-Object { $_.CustomImageChanged }).Count

# Confirmation prompt (unless Force, DryRun, or no changes)
if (-not $Force -and -not $DryRun -and ($renameCount + $typeCount + $imageCount) -gt 0) {
    Write-Host ""
    Write-Host "  Proposed changes:" -ForegroundColor White
    if ($renameCount -gt 0) { Write-Host "    Renames:       $renameCount" -ForegroundColor Green }
    if ($typeCount -gt 0)   { Write-Host "    Type changes:  $typeCount" -ForegroundColor Cyan }
    if ($imageCount -gt 0)  { Write-Host "    Image changes: $imageCount" -ForegroundColor Magenta }
    Write-Host ""
    Write-Host "  This will modify your Domoticz database." -ForegroundColor Yellow
    $response = Read-Host "  Proceed? (y/N)"
    if ($response -notmatch '^[Yy]') {
        Write-Host "  Operation cancelled by user." -ForegroundColor Yellow
        if ($DbConn) {
            try { $DbConn.Close() } catch { Write-Log "Failed to close connection: $_" -Level WARNING }
        }
        exit $Script:ExitCodes.UserCancelled
    }
    Write-Host ""
}

# Phase 2: Apply changes
if ($Script:RenameList.Count -eq 0) {
    Write-Host "  ℹ️  No devices need to be updated." -ForegroundColor Yellow
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
            [void](Invoke-SqliteNonQuery -Connection $DbConn -Sql "BEGIN IMMEDIATE TRANSACTION;")
            $transactionBegun = $true
            Write-Log "Transaction started" -Level DEBUG
        }

        $updateIdx = 0
        foreach ($item in $Script:RenameList) {
            $updateIdx++

            if ($updateIdx % 50 -eq 0 -or $updateIdx -eq $Script:RenameList.Count) {
                Write-ProgressWithEta -Current $updateIdx -Total $Script:RenameList.Count -Stopwatch $updateStopwatch -Activity "Updating devices"
            }

            # Build change description
            $changes = @()
            if ($item.NameChanged) { $changes += "Name: '$($item.OldName)' -> '$($item.NewName)'" }
            if ($item.SwitchTypeChanged) { $changes += "SwitchType: $($item.OldSwitchType) -> $($item.NewSwitchType)" }
            if ($item.CustomImageChanged) { $changes += "CustomImage: $($item.OldCustomImage) -> $($item.NewCustomImage)" }

            Write-Log "UPDATING: $($item.DeviceID) | $($changes -join '; ')" -Level INFO

            if (-not $DryRun) {
                try {
                    # Build dynamic SET clause
                    $setParts = @()
                    $sqlParams = @{ DeviceID = $item.DeviceID }

                    if ($item.NameChanged) {
                        $setParts += "Name = @NewName"
                        $sqlParams.NewName = $item.NewName
                    }
                    if ($item.SwitchTypeChanged) {
                        $setParts += "SwitchType = @NewSwitchType"
                        $sqlParams.NewSwitchType = $item.NewSwitchType
                    }
                    if ($item.CustomImageChanged) {
                        $setParts += "CustomImage = @NewCustomImage"
                        $sqlParams.NewCustomImage = $item.NewCustomImage
                    }

                    $updateQuery = "UPDATE DeviceStatus SET $($setParts -join ', ') WHERE DeviceID = @DeviceID"
                    [void](Invoke-SqliteNonQuery -Connection $DbConn -Sql $updateQuery -Parameters $sqlParams)

                    # Update cached data
                    if ($item.NameChanged) {
                        $allDevices[$item.DeviceID].Name = $item.NewName
                        $Script:Stats.Renamed++
                    }
                    if ($item.SwitchTypeChanged) {
                        $allDevices[$item.DeviceID].SwitchType = $item.NewSwitchType
                        $Script:Stats.TypeChanged++
                    }
                    if ($item.CustomImageChanged) {
                        $allDevices[$item.DeviceID].CustomImage = $item.NewCustomImage
                        $Script:Stats.ImageChanged++
                    }

                    Write-Log "SUCCESS: Updated $($item.DeviceID)" -Level SUCCESS
                }
                catch {
                    Write-Log "ERROR: Failed to update $($item.DeviceID): $_" -Level ERROR
                    $Script:Stats.Errors++
                    $anyUpdateError = $true
                    throw
                }
            }
            else {
                Write-Log "DRY-RUN: Would update $($item.DeviceID)" -Level INFO
                if ($item.NameChanged) { $Script:Stats.Renamed++ }
                if ($item.SwitchTypeChanged) { $Script:Stats.TypeChanged++ }
                if ($item.CustomImageChanged) { $Script:Stats.ImageChanged++ }
            }
        }

        if (-not $DryRun -and -not $anyUpdateError) {
            [void](Invoke-SqliteNonQuery -Connection $DbConn -Sql "COMMIT;")
            Write-Log "Transaction committed successfully" -Level SUCCESS
        }
    }
    catch {
        if ($transactionBegun) {
            try {
                [void](Invoke-SqliteNonQuery -Connection $DbConn -Sql "ROLLBACK;")
                Write-Log "Transaction rolled back due to error" -Level WARNING
            }
            catch {
                Write-Log "ROLLBACK failed: $_" -Level ERROR
            }
        }
        $Script:Stats.Errors++
        Write-Host "  ❌ ERROR: Database transaction failed: $_" -ForegroundColor Red
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
Write-Log "Summary: Renamed=$($Script:Stats.Renamed); TypeChanged=$($Script:Stats.TypeChanged); ImageChanged=$($Script:Stats.ImageChanged); Unchanged=$($Script:Stats.Unchanged); Missing=$($Script:Stats.Missing); Excluded=$($Script:Stats.Excluded); Collisions=$($Script:Stats.Collisions); Errors=$($Script:Stats.Errors)" -Level INFO

# Write output files
$LogPrimary = $LogFile
$LogDbFallback = Join-Path $DbFolder ("rename_log-{0}.txt" -f $Timestamp)
$LogTempFallback = Join-Path $TempDir ("rename_log-{0}.txt" -f $Timestamp)

$CsvPrimary = $CsvFile
$CsvDbFallback = Join-Path $DbFolder ("rename_summary-{0}.csv" -f $Timestamp)
$CsvTempFallback = Join-Path $TempDir ("rename_summary-{0}.csv" -f $Timestamp)

# Write debug log
$finalLogPath = Write-SafeFile -PrimaryPath $LogPrimary -FallbackDbPath $LogDbFallback -FallbackTempPath $LogTempFallback -Description "Debug log" -Writer {
    param([string]$Path)
    $Script:DebugLog.ToArray() | Out-File -FilePath $Path -Encoding utf8
}

# Write CSV (only if explicitly requested AND changes were made)
$finalCsvPath = $null
if (-not [string]::IsNullOrWhiteSpace($CsvFile) -and $Script:RenameList.Count -gt 0) {
    $finalCsvPath = Write-SafeFile -PrimaryPath $CsvPrimary -FallbackDbPath $CsvDbFallback -FallbackTempPath $CsvTempFallback -Description "Renaming summary" -Writer {
        param([string]$Path)
        $Script:RenameList.ToArray() | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    }
}

# Write undo script (only if changes were made and not dry run)
$finalUndoPath = $null
if (-not $DryRun -and $Script:UndoStatements.Count -gt 0) {
    $UndoDbFallback = Join-Path $DbFolder ("undo_rename-{0}.sql" -f $Timestamp)
    $UndoTempFallback = Join-Path $TempDir ("undo_rename-{0}.sql" -f $Timestamp)

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

# Write HTML report (always generated by default)
$HtmlPrimary = $HtmlReport
$HtmlDbFallback = Join-Path $DbFolder ("rename_report-{0}.html" -f $Timestamp)
$HtmlTempFallback = Join-Path $TempDir ("rename_report-{0}.html" -f $Timestamp)

$finalHtmlPath = Write-SafeFile -PrimaryPath $HtmlPrimary -FallbackDbPath $HtmlDbFallback -FallbackTempPath $HtmlTempFallback -Description "HTML report" -Writer {
    param([string]$Path)
    New-HtmlReport -OutputPath $Path -Stats $Script:Stats -RenameList $Script:RenameList -Collisions $Script:NameCollisions -ResolvedCollisions $Script:ResolvedCollisions -AmbiguousDevices $Script:AmbiguousDevices -BackupPath $BackupPath -WasDryRun $DryRun
}

$Script:Stopwatch.Stop()

Write-Host ""

# Final summary box
$summaryContent = [ordered]@{
    Renamed      = $Script:Stats.Renamed
    TypeChanged  = $Script:Stats.TypeChanged
    ImageChanged = $Script:Stats.ImageChanged
    Unchanged    = $Script:Stats.Unchanged
    Excluded     = $Script:Stats.Excluded
    Collisions   = $Script:Stats.Collisions
    Errors       = $Script:Stats.Errors
}

# Only surfaced when it has something to say, so the usual run's summary box is
# byte-identical to previous versions.
if ($Script:Stats.Ambiguous -gt 0) {
    $summaryContent.Insert(5, 'Ambiguous', $Script:Stats.Ambiguous)
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
$totalChanges = $Script:Stats.Renamed + $Script:Stats.TypeChanged + $Script:Stats.ImageChanged
if ($Script:Stats.Errors -gt 0) {
    exit $Script:ExitCodes.PartialSuccess
}
elseif ($totalChanges -eq 0) {
    exit $Script:ExitCodes.NoChanges
}
else {
    exit $Script:ExitCodes.Success
}

#endregion