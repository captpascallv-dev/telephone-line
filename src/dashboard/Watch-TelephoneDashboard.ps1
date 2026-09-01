# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$ConfigPath,
    [switch]$Headless,
    [switch]$Once,
    [ValidateRange(50, 60000)][int]$IntervalMilliseconds = 1000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneDashboard.Common.ps1')
. (Join-Path $PSScriptRoot 'TelephoneDashboard.Projection.ps1')

$root = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
$stateSafety = Test-TelephoneCompletePathChain -Path $root -AllowMissing -Label 'Dashboard state root'
if (-not [bool]$stateSafety.ok) {
    throw ('Dashboard state root refused: ' + [string]$stateSafety.error)
}
$root = [string]$stateSafety.path
[IO.Directory]::CreateDirectory($root) | Out-Null
$paths = Get-TelephoneDashboardPaths -StateRoot $root
foreach ($writePath in @([string]$paths.ensure_lock, [string]$paths.watcher, [string]$paths.projection, [string]$paths.summary)) {
    $writeSafety = Test-TelephoneCompletePathChain -Path $writePath -Root $root -AllowMissing -Label 'Dashboard runtime file'
    if (-not [bool]$writeSafety.ok) {
        throw ('Dashboard runtime path refused: ' + [string]$writeSafety.error)
    }
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = [string]$paths.config }
$watchScript = Get-TelephoneDashboardWatchScriptPath
$proc = Get-Process -Id $PID -ErrorAction Stop
try {
    $owner = [ordered]@{
        pid = [int]$PID
        start_time_utc_ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
        started_at_utc = $proc.StartTime.ToUniversalTime().ToString('o')
    }
} finally {
    $proc.Dispose()
}
$null = Write-TelephoneDashboardWatcherIdentity -Path $paths.watcher -Owner $owner -WatchScript $watchScript

function New-TelephoneDashboardFailClosedProjection {
    param([string]$Code = 'PROJECTION_FAILED')
    return [ordered]@{
        protocol_version = 'telephone-line-dashboard-projection-v1'
        observational = $true
        updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        config_present = $false
        stale = $true
        groups = @(
            [ordered]@{
                project = 'dashboard'
                lead_session_id = ''
                lead_run_id = ''
                phase = 'idle'
                visible = $true
                disappeared = $false
                color = 'yellow'
                lead = $false
                execution = $false
                final_audit = $false
                correction = $false
                closure = $false
                terminal = $false
                closure_receipt = ''
                line_job_id = ''
                stage = ''
                role = ''
                route = ''
                duplicate_count = 0
                provenance = ''
                findings = @([ordered]@{ code = [string]$Code; severity = 'fail_closed' })
            }
        )
    }
}

function Publish-TelephoneDashboardWatchOnce {
    param([switch]$Recover)
    $projection = $null
    $code = 'PROJECTION_FAILED'
    try {
        $injected = [string][Environment]::GetEnvironmentVariable('TELEPHONE_TEST_DASHBOARD_FAIL_AT')
        if (-not [string]::IsNullOrWhiteSpace($injected) -and -not $Recover) {
            throw $injected
        }
        $projection = Get-TelephoneDashboardProjection -ConfigPath $ConfigPath
        $jsonText = (($projection | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n")
        Assert-TelephoneJsonSchema -JsonText $jsonText -SchemaName 'dashboard-projection' -Label 'dashboard projection'
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -match 'schema|SCHEMA') { $code = 'SCHEMA_INVALID' }
        elseif ($message -match 'config|CONFIG') { $code = 'CONFIG_INVALID' }
        elseif ($message -ceq 'WRITE_FAILED') { $code = 'PUBLICATION_FAILED' }
        $projection = New-TelephoneDashboardFailClosedProjection -Code $code
    }
    try {
        if ([string][Environment]::GetEnvironmentVariable('TELEPHONE_TEST_DASHBOARD_FAIL_AT') -ceq 'WRITE_FAILED' -and -not $Recover) {
            throw 'WRITE_FAILED'
        }
        $jsonText = (($projection | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n")
        Assert-TelephoneJsonSchema -JsonText $jsonText -SchemaName 'dashboard-projection' -Label 'dashboard projection'
        $null = Write-TelephoneJsonReplace -Path $paths.projection -Value $projection
        $summary = Format-TelephoneDashboardSummary -Projection $projection
        $null = Write-TelephoneBytesReplace -Path $paths.summary -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($summary))
        if (-not $Headless) {
            Clear-Host
            Write-Output $summary.TrimEnd()
        }
        return $projection
    } catch {
        Invalidate-TelephoneDashboardWatcherIdentity -Path $paths.watcher
        throw
    }
}

if ($Once) {
    $null = Publish-TelephoneDashboardWatchOnce
    exit 0
}

while ($true) {
    try {
        $null = Publish-TelephoneDashboardWatchOnce
    } catch {
        try {
            $errorView = New-TelephoneDashboardFailClosedProjection -Code 'PUBLICATION_FAILED'
            $null = Write-TelephoneJsonReplace -Path $paths.projection -Value $errorView
            $null = Write-TelephoneBytesReplace -Path $paths.summary -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((Format-TelephoneDashboardSummary -Projection $errorView)))
        } catch {
            Invalidate-TelephoneDashboardWatcherIdentity -Path $paths.watcher
        }
    }
    Start-Sleep -Milliseconds $IntervalMilliseconds
}
