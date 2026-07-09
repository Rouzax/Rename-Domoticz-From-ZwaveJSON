#Requires -Version 7.0

<#
.SYNOPSIS
    Fetches the pinned, hash-verified SQLite assemblies the renamer needs.

.DESCRIPTION
    Rename-Domoticz-From-ZwaveJSON.ps1 talks to the Domoticz SQLite database
    through Microsoft.Data.Sqlite, which in turn loads a native SQLite build via
    SQLitePCLRaw. This script downloads the exact package versions below from
    nuget.org, verifies each .nupkg against a pinned SHA-256, and extracts:

      - three RID-independent managed assemblies (netstandard2.0), and
      - the ONE native SQLite library that matches THIS machine's runtime
        identifier (linux-arm64, linux-x64, win-x64, osx-arm64, ...),

    into ./lib. That native selection is what makes the tool work on ARM
    (Raspberry Pi), which the older PSSQLite module could not do.

    Run this once per machine (and again after changing the pinned versions):

        pwsh ./setup.ps1

.PARAMETER LibDir
    Destination directory for the assemblies. Defaults to ./lib next to this
    script.

.PARAMETER Force
    Re-download and re-extract even if ./lib already looks complete.
#>
[CmdletBinding()]
param(
    [string]$LibDir = (Join-Path $PSScriptRoot 'lib'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- Pinned packages -------------------------------------------------------
# Managed assemblies are RID-independent (netstandard2.0). The native package
# ships e_sqlite3 for every runtime identifier; we extract only the one that
# matches this machine. Versions and hashes are pinned per the supply-chain
# policy: bumping a version means updating both the Version and the Sha256.
$ManagedPackages = @(
    @{ Id = 'SQLitePCLRaw.core'; Version = '3.0.3';
       Sha256 = '30bb8decacdf856c955f78b8a62e79290a7d27c251f37b020af79e52eb032aac';
       Assembly = 'SQLitePCLRaw.core.dll' }
    @{ Id = 'SQLitePCLRaw.provider.e_sqlite3'; Version = '3.0.3';
       Sha256 = '6eb54fbba60405b2ad7caadfe4f57cb03659b269591602f92ac7ba14fd35b85d';
       Assembly = 'SQLitePCLRaw.provider.e_sqlite3.dll' }
    @{ Id = 'Microsoft.Data.Sqlite.Core'; Version = '10.0.8';
       Sha256 = 'dc31e393411cfabf62134176a649c5c60993bab4472ef863c0e44a48eb335656';
       Assembly = 'Microsoft.Data.Sqlite.dll' }
)
$NativePackage = @{ Id = 'SQLitePCLRaw.lib.e_sqlite3'; Version = '3.53.3';
                    Sha256 = '72cb724779218e024833a21e2903c795a9e90c0bfa01520f27990c36413f32d4' }

# --- Resolve this machine's runtime identifier + native file name ----------
$archTag = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64'   { 'x64' }
    'Arm64' { 'arm64' }
    'Arm'   { 'arm' }
    'X86'   { 'x86' }
    default { throw "Unsupported CPU architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" }
}
if ($IsWindows)     { $osTag = 'win';   $NativeFileName = 'e_sqlite3.dll' }
elseif ($IsMacOS)   { $osTag = 'osx';   $NativeFileName = 'libe_sqlite3.dylib' }
else                { $osTag = 'linux'; $NativeFileName = 'libe_sqlite3.so' }
$rid = "$osTag-$archTag"

Write-Host "  Target runtime identifier: $rid" -ForegroundColor Cyan

# --- Helpers ---------------------------------------------------------------
function Get-VerifiedNupkg {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$OutFile
    )
    $lc = $Id.ToLowerInvariant()
    $url = "https://api.nuget.org/v3-flatcontainer/$lc/$Version/$lc.$Version.nupkg"
    Write-Host "  Downloading $Id $Version..." -ForegroundColor Gray
    Invoke-WebRequest -Uri $url -OutFile $OutFile

    $actual = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        throw "SHA-256 mismatch for $Id $Version.`n    expected $($Sha256.ToLowerInvariant())`n    actual   $actual`nRefusing to use this package."
    }
}

function Expand-NupkgEntry {
    param(
        [Parameter(Mandatory)][string]$NupkgPath,
        [Parameter(Mandatory)][string]$EntryName,
        [Parameter(Mandatory)][string]$OutFile
    )
    $zip = [System.IO.Compression.ZipFile]::OpenRead($NupkgPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $EntryName } | Select-Object -First 1
        if (-not $entry) { return $false }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $OutFile, $true)
        return $true
    }
    finally { $zip.Dispose() }
}

# --- Short-circuit if already provisioned ----------------------------------
$expected = @($ManagedPackages.Assembly + $NativeFileName)
$haveAll = (Test-Path -LiteralPath $LibDir) -and
           -not ($expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $LibDir $_)) })
if ($haveAll -and -not $Force) {
    Write-Host "  ✓ ./lib already provisioned for $rid (use -Force to refresh)." -ForegroundColor Green
    return
}

New-Item -ItemType Directory -Path $LibDir -Force | Out-Null
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("renamer-setup-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    # Managed assemblies (netstandard2.0 -> works on any PowerShell 7.x).
    foreach ($pkg in $ManagedPackages) {
        $nupkg = Join-Path $tmp ("{0}.nupkg" -f $pkg.Id)
        Get-VerifiedNupkg -Id $pkg.Id -Version $pkg.Version -Sha256 $pkg.Sha256 -OutFile $nupkg
        $ok = Expand-NupkgEntry -NupkgPath $nupkg -EntryName ("lib/netstandard2.0/{0}" -f $pkg.Assembly) -OutFile (Join-Path $LibDir $pkg.Assembly)
        if (-not $ok) { throw "Package $($pkg.Id) $($pkg.Version) has no lib/netstandard2.0/$($pkg.Assembly)." }
        Write-Host "  ✓ $($pkg.Assembly)" -ForegroundColor Green
    }

    # Native SQLite for this runtime identifier.
    $nupkg = Join-Path $tmp ("{0}.nupkg" -f $NativePackage.Id)
    Get-VerifiedNupkg -Id $NativePackage.Id -Version $NativePackage.Version -Sha256 $NativePackage.Sha256 -OutFile $nupkg
    $entry = "runtimes/$rid/native/$NativeFileName"
    $ok = Expand-NupkgEntry -NupkgPath $nupkg -EntryName $entry -OutFile (Join-Path $LibDir $NativeFileName)
    if (-not $ok) {
        throw "No native SQLite for '$rid' in $($NativePackage.Id) $($NativePackage.Version) (looked for $entry). This platform may be unsupported."
    }
    Write-Host "  ✓ $NativeFileName ($rid)" -ForegroundColor Green

    # Record what we provisioned, for diagnostics and future setup runs.
    $manifest = [ordered]@{
        rid      = $rid
        native   = @{ id = $NativePackage.Id; version = $NativePackage.Version }
        managed  = $ManagedPackages | ForEach-Object { @{ id = $_.Id; version = $_.Version } }
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $LibDir 'provisioned.json') -Encoding utf8

    Write-Host ""
    Write-Host "  ✓ SQLite assemblies ready in $LibDir" -ForegroundColor Green
    Write-Host "    You can now run Rename-Domoticz-From-ZwaveJSON.ps1" -ForegroundColor Gray
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
