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

    [string]$DockerImagesDirectory,

    [string]$AdkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$helpersPath = Join-Path $PSScriptRoot 'Common-WinPEHelpers.ps1'
. $helpersPath

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

$stagingRoot = $null
$packagingWorkDir = $WinPEWorkDir

# Package the already-customized WinPE media directory as a bootable ISO.
try {
    if ($InstallWimPath -or $DockerImagesDirectory) {
        $resolvedInstallWimPath = $null
        $resolvedDockerImagesDirectory = $null

        if ($InstallWimPath) {
            if (-not (Test-Path -LiteralPath $InstallWimPath)) {
                throw "install.wim was not found at $InstallWimPath"
            }

            $resolvedInstallWimPath = (Get-Item -LiteralPath $InstallWimPath).FullName
        }

        if ($DockerImagesDirectory) {
            if (-not (Test-Path -LiteralPath $DockerImagesDirectory)) {
                throw "The Docker images directory was not found at $DockerImagesDirectory"
            }

            $resolvedDockerImagesDirectory = (Get-Item -LiteralPath $DockerImagesDirectory).FullName
        }

        $stagingRoot = New-TemporaryDirectory -Prefix 'WinPEIsoStage'
        $packagingWorkDir = Join-Path $stagingRoot (Split-Path -Leaf $WinPEWorkDir)
        Write-Host "Creating temporary ISO staging tree at $packagingWorkDir..." -ForegroundColor Cyan
        Copy-Item -LiteralPath $WinPEWorkDir -Destination $packagingWorkDir -Recurse

        $stagingMediaDir = Join-Path $packagingWorkDir 'media'

        if ($resolvedInstallWimPath) {
            $sourceDir = Join-Path $stagingMediaDir 'sources'
            New-DirectoryIfMissing -Path $sourceDir

            $destinationWimPath = Join-Path $sourceDir 'install.wim'
            Write-Host "Copying install.wim to $destinationWimPath..." -ForegroundColor Cyan
            Copy-Item -LiteralPath $resolvedInstallWimPath -Destination $destinationWimPath -Force

            $tagPath = Join-Path $sourceDir 'winpe-autodeploy.tag'
            Write-WinPEAutoDeployTag -TagPath $tagPath -SourceLabel 'WinPE Auto Deploy Standalone ISO source' -SourceWimPath $resolvedInstallWimPath
        }

        if ($resolvedDockerImagesDirectory) {
            $dockerPayloadDir = Join-Path $stagingMediaDir 'payload\docker-images'
            Write-Host "Copying payload files to $dockerPayloadDir..." -ForegroundColor Cyan
            Copy-DockerPayloadTree -SourceDirectory $resolvedDockerImagesDirectory -DestinationDirectory $dockerPayloadDir
        }
    }

    Write-Host "Packaging ISO..." -ForegroundColor Cyan
    Invoke-ExternalCommand -FilePath $makeWinPEMediaPath -Arguments @(
        '/ISO',
        $packagingWorkDir,
        $IsoPath
    )
}
finally {
    if ($stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

Write-Host ''
Write-Host "WinPE ISO created at $IsoPath" -ForegroundColor Green
Write-Host 'Attach this ISO to a UEFI virtual machine for deployment testing.' -ForegroundColor Green
