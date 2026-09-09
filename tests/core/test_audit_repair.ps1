# SPDX-License-Identifier: MPL-2.0
# Focused audit-repair checks. Isolated fixtures only; no live install, Task
# Scheduler, App, or paid PI mutation. Does not repeat hop-1 50-assertion suite.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
. (Join-Path $repoRoot 'src\dashboard\TelephoneDashboard.Common.ps1')
. (Join-Path $repoRoot 'src\dashboard\TelephoneDashboard.Projection.ps1')
. (Join-Path $repoRoot 'src\supervisor\TelephoneSupervisor.Common.ps1')
. (Join-Path $repoRoot 'src\install\TelephoneLineInstall.Common.ps1')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$assertions = 0
$previousDashState = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_STATE', 'Process')
$previousDashOpt = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', 'Process')
$previousLeadState = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_LEAD_STATE_ROOT', 'Process')
$previousTaskBackend = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_TASK_BACKEND', 'Process')
$previousTaskStore = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_TASK_STORE', 'Process')
$previousSupState = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_SUPERVISOR_STATE_ROOT', 'Process')
$previousLineState = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_STATE_ROOT', 'Process')

function Assert-Repair {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Get-RepairSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

try {
    $env:TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY = '1'
    $env:TELEPHONE_LINE_DASHBOARD_OPT_OUT = '1'
    $dashState = Join-Path $testRoot 'dashboard-runtime'
    [IO.Directory]::CreateDirectory($dashState) | Out-Null
    $env:TELEPHONE_LINE_DASHBOARD_STATE = $dashState

    $failLauncher = Join-Path $testRoot 'fail-preturn.ps1'
    [IO.File]::WriteAllText($failLauncher, @'
param([string]$WorktreePath,[string]$PromptFile,[string]$ResumeSessionId,[string]$RunId,[string]$StateRootOverride)
$ErrorActionPreference = "Stop"
$run = [IO.Path]::GetFullPath((Join-Path $StateRootOverride $RunId))
[IO.Directory]::CreateDirectory($run) | Out-Null
[IO.File]::WriteAllText((Join-Path $run "codex-events.jsonl"), "", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $run "codex-stderr.txt"), "thread-store conflict: session already has an active writer`n", [Text.UTF8Encoding]::new($false))
[ordered]@{ exit_code = 1; completed_at_utc = [DateTimeOffset]::UtcNow.ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run "host-terminal.json") -Encoding utf8NoBOM
[Console]::Error.WriteLine("thread-store conflict: session already has an active writer")
exit 1
'@, [Text.UTF8Encoding]::new($false))

    $leadState = Join-Path $testRoot 'lead-state'
    [IO.Directory]::CreateDirectory($leadState) | Out-Null
    $env:TELEPHONE_LINE_LEAD_STATE_ROOT = $leadState
    $work = Join-Path $testRoot 'worktree'
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $prompt = Join-Path $testRoot 'wake.md'
    [IO.File]::WriteAllText($prompt, "wake`n", [Text.UTF8Encoding]::new($false))
    $runId = 'telephone-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1'
    try {
        Invoke-TelephoneFrozenLeadLauncher -LauncherPath $failLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId 'sess-1' -RunId $runId
        throw 'Pre-turn launcher was treated as success.'
    } catch {
        Assert-Repair ([string]$_.Exception.Message -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT') 'Pre-turn conflict did not throw LEAD_WAKE_PRE_TURN_CONFLICT.'
    }
    $diag = Get-TelephoneLastLeadLaunchDiagnostic
    Assert-Repair ($null -ne $diag) 'Launch diagnostic was not stashed.'
    Assert-Repair ([string]$diag.error_code -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT') 'Diagnostic code was replaced.'
    Assert-Repair (-not [string]::IsNullOrWhiteSpace([string]$diag.language_mode)) 'Language mode was not persisted.'
    Assert-Repair ([string]$diag.stderr -match 'active writer') 'Original stderr was not persisted.'
    Assert-Repair ([int]$diag.exit_code -eq 1) 'Host exit was not persisted.'
    Assert-Repair ([string]$diag.error_code -cne 'Lead launcher failed.') 'Generic launcher failure replaced evidence.'

    $conflictRoot = Join-Path $leadState $runId
    $conflict = Test-TelephoneLeadPreTurnActiveWriterConflict -RunRoot $conflictRoot
    Assert-Repair ([bool]$conflict.matched) 'Fixture run was not classified as pre-turn writer conflict.'
    Assert-Repair ([bool]$conflict.retry_eligible) 'Pre-turn conflict was not retry-eligible.'
    Assert-Repair (-not [bool]$conflict.writer_alive) 'Missing writer identity was treated as a live writer.'

    $aliveStderr = ('thread-store conflict pid=' + [int]$PID + ' already has an active writer')
    $alive = Test-TelephoneLeadPreTurnActiveWriterConflict -RunRoot $conflictRoot -StderrText $aliveStderr -ExitCode 1
    Assert-Repair ([bool]$alive.writer_alive) 'Exact current writer PID was not treated as alive.'

    $jobId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1'
    $session = '01a07aae-1026-79a0-aa0c-c9fdc2f083d6'
    $jobRoot = Join-Path $testRoot ('jobs\' + $jobId)
    [IO.Directory]::CreateDirectory($jobRoot) | Out-Null
    $paths = Get-TelephoneJobPaths -JobRoot $jobRoot
    $leadBinding = [ordered]@{
        protocol_version = 'telephone-line-lead-binding-v1'
        session_id = $session
        worktree = $work
        launcher = [ordered]@{ path = $failLauncher; arguments = @('-StateRootOverride', $leadState) }
    }
    $bindingId = Write-TelephoneJsonCreateNew -Path $paths.lead_binding -Value $leadBinding
    $requestPath = Join-Path $testRoot 'request.json'
    $request = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $jobId
        project = 'audit-repair'
        stage = 'focused'
        role = 'execution'
        route = 'direct-cursor'
        summary = 'trusted-consumption-fixture'
        lead = $leadBinding
        command = [ordered]@{ executable = $pwsh; working_directory = $work; arguments = @('-NoLogo'); stdin = $null }
    }
    $null = Write-TelephoneJsonCreateNew -Path $requestPath -Value $request
    $requestId = Get-TelephoneFileIdentity -Path $requestPath
    $dispatch = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $jobId
        project = 'audit-repair'
        stage = 'focused'
        role = 'execution'
        route = 'direct-cursor'
        summary = 'trusted-consumption-fixture'
        lead = $leadBinding
        command = [ordered]@{ executable = $pwsh; working_directory = $work; arguments = @('-NoLogo'); stdin = $null }
        source_request = $requestId
        lead_binding = $bindingId
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        absolute_task_timeout = $false
        project_judgment = $false
    }
    $dispatchId = Write-TelephoneJsonCreateNew -Path $paths.dispatch -Value $dispatch
    $receipt = [ordered]@{
        protocol_version = 'telephone-line-receipt-v1'
        line_job_id = $jobId
        project = 'audit-repair'
        stage = 'focused'
        role = 'execution'
        route = 'direct-cursor'
        summary = 'trusted-consumption-fixture'
        dispatch = $dispatchId
        transport_complete = $true
        command_exit_code = 0
        command_error_code = $null
        command_error_message = $null
        stdout = @{ path = (Join-Path $jobRoot 'out.txt'); bytes = 0; sha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
        stderr = @{ path = (Join-Path $jobRoot 'err.txt'); bytes = 0; sha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
        started_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        absolute_task_timeout = $false
        automatic_rerun = $false
        project_judgment = $false
    }
    [IO.File]::WriteAllText((Join-Path $jobRoot 'out.txt'), '', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $jobRoot 'err.txt'), '', [Text.UTF8Encoding]::new($false))
    $null = Write-TelephoneJsonCreateNew -Path $paths.receipt -Value $receipt
    $receiptRead = Read-TelephoneJson -Path $paths.receipt -SchemaName 'receipt'
    $wake = New-TelephoneWakeIdentity -LineJobId $jobId -ReceiptIdentity $receiptRead.identity -LeadSessionId $session
    $relayError = [ordered]@{
        protocol_version = 'telephone-line-relay-error-v1'
        line_job_id = $jobId
        lead_session_id = $session
        retrying = $false
        error_code = 'LEAD_WAKE_FAILED'
        error_message = 'old failure'
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $null = Write-TelephoneJsonCreateNew -Path $paths.relay_error -Value $relayError
    $evidence = [ordered]@{
        protocol_version = 'telephone-explicit-consumption-evidence-v1'
        kind = 'EXPLICIT_PASCAL_MANUAL_RECOVERY_EXISTING_ORIGINAL_LEAD'
        lead_session_id = $session
        wake_key = [string]$wake.wake_key
        automatic_callback_success = $false
        receipt = @{ sha256 = [string]$receiptRead.identity.sha256 }
    }
    $evidencePath = Join-Path $testRoot 'consumption.json'
    $null = Write-TelephoneJsonCreateNew -Path $evidencePath -Value $evidence

    $wrong = Complete-TelephoneTrustedManualConsumption -JobRoot $jobRoot -ExpectedReceiptSha256 ('0' * 64) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath -Execute
    Assert-Repair (-not [bool]$wrong.ok) 'Wrong receipt hash was accepted.'
    $wrongKey = Complete-TelephoneTrustedManualConsumption -JobRoot $jobRoot -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ('1' * 64) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath -Execute
    Assert-Repair (-not [bool]$wrongKey.ok) 'Wrong wake key was accepted.'
    $wrongSess = Complete-TelephoneTrustedManualConsumption -JobRoot $jobRoot -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId 'sess-other' -ConsumptionEvidencePath $evidencePath -Execute
    Assert-Repair (-not [bool]$wrongSess.ok) 'Wrong session was accepted.'
    $autoEvidence = [ordered]@{
        protocol_version = 'telephone-explicit-consumption-evidence-v1'
        kind = 'EXPLICIT_PASCAL_MANUAL_RECOVERY_EXISTING_ORIGINAL_LEAD'
        lead_session_id = $session
        wake_key = [string]$wake.wake_key
        automatic_callback_success = $true
        receipt = @{ sha256 = [string]$receiptRead.identity.sha256 }
    }
    $autoPath = Join-Path $testRoot 'auto-claim.json'
    $null = Write-TelephoneJsonCreateNew -Path $autoPath -Value $autoEvidence
    $autoReject = Complete-TelephoneTrustedManualConsumption -JobRoot $jobRoot -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $autoPath -Execute
    Assert-Repair (-not [bool]$autoReject.ok) 'Automatic-callback claim was accepted as trusted consumption.'
    $dry = Complete-TelephoneTrustedManualConsumption -JobRoot $jobRoot -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath
    Assert-Repair ([string]$dry.code -ceq 'DRY_RUN') 'Dry-run did not stay unexecuted.'
    Assert-Repair (-not [IO.File]::Exists($paths.delivery)) 'Dry-run wrote delivery.json.'
    $closed = Complete-TelephoneTrustedManualConsumption -JobRoot $jobRoot -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath -Execute
    Assert-Repair ([bool]$closed.ok) 'Trusted consumption failed.'
    Assert-Repair ([string]$closed.delivery_kind -ceq 'MANUAL_TRUSTED_CONSUMPTION') 'Manual closeout was not distinguished.'
    Assert-Repair (-not [bool]$closed.automatic) 'Manual recovery was recorded as automatic.'
    Assert-Repair ([bool]$closed.old_failure_preserved) 'Old relay-error was not preserved.'
    Assert-Repair ([IO.File]::Exists($paths.relay_error)) 'Old failure file was removed.'
    $repeat = Complete-TelephoneTrustedManualConsumption -JobRoot $jobRoot -ExpectedReceiptSha256 ([string]$receiptRead.identity.sha256) -ExpectedWakeKey ([string]$wake.wake_key) -ExpectedLeadSessionId $session -ConsumptionEvidencePath $evidencePath -Execute
    Assert-Repair ([string]$repeat.code -ceq 'ALREADY_CLOSED') 'Repeat consumption was not idempotent.'
    $delivery = (Read-TelephoneJson -Path $paths.delivery).value
    Assert-Repair ([string]$delivery.delivery_kind -ceq 'MANUAL_TRUSTED_CONSUMPTION') 'Repeat wrote a second automatic delivery kind.'

    $retryingPaths = Get-TelephoneJobPaths -JobRoot (Join-Path $testRoot 'jobs\retrying')
    [IO.Directory]::CreateDirectory($retryingPaths.root) | Out-Null
    $retryErr = [ordered]@{ protocol_version = 'telephone-line-relay-error-v1'; retrying = $true; error_code = 'LEAD_WAKE_PRE_TURN_CONFLICT' }
    $null = Write-TelephoneJsonCreateNew -Path $retryingPaths.relay_error -Value $retryErr
    Assert-Repair (-not (Test-TelephoneRelayErrorBlocksWait -JobPaths $retryingPaths)) 'Retrying pre-turn relay-error blocked wait.'

    $supRoot = Join-Path $testRoot 'supervisor'
    $runUuid = 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeee2'
    $supRequest = [ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-request-v1'
        run_id = $runUuid
        request_sha256 = ('a' * 64)
        project = 'claimed-reconcile'
        stage = 'focused'
        lead_session_id = $session
        worktree = $work
        command = [ordered]@{ executable = $pwsh; working_directory = $work; arguments = @('-NoLogo') }
        installed_version = [ordered]@{ version_id = ('b' * 64); source_sha256 = ('b' * 64); install_root = $testRoot }
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $supRequest.request_sha256 = Get-TelephoneSupervisorRequestHash -Request $supRequest
    $null = Initialize-TelephoneSupervisorLayout -StateRoot $supRoot
    $claimedPath = Get-TelephoneSupervisorRecordPath -StateRoot $supRoot -Kind claimed -RunId $runUuid
    $null = Write-TelephoneJsonCreateNew -Path $claimedPath -Value $supRequest
    $reconciled = @(Reconcile-TelephoneSupervisorClaimed -StateRoot $supRoot)
    Assert-Repair ($reconciled.Count -eq 1) 'Claimed-without-owner was silently skipped.'
    Assert-Repair ([string]$reconciled[0].decision -ceq 'proven_not_started') 'Claimed-without-owner was not proven-not-started.'
    $outboxPath = Get-TelephoneSupervisorRecordPath -StateRoot $supRoot -Kind outbox -RunId $runUuid
    Assert-Repair ([IO.File]::Exists($outboxPath)) 'Proven-not-started did not write outbox.'
    $outbox = (Read-TelephoneJson -Path $outboxPath).value
    Assert-Repair ([string]$outbox.error_code -ceq 'SUPERVISOR_CLAIMED_NOT_STARTED') 'Outbox used a replay/generic code.'
    Assert-Repair (-not [IO.File]::Exists($claimedPath)) 'Claimed file remained after proven-not-started.'

    $lineState = Join-Path $testRoot 'line-state'
    [IO.Directory]::CreateDirectory((Join-Path $lineState 'jobs')) | Out-Null
    $reg = Register-TelephoneDashboardLineSource -LineStateRoot $lineState -LineJobId $jobId -Project 'audit-repair' -LeadSessionId $session -LeadRunId ('telephone-' + $jobId) -Route 'direct-cursor' -DashboardStateRoot $dashState
    Assert-Repair ([bool]$reg.registered) 'Line source was not registered.'
    $srcDoc = (Read-TelephoneJson -Path ([string]$reg.path)).value
    Assert-Repair (@($srcDoc.sources).Count -ge 1) 'Source registry was empty.'
    $projection = Get-TelephoneDashboardProjection -StateRoot $lineState
    $jsonText = (($projection | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n")
    Assert-TelephoneJsonSchema -JsonText $jsonText -SchemaName 'dashboard-projection' -Label 'audit-repair projection'
    Assert-Repair ($projection.Contains('last_success_at_utc')) 'Projection omitted last-success timestamp.'
    $summary = Format-TelephoneDashboardSummary -Projection $projection
    Assert-Repair ($summary -match 'Truth: stale=') 'Summary did not share timestamp truth with projection.'

    $liveJob = [ordered]@{
        job_id = $jobId
        job_root = $jobRoot
        command_alive = $false
        relay_alive = $false
        delivery = $false
        receipt = [ordered]@{ present = $true; valid = $true }
        findings = @([ordered]@{ code = 'RECEIPT_AWAITING_DELIVERY'; severity = 'info' })
        direct_route = $true
    }
    $hiddenLive = Test-TelephoneDashboardDirectHistoryRetired -Job $liveJob -AllJobs @($liveJob) -Descriptor ([ordered]@{ project = 'audit-repair'; successor_line_job_id = 'cccccccc-bbbb-cccc-dddd-eeeeeeeeeee3' }) -DirectByJobId @{} -ProofJobIds @('cccccccc-bbbb-cccc-dddd-eeeeeeeeeee3') -ProofDirectSessions @('other')
    Assert-Repair (-not [bool]$hiddenLive) 'Receipt-awaiting live job was hidden by history/retired.'
    Assert-Repair (Test-TelephoneDashboardJobMustRemainVisible -Job $liveJob) 'Receipt-awaiting job was not marked remain-visible.'

    $wrapperDir = Join-Path $testRoot 'wrapper-owner\src\supervisor'
    [IO.Directory]::CreateDirectory($wrapperDir) | Out-Null
    $exe = Join-Path $wrapperDir 'SupervisorNoConsoleHost.exe'
    [IO.File]::WriteAllBytes($exe, [byte[]](77, 90, 0, 0, 1, 2, 3, 4))
    $exeSha = Get-RepairSha256 -Path $exe
    $installRoot = [IO.Path]::GetFullPath((Join-Path $testRoot 'wrapper-owner'))
    $sidecar = Join-Path $wrapperDir 'wrapper-identity.json'
    $null = Write-TelephoneJsonCreateNew -Path $sidecar -Value ([ordered]@{
        protocol_version = 'telephone-line-supervisor-wrapper-identity-v1'
        install_root = $installRoot
        wrapper_path = $exe
        sha256 = $exeSha
    })
    $owned = Get-TelephoneSupervisorInstallRootFromWrapperIdentity -ActionScript $exe
    Assert-Repair ($owned.Equals($installRoot, [StringComparison]::OrdinalIgnoreCase)) 'Verified wrapper identity did not resolve install root.'
    $foreignExe = Join-Path $testRoot 'foreign-host.exe'
    [IO.File]::WriteAllBytes($foreignExe, [byte[]](77, 90, 9, 9))
    $filenameOnly = Get-TelephoneSupervisorInstallRootFromActionScript -ActionScript $foreignExe
    Assert-Repair ([string]::IsNullOrWhiteSpace($filenameOnly)) 'Filename-only EXE bypassed wrapper identity.'
    $bareNamed = Join-Path $testRoot 'SupervisorNoConsoleHost.exe'
    [IO.File]::WriteAllBytes($bareNamed, [byte[]](77, 90, 8, 8))
    $bareRoot = Get-TelephoneSupervisorInstallRootFromActionScript -ActionScript $bareNamed
    Assert-Repair ([string]::IsNullOrWhiteSpace($bareRoot)) 'SupervisorNoConsoleHost.exe filename alone resolved an install root.'
    $ownedViaAction = Get-TelephoneSupervisorInstallRootFromActionScript -ActionScript $exe
    Assert-Repair ($ownedViaAction.Equals($installRoot, [StringComparison]::OrdinalIgnoreCase)) 'Verified wrapper identity was not accepted through the action-script path.'

    $foreignSup = Join-Path $testRoot 'foreign-supervisor'
    [IO.Directory]::CreateDirectory($foreignSup) | Out-Null
    $marker = Join-Path $foreignSup 'FOREIGN.txt'
    [IO.File]::WriteAllText($marker, 'do-not-recycle', [Text.UTF8Encoding]::new($false))
    $ourInstall = Join-Path $testRoot 'our-install'
    [IO.Directory]::CreateDirectory($ourInstall) | Out-Null
    $manifest = [ordered]@{
        protocol_version = 'telephone-line-install-manifest-v1'
        product_id = 'telephone-line'
        install_root = '.'
        source_identity = @{ path = $repoRoot; bytes = 1; sha256 = ('c' * 64) }
        path_appended = $false
        files = @()
    }
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $ourInstall 'install-manifest.json') -Value $manifest
    $taskStore = Join-Path $testRoot 'task-store'
    [IO.Directory]::CreateDirectory($taskStore) | Out-Null
    $foreignTask = [ordered]@{
        task_name = 'TelephoneLineWiredSupervisor'
        registered = $true
        install_root = (Join-Path $testRoot 'other-install')
        action_script = (Join-Path $testRoot 'other-install\src\supervisor\Invoke-TelephoneSupervisor.ps1')
        action_arguments = '-InstallRoot "other"'
    }
    [IO.File]::WriteAllText((Join-Path $taskStore 'task.json'), (($foreignTask | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $env:TELEPHONE_LINE_TASK_BACKEND = (Join-Path $repoRoot 'tests\supervisor\fixtures\mock-scheduler.ps1')
    $env:TELEPHONE_LINE_TASK_STORE = $taskStore
    $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT = $foreignSup
    $ourState = Join-Path $testRoot 'our-state'
    [IO.Directory]::CreateDirectory($ourState) | Out-Null
    $env:TELEPHONE_LINE_STATE_ROOT = $ourState
    $gate = Test-TelephoneSupervisorTaskAvailableForInstallRoot -InstallRoot $ourInstall
    Assert-Repair ([bool]$gate.registered) 'Foreign mock task was not seen as registered.'
    Assert-Repair (-not [bool]$gate.available) 'Cross-install registered task was treated as owned.'
    $un = Invoke-TelephoneLineUninstall -InstallRoot $ourInstall -RemoveState
    Assert-Repair ([IO.File]::Exists($marker)) 'Foreign supervisor state was selected for RemoveState deletion.'
    Assert-Repair ([IO.File]::Exists((Join-Path $taskStore 'task.json'))) 'Foreign scheduled-task record was unregistered during same-task fail-closed uninstall.'
    Assert-Repair ([bool]$un.ok -or [string]$un.code -cin @('UNINSTALLED', 'UNMANAGED_CONTENT_REMAINS', 'ALREADY_CURRENT')) ('Uninstall unexpected code: ' + [string]$un.code)

    $okLauncher = Join-Path $testRoot 'ok-exit.ps1'
    [IO.File]::WriteAllText($okLauncher, @'
param([string]$WorktreePath,[string]$PromptFile,[string]$ResumeSessionId,[string]$RunId,[string]$StateRootOverride)
$run = [IO.Path]::GetFullPath((Join-Path $StateRootOverride $RunId))
[IO.Directory]::CreateDirectory($run) | Out-Null
[ordered]@{ run_root = $run; state = "completed"; exit_code = 0 } | ConvertTo-Json -Compress
exit 0
'@, [Text.UTF8Encoding]::new($false))
    $okRun = 'ok-run-1'
    $launchOk = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $okLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId 'sess-ok' -RunId $okRun
    Assert-Repair (-not [string]::IsNullOrWhiteSpace([string]$launchOk.run_root)) 'Successful launcher lost run_root.'

    $aliveRunId = 'writer-alive-run'
    $aliveRoot = Join-Path $leadState $aliveRunId
    [IO.Directory]::CreateDirectory($aliveRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $aliveRoot 'codex-events.jsonl'), '', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $aliveRoot 'codex-stderr.txt'), ('thread-store conflict pid=' + [int]$PID + ' already has an active writer'), [Text.UTF8Encoding]::new($false))
    $null = Write-TelephoneJsonCreateNew -Path (Join-Path $aliveRoot 'host-terminal.json') -Value ([ordered]@{ exit_code = 1; completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o') })
    $aliveAttachDir = Join-Path $testRoot 'jobs\writer-alive'
    [IO.Directory]::CreateDirectory($aliveAttachDir) | Out-Null
    try {
        Invoke-TelephoneNamedWakeAttach -LaunchResultPath (Join-Path $aliveAttachDir 'wake-launch-result.json') -LauncherPath $okLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId 'sess-1' -RunId $aliveRunId -WakeKey ('a' * 64) -LineJobId $jobId
        throw 'Live writer was not fail-closed.'
    } catch {
        Assert-Repair ([string]$_.Exception.Message -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT') 'Live writer did not throw LEAD_WAKE_PRE_TURN_CONFLICT.'
    }
    Assert-Repair (-not [IO.File]::Exists((Join-Path $aliveAttachDir 'wake-retry.json'))) 'Live writer wrote a retry record.'
    Assert-Repair ([IO.Directory]::Exists($aliveRoot)) 'Live-writer failed run was removed.'

    $retryAttachDir = Join-Path $testRoot 'jobs\writer-released'
    [IO.Directory]::CreateDirectory($retryAttachDir) | Out-Null
    $retryAttach = Invoke-TelephoneNamedWakeAttach -LaunchResultPath (Join-Path $retryAttachDir 'wake-launch-result.json') -LauncherPath $okLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId 'sess-1' -RunId $runId -WakeKey ([string]$wake.wake_key) -LineJobId $jobId
    Assert-Repair ([IO.File]::Exists((Join-Path $retryAttachDir 'wake-retry.json'))) 'Writer-released retry did not persist wake-retry.json.'
    $retryDoc = (Read-TelephoneJson -Path (Join-Path $retryAttachDir 'wake-retry.json')).value
    Assert-Repair ([string]$retryDoc.original_wake_run_id -ceq $runId) 'Retry did not keep the original wake run id.'
    Assert-Repair ([string]$retryDoc.wake_key -ceq [string]$wake.wake_key) 'Retry did not keep the original wake key.'
    Assert-Repair (-not [bool]$retryDoc.executor_rerun) 'Retry claimed an executor rerun.'
    Assert-Repair ([IO.Directory]::Exists($conflictRoot)) 'Failed original run was erased by retry.'
    Assert-Repair ([string]$retryAttach.wake_run_id -ceq ([string]$runId + '-retry-1') -or [string]$retryDoc.retry_wake_run_id -ceq ([string]$runId + '-retry-1')) 'Retry did not use a distinct wake_run_id.'
    $repeatAttach = Invoke-TelephoneNamedWakeAttach -LaunchResultPath (Join-Path $retryAttachDir 'wake-launch-result.json') -LauncherPath $okLauncher -ExtraArguments @('-StateRootOverride', $leadState) -Worktree $work -PromptFile $prompt -SessionId 'sess-1' -RunId $runId -WakeKey ([string]$wake.wake_key) -LineJobId $jobId
    Assert-Repair ([string]$repeatAttach.wake_key -ceq [string]$wake.wake_key) 'Repeated attach did not keep the same wake key.'

    $defaults = Get-Content -LiteralPath (Join-Path $repoRoot '_audit_repair_artifacts_20260909\private-candidate\defaults\TELEPHONE_NEW_LEAD_DEFAULTS.json') -Raw | ConvertFrom-Json
    Assert-Repair ([string]$defaults.codex_command -match 'telephone-cli\\0\.153\.4-fd4c151a\\codex\.exe') 'Isolated defaults still named the deleted App path.'
    Assert-Repair ([string]$defaults.model -ceq 'gpt-6-astra') 'Defaults model policy drifted.'
    Assert-Repair ([string]$defaults.reasoning_effort -ceq 'high') 'Defaults effort policy drifted.'
    Assert-Repair ([string]$defaults.service_tier -ceq 'default') 'Defaults service policy drifted.'
    Assert-Repair ([string]$defaults.default_executor_route -ceq 'direct-cursor') 'Defaults route policy drifted.'

    $tutu = Get-Content -LiteralPath (Join-Path $repoRoot '_audit_repair_artifacts_20260909\private-candidate\tutu\scripts\New-TutuPiDirectCursorDispatch.ps1') -Raw
    Assert-Repair ($tutu -match 'pending_registered_task_is_not_success') 'Tutu dispatch still equated pending task with success.'
    Assert-Repair ($tutu -match 'success = \$false') 'Tutu dispatch result lacked explicit non-success.'

    Write-Output ('AUDIT_REPAIR_ASSERTIONS=' + $assertions)
} finally {
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_STATE', $previousDashState, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', $previousDashOpt, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_LEAD_STATE_ROOT', $previousLeadState, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_TASK_BACKEND', $previousTaskBackend, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_TASK_STORE', $previousTaskStore, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_SUPERVISOR_STATE_ROOT', $previousSupState, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_STATE_ROOT', $previousLineState, 'Process')
}
