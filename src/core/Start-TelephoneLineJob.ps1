# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestFile,
    [Parameter(Mandatory = $true)][string]$StateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneLine.Common.ps1')
$dashboardEnsure = Invoke-TelephoneDashboardEnsure

$state = Assert-TelephoneDirectoryPath -Path $StateRoot -Label 'State root'
$requestRead = Read-TelephoneJson -Path $RequestFile
Assert-TelephoneDispatchRequestText -JsonText ([string]$requestRead.text)
$request = $requestRead.value
if ([string]$request.protocol_version -cne 'telephone-line-dispatch-v1') { throw 'Unsupported telephone-line dispatch protocol.' }
if ([string]$request.line_job_id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'line_job_id must be a UUID.' }
if ([string]$request.role -cnotin @('execution', 'review')) { throw 'role must be execution or review.' }
foreach ($field in @('project', 'stage', 'route', 'summary')) {
    if ([string]::IsNullOrWhiteSpace([string]$request[$field])) { throw "Dispatch field is empty: $field" }
}
if ($null -eq $request.command) { throw 'Dispatch command is required.' }
foreach ($field in @('executable', 'working_directory')) {
    if ([string]::IsNullOrWhiteSpace([string]$request.command[$field])) { throw "Command field is empty: $field" }
}
if ($request.command.arguments -is [string] -or $request.command.arguments -isnot [Collections.IEnumerable]) { throw 'command.arguments must be an array.' }
$leadBinding = Read-TelephoneLeadBinding -Lead $request.lead
$leadSessionId = [string]$leadBinding.session_id
$batch = Resolve-TelephoneRequestBatch -Request $request -LineJobId ([string]$request.line_job_id)
$nestedTarget = $null
if ($request.Contains('nested_target') -and $null -ne $request.nested_target) {
    $nestedTarget = Read-TelephoneLeadBinding -Lead $request.nested_target
    if ([string]$nestedTarget.session_id -ceq $leadSessionId) {
        throw 'Nested target session must differ from the owning Lead session.'
    }
}

$jobRoot = Join-Path (Join-Path $state 'jobs') ([string]$request.line_job_id)
if ([IO.Directory]::Exists($jobRoot)) { throw 'Telephone-line job already exists; use Resume-TelephoneLines.ps1 for recovery.' }
$jobsRoot = Join-Path $state 'jobs'
if ([IO.Directory]::Exists($jobsRoot)) {
    foreach ($existingDir in @([IO.Directory]::GetDirectories($jobsRoot))) {
        $existingDispatchPath = Join-Path $existingDir 'dispatch.json'
        if (-not [IO.File]::Exists($existingDispatchPath)) { continue }
        try {
            $existingDispatch = (Read-TelephoneJson -Path $existingDispatchPath).value
            $existingBatch = Resolve-TelephoneDispatchBatch -Dispatch $existingDispatch -LineJobId ([string]$existingDispatch.line_job_id)
            if ([string]$existingBatch.batch_id -ceq [string]$batch.batch_id -and [string]$existingBatch.package_id -ceq [string]$batch.package_id) {
                throw 'Duplicate batch package_id is not allowed.'
            }
        } catch {
            if ([string]$_.Exception.Message -ceq 'Duplicate batch package_id is not allowed.') { throw }
        }
    }
}
[IO.Directory]::CreateDirectory($jobRoot) | Out-Null
$paths = Get-TelephoneJobPaths -JobRoot $jobRoot
$stdinIdentity = if ($request.command.Contains('stdin_file') -and -not [string]::IsNullOrWhiteSpace([string]$request.command.stdin_file)) {
    Get-TelephoneFileIdentity -Path ([string]$request.command.stdin_file)
} else {
    $null
}
$executable = Assert-TelephoneRegularFilePath -Path ([string]$request.command.executable) -Label 'Route executable'
$workingDirectory = Assert-TelephoneDirectoryPath -Path ([string]$request.command.working_directory) -Label 'Route working directory'
$leadBindingIdentity = Write-TelephoneJsonCreateNew -Path $paths.lead_binding -Value $leadBinding
$dispatch = [ordered]@{
    protocol_version = 'telephone-line-dispatch-v1'
    line_job_id = [string]$request.line_job_id
    project = [string]$request.project
    stage = [string]$request.stage
    role = [string]$request.role
    route = [string]$request.route
    summary = [string]$request.summary
    lead = $leadBinding
    command = [ordered]@{
        executable = $executable
        working_directory = $workingDirectory
        arguments = @($request.command.arguments | ForEach-Object { [string]$_ })
        stdin = $stdinIdentity
    }
    source_request = $requestRead.identity
    lead_binding = $leadBindingIdentity
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    absolute_task_timeout = $false
    project_judgment = $false
}
if ($null -ne $nestedTarget) { $dispatch['nested_target'] = $nestedTarget }
if ($request -is [Collections.IDictionary] -and $request.Contains('batch') -and $null -ne $request.batch) {
    $dispatch['batch'] = $batch
}
if ($request -is [Collections.IDictionary] -and $request.Contains('control_plane') -and $null -ne $request.control_plane) {
    $dispatch['control_plane'] = $request.control_plane
}
$dispatchIdentity = Write-TelephoneJsonCreateNew -Path $paths.dispatch -Value $dispatch
$null = Read-TelephoneJson -Path $paths.dispatch -SchemaName 'dispatch'
if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID)) {
    $lineage = [ordered]@{
        protocol_version = 'telephone-line-supervisor-lineage-v1'
        supervisor_run_id = [string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID
        line_job_id = [string]$request.line_job_id
        lead_session_id = $leadSessionId
        lead_identity_sha256 = [string](Get-TelephoneLeadCanonicalIdentity -Lead $leadBinding).identity_sha256
        batch_id = [string]$batch.batch_id
        package_id = [string]$batch.package_id
    }
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $jobRoot 'supervisor-lineage.json') -Value $lineage
}
if ([string]$leadSessionId -cne [string]$dispatch.lead.session_id) {
    throw 'Frozen dispatch session disagrees with the Lead binding.'
}

$commandHostIdentity = Get-TelephoneFileIdentity -Path (Join-Path $PSScriptRoot 'Invoke-TelephoneLineCommandHost.ps1')
$forceStartFailed = [string][Environment]::GetEnvironmentVariable('TELEPHONE_TEST_FORCE_COMMAND_START_FAILED', 'Process')
$forceStartFailedMatch = (-not [string]::IsNullOrWhiteSpace($forceStartFailed) -and (
    $forceStartFailed -ceq [string]$request.line_job_id -or $forceStartFailed -ceq [string]$batch.package_id
))
$commandOwner = $null
if ($forceStartFailedMatch) {
    $failureReceipt = New-TelephoneTransportFailureReceipt -DispatchRead (Read-TelephoneJson -Path $paths.dispatch -SchemaName 'dispatch') `
        -ErrorCode 'COMMAND_START_FAILED' -ErrorMessage (Get-TelephonePublicErrorMessage -ErrorCode 'COMMAND_START_FAILED') -StartedAtUtc $null
    try { $null = Write-TelephoneJsonCreateNew -Path $paths.receipt -Value $failureReceipt } catch [IO.IOException] { }
} else {
    $null = Write-TelephoneJsonCreateNew -Path $paths.command_start_intent -Value ([ordered]@{
        protocol_version = 'telephone-line-command-start-v1'
        line_job_id = [string]$request.line_job_id
        dispatch = $dispatchIdentity
        command_host = $commandHostIdentity
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    try {
        $commandOwner = Start-TelephoneHiddenPowerShell -ScriptPath (Join-Path $PSScriptRoot 'Invoke-TelephoneLineCommandHost.ps1') -Arguments @('-JobRoot', $jobRoot)
        try {
            $null = Write-TelephoneJsonCreateNew -Path $paths.command_launch -Value ([ordered]@{
                protocol_version = 'telephone-line-command-launch-v1'
                line_job_id = [string]$request.line_job_id
                dispatch = $dispatchIdentity
                owner = $commandOwner
                launched_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            })
        } catch [IO.IOException] {
            # The child self-publishes command-owner.json before invoking the route.
            # A missing parent launch record therefore does not invalidate a live child.
        }
    } catch {
        if ([IO.File]::Exists($paths.command_launch)) {
            try { $commandOwner = (Read-TelephoneJson -Path $paths.command_launch).value.owner } catch { }
        }
        if ([IO.File]::Exists($paths.command_owner)) {
            try { $commandOwner = (Read-TelephoneJson -Path $paths.command_owner).value } catch { }
        }
        $launchAlive = Test-TelephoneCommandLaunchAlive -Paths $paths
        $ownerAlive = Test-TelephoneOwnerAlive -Owner $commandOwner
        if (-not $launchAlive -and -not $ownerAlive -and -not [IO.File]::Exists($paths.receipt)) {
            $message = Get-TelephonePublicErrorMessage -ErrorCode 'COMMAND_START_FAILED'
            $startGate = Open-TelephoneExclusiveGate -Path $paths.command_gate -WaitMilliseconds 2000
            if ($null -ne $startGate) {
                try {
                    if ([IO.File]::Exists($paths.command_owner)) {
                        $commandOwner = (Read-TelephoneJson -Path $paths.command_owner).value
                    } elseif ((Test-TelephoneCommandLaunchAlive -Paths $paths)) {
                        $commandOwner = (Read-TelephoneJson -Path $paths.command_launch).value.owner
                    } elseif (-not [IO.File]::Exists($paths.receipt)) {
                        $failureReceipt = New-TelephoneTransportFailureReceipt -DispatchRead (Read-TelephoneJson -Path $paths.dispatch -SchemaName 'dispatch') `
                            -ErrorCode 'COMMAND_START_FAILED' -ErrorMessage $message -StartedAtUtc $null
                        try { $null = Write-TelephoneJsonCreateNew -Path $paths.receipt -Value $failureReceipt } catch [IO.IOException] { }
                    }
                } finally {
                    $startGate.Dispose()
                }
            }
        }
    }
}
$null = Write-TelephoneLifecycleStatus -Paths $paths -Phase 'dispatched' -Idle $false
$relayOwner = Start-TelephoneHiddenPowerShell -ScriptPath (Join-Path $PSScriptRoot 'Invoke-TelephoneLineRelay.ps1') -Arguments @('-JobRoot', $jobRoot)
if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID)) {
    $relayOwner['supervisor_run_id'] = [string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID
}
$null = Write-TelephoneJsonCreateNew -Path $paths.relay_owner -Value $relayOwner
$controlPlaneWake = Invoke-TelephoneControlPlaneLifecycleWake -Dispatch $dispatch -JobRoot $jobRoot -Reason 'dispatch-created'

[ordered]@{
    dispatched = $true
    line_job_id = [string]$request.line_job_id
    job_root = $jobRoot
    dispatch = $dispatchIdentity
    command_owner = $commandOwner
    relay_owner = $relayOwner
    status_dashboard = $dashboardEnsure
    control_plane_wake = $controlPlaneWake
    lead_should_exit_now = $true
    absolute_task_timeout = $false
    project_judgment = $false
} | ConvertTo-Json -Depth 32
