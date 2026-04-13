[CmdletBinding()]
<#
.SYNOPSIS
Creates a bootable WinPE ISO from an existing WinPE work directory.

.DESCRIPTION
Use this after Build-WinPEAutoDeploy.ps1 when you want to test inside VMware, Hyper-V,
or any other VM platform that boots from ISO more easily than from USB.

This script does not rebuild boot.wim. It simply takes the already-prepared work directory
and asks MakeWinPEMedia.cmd to package it as an ISO.
#>
param(
    [ValidateSet('amd64')]
    [string]$Architecture = 'amd64',

    [string]$WinPEWorkDir = 'C:\WinPE_AutoDeploy_amd64',

    [string]$IsoPath,

    [string]$InstallWimPath,

    [string]$AdkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Keeps the behavior of external ADK tools consistent and fail-fast.
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

# Rebuilds the minimal ADK environment so MakeWinPEMedia.cmd can find oscdimg and related tools.
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

$mediaDir = Join-Path $WinPEWorkDir 'media'
$makeWinPEMediaPath = Join-Path $AdkRoot 'Windows Preinstallation Environment\MakeWinPEMedia.cmd'

if (-not (Test-Path -LiteralPath $mediaDir)) {
    throw "The WinPE media directory was not found at $mediaDir. Build the work directory first."
}

if (-not (Test-Path -LiteralPath $makeWinPEMediaPath)) {
    throw "MakeWinPEMedia.cmd was not found at $makeWinPEMediaPath"
}

if (-not $IsoPath) {
    # Default the ISO name to the work-directory name so multiple builds are easier to distinguish.
    $isoName = '{0}.iso' -f (Split-Path -Leaf $WinPEWorkDir)
    $IsoPath = Join-Path $WinPEWorkDir $isoName
}

$isoDirectory = Split-Path -Parent $IsoPath
if ($isoDirectory -and -not (Test-Path -LiteralPath $isoDirectory)) {
    New-Item -ItemType Directory -Path $isoDirectory -Force | Out-Null
}

if (Test-Path -LiteralPath $IsoPath) {
    if (-not $Force) {
        throw "The ISO file already exists: $IsoPath. Re-run with -Force to overwrite it."
    }

    Remove-Item -LiteralPath $IsoPath -Force
}

if ($InstallWimPath) {
    if (-not (Test-Path -LiteralPath $InstallWimPath)) {
        throw "install.wim was not found at $InstallWimPath"
    }

    $sourceDir = Join-Path $mediaDir 'sources'
    if (-not (Test-Path -LiteralPath $sourceDir)) {
        New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
    }

    $destinationWimPath = Join-Path $sourceDir 'install.wim'
    Write-Host "Copying install.wim to $destinationWimPath..." -ForegroundColor Cyan
    Copy-Item -LiteralPath $InstallWimPath -Destination $destinationWimPath -Force

    $tagPath = Join-Path $sourceDir 'winpe-autodeploy.tag'
    Set-Content -LiteralPath $tagPath -Value @(
        'WinPE Auto Deploy Standalone ISO source'
        ('Created={0}' -f (Get-Date -Format s))
        ('SourceWim={0}' -f $InstallWimPath)
    ) -Encoding ASCII
}

if ($DockerImagesDirectory) {
    if (-not (Test-Path -LiteralPath $DockerImagesDirectory)) {
        throw "The Docker images directory was not found at $DockerImagesDirectory"
    }

    $dockerPayloadDir = Join-Path $mediaDir 'payload\docker-images'
    if (-not (Test-Path -LiteralPath $dockerPayloadDir)) {
        New-Item -ItemType Directory -Path $dockerPayloadDir -Force | Out-Null
    }

    Write-Host "Copying payload files to $dockerPayloadDir..." -ForegroundColor Cyan
    Copy-Item -Path "$DockerImagesDirectory\*" -Destination $dockerPayloadDir -Recurse -Force
}

# Package the already-customized WinPE media directory as a bootable ISO.
Write-Host "Packaging ISO..." -ForegroundColor Cyan
Invoke-ExternalCommand -FilePath $makeWinPEMediaPath -Arguments @(
    '/ISO',
    $WinPEWorkDir,
    $IsoPath
)

Write-Host ''
Write-Host "WinPE ISO created at $IsoPath" -ForegroundColor Green
Write-Host 'Attach this ISO to a UEFI virtual machine for deployment testing.' -ForegroundColor Green
