[CmdletBinding()]
<#
.SYNOPSIS
    Builds a WinPE working directory and injects the automation files used by this project.

.DESCRIPTION
    This is the main "authoring" script for the WinPE image. It does not create a USB drive or
    an ISO by itself. Instead, it prepares a reusable WinPE work tree at $WinPEWorkDir and then:

    1. Bootstraps the ADK environment variables that Microsoft's batch files expect.
    2. Runs copype.cmd to stage the standard WinPE files.
    3. Mounts media\sources\boot.wim.
    4. Drops the rendered deployment files into Windows\System32 inside the mounted image.
    5. Also injects the first-logon automation templates used to import Docker payloads.
    6. Optionally embeds out-of-box drivers into the WinPE image for injection at deploy time.
    7. Commits the boot.wim changes so every future ISO or USB build reuses the same automation.

    The most common parameters you will customize are:
    -WimIndex          Which image inside install.wim should be applied.
    -TargetDisk        Which disk number on the target machine will be wiped and deployed.
                       Use 'auto' to select the first disk (disk 0), or specify a disk number directly.
    -DriversDirectory  Optional path to a local driver directory to embed into the WinPE image.

    Partition customization parameters:
    -WindowsPartitionSizeGB  Size of the Windows partition in GB. 0 = auto (use remaining space).
    -CreateDataPartition     If set, creates a Data partition after Windows using remaining space.
    -WindowsPartitionLabel   Custom label for the Windows partition (empty = no label).
    -DataPartitionLabel      Custom label for the Data partition (empty = default "Data").
    -RecoverySizeMB          Recovery partition size in MB (default: 1024).
#>
param(
    [ValidateSet('amd64')]
    [string]$Architecture = 'amd64',

    # Working directory for the WinPE build. Will be created if it does not exist.
    [string]$WinPEWorkDir = 'C:\WinPE_AutoDeploy_amd64',

    # Index of the image inside install.wim to apply during deployment.
    [int]$WimIndex = 1,

    # Target disk for deployment. 'auto' = selects the first disk (disk 0).
    # Specify a disk number directly to target a specific disk.
    [ValidateScript({
            if ($_ -eq 'auto') { return $true }
            if ($_ -match '^\d+$') { return $true }
            throw "TargetDisk must be 'auto' or a numeric disk number."
        })]
    [string]$TargetDisk = 'auto',

    # Root path of the Windows ADK installation.
    [string]$AdkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit',

    # Optional: path to a local driver directory to embed into the WinPE image.
    [string]$DriversDirectory,

    # Force: rebuild the work directory if it already exists.
    [switch]$Force,

    # Size of the Windows partition in GB. 0 = use all remaining space.
    [int]$WindowsPartitionSizeGB = 0,

    # If set, creates a D: partition after Windows using remaining space.
    [switch]$CreateDataPartition,

    # Custom label for the Windows partition. Empty = no label.
    [string]$WindowsPartitionLabel = '',

    # Custom label for the Data partition. Empty = default "Data".
    [string]$DataPartitionLabel = '',

    # Recovery partition size in MB.
    [int]$RecoverySizeMB = 1024
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$helpersPath = Join-Path $PSScriptRoot 'Common-WinPEHelpers.ps1'
. $helpersPath

# ── Template rendering ────────────────────────────────────────────────────────
# Replaces __TOKEN__ placeholders in batch/DiskPart/XML templates.
# Output is written as ASCII because WinPE batch scripts cannot handle BOM/UTF-8.
function Write-RenderedTemplate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplatePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter()]
        [hashtable]$Tokens = @{}
    )

    $content = Get-Content -LiteralPath $TemplatePath -Raw

    foreach ($entry in $Tokens.GetEnumerator()) {
        $content = $content.Replace($entry.Key, [string]$entry.Value)
    }

    $destinationDirectory = Split-Path -Parent $DestinationPath
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }

    $encoding = [System.Text.ASCIIEncoding]::new()
    [System.IO.File]::WriteAllText($DestinationPath, $content, $encoding)
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session.'
}

# Populate the same environment variables that "Deployment and Imaging Tools Environment" would set.
Set-AdkEnvironment -AdkRootPath $AdkRoot -TargetArchitecture $Architecture

$repoRoot = Split-Path -Parent $PSScriptRoot
$templatesDir = Join-Path $repoRoot 'templates'

# Validate that all required template files exist before starting the build.
foreach ($requiredTemplate in @(
        'deploy.cmd',
        'startnet.cmd',
        'firstboot.ps1',
        'firstboot-launcher.vbs',
        'register-firstboot.ps1',
        'SetupComplete.cmd'
    )) {
    $templatePath = Join-Path $templatesDir $requiredTemplate
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Missing template file: $templatePath"
    }
}

$copypePath = Join-Path $AdkRoot 'Windows Preinstallation Environment\copype.cmd'
$dismPath = Join-Path $env:DISMRoot 'Dism.exe'

if (-not (Test-Path -LiteralPath $copypePath)) {
    throw "copype.cmd was not found at $copypePath"
}

if (-not (Test-Path -LiteralPath $dismPath)) {
    throw "DISM was not found at $dismPath"
}

# ── Prepare work directory ────────────────────────────────────────────────────
if (Test-Path -LiteralPath $WinPEWorkDir) {
    if (-not $Force) {
        throw "The WinPE work directory already exists: $WinPEWorkDir. Re-run with -Force to rebuild it."
    }

    # Rebuilding is safer than trying to patch an unknown previous work tree in place.
    Write-Host "Removing existing work directory $WinPEWorkDir" -ForegroundColor Yellow
    Remove-Item -LiteralPath $WinPEWorkDir -Recurse -Force
}

$workDirParent = Split-Path -Parent $WinPEWorkDir
if ($workDirParent -and -not (Test-Path -LiteralPath $workDirParent)) {
    New-Item -ItemType Directory -Path $workDirParent -Force | Out-Null
}

Write-Host "Creating WinPE work directory..." -ForegroundColor Cyan
Invoke-ExternalCommand -FilePath $copypePath -Arguments @($Architecture, $WinPEWorkDir)

# ── Mount boot.wim ────────────────────────────────────────────────────────────
$bootWimPath = Join-Path $WinPEWorkDir 'media\sources\boot.wim'
$mountDir = Join-Path $WinPEWorkDir 'mount'

if (-not (Test-Path -LiteralPath $bootWimPath)) {
    throw "Expected boot.wim at $bootWimPath after copype, but it was not created."
}

New-Item -ItemType Directory -Path $mountDir -Force | Out-Null

$mounted = $false
$commitChanges = $false

try {
    Write-Host "Mounting boot.wim..." -ForegroundColor Cyan
    Invoke-ExternalCommand -FilePath $dismPath -Arguments @(
        '/Mount-Image',
        "/ImageFile:$bootWimPath",
        '/Index:1',
        "/MountDir:$mountDir"
    )
    $mounted = $true

    $system32Dir = Join-Path $mountDir 'Windows\System32'

    # Build token map for template rendering.
    $tokens = @{
        '__TARGET_DISK__'             = $TargetDisk
        '__WIM_INDEX__'               = $WimIndex
        '__WINDOWS_PARTITION_SIZE__'  = $WindowsPartitionSizeGB
        '__CREATE_DRIVE_D__'          = if ($CreateDataPartition) { 1 } else { 0 }
        '__WINDOWS_PARTITION_LABEL__' = $WindowsPartitionLabel
        '__DATA_PARTITION_LABEL__'    = $DataPartitionLabel
        '__RECOVERY_SIZE__'           = $RecoverySizeMB
    }

    # Render and inject deployment templates into the mounted WinPE image.
    # install.wim itself stays on the deployment media and is discovered at runtime.
    Write-Host "Injecting deployment templates..." -ForegroundColor Cyan
    Write-RenderedTemplate -TemplatePath (Join-Path $templatesDir 'deploy.cmd') -DestinationPath (Join-Path $system32Dir 'deploy.cmd') -Tokens $tokens
    Write-RenderedTemplate -TemplatePath (Join-Path $templatesDir 'startnet.cmd') -DestinationPath (Join-Path $system32Dir 'startnet.cmd')
    Write-RenderedTemplate -TemplatePath (Join-Path $templatesDir 'firstboot.ps1') -DestinationPath (Join-Path $system32Dir 'firstboot.ps1')
    Write-RenderedTemplate -TemplatePath (Join-Path $templatesDir 'firstboot-launcher.vbs') -DestinationPath (Join-Path $system32Dir 'firstboot-launcher.vbs')
    Write-RenderedTemplate -TemplatePath (Join-Path $templatesDir 'register-firstboot.ps1') -DestinationPath (Join-Path $system32Dir 'register-firstboot.ps1')
    Write-RenderedTemplate -TemplatePath (Join-Path $templatesDir 'SetupComplete.cmd') -DestinationPath (Join-Path $system32Dir 'SetupComplete.cmd')
    Write-RenderedTemplate -TemplatePath (Join-Path $templatesDir 'unattend.xml') -DestinationPath (Join-Path $system32Dir 'unattend.xml')

    # Embed drivers into the WinPE image if a driver directory was specified.
    # Drivers are stored at X:\Windows\System32\drivers-payload and injected
    # into the target Windows Driver Store at deploy time via DISM /Add-Driver.
    if ($DriversDirectory) {
        if (-not (Test-Path -LiteralPath $DriversDirectory)) {
            throw "Drivers directory not found: $DriversDirectory"
        }

        $driversPayloadDir = Join-Path $system32Dir 'drivers-payload'
        Write-Host "Embedding drivers from $DriversDirectory..." -ForegroundColor Cyan

        if (-not (Test-Path -LiteralPath $driversPayloadDir)) {
            New-Item -ItemType Directory -Path $driversPayloadDir -Force | Out-Null
        }

        $xcopyArgs = @(
            "`"$DriversDirectory\*`"",
            "`"$driversPayloadDir\`"",
            '/S', '/E', '/Y', '/Q'
        )
        $xcopyExitCode = Start-Process -FilePath 'xcopy.exe' -ArgumentList $xcopyArgs -NoNewWindow -Wait -PassThru | Select-Object -ExpandProperty ExitCode
        if ($xcopyExitCode -ne 0) {
            throw "xcopy failed to copy drivers from $DriversDirectory to $driversPayloadDir (exit code: $xcopyExitCode)"
        }

        Write-Host "Drivers embedded successfully." -ForegroundColor Green
    }

    $commitChanges = $true
}
finally {
    if ($mounted) {
        $unmountMode = if ($commitChanges) { '/Commit' } else { '/Discard' }

        try {
            # Commit only if every earlier step succeeded; otherwise discard to avoid baking a half-edited WIM.
            Invoke-ExternalCommand -FilePath $dismPath -Arguments @(
                '/Unmount-Image',
                "/MountDir:$mountDir",
                $unmountMode
            )
        }
        catch {
            if ($unmountMode -eq '/Commit') {
                Write-Warning 'Failed to commit the mounted image. Attempting to discard the mount to avoid leaving it open.'
                Invoke-ExternalCommand -FilePath $dismPath -Arguments @(
                    '/Unmount-Image',
                    "/MountDir:$mountDir",
                    '/Discard'
                )
            }

            throw
        }
    }
}

Write-Host ''
Write-Host "WinPE work directory is ready at $WinPEWorkDir" -ForegroundColor Green
Write-Host 'Next step: run Prepare-WinPEUsb.ps1 from an elevated PowerShell session to create the dual-partition USB.' -ForegroundColor Green
