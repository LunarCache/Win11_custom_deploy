[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This script is staged into the deployed operating system and runs on user logon
# until it completes successfully. Its job is to ensure the Docker daemon is ready
# and then execute the payload setup script (e.g. install_appstore.bat).

$baseDir = 'C:\ProgramData\FirstBoot'
$logPath = Join-Path $baseDir 'firstboot.log'
$payloadLogsDir = Join-Path $baseDir 'PayloadLogs'
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

function Mark-Completed {
    New-Item -ItemType File -Path $markerPath -Force | Out-Null
    Remove-RunRegistration
}

function New-PayloadLogPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath)
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    return Join-Path $payloadLogsDir ('{0}_{1}.log' -f $scriptName, $timestamp)
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

function Invoke-PayloadScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [switch]$VisibleWindow
    )

    $payloadLogPath = New-PayloadLogPath -ScriptPath $ScriptPath
    New-Item -ItemType File -Path $payloadLogPath -Force | Out-Null

    Write-Log -Level 'INFO' -Message ("Executing {0}: {1}" -f $DisplayName, $ScriptPath)
    Write-Log -Level 'INFO' -Message ("Payload log path: {0}" -f $payloadLogPath)

    try {
        $commandLine = 'call "{0}" "{1}"' -f $ScriptPath, $payloadLogPath

        $startProcessArgs = @{
            FilePath   = 'cmd.exe'
            ArgumentList = @('/d', '/c', $commandLine)
            Wait     = $true
            PassThru = $true
        }

        if ($VisibleWindow) {
            $startProcessArgs.WindowStyle = 'Normal'
        }
        else {
            $startProcessArgs.WindowStyle = 'Hidden'
        }

        $process = Start-Process @startProcessArgs
        if ($process.ExitCode -eq 0) {
            Write-Log -Level 'INFO' -Message ("{0} finished with exit code 0. Details: {1}" -f $DisplayName, $payloadLogPath)
            return $true
        }

        Write-Log -Level 'WARNING' -Message ("{0} finished with non-zero exit code {1}. Details: {2}. Setup will retry on the next logon." -f $DisplayName, $process.ExitCode, $payloadLogPath)
        return $false
    }
    catch {
        Write-Log -Level 'ERROR' -Message ("Failed to execute {0}: {1}. Intended payload log: {2}" -f $DisplayName, $_.Exception.Message, $payloadLogPath)
        return $false
    }
}

if (-not (Test-Path -LiteralPath $baseDir)) {
    New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $payloadLogsDir)) {
    New-Item -ItemType Directory -Path $payloadLogsDir -Force | Out-Null
}

Write-Log -Level 'INFO' -Message 'First-logon setup started.'

if (Test-Path -LiteralPath $markerPath) {
    Write-Log -Level 'INFO' -Message 'Marker file already exists. Cleaning up Run registration and exiting.'
    Remove-RunRegistration
    exit 0
}

if (-not (Test-Path -LiteralPath $dockerPayloadDir)) {
    Write-Log -Level 'INFO' -Message 'No payload directory exists at C:\Payload\DockerImages. Skipping setup.'
    Mark-Completed
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

$payloadFailed = $false

$loadImagesScript = Join-Path $dockerPayloadDir 'load_images.bat'
if (Test-Path -LiteralPath $loadImagesScript) {
    if (-not (Invoke-PayloadScript -ScriptPath $loadImagesScript -DisplayName 'docker image load script')) {
        $payloadFailed = $true
    }
}

$appstoreScript = Join-Path $dockerPayloadDir 'install_appstore.bat'
if (Test-Path -LiteralPath $appstoreScript) {
    # Start the batch script in a visible window so the user can see progress and the final 'pause'.
    if (-not (Invoke-PayloadScript -ScriptPath $appstoreScript -DisplayName 'appstore setup script' -VisibleWindow)) {
        $payloadFailed = $true
    }
}

if ($payloadFailed) {
    Write-Log -Level 'WARNING' -Message 'One or more payload scripts failed. Setup will retry on the next logon.'
    exit 1
}

Mark-Completed
Write-Log -Level 'INFO' -Message 'Payload setup completed successfully.'
exit 0
