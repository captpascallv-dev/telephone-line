# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$StateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneSupervisor.Common.ps1')
if (-not $IsWindows) { throw 'Telephone Line v0.1 supports Windows only.' }

$resolvedState = Resolve-TelephoneSupervisorStateRoot -StateRoot $StateRoot
$resolvedInstall = if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
    [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
} elseif (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_INSTALL_ROOT)) {
    [IO.Path]::GetFullPath([string]$env:TELEPHONE_LINE_INSTALL_ROOT).TrimEnd('\')
} else {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
}
$resolvedInstall = Assert-TelephoneSupervisorCanonicalRoot -Path (Get-TelephoneSupervisorBaseInstallRoot -Path $resolvedInstall) -Label 'Supervisor install root'

function Invoke-TelephoneControlPlaneRegisteredProjects {
    param([Parameter(Mandatory = $true)][string]$WakeScript)
    return (& $WakeScript -SupervisorStateRoot $resolvedState -InstallRoot $resolvedInstall | Out-String)
}

$paths = Initialize-TelephoneSupervisorLayout -StateRoot $resolvedState
$self = $null
$lock = Open-TelephoneSupervisorMutex -StateRoot $resolvedState
try {
    if (-not [bool]$lock.created) {
        $acquired=$false
        try { $acquired=[bool]$lock.mutex.WaitOne([TimeSpan]::FromSeconds(30)) } catch [Threading.AbandonedMutexException] { $acquired=$true }
        if(-not$acquired){[ordered]@{ok=$true;duplicate=$true;deferred=$true;launched=0}|ConvertTo-Json -Compress;exit 0}
        $lock.created=$true
    }
    $self = New-TelephoneSupervisorOwnerSnapshot -Kind supervisor
    try {
        $null = Write-TelephoneJsonCreateNew -Path $paths.supervisor_owner -Value $self
    } catch [IO.IOException] {
        $existing = (Read-TelephoneJson -Path $paths.supervisor_owner -SchemaName 'wired-supervisor-owner').value
        if ([int]$existing.pid -ne [int]$self.pid -or [int64]$existing.start_time_utc_ticks -ne [int64]$self.start_time_utc_ticks) {
            if (Test-TelephoneSupervisorExactOwner -Owner $existing) {
                [ordered]@{ ok = $true; duplicate = $true; launched = 0 } | ConvertTo-Json -Compress
                exit 0
            }
            $null = Write-TelephoneJsonReplace -Path $paths.supervisor_owner -Value $self
        }
    }
    $null = Reconcile-TelephoneSupervisorClaimed -StateRoot $resolvedState
    $controlPlane = [ordered]@{ scanned = 0; applied = 0; failed = 0; remaining_dirty = 0; projects = @() }

    function Start-TelephoneSupervisorClaimedHosts {
        $started = 0
        $pauseNow = Get-TelephoneSupervisorPause -StateRoot $resolvedState
        if ([bool]$pauseNow.paused_by_pascal) { return 0 }
        foreach ($file in @([IO.Directory]::EnumerateFiles($paths.inbox, '*.json') | Sort-Object)) {
            $name = [IO.Path]::GetFileNameWithoutExtension($file)
            try {
                $claimed = Claim-TelephoneSupervisorInbox -StateRoot $resolvedState -RunId $name
            } catch {
                continue
            }
            if ([bool]$claimed.terminal -or [bool]$claimed.replayed) { continue }
            $request = $claimed.record.value
            $runHost = Join-Path $PSScriptRoot 'Invoke-TelephoneSupervisorRunHost.ps1'
            $versionId = ''
            if ($request.Contains('installed_version') -and -not [string]::IsNullOrWhiteSpace([string]$request.installed_version.version_id)) {
                $versionId = [string]$request.installed_version.version_id
            }
            $identities = Resolve-TelephoneSupervisorInstallIdentities -InstallRoot $resolvedInstall -RuntimeRoot $resolvedInstall -VersionId $versionId
            if ([bool]$identities.distinct) {
                $pinnedHost = Join-Path $identities.pinned_runtime_root 'src\supervisor\Invoke-TelephoneSupervisorRunHost.ps1'
                if ([IO.File]::Exists($pinnedHost)) {
                    $runHost = $pinnedHost
                }
            }
            $null = Start-TelephoneSupervisorDetachedPowerShell -ScriptPath $runHost -Arguments @(
                '-StateRoot', $resolvedState,
                '-RunId', [string]$request.run_id,
                '-InstallRoot', [string]$identities.base_install_root
            )
            $started += 1
        }
        return $started
    }

    $launched = [int](Start-TelephoneSupervisorClaimedHosts)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    do {
        $launched += [int](Start-TelephoneSupervisorClaimedHosts)
        $inboxLeft = @([IO.Directory]::EnumerateFiles($paths.inbox, '*.json')).Count
        $pauseNow = Get-TelephoneSupervisorPause -StateRoot $resolvedState
        if ($inboxLeft -eq 0 -or [bool]$pauseNow.paused_by_pascal) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    $controlPlaneWake = Join-Path $resolvedInstall 'src\control-plane\Invoke-TelephoneControlPlaneWake.ps1'
    if (-not [IO.File]::Exists($controlPlaneWake)) { $controlPlaneWake = Join-Path $PSScriptRoot '..\control-plane\Invoke-TelephoneControlPlaneWake.ps1' }
    if ([IO.File]::Exists($controlPlaneWake)) {
        $drainPass = 0; $remainingDirty = 0
        do {
            $drainPass += 1
            try {
                $controlPlaneText = Invoke-TelephoneControlPlaneRegisteredProjects -WakeScript $controlPlaneWake
                if (-not [string]::IsNullOrWhiteSpace($controlPlaneText)) { $controlPlane = $controlPlaneText | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String }
            } catch {
                $controlPlane = [ordered]@{ scanned = 0; applied = 0; failed = 1; remaining_dirty = 0; projects = @([ordered]@{ project = 'control-plane'; ok = $false; error = [string]$_.Exception.Message }) }
            }
            $launched += [int](Start-TelephoneSupervisorClaimedHosts)
            $remainingDirty = [int]$controlPlane.remaining_dirty + @([IO.Directory]::EnumerateFiles($paths.inbox, '*.json')).Count
        } while ($remainingDirty -gt 0 -and $drainPass -lt 32)
        if ($remainingDirty -gt 0) { $controlPlane.failed = [int]$controlPlane.failed + 1; $controlPlane['drain_exhausted'] = $true }
        $controlPlane['drain_passes'] = $drainPass
    }
    Invoke-TelephoneSupervisorIdleVersionActivation -InstallRoot $resolvedInstall -StateRoot $resolvedState | Out-Null
    [ordered]@{ ok = ([int]$controlPlane.failed -eq 0); duplicate = $false; launched = [int]$launched; control_plane = $controlPlane } | ConvertTo-Json -Depth 32 -Compress
} finally {
    if ($null -ne $self -and [IO.File]::Exists($paths.supervisor_owner)) {
        try {
            $written = (Read-TelephoneJson -Path $paths.supervisor_owner).value
            if ([int]$written.pid -eq [int]$self.pid -and [int64]$written.start_time_utc_ticks -eq [int64]$self.start_time_utc_ticks) {
                [IO.File]::Delete($paths.supervisor_owner)
            }
        } catch { }
    }
    if ($null -ne $lock -and $null -ne $lock.mutex) {
        try { [void]$lock.mutex.ReleaseMutex() } catch { }
        $lock.mutex.Dispose()
    }
}
