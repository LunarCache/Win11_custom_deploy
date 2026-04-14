[CmdletBinding()]
param(
    [string]$TimingFilePath,
    [string]$Phase,
    [ValidateSet('Start', 'Complete', 'Status')]
    [string]$Event,
    [string]$Status,
    [string]$Result
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function New-PhaseState {
    return [ordered]@{
        started_at       = $null
        completed_at     = $null
        duration_seconds = $null
        status           = $null
    }
}

function New-InstallTimingState {
    return [ordered]@{
        started_at             = $null
        completed_at           = $null
        total_duration_seconds = $null
        result                 = $null
        phases                 = [ordered]@{
            deploy         = (New-PhaseState)
            setup_complete = (New-PhaseState)
            first_logon    = (New-PhaseState)
            payloads       = (New-PhaseState)
        }
    }
}

function ConvertTo-PlainData {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-PlainData -InputObject $InputObject[$key]
        }

        return $result
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-PlainData -InputObject $item)
        }

        return $items
    }

    if ($InputObject -is [psobject]) {
        $result = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-PlainData -InputObject $property.Value
        }

        return $result
    }

    return $InputObject
}

function Get-IsoTimestamp {
    return (Get-Date).ToString('o')
}

function Get-DurationSeconds {
    param(
        [string]$StartedAt,
        [string]$CompletedAt
    )

    if (-not $StartedAt -or -not $CompletedAt) {
        return $null
    }

    $start = [DateTimeOffset]::Parse($StartedAt)
    $end = [DateTimeOffset]::Parse($CompletedAt)
    return [math]::Round(($end - $start).TotalSeconds, 0)
}

function Initialize-TimingFileDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

function Read-InstallTimingState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return New-InstallTimingState
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return New-InstallTimingState
    }

    return ConvertTo-PlainData -InputObject ($raw | ConvertFrom-Json)
}

function Write-InstallTimingState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$State
    )

    Initialize-TimingFileDirectory -Path $Path
    $json = $State | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Update-InstallTiming {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TimingFilePath,

        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Start', 'Complete', 'Status')]
        [string]$Event,

        [string]$Status,
        [string]$Result
    )

    $state = Read-InstallTimingState -Path $TimingFilePath
    $timestamp = Get-IsoTimestamp

    if ([string]::IsNullOrWhiteSpace($Phase) -or $Phase -eq 'overall') {
        switch ($Event) {
            'Start' {
                if (-not $state.started_at) {
                    $state.started_at = $timestamp
                }
            }
            'Complete' {
                if (-not $state.started_at) {
                    $state.started_at = $timestamp
                }

                $state.completed_at = $timestamp
                $state.total_duration_seconds = Get-DurationSeconds -StartedAt $state.started_at -CompletedAt $state.completed_at
            }
            'Status' {
            }
        }

        if ($Result) {
            $state.result = $Result
        }
    }
    else {
        if (-not $state.phases.Contains($Phase)) {
            $state.phases[$Phase] = New-PhaseState
        }

        $phaseState = $state.phases[$Phase]
        switch ($Event) {
            'Start' {
                if (-not $phaseState.started_at) {
                    $phaseState.started_at = $timestamp
                }
            }
            'Complete' {
                if (-not $phaseState.started_at) {
                    $phaseState.started_at = $timestamp
                }

                $phaseState.completed_at = $timestamp
                $phaseState.duration_seconds = Get-DurationSeconds -StartedAt $phaseState.started_at -CompletedAt $phaseState.completed_at
            }
            'Status' {
            }
        }

        if ($Status) {
            $phaseState.status = $Status
        }
    }

    Write-InstallTimingState -Path $TimingFilePath -State $state
}

if ($PSBoundParameters.ContainsKey('TimingFilePath') -and $PSBoundParameters.ContainsKey('Event')) {
    Update-InstallTiming @PSBoundParameters
}
