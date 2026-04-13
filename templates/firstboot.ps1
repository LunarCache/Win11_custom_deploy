[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This script is staged into the deployed operating system and runs on user logon
# until it completes successfully. Its job is limited to importing Docker image tar
# files that were copied into C:\Payload\DockerImages during WinPE deployment.

$baseDir = 'C:\ProgramData\FirstBoot'
$logPath = Join-Path $baseDir 'firstboot.log'
$markerPath = Join-Path $baseDir 'done.tag'
$dockerPayloadDir = 'C:\Payload\DockerImages'
$runKeyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'CodexFirstBoot'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message
    Add-Content -LiteralPath $logPath -Value $line
}

function Remove-RunRegistration {
    Remove-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
}

function Resolve-DockerCommand {
    $dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($dockerCommand) {
        return $dockerCommand.Source
    }

    $commonDockerPath = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
    if (Test-Path -LiteralPath $commonDockerPath) {
        return $commonDockerPath
    }

    return $null
}

function Ensure-DockerReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DockerExe
    )

    # If Docker Desktop is installed, ensure the GUI is running to trigger daemon initialization.
    $dockerDesktopPath = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    if (Test-Path -LiteralPath $dockerDesktopPath) {
        $desktopProcess = Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue
        if (-not $desktopProcess) {
            Write-Log -Level 'INFO' -Message 'Starting Docker Desktop GUI...'
            Start-Process -FilePath $dockerDesktopPath
        }
    }

    foreach ($serviceName in @('com.docker.service', 'docker')) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            if ($service.Status -ne 'Running') {
                Start-Service -Name $serviceName -ErrorAction Stop
                Write-Log -Level 'INFO' -Message ("Started service {0}." -f $serviceName)
            }
        }
        catch {
            # Absence of a specific service name is acceptable because Docker packaging differs by product.
        }
    }

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        & $DockerExe info *> $null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }

        Write-Log -Level 'INFO' -Message ("Docker daemon not ready yet (attempt {0}/30). Waiting 10 seconds." -f $attempt)
        Start-Sleep -Seconds 10
    }

    return $false
}

if (-not (Test-Path -LiteralPath $baseDir)) {
    New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
}

Write-Log -Level 'INFO' -Message 'First-logon Docker payload import started.'

if (Test-Path -LiteralPath $markerPath) {
    Write-Log -Level 'INFO' -Message 'Marker file already exists. Cleaning up Run registration and exiting.'
    Remove-RunRegistration
    exit 0
}

if (-not (Test-Path -LiteralPath $dockerPayloadDir)) {
    Write-Log -Level 'INFO' -Message 'No Docker payload directory exists at C:\Payload\DockerImages. Skipping Docker image import.'
    New-Item -ItemType File -Path $markerPath -Force | Out-Null
    Remove-RunRegistration
    exit 0
}

$tarFiles = Get-ChildItem -LiteralPath $dockerPayloadDir -Filter *.tar -File -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $tarFiles) {
    Write-Log -Level 'INFO' -Message 'No Docker image tar files were found in C:\Payload\DockerImages. Skipping Docker image import.'
    New-Item -ItemType File -Path $markerPath -Force | Out-Null
    Remove-RunRegistration
    exit 0
}

$dockerExe = Resolve-DockerCommand
if (-not $dockerExe) {
    Write-Log -Level 'WARNING' -Message 'docker.exe was not found. The import will retry on the next logon.'
    exit 1
}

if (-not (Wait-DockerReady -DockerExe $dockerExe)) {
    Write-Log -Level 'WARNING' -Message 'Docker daemon never became ready. The import will retry on the next logon.'
    exit 1
}

foreach ($tarFile in $tarFiles) {
    Write-Log -Level 'INFO' -Message ("Importing Docker image tar: {0}" -f $tarFile.FullName)
    $output = & $dockerExe load -i $tarFile.FullName 2>&1
    $exitCode = $LASTEXITCODE

    foreach ($line in $output) {
        Add-Content -LiteralPath $logPath -Value $line
    }

    if ($exitCode -ne 0) {
        Write-Log -Level 'ERROR' -Message ("Docker import failed for {0}. The import will retry on the next logon." -f $tarFile.Name)
        exit 1
    }
}

$appstoreScript = Join-Path $dockerPayloadDir 'install_appstore.bat'
if (Test-Path -LiteralPath $appstoreScript) {
    Write-Log -Level 'INFO' -Message ("Executing appstore setup script: {0}" -f $appstoreScript)
    try {
        # Start the batch script in a visible window so the user can see progress and the final 'pause'.
        $process = Start-Process -FilePath $appstoreScript -Wait -PassThru
        Write-Log -Level 'INFO' -Message ("Appstore setup script finished with exit code {0}." -f $process.ExitCode)
    }
    catch {
        Write-Log -Level 'ERROR' -Message ("Failed to execute appstore setup script: {0}" -f $_.Exception.Message)
    }
}

New-Item -ItemType File -Path $markerPath -Force | Out-Null
Write-Log -Level 'INFO' -Message 'Docker payload import completed successfully.'
Remove-RunRegistration
exit 0
