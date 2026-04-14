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
$dockerDesktopRunKeyPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$dockerDesktopRunValueName = 'DockerDesktopAutoStart'
$timingFilePath = Join-Path $baseDir 'install-timing.json'
$timingHelperPath = Join-Path $baseDir 'Update-InstallTiming.ps1'

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

function Complete-FirstBootSetup {
    New-Item -ItemType File -Path $markerPath -Force | Out-Null
    Remove-RunRegistration
}

function Update-TimingState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Start', 'Complete', 'Status')]
        [string]$Event,

        [string]$Status,
        [string]$Result
    )

    if (-not (Get-Command Update-InstallTiming -ErrorAction SilentlyContinue)) {
        return
    }

    $parameters = @{
        TimingFilePath = $timingFilePath
        Phase          = $Phase
        Event          = $Event
    }

    if ($PSBoundParameters.ContainsKey('Status')) {
        $parameters.Status = $Status
    }

    if ($PSBoundParameters.ContainsKey('Result')) {
        $parameters.Result = $Result
    }

    Update-InstallTiming @parameters
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

function Resolve-DockerDesktopGuiPath {
    $candidatePaths = @(
        'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    )

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            return $candidatePath
        }
    }

    return $null
}

function Set-DockerDesktopAutoStart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DockerDesktopPath
    )

    $runCommand = '"{0}"' -f $DockerDesktopPath
    New-Item -Path $dockerDesktopRunKeyPath -Force | Out-Null

    $currentValue = $null
    try {
        $currentValue = (Get-ItemProperty -Path $dockerDesktopRunKeyPath -Name $dockerDesktopRunValueName -ErrorAction Stop).$dockerDesktopRunValueName
    }
    catch {
        $currentValue = $null
    }

    if ($currentValue -ne $runCommand) {
        Set-ItemProperty -Path $dockerDesktopRunKeyPath -Name $dockerDesktopRunValueName -Value $runCommand
        Write-Log -Level 'INFO' -Message ("Configured Docker Desktop auto-start in HKCU Run: {0}" -f $runCommand)
    }
    else {
        Write-Log -Level 'INFO' -Message 'Docker Desktop auto-start is already configured in HKCU Run.'
    }
}

function Start-DockerDesktopBackground {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DockerExe,

        [Parameter()]
        [string]$DockerDesktopPath
    )

    try {
        Write-Log -Level 'INFO' -Message 'Starting Docker Desktop with "docker desktop start"...'
        & $DockerExe desktop start *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Log -Level 'INFO' -Message '"docker desktop start" returned exit code 0.'
            return
        }

        Write-Log -Level 'WARNING' -Message ('"docker desktop start" returned exit code {0}. Falling back to direct process start.' -f $LASTEXITCODE)
    }
    catch {
        Write-Log -Level 'WARNING' -Message ('Failed to execute "docker desktop start": {0}. Falling back to direct process start.' -f $_.Exception.Message)
    }

    if ($DockerDesktopPath) {
        Write-Log -Level 'INFO' -Message ("Starting Docker Desktop directly: {0}" -f $DockerDesktopPath)
        Start-Process -FilePath $DockerDesktopPath -WindowStyle Hidden
    }
    else {
        Write-Log -Level 'WARNING' -Message 'Docker Desktop executable was not found for direct fallback start.'
    }
}

function Wait-DockerDesktopProcess {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $desktopProcess = Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue
        if ($desktopProcess) {
            Write-Log -Level 'INFO' -Message ("Docker Desktop process detected on attempt {0}/10." -f $attempt)
            return $true
        }

        Write-Log -Level 'INFO' -Message ("Docker Desktop process not detected yet (attempt {0}/10). Waiting 2 seconds." -f $attempt)
        Start-Sleep -Seconds 2
    }

    return $false
}

function Wait-DockerDaemonReadyShort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DockerExe
    )

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

    $waitScheduleSeconds = @(2, 2, 3, 5, 8, 8)
    for ($attempt = 0; $attempt -lt $waitScheduleSeconds.Count; $attempt++) {
        & $DockerExe info *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Log -Level 'INFO' -Message ("Docker daemon became ready on attempt {0}/{1}." -f ($attempt + 1), $waitScheduleSeconds.Count)
            return $true
        }

        $waitSeconds = $waitScheduleSeconds[$attempt]
        Write-Log -Level 'INFO' -Message ("Docker daemon not ready yet (attempt {0}/{1}). Waiting {2} seconds." -f ($attempt + 1), $waitScheduleSeconds.Count, $waitSeconds)
        Start-Sleep -Seconds $waitSeconds
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

if (Test-Path -LiteralPath $timingHelperPath) {
    . $timingHelperPath
}

Write-Log -Level 'INFO' -Message 'First-logon setup started.'
Update-TimingState -Phase 'first_logon' -Event Start

if (Test-Path -LiteralPath $markerPath) {
    Write-Log -Level 'INFO' -Message 'Marker file already exists. Cleaning up Run registration and exiting.'
    Remove-RunRegistration
    exit 0
}

if (-not (Test-Path -LiteralPath $dockerPayloadDir)) {
    Write-Log -Level 'INFO' -Message 'No payload directory exists at C:\Payload\DockerImages. Skipping setup.'
    Update-TimingState -Phase 'payloads' -Event Start
    Update-TimingState -Phase 'payloads' -Event Complete -Status 'skipped'
    Update-TimingState -Phase 'first_logon' -Event Complete -Status 'success'
    Update-TimingState -Phase 'overall' -Event Complete -Result 'success'
    Complete-FirstBootSetup
    exit 0
}

$dockerExe = Resolve-DockerCommand
if (-not $dockerExe) {
    Write-Log -Level 'WARNING' -Message 'docker.exe was not found. Setup will retry on the next logon.'
    Update-TimingState -Phase 'first_logon' -Event Status -Status 'retry_pending'
    exit 1
}

$dockerDesktopPath = Resolve-DockerDesktopGuiPath
if ($dockerDesktopPath) {
    Set-DockerDesktopAutoStart -DockerDesktopPath $dockerDesktopPath
}
else {
    Write-Log -Level 'WARNING' -Message 'Docker Desktop executable was not found. Auto-start registration was skipped.'
}

Start-DockerDesktopBackground -DockerExe $dockerExe -DockerDesktopPath $dockerDesktopPath

if (-not (Wait-DockerDesktopProcess)) {
    Write-Log -Level 'WARNING' -Message 'Docker Desktop process did not appear after startup. Setup will retry on the next logon.'
    Update-TimingState -Phase 'first_logon' -Event Status -Status 'retry_pending'
    exit 1
}

if (-not (Wait-DockerDaemonReadyShort -DockerExe $dockerExe)) {
    Write-Log -Level 'WARNING' -Message 'Docker Desktop process started but the Docker daemon never became ready. Setup will retry on the next logon.'
    Update-TimingState -Phase 'first_logon' -Event Status -Status 'retry_pending'
    exit 1
}

$payloadFailed = $false
Update-TimingState -Phase 'payloads' -Event Start

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
    Update-TimingState -Phase 'payloads' -Event Status -Status 'retry_pending'
    Update-TimingState -Phase 'first_logon' -Event Status -Status 'retry_pending'
    exit 1
}

Update-TimingState -Phase 'payloads' -Event Complete -Status 'success'
Update-TimingState -Phase 'first_logon' -Event Complete -Status 'success'
Update-TimingState -Phase 'overall' -Event Complete -Result 'success'
Complete-FirstBootSetup
Write-Log -Level 'INFO' -Message 'Payload setup completed successfully.'
exit 0
