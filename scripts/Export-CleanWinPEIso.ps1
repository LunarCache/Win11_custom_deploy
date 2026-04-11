[CmdletBinding()]
<#
.SYNOPSIS
Creates a clean WinPE ISO with no project-specific automation injected.

.DESCRIPTION
Use this when you need a plain WinPE boot image for maintenance work such as
capturing a new install.wim in a virtual machine. Unlike Build-WinPEAutoDeploy.ps1,
this script does not mount boot.wim or copy any custom batch/PowerShell files
into the image. It simply:

1. Recreates the ADK environment variables expected by Microsoft's helper scripts.
2. Runs copype.cmd to build a fresh WinPE work directory.
3. Uses oscdimg.exe to package that work directory as a bootable ISO.

The output defaults to C:\ so the generated paths do not contain spaces. This avoids
path-handling problems in copype.cmd and DISM while still keeping the clean ISO
separate from the automated deployment work tree.
#>
param(
    [ValidateSet('amd64')]
    [string]$Architecture = 'amd64',

    [string]$WinPEWorkDir,

    [string]$IsoPath,

    [string]$AdkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $WinPEWorkDir) {
    $WinPEWorkDir = 'C:\WinPE_Clean_amd64'
}

if (-not $IsoPath) {
    $IsoPath = 'C:\WinPE_Clean_amd64.iso'
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter()]
        [string[]]$Arguments = @()
    )

    Write-Host ('>> {0} {1}' -f $FilePath, ($Arguments -join ' ')) -ForegroundColor Cyan
    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw ("Command failed with exit code {0}: {1} {2}" -f $LASTEXITCODE, $FilePath, ($Arguments -join ' '))
    }
}

function Test-CleanWinPEMediaReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkDirectory
    )

    $requiredFiles = @(
        (Join-Path $WorkDirectory 'media\sources\boot.wim'),
        (Join-Path $WorkDirectory 'media\Boot\BCD'),
        (Join-Path $WorkDirectory 'media\EFI\Boot\bootx64.efi')
    )

    foreach ($path in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $path)) {
            return $false
        }
    }

    return $true
}

function Set-AdkEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdkRootPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetArchitecture
    )

    $deploymentToolsRoot = Join-Path $AdkRootPath 'Deployment Tools'
    $architectureToolsRoot = Join-Path $deploymentToolsRoot $TargetArchitecture
    $winPeRoot = Join-Path $AdkRootPath 'Windows Preinstallation Environment'

    $requiredPaths = @(
        $deploymentToolsRoot,
        $architectureToolsRoot,
        $winPeRoot,
        (Join-Path $architectureToolsRoot 'DISM'),
        (Join-Path $architectureToolsRoot 'BCDBoot'),
        (Join-Path $architectureToolsRoot 'Oscdimg')
    )

    foreach ($path in $requiredPaths) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Required ADK path was not found: $path"
        }
    }

    $env:DandIRoot = $deploymentToolsRoot
    $env:WinPERoot = $winPeRoot
    $env:WinPERootNoArch = $winPeRoot
    $env:WindowsSetupRootNoArch = Join-Path $AdkRootPath 'Windows Setup'
    $env:USMTRootNoArch = Join-Path $AdkRootPath 'User State Migration Tool'
    $env:DISMRoot = Join-Path $architectureToolsRoot 'DISM'
    $env:BCDBootRoot = Join-Path $architectureToolsRoot 'BCDBoot'
    $imagingRoot = Join-Path $architectureToolsRoot 'Imaging'
    $env:ImagingRoot = if (Test-Path -LiteralPath $imagingRoot) { $imagingRoot } else { $null }
    $env:OSCDImgRoot = Join-Path $architectureToolsRoot 'Oscdimg'
    $wdsmcastRoot = Join-Path $architectureToolsRoot 'Wdsmcast'
    $env:WdsmcastRoot = if (Test-Path -LiteralPath $wdsmcastRoot) { $wdsmcastRoot } else { $null }

    $adkToolPaths = @(
        $env:DISMRoot,
        $env:ImagingRoot,
        $env:BCDBootRoot,
        $env:OSCDImgRoot,
        $env:WdsmcastRoot,
        $env:WinPERoot
    ) | Where-Object { $_ }

    $existingPathEntries = @()
    if ($env:PATH) {
        $existingPathEntries = $env:PATH -split ';' | Where-Object { $_ }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $combinedPathEntries = [System.Collections.Generic.List[string]]::new()

    foreach ($pathEntry in @($adkToolPaths + $existingPathEntries)) {
        if ($pathEntry -and $seen.Add($pathEntry)) {
            [void]$combinedPathEntries.Add($pathEntry)
        }
    }

    $env:PATH = $combinedPathEntries -join ';'
}

Set-AdkEnvironment -AdkRootPath $AdkRoot -TargetArchitecture $Architecture

$copypePath = Join-Path $AdkRoot 'Windows Preinstallation Environment\copype.cmd'
$oscdimgPath = Join-Path $AdkRoot 'Deployment Tools\amd64\Oscdimg\oscdimg.exe'
$etfsbootPath = Join-Path $AdkRoot 'Deployment Tools\amd64\Oscdimg\etfsboot.com'
$efisysPath = Join-Path $AdkRoot 'Deployment Tools\amd64\Oscdimg\efisys.bin'

if (-not (Test-Path -LiteralPath $copypePath)) {
    throw "copype.cmd was not found at $copypePath"
}

foreach ($requiredToolPath in @($oscdimgPath, $etfsbootPath, $efisysPath)) {
    if (-not (Test-Path -LiteralPath $requiredToolPath)) {
        throw "Required ISO packaging tool was not found: $requiredToolPath"
    }
}

if (Test-Path -LiteralPath $WinPEWorkDir) {
    if (-not $Force) {
        throw "The clean WinPE work directory already exists: $WinPEWorkDir. Re-run with -Force to rebuild it."
    }

    Write-Host "Removing existing clean work directory $WinPEWorkDir" -ForegroundColor Yellow
    Remove-Item -LiteralPath $WinPEWorkDir -Recurse -Force
}

$workDirParent = Split-Path -Parent $WinPEWorkDir
if ($workDirParent -and -not (Test-Path -LiteralPath $workDirParent)) {
    New-Item -ItemType Directory -Path $workDirParent -Force | Out-Null
}

$isoDirectory = Split-Path -Parent $IsoPath
if ($isoDirectory -and -not (Test-Path -LiteralPath $isoDirectory)) {
    New-Item -ItemType Directory -Path $isoDirectory -Force | Out-Null
}

if (Test-Path -LiteralPath $IsoPath) {
    if (-not $Force) {
        throw "The clean WinPE ISO already exists: $IsoPath. Re-run with -Force to overwrite it."
    }

    Remove-Item -LiteralPath $IsoPath -Force
}

$copypeCompleted = $false

try {
    Invoke-ExternalCommand -FilePath $copypePath -Arguments @($Architecture, $WinPEWorkDir)
    $copypeCompleted = $true
}
catch {
    if (-not (Test-CleanWinPEMediaReady -WorkDirectory $WinPEWorkDir)) {
        throw
    }

    Write-Warning 'copype.cmd reported a mount-stage failure, but the WinPE media tree is present. Continuing with direct ISO packaging.'
}

$mediaDir = Join-Path $WinPEWorkDir 'media'
$bootData = '-bootdata:2#p0,e,b{0}#pEF,e,b{1}' -f $etfsbootPath, $efisysPath

Invoke-ExternalCommand -FilePath $oscdimgPath -Arguments @(
    '-m',
    '-o',
    '-u2',
    '-udfver102',
    $bootData,
    $mediaDir,
    $IsoPath
)

Write-Host ''
Write-Host "Clean WinPE work directory: $WinPEWorkDir" -ForegroundColor Green
Write-Host "Clean WinPE ISO created at $IsoPath" -ForegroundColor Green
if ($copypeCompleted) {
    Write-Host 'This ISO contains only the stock WinPE files generated by the ADK.' -ForegroundColor Green
}
else {
    Write-Host 'This ISO was packaged from the stock WinPE media tree after copype staged the files.' -ForegroundColor Green
}
