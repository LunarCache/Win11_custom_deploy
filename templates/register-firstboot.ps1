[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This helper runs from SetupComplete.cmd inside the deployed OS.
# It registers a normal HKLM\Run entry instead of RunOnce so the Docker import can retry on
# later logons if Docker is not ready during the first attempt.

$baseDir = 'C:\ProgramData\FirstBoot'
$logPath = Join-Path $baseDir 'register-firstboot.log'
$runKeyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'CodexFirstBoot'
$launcherPath = Join-Path $baseDir 'firstboot-launcher.vbs'
$hiddenRunCommand = '"{0}" "{1}"' -f `
    "$env:SystemRoot\System32\wscript.exe", `
    $launcherPath

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

if (-not (Test-Path -LiteralPath $baseDir)) {
    New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
}

Write-Log -Level 'INFO' -Message 'Registering first-logon Docker payload importer.'

if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    Write-Log -Level 'WARNING' -Message ("Launcher script was not found: {0}" -f $launcherPath)
    exit 1
}

New-Item -Path $runKeyPath -Force | Out-Null
Set-ItemProperty -Path $runKeyPath -Name $runValueName -Value $hiddenRunCommand

$dockerPath = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
if (Test-Path -LiteralPath $dockerPath) {
    Set-ItemProperty -Path $runKeyPath -Name 'DockerDesktopAutoStart' -Value ('"{0}"' -f $dockerPath)
    Write-Log -Level 'INFO' -Message 'Registered Docker Desktop auto-start in HKLM Run for all users.'
} else {
    Write-Log -Level 'WARNING' -Message 'Docker Desktop executable not found during SYSTEM register phase.'
}

Write-Log -Level 'INFO' -Message ("Registered HKLM Run entry {0}." -f $runValueName)
exit 0
