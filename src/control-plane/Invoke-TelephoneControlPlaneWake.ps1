# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SupervisorStateRoot,
    [Parameter(Mandatory = $true)][string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneControlPlane.Common.ps1')

function Invoke-TelephoneControlPlaneRegisteredProjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SupervisorStateRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )
    $supervisor = [IO.Path]::GetFullPath($SupervisorStateRoot).TrimEnd('\')
    $install = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $registrations = Join-Path (Join-Path $supervisor 'control-plane') 'registrations'
    $dirtyRoot = Join-Path (Join-Path $supervisor 'control-plane') 'dirty'
    if (-not [IO.Directory]::Exists($dirtyRoot)) { [IO.Directory]::CreateDirectory($dirtyRoot) | Out-Null }
    $rows = [Collections.Generic.List[object]]::new()
    if (-not [IO.Directory]::Exists($registrations)) { return [ordered]@{ scanned = 0; applied = 0; failed = 0; remaining_dirty = 0; projects = @() } }
    foreach ($file in @([IO.Directory]::EnumerateFiles($registrations, '*.json') | Sort-Object)) {
        try {
            $registration = (Read-TelephoneJson -Path $file).value
            if ([string]$registration.protocol_version -cne 'telephone-line-control-plane-registration-v1' -or -not [bool]$registration.enabled) { continue }
            $projectKey = Get-TelephoneControlPlaneSha256 -Text ([string]$registration.project)
            $dirtyPath = Join-Path $dirtyRoot ($projectKey + '.json')
            $dirtyBefore = if ([IO.File]::Exists($dirtyPath)) { (Read-TelephoneJson -Path $dirtyPath).value } else { $null }
            $observedGeneration = if ($null -eq $dirtyBefore) { 0L } else { [int64]$dirtyBefore.generation }
            $ackGeneration = if ($null -eq $dirtyBefore) { -1L } else { [int64]$dirtyBefore.ack_generation }
            $timerDue = $false
            if ($null -ne $dirtyBefore -and -not [string]::IsNullOrWhiteSpace([string]$dirtyBefore.next_reconcile_at_utc)) { try { $timerDue = ([DateTimeOffset]::Parse([string]$dirtyBefore.next_reconcile_at_utc).ToUniversalTime() -le [DateTimeOffset]::UtcNow) } catch { $timerDue = $true } }
            if ($null -ne $dirtyBefore -and $observedGeneration -le $ackGeneration -and -not $timerDue) { [void]$rows.Add([ordered]@{ project=[string]$registration.project;ok=$true;applied=$false;executed=0;blocked=0;unresolved_actions=0;remaining_dirty=$false;skipped_until=[string]$dirtyBefore.next_reconcile_at_utc }); continue }
            $pointer = $null
            try { $pointer = Read-TelephoneJson -Path ([string]$registration.current_pointer) -SchemaName 'control-plane-current-pointer' } catch {
                $registeredManifest = Read-TelephoneJson -Path ([string]$registration.manifest.path) -SchemaName 'control-plane-wave-manifest'
                Assert-TelephoneFileIdentity -Expected $registration.manifest -Actual $registeredManifest.identity -Label 'Registered manifest for pointer recovery'
                $repairPaths = Get-TelephoneControlPlanePaths -ControlStateRoot ([string]$registeredManifest.value.control_state_root) -Project ([string]$registeredManifest.value.project) -ProjectEpoch ([string]$registeredManifest.value.project_epoch) -WaveId ([string]$registeredManifest.value.wave_id)
                $null = Repair-TelephoneControlPlanePointerFromRegistration -Manifest $registeredManifest.value -ManifestIdentity $registeredManifest.identity -Paths $repairPaths
                $pointer = Read-TelephoneJson -Path ([string]$registration.current_pointer) -SchemaName 'control-plane-current-pointer'
            }
            $manifestPath = [string]$pointer.value.manifest.path
            $manifestIdentity = Get-TelephoneFileIdentity -Path $manifestPath
            Assert-TelephoneFileIdentity -Expected $pointer.value.manifest -Actual $manifestIdentity -Label 'Control-plane registered manifest'
            $controller = Join-Path $install 'src\control-plane\Invoke-TelephoneContinuityController.ps1'
            $controller = Assert-TelephoneRegularFilePath -Path $controller -Label 'Installed continuity controller'
            $output = & $controller -ManifestFile $manifestPath -Apply | Out-String
            $parsed = $output | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
            $dirtyGate = Open-TelephoneExclusiveGate -Path ($dirtyPath + '.lock') -WaitMilliseconds 10000
            if ($null -eq $dirtyGate) { throw 'Control-plane dirty acknowledgment is already owned.' }
            try {
                $latest = if ([IO.File]::Exists($dirtyPath)) { (Read-TelephoneJson -Path $dirtyPath).value } else { [ordered]@{ generation=$observedGeneration;ack_generation=-1;reason='periodic-reconcile';dirty_at_utc=[DateTimeOffset]::UtcNow.ToString('o') } }
                $nextAt = if ($parsed.Contains('next_reconcile_at_utc')) { [string]$parsed.next_reconcile_at_utc } else { '' }
                $ack = [math]::Max([int64]$latest.ack_generation, $observedGeneration)
                $nextDirty = [ordered]@{ protocol_version='telephone-line-control-plane-dirty-v1';project=[string]$registration.project;generation=[int64]$latest.generation;ack_generation=$ack;reason=[string]$latest.reason;manifest=$pointer.value.manifest;dirty_at_utc=[string]$latest.dirty_at_utc;next_reconcile_at_utc=$nextAt }
                $null = Write-TelephoneJsonReplace -Path $dirtyPath -Value $nextDirty
                $remaining = ([int64]$nextDirty.generation -gt [int64]$nextDirty.ack_generation)
                if (-not $remaining -and -not [string]::IsNullOrWhiteSpace($nextAt)) { try { $remaining = ([DateTimeOffset]::Parse($nextAt).ToUniversalTime() -le [DateTimeOffset]::UtcNow) } catch { $remaining = $true } }
            } finally { $dirtyGate.Dispose() }
            [void]$rows.Add([ordered]@{ project = [string]$registration.project; ok = [bool]$parsed.healthy; applied = [bool]$parsed.applied; executed = @($parsed.executed).Count; blocked = @($parsed.blocked).Count; unresolved_actions = [int]$parsed.unresolved_action_count; remaining_dirty=$remaining; next_reconcile_at_utc=$nextAt; current_state = $parsed.current_state })
        } catch {
            [void]$rows.Add([ordered]@{ project = [IO.Path]::GetFileNameWithoutExtension($file); ok = $false; error = [string]$_.Exception.Message })
        }
    }
    return [ordered]@{ scanned = $rows.Count; applied = @($rows | Where-Object { [bool]$_.applied }).Count; failed = @($rows | Where-Object { -not [bool]$_.ok }).Count; remaining_dirty = @($rows | Where-Object { $_ -is [Collections.IDictionary] -and $_.Contains('remaining_dirty') -and [bool]$_['remaining_dirty'] }).Count; projects = @($rows.ToArray()) }
}

$result = Invoke-TelephoneControlPlaneRegisteredProjects -SupervisorStateRoot $SupervisorStateRoot -InstallRoot $InstallRoot
$result | ConvertTo-Json -Depth 32
if ([int]$result.failed -gt 0) { exit 1 }
