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
$runCommand = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f `
    "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe", `
    (Join-Path $baseDir 'firstboot.ps1')

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

New-Item -Path $runKeyPath -Force | Out-Null
Set-ItemProperty -Path $runKeyPath -Name $runValueName -Value $runCommand

Write-Log -Level 'INFO' -Message ("Registered HKLM Run entry {0}." -f $runValueName)
exit 0
