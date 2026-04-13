[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This script is staged into the deployed operating system and runs on user logon
# until it completes successfully. Its job is to ensure the Docker daemon is ready
# and then execute the payload setup script (e.g. install_appstore.bat).

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

function Wait-DockerReady {
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

Write-Log -Level 'INFO' -Message 'First-logon setup started.'

if (Test-Path -LiteralPath $markerPath) {
    Write-Log -Level 'INFO' -Message 'Marker file already exists. Cleaning up Run registration and exiting.'
    Remove-RunRegistration
    exit 0
}

if (-not (Test-Path -LiteralPath $dockerPayloadDir)) {
    Write-Log -Level 'INFO' -Message 'No payload directory exists at C:\Payload\DockerImages. Skipping setup.'
    New-Item -ItemType File -Path $markerPath -Force | Out-Null
    Remove-RunRegistration
    exit 0
}

$dockerExe = Resolve-DockerCommand
if (-not $dockerExe) {
    Write-Log -Level 'WARNING' -Message 'docker.exe was not found. Setup will retry on the next logon.'
    exit 1
}

if (-not (Wait-DockerReady -DockerExe $dockerExe)) {
    Write-Log -Level 'WARNING' -Message 'Docker daemon never became ready. Setup will retry on the next logon.'
    exit 1
}

$loadImagesScript = Join-Path $dockerPayloadDir 'load_images.bat'
if (Test-Path -LiteralPath $loadImagesScript) {
    Write-Log -Level 'INFO' -Message ("Executing docker images load script: {0}" -f $loadImagesScript)
    try {
        $process = Start-Process -FilePath $loadImagesScript -Wait -PassThru
        Write-Log -Level 'INFO' -Message ("Load script finished with exit code {0}." -f $process.ExitCode)
    }
    catch {
        Write-Log -Level 'ERROR' -Message ("Failed to execute load script: {0}" -f $_.Exception.Message)
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
Write-Log -Level 'INFO' -Message 'Payload setup completed successfully.'
Remove-RunRegistration
exit 0
