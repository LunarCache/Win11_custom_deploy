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
5. Commits the boot.wim changes so every future ISO or USB build reuses the same automation.

The two most common parameters you will customize later are:
-WimIndex   Which image inside install.wim should be applied.
-TargetDisk Which disk number on the target machine will be wiped and deployed.
#>
param(
    [ValidateSet('amd64')]
    [string]$Architecture = 'amd64',

    [string]$WinPEWorkDir = 'C:\WinPE_AutoDeploy_amd64',

    [int]$WimIndex = 1,

    [int]$TargetDisk = 0,

    [string]$AdkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Small helper used by the mutating scripts that must run elevated.
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Wraps external tools so failures stop the script immediately instead of being ignored.
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

# Recreates the ADK shell environment inside a normal PowerShell session.
# Microsoft tools such as copype.cmd and MakeWinPEMedia.cmd assume these variables exist.
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

# Renders a template file by replacing simple token strings such as __TARGET_DISK__.
# We write ASCII on purpose because the target files are batch/DiskPart scripts consumed by WinPE.
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

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session.'
}

# Populate the same environment variables that "Deployment and Imaging Tools Environment" would set.
Set-AdkEnvironment -AdkRootPath $AdkRoot -TargetArchitecture $Architecture

$repoRoot = Split-Path -Parent $PSScriptRoot
$templatesDir = Join-Path $repoRoot 'templates'

# All three templates are injected into boot.wim, so fail early if one is missing.
foreach ($requiredTemplate in @('deploy.cmd', 'diskpart-uefi.txt', 'startnet.cmd')) {
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

Invoke-ExternalCommand -FilePath $copypePath -Arguments @($Architecture, $WinPEWorkDir)

$bootWimPath = Join-Path $WinPEWorkDir 'media\sources\boot.wim'
$mountDir = Join-Path $WinPEWorkDir 'mount'

if (-not (Test-Path -LiteralPath $bootWimPath)) {
    throw "Expected boot.wim at $bootWimPath after copype, but it was not created."
}

New-Item -ItemType Directory -Path $mountDir -Force | Out-Null

$mounted = $false
$commitChanges = $false

try {
    # Mount the WinPE boot image so we can replace its startup files.
    Invoke-ExternalCommand -FilePath $dismPath -Arguments @(
        '/Mount-Image',
        "/ImageFile:$bootWimPath",
        '/Index:1',
        "/MountDir:$mountDir"
    )
    $mounted = $true

    $system32Dir = Join-Path $mountDir 'Windows\System32'
    $tokens = @{
        '__TARGET_DISK__' = $TargetDisk
        '__WIM_INDEX__'   = $WimIndex
    }

    # The boot image only receives small launcher/config files.
    # install.wim itself stays on the deployment media and is discovered at runtime.
    Write-RenderedTemplate -TemplatePath (Join-Path $templatesDir 'deploy.cmd') -DestinationPath (Join-Path $system32Dir 'deploy.cmd') -Tokens $tokens
    Write-RenderedTemplate -TemplatePath (Join-Path $templatesDir 'diskpart-uefi.txt') -DestinationPath (Join-Path $system32Dir 'diskpart-uefi.txt') -Tokens $tokens
    Write-RenderedTemplate -TemplatePath (Join-Path $templatesDir 'startnet.cmd') -DestinationPath (Join-Path $system32Dir 'startnet.cmd')

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
