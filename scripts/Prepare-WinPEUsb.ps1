[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
<#
.SYNOPSIS
Creates the bootable dual-partition USB used by this project.

.DESCRIPTION
This script assumes Build-WinPEAutoDeploy.ps1 has already prepared a WinPE work directory.
It then turns a selected USB disk into:

- Partition 1: FAT32, bootable, contains the WinPE runtime.
- Partition 2: NTFS, contains \sources\install.wim and the marker file used by deploy.cmd.
- Optionally, \payload\docker-images\*.tar used by the first-logon importer inside the deployed OS.

Why two partitions:
- FAT32 keeps UEFI firmware boot compatibility high.
- NTFS avoids FAT32's 4 GB file-size limit for large install.wim images.

This script is intentionally destructive. It clears the selected USB disk before rebuilding it.
#>
param(
    [Parameter(Mandatory = $true)]
    [int]$UsbDiskNumber,

    [ValidateSet('amd64')]
    [string]$Architecture = 'amd64',

    [string]$WinPEWorkDir = 'C:\WinPE_AutoDeploy_amd64',

    [string]$InstallWimPath = 'C:\WorkSpace\Win11_Custom\install.wim',

    [string]$DockerImagesDirectory,

    [ValidateRange(1024, 32768)]
    [int]$BootPartitionSizeMB = 2048,

    [string]$AdkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Required because disk partitioning and formatting are privileged operations.
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Centralized wrapper for external commands so native tool failures become terminating errors.
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

# Matches the environment that ADK helper batch files expect even when launched from normal PowerShell.
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

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session.'
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

if (-not (Test-Path -LiteralPath $InstallWimPath)) {
    throw "install.wim was not found at $InstallWimPath"
}

if ($DockerImagesDirectory -and -not (Test-Path -LiteralPath $DockerImagesDirectory)) {
    throw "The Docker images directory was not found at $DockerImagesDirectory"
}

$installWim = Get-Item -LiteralPath $InstallWimPath
$disk = Get-Disk -Number $UsbDiskNumber -ErrorAction Stop

# Refuse obvious self-destruction scenarios first.
if ($disk.IsBoot -or $disk.IsSystem) {
    throw "Refusing to operate on disk $UsbDiskNumber because Windows reports it as a boot or system disk."
}

if ($disk.BusType -ne 'USB') {
    Write-Warning "Disk $UsbDiskNumber is reported as bus type $($disk.BusType), not USB. Verify the disk number carefully before continuing."
}

$requiredBytes = ([int64]$BootPartitionSizeMB * 1MB) + $installWim.Length + 1GB
if ($disk.Size -lt $requiredBytes) {
    throw "Disk $UsbDiskNumber is too small. Required at least $requiredBytes bytes for the configured boot partition and install.wim."
}

$targetDescription = "USB disk $UsbDiskNumber ($($disk.FriendlyName))"

if (-not $PSCmdlet.ShouldProcess($targetDescription, 'Create a dual-partition WinPE USB and copy install.wim')) {
    return
}

if ($disk.IsOffline) {
    Set-Disk -Number $UsbDiskNumber -IsOffline $false
}

if ($disk.IsReadOnly) {
    Set-Disk -Number $UsbDiskNumber -IsReadOnly $false
}

# Start with a clean removable disk so partition numbering and drive letters are predictable.
Write-Host "Wiping and preparing disk $UsbDiskNumber..." -ForegroundColor Yellow
Clear-Disk -Number $UsbDiskNumber -RemoveData -RemoveOEM -Confirm:$false

# Small sleep ensures Windows has recognized the 'uninitialized' state.
Start-Sleep -Seconds 2

# Force MBR style regardless of previous state.
$currentDisk = Get-Disk -Number $UsbDiskNumber
if ($currentDisk.PartitionStyle -eq 'RAW') {
    Initialize-Disk -Number $UsbDiskNumber -PartitionStyle MBR
} elseif ($currentDisk.PartitionStyle -ne 'MBR') {
    Set-Disk -Number $UsbDiskNumber -PartitionStyle MBR
}

# The first FAT32 partition is what firmware boots from.
$bootPartition = New-Partition -DiskNumber $UsbDiskNumber -Size ([int64]$BootPartitionSizeMB * 1MB) -AssignDriveLetter
Format-Volume -Partition $bootPartition -FileSystem FAT32 -NewFileSystemLabel 'WINPE' -Confirm:$false | Out-Null
Set-Partition -DiskNumber $UsbDiskNumber -PartitionNumber $bootPartition.PartitionNumber -IsActive $true

# The second NTFS partition stores the large WIM and marker file used by runtime source detection.
$imagePartition = New-Partition -DiskNumber $UsbDiskNumber -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $imagePartition -FileSystem NTFS -NewFileSystemLabel 'IMAGES' -Confirm:$false | Out-Null

$bootDriveLetter = (Get-Partition -DiskNumber $UsbDiskNumber -PartitionNumber $bootPartition.PartitionNumber | Get-Volume).DriveLetter
$imageDriveLetter = (Get-Partition -DiskNumber $UsbDiskNumber -PartitionNumber $imagePartition.PartitionNumber | Get-Volume).DriveLetter

if (-not $bootDriveLetter) {
    throw 'Failed to determine the boot partition drive letter.'
}

if (-not $imageDriveLetter) {
    throw 'Failed to determine the image partition drive letter.'
}

# Use Microsoft's helper to populate the FAT32 partition with the WinPE files.
Invoke-ExternalCommand -FilePath $makeWinPEMediaPath -Arguments @(
    '/UFD',
    $WinPEWorkDir,
    ("{0}:" -f $bootDriveLetter)
)

$imageDriveLetter = (Get-Partition -DiskNumber $UsbDiskNumber -PartitionNumber $imagePartition.PartitionNumber | Get-Volume).DriveLetter
if (-not $imageDriveLetter) {
    throw 'The image partition drive letter was lost after MakeWinPEMedia completed.'
}

$sourceDir = "{0}:\sources" -f $imageDriveLetter
New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null

$destinationWimPath = Join-Path $sourceDir 'install.wim'
Write-Host "Copying install.wim to $destinationWimPath" -ForegroundColor Cyan
Copy-Item -LiteralPath $InstallWimPath -Destination $destinationWimPath -Force

$tagPath = Join-Path $sourceDir 'winpe-autodeploy.tag'
# The marker file makes runtime source selection safer than "first install.wim found wins".
Set-Content -LiteralPath $tagPath -Value @(
    'WinPE Auto Deploy USB source'
    ('Created={0}' -f (Get-Date -Format s))
    ('SourceWim={0}' -f $InstallWimPath)
) -Encoding ASCII

if ($DockerImagesDirectory) {
    $dockerPayloadDir = "{0}:\payload\docker-images" -f $imageDriveLetter
    if (-not (Test-Path -LiteralPath $dockerPayloadDir)) {
        New-Item -ItemType Directory -Path $dockerPayloadDir -Force | Out-Null
    }

    Write-Host "Copying payload files to $dockerPayloadDir..." -ForegroundColor Cyan
    Copy-Item -Path "$DockerImagesDirectory\*" -Destination $dockerPayloadDir -Recurse -Force
}
Write-Host ''
Write-Host ('USB preparation completed.' ) -ForegroundColor Green
Write-Host ("Boot partition : {0}:" -f $bootDriveLetter) -ForegroundColor Green
Write-Host ("Image partition: {0}:\sources\install.wim" -f $imageDriveLetter) -ForegroundColor Green
if ($DockerImagesDirectory) {
    Write-Host ("Docker payload: {0}:\payload\docker-images" -f $imageDriveLetter) -ForegroundColor Green
}
Write-Host 'Boot the target machine from this USB device. WinPE will scan mounted volumes for \sources\install.wim and start deployment automatically.' -ForegroundColor Green
