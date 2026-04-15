[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This script is staged into the deployed operating system and runs on user logon
# until it completes successfully. Its job is to ensure the Docker daemon is ready
# and then execute ordered payload service directories under C:\Payload\DockerImages.

$baseDir = 'C:\ProgramData\FirstBoot'
$logPath = Join-Path $baseDir 'firstboot.log'
$payloadLogsDir = Join-Path $baseDir 'PayloadLogs'
$markerPath = Join-Path $baseDir 'done.tag'
$dockerPayloadDir = 'C:\Payload\DockerImages'
$runKeyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'CodexFirstBoot'
$dockerDesktopRunKeyPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$dockerDesktopRunValueName = 'DockerDesktopAutoStart'

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

function New-PayloadLogPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter()]
        [string]$ServiceDirectoryName
    )

    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath)
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    if ($ServiceDirectoryName) {
        return Join-Path $payloadLogsDir ('{0}_{1}_{2}.log' -f $ServiceDirectoryName, $scriptName, $timestamp)
    }

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

        [Parameter()]
        [string]$ServiceDirectoryName,

        [switch]$VisibleWindow
    )

    $payloadLogPath = New-PayloadLogPath -ScriptPath $ScriptPath -ServiceDirectoryName $ServiceDirectoryName
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

function Get-OrderedPayloadDirectories {
    if (-not (Test-Path -LiteralPath $dockerPayloadDir -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $dockerPayloadDir -Directory |
            Where-Object { $_.Name -match '^\d{2}-.+' } |
            Sort-Object -Property Name
    )
}

function Invoke-PayloadService {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.DirectoryInfo]$ServiceDirectory
    )

    Write-Log -Level 'INFO' -Message ("Starting payload service directory: {0}" -f $ServiceDirectory.Name)

    $loadImagesScript = Join-Path $ServiceDirectory.FullName 'load_images.bat'
    $installServiceScript = Join-Path $ServiceDirectory.FullName 'install_service.bat'

    if (
        -not (Test-Path -LiteralPath $loadImagesScript -PathType Leaf) -and
        -not (Test-Path -LiteralPath $installServiceScript -PathType Leaf)
    ) {
        Write-Log -Level 'INFO' -Message ("Payload service directory {0} does not contain load_images.bat or install_service.bat. Skipping it." -f $ServiceDirectory.Name)
        return $true
    }

    if (Test-Path -LiteralPath $loadImagesScript) {
        if (-not (Invoke-PayloadScript -ScriptPath $loadImagesScript -DisplayName ("docker image load script ({0})" -f $ServiceDirectory.Name) -ServiceDirectoryName $ServiceDirectory.Name -VisibleWindow)) {
            return $false
        }
    }

    if (Test-Path -LiteralPath $installServiceScript) {
        if (-not (Invoke-PayloadScript -ScriptPath $installServiceScript -DisplayName ("service setup script ({0})" -f $ServiceDirectory.Name) -ServiceDirectoryName $ServiceDirectory.Name -VisibleWindow)) {
            return $false
        }

        if ($ServiceDirectory.Name -like '*win11-install') {
            $credentialInfo = Get-1PanelCredentialInfo
            Show-1PanelCredentialWindow -Url $credentialInfo.Url -Username $credentialInfo.Username -SecretValue $credentialInfo.Password
        }
        elseif ($ServiceDirectory.Name -like '*CIKE-install') {
            Show-CikeCredentialWindow
        }
    }

    Write-Log -Level 'INFO' -Message ("Payload service directory completed successfully: {0}" -f $ServiceDirectory.Name)
    return $true
}

function Get-1PanelCredentialInfo {
    $credentialInfo = [ordered]@{
        Url      = 'http://localhost:10086/entrance'
        Username = 'admin'
        Password = 'Cp@12345'
    }

    $composePath = 'C:\1Panel\docker-compose.yml'
    if (-not (Test-Path -LiteralPath $composePath)) {
        return $credentialInfo
    }

    try {
        foreach ($line in Get-Content -LiteralPath $composePath) {
            if ($line -match '^\s*-\s*"?(?<hostPort>\d+):\d+"?\s*$') {
                $credentialInfo.Url = 'http://localhost:{0}/entrance' -f $Matches.hostPort
                continue
            }

            if ($line -match '^\s*-\s*PANEL_USERNAME=(?<value>.+)\s*$') {
                $credentialInfo.Username = $Matches.value.Trim()
                continue
            }

            if ($line -match '^\s*-\s*PANEL_PASSWORD=(?<value>.+)\s*$') {
                $credentialInfo.Password = $Matches.value.Trim()
                continue
            }

            if ($line -match '^\s*-\s*PANEL_ENTRANCE=(?<value>.+)\s*$') {
                $entrance = $Matches.value.Trim()
                $credentialInfo.Url = $credentialInfo.Url -replace '/[^/]*$', "/$entrance"
            }
        }
    }
    catch {
        Write-Log -Level 'WARNING' -Message ("Failed to parse 1Panel credentials from docker-compose.yml: {0}" -f $_.Exception.Message)
    }

    return $credentialInfo
}

function Show-1PanelCredentialWindow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Username,

        [Parameter(Mandatory = $true)]
        [string]$SecretValue
    )

    $commandLine = @(
        'title 1Panel Credentials',
        'echo ==================================================',
        'echo.',
        'echo    1Panel Installation Complete!',
        ('echo    URL: {0}' -f $Url),
        ('echo    Username: {0}' -f $Username),
        ('echo    Password: {0}' -f $SecretValue),
        'echo.',
        'echo ==================================================',
        'pause'
    ) -join ' & '

    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/k', $commandLine) -WindowStyle Normal
    Write-Log -Level 'INFO' -Message 'Opened detached 1Panel credential window.'
}

function Show-CikeCredentialWindow {
    $commandLine = @(
        'title CIKE Deployment Complete',
        'echo ==================================================',
        'echo.',
        'echo    CIKE Deployment Complete!',
        'echo    CIKE Web: http://localhost:980',
        'echo    CIKE Admin Web: http://localhost:980/admin',
        'echo    CIKE Admin Account: admin@cloud.ai / admin',
        'echo.',
        'echo ==================================================',
        'pause'
    ) -join ' & '

    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/k', $commandLine) -WindowStyle Normal
    Write-Log -Level 'INFO' -Message 'Opened detached CIKE credential window.'
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
    Complete-FirstBootSetup
    exit 0
}

$payloadDirectories = @(Get-OrderedPayloadDirectories)
if ($payloadDirectories.Count -eq 0) {
    Write-Log -Level 'INFO' -Message 'No ordered payload service directories were found. Skipping setup.'
    Complete-FirstBootSetup
    exit 0
}

$dockerExe = Resolve-DockerCommand
if (-not $dockerExe) {
    Write-Log -Level 'WARNING' -Message 'docker.exe was not found. Setup will retry on the next logon.'
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
    exit 1
}

if (-not (Wait-DockerDaemonReadyShort -DockerExe $dockerExe)) {
    Write-Log -Level 'WARNING' -Message 'Docker Desktop process started but the Docker daemon never became ready. Setup will retry on the next logon.'
    exit 1
}

$payloadFailed = $false

foreach ($payloadDirectory in $payloadDirectories) {
    if (-not (Invoke-PayloadService -ServiceDirectory $payloadDirectory)) {
        $payloadFailed = $true
        break
    }
}

if ($payloadFailed) {
    Write-Log -Level 'WARNING' -Message 'One or more payload scripts failed. Setup will retry on the next logon.'
    exit 1
}

Complete-FirstBootSetup
Write-Log -Level 'INFO' -Message 'Payload setup completed successfully.'
exit 0
