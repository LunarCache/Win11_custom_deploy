[CmdletBinding()]
param()

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-WinPEAutoDeployTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagPath,

        [Parameter(Mandatory = $true)]
        [string]$SourceLabel,

        [Parameter(Mandatory = $true)]
        [string]$SourceWimPath
    )

    Set-Content -LiteralPath $TagPath -Value @(
        $SourceLabel
        ('Created={0}' -f (Get-Date -Format s))
        ('SourceWim={0}' -f $SourceWimPath)
    ) -Encoding ASCII
}

function Copy-DockerPayloadTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory)) {
        throw "The Docker images directory was not found at $SourceDirectory"
    }

    Ensure-Directory -Path $DestinationDirectory
    Copy-Item -Path (Join-Path $SourceDirectory '*') -Destination $DestinationDirectory -Recurse -Force
}

function New-TemporaryDirectory {
    param(
        [string]$Prefix = 'WinPEAutoDeploy'
    )

    $tempRoot = [System.IO.Path]::GetTempPath()
    $directoryName = '{0}_{1}' -f $Prefix, ([System.Guid]::NewGuid().ToString('N'))
    $directoryPath = Join-Path $tempRoot $directoryName
    New-Item -ItemType Directory -Path $directoryPath -Force | Out-Null
    return $directoryPath
}
