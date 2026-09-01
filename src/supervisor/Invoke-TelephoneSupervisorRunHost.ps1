# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneSupervisor.Common.ps1')
if (-not $IsWindows) { throw 'Telephone Line v0.1 supports Windows only.' }

$resolvedState = Resolve-TelephoneSupervisorStateRoot -StateRoot $StateRoot
$claimedPath = Get-TelephoneSupervisorRecordPath -StateRoot $resolvedState -Kind claimed -RunId $RunId
$outboxPath = Get-TelephoneSupervisorRecordPath -StateRoot $resolvedState -Kind outbox -RunId $RunId
if ([IO.File]::Exists($outboxPath)) { exit 0 }
if (-not [IO.File]::Exists($claimedPath)) { throw 'Supervisor claimed request is missing.' }
$claimed = Read-TelephoneJson -Path $claimedPath -SchemaName 'wired-supervisor-request'
$request = $claimed.value
$null = Assert-TelephoneSupervisorRequestValue -Request $request
if ([string]$request.run_id -cne [string]$RunId) { throw 'Supervisor claimed run-id does not match.' }

$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID = [string]$RunId
$env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = [string]$resolvedState
$scriptRuntime = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$installCandidate = ''
if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
    $installCandidate = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
} elseif ($request.Contains('installed_version') -and $request.installed_version -is [Collections.IDictionary] -and $request.installed_version.Contains('install_root')) {
    $installCandidate = [IO.Path]::GetFullPath([string]$request.installed_version.install_root).TrimEnd('\')
} elseif (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_INSTALL_ROOT)) {
    $installCandidate = [IO.Path]::GetFullPath([string]$env:TELEPHONE_LINE_INSTALL_ROOT).TrimEnd('\')
} else {
    $installCandidate = $scriptRuntime
}
$versionId = ''
if ($request.Contains('installed_version') -and $request.installed_version -is [Collections.IDictionary] -and -not [string]::IsNullOrWhiteSpace([string]$request.installed_version.version_id)) {
    $versionId = [string]$request.installed_version.version_id
}
$identities = Resolve-TelephoneSupervisorInstallIdentities -InstallRoot $installCandidate -RuntimeRoot $scriptRuntime -VersionId $versionId
$env:TELEPHONE_LINE_INSTALL_ROOT = [string]$identities.pinned_runtime_root

$job = $null
$ownerWritten = $false
try {
    $job = New-TelephoneSupervisorRunJob -RunId $RunId
    $arguments = @($request.command.arguments | ForEach-Object { [string]$_ })
    $started = Start-TelephoneSupervisorLeadInJob -Job $job -Executable ([string]$request.command.executable) -WorkingDirectory ([string]$request.command.working_directory) -Arguments $arguments
    $hostProc = Get-Process -Id $PID
    try {
        $hostPid = [int]$hostProc.Id
        $hostTicks = [int64]$hostProc.StartTime.ToUniversalTime().Ticks
        $hostStartedAt = $hostProc.StartTime.ToUniversalTime().ToString('o')
    } finally {
        $hostProc.Dispose()
    }
    $leadIdentity = [ordered]@{
        pid = [int]$started.pid
        start_time_utc_ticks = [int64]$started.start_time_utc_ticks
        started_at_utc = [string]$started.started_at_utc
    }
    $owner = [ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-owner-v1'
        kind = 'run'
        run_id = [string]$RunId
        request_sha256 = [string]$request.request_sha256
        pid = [int]$hostPid
        start_time_utc_ticks = [int64]$hostTicks
        started_at_utc = [string]$hostStartedAt
        lead_pid = [int]$leadIdentity.pid
        lead_start_time_utc_ticks = [int64]$leadIdentity.start_time_utc_ticks
        lead_started_at_utc = [string]$leadIdentity.started_at_utc
        job_name = [string]$job.name
        project = [string]$request.project
        stage = [string]$request.stage
        lead_session_id = [string]$request.lead_session_id
        installed_version = [ordered]@{
            version_id = [string]$request.installed_version.version_id
            source_sha256 = [string]$request.installed_version.source_sha256
        }
    }
    if ($request.Contains('lead_run_id') -and -not [string]::IsNullOrWhiteSpace([string]$request.lead_run_id)) {
        $owner.lead_run_id = [string]$request.lead_run_id
    }
    $null = Write-TelephoneSupervisorRunOwner -StateRoot $resolvedState -Owner $owner
    $ownerWritten = $true
    $paths = Get-TelephoneSupervisorPaths -StateRoot $resolvedState
    $runDir = Join-Path $paths.runs $RunId
    $memberPath = Join-Path $runDir 'job-members.json'
    $stopPath = Join-Path $runDir 'stop.requested'
    $null = Write-TelephoneSupervisorJobMembers -Path $memberPath -RunId $RunId -Job $job -LeadIdentity $leadIdentity
    $terminal = 'completed'
    $relayScript = Join-Path ([string]$identities.pinned_runtime_root) 'src\core\Invoke-TelephoneLineRelay.ps1'
    while ($true) {
        $null = Write-TelephoneSupervisorJobMembers -Path $memberPath -RunId $RunId -Job $job -LeadIdentity $leadIdentity
        try {
            $null = Sync-TelephoneSupervisorMailboxBinding -StateRoot $resolvedState -RunId $RunId -Job $job -RelayScript $relayScript
        } catch { }
        if ([IO.File]::Exists($stopPath)) {
            $null = Stop-TelephoneSupervisorRunJob -Job $job
            $terminal = 'cancelled'
            while (@(Get-TelephoneSupervisorJobProcessIds -Job $job).Count -gt 0) {
                Start-Sleep -Milliseconds 50
            }
            break
        }
        $remaining = @(Get-TelephoneSupervisorJobProcessIds -Job $job)
        if ($remaining.Count -eq 0) {
            $terminal = 'completed'
            break
        }
        Start-Sleep -Milliseconds 200
    }
    $null = Write-TelephoneSupervisorOutbox -StateRoot $resolvedState -RunId $RunId -Terminal $terminal -Request $request
} catch {
    if (-not [IO.File]::Exists($outboxPath)) {
        $null = Write-TelephoneSupervisorOutbox -StateRoot $resolvedState -RunId $RunId -Terminal 'failed' -Request $request -ErrorCode 'SUPERVISOR_RUN_FAILED'
    }
    if (-not $ownerWritten) { throw }
} finally {
    Close-TelephoneSupervisorRunJob -Job $job
    if (-not [string]::IsNullOrWhiteSpace([string]$identities.base_install_root)) {
        Invoke-TelephoneSupervisorIdleVersionActivation -InstallRoot ([string]$identities.base_install_root) -StateRoot $resolvedState
    }
}
exit 0
