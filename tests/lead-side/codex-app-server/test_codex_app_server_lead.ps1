# SPDX-License-Identifier: MPL-2.0
# Current Understanding (execution, 2026-08-27 owner-observe race):
# 1. Phase: close post-activation OWNER_INVALID race on candidate c0b1362c; preserve accepted proofs; amend the same one commit over 6c9d25e.
# 2. Denominator: thread-owner disappearance/replacement during observation is re-evaluated; stable malformed/wrong-thread remains OWNER_INVALID; ack/terminal already published wins; owner absence never invents success.
# 3. Only next step: Lifecycle observation retry + focused race regression, then frozen union.
# 4. Frozen non-goals: no Common/schema/dashboard/core mutation, no runtime activation, no real smoke.
# 5. Exit: WakeAmbiguityRepairOnly plus frozen union, clean one commit over 6c9d25e, self_accepted=false; not project PASS.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TestRoot,
    [switch]$F02WriterOracleOnly,
    [Alias('CompatibilityOnly')][switch]$Compatibility0147Only,
    [switch]$CallbackOwnerOnly,
    [switch]$BatchFanInOnly,
    [switch]$LegacyHistoryBaselineOnly,
    [switch]$AppServerDeathRecoveryOnly,
    [switch]$WorkerDeathRecoveryOnly,
    [switch]$WakeAmbiguityRepairOnly,
    [switch]$F02SchemaNoneInProgressOnly,
    [switch]$F02WorkerNoneFallbackOnly,
    [switch]$F02RecoveryForwardOnly,
    [switch]$OfficialTerminalsOnly,
    [switch]$AckObservationRaceOnly,
    [switch]$F03TerminalReentryOnly,
    [switch]$R8ScopedCutOnly,
    [switch]$R8RecoveryRequiredCutOnly,
    [string]$InstalledCodexCommand = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PreviousDashboardProcessEnvOnly = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', 'Process')
$script:PreviousDashboardOptOut = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', 'Process')
$script:PreviousDashboardState = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_STATE', 'Process')
$script:PreviousDashboardHeadless = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_HEADLESS', 'Process')
[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', '1', 'Process')
[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', '1', 'Process')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
. (Join-Path $repoRoot 'src\lead-side\codex-app-server\CodexAppServerLead.Common.ps1')
$pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$packageMock = Join-Path $PSScriptRoot 'fixtures\Mock-CodexAppServer.ps1'
$mock = $packageMock
$cliSpy = Join-Path $PSScriptRoot 'fixtures\Spy-CliLeadLauncher.ps1'
$fullTestRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($fullTestRoot) | Out-Null
$runtimeRepoRoot = Join-Path $fullTestRoot '_runtime-package'
[IO.Directory]::CreateDirectory((Join-Path $runtimeRepoRoot 'src')) | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'src\core') -Destination (Join-Path $runtimeRepoRoot 'src\core') -Recurse
[IO.Directory]::CreateDirectory((Join-Path $runtimeRepoRoot 'src\lead-side')) | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'src\lead-side\codex-app-server') -Destination (Join-Path $runtimeRepoRoot 'src\lead-side\codex-app-server') -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'src\dashboard') -Destination (Join-Path $runtimeRepoRoot 'src\dashboard') -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'schemas') -Destination (Join-Path $runtimeRepoRoot 'schemas') -Recurse
[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_STATE', (Join-Path $fullTestRoot 'dashboard-runtime'), 'Process')
[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_HEADLESS', '1', 'Process')
$runtimeCatalogPath = Join-Path $runtimeRepoRoot 'src\lead-side\codex-app-server\CodexAppServerCompatibility.psd1'
$runtimeCatalogText = [IO.File]::ReadAllText($runtimeCatalogPath, [Text.UTF8Encoding]::new($false, $true))
$runtimeTestEntry = @"
        @{
            CodexVersion = 'codex-cli telephone-test-mock'
            SchemaFileCount = 6
            SchemaBytes = 284
            SchemaFingerprint = 'c4f8f2bee7fdb67c53ad007290f634112af3ee30cc74e094689fe44288149c44'
            SurfaceFileCount = 0
            SurfaceBytes = 0
            SurfaceFingerprint = '0000000000000000000000000000000000000000000000000000000000000000'
            AdapterRule = 'app-server-v0147'
            ProjectIdMode = 'absent'
            NotificationEnvelopeMode = 'strict-v0147'
        }
        # TEST_RUNTIME_ENTRY_INSERTION_POINT
"@
if ($runtimeCatalogText.IndexOf('        # TEST_RUNTIME_ENTRY_INSERTION_POINT', [StringComparison]::Ordinal) -lt 0) {
    throw 'Compatibility catalog test insertion point is missing.'
}
$runtimeCatalogText = $runtimeCatalogText.Replace('        # TEST_RUNTIME_ENTRY_INSERTION_POINT', $runtimeTestEntry.TrimEnd("`r", "`n"))
[IO.File]::WriteAllText($runtimeCatalogPath, $runtimeCatalogText, [Text.UTF8Encoding]::new($false))
$profileScript = Join-Path $runtimeRepoRoot 'src\lead-side\codex-app-server\Invoke-CodexAppServerLeadProfile.ps1'
$preflightScript = Join-Path $runtimeRepoRoot 'src\lead-side\codex-app-server\Invoke-CodexAppServerLeadPreflight.ps1'
$qualificationScript = Join-Path $repoRoot 'src\lead-side\codex-app-server\Invoke-CodexAppServerCompatibilityQualification.ps1'
$builderScript = Join-Path $runtimeRepoRoot 'src\lead-side\codex-app-server\New-CodexAppServerLeadBinding.ps1'
$launcherScript = Join-Path $runtimeRepoRoot 'src\lead-side\codex-app-server\Invoke-CodexAppServerLeadLauncher.ps1'
$workerScript = Join-Path $runtimeRepoRoot 'src\lead-side\codex-app-server\Invoke-CodexAppServerLeadWorker.ps1'
$statusScript = Join-Path $runtimeRepoRoot 'src\lead-side\codex-app-server\Get-CodexAppServerLeadStatus.ps1'
$assertions = 0
$threadIdDirect = 0
$restartResume = 0
$callbackOnce = 0
$durableCreateSameProcess = 0
$durableCreateRestartResume = 0
$durableCreateFailClosed = 0
$crashBeforeWrite = 0
$crashAfterAmbiguousWrite = 0
$crashAfterTurnBind = 0
$crashBeforeAck = 0
$concurrencyOnce = 0
$failClosedZero = 0
$failClosedMultiple = 0
$failClosedUnexplained = 0
$statusNotLoaded = 0
$statusIdle = 0
$statusSystemError = 0
$statusActive = 0
$flagApproval = 0
$flagUserInput = 0
$pendingProjected = 0
$statusObservational = 0
$schemaMismatch = 0
$explicitFallback = 0
$automaticFallbackAbsent = 0
$stdioOnly = 0
$experimentalExcluded = 0
$privacyClean = 0
$noProvider = 0
$denominatorEight = 0
$parseCheck = 0
$f1GateReleasedBeforeAckWait = 0
$appServerDeathRecoveryFocused = 0
$quietNotTerminalOracle = 0
$terminalWaitObservationOnly = 0
$naturalQuiesceObservationOnly = 0
$stuckOwnerExposedWithoutKill = 0
$workerDeathOfficialTerminal = 0
$workerDeathNaturalQuiesceObservationOnly = 0
$wakeAmbiguityPositiveRestart = 0
$wakeAmbiguityMarkerRecovery = 0
$wakeAmbiguityMultipleMarkersClosed = 0
$wakeAmbiguityPostIntentClosed = 0
$wakeAmbiguityIdentityMismatchClosed = 0
$wakeAmbiguitySendingWithoutMarkerClosed = 0
$wakeAmbiguityLiveOwnerSerialized = 0
$wakeAmbiguityMatchConflictClosed = 0
$wakeAmbiguityExactTextAttach = 0
$wakeAmbiguityWrongTextClosed = 0
$wakeAmbiguityExactPlusWrongTextClosed = 0
$wakeAmbiguityMalformedProtocolClosed = 0
$wakeAmbiguityUnrelatedBusyCodeClosed = 0
$busyClientReconnectOnce = 0
$wakeAmbiguityQuiescence = 0
$wakeAmbiguityArtifactsAgree = 0
$wakeAmbiguityCapturedPriorBaseline = 0
$wakeAmbiguityPreIntentPredicateClosed = 0
$wakeAmbiguityActiveStartedBeforeIntentClosed = 0
$wakeAmbiguityTerminalWithoutTimeClosed = 0
$wakeAmbiguityIntentTimeUnparseableClosed = 0
$wakeAmbiguityCompletedAfterIntentClosed = 0
$wakeAmbiguitySameSecondClosed = 0
$wakeAmbiguityArchivedResumeOnce = 0
$wakeAmbiguityArchivedRepeatNoSecondUnarchive = 0
$wakeAmbiguityArchivedWrongCodeClosed = 0
$wakeAmbiguityArchivedNoncanonicalClosed = 0
$wakeAmbiguityArchivedMissingIdClosed = 0
$wakeAmbiguityArchivedMismatchedIdClosed = 0
$wakeAmbiguityArchivedUnrelatedResumeClosed = 0
$wakeAmbiguityArchivedUnarchiveFailedClosed = 0
$wakeAmbiguityArchivedRetryFailedClosed = 0
$wakeAmbiguityArchivedCommandBoundary = 0
$wakeAmbiguityArchivedRawJsonResumeError = 0
$wakeAmbiguityOwnerObserveRaceClosed = 0
$f02SchemaNoneInProgressIsolated = 0
$f02WorkerFixtureQueueClean = 0
$f02QueueContaminationRejected = 0
$f02WorkerNoneFallbackCaught = 0
$f02PreloopNoDeclaration = 0
$f02WorkerCatchBoundaryDistinguished = 0
$f02RecoveryForwardOwnerRebound = 0
$durableCreateFailureDiagnostic = 0
$script:casIntLastInvocation = $null
$ackObservationRace = 0
$durableAckBeforeTerminal = 0
$launcherExitSameTurn = 0
$appserverDeathSameTurn = 0
$workerDeathSameTurn = 0
$callbackContinuationSameSession = 0
$callbackContinuationMismatchRefused = 0
$intentMismatchClosed = 0
$markerUserExact = 0
$markerEchoRejected = 0
$pendingFourMethods = 0
$pendingUnknownIgnored = 0
$pendingResolvedCleared = 0
$stderrDrained = 0
$failClosedEmpty = 0
$officialCompleted = 0
$officialFailed = 0
$officialInterrupted = 0
$recoveryRequired = 0
$quietReadSurvived = 0
$noConcurrentStdoutRead = 0
$noAbsoluteTurnTimeout = 0
$crossIdentityIgnored = 0
$malformedTerminalNotCompleted = 0
$chainValidRecovered = 0
$chainOrphanAckClosed = 0
$chainOrphanBoundClosed = 0
$chainConflictClosed = 0
$chainTerminalWithoutChainClosed = 0
$chainLiveOwnerBypassClosed = 0
$f01StableProtocol = 0
$f02DurableChain = 0
$f02IllegalRecoveryHistory = 0
$f02IllegalFailureHistory = 0
$f02LegalRecoveryHistory = 0
$f02LegalFailureHistory = 0
$f02WriterObservedCount = 0
$f02TableCount = 0
$f02ExpectedCount = 0
$f02MissingRows = 0
$f02ExtraRows = 0
$f02DuplicateRows = 0
$f02ScenarioCount = 0
$f02ScenarioNames = @()
$f02WriterObservedRows = @()
$f02TableRows = @()
$f02R5PrebindRecoveryPreserved = 0
$f02R5TerminalPublishingPreserved = 0
$f02RawObservationCount = 0
$f02SubmittedCount = 0
$f02WriterUniqueCount = 0
$f02ProductionDuplicateCount = 0
$f02DuplicateProvenance = [Collections.Generic.List[object]]::new()
$f02TupleProvenance = [Collections.Generic.List[object]]::new()
$f02ClosedAccounting = 0
$f02CaptureFilterAbsent = 0
$f02OwnerLocalDedupeAbsent = 0
$f02SameKeyByteObservation = 0
$f02ChangedKeyRecoveryObservation = 0
$f02DuplicateProbe = 0
$f02DuplicateProbeProvenance = @()
$f02PerCallRaw = [Collections.Generic.List[object]]::new()
$f02IndependentExpectedCount = 0
$f02R6RecoverForwardTurnBoundCrash = 0
$f02R6RecoverForwardInProgressCrash = 0
$f02R6RecoverForwardRepeatTerminal = 0
$f02R6RecoverForwardPublishingCrash = 0
$f02R7RecoveryCommitLifecycle = 0
$f02R7MarkerPrebindRecovery = 0
$f02R7SuccessiveRecoveryCrashes = 0
$f02R7RecoveredFailed = 0
$f02R7RecoveredInterrupted = 0
$f02R7UnfilteredWriterEquality = 0
$f02R8IndependentOracle = 0
$f02R8WriterScopedCuts = 0
$f02R8ProcessDeathCuts = 0
$f02R8CutResults = [Collections.Generic.List[object]]::new()
$f03AtomicPublish = 0
$f03CrashBeforeTerminalIntent = 0
$f03CrashAfterTerminalIntent = 0
$f03CrashAfterTerminalFinal = 0
$f03CrashAfterTerminalBound = 0
$f03CrashAfterTerminalRun = 0
$f03CrashAfterTerminalResult = 0
$f04ServiceTierDefault = 0
$f05CompatibilityIdentity = 0
$f06StatusContainment = 0
$f07PublicErrorPrivacy = 0
$nondefaultTurnStarts = 0
$privacyNeedleHits = 0

function Assert-CasInt {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Invoke-CasIntScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [int]$TimeoutMs = 0
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    foreach ($argument in @($Arguments)) { [void]$info.ArgumentList.Add([string]$argument) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($TimeoutMs -gt 0) {
            if (-not $process.WaitForExit($TimeoutMs)) {
                try { $process.Kill($true) } catch { }
                $null = $process.WaitForExit(2000)
            }
        } else {
            $process.WaitForExit()
        }
        $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
        $json = $null
        try { $json = ($stdout | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String } catch { $json = $null }
        return [ordered]@{
            exit_code = [int]$process.ExitCode
            stdout = $stdout
            stderr = $stderr
            json = $json
        }
    } finally {
        $process.Dispose()
    }
}

function New-CasIntHarness {
    param([string]$Name)
    $root = Join-Path $TestRoot $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $worktree = Join-Path $root 'worktree'
    [IO.Directory]::CreateDirectory($worktree) | Out-Null
    $state = Join-Path $root 'state'
    [IO.Directory]::CreateDirectory($state) | Out-Null
    $promptPath = Join-Path $root 'callback.md'
    $secret = 'SECRET_PROMPT_BODY_DO_NOT_STORE_9f3a'
    [IO.File]::WriteAllText($promptPath, ("Telephone Line callback identity only.`n$secret`n"), [Text.UTF8Encoding]::new($false))
    $profilePath = Join-Path $state 'profile.json'
    $bindingPath = Join-Path $root 'lead-binding.json'
    $env:TELEPHONE_TEST_APP_SERVER_NO_WATCHDOG = '1'
    return [ordered]@{
        root = $root
        worktree = $worktree
        state = $state
        prompt = $promptPath
        secret = $secret
        profile = $profilePath
        binding = $bindingPath
    }
}

function Get-CasIntCodexCommand {
    param([string]$CodexCommand = '')
    if (-not [string]::IsNullOrWhiteSpace($CodexCommand)) { return [IO.Path]::GetFullPath($CodexCommand) }
    return $mock
}

function Invoke-CasIntProfile {
    param($Harness, [string]$CodexCommand = '')
    $exe = Get-CasIntCodexCommand -CodexCommand $CodexCommand
    $result = Invoke-CasIntScript -ScriptPath $profileScript -Arguments @(
        '-CodexCommand', $exe, '-OutputPath', [string]$Harness.profile
    )
    Assert-CasInt ($result.exit_code -eq 0) ("Profile bind failed: $($result.stderr) $($result.stdout)")
    return $result.json
}

function Invoke-CasIntBuilder {
    param(
        $Harness,
        [string]$ResumeSessionId = '',
        [string]$Transport = 'app-server',
        [string]$CliLauncher = '',
        [string]$BindingOutputPath = '',
        [string]$StateRoot = ''
    )
    $binding = [string]$BindingOutputPath
    if ([string]::IsNullOrWhiteSpace($binding)) { $binding = [string]$Harness.binding }
    $state = [string]$StateRoot
    if ([string]::IsNullOrWhiteSpace($state)) { $state = [string]$Harness.state }
    $args = [Collections.Generic.List[string]]::new()
    foreach ($item in @(
        '-WorktreePath', [string]$Harness.worktree,
        '-StateRoot', $state,
        '-BindingOutputPath', $binding,
        '-CallbackTransport', $Transport,
        '-CodexCommand', $mock,
        '-ProfilePath', [string]$Harness.profile
    )) { $args.Add($item) }
    if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) {
        $args.Add('-ResumeSessionId'); $args.Add($ResumeSessionId)
    }
    if (-not [string]::IsNullOrWhiteSpace($CliLauncher)) {
        $args.Add('-CliLauncher'); $args.Add($CliLauncher)
    }
    return Invoke-CasIntScript -ScriptPath $builderScript -Arguments @($args)
}

function Invoke-CasIntDurableCreate {
    param($Harness, [string]$RunId, [string]$CodexCommand = '')
    $exe = Get-CasIntCodexCommand -CodexCommand $CodexCommand
    $script:casIntLastInvocation = [ordered]@{ kind = 'durable-create'; harness = $Harness; thread_id = ''; run_id = $RunId; result = $null }
    $result = Invoke-CasIntScript -ScriptPath $builderScript -Arguments @(
        '-WorktreePath', [string]$Harness.worktree,
        '-StateRoot', [string]$Harness.state,
        '-BindingOutputPath', [string]$Harness.binding,
        '-CallbackTransport', 'app-server',
        '-CodexCommand', $exe,
        '-ProfilePath', [string]$Harness.profile,
        '-PromptFile', [string]$Harness.prompt,
        '-RunId', $RunId
    )
    $script:casIntLastInvocation.result = $result
    return $result
}

function Get-CasIntDurableCreateFailureDiagnostic {
    param($Harness, [string]$RunId, $Result)
    $paths = Get-CodexAppServerRunPaths -StateRoot ([string]$Harness.state) -RunId $RunId
    $present = [Collections.Generic.List[string]]::new()
    foreach ($name in @('owner', 'child', 'intent', 'run', 'bound_turn', 'transitions', 'status', 'ack', 'final', 'recovery', 'result', 'failure', 'stderr_evidence', 'read_lifetime')) {
        if ([IO.File]::Exists([string]$paths[$name])) { $present.Add($name) }
    }
    $ownerAlive = $false
    if ([IO.File]::Exists($paths.owner)) {
        try { $ownerAlive = Test-TelephoneOwnerAlive -Owner ((Read-TelephoneJson -Path $paths.owner).value) } catch { $ownerAlive = $false }
    }
    $childAlive = $false
    if ([IO.File]::Exists($paths.child)) {
        try { $childAlive = Test-TelephoneOwnerAlive -Owner ((Read-TelephoneJson -Path $paths.child).value) } catch { $childAlive = $false }
    }
    $failureCategory = ''
    $failureCode = ''
    $failurePhase = ''
    $failureDisposition = ''
    if ([IO.File]::Exists($paths.failure)) {
        try {
            $failure = (Read-TelephoneJson -Path $paths.failure -SchemaName 'codex-app-server-lead-failure').value
            $failureCategory = Get-CodexAppServerDictString -Dict $failure -Key 'category'
            $failureCode = Get-CodexAppServerDictString -Dict $failure -Key 'code'
            $failurePhase = Get-CodexAppServerDictString -Dict $failure -Key 'callback_write_phase'
            $failureDisposition = Get-CodexAppServerDictString -Dict $failure -Key 'disposition'
        } catch { $failureCode = 'diagnostic_read_failed' }
    }
    $resultStarted = $false
    $resultState = ''
    $resultFallback = ''
    if ([IO.File]::Exists($paths.result)) {
        try {
            $resultDoc = (Read-TelephoneJson -Path $paths.result -SchemaName 'codex-app-server-lead-result').value
            if ($resultDoc.Contains('started')) { $resultStarted = [bool]$resultDoc.started }
            $resultState = Get-CodexAppServerDictString -Dict $resultDoc -Key 'state'
            $resultFallback = Get-CodexAppServerDictString -Dict $resultDoc -Key 'fallback_required'
        } catch { $resultState = 'diagnostic_read_failed' }
    }
    $transitionStates = [Collections.Generic.List[string]]::new()
    if ([IO.File]::Exists($paths.transitions)) {
        $transitionLines = @()
        try { $transitionLines = @([IO.File]::ReadAllLines($paths.transitions)) } catch [IO.IOException] { $transitionStates.Add('temporarily_unreadable') } catch { $transitionStates.Add('diagnostic_read_failed') }
        foreach ($line in $transitionLines) {
            try {
                $transition = $line | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
                if ($transition -is [Collections.IDictionary] -and $transition.Contains('state')) { $transitionStates.Add([string]$transition.state) }
            } catch { $transitionStates.Add('diagnostic_read_failed') }
        }
    }
    $stderrCategory = ''
    $stderrLineCount = 0
    $stderrByteCount = 0
    if ([IO.File]::Exists($paths.stderr_evidence)) {
        try {
            $stderrEvidence = (Read-TelephoneJson -Path $paths.stderr_evidence).value
            $stderrCategory = Get-CodexAppServerDictString -Dict $stderrEvidence -Key 'category'
            if ($stderrEvidence.Contains('line_count')) { $stderrLineCount = [int]$stderrEvidence.line_count }
            if ($stderrEvidence.Contains('byte_count')) { $stderrByteCount = [int64]$stderrEvidence.byte_count }
        } catch { $stderrCategory = 'diagnostic_read_failed' }
    }
    return [ordered]@{
        exit_code = [int]$Result.exit_code
        run_root_exists = [IO.Directory]::Exists($paths.run_root)
        binding_exists = [IO.File]::Exists([string]$Harness.binding)
        store_exists = [IO.File]::Exists($paths.store)
        present_artifacts = @($present)
        owner_alive = $ownerAlive
        child_alive = $childAlive
        failure_category = $failureCategory
        failure_code = $failureCode
        failure_phase = $failurePhase
        failure_disposition = $failureDisposition
        result_started = $resultStarted
        result_state = $resultState
        result_fallback = $resultFallback
        transition_states = @($transitionStates)
        stderr_category = $stderrCategory
        stderr_line_count = $stderrLineCount
        stderr_byte_count = $stderrByteCount
    }
}

function Invoke-CasIntLauncher {
    param($Harness, [string]$ThreadId, [string]$RunId, [string]$CodexCommand = '')
    $exe = Get-CasIntCodexCommand -CodexCommand $CodexCommand
    $script:casIntLastInvocation = [ordered]@{ kind = 'launcher'; harness = $Harness; thread_id = $ThreadId; run_id = $RunId; result = $null }
    $result = Invoke-CasIntScript -ScriptPath $launcherScript -Arguments @(
        '-WorktreePath', [string]$Harness.worktree,
        '-PromptFile', [string]$Harness.prompt,
        '-ResumeSessionId', $ThreadId,
        '-RunId', $RunId,
        '-StateRoot', [string]$Harness.state,
        '-CodexCommand', $exe,
        '-ProfilePath', [string]$Harness.profile
    )
    $script:casIntLastInvocation.result = $result
    return $result
}

function Invoke-CasIntWorker {
    param($Harness, [string]$ThreadId, [string]$RunId)
    return Invoke-CasIntScript -ScriptPath $workerScript -Arguments @(
        '-WorktreePath', [string]$Harness.worktree,
        '-PromptFile', [string]$Harness.prompt,
        '-ResumeSessionId', $ThreadId,
        '-RunId', $RunId,
        '-StateRoot', [string]$Harness.state,
        '-CodexCommand', $mock,
        '-ProfilePath', [string]$Harness.profile
    )
}

function Start-CasIntLauncherProcess {
    param($Harness, [string]$ThreadId, [string]$RunId)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $launcherScript,
        '-WorktreePath', [string]$Harness.worktree,
        '-PromptFile', [string]$Harness.prompt,
        '-ResumeSessionId', $ThreadId,
        '-RunId', $RunId,
        '-StateRoot', [string]$Harness.state,
        '-CodexCommand', $mock,
        '-ProfilePath', [string]$Harness.profile
    )) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    return [ordered]@{
        process = $process
        stdout = $process.StandardOutput.ReadToEndAsync()
        stderr = $process.StandardError.ReadToEndAsync()
    }
}

function Get-CasIntStoreTurns {
    param($Harness, [string]$ThreadId, [string]$StorePath = '')
    $resolved = [string]$StorePath
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = Join-Path $Harness.state 'app-server-store.json' }
    if (-not [IO.File]::Exists($resolved)) { return @() }
    $store = (Read-TelephoneJson -Path $resolved).value
    if ($store -isnot [Collections.IDictionary] -or -not $store.Contains('threads')) { return @() }
    $thread = $store.threads[$ThreadId]
    if ($thread -isnot [Collections.IDictionary]) { return @() }
    return @($thread.turns)
}

function Set-CasIntStoreTurnStatus {
    param($Harness, [string]$ThreadId, [string]$TurnId, [string]$Status, [string]$StorePath = '')
    $resolved = [string]$StorePath
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = Join-Path $Harness.state 'app-server-store.json' }
    Assert-CasInt ([IO.File]::Exists($resolved)) 'Mock provider store is missing.'
    $store = (Read-TelephoneJson -Path $resolved).value
    Assert-CasInt ($store -is [Collections.IDictionary] -and $store.Contains('threads')) 'Mock provider store has no threads.'
    $thread = $store.threads[$ThreadId]
    Assert-CasInt ($thread -is [Collections.IDictionary]) 'Mock provider thread is missing.'
    $updated = [Collections.Generic.List[object]]::new()
    $found = $false
    foreach ($turn in (Get-CodexAppServerJsonArrayItems -Value (Get-CodexAppServerDictObject -Dict $thread -Key 'turns'))) {
        if ($turn -is [Collections.IDictionary] -and (Get-CodexAppServerDictString -Dict $turn -Key 'id') -ceq $TurnId) {
            $turn.status = [string]$Status
            if ([string]$Status -ceq 'completed' -or [string]$Status -ceq 'failed' -or [string]$Status -ceq 'interrupted') {
                $now = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $turn.completedAt = $now
                $turn.durationMs = 1
            }
            $found = $true
        }
        $updated.Add($turn)
    }
    Assert-CasInt $found 'Mock provider turn is missing from the store.'
    $thread.turns = @($updated)
    $store.threads[$ThreadId] = $thread
    $json = (($store | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n")
    [IO.File]::WriteAllText($resolved, $json, [Text.UTF8Encoding]::new($false))
}

function Get-CasIntAdapterFiles {
    param($Harness, [string]$RunId)
    $runRoot = Join-Path $Harness.state ('runs\' + $RunId)
    $names = @(
        'intent.json', 'run.json', 'status.json', 'bound-turn.json', 'owner.json',
        'child.json', 'lead-wake-ack.json', 'launcher-final.txt', 'transitions.jsonl',
        'launcher-result.json', 'failure.json', 'stderr-evidence.json', 'read-lifetime.json'
    )
    $files = [Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        $path = Join-Path $runRoot $name
        if ([IO.File]::Exists($path)) { $files.Add($path) }
    }
    $profile = Join-Path $Harness.state 'profile.json'
    if ([IO.File]::Exists($profile)) { $files.Add($profile) }
    return @($files)
}

function Get-CasIntRunRoot {
    param($Harness, [string]$RunId)
    return Join-Path $Harness.state ('runs\' + $RunId)
}

function Wait-CasIntPath {
    param([string]$Path, [int]$TimeoutMs = 30000)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    while (-not [IO.File]::Exists($Path) -and [DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    return [IO.File]::Exists($Path)
}

function Test-CasIntOwnerAlive {
    param($Harness, [string]$RunId)
    $path = Join-Path (Get-CasIntRunRoot -Harness $Harness -RunId $RunId) 'owner.json'
    if (-not [IO.File]::Exists($path)) { return $false }
    try {
        return (Test-TelephoneOwnerAlive -Owner ((Read-TelephoneJson -Path $path).value))
    } catch {
        if ($_.Exception -is [IO.IOException] -or $_.Exception.InnerException -is [IO.IOException]) { return $true }
        return $false
    }
}

function Clear-CasIntTestEnv {
    param([string[]]$Names = @())
    $targets = @(
        'TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT', 'TELEPHONE_TEST_APP_SERVER_LEAD_THROW_AT', 'TELEPHONE_TEST_APP_SERVER_CRASH_AT',
        'TELEPHONE_TEST_APP_SERVER_TURN_STATUS', 'TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH',
        'TELEPHONE_TEST_APP_SERVER_EVENT_LOG', 'TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS',
        'TELEPHONE_TEST_APP_SERVER_STATUS', 'TELEPHONE_TEST_APP_SERVER_ACTIVE_FLAGS',
        'TELEPHONE_TEST_APP_SERVER_PENDING_METHOD', 'TELEPHONE_TEST_APP_SERVER_PENDING_ID',
        'TELEPHONE_TEST_APP_SERVER_PENDING_METHODS', 'TELEPHONE_TEST_APP_SERVER_POST_START_SEQUENCE',
        'TELEPHONE_TEST_APP_SERVER_RESOLVE_PENDING', 'TELEPHONE_TEST_APP_SERVER_INJECT_FOREIGN',
        'TELEPHONE_TEST_APP_SERVER_RETURN_TIER', 'TELEPHONE_TEST_APP_SERVER_VERSION',
        'TELEPHONE_TEST_APP_SERVER_SCHEMA_FAIL', 'TELEPHONE_TEST_APP_SERVER_VERSION_FAIL',
        'TELEPHONE_TEST_APP_SERVER_FORMER_READ_TIMEOUT_MS', 'TELEPHONE_TEST_APP_SERVER_POST_START_DELAY_MS',
        'TELEPHONE_TEST_APP_SERVER_SCHEMA_EXTRA', 'TELEPHONE_TEST_APP_SERVER_UNWRAP_THREAD',
        'TELEPHONE_TEST_APP_SERVER_UNWRAP_TURN', 'TELEPHONE_TEST_APP_SERVER_TURN_START_EXTRA',
        'TELEPHONE_TEST_APP_SERVER_OMIT_WRAPPER_FIELD', 'TELEPHONE_TEST_APP_SERVER_INJECT_PROTOCOL_NEGATIVES',
        'TELEPHONE_TEST_APP_SERVER_PUBLISH_CRASH_AT', 'TELEPHONE_TEST_APP_SERVER_INHERITED_TIER',
        'TELEPHONE_TEST_APP_SERVER_OMIT_SERVICE_TIER', 'TELEPHONE_TEST_APP_SERVER_OMIT_THREAD_ID',
        'TELEPHONE_TEST_APP_SERVER_FOREIGN_THREAD_ID', 'TELEPHONE_TEST_APP_SERVER_OMIT_TURN_ID',
        'TELEPHONE_TEST_APP_SERVER_FOREIGN_TURN_ID',
        'TELEPHONE_TEST_APP_SERVER_EMIT_OPTIONAL_0147', 'TELEPHONE_TEST_APP_SERVER_RETURN_NULL_TIER',
        'TELEPHONE_TEST_APP_SERVER_RETURN_EMPTY_TIER', 'TELEPHONE_TEST_APP_SERVER_UNKNOWN_WRAPPER_KEY',
        'TELEPHONE_TEST_APP_SERVER_UNKNOWN_THREAD_KEY', 'TELEPHONE_TEST_APP_SERVER_MALFORMED_OPTIONAL',
        'TELEPHONE_TEST_APP_SERVER_0147_COMPAT', 'TELEPHONE_TEST_APP_SERVER_PROJECT_ID_NULL',
        'TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS', 'TELEPHONE_TEST_APP_SERVER_ACK_TIMEOUT_SECONDS',
        'TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_TURN_ID', 'TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_HOLD_PATH',
        'TELEPHONE_TEST_APP_SERVER_TURN_START_ERROR_MESSAGE', 'TELEPHONE_TEST_APP_SERVER_TURN_START_ERROR_CODE',
        'TELEPHONE_TEST_APP_SERVER_CRASH_ON_NTH', 'TELEPHONE_TEST_APP_SERVER_CRASH_COUNT_PATH',
        'TELEPHONE_TEST_APP_SERVER_CRASH_ONCE_PATH',
        'TELEPHONE_TEST_APP_SERVER_ARCHIVED_RESUME_ONCE', 'TELEPHONE_TEST_APP_SERVER_ARCHIVED_RESUME_JSON_ONCE',
        'TELEPHONE_TEST_CODEX_COMMAND_LOG',
        'TELEPHONE_TEST_UNARCHIVE_EXIT', 'TELEPHONE_APP_SERVER_THREAD_STORE', 'TELEPHONE_TEST_APP_SERVER_STORE'
    )
    if (@($Names).Count -gt 0) { $targets = @($Names) }
    foreach ($name in $targets) {
        Remove-Item -Path ('env:' + $name) -ErrorAction SilentlyContinue
    }
}

function Stop-CasIntThreadOwner {
    param($Harness, [string]$ThreadId)
    if ([string]::IsNullOrWhiteSpace($ThreadId)) { return }
    $path = Join-Path $Harness.state ('threads\' + $ThreadId + '\owner.json')
    if (-not [IO.File]::Exists($path)) { return }
    $rec = $null
    try {
        $rec = (Read-TelephoneJson -Path $path).value
        if (Test-TelephoneOwnerAlive -Owner $rec) {
            try { Stop-Process -Id ([int]$rec.pid) -Force -ErrorAction SilentlyContinue } catch { }
        }
    } catch { }
    if ($null -ne $rec) {
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
        while ((Test-TelephoneOwnerAlive -Owner $rec) -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    }
}

function Stop-CasIntRun {
    param($Harness, [string]$RunId)
    $root = Get-CasIntRunRoot -Harness $Harness -RunId $RunId
    $threadId = ''
    foreach ($name in @('owner.json', 'child.json', 'lifecycle-owner.json', 'run.json', 'intent.json')) {
        $path = Join-Path $root $name
        if (-not [IO.File]::Exists($path)) { continue }
        try {
            $rec = (Read-TelephoneJson -Path $path).value
            if ([string]::IsNullOrWhiteSpace($threadId)) {
                $threadId = Get-CodexAppServerDictString -Dict $rec -Key 'thread_id'
            }
            if ($name -ceq 'run.json' -or $name -ceq 'intent.json') { continue }
            if (Test-TelephoneOwnerAlive -Owner $rec) {
                try { Stop-Process -Id ([int]$rec.pid) -Force -ErrorAction SilentlyContinue } catch { }
            }
        } catch { }
    }
    Stop-CasIntThreadOwner -Harness $Harness -ThreadId $threadId
}

function Get-CasIntThreadOwnerPath {
    param($Harness, [string]$ThreadId)
    return Join-Path $Harness.state ('threads\' + $ThreadId + '\owner.json')
}

function Test-CasIntThreadOwnerAlive {
    param($Harness, [string]$ThreadId)
    $path = Get-CasIntThreadOwnerPath -Harness $Harness -ThreadId $ThreadId
    if (-not [IO.File]::Exists($path)) { return $false }
    try {
        return (Test-TelephoneOwnerAlive -Owner ((Read-TelephoneJson -Path $path).value))
    } catch {
        return $true
    }
}

function Wait-CasIntThreadOwnerQuiet {
    param($Harness, [string]$ThreadId, [int]$TimeoutMs = 30000)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    $observedIdentity = Get-CasIntThreadOwnerIdentityKey -Harness $Harness -ThreadId $ThreadId
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $currentIdentity = Get-CasIntThreadOwnerIdentityKey -Harness $Harness -ThreadId $ThreadId
        if (-not [string]::IsNullOrWhiteSpace($currentIdentity)) { $observedIdentity = $currentIdentity }
        if (-not (Test-CasIntThreadOwnerAlive -Harness $Harness -ThreadId $ThreadId) -and -not (Test-CasIntIdentityKeyAlive -IdentityKey $observedIdentity)) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Wait-CasIntRunQuiet {
    param($Harness, [string]$RunId, [int]$TimeoutMs = 30000)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (-not (Test-CasIntOwnerAlive -Harness $Harness -RunId $RunId)) { return $true }
        Start-Sleep -Milliseconds 50
    }
    Stop-CasIntRun -Harness $Harness -RunId $RunId
    Start-Sleep -Milliseconds 200
    return -not (Test-CasIntOwnerAlive -Harness $Harness -RunId $RunId)
}

function Wait-CasIntRunOwnerQuiet {
    param($Harness, [string]$RunId, [int]$TimeoutMs = 30000)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    $observedOwner = Get-CasIntRunOwnerIdentityKey -Harness $Harness -RunId $RunId
    $observedChild = Get-CasIntChildIdentityKey -Harness $Harness -RunId $RunId
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $currentOwner = Get-CasIntRunOwnerIdentityKey -Harness $Harness -RunId $RunId
        $currentChild = Get-CasIntChildIdentityKey -Harness $Harness -RunId $RunId
        if (-not [string]::IsNullOrWhiteSpace($currentOwner)) { $observedOwner = $currentOwner }
        if (-not [string]::IsNullOrWhiteSpace($currentChild)) { $observedChild = $currentChild }
        if (-not (Test-CasIntOwnerAlive -Harness $Harness -RunId $RunId) -and -not (Test-CasIntIdentityKeyAlive -IdentityKey $observedOwner) -and -not (Test-CasIntIdentityKeyAlive -IdentityKey $observedChild)) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Test-CasIntOfficialTerminal {
    param($Harness, [string]$RunId, [string]$ThreadId, [string]$TurnId, [string]$Disposition = 'completed')
    try {
        $run = Get-CasIntRunJson -Harness $Harness -RunId $RunId
        if ([string]$run.disposition -cne $Disposition) { return $false }
        if ([string]$run.callback_write_phase -cne 'terminal') { return $false }
        if ([string]$run.thread_id -cne $ThreadId) { return $false }
        if (-not [string]::IsNullOrWhiteSpace($TurnId) -and [string]$run.selected_turn_id -cne $TurnId) { return $false }
        if ((Get-CasIntFinalText -Harness $Harness -RunId $RunId) -cne $Disposition) { return $false }
        $paths = Get-CodexAppServerRunPaths -StateRoot ([string]$Harness.state) -RunId $RunId
        if (-not [IO.File]::Exists([string]$paths.result)) { return $false }
        $result = (Read-TelephoneJson -Path ([string]$paths.result) -SchemaName 'codex-app-server-lead-result').value
        if ([string]$result.state -cne $Disposition) { return $false }
        if ([string]$result.run_id -cne $RunId) { return $false }
        $bound = Get-CasIntBoundJson -Harness $Harness -RunId $RunId
        if ([string]$bound.turn_id -cne $TurnId) { return $false }
        if ([string]$bound.thread_id -cne $ThreadId) { return $false }
        if ([string]$bound.state -cne $Disposition) { return $false }
        return $true
    } catch {
        return $false
    }
}

function Wait-CasIntOfficialTerminal {
    param($Harness, [string]$RunId, [string]$ThreadId, [string]$TurnId, [string]$Disposition = 'completed', [int]$TimeoutMs = 30000)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-CasIntOfficialTerminal -Harness $Harness -RunId $RunId -ThreadId $ThreadId -TurnId $TurnId -Disposition $Disposition) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Invoke-CasIntAppServerDeathRecoveryProof {
    param([string]$Name = 'death-app-server')
    $hdth = New-CasIntHarness -Name $Name
    $null = Invoke-CasIntProfile -Harness $hdth
    $bdth = Invoke-CasIntBuilder -Harness $hdth
    $tidd = [string]$bdth.json.thread_id
    $ridd = 'run-death-app'
    $holdDeath = Join-Path $hdth.root 'hold-completed'
    $deathLog = Join-Path $hdth.root 'death-events.log'
    $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdDeath
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $deathLog
    $d1 = Invoke-CasIntLauncher -Harness $hdth -ThreadId $tidd -RunId $ridd
    Assert-CasInt ($d1.exit_code -eq 0) ("App-server death first launch failed: $($d1.stderr)")
    $boundDeath = Get-CasIntBoundJson -Harness $hdth -RunId $ridd
    $childPath = Join-Path (Get-CasIntRunRoot -Harness $hdth -RunId $ridd) 'child.json'
    Assert-CasInt (Wait-CasIntPath -Path $childPath) 'Child identity is missing.'
    $child = (Read-TelephoneJson -Path $childPath).value
    try { Stop-Process -Id ([int]$child.pid) -Force -ErrorAction SilentlyContinue } catch { }
    $deadBy = [DateTimeOffset]::UtcNow.AddSeconds(20)
    while ((Test-CasIntOwnerAlive -Harness $hdth -RunId $ridd) -and [DateTimeOffset]::UtcNow -lt $deadBy) { Start-Sleep -Milliseconds 50 }
    Assert-CasInt (-not (Test-CasIntOwnerAlive -Harness $hdth -RunId $ridd)) 'App-server death left a live worker.'
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hdth -RunId $ridd).disposition -ceq 'recovery_required') 'App-server death did not persist recovery_required.'
    Assert-CasInt ([string](Get-CasIntBoundJson -Harness $hdth -RunId $ridd).state -ceq 'recovery_required') 'App-server death bound state was not recovery_required.'
    Assert-CasInt ([string](Get-CasIntFinalText -Harness $hdth -RunId $ridd) -ceq '') 'App-server death wrote a false final.'
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hdth -RunId $ridd).disposition -cne 'interrupted') 'App-server death inferred official interrupted.'
    Assert-CasInt ([string](Get-CasIntBoundJson -Harness $hdth -RunId $ridd).turn_id -ceq [string]$boundDeath.turn_id) 'App-server death changed the selected turn.'
    [IO.File]::WriteAllText($holdDeath, 'release', [Text.UTF8Encoding]::new($false))
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH -ErrorAction SilentlyContinue
    $d2 = Invoke-CasIntLauncher -Harness $hdth -ThreadId $tidd -RunId $ridd
    Assert-CasInt ($d2.exit_code -eq 0) ("App-server death recovery failed: $($d2.stderr) $($d2.stdout)")
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hdth -ThreadId $tidd).Count -eq 1) 'App-server death recovery started a second turn.'
    Assert-CasInt ([string](Get-CasIntBoundJson -Harness $hdth -RunId $ridd).turn_id -ceq [string]$boundDeath.turn_id) 'App-server death recovered a different turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $deathLog -Name 'turn/start') -eq 1) 'App-server death recovery sent a replacement turn/start.'
    Assert-CasInt (Wait-CasIntOfficialTerminal -Harness $hdth -RunId $ridd -ThreadId $tidd -TurnId ([string]$boundDeath.turn_id) -Disposition 'completed' -TimeoutMs 30000) 'App-server death recovery did not publish official completed terminal.'
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hdth -RunId $ridd).disposition -ceq 'completed') 'App-server death did not converge on the matching terminal.'
    Assert-CasInt ([string](Get-CasIntFinalText -Harness $hdth -RunId $ridd) -ceq 'completed') 'App-server death recovery did not write the matching final.'
    $perRunQuiet = Wait-CasIntRunOwnerQuiet -Harness $hdth -RunId $ridd -TimeoutMs 20000
    $threadQuiet = Wait-CasIntThreadOwnerQuiet -Harness $hdth -ThreadId $tidd -TimeoutMs 20000
    $perRunAliveAfter = Test-CasIntOwnerAlive -Harness $hdth -RunId $ridd
    $threadAliveAfter = Test-CasIntThreadOwnerAlive -Harness $hdth -ThreadId $tidd
    Assert-CasInt $perRunQuiet 'App-server death per-run owner did not quiesce naturally.'
    Assert-CasInt $threadQuiet 'App-server death thread owner did not quiesce naturally.'
    Assert-CasInt (-not $perRunAliveAfter) 'App-server death left a live per-run owner after natural-quiesce observation.'
    Assert-CasInt (-not $threadAliveAfter) 'App-server death left a live thread owner after natural-quiesce observation.'
    $script:naturalQuiesceObservationOnly = 1
    if ($perRunAliveAfter -or $threadAliveAfter) { Stop-CasIntRun -Harness $hdth -RunId $ridd }
    Clear-CasIntTestEnv
    $script:appserverDeathSameTurn = 1
    $script:recoveryRequired = 1
    $script:appServerDeathRecoveryFocused = 1
}

function Invoke-CasIntWorkerDeathRecoveryProof {
    param([string]$Name = 'death-worker')
    $hwd = New-CasIntHarness -Name $Name
    $null = Invoke-CasIntProfile -Harness $hwd
    $bwd = Invoke-CasIntBuilder -Harness $hwd
    $tidw = [string]$bwd.json.thread_id
    $ridw = 'run-death-worker'
    $holdWorker = Join-Path $hwd.root 'hold-completed'
    $workerLog = Join-Path $hwd.root 'worker-death-events.log'
    $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdWorker
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $workerLog
    $w1 = Invoke-CasIntLauncher -Harness $hwd -ThreadId $tidw -RunId $ridw
    Assert-CasInt ($w1.exit_code -eq 0) ("Worker death first launch failed: $($w1.stderr)")
    $boundW = Get-CasIntBoundJson -Harness $hwd -RunId $ridw
    Stop-CasIntRun -Harness $hwd -RunId $ridw
    $deadW = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while ((Test-CasIntOwnerAlive -Harness $hwd -RunId $ridw) -and [DateTimeOffset]::UtcNow -lt $deadW) { Start-Sleep -Milliseconds 50 }
    Assert-CasInt (-not (Test-CasIntOwnerAlive -Harness $hwd -RunId $ridw)) 'Worker death left a live per-run owner.'
    Assert-CasInt ([string](Get-CasIntFinalText -Harness $hwd -RunId $ridw) -ceq '') 'Worker death wrote a false final.'
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hwd -RunId $ridw).disposition -cne 'interrupted') 'Worker death inferred official interrupted.'
    Assert-CasInt ([string](Get-CasIntBoundJson -Harness $hwd -RunId $ridw).turn_id -ceq [string]$boundW.turn_id) 'Worker death changed the selected turn.'
    [IO.File]::WriteAllText($holdWorker, 'release', [Text.UTF8Encoding]::new($false))
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH -ErrorAction SilentlyContinue
    $w2 = Invoke-CasIntLauncher -Harness $hwd -ThreadId $tidw -RunId $ridw
    Assert-CasInt ($w2.exit_code -eq 0) ("Worker death recovery failed: $($w2.stderr) $($w2.stdout)")
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hwd -ThreadId $tidw).Count -eq 1) 'Worker death recovery started a second turn.'
    Assert-CasInt ([string](Get-CasIntBoundJson -Harness $hwd -RunId $ridw).turn_id -ceq [string]$boundW.turn_id) 'Worker death recovered a different turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $workerLog -Name 'turn/start') -eq 1) 'Worker death recovery sent a replacement turn/start.'
    Assert-CasInt (Wait-CasIntOfficialTerminal -Harness $hwd -RunId $ridw -ThreadId $tidw -TurnId ([string]$boundW.turn_id) -Disposition 'completed' -TimeoutMs 30000) 'Worker death recovery did not publish official completed terminal.'
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hwd -RunId $ridw).disposition -ceq 'completed') 'Worker death did not converge on the matching terminal.'
    Assert-CasInt ([string](Get-CasIntFinalText -Harness $hwd -RunId $ridw) -ceq 'completed') 'Worker death recovery did not write the matching final.'
    $perRunQuiet = Wait-CasIntRunOwnerQuiet -Harness $hwd -RunId $ridw -TimeoutMs 20000
    $threadQuiet = Wait-CasIntThreadOwnerQuiet -Harness $hwd -ThreadId $tidw -TimeoutMs 20000
    $perRunAliveAfter = Test-CasIntOwnerAlive -Harness $hwd -RunId $ridw
    $threadAliveAfter = Test-CasIntThreadOwnerAlive -Harness $hwd -ThreadId $tidw
    Assert-CasInt $perRunQuiet 'Worker death per-run owner did not quiesce naturally.'
    Assert-CasInt $threadQuiet 'Worker death thread owner did not quiesce naturally.'
    Assert-CasInt (-not $perRunAliveAfter) 'Worker death left a live per-run owner after natural-quiesce observation.'
    Assert-CasInt (-not $threadAliveAfter) 'Worker death left a live thread owner after natural-quiesce observation.'
    $script:workerDeathOfficialTerminal = 1
    $script:workerDeathNaturalQuiesceObservationOnly = 1
    if ($perRunAliveAfter -or $threadAliveAfter) { Stop-CasIntRun -Harness $hwd -RunId $ridw }
    Clear-CasIntTestEnv
    $script:workerDeathSameTurn = 1
    $script:recoveryRequired = 1
}

function Invoke-CasIntCallbackContinuationProof {
    $hc = New-CasIntHarness -Name 'callback-continue'
    Remove-Item Env:TELEPHONE_TEST_APP_SERVER_NO_WATCHDOG -ErrorAction SilentlyContinue
    $null = Invoke-CasIntProfile -Harness $hc
    $bc = Invoke-CasIntBuilder -Harness $hc
    $tidc = [string]$bc.json.thread_id
    $ridc = 'run-callback-continue'
    $holdC = Join-Path $hc.root 'hold-continue'
    $logC = Join-Path $hc.root 'continue-events.log'
    $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdC
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $logC
    $c1 = Invoke-CasIntLauncher -Harness $hc -ThreadId $tidc -RunId $ridc
    Assert-CasInt ($c1.exit_code -eq 0) ("Callback continuation first launch failed: $($c1.stderr)")
    $boundC = Get-CasIntBoundJson -Harness $hc -RunId $ridc
    $ownerPath = Join-Path (Get-CasIntRunRoot -Harness $hc -RunId $ridc) 'owner.json'
    Assert-CasInt (Wait-CasIntPath -Path $ownerPath) 'Callback continuation missing owner.'
    $owner = (Read-TelephoneJson -Path $ownerPath).value
    try { Stop-Process -Id ([int]$owner.pid) -Force -ErrorAction SilentlyContinue } catch { }
    $deadBy = [DateTimeOffset]::UtcNow.AddSeconds(8)
    while ((Test-CasIntOwnerAlive -Harness $hc -RunId $ridc) -and [DateTimeOffset]::UtcNow -lt $deadBy) { Start-Sleep -Milliseconds 50 }
    $aliveBy = [DateTimeOffset]::UtcNow.AddSeconds(20)
    while (-not (Test-CasIntOwnerAlive -Harness $hc -RunId $ridc) -and [DateTimeOffset]::UtcNow -lt $aliveBy) { Start-Sleep -Milliseconds 100 }
    Assert-CasInt (Test-CasIntOwnerAlive -Harness $hc -RunId $ridc) 'Lifecycle owner restart did not continue the callback turn.'
    Assert-CasInt ([string](Get-CasIntBoundJson -Harness $hc -RunId $ridc).turn_id -ceq [string]$boundC.turn_id) 'Callback continuation changed the selected turn.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hc -ThreadId $tidc).Count -eq 1) 'Callback continuation started a second turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $logC -Name 'turn/start') -eq 1) 'Callback continuation sent a replacement turn/start.'
    [IO.File]::WriteAllText($holdC, 'release', [Text.UTF8Encoding]::new($false))
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH -ErrorAction SilentlyContinue
    Assert-CasInt (Wait-CasIntOfficialTerminal -Harness $hc -RunId $ridc -ThreadId $tidc -TurnId ([string]$boundC.turn_id) -Disposition 'completed' -TimeoutMs 30000) 'Callback continuation did not reach official completed.'
    Stop-CasIntRun -Harness $hc -RunId $ridc
    Clear-CasIntTestEnv
    $env:TELEPHONE_TEST_APP_SERVER_NO_WATCHDOG = '1'
    $script:callbackContinuationSameSession = 1

    $hm = New-CasIntHarness -Name 'callback-mismatch'
    $null = Invoke-CasIntProfile -Harness $hm
    $bm = Invoke-CasIntBuilder -Harness $hm
    $tidm = [string]$bm.json.thread_id
    $ridm = 'run-callback-mismatch'
    $holdM = Join-Path $hm.root 'hold-mismatch'
    $logM = Join-Path $hm.root 'mismatch-events.log'
    $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdM
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $logM
    $m1 = Invoke-CasIntLauncher -Harness $hm -ThreadId $tidm -RunId $ridm
    Assert-CasInt ($m1.exit_code -eq 0) ("Callback mismatch first launch failed: $($m1.stderr)")
    $boundM = Get-CasIntBoundJson -Harness $hm -RunId $ridm
    $turnsBefore = @(Get-CasIntStoreTurns -Harness $hm -ThreadId $tidm).Count
    [IO.File]::WriteAllText($hm.prompt, "Telephone Line callback identity only.`nCHANGED_RECEIPT_OR_BINDING`n", [Text.UTF8Encoding]::new($false))
    Stop-CasIntRun -Harness $hm -RunId $ridm
    $m2 = Invoke-CasIntLauncher -Harness $hm -ThreadId $tidm -RunId $ridm
    Assert-CasInt ($m2.exit_code -ne 0) 'Binding/receipt mismatch was allowed to continue the callback.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hm -ThreadId $tidm).Count -eq $turnsBefore) 'Mismatch continuation sent another turn.'
    Assert-CasInt ([string](Get-CasIntBoundJson -Harness $hm -RunId $ridm).turn_id -ceq [string]$boundM.turn_id) 'Mismatch continuation mutated the bound turn.'
    [IO.File]::WriteAllText($holdM, 'release', [Text.UTF8Encoding]::new($false))
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH -ErrorAction SilentlyContinue
    Clear-CasIntTestEnv
    $script:callbackContinuationMismatchRefused = 1
}

function Write-CasIntWakeAmbiguityQueuedWorld {
    param(
        $Harness,
        [string]$ThreadId,
        [string]$RunId,
        [string]$Phase = 'none',
        [string]$Disposition = 'in_progress'
    )
    $paths = Write-CasIntPlantedIntent -Harness $Harness -RunId $RunId -ThreadId $ThreadId -Baseline @()
    Write-CasIntPlantedRun -Paths $paths -Harness $Harness -RunId $RunId -ThreadId $ThreadId -Selected '' -Disposition $Disposition -Baseline @() -Phase $Phase -QueueState 'callback_active'
    Write-CasIntPlantedFailure -Paths $paths -RunId $RunId -ThreadId $ThreadId -TurnId '' -Phase $Phase -Disposition $Disposition -Category 'worker' -Code 'worker_failed'
    return $paths
}

function Assert-CasIntWakeBaselineEmpty {
    param($Harness, [string]$RunId)
    $paths = Get-CodexAppServerRunPaths -StateRoot ([string]$Harness.state) -RunId $RunId
    $intent = (Read-TelephoneJson -Path $paths.intent -SchemaName 'codex-app-server-lead-intent').value
    $run = Get-CasIntRunJson -Harness $Harness -RunId $RunId
    Assert-CasInt (@(Get-CodexAppServerStringList -Value $intent.baseline_turn_ids).Count -eq 0) 'Stored intent baseline was mutated.'
    Assert-CasInt (@(Get-CodexAppServerStringList -Value $run.baseline_turn_ids).Count -eq 0) 'Stored run baseline was mutated.'
}

function Add-CasIntStoreTurn {
    param(
        $Harness,
        [string]$ThreadId,
        [string]$TurnId,
        [string]$Status = 'completed',
        [AllowNull()][object]$StartedAt = $null,
        [AllowNull()][object]$CompletedAt = $null,
        [string]$Text = 'unrelated non-marker turn'
    )
    $storePath = Join-Path $Harness.state 'app-server-store.json'
    Assert-CasInt ([IO.File]::Exists($storePath)) 'Mock provider store is missing.'
    $store = (Read-TelephoneJson -Path $storePath).value
    $thread = $store.threads[$ThreadId]
    Assert-CasInt ($thread -is [Collections.IDictionary]) 'Mock provider thread is missing.'
    $turns = [Collections.Generic.List[object]]::new()
    foreach ($existing in (Get-CodexAppServerJsonArrayItems -Value (Get-CodexAppServerDictObject -Dict $thread -Key 'turns'))) {
        $turns.Add($existing)
    }
    $duration = $null
    if ($Status -ceq 'completed' -or $Status -ceq 'failed' -or $Status -ceq 'interrupted') {
        if ($null -ne $CompletedAt) { $duration = 1 }
    }
    $turns.Add([ordered]@{
        id = [string]$TurnId
        items = @(, (New-CasIntOfficialUserMessage -Text $Text -Id ('um-' + [string]$TurnId)))
        itemsView = 'full'
        status = [string]$Status
        error = $null
        startedAt = $StartedAt
        completedAt = $CompletedAt
        durationMs = $duration
    })
    $thread.turns = @($turns)
    $store.threads[$ThreadId] = $thread
    $json = (($store | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n")
    [IO.File]::WriteAllText($storePath, $json, [Text.UTF8Encoding]::new($false))
}

function Set-CasIntStoreThreadApprovedOptionalFields {
    param(
        $Harness,
        [string]$ThreadId,
        [string]$StorePath = '',
        [switch]$IncludeNullProjectId
    )
    $path = [string]$StorePath
    if ([string]::IsNullOrWhiteSpace($path)) { $path = Join-Path $Harness.state 'app-server-store.json' }
    Assert-CasInt ([IO.File]::Exists($path)) 'Optional-field store is missing.'
    $store = (Read-TelephoneJson -Path $path).value
    $thread = $store.threads[$ThreadId]
    Assert-CasInt ($thread -is [Collections.IDictionary]) 'Optional-field thread is missing.'
    $thread['canAcceptDirectInput'] = $false
    $thread['extra'] = [ordered]@{}
    $thread['historyMode'] = 'legacy'
    if ($IncludeNullProjectId) { $thread['projectId'] = $null }
    $store.threads[$ThreadId] = $thread
    $json = (($store | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n")
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
}

function New-CasIntCodexForwarder {
    param($Harness, [string]$ForwardMock = '', [switch]$PatchArchivedResumeJson)
    $forward = [string]$ForwardMock
    if ([string]::IsNullOrWhiteSpace($forward)) { $forward = $mock }
    $forward = [IO.Path]::GetFullPath($forward)
    if ($PatchArchivedResumeJson) {
        $patched = Join-Path $Harness.root 'Mock-CodexAppServer.patched.ps1'
        $src = [IO.File]::ReadAllText($forward, [Text.UTF8Encoding]::new($false, $true))
        $needle = "        if (`$method -ceq 'thread/resume') {`r`n            `$threadId = Get-MockDictString -Dict `$params -Key 'threadId'"
        $needleLf = "        if (`$method -ceq 'thread/resume') {`n            `$threadId = Get-MockDictString -Dict `$params -Key 'threadId'"
        $insert = @'
        if ($method -ceq 'thread/resume') {
            $oncePath = [string]$env:TELEPHONE_TEST_APP_SERVER_ARCHIVED_RESUME_JSON_ONCE
            if (-not [string]::IsNullOrWhiteSpace($oncePath) -and [IO.File]::Exists($oncePath)) {
                $doc = $null
                try { $doc = ([IO.File]::ReadAllText($oncePath, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String) } catch { $doc = $null }
                $remaining = 0
                if ($doc -is [Collections.IDictionary] -and $doc.Contains('remaining')) {
                    try { $remaining = [int]$doc.remaining } catch { $remaining = 0 }
                }
                if ($remaining -ge 1) {
                    $doc.remaining = $remaining - 1
                    try {
                        if ([int]$doc.remaining -le 0) { [IO.File]::Delete($oncePath) }
                        else { [IO.File]::WriteAllText($oncePath, (($doc | ConvertTo-Json -Compress -Depth 8) + [char]10), [Text.UTF8Encoding]::new($false)) }
                    } catch { }
                    $tid = Get-MockDictString -Dict $params -Key 'threadId'
                    $bt = [char]96
                    $message = ('session ' + $tid + ' is archived. Run ' + $bt + 'codex unarchive ' + $tid + $bt + ' to unarchive it first.')
                    if ($doc.Contains('message') -and -not [string]::IsNullOrWhiteSpace([string]$doc.message)) { $message = [string]$doc.message }
                    $eventLog = [string]$env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG
                    if (-not [string]::IsNullOrWhiteSpace($eventLog)) {
                        [IO.File]::AppendAllText($eventLog, ('thread/resume-archived-json-error' + [char]10), [Text.UTF8Encoding]::new($false))
                    }
                    Write-MockError -Id $id -Message $message
                    continue
                }
            }
            $threadId = Get-MockDictString -Dict $params -Key 'threadId'
'@
        $replaced = $false
        if ($src.Contains($needle)) { $src = $src.Replace($needle, $insert); $replaced = $true }
        elseif ($src.Contains($needleLf)) { $src = $src.Replace($needleLf, $insert); $replaced = $true }
        if (-not $replaced) { throw 'Harness mock copy is missing the thread/resume insertion point.' }
        [IO.File]::WriteAllText($patched, $src.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
        $forward = [IO.Path]::GetFullPath($patched)
    }
    $path = Join-Path $Harness.root 'fake-codex.ps1'
    $escaped = $forward.Replace("'", "''")
    $text = @"
# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$forward = '$escaped'
`$argList = @()
foreach (`$item in `$args) { `$argList += [string]`$item }
if (`$argList.Count -ge 1 -and `$argList[0] -ceq 'unarchive') {
    `$forced = [string]`$env:TELEPHONE_TEST_UNARCHIVE_EXIT
    if ([string]::IsNullOrWhiteSpace(`$forced)) { exit 0 }
    exit ([int]`$forced)
}
& `$forward @argList
exit `$LASTEXITCODE
"@
    [IO.File]::WriteAllText($path, ($text.Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    return [IO.Path]::GetFullPath($path)
}

function Write-CasIntArchivedResumeOnce {
    param($Harness, [int]$Remaining = 1, [object]$Code = -32600, [string]$Message = '')
    $path = Join-Path $Harness.root 'archived-resume-once.json'
    $doc = [ordered]@{
        remaining = [int]$Remaining
        code = $Code
    }
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $doc.message = [string]$Message }
    [IO.File]::WriteAllText($path, (($doc | ConvertTo-Json -Compress -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    $env:TELEPHONE_TEST_APP_SERVER_ARCHIVED_RESUME_ONCE = $path
    return $path
}

function Write-CasIntArchivedResumeJsonOnce {
    param($Harness, [int]$Remaining = 1, [object]$Code = -32600, [string]$Message = '')
    $path = Join-Path $Harness.root 'archived-resume-json-once.json'
    $doc = [ordered]@{
        remaining = [int]$Remaining
        code = $Code
    }
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $doc.message = [string]$Message }
    [IO.File]::WriteAllText($path, (($doc | ConvertTo-Json -Compress -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    $env:TELEPHONE_TEST_APP_SERVER_ARCHIVED_RESUME_JSON_ONCE = $path
    Remove-Item -Path 'env:TELEPHONE_TEST_APP_SERVER_ARCHIVED_RESUME_ONCE' -ErrorAction SilentlyContinue
    return $path
}

function Get-CasIntCommandLogRecords {
    param([string]$Path)
    $rows = [Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return @() }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $row = $line | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
            if ($row -is [Collections.IDictionary]) { $rows.Add($row) }
        } catch { }
    }
    return @($rows)
}

function Get-CasIntUnarchiveLogRecords {
    param([string]$Path)
    $out = [Collections.Generic.List[object]]::new()
    foreach ($row in @(Get-CasIntCommandLogRecords -Path $Path)) {
        $args = @()
        if ($row.Contains('arguments')) { $args = @($row.arguments | ForEach-Object { [string]$_ }) }
        if ($args.Count -ge 1 -and $args[0] -ceq 'unarchive') { $out.Add($row) }
    }
    return @($out)
}

function Assert-CasIntUnarchiveCommandBoundary {
    param(
        [string]$LogPath,
        [string]$Executable,
        [string]$ThreadId,
        [int]$Count,
        [AllowNull()][object]$ExitCode = $null
    )
    $rows = @(Get-CasIntUnarchiveLogRecords -Path $LogPath)
    Assert-CasInt ($rows.Count -eq $Count) ("Unarchive count=$($rows.Count) expected=$Count.")
    $expectedExe = [IO.Path]::GetFullPath($Executable)
    foreach ($row in $rows) {
        $exe = [string]$row.executable
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace($exe)) 'Unarchive log omitted the executable path.'
        Assert-CasInt ([IO.Path]::GetFullPath($exe).Equals($expectedExe, [StringComparison]::OrdinalIgnoreCase)) ("Unarchive used a different executable. expected=$expectedExe actual=$exe")
        $args = @()
        if ($row.Contains('arguments')) { $args = @($row.arguments | ForEach-Object { [string]$_ }) }
        Assert-CasInt ($args.Count -eq 2 -and $args[0] -ceq 'unarchive' -and $args[1] -ceq $ThreadId) ("Unarchive argument vector drifted: [$([string]::Join(' ', $args))].")
        foreach ($token in @($args)) {
            Assert-CasInt ($token.IndexOf('Fast', [StringComparison]::OrdinalIgnoreCase) -lt 0) 'Unarchive argument contained Fast.'
            Assert-CasInt ($token.IndexOf('priority', [StringComparison]::OrdinalIgnoreCase) -lt 0) 'Unarchive argument contained priority.'
            Assert-CasInt ($token.IndexOf('ultrafast', [StringComparison]::OrdinalIgnoreCase) -lt 0) 'Unarchive argument contained ultrafast.'
        }
        if ($null -ne $ExitCode) {
            Assert-CasInt ($row.Contains('exit_code') -and [int]$row.exit_code -eq [int]$ExitCode) ("Unarchive exit_code drifted: expected=$ExitCode.")
        }
    }
}

function Assert-CasIntArchivedNoCallback {
    param($Harness, [string]$ThreadId, [string]$RunId, $Paths, [string]$EventLog)
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $Harness -ThreadId $ThreadId -RunId $RunId).Count -eq 0) 'Archived fail-closed started a callback marker turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $EventLog -Name 'turn/start') -eq 0) 'Archived fail-closed sent turn/start.'
    Assert-CasIntWakeBaselineEmpty -Harness $Harness -RunId $RunId
    Assert-CasInt (-not [IO.File]::Exists($Paths.ack)) 'Archived fail-closed published ack.'
    Assert-CasInt (-not [IO.File]::Exists($Paths.bound_turn)) 'Archived fail-closed bound a turn.'
    Assert-CasInt (-not [IO.File]::Exists($Paths.child)) 'Archived fail-closed wrote child.json.'
    if ([IO.File]::Exists($Paths.transitions)) {
        $hasBaseline = $false
        foreach ($line in [IO.File]::ReadAllLines($Paths.transitions)) {
            try {
                $row = $line | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
                if ($row -is [Collections.IDictionary] -and [string]$row.state -ceq 'baseline_recorded') { $hasBaseline = $true }
            } catch { }
        }
        Assert-CasInt (-not $hasBaseline) 'Archived fail-closed recorded a baseline.'
    }
}

function Assert-CasIntArchivedPublicFailure {
    param($Launch)
    Assert-CasInt ($Launch.exit_code -ne 0) 'Archived fail-closed did not fail the launcher.'
    $err = ''
    $code = ''
    if ($null -ne $Launch.json -and $Launch.json -is [Collections.IDictionary]) {
        $code = Get-CodexAppServerDictString -Dict $Launch.json -Key 'code'
        $err = Get-CodexAppServerDictString -Dict $Launch.json -Key 'error'
    }
    $blob = (([string]$Launch.stdout) + ([string]$Launch.stderr) + $err)
    Assert-CasInt ($blob.IndexOf('codex unarchive ', [StringComparison]::Ordinal) -lt 0) 'Raw archived advice leaked on the public error surface.'
    if (-not [string]::IsNullOrWhiteSpace($code)) {
        Assert-CasInt ($code -cne '-32600' -and $code -cne '-32602' -and $code -cne '-32700') ("Raw JSON-RPC code leaked as the public code: $code")
    }
}

function New-CasIntArchivedWakeWorld {
    param(
        [string]$Name,
        [string]$CreateId,
        [string]$RunId,
        [int]$Remaining = 1,
        [object]$Code = -32600,
        [string]$Message = '',
        [string]$UnarchiveExit = '',
        [switch]$UseForwarder,
        [switch]$JsonResumeError
    )
    Clear-CasIntTestEnv
    $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
    $h = New-CasIntHarness -Name $Name
    $exe = $mock
    if ($UseForwarder) {
        $exe = New-CasIntCodexForwarder -Harness $h -PatchArchivedResumeJson:$JsonResumeError
    }
    $null = Invoke-CasIntProfile -Harness $h -CodexCommand $exe
    $created = Invoke-CasIntDurableCreate -Harness $h -RunId $CreateId -CodexCommand $exe
    Assert-CasInt ($created.exit_code -eq 0) ("Archived $Name durable create failed: $($created.stderr) $($created.stdout)")
    $tid = [string]$created.json.thread_id
    Assert-CasInt (-not [string]::IsNullOrWhiteSpace($tid)) "Archived $Name omitted thread id."
    Assert-CasInt (Wait-CasIntRunOwnerQuiet -Harness $h -RunId $CreateId -TimeoutMs 20000) "Archived $Name create owner did not quiesce."
    Stop-CasIntRun -Harness $h -RunId $CreateId
    Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $h -ThreadId $tid -TimeoutMs 20000) "Archived $Name create thread owner did not quiesce."
    Assert-CasInt (Wait-CasIntPriorTurnConservativelyBeforeNow -Harness $h -ThreadId $tid) "Archived $Name prior turn was not conservatively complete."
    $createPaths = Get-CodexAppServerRunPaths -StateRoot ([string]$h.state) -RunId $CreateId
    $priorBound = Read-CodexAppServerValidated -Path $createPaths.bound_turn -SchemaName 'codex-app-server-lead-bound-turn'
    $priorId = Get-CodexAppServerDictString -Dict $priorBound -Key 'turn_id'
    Assert-CasInt (-not [string]::IsNullOrWhiteSpace($priorId)) "Archived $Name prior turn id was empty."
    $paths = Write-CasIntWakeAmbiguityQueuedWorld -Harness $h -ThreadId $tid -RunId $RunId
    $eventLog = Join-Path $h.root 'archived-events.log'
    $commandLog = Join-Path $h.root 'codex-command.log'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLog
    $env:TELEPHONE_TEST_CODEX_COMMAND_LOG = $commandLog
    if (-not [string]::IsNullOrWhiteSpace($UnarchiveExit)) {
        $env:TELEPHONE_TEST_UNARCHIVE_EXIT = $UnarchiveExit
    }
    if ($JsonResumeError) {
        $jsonMessage = [string]$Message
        if ([string]::IsNullOrWhiteSpace($jsonMessage)) {
            $jsonMessage = Get-CodexAppServerArchivedThreadErrorMessage -ThreadId $tid
        }
        $null = Write-CasIntArchivedResumeJsonOnce -Harness $h -Remaining $Remaining -Code $Code -Message $jsonMessage
    } else {
        $null = Write-CasIntArchivedResumeOnce -Harness $h -Remaining $Remaining -Code $Code -Message $Message
    }
    return [ordered]@{
        harness = $h
        forwarder = $exe
        thread_id = $tid
        run_id = $RunId
        create_id = $CreateId
        prior_id = $priorId
        paths = $paths
        event_log = $eventLog
        command_log = $commandLog
    }
}

function Wait-CasIntPriorTurnConservativelyBeforeNow {
    param($Harness, [string]$ThreadId, [int]$TimeoutMs = 10000)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    $storePath = Join-Path $Harness.state 'app-server-store.json'
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ([IO.File]::Exists($storePath)) {
            try {
                $store = (Read-TelephoneJson -Path $storePath).value
                $thread = $store.threads[$ThreadId]
                foreach ($turn in (Get-CodexAppServerJsonArrayItems -Value (Get-CodexAppServerDictObject -Dict $thread -Key 'turns'))) {
                    if ($turn -isnot [Collections.IDictionary]) { continue }
                    $raw = $null
                    if ($turn.Contains('completedAt')) { $raw = $turn['completedAt'] }
                    $completed = Get-CodexAppServerUnixTime -Value $raw
                    $now = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
                    if ($null -ne $completed -and (([Math]::Floor([double]$completed) + 1.0) -le $now)) { return $true }
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 50
    }
    Start-Sleep -Milliseconds 2000
    return $true
}

function Get-CasIntMarkerStoreTurns {
    param($Harness, [string]$ThreadId, [string]$RunId, [string]$StorePath = '')
    $marker = Get-CodexAppServerWakeMarker -RunId $RunId
    $matched = [Collections.Generic.List[object]]::new()
    foreach ($turn in @(Get-CasIntStoreTurns -Harness $Harness -ThreadId $ThreadId -StorePath $StorePath)) {
        if ($turn -isnot [Collections.IDictionary]) { continue }
        $found = Find-CodexAppServerMatchingTurns -Thread ([ordered]@{ id = $ThreadId; turns = @(, $turn) }) -Marker $marker -BaselineTurnIds @()
        if (@($found.matches).Count -eq 1) { $matched.Add($turn) }
    }
    return @($matched)
}

function Get-CasIntAnyMarkerStoreTurns {
    param($Harness, [string]$ThreadId)
    $matched = [Collections.Generic.List[object]]::new()
    foreach ($turn in @(Get-CasIntStoreTurns -Harness $Harness -ThreadId $ThreadId)) {
        if ($turn -isnot [Collections.IDictionary]) { continue }
        $blob = Get-CodexAppServerItemTextBlob -Node $turn
        if (Test-CodexAppServerTextHasMarker -Text $blob -Marker 'tl-wake:') { [void]$matched.Add($turn) }
    }
    return @($matched)
}

function Assert-CasIntWakeArtifactsAgree {
    param($Harness, [string]$RunId, [string]$ThreadId, [string]$TurnId)
    $paths = Get-CodexAppServerRunPaths -StateRoot ([string]$Harness.state) -RunId $RunId
    $run = Get-CasIntRunJson -Harness $Harness -RunId $RunId
    $intent = (Read-TelephoneJson -Path $paths.intent -SchemaName 'codex-app-server-lead-intent').value
    $bound = Get-CasIntBoundJson -Harness $Harness -RunId $RunId
    $ack = (Read-TelephoneJson -Path $paths.ack -SchemaName 'codex-app-server-lead-ack').value
    $result = (Read-TelephoneJson -Path $paths.result -SchemaName 'codex-app-server-lead-result').value
    $final = Get-CasIntFinalText -Harness $Harness -RunId $RunId
    Assert-CasInt ([string]$run.run_id -ceq $RunId) 'Terminal run_id drifted.'
    Assert-CasInt ([string]$intent.run_id -ceq $RunId) 'Terminal intent run_id drifted.'
    Assert-CasInt ([string]$result.run_id -ceq $RunId) 'Terminal result run_id drifted.'
    Assert-CasInt ([string]$run.thread_id -ceq $ThreadId) 'Terminal run thread drifted.'
    Assert-CasInt ([string]$intent.thread_id -ceq $ThreadId) 'Terminal intent thread drifted.'
    Assert-CasInt ([string]$bound.thread_id -ceq $ThreadId) 'Terminal bound thread drifted.'
    Assert-CasInt ([string]$ack.session_id -ceq $ThreadId) 'Terminal ack session drifted.'
    Assert-CasInt ([string]$run.selected_turn_id -ceq $TurnId) 'Terminal selected turn drifted.'
    Assert-CasInt ([string]$bound.turn_id -ceq $TurnId) 'Terminal bound turn drifted.'
    Assert-CasInt ([string]$ack.turn_id -ceq $TurnId) 'Terminal ack turn drifted.'
    Assert-CasInt ([string]$run.callback_write_phase -ceq 'terminal') 'Terminal phase was not terminal.'
    Assert-CasInt ([string]$run.disposition -ceq 'completed') 'Terminal disposition was not completed.'
    Assert-CasInt ([string]$bound.state -ceq 'completed') 'Terminal bound state was not completed.'
    Assert-CasInt ([string]$result.state -ceq 'completed') 'Terminal result was not completed.'
    Assert-CasInt ($final -ceq 'completed') 'Terminal final artifact was not completed.'
    Assert-CasInt (-not [IO.File]::Exists($paths.failure)) 'Stale failure.json remained at terminal.'
    Assert-CasInt (-not [IO.File]::Exists($paths.recovery)) 'Stale recovery.json remained at terminal.'
}

function Invoke-CasIntWakeAmbiguityRepairProof {
    $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'

    $intentUnix = 1000.5
    Assert-CasInt (-not (Test-CodexAppServerTurnIsProvablePreIntent -Turn ([ordered]@{
        id = 'active-before'
        status = 'inProgress'
        startedAt = 900.0
        completedAt = $null
        itemsView = 'full'
        error = $null
        durationMs = $null
        items = @()
    }) -IntentUnix $intentUnix)) 'Active turn started before intent was treated as pre-intent.'
    Assert-CasInt (-not (Test-CodexAppServerTurnIsProvablePreIntent -Turn ([ordered]@{
        id = 'term-no-time'
        status = 'completed'
        startedAt = $null
        completedAt = $null
        itemsView = 'full'
        error = $null
        durationMs = 1
        items = @()
    }) -IntentUnix $intentUnix)) 'Terminal turn without timestamps was treated as pre-intent.'
    Assert-CasInt (-not (Test-CodexAppServerTurnIsProvablePreIntent -Turn ([ordered]@{
        id = 'term-no-intent'
        status = 'completed'
        startedAt = 1.0
        completedAt = 2.0
        itemsView = 'full'
        error = $null
        durationMs = 1
        items = @()
    }) -IntentUnix $null)) 'Terminal turn without intent time was treated as pre-intent.'
    Assert-CasInt (-not (Test-CodexAppServerTurnIsProvablePreIntent -Turn ([ordered]@{
        id = 'same-second'
        status = 'completed'
        startedAt = 1000.0
        completedAt = 1000.0
        itemsView = 'full'
        error = $null
        durationMs = 1
        items = @()
    }) -IntentUnix $intentUnix)) 'Same-second completedAt was treated as wholly before intent.'
    Assert-CasInt (-not (Test-CodexAppServerTurnIsProvablePreIntent -Turn ([ordered]@{
        id = 'overlap'
        status = 'completed'
        startedAt = 990.0
        completedAt = 1001.0
        itemsView = 'full'
        error = $null
        durationMs = 1
        items = @()
    }) -IntentUnix $intentUnix)) 'Turn completed after intent was treated as pre-intent.'
    Assert-CasInt (Test-CodexAppServerTurnIsProvablePreIntent -Turn ([ordered]@{
        id = 'safe-prior'
        status = 'completed'
        startedAt = 100.0
        completedAt = 200.0
        itemsView = 'full'
        error = $null
        durationMs = 1
        items = @()
    }) -IntentUnix 201.0) 'Conservatively complete prior turn was not accepted as pre-intent.'
    $script:wakeAmbiguityPreIntentPredicateClosed = 1

    Clear-CasIntTestEnv
    $hPos = New-CasIntHarness -Name 'wake-amb-positive'
    $null = Invoke-CasIntProfile -Harness $hPos
    $createId = 'wake-amb-create-1'
    $created = Invoke-CasIntDurableCreate -Harness $hPos -RunId $createId
    Assert-CasInt ($created.exit_code -eq 0) ("Wake-ambiguity durable create failed: $($created.stderr) $($created.stdout)")
    $tid = [string]$created.json.thread_id
    Assert-CasInt (-not [string]::IsNullOrWhiteSpace($tid)) 'Wake-ambiguity durable create omitted thread id.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hPos -ThreadId $tid).Count -eq 1) 'Wake-ambiguity prior Lead turn is missing.'
    Assert-CasInt (Wait-CasIntRunOwnerQuiet -Harness $hPos -RunId $createId -TimeoutMs 20000) 'Wake-ambiguity create owner did not quiesce.'
    Stop-CasIntRun -Harness $hPos -RunId $createId
    Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hPos -ThreadId $tid -TimeoutMs 20000) 'Wake-ambiguity create thread owner did not quiesce.'
    Assert-CasInt (Wait-CasIntPriorTurnConservativelyBeforeNow -Harness $hPos -ThreadId $tid) 'Wake-ambiguity prior turn was not conservatively complete before callback intent.'
    $createPaths = Get-CodexAppServerRunPaths -StateRoot ([string]$hPos.state) -RunId $createId
    $priorBound = Read-CodexAppServerValidated -Path $createPaths.bound_turn -SchemaName 'codex-app-server-lead-bound-turn'
    $priorId = Get-CodexAppServerDictString -Dict $priorBound -Key 'turn_id'
    Assert-CasInt (-not [string]::IsNullOrWhiteSpace($priorId)) 'Wake-ambiguity prior turn id was empty.'
    $rid = 'telephone-wake-amb-1'
    $eventLog = Join-Path $hPos.root 'wake-amb-events.log'
    $paths = Write-CasIntWakeAmbiguityQueuedWorld -Harness $hPos -ThreadId $tid -RunId $rid
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hPos -RunId $rid).callback_write_phase -ceq 'none') 'Planted wake-ambiguity phase was not none.'
    Assert-CasInt (@(Get-CodexAppServerStringList -Value (Get-CasIntRunJson -Harness $hPos -RunId $rid).baseline_turn_ids).Count -eq 0) 'Planted wake-ambiguity baseline was not empty.'
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hPos -RunId $rid).selected_turn_id -ceq '') 'Planted wake-ambiguity selected turn was not empty.'
    Assert-CasInt ([IO.File]::Exists($paths.failure)) 'Planted wake-ambiguity omitted worker_failed.'
    Assert-CasInt (-not (Test-CasIntOwnerAlive -Harness $hPos -RunId $rid)) 'Planted wake-ambiguity had a live per-run owner.'
    Assert-CasInt (-not (Test-CasIntThreadOwnerAlive -Harness $hPos -ThreadId $tid)) 'Planted wake-ambiguity had a live thread owner.'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLog
    $first = Invoke-CasIntLauncher -Harness $hPos -ThreadId $tid -RunId $rid
    Assert-CasInt ($first.exit_code -eq 0) ("Wake-ambiguity positive launch failed: $($first.stderr) $($first.stdout)")
    Assert-CasInt (Wait-CasIntPath -Path $paths.ack) 'Wake-ambiguity positive did not publish ack.'
    $turnId = [string]((Read-TelephoneJson -Path $paths.ack -SchemaName 'codex-app-server-lead-ack').value.turn_id)
    Assert-CasInt (-not [string]::IsNullOrWhiteSpace($turnId)) 'Wake-ambiguity positive ack omitted turn id.'
    $settled = Wait-CasIntOfficialTerminalAndQuiet -Harness $hPos -RunId $rid -ThreadId $tid -TurnId $turnId
    Assert-CasInt ([bool]$settled.success) ("Wake-ambiguity positive did not settle: terminal=$([bool]$settled.terminal) run_quiet=$([bool]$settled.run_quiet) thread_quiet=$([bool]$settled.thread_quiet) phase=$([string]$settled.phase) state=$([string]$settled.state).")
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hPos -ThreadId $tid -RunId $rid).Count -eq 1) 'Wake-ambiguity positive did not keep exactly one callback marker turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $eventLog -Name 'turn/start') -eq 1) 'Wake-ambiguity positive did not send exactly one turn/start.'
    $intentPos = (Read-TelephoneJson -Path $paths.intent -SchemaName 'codex-app-server-lead-intent').value
    $runPos = Get-CasIntRunJson -Harness $hPos -RunId $rid
    $intentBaseline = @(Get-CodexAppServerStringList -Value $intentPos.baseline_turn_ids)
    $runBaseline = @(Get-CodexAppServerStringList -Value $runPos.baseline_turn_ids)
    Assert-CasInt ($intentBaseline.Count -eq 1 -and $intentBaseline[0] -ceq $priorId) ("Wake-ambiguity positive did not capture exactly the prior Lead turn id in intent baseline. prior=$priorId intent=[$([string]::Join(',', $intentBaseline))] count=$($intentBaseline.Count)")
    Assert-CasInt ($runBaseline.Count -eq 1 -and $runBaseline[0] -ceq $priorId) ("Wake-ambiguity positive did not capture exactly the prior Lead turn id in run baseline. prior=$priorId run=[$([string]::Join(',', $runBaseline))] count=$($runBaseline.Count)")
    $script:wakeAmbiguityCapturedPriorBaseline = 1
    Assert-CasInt (-not (Test-CasIntOwnerAlive -Harness $hPos -RunId $rid)) 'Wake-ambiguity positive left a live per-run owner.'
    Assert-CasInt (-not (Test-CasIntThreadOwnerAlive -Harness $hPos -ThreadId $tid)) 'Wake-ambiguity positive left a live thread owner.'
    Assert-CasInt (-not (Test-CasIntIdentityKeyAlive -IdentityKey (Get-CasIntChildIdentityKey -Harness $hPos -RunId $rid))) 'Wake-ambiguity positive left a live child.'
    Assert-CasIntWakeArtifactsAgree -Harness $hPos -RunId $rid -ThreadId $tid -TurnId $turnId
    $repeat = Invoke-CasIntLauncher -Harness $hPos -ThreadId $tid -RunId $rid
    Assert-CasInt ($repeat.exit_code -eq 0) ("Wake-ambiguity repeat launcher failed: $($repeat.stderr) $($repeat.stdout)")
    Assert-CasInt ([string]$repeat.json.state -ceq 'completed') 'Wake-ambiguity repeat did not return the official terminal.'
    Assert-CasInt ([string](Get-CasIntBoundJson -Harness $hPos -RunId $rid).turn_id -ceq $turnId) 'Wake-ambiguity repeat bound a different turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $eventLog -Name 'turn/start') -eq 1) 'Wake-ambiguity repeat sent another turn/start.'
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hPos -ThreadId $tid -RunId $rid).Count -eq 1) 'Wake-ambiguity repeat created another marker turn.'
    Assert-CasIntWakeArtifactsAgree -Harness $hPos -RunId $rid -ThreadId $tid -TurnId $turnId
    $script:wakeAmbiguityPositiveRestart = 1
    $script:wakeAmbiguityQuiescence = 1
    $script:wakeAmbiguityArtifactsAgree = 1
    Stop-CasIntRun -Harness $hPos -RunId $rid
    Clear-CasIntTestEnv

    $hRec = New-CasIntHarness -Name 'wake-amb-recovery'
    $null = Invoke-CasIntProfile -Harness $hRec
    $createdRec = Invoke-CasIntDurableCreate -Harness $hRec -RunId 'wake-amb-create-2'
    Assert-CasInt ($createdRec.exit_code -eq 0) ("Wake-ambiguity recovery create failed: $($createdRec.stderr) $($createdRec.stdout)")
    $tidRec = [string]$createdRec.json.thread_id
    Assert-CasInt (Wait-CasIntRunOwnerQuiet -Harness $hRec -RunId 'wake-amb-create-2' -TimeoutMs 20000) 'Wake-ambiguity recovery create owner did not quiesce.'
    Stop-CasIntRun -Harness $hRec -RunId 'wake-amb-create-2'
    Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hRec -ThreadId $tidRec -TimeoutMs 20000) 'Wake-ambiguity recovery create thread owner did not quiesce.'
    Start-Sleep -Milliseconds 1500
    $ridRec = 'telephone-wake-amb-2'
    $eventRec = Join-Path $hRec.root 'wake-amb-recovery.log'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventRec
    $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = 'after-ambiguous-write'
    $crash = Invoke-CasIntLauncher -Harness $hRec -ThreadId $tidRec -RunId $ridRec
    Assert-CasInt ($crash.exit_code -ne 0) 'Wake-ambiguity marker crash did not fail closed.'
    Assert-CasInt (Wait-CasIntRunOwnerQuiet -Harness $hRec -RunId $ridRec -TimeoutMs 20000) 'Wake-ambiguity marker crash left a live owner.'
    Stop-CasIntRun -Harness $hRec -RunId $ridRec
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT -ErrorAction SilentlyContinue
    $runCrash = Get-CasIntRunJson -Harness $hRec -RunId $ridRec
    Assert-CasInt ([string]$runCrash.callback_write_phase -ceq 'turn_start_sending') ("Wake-ambiguity marker crash phase=$([string]$runCrash.callback_write_phase).")
    Assert-CasInt ([string]$runCrash.selected_turn_id -ceq '') 'Wake-ambiguity marker crash bound a selected turn.'
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hRec -ThreadId $tidRec -RunId $ridRec).Count -eq 1) 'Wake-ambiguity marker crash lost the callback turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $eventRec -Name 'turn/start') -eq 1) 'Wake-ambiguity marker crash did not send exactly one turn/start.'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventRec
    $recovered = Invoke-CasIntLauncher -Harness $hRec -ThreadId $tidRec -RunId $ridRec
    Assert-CasInt ($recovered.exit_code -eq 0) ("Wake-ambiguity marker recovery failed: $($recovered.stderr) $($recovered.stdout)")
    $ackRec = Join-Path (Get-CasIntRunRoot -Harness $hRec -RunId $ridRec) 'lead-wake-ack.json'
    Assert-CasInt (Wait-CasIntPath -Path $ackRec) 'Wake-ambiguity marker recovery omitted ack.'
    $turnRec = [string]((Read-TelephoneJson -Path $ackRec -SchemaName 'codex-app-server-lead-ack').value.turn_id)
    $settledRec = Wait-CasIntOfficialTerminalAndQuiet -Harness $hRec -RunId $ridRec -ThreadId $tidRec -TurnId $turnRec
    Assert-CasInt ([bool]$settledRec.success) ("Wake-ambiguity marker recovery did not settle: terminal=$([bool]$settledRec.terminal) run_quiet=$([bool]$settledRec.run_quiet) thread_quiet=$([bool]$settledRec.thread_quiet).")
    Assert-CasInt ((Get-CasIntEventCount -Path $eventRec -Name 'turn/start') -eq 1) 'Wake-ambiguity marker recovery sent a replacement turn/start.'
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hRec -ThreadId $tidRec -RunId $ridRec).Count -eq 1) 'Wake-ambiguity marker recovery created another marker turn.'
    Assert-CasIntWakeArtifactsAgree -Harness $hRec -RunId $ridRec -ThreadId $tidRec -TurnId $turnRec
    $script:wakeAmbiguityMarkerRecovery = 1
    Stop-CasIntRun -Harness $hRec -RunId $ridRec
    Clear-CasIntTestEnv

    $hMulti = New-CasIntHarness -Name 'wake-amb-multi'
    $null = Invoke-CasIntProfile -Harness $hMulti
    $createdMulti = Invoke-CasIntDurableCreate -Harness $hMulti -RunId 'wake-amb-create-3'
    Assert-CasInt ($createdMulti.exit_code -eq 0) ("Wake-ambiguity multi create failed: $($createdMulti.stderr) $($createdMulti.stdout)")
    $tidMulti = [string]$createdMulti.json.thread_id
    Stop-CasIntRun -Harness $hMulti -RunId 'wake-amb-create-3'
    Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hMulti -ThreadId $tidMulti -TimeoutMs 20000) 'Wake-ambiguity multi create thread owner did not quiesce.'
    Start-Sleep -Milliseconds 1500
    $ridMulti = 'telephone-wake-amb-3'
    $null = Write-CasIntWakeAmbiguityQueuedWorld -Harness $hMulti -ThreadId $tidMulti -RunId $ridMulti
    $promptMulti = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes([string]$hMulti.prompt))
    $textMulti = New-CodexAppServerTurnInputText -PromptText $promptMulti -RunId $ridMulti
    $env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS = (@(
        [ordered]@{ id = 'wake-amb-x1'; items = @(, (New-CasIntOfficialUserMessage -Text $textMulti -Id 'um-wake-amb-x1')) },
        [ordered]@{ id = 'wake-amb-x2'; items = @(, (New-CasIntOfficialUserMessage -Text $textMulti -Id 'um-wake-amb-x2')) }
    ) | ConvertTo-Json -Depth 16 -Compress)
    $multi = Invoke-CasIntLauncher -Harness $hMulti -ThreadId $tidMulti -RunId $ridMulti
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS -ErrorAction SilentlyContinue
    Assert-CasInt ($multi.exit_code -ne 0) 'Multiple matching marker turns were not fail-closed.'
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hMulti -ThreadId $tidMulti -RunId $ridMulti).Count -eq 0) 'Multiple matching marker turns started a replacement callback turn.'
    $script:wakeAmbiguityMultipleMarkersClosed = 1
    Stop-CasIntRun -Harness $hMulti -RunId $ridMulti
    Clear-CasIntTestEnv

    $hPost = New-CasIntHarness -Name 'wake-amb-post-intent'
    $null = Invoke-CasIntProfile -Harness $hPost
    $createdPost = Invoke-CasIntDurableCreate -Harness $hPost -RunId 'wake-amb-create-4'
    Assert-CasInt ($createdPost.exit_code -eq 0) ("Wake-ambiguity post-intent create failed: $($createdPost.stderr) $($createdPost.stdout)")
    $tidPost = [string]$createdPost.json.thread_id
    Stop-CasIntRun -Harness $hPost -RunId 'wake-amb-create-4'
    Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hPost -ThreadId $tidPost -TimeoutMs 20000) 'Wake-ambiguity post-intent create thread owner did not quiesce.'
    Start-Sleep -Milliseconds 1500
    $ridPost = 'telephone-wake-amb-4'
    $null = Write-CasIntWakeAmbiguityQueuedWorld -Harness $hPost -ThreadId $tidPost -RunId $ridPost
    Start-Sleep -Milliseconds 1500
    $nowPost = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS = (@(
        [ordered]@{
            id = 'wake-amb-post'
            items = @(, (New-CasIntOfficialUserMessage -Text 'unrelated post-intent turn' -Id 'um-wake-amb-post'))
            itemsView = 'full'
            status = 'completed'
            error = $null
            startedAt = ($nowPost - 1.0)
            completedAt = $nowPost
            durationMs = 1
        }
    ) | ConvertTo-Json -Depth 16 -Compress)
    $post = Invoke-CasIntLauncher -Harness $hPost -ThreadId $tidPost -RunId $ridPost
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS -ErrorAction SilentlyContinue
    Assert-CasInt ($post.exit_code -ne 0) 'Post-intent unexplained turn was not fail-closed.'
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hPost -ThreadId $tidPost -RunId $ridPost).Count -eq 0) 'Post-intent unexplained turn started a callback turn.'
    Assert-CasIntWakeBaselineEmpty -Harness $hPost -RunId $ridPost
    $script:wakeAmbiguityPostIntentClosed = 1
    Stop-CasIntRun -Harness $hPost -RunId $ridPost
    Clear-CasIntTestEnv

    function Invoke-CasIntWakeAmbiguityNegativeWorld {
        param([string]$Name, [string]$CreateId, [string]$RunId, [scriptblock]$Mutate)
        $h = New-CasIntHarness -Name $Name
        $null = Invoke-CasIntProfile -Harness $h
        $created = Invoke-CasIntDurableCreate -Harness $h -RunId $CreateId
        Assert-CasInt ($created.exit_code -eq 0) ("Wake-ambiguity $Name create failed: $($created.stderr) $($created.stdout)")
        $threadId = [string]$created.json.thread_id
        Stop-CasIntRun -Harness $h -RunId $CreateId
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $h -ThreadId $threadId -TimeoutMs 20000) ("Wake-ambiguity $Name create thread owner did not quiesce.")
        Assert-CasInt (Wait-CasIntPriorTurnConservativelyBeforeNow -Harness $h -ThreadId $threadId) ("Wake-ambiguity $Name prior turn was not conservatively complete.")
        $null = Write-CasIntWakeAmbiguityQueuedWorld -Harness $h -ThreadId $threadId -RunId $RunId
        $paths = Get-CodexAppServerRunPaths -StateRoot ([string]$h.state) -RunId $RunId
        & $Mutate $h $threadId $RunId $paths
        $launch = Invoke-CasIntLauncher -Harness $h -ThreadId $threadId -RunId $RunId
        Assert-CasInt ($launch.exit_code -ne 0) ("Wake-ambiguity $Name was not fail-closed.")
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $h -ThreadId $threadId -RunId $RunId).Count -eq 0) ("Wake-ambiguity $Name started a callback marker turn.")
        Assert-CasIntWakeBaselineEmpty -Harness $h -RunId $RunId
        Assert-CasInt (-not [IO.File]::Exists($paths.ack)) ("Wake-ambiguity $Name published ack.")
        Assert-CasInt (-not [IO.File]::Exists($paths.bound_turn)) ("Wake-ambiguity $Name bound a turn.")
        Stop-CasIntRun -Harness $h -RunId $RunId
        Clear-CasIntTestEnv
        return $true
    }

    $null = Invoke-CasIntWakeAmbiguityNegativeWorld -Name 'wake-amb-active-before' -CreateId 'wake-amb-create-8' -RunId 'telephone-wake-amb-8' -Mutate {
        param($Harness, $ThreadId, $RunId, $Paths)
        $intent = (Read-TelephoneJson -Path $Paths.intent -SchemaName 'codex-app-server-lead-intent').value
        $intentUnix = Get-CodexAppServerUnixTime -Value $intent['created_at_utc']
        Add-CasIntStoreTurn -Harness $Harness -ThreadId $ThreadId -TurnId 'amb-active-before' -Status 'inProgress' -StartedAt ([double]$intentUnix - 10.0) -CompletedAt $null -Text 'active started before intent'
    }
    $script:wakeAmbiguityActiveStartedBeforeIntentClosed = 1

    $null = Invoke-CasIntWakeAmbiguityNegativeWorld -Name 'wake-amb-term-no-time' -CreateId 'wake-amb-create-9' -RunId 'telephone-wake-amb-9' -Mutate {
        param($Harness, $ThreadId, $RunId, $Paths)
        Add-CasIntStoreTurn -Harness $Harness -ThreadId $ThreadId -TurnId 'amb-term-no-time' -Status 'completed' -StartedAt $null -CompletedAt $null -Text 'terminal without timestamps'
    }
    $script:wakeAmbiguityTerminalWithoutTimeClosed = 1

    $null = Invoke-CasIntWakeAmbiguityNegativeWorld -Name 'wake-amb-bad-intent-time' -CreateId 'wake-amb-create-10' -RunId 'telephone-wake-amb-10' -Mutate {
        param($Harness, $ThreadId, $RunId, $Paths)
        $intent = (Read-TelephoneJson -Path $Paths.intent -SchemaName 'codex-app-server-lead-intent').value
        $intent.created_at_utc = 'not-a-timestamp'
        $null = Write-CodexAppServerValidatedReplace -Path $Paths.intent -Value $intent -SchemaName 'codex-app-server-lead-intent'
        Add-CasIntStoreTurn -Harness $Harness -ThreadId $ThreadId -TurnId 'amb-needs-intent-time' -Status 'completed' -StartedAt 10.0 -CompletedAt 20.0 -Text 'needs parseable intent time'
    }
    $script:wakeAmbiguityIntentTimeUnparseableClosed = 1

    $null = Invoke-CasIntWakeAmbiguityNegativeWorld -Name 'wake-amb-completed-after' -CreateId 'wake-amb-create-11' -RunId 'telephone-wake-amb-11' -Mutate {
        param($Harness, $ThreadId, $RunId, $Paths)
        $intent = (Read-TelephoneJson -Path $Paths.intent -SchemaName 'codex-app-server-lead-intent').value
        $intentUnix = Get-CodexAppServerUnixTime -Value $intent['created_at_utc']
        Add-CasIntStoreTurn -Harness $Harness -ThreadId $ThreadId -TurnId 'amb-completed-after' -Status 'completed' -StartedAt ([double]$intentUnix - 20.0) -CompletedAt ([double]$intentUnix + 20.0) -Text 'started before completed after intent'
    }
    $script:wakeAmbiguityCompletedAfterIntentClosed = 1

    $null = Invoke-CasIntWakeAmbiguityNegativeWorld -Name 'wake-amb-same-second' -CreateId 'wake-amb-create-12' -RunId 'telephone-wake-amb-12' -Mutate {
        param($Harness, $ThreadId, $RunId, $Paths)
        $intent = (Read-TelephoneJson -Path $Paths.intent -SchemaName 'codex-app-server-lead-intent').value
        $intentUnix = Get-CodexAppServerUnixTime -Value $intent['created_at_utc']
        $same = [Math]::Floor([double]$intentUnix)
        Add-CasIntStoreTurn -Harness $Harness -ThreadId $ThreadId -TurnId 'amb-same-second' -Status 'completed' -StartedAt ([double]$same) -CompletedAt ([double]$same) -Text 'same whole-second timestamp bucket'
    }
    $script:wakeAmbiguitySameSecondClosed = 1

    $hId = New-CasIntHarness -Name 'wake-amb-identity'
    $null = Invoke-CasIntProfile -Harness $hId
    $createdId = Invoke-CasIntDurableCreate -Harness $hId -RunId 'wake-amb-create-5'
    Assert-CasInt ($createdId.exit_code -eq 0) ("Wake-ambiguity identity create failed: $($createdId.stderr) $($createdId.stdout)")
    $tidId = [string]$createdId.json.thread_id
    Stop-CasIntRun -Harness $hId -RunId 'wake-amb-create-5'
    Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hId -ThreadId $tidId -TimeoutMs 20000) 'Wake-ambiguity identity create thread owner did not quiesce.'
    Start-Sleep -Milliseconds 1500
    $ridId = 'telephone-wake-amb-5'
    $null = Write-CasIntWakeAmbiguityQueuedWorld -Harness $hId -ThreadId $tidId -RunId $ridId
    [IO.File]::WriteAllText($hId.prompt, "changed callback bytes`n", [Text.UTF8Encoding]::new($false))
    $ident = Invoke-CasIntLauncher -Harness $hId -ThreadId $tidId -RunId $ridId
    Assert-CasInt ($ident.exit_code -ne 0) 'Identity mismatch was not fail-closed.'
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hId -ThreadId $tidId -RunId $ridId).Count -eq 0) 'Identity mismatch started a callback turn.'
    $script:wakeAmbiguityIdentityMismatchClosed = 1
    Stop-CasIntRun -Harness $hId -RunId $ridId
    Clear-CasIntTestEnv

    $hSend = New-CasIntHarness -Name 'wake-amb-sending'
    $null = Invoke-CasIntProfile -Harness $hSend
    $createdSend = Invoke-CasIntDurableCreate -Harness $hSend -RunId 'wake-amb-create-6'
    Assert-CasInt ($createdSend.exit_code -eq 0) ("Wake-ambiguity sending create failed: $($createdSend.stderr) $($createdSend.stdout)")
    $tidSend = [string]$createdSend.json.thread_id
    Stop-CasIntRun -Harness $hSend -RunId 'wake-amb-create-6'
    Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hSend -ThreadId $tidSend -TimeoutMs 20000) 'Wake-ambiguity sending create thread owner did not quiesce.'
    Start-Sleep -Milliseconds 1500
    $ridSend = 'telephone-wake-amb-6'
    $null = Write-CasIntWakeAmbiguityQueuedWorld -Harness $hSend -ThreadId $tidSend -RunId $ridSend -Phase 'turn_start_sending'
    $send = Invoke-CasIntLauncher -Harness $hSend -ThreadId $tidSend -RunId $ridSend
    Assert-CasInt ($send.exit_code -ne 0) 'Uncertain turn_start_sending without marker proof was not fail-closed.'
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hSend -ThreadId $tidSend -RunId $ridSend).Count -eq 0) 'Uncertain turn_start_sending started a replacement callback turn.'
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hSend -RunId $ridSend).callback_write_phase -ceq 'turn_start_sending') 'Uncertain turn_start_sending changed phase.'
    $script:wakeAmbiguitySendingWithoutMarkerClosed = 1
    Stop-CasIntRun -Harness $hSend -RunId $ridSend
    Clear-CasIntTestEnv

    $hLive = New-CasIntHarness -Name 'wake-amb-live-owner'
    $null = Invoke-CasIntProfile -Harness $hLive
    $createdLive = Invoke-CasIntDurableCreate -Harness $hLive -RunId 'wake-amb-create-7'
    Assert-CasInt ($createdLive.exit_code -eq 0) ("Wake-ambiguity live-owner create failed: $($createdLive.stderr) $($createdLive.stdout)")
    $tidLive = [string]$createdLive.json.thread_id
    Stop-CasIntRun -Harness $hLive -RunId 'wake-amb-create-7'
    Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hLive -ThreadId $tidLive -TimeoutMs 20000) 'Wake-ambiguity live-owner create thread owner did not quiesce.'
    Start-Sleep -Milliseconds 1500
    $ridLive = 'telephone-wake-amb-7'
    $holdLive = Join-Path $hLive.root 'live-owner-hold'
    $logLive = Join-Path $hLive.root 'live-owner.log'
    $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdLive
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $logLive
    $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '20000'
    $firstLive = Invoke-CasIntLauncher -Harness $hLive -ThreadId $tidLive -RunId $ridLive
    Assert-CasInt ($firstLive.exit_code -eq 0) ("Wake-ambiguity live-owner first launch failed: $($firstLive.stderr) $($firstLive.stdout)")
    Assert-CasInt (Test-CasIntThreadOwnerAlive -Harness $hLive -ThreadId $tidLive) 'Wake-ambiguity live-owner lost the live thread owner.'
    $procLive = Start-CasIntLauncherProcess -Harness $hLive -ThreadId $tidLive -RunId $ridLive
    Start-Sleep -Milliseconds 800
    Assert-CasInt (-not $procLive.process.HasExited) 'Wake-ambiguity live-owner second launcher exited instead of attaching.'
    Assert-CasInt ((Get-CasIntEventCount -Path $logLive -Name 'turn/start') -eq 1) 'Wake-ambiguity live-owner started a second turn while the owner was live.'
    [IO.File]::WriteAllText($holdLive, "release`n", [Text.UTF8Encoding]::new($false))
    $null = $procLive.process.WaitForExit(120000)
    $liveExit = [int]$procLive.process.ExitCode
    $liveOut = [string]$procLive.stdout.GetAwaiter().GetResult()
    $procLive.process.Dispose()
    Assert-CasInt ($liveExit -eq 0) ("Wake-ambiguity live-owner attach failed: $liveOut")
    Assert-CasInt ((Get-CasIntEventCount -Path $logLive -Name 'turn/start') -eq 1) 'Wake-ambiguity live-owner attach sent another turn/start.'
    $ackLive = Join-Path (Get-CasIntRunRoot -Harness $hLive -RunId $ridLive) 'lead-wake-ack.json'
    Assert-CasInt (Wait-CasIntPath -Path $ackLive) 'Wake-ambiguity live-owner omitted ack.'
    $turnLive = [string]((Read-TelephoneJson -Path $ackLive -SchemaName 'codex-app-server-lead-ack').value.turn_id)
    $settledLive = Wait-CasIntOfficialTerminalAndQuiet -Harness $hLive -RunId $ridLive -ThreadId $tidLive -TurnId $turnLive
    Assert-CasInt ([bool]$settledLive.success) ("Wake-ambiguity live-owner did not settle: terminal=$([bool]$settledLive.terminal) run_quiet=$([bool]$settledLive.run_quiet) thread_quiet=$([bool]$settledLive.thread_quiet).")
    $script:wakeAmbiguityLiveOwnerSerialized = 1
    Stop-CasIntRun -Harness $hLive -RunId $ridLive
    Clear-CasIntTestEnv

    $hMc = New-CasIntHarness -Name 'wake-amb-match-conflict'
    $null = Invoke-CasIntProfile -Harness $hMc
    $createdMc = Invoke-CasIntDurableCreate -Harness $hMc -RunId 'wake-amb-create-match-conflict'
    Assert-CasInt ($createdMc.exit_code -eq 0) ("Wake-ambiguity match+conflict create failed: $($createdMc.stderr) $($createdMc.stdout)")
    $tidMc = [string]$createdMc.json.thread_id
    Stop-CasIntRun -Harness $hMc -RunId 'wake-amb-create-match-conflict'
    Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hMc -ThreadId $tidMc -TimeoutMs 20000) 'Wake-ambiguity match+conflict create thread owner did not quiesce.'
    Assert-CasInt (Wait-CasIntPriorTurnConservativelyBeforeNow -Harness $hMc -ThreadId $tidMc) 'Wake-ambiguity match+conflict prior turn was not conservatively complete.'
    $ridMc = 'telephone-wake-amb-match-conflict'
    $pathsMc = Write-CasIntWakeAmbiguityQueuedWorld -Harness $hMc -ThreadId $tidMc -RunId $ridMc
    $priorMc = [string](@(Get-CasIntStoreTurns -Harness $hMc -ThreadId $tidMc)[0].id)
    Assert-CasInt (-not [string]::IsNullOrWhiteSpace($priorMc)) 'Wake-ambiguity match+conflict omitted the prior turn id.'
    $intentMc = (Read-TelephoneJson -Path $pathsMc.intent -SchemaName 'codex-app-server-lead-intent').value
    $intentMc.baseline_turn_ids = @($priorMc)
    $null = Write-CodexAppServerValidatedReplace -Path $pathsMc.intent -Value $intentMc -SchemaName 'codex-app-server-lead-intent'
    $runMc = Get-CasIntRunJson -Harness $hMc -RunId $ridMc
    $runMc.baseline_turn_ids = @($priorMc)
    $null = Write-CodexAppServerValidatedReplace -Path $pathsMc.run -Value $runMc -SchemaName 'codex-app-server-lead-run'
    $textMc = New-CodexAppServerTurnInputText -PromptText ([Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes([string]$hMc.prompt))) -RunId $ridMc
    $nowMc = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $logMc = Join-Path $hMc.root 'match-conflict.log'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $logMc
    $env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS = (@(
        [ordered]@{
            id = 'wake-amb-existing-match'
            items = @(, (New-CasIntOfficialUserMessage -Text $textMc -Id 'um-wake-amb-existing-match'))
            itemsView = 'full'
            status = 'completed'
            error = $null
            startedAt = ($nowMc - 2.0)
            completedAt = ($nowMc - 1.0)
            durationMs = 1
        },
        [ordered]@{
            id = 'wake-amb-conflict-completed'
            items = @(, (New-CasIntOfficialUserMessage -Text 'unrelated completed post-intent turn' -Id 'um-wake-amb-conflict-completed'))
            itemsView = 'full'
            status = 'completed'
            error = $null
            startedAt = ($nowMc - 2.0)
            completedAt = ($nowMc - 1.0)
            durationMs = 1
        }
    ) | ConvertTo-Json -Depth 16 -Compress)
    $launchMc = Invoke-CasIntLauncher -Harness $hMc -ThreadId $tidMc -RunId $ridMc
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS -ErrorAction SilentlyContinue
    Assert-CasInt ($launchMc.exit_code -ne 0) 'Exact match plus conflicting completed post-intent turn was not fail-closed.'
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hMc -ThreadId $tidMc -RunId $ridMc).Count -eq 0) 'Exact match plus conflict started a replacement callback turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $logMc -Name 'turn/start') -eq 0) 'Exact match plus conflict sent turn/start.'
    Assert-CasInt (-not [IO.File]::Exists($pathsMc.ack)) 'Exact match plus conflict published ack.'
    Assert-CasInt (-not [IO.File]::Exists($pathsMc.bound_turn)) 'Exact match plus conflict bound a turn.'
    Assert-CasInt ([IO.File]::Exists($pathsMc.intent) -and [IO.File]::Exists($pathsMc.run)) 'Exact match plus conflict dropped queued artifacts.'
    $script:wakeAmbiguityMatchConflictClosed = 1
    Stop-CasIntRun -Harness $hMc -RunId $ridMc
    Clear-CasIntTestEnv

    $probeMarker = 'tl-wake:exact-text-probe'
    $probeExpected = '# frozen callback body tl-wake:exact-text-probe'
    $probeWrong = 'prefix tl-wake:exact-text-probe but wrong frozen callback body'
    $probeWrongTurn = [ordered]@{
        id = 'turn-wrong-body'
        items = @(, (New-CasIntOfficialUserMessage -Text $probeWrong -Id 'um-wrong-body'))
        itemsView = 'full'
        status = 'completed'
        error = $null
        startedAt = 1.0
        completedAt = 2.0
        durationMs = 1
    }
    Assert-CasInt (-not (Test-CodexAppServerExactUserInput -Turn $probeWrongTurn -ExpectedText $probeExpected)) 'Wrong-text probe was treated as exact input.'
    $probeThrew = $false
    $probeMsg = ''
    $probeFound = $null
    try {
        $probeFound = Find-CodexAppServerMatchingTurns -Thread ([ordered]@{ id = 'thread-exact-text-probe'; turns = @(, $probeWrongTurn) }) -Marker $probeMarker -BaselineTurnIds @() -ExpectedText $probeExpected
    } catch {
        $probeThrew = $true
        $probeMsg = [string]$_.Exception.Message
    }
    Assert-CasInt $probeThrew 'Same-marker wrong-text Find did not fail closed.'
    Assert-CasInt ($probeMsg -ceq 'Multiple or conflicting wake-marker turns were present.') ("Same-marker wrong-text Find used a different failure: $probeMsg")
    Assert-CasInt ($null -eq $probeFound) 'Same-marker wrong-text Find returned a match set.'

    $hEx = New-CasIntHarness -Name 'wake-amb-exact-text-attach'
    $null = Invoke-CasIntProfile -Harness $hEx
    $bEx = Invoke-CasIntBuilder -Harness $hEx
    $tidEx = [string]$bEx.json.thread_id
    $ridEx = 'telephone-wake-amb-exact-text'
    $textEx = New-CodexAppServerTurnInputText -PromptText ([Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes([string]$hEx.prompt))) -RunId $ridEx
    $nowEx = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Add-CasIntStoreTurn -Harness $hEx -ThreadId $tidEx -TurnId 'turn-exact-existing' -Status 'completed' -StartedAt ($nowEx - 2.0) -CompletedAt ($nowEx - 1.0) -Text $textEx
    $logEx = Join-Path $hEx.root 'exact-text-attach.log'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $logEx
    $pathsEx = Get-CodexAppServerRunPaths -StateRoot ([string]$hEx.state) -RunId $ridEx
    $launchEx = Invoke-CasIntLauncher -Harness $hEx -ThreadId $tidEx -RunId $ridEx
    Assert-CasInt ($launchEx.exit_code -eq 0) ("Exact marker+text attach failed: $($launchEx.stderr) $($launchEx.stdout)")
    Assert-CasInt (Wait-CasIntPath -Path $pathsEx.ack) 'Exact marker+text attach omitted ack.'
    Assert-CasInt ([string]((Read-TelephoneJson -Path $pathsEx.ack -SchemaName 'codex-app-server-lead-ack').value.turn_id) -ceq 'turn-exact-existing') 'Exact marker+text attach bound a different turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $logEx -Name 'turn/start') -eq 0) 'Exact marker+text attach sent another turn/start.'
    Assert-CasInt ([string](Get-CasIntBoundJson -Harness $hEx -RunId $ridEx).turn_id -ceq 'turn-exact-existing') 'Exact marker+text attach omitted bound-turn.'
    $script:wakeAmbiguityExactTextAttach = 1
    Stop-CasIntRun -Harness $hEx -RunId $ridEx
    Clear-CasIntTestEnv

    $hWrong = New-CasIntHarness -Name 'wake-amb-wrong-text'
    $null = Invoke-CasIntProfile -Harness $hWrong
    $bWrong = Invoke-CasIntBuilder -Harness $hWrong
    $tidWrong = [string]$bWrong.json.thread_id
    $ridWrong = 'telephone-wake-amb-wrong-text'
    $markerWrong = Get-CodexAppServerWakeMarker -RunId $ridWrong
    $wrongText = "prefix $markerWrong but wrong frozen callback body"
    $nowWrong = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Add-CasIntStoreTurn -Harness $hWrong -ThreadId $tidWrong -TurnId 'turn-wrong-body' -Status 'completed' -StartedAt ($nowWrong - 2.0) -CompletedAt ($nowWrong - 1.0) -Text $wrongText
    $logWrong = Join-Path $hWrong.root 'wrong-text.log'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $logWrong
    $pathsWrong = Get-CodexAppServerRunPaths -StateRoot ([string]$hWrong.state) -RunId $ridWrong
    $turnsWrongBefore = @(Get-CasIntStoreTurns -Harness $hWrong -ThreadId $tidWrong).Count
    $launchWrong = Invoke-CasIntLauncher -Harness $hWrong -ThreadId $tidWrong -RunId $ridWrong
    Assert-CasInt ($launchWrong.exit_code -ne 0) 'Same-marker wrong-text launcher was not fail-closed.'
    Assert-CasInt ((Get-CasIntEventCount -Path $logWrong -Name 'turn/start') -eq 0) 'Same-marker wrong-text sent turn/start.'
    Assert-CasInt (-not [IO.File]::Exists($pathsWrong.ack)) 'Same-marker wrong-text published ack.'
    Assert-CasInt (-not [IO.File]::Exists($pathsWrong.bound_turn)) 'Same-marker wrong-text bound a turn.'
    Assert-CasInt (-not [IO.File]::Exists($pathsWrong.result)) 'Same-marker wrong-text published launcher result.'
    Assert-CasInt (-not [IO.File]::Exists($pathsWrong.final)) 'Same-marker wrong-text published launcher final.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hWrong -ThreadId $tidWrong).Count -eq $turnsWrongBefore) 'Same-marker wrong-text started a replacement turn.'
    Assert-CasInt ([IO.File]::Exists($pathsWrong.intent) -and [IO.File]::Exists($pathsWrong.run)) 'Same-marker wrong-text dropped queued artifacts.'
    $script:wakeAmbiguityWrongTextClosed = 1
    Stop-CasIntRun -Harness $hWrong -RunId $ridWrong
    Clear-CasIntTestEnv

    $hBoth = New-CasIntHarness -Name 'wake-amb-exact-plus-wrong-text'
    $null = Invoke-CasIntProfile -Harness $hBoth
    $bBoth = Invoke-CasIntBuilder -Harness $hBoth
    $tidBoth = [string]$bBoth.json.thread_id
    $ridBoth = 'telephone-wake-amb-exact-plus-wrong'
    $textBoth = New-CodexAppServerTurnInputText -PromptText ([Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes([string]$hBoth.prompt))) -RunId $ridBoth
    $markerBoth = Get-CodexAppServerWakeMarker -RunId $ridBoth
    $wrongBoth = "prefix $markerBoth but wrong frozen callback body"
    $nowBoth = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Add-CasIntStoreTurn -Harness $hBoth -ThreadId $tidBoth -TurnId 'turn-exact-keep' -Status 'completed' -StartedAt ($nowBoth - 3.0) -CompletedAt ($nowBoth - 1.0) -Text $textBoth
    Add-CasIntStoreTurn -Harness $hBoth -ThreadId $tidBoth -TurnId 'turn-wrong-sibling' -Status 'completed' -StartedAt ($nowBoth - 2.0) -CompletedAt ($nowBoth - 1.0) -Text $wrongBoth
    $logBoth = Join-Path $hBoth.root 'exact-plus-wrong.log'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $logBoth
    $pathsBoth = Get-CodexAppServerRunPaths -StateRoot ([string]$hBoth.state) -RunId $ridBoth
    $turnsBothBefore = @(Get-CasIntStoreTurns -Harness $hBoth -ThreadId $tidBoth).Count
    $launchBoth = Invoke-CasIntLauncher -Harness $hBoth -ThreadId $tidBoth -RunId $ridBoth
    Assert-CasInt ($launchBoth.exit_code -ne 0) 'Exact match plus same-marker wrong-text was not fail-closed.'
    Assert-CasInt ((Get-CasIntEventCount -Path $logBoth -Name 'turn/start') -eq 0) 'Exact match plus wrong-text sent turn/start.'
    Assert-CasInt (-not [IO.File]::Exists($pathsBoth.ack)) 'Exact match plus wrong-text published ack.'
    Assert-CasInt (-not [IO.File]::Exists($pathsBoth.bound_turn)) 'Exact match plus wrong-text bound a turn.'
    Assert-CasInt (-not [IO.File]::Exists($pathsBoth.result)) 'Exact match plus wrong-text published launcher result.'
    Assert-CasInt (-not [IO.File]::Exists($pathsBoth.final)) 'Exact match plus wrong-text published launcher final.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hBoth -ThreadId $tidBoth).Count -eq $turnsBothBefore) 'Exact match plus wrong-text started a replacement turn.'
    Assert-CasInt ([IO.File]::Exists($pathsBoth.intent) -and [IO.File]::Exists($pathsBoth.run)) 'Exact match plus wrong-text dropped queued artifacts.'
    $script:wakeAmbiguityExactPlusWrongTextClosed = 1
    Stop-CasIntRun -Harness $hBoth -RunId $ridBoth
    Clear-CasIntTestEnv

    $hMal = New-CasIntHarness -Name 'wake-amb-malformed-protocol'
    $null = Invoke-CasIntProfile -Harness $hMal
    $createdMal = Invoke-CasIntDurableCreate -Harness $hMal -RunId 'wake-amb-create-malformed'
    Assert-CasInt ($createdMal.exit_code -eq 0) ("Wake-ambiguity malformed-protocol create failed: $($createdMal.stderr) $($createdMal.stdout)")
    $tidMal = [string]$createdMal.json.thread_id
    Stop-CasIntRun -Harness $hMal -RunId 'wake-amb-create-malformed'
    Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hMal -ThreadId $tidMal -TimeoutMs 20000) 'Wake-ambiguity malformed-protocol create thread owner did not quiesce.'
    Assert-CasInt (Wait-CasIntPriorTurnConservativelyBeforeNow -Harness $hMal -ThreadId $tidMal) 'Wake-ambiguity malformed-protocol prior turn was not conservatively complete.'
    $ridMal = 'telephone-wake-amb-malformed'
    $pathsMal = Write-CasIntWakeAmbiguityQueuedWorld -Harness $hMal -ThreadId $tidMal -RunId $ridMal
    $priorMal = [string](@(Get-CasIntStoreTurns -Harness $hMal -ThreadId $tidMal)[0].id)
    $intentMal = (Read-TelephoneJson -Path $pathsMal.intent -SchemaName 'codex-app-server-lead-intent').value
    $intentMal.baseline_turn_ids = @($priorMal)
    $null = Write-CodexAppServerValidatedReplace -Path $pathsMal.intent -Value $intentMal -SchemaName 'codex-app-server-lead-intent'
    $runMal = Get-CasIntRunJson -Harness $hMal -RunId $ridMal
    $runMal.baseline_turn_ids = @($priorMal)
    $null = Write-CodexAppServerValidatedReplace -Path $pathsMal.run -Value $runMal -SchemaName 'codex-app-server-lead-run'
    $textMal = New-CodexAppServerTurnInputText -PromptText ([Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes([string]$hMal.prompt))) -RunId $ridMal
    $nowMal = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $logMal = Join-Path $hMal.root 'malformed-protocol.log'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $logMal
    $env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS = (@(
        [ordered]@{
            id = 'wake-amb-malformed-match'
            items = @(, (New-CasIntOfficialUserMessage -Text $textMal -Id 'um-wake-amb-malformed-match'))
            itemsView = 'full'
            status = 'completed'
            error = $null
            startedAt = ($nowMal - 2.0)
            completedAt = ($nowMal - 1.0)
            durationMs = 1
        },
        [ordered]@{
            id = 'wake-amb-malformed-turn'
            items = @(, [ordered]@{
                type = 'userMessage'
                id = 'um-wake-amb-malformed-turn'
                clientId = $null
                unknownField = $true
                content = @(
                    [ordered]@{ type = 'text'; text = 'malformed userMessage projection'; text_elements = @() }
                )
            })
            itemsView = 'full'
            status = 'completed'
            error = $null
            startedAt = ($nowMal - 2.0)
            completedAt = ($nowMal - 1.0)
            durationMs = 1
        }
    ) | ConvertTo-Json -Depth 16 -Compress)
    $launchMal = Invoke-CasIntLauncher -Harness $hMal -ThreadId $tidMal -RunId $ridMal
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS -ErrorAction SilentlyContinue
    Assert-CasInt ($launchMal.exit_code -ne 0) 'Malformed stable-protocol evidence was not fail-closed.'
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hMal -ThreadId $tidMal -RunId $ridMal).Count -eq 0) 'Malformed stable-protocol evidence started a callback turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $logMal -Name 'turn/start') -eq 0) 'Malformed stable-protocol evidence sent turn/start.'
    Assert-CasInt (-not [IO.File]::Exists($pathsMal.ack)) 'Malformed stable-protocol evidence published ack.'
    Assert-CasInt (-not [IO.File]::Exists($pathsMal.bound_turn)) 'Malformed stable-protocol evidence bound a turn.'
    Assert-CasInt ([IO.File]::Exists($pathsMal.intent) -and [IO.File]::Exists($pathsMal.run)) 'Malformed stable-protocol evidence dropped queued artifacts.'
    $script:wakeAmbiguityMalformedProtocolClosed = 1
    Stop-CasIntRun -Harness $hMal -RunId $ridMal
    Clear-CasIntTestEnv

    $h320 = New-CasIntHarness -Name 'wake-amb-unrelated-32000'
    $null = Invoke-CasIntProfile -Harness $h320
    $b320 = Invoke-CasIntBuilder -Harness $h320
    $tid320 = [string]$b320.json.thread_id
    $log320 = Join-Path $h320.root 'unrelated-32000.log'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $log320
    $env:TELEPHONE_TEST_APP_SERVER_TURN_START_ERROR_MESSAGE = 'internal server error'
    $env:TELEPHONE_TEST_APP_SERVER_TURN_START_ERROR_CODE = '-32000'
    $launch320 = Invoke-CasIntLauncher -Harness $h320 -ThreadId $tid320 -RunId 'run-unrelated-32000'
    Assert-CasInt ($launch320.exit_code -ne 0) 'Unrelated -32000 was not fail-closed.'
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $h320 -ThreadId $tid320 -RunId 'run-unrelated-32000').Count -eq 0) 'Unrelated -32000 started a callback turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $log320 -Name 'turn/start') -eq 0) 'Unrelated -32000 sent turn/start.'
    Assert-CasInt ((Get-CasIntEventCount -Path $log320 -Name 'turn/start_unrelated_error') -eq 1) 'Unrelated -32000 did not surface the forced server error.'
    Assert-CasInt ((Get-CasIntEventCount -Path $log320 -Name 'turn/start_busy') -eq 0) 'Unrelated -32000 was treated as waitable busy.'
    $paths320 = Get-CodexAppServerRunPaths -StateRoot ([string]$h320.state) -RunId 'run-unrelated-32000'
    Assert-CasInt (-not [IO.File]::Exists($paths320.ack)) 'Unrelated -32000 published ack.'
    Assert-CasInt (-not [IO.File]::Exists($paths320.bound_turn)) 'Unrelated -32000 bound a turn.'
    Assert-CasInt ([IO.File]::Exists($paths320.intent) -and [IO.File]::Exists($paths320.run)) 'Unrelated -32000 dropped queued artifacts.'
    $script:wakeAmbiguityUnrelatedBusyCodeClosed = 1
    Stop-CasIntRun -Harness $h320 -RunId 'run-unrelated-32000'
    Clear-CasIntTestEnv

    $hRace = New-CasIntHarness -Name 'wake-amb-owner-observe-race'
    $null = Invoke-CasIntProfile -Harness $hRace
    $createdRace = Invoke-CasIntDurableCreate -Harness $hRace -RunId 'wake-amb-create-race'
    Assert-CasInt ($createdRace.exit_code -eq 0) ("Owner-observe race create failed: $($createdRace.stderr) $($createdRace.stdout)")
    $tidRace = [string]$createdRace.json.thread_id
    Assert-CasInt (Wait-CasIntRunOwnerQuiet -Harness $hRace -RunId 'wake-amb-create-race' -TimeoutMs 20000) 'Owner-observe race create owner did not quiesce.'
    Stop-CasIntRun -Harness $hRace -RunId 'wake-amb-create-race'
    Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hRace -ThreadId $tidRace -TimeoutMs 20000) 'Owner-observe race create thread owner did not quiesce.'
    $racePaths = Get-CodexAppServerThreadPaths -StateRoot ([string]$hRace.state) -ThreadId $tidRace
    [IO.Directory]::CreateDirectory($racePaths.thread_root) | Out-Null
    $staleRace = [ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-owner-v1'
        pid = 1
        start_time_utc_ticks = [int64]1
        started_at_utc = '2026-01-01T00:00:00.0000000+00:00'
        thread_id = $tidRace
    }
    $null = Write-CodexAppServerValidatedReplace -Path $racePaths.owner -Value $staleRace -SchemaName 'codex-app-server-lead-owner'
    $env:TELEPHONE_TEST_APP_SERVER_OWNER_OBSERVE_FAULT = '3'
    $observedRace = Read-CodexAppServerThreadOwner -ThreadPaths $racePaths
    Assert-CasInt ($null -ne $observedRace -and [int]$observedRace.pid -eq 1) 'Owner observation did not re-evaluate past injected read faults.'
    [IO.File]::WriteAllBytes($racePaths.owner, [byte[]]@(0x7B))
    $emptyThrew = $false
    $emptyMsg = ''
    try { $null = Read-CodexAppServerThreadOwner -ThreadPaths $racePaths } catch {
        $emptyThrew = $true
        $emptyMsg = [string]$_.Exception.Message
    }
    Assert-CasInt ($emptyThrew -and $emptyMsg -ceq (Get-CodexAppServerPublicMessage -Code 'OWNER_INVALID')) 'Stable malformed owner was not OWNER_INVALID after retries.'
    if ([IO.File]::Exists($racePaths.owner)) { [IO.File]::Delete($racePaths.owner) }
    $gone = Read-CodexAppServerThreadOwner -ThreadPaths $racePaths
    Assert-CasInt ($null -eq $gone) 'Missing thread owner was not re-evaluated as absent.'
    $ridRace = 'telephone-wake-amb-race'
    $eventRace = Join-Path $hRace.root 'owner-observe-race.log'
    $null = Write-CasIntWakeAmbiguityQueuedWorld -Harness $hRace -ThreadId $tidRace -RunId $ridRace
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventRace
    $env:TELEPHONE_TEST_APP_SERVER_OWNER_OBSERVE_FAULT = '4'
    $stopRace = Join-Path $hRace.root 'owner-race-stop'
    $interleave = Join-Path $hRace.root 'owner-race-interleave.ps1'
    [IO.File]::WriteAllText($interleave, @"
param([string]`$OwnerPath, [string]`$StopPath)
`$deadline = [DateTimeOffset]::UtcNow.AddMilliseconds(400)
Start-Sleep -Milliseconds 20
while (-not [IO.File]::Exists(`$StopPath) -and [DateTimeOffset]::UtcNow -lt `$deadline) {
    try {
        if ([IO.File]::Exists(`$OwnerPath)) {
            [IO.File]::WriteAllBytes(`$OwnerPath, [byte[]]@(0x7B))
            Start-Sleep -Milliseconds 12
            if ([IO.File]::Exists(`$OwnerPath)) { [IO.File]::Delete(`$OwnerPath) }
        }
    } catch { }
    Start-Sleep -Milliseconds 12
}
"@, [Text.UTF8Encoding]::new($false))
    $raceInfo = [Diagnostics.ProcessStartInfo]::new()
    $raceInfo.FileName = $pwsh
    $raceInfo.UseShellExecute = $false
    $raceInfo.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $interleave, '-OwnerPath', [string]$racePaths.owner, '-StopPath', $stopRace)) {
        [void]$raceInfo.ArgumentList.Add([string]$argument)
    }
    $raceProc = [Diagnostics.Process]::Start($raceInfo)
    try {
        $firstRace = Invoke-CasIntLauncher -Harness $hRace -ThreadId $tidRace -RunId $ridRace
        Assert-CasInt ($firstRace.exit_code -eq 0) ("Owner-observe race launch failed: $($firstRace.stderr) $($firstRace.stdout)")
        Assert-CasInt ([bool]$firstRace.json.started) 'Owner-observe race launcher omitted started ack.'
        $pathsRace = Get-CodexAppServerRunPaths -StateRoot ([string]$hRace.state) -RunId $ridRace
        Assert-CasInt (Wait-CasIntPath -Path $pathsRace.ack) 'Owner-observe race did not publish ack.'
        $turnRace = [string]((Read-TelephoneJson -Path $pathsRace.ack -SchemaName 'codex-app-server-lead-ack').value.turn_id)
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace($turnRace)) 'Owner-observe race ack omitted turn id.'
        $settledRace = Wait-CasIntOfficialTerminalAndQuiet -Harness $hRace -RunId $ridRace -ThreadId $tidRace -TurnId $turnRace
        Assert-CasInt ([bool]$settledRace.success) ("Owner-observe race did not settle: terminal=$([bool]$settledRace.terminal) run_quiet=$([bool]$settledRace.run_quiet) thread_quiet=$([bool]$settledRace.thread_quiet).")
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hRace -ThreadId $tidRace -RunId $ridRace).Count -eq 1) 'Owner-observe race did not keep exactly one callback marker turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $eventRace -Name 'turn/start') -eq 1) 'Owner-observe race did not send exactly one turn/start.'
        Assert-CasInt (-not (Test-CasIntOwnerAlive -Harness $hRace -RunId $ridRace)) 'Owner-observe race left a live per-run owner.'
        Assert-CasInt (-not (Test-CasIntThreadOwnerAlive -Harness $hRace -ThreadId $tidRace)) 'Owner-observe race left a live thread owner.'
        Assert-CasInt (-not (Test-CasIntIdentityKeyAlive -IdentityKey (Get-CasIntChildIdentityKey -Harness $hRace -RunId $ridRace))) 'Owner-observe race left a live child.'
    } finally {
        [IO.File]::WriteAllText($stopRace, "stop`n", [Text.UTF8Encoding]::new($false))
        if ($null -ne $raceProc) {
            $null = $raceProc.WaitForExit(5000)
            if (-not $raceProc.HasExited) { try { Stop-Process -Id $raceProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
            $raceProc.Dispose()
        }
    }
    $script:wakeAmbiguityOwnerObserveRaceClosed = 1
    Stop-CasIntRun -Harness $hRace -RunId $ridRace
    Clear-CasIntTestEnv

    $frozenTid = '01a038e9-8da3-70f3-a2c8-4f28a8a3ac8e'
    $bt = [char]96
    $frozenExact = ('session ' + $frozenTid + ' is archived. Run ' + $bt + 'codex unarchive ' + $frozenTid + $bt + ' to unarchive it first.')
    Assert-CasInt ($frozenExact -ceq (Get-CodexAppServerArchivedThreadErrorMessage -ThreadId $frozenTid)) 'Canonical archived grammar drifted from the frozen 0.149.1 message.'
    Assert-CasInt (Test-CodexAppServerArchivedThreadError -Code ([int64]-32600) -Message $frozenExact -ThreadId $frozenTid) 'Exact frozen archived resume message was not recognized.'
    $classifierTid = 'thread-archived-classifier-1'
    $classifierAdvice = Get-CodexAppServerArchivedResumeAdvice -ThreadId $classifierTid
    $classifierExact = Get-CodexAppServerArchivedThreadErrorMessage -ThreadId $classifierTid
    Assert-CasInt ($classifierAdvice -ceq ('codex unarchive ' + $classifierTid)) 'Canonical archived advice fragment drifted.'
    Assert-CasInt (Test-CodexAppServerArchivedThreadError -Code ([int64]-32600) -Message $classifierExact -ThreadId $classifierTid) 'Canonical archived grammar was not recognized.'
    Assert-CasInt (-not (Test-CodexAppServerArchivedThreadError -Code ([int64]-32600) -Message $classifierAdvice -ThreadId $classifierTid)) 'Advice-only text was classified as archived.'
    Assert-CasInt (-not (Test-CodexAppServerArchivedThreadError -Code ([int64]-32600) -Message ('The conversation is archived. Restore it with: ' + $classifierAdvice) -ThreadId $classifierTid)) 'Wrapped archived wording was classified as archived.'
    Assert-CasInt (-not (Test-CodexAppServerArchivedThreadError -Code ([int64]-32600) -Message ('prefix ' + $classifierExact) -ThreadId $classifierTid)) 'Prefixed archived wording was classified as archived.'
    Assert-CasInt (-not (Test-CodexAppServerArchivedThreadError -Code ([int64]-32600) -Message ($classifierExact + ' extra') -ThreadId $classifierTid)) 'Suffixed archived wording was classified as archived.'
    Assert-CasInt (-not (Test-CodexAppServerArchivedThreadError -Code ([int64]-32600) -Message ('session ' + $classifierTid + ' is archived. Run codex unarchive ' + $classifierTid + ' to unarchive it first.') -ThreadId $classifierTid)) 'Archived wording missing backticks was classified as archived.'
    Assert-CasInt (-not (Test-CodexAppServerArchivedThreadError -Code ([int64]-32700) -Message $classifierExact -ThreadId $classifierTid)) 'Wrong JSON-RPC code was classified as archived.'
    Assert-CasInt (-not (Test-CodexAppServerArchivedThreadError -Code ([int64]-32600) -Message 'The session is archived; restore it before resuming.' -ThreadId $classifierTid)) 'Noncanonical archived wording was classified as archived.'
    Assert-CasInt (-not (Test-CodexAppServerArchivedThreadError -Code ([int64]-32600) -Message 'The session is archived. Restore it with: codex unarchive' -ThreadId $classifierTid)) 'Archived wording missing the thread id was classified as archived.'
    Assert-CasInt (-not (Test-CodexAppServerArchivedThreadError -Code ([int64]-32600) -Message (Get-CodexAppServerArchivedThreadErrorMessage -ThreadId 'other-thread-id-1') -ThreadId $classifierTid)) 'Mismatched archived thread id was classified as archived.'
    Assert-CasInt (-not (Test-CodexAppServerArchivedThreadError -Code ([int64]-32602) -Message 'Invalid params' -ThreadId $classifierTid)) 'Unrelated resume error was classified as archived.'
    Assert-CasInt (-not (Test-CodexAppServerArchivedThreadError -Code ([int64]-32600) -Message ([ordered]@{ text = $classifierExact }) -ThreadId $classifierTid)) 'Non-string archived message was classified as archived.'

    $archPos = New-CasIntArchivedWakeWorld -Name 'wake-amb-archived-positive' -CreateId 'wake-amb-arch-create-1' -RunId 'telephone-wake-amb-arch-1' -Remaining 1 -Code ([int64]-32600) -UseForwarder -JsonResumeError
    $firstArch = Invoke-CasIntLauncher -Harness $archPos.harness -ThreadId ([string]$archPos.thread_id) -RunId ([string]$archPos.run_id) -CodexCommand ([string]$archPos.forwarder)
    Assert-CasInt ($firstArch.exit_code -eq 0) ("Archived positive launch failed: $($firstArch.stderr) $($firstArch.stdout)")
    Assert-CasInt (Wait-CasIntPath -Path $archPos.paths.ack) 'Archived positive did not publish ack.'
    $turnArch = [string]((Read-TelephoneJson -Path $archPos.paths.ack -SchemaName 'codex-app-server-lead-ack').value.turn_id)
    Assert-CasInt (-not [string]::IsNullOrWhiteSpace($turnArch)) 'Archived positive ack omitted turn id.'
    $settledArch = Wait-CasIntOfficialTerminalAndQuiet -Harness $archPos.harness -RunId ([string]$archPos.run_id) -ThreadId ([string]$archPos.thread_id) -TurnId $turnArch
    Assert-CasInt ([bool]$settledArch.success) ("Archived positive did not settle: terminal=$([bool]$settledArch.terminal) run_quiet=$([bool]$settledArch.run_quiet) thread_quiet=$([bool]$settledArch.thread_quiet) phase=$([string]$settledArch.phase) state=$([string]$settledArch.state).")
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $archPos.harness -ThreadId ([string]$archPos.thread_id) -RunId ([string]$archPos.run_id)).Count -eq 1) 'Archived positive did not keep exactly one callback marker turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path ([string]$archPos.event_log) -Name 'turn/start') -eq 1) 'Archived positive did not send exactly one turn/start.'
    $intentArch = (Read-TelephoneJson -Path $archPos.paths.intent -SchemaName 'codex-app-server-lead-intent').value
    $runArch = Get-CasIntRunJson -Harness $archPos.harness -RunId ([string]$archPos.run_id)
    $intentArchBaseline = @(Get-CodexAppServerStringList -Value $intentArch.baseline_turn_ids)
    $runArchBaseline = @(Get-CodexAppServerStringList -Value $runArch.baseline_turn_ids)
    Assert-CasInt ($intentArchBaseline.Count -eq 1 -and $intentArchBaseline[0] -ceq [string]$archPos.prior_id) ("Archived positive did not capture the prior Lead turn in intent baseline. prior=$([string]$archPos.prior_id) intent=[$([string]::Join(',', $intentArchBaseline))]")
    Assert-CasInt ($runArchBaseline.Count -eq 1 -and $runArchBaseline[0] -ceq [string]$archPos.prior_id) ("Archived positive did not capture the prior Lead turn in run baseline. prior=$([string]$archPos.prior_id) run=[$([string]::Join(',', $runArchBaseline))]")
    Assert-CasIntUnarchiveCommandBoundary -LogPath ([string]$archPos.command_log) -Executable ([string]$archPos.forwarder) -ThreadId ([string]$archPos.thread_id) -Count 1 -ExitCode 0
    Assert-CasInt ((Get-CasIntEventCount -Path ([string]$archPos.event_log) -Name 'thread/resume-archived-json-error') -eq 1) 'Archived positive did not receive exactly one JSON archived thread/resume error from the fake App Server.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path $archPos.harness.root 'archived-resume-once.json'))) 'Archived positive planted a pre-request injection file.'
    Assert-CasInt ([string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_TEST_APP_SERVER_ARCHIVED_RESUME_ONCE)) 'Archived positive used pre-request injection as the sole error path.'
    Assert-CasIntWakeArtifactsAgree -Harness $archPos.harness -RunId ([string]$archPos.run_id) -ThreadId ([string]$archPos.thread_id) -TurnId $turnArch
    $script:wakeAmbiguityArchivedResumeOnce = 1
    $script:wakeAmbiguityArchivedCommandBoundary = 1
    $script:wakeAmbiguityArchivedRawJsonResumeError = 1
    $repeatArch = Invoke-CasIntLauncher -Harness $archPos.harness -ThreadId ([string]$archPos.thread_id) -RunId ([string]$archPos.run_id) -CodexCommand ([string]$archPos.forwarder)
    Assert-CasInt ($repeatArch.exit_code -eq 0) ("Archived repeat launcher failed: $($repeatArch.stderr) $($repeatArch.stdout)")
    Assert-CasInt ([string]$repeatArch.json.state -ceq 'completed') 'Archived repeat did not return the official terminal.'
    Assert-CasInt ([string](Get-CasIntBoundJson -Harness $archPos.harness -RunId ([string]$archPos.run_id)).turn_id -ceq $turnArch) 'Archived repeat bound a different turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path ([string]$archPos.event_log) -Name 'turn/start') -eq 1) 'Archived repeat sent another turn/start.'
    Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $archPos.harness -ThreadId ([string]$archPos.thread_id) -RunId ([string]$archPos.run_id)).Count -eq 1) 'Archived repeat created another marker turn.'
    Assert-CasIntUnarchiveCommandBoundary -LogPath ([string]$archPos.command_log) -Executable ([string]$archPos.forwarder) -ThreadId ([string]$archPos.thread_id) -Count 1 -ExitCode 0
    Assert-CasInt ((Get-CasIntEventCount -Path ([string]$archPos.event_log) -Name 'thread/resume-archived-json-error') -eq 1) 'Archived repeat emitted another JSON archived thread/resume error.'
    Assert-CasIntWakeArtifactsAgree -Harness $archPos.harness -RunId ([string]$archPos.run_id) -ThreadId ([string]$archPos.thread_id) -TurnId $turnArch
    $script:wakeAmbiguityArchivedRepeatNoSecondUnarchive = 1
    Stop-CasIntRun -Harness $archPos.harness -RunId ([string]$archPos.run_id)
    Clear-CasIntTestEnv

    $archWrong = New-CasIntArchivedWakeWorld -Name 'wake-amb-archived-wrong-code' -CreateId 'wake-amb-arch-create-2' -RunId 'telephone-wake-amb-arch-2' -Remaining 1 -Code ([int64]-32700)
    $null = Write-CasIntArchivedResumeOnce -Harness $archWrong.harness -Remaining 1 -Code ([int64]-32700) -Message (Get-CodexAppServerArchivedResumeAdvice -ThreadId ([string]$archWrong.thread_id))
    $wrongLaunch = Invoke-CasIntLauncher -Harness $archWrong.harness -ThreadId ([string]$archWrong.thread_id) -RunId ([string]$archWrong.run_id) -CodexCommand ([string]$archWrong.forwarder)
    Assert-CasIntArchivedPublicFailure -Launch $wrongLaunch
    Assert-CasIntArchivedNoCallback -Harness $archWrong.harness -ThreadId ([string]$archWrong.thread_id) -RunId ([string]$archWrong.run_id) -Paths $archWrong.paths -EventLog ([string]$archWrong.event_log)
    Assert-CasIntUnarchiveCommandBoundary -LogPath ([string]$archWrong.command_log) -Executable ([string]$archWrong.forwarder) -ThreadId ([string]$archWrong.thread_id) -Count 0
    $script:wakeAmbiguityArchivedWrongCodeClosed = 1
    Stop-CasIntRun -Harness $archWrong.harness -RunId ([string]$archWrong.run_id)
    Clear-CasIntTestEnv

    $archWording = New-CasIntArchivedWakeWorld -Name 'wake-amb-archived-noncanonical' -CreateId 'wake-amb-arch-create-3' -RunId 'telephone-wake-amb-arch-3' -Remaining 1 -Code ([int64]-32600) -Message 'The session is archived; restore it before resuming.'
    $wordingLaunch = Invoke-CasIntLauncher -Harness $archWording.harness -ThreadId ([string]$archWording.thread_id) -RunId ([string]$archWording.run_id) -CodexCommand ([string]$archWording.forwarder)
    Assert-CasIntArchivedPublicFailure -Launch $wordingLaunch
    Assert-CasIntArchivedNoCallback -Harness $archWording.harness -ThreadId ([string]$archWording.thread_id) -RunId ([string]$archWording.run_id) -Paths $archWording.paths -EventLog ([string]$archWording.event_log)
    Assert-CasIntUnarchiveCommandBoundary -LogPath ([string]$archWording.command_log) -Executable ([string]$archWording.forwarder) -ThreadId ([string]$archWording.thread_id) -Count 0
    $script:wakeAmbiguityArchivedNoncanonicalClosed = 1
    Stop-CasIntRun -Harness $archWording.harness -RunId ([string]$archWording.run_id)
    Clear-CasIntTestEnv

    $archMissing = New-CasIntArchivedWakeWorld -Name 'wake-amb-archived-missing-id' -CreateId 'wake-amb-arch-create-4' -RunId 'telephone-wake-amb-arch-4' -Remaining 1 -Code ([int64]-32600) -Message 'The session is archived. Restore it with: codex unarchive'
    $missingLaunch = Invoke-CasIntLauncher -Harness $archMissing.harness -ThreadId ([string]$archMissing.thread_id) -RunId ([string]$archMissing.run_id) -CodexCommand ([string]$archMissing.forwarder)
    Assert-CasIntArchivedPublicFailure -Launch $missingLaunch
    Assert-CasIntArchivedNoCallback -Harness $archMissing.harness -ThreadId ([string]$archMissing.thread_id) -RunId ([string]$archMissing.run_id) -Paths $archMissing.paths -EventLog ([string]$archMissing.event_log)
    Assert-CasIntUnarchiveCommandBoundary -LogPath ([string]$archMissing.command_log) -Executable ([string]$archMissing.forwarder) -ThreadId ([string]$archMissing.thread_id) -Count 0
    $script:wakeAmbiguityArchivedMissingIdClosed = 1
    Stop-CasIntRun -Harness $archMissing.harness -RunId ([string]$archMissing.run_id)
    Clear-CasIntTestEnv

    $archMismatch = New-CasIntArchivedWakeWorld -Name 'wake-amb-archived-mismatched-id' -CreateId 'wake-amb-arch-create-5' -RunId 'telephone-wake-amb-arch-5' -Remaining 1 -Code ([int64]-32600) -Message (Get-CodexAppServerArchivedResumeAdvice -ThreadId 'other-thread-id-1')
    $mismatchLaunch = Invoke-CasIntLauncher -Harness $archMismatch.harness -ThreadId ([string]$archMismatch.thread_id) -RunId ([string]$archMismatch.run_id) -CodexCommand ([string]$archMismatch.forwarder)
    Assert-CasIntArchivedPublicFailure -Launch $mismatchLaunch
    Assert-CasIntArchivedNoCallback -Harness $archMismatch.harness -ThreadId ([string]$archMismatch.thread_id) -RunId ([string]$archMismatch.run_id) -Paths $archMismatch.paths -EventLog ([string]$archMismatch.event_log)
    Assert-CasIntUnarchiveCommandBoundary -LogPath ([string]$archMismatch.command_log) -Executable ([string]$archMismatch.forwarder) -ThreadId ([string]$archMismatch.thread_id) -Count 0
    $script:wakeAmbiguityArchivedMismatchedIdClosed = 1
    Stop-CasIntRun -Harness $archMismatch.harness -RunId ([string]$archMismatch.run_id)
    Clear-CasIntTestEnv

    $archUnrelated = New-CasIntArchivedWakeWorld -Name 'wake-amb-archived-unrelated' -CreateId 'wake-amb-arch-create-6' -RunId 'telephone-wake-amb-arch-6' -Remaining 1 -Code ([int64]-32602) -Message 'Invalid params'
    $unrelatedLaunch = Invoke-CasIntLauncher -Harness $archUnrelated.harness -ThreadId ([string]$archUnrelated.thread_id) -RunId ([string]$archUnrelated.run_id) -CodexCommand ([string]$archUnrelated.forwarder)
    Assert-CasIntArchivedPublicFailure -Launch $unrelatedLaunch
    Assert-CasIntArchivedNoCallback -Harness $archUnrelated.harness -ThreadId ([string]$archUnrelated.thread_id) -RunId ([string]$archUnrelated.run_id) -Paths $archUnrelated.paths -EventLog ([string]$archUnrelated.event_log)
    Assert-CasIntUnarchiveCommandBoundary -LogPath ([string]$archUnrelated.command_log) -Executable ([string]$archUnrelated.forwarder) -ThreadId ([string]$archUnrelated.thread_id) -Count 0
    $script:wakeAmbiguityArchivedUnrelatedResumeClosed = 1
    Stop-CasIntRun -Harness $archUnrelated.harness -RunId ([string]$archUnrelated.run_id)
    Clear-CasIntTestEnv

    $archFail = New-CasIntArchivedWakeWorld -Name 'wake-amb-archived-unarchive-fail' -CreateId 'wake-amb-arch-create-7' -RunId 'telephone-wake-amb-arch-7' -Remaining 1 -Code ([int64]-32600) -UnarchiveExit '2' -UseForwarder
    $failLaunch = Invoke-CasIntLauncher -Harness $archFail.harness -ThreadId ([string]$archFail.thread_id) -RunId ([string]$archFail.run_id) -CodexCommand ([string]$archFail.forwarder)
    Assert-CasIntArchivedPublicFailure -Launch $failLaunch
    Assert-CasIntArchivedNoCallback -Harness $archFail.harness -ThreadId ([string]$archFail.thread_id) -RunId ([string]$archFail.run_id) -Paths $archFail.paths -EventLog ([string]$archFail.event_log)
    Assert-CasIntUnarchiveCommandBoundary -LogPath ([string]$archFail.command_log) -Executable ([string]$archFail.forwarder) -ThreadId ([string]$archFail.thread_id) -Count 1 -ExitCode 2
    $script:wakeAmbiguityArchivedUnarchiveFailedClosed = 1
    Stop-CasIntRun -Harness $archFail.harness -RunId ([string]$archFail.run_id)
    Clear-CasIntTestEnv

    $archRetry = New-CasIntArchivedWakeWorld -Name 'wake-amb-archived-retry-fail' -CreateId 'wake-amb-arch-create-8' -RunId 'telephone-wake-amb-arch-8' -Remaining 2 -Code ([int64]-32600) -UseForwarder
    $retryLaunch = Invoke-CasIntLauncher -Harness $archRetry.harness -ThreadId ([string]$archRetry.thread_id) -RunId ([string]$archRetry.run_id) -CodexCommand ([string]$archRetry.forwarder)
    Assert-CasIntArchivedPublicFailure -Launch $retryLaunch
    Assert-CasIntArchivedNoCallback -Harness $archRetry.harness -ThreadId ([string]$archRetry.thread_id) -RunId ([string]$archRetry.run_id) -Paths $archRetry.paths -EventLog ([string]$archRetry.event_log)
    Assert-CasIntUnarchiveCommandBoundary -LogPath ([string]$archRetry.command_log) -Executable ([string]$archRetry.forwarder) -ThreadId ([string]$archRetry.thread_id) -Count 1 -ExitCode 0
    $script:wakeAmbiguityArchivedRetryFailedClosed = 1
    Stop-CasIntRun -Harness $archRetry.harness -RunId ([string]$archRetry.run_id)
    Clear-CasIntTestEnv
}

function Wait-CasIntStatus {
    param($Harness, [string]$RunId, [scriptblock]$Predicate, [string]$Message, [int]$TimeoutMs = 20000)
    $statusPath = Join-Path (Get-CasIntRunRoot -Harness $Harness -RunId $RunId) 'status.json'
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    $last = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ([IO.File]::Exists($statusPath)) {
            try {
                $last = (Read-TelephoneJson -Path $statusPath -SchemaName 'codex-app-server-lead-status').value
                if (& $Predicate $last) { return $last }
            } catch {
                $last = $null
            }
        }
        Start-Sleep -Milliseconds 50
    }
    throw $Message
}

function Invoke-CasIntSharedJsonRead {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$SchemaName = ''
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    $last = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            if ([string]::IsNullOrWhiteSpace($SchemaName)) {
                return (Read-TelephoneJson -Path $Path).value
            }
            return (Read-TelephoneJson -Path $Path -SchemaName $SchemaName).value
        } catch {
            $last = $_
            Start-Sleep -Milliseconds 50
        }
    }
    throw $last
}

function Get-CasIntRunJson {
    param($Harness, [string]$RunId)
    return Invoke-CasIntSharedJsonRead -Path (Join-Path (Get-CasIntRunRoot -Harness $Harness -RunId $RunId) 'run.json') -SchemaName 'codex-app-server-lead-run'
}

function Get-CasIntBoundJson {
    param($Harness, [string]$RunId)
    return Invoke-CasIntSharedJsonRead -Path (Join-Path (Get-CasIntRunRoot -Harness $Harness -RunId $RunId) 'bound-turn.json')
}

function Get-CasIntFinalText {
    param($Harness, [string]$RunId)
    $path = Join-Path (Get-CasIntRunRoot -Harness $Harness -RunId $RunId) 'launcher-final.txt'
    if (-not [IO.File]::Exists($path)) { return '' }
    return ([IO.File]::ReadAllText($path)).Trim()
}

function Write-CasIntPlantedIntent {
    param($Harness, [string]$RunId, [string]$ThreadId, [AllowEmptyCollection()][string[]]$Baseline = @())
    $paths = Get-CodexAppServerRunPaths -StateRoot ([string]$Harness.state) -RunId $RunId
    [IO.Directory]::CreateDirectory($paths.run_root) | Out-Null
    $identity = Get-TelephoneFileIdentity -Path ([string]$Harness.prompt)
    $profile = (Read-TelephoneJson -Path ([string]$Harness.profile) -SchemaName 'codex-app-server-lead-profile').value
    $compat = Get-CodexAppServerCompatibilityIdentity -Profile $profile -ProfilePath ([string]$Harness.profile)
    $null = Write-TelephoneJsonCreateNew -Path $paths.intent -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-intent-v1'
        run_id = [string]$RunId
        thread_id = [string]$ThreadId
        worktree = [string]$Harness.worktree
        callback = [ordered]@{
            path = [string]$identity.path
            bytes = [int64]$identity.bytes
            sha256 = [string]$identity.sha256
        }
        wake_marker = (Get-CodexAppServerWakeMarker -RunId $RunId)
        profile_fingerprint = [string]$compat.profile_fingerprint
        codex_version = [string]$compat.codex_version
        executable_sha256 = [string]$compat.executable_sha256
        profile_sha256 = [string]$compat.profile_sha256
        codex_command = [string]$compat.codex_command
        service_tier = [string]$compat.service_tier
        baseline_turn_ids = @($Baseline)
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    return $paths
}

function Write-CasIntPlantedRun {
    param(
        $Paths, $Harness, [string]$RunId, [string]$ThreadId, [string]$Selected = '', [string]$Disposition = 'in_progress',
        [AllowEmptyCollection()][string[]]$Baseline = @(), [string]$Phase = '', [string]$FallbackRequired = '',
        [string]$TerminalTarget = '',
        [string]$QueueState = ''
    )
    $identity = Get-TelephoneFileIdentity -Path ([string]$Harness.prompt)
    $profile = (Read-TelephoneJson -Path ([string]$Harness.profile) -SchemaName 'codex-app-server-lead-profile').value
    $compat = Get-CodexAppServerCompatibilityIdentity -Profile $profile -ProfilePath ([string]$Harness.profile)
    $resolvedPhase = [string]$Phase
    if ([string]::IsNullOrWhiteSpace($resolvedPhase)) {
        if (Test-CodexAppServerTurnTerminalDisposition -Disposition $Disposition) { $resolvedPhase = 'terminal' }
        elseif ($Disposition -ceq 'fallback_required_cli') { $resolvedPhase = 'none' }
        elseif (-not [string]::IsNullOrWhiteSpace($Selected)) { $resolvedPhase = 'acknowledged' }
        else { $resolvedPhase = 'none' }
    }
    $fallback = [string]$FallbackRequired
    if ($Disposition -ceq 'fallback_required_cli' -and [string]::IsNullOrWhiteSpace($fallback)) { $fallback = 'cli' }
    $resolvedTarget = [string]$TerminalTarget
    if ([string]::IsNullOrWhiteSpace($resolvedTarget) -and ($resolvedPhase -ceq 'terminal' -or $resolvedPhase -ceq 'terminal_publishing')) {
        $resolvedTarget = [string]$Disposition
        if ($resolvedPhase -ceq 'terminal_publishing' -and -not (Test-CodexAppServerTurnTerminalDisposition -Disposition $Disposition)) {
            $resolvedTarget = 'completed'
        }
    }
    $runDoc = [ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-run-v1'
        run_id = [string]$RunId
        thread_id = [string]$ThreadId
        worktree = [string]$Harness.worktree
        callback = [ordered]@{
            path = [string]$identity.path
            bytes = [int64]$identity.bytes
            sha256 = [string]$identity.sha256
        }
        wake_marker = (Get-CodexAppServerWakeMarker -RunId $RunId)
        profile_fingerprint = [string]$compat.profile_fingerprint
        codex_version = [string]$compat.codex_version
        executable_sha256 = [string]$compat.executable_sha256
        profile_sha256 = [string]$compat.profile_sha256
        codex_command = [string]$compat.codex_command
        service_tier = [string]$compat.service_tier
        baseline_turn_ids = @($Baseline)
        selected_turn_id = [string]$Selected
        disposition = [string]$Disposition
        callback_write_phase = [string]$resolvedPhase
        terminal_target = [string]$resolvedTarget
        fallback_required = [string]$fallback
    }
    if (-not [string]::IsNullOrWhiteSpace($QueueState)) { $runDoc.queue_state = [string]$QueueState }
    $null = Write-TelephoneJsonCreateNew -Path $Paths.run -Value $runDoc
}

function Write-CasIntPlantedBound {
    param($Paths, [string]$ThreadId, [string]$TurnId, [string]$State = 'active')
    $null = Write-TelephoneJsonCreateNew -Path $Paths.bound_turn -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-bound-turn-v1'
        thread_id = [string]$ThreadId
        turn_id = [string]$TurnId
        state = [string]$State
        bound_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
}

function Write-CasIntPlantedAck {
    param($Paths, [string]$ThreadId, [string]$TurnId)
    $null = Write-TelephoneJsonCreateNew -Path $Paths.ack -Value (New-CodexAppServerWakeAck -SessionId $ThreadId -TurnId $TurnId)
}

function New-CasIntOfficialUserMessage {
    param([string]$Text, [string]$Id = 'um-1', [AllowNull()][object]$ClientId = $null, [AllowNull()][object]$Elements = $null)
    $textElements = @()
    if ($null -ne $Elements) { $textElements = @($Elements) }
    return [ordered]@{
        type = 'userMessage'
        id = [string]$Id
        clientId = $ClientId
        content = @(
            [ordered]@{
                type = 'text'
                text = [string]$Text
                text_elements = $textElements
            }
        )
    }
}

function Write-CasIntPlantedResult {
    param($Paths, [string]$RunId, [string]$State, [bool]$Started = $true, [bool]$Existing = $false, [string]$RunRoot = '')
    $root = [string]$RunRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [string]$Paths.run_root }
    $null = Write-TelephoneJsonCreateNew -Path $Paths.result -Value ([ordered]@{
        started = [bool]$Started
        existing = [bool]$Existing
        state = [string]$State
        run_id = [string]$RunId
        run_root = [string]$root
        fallback_required = ''
    })
}

function Write-CasIntPlantedRecovery {
    param($Paths, [string]$RunId, [string]$ThreadId, [string]$TurnId = '', [string]$Phase = 'acknowledged', [string]$RunRoot = '')
    $root = [string]$RunRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [string]$Paths.run_root }
    $null = Write-TelephoneJsonCreateNew -Path $Paths.recovery -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-recovery-v1'
        state = 'recovery_required'
        run_id = [string]$RunId
        run_root = [string]$root
        thread_id = [string]$ThreadId
        turn_id = [string]$TurnId
        callback_write_phase = [string]$Phase
        at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
}

function Write-CasIntPlantedFailure {
    param($Paths, [string]$RunId, [string]$ThreadId, [string]$TurnId = '', [string]$Phase = 'acknowledged', [string]$Disposition = 'recovery_required', [string]$Category = 'worker', [string]$Code = 'transport_lost_before_terminal', [string]$RunRoot = '')
    $root = [string]$RunRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [string]$Paths.run_root }
    $null = Write-TelephoneJsonCreateNew -Path $Paths.failure -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-failure-v1'
        category = [string]$Category
        code = [string]$Code
        run_id = [string]$RunId
        run_root = [string]$root
        thread_id = [string]$ThreadId
        turn_id = [string]$TurnId
        callback_write_phase = [string]$Phase
        disposition = [string]$Disposition
        at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
}

function Get-CasIntEventCount {
    param([string]$Path, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return 0 }
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ([string]$line -ceq $Name) { $n += 1 }
    }
    return $n
}

function Get-CasIntProcessEventCount {
    param([string]$Path, [string]$Method)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return 0 }
    $n = 0
    $pattern = '^process:\d+:' + [regex]::Escape([string]$Method) + '$'
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ([string]$line -match $pattern) { $n += 1 }
    }
    return $n
}

function Get-CasIntIntentBaseline {
    param($Harness, [string]$RunId)
    $path = Join-Path (Get-CasIntRunRoot -Harness $Harness -RunId $RunId) 'intent.json'
    if (-not [IO.File]::Exists($path)) { return [string[]]@() }
    $intent = (Read-TelephoneJson -Path $path -SchemaName 'codex-app-server-lead-intent').value
    return @(Get-CodexAppServerStringList -Value (Get-CodexAppServerDictObject -Dict $intent -Key 'baseline_turn_ids'))
}

function Wait-CasIntIntentBaselineContains {
    param($Harness, [string]$RunId, [string[]]$TurnIds, [int]$TimeoutMs = 20000)
    return (Wait-CasIntPredicate -TimeoutMs $TimeoutMs -Predicate {
        $have = @(Get-CasIntIntentBaseline -Harness $Harness -RunId $RunId)
        foreach ($id in @($TurnIds)) {
            if (@($have) -cnotcontains [string]$id) { return $false }
        }
        return $true
    })
}

function Complete-CasIntLauncherProcess {
    param($Proc, [int]$TimeoutMs = 90000)
    if ($null -eq $Proc -or $null -eq $Proc.process) {
        return [ordered]@{ exit_code = -1; stdout = ''; stderr = ''; json = $null }
    }
    try {
        if (-not $Proc.process.HasExited -and -not $Proc.process.WaitForExit($TimeoutMs)) {
            try { $Proc.process.Kill($true) } catch { }
            $null = $Proc.process.WaitForExit(2000)
        }
        $stdout = ''
        $stderr = ''
        try { $stdout = [string]$Proc.stdout.GetAwaiter().GetResult() } catch { $stdout = '' }
        try { $stderr = [string]$Proc.stderr.GetAwaiter().GetResult() } catch { $stderr = '' }
        $json = $null
        try { $json = ($stdout | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String } catch { $json = $null }
        return [ordered]@{
            exit_code = [int]$Proc.process.ExitCode
            stdout = $stdout
            stderr = $stderr
            json = $json
        }
    } finally {
        try { $Proc.process.Dispose() } catch { }
    }
}

function Stop-CasIntOwnerPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return }
    try {
        $rec = (Read-TelephoneJson -Path $Path).value
        if ([int]$rec.pid -eq [int]$PID) { return }
        if (Test-TelephoneOwnerAlive -Owner $rec) {
            try { Stop-Process -Id ([int]$rec.pid) -Force -ErrorAction SilentlyContinue } catch { }
        }
    } catch { }
}

function Stop-CasIntTelephoneJob {
    param([string]$JobRoot)
    if ([string]::IsNullOrWhiteSpace($JobRoot) -or -not [IO.Directory]::Exists($JobRoot)) { return }
    $jobPaths = Get-TelephoneJobPaths -JobRoot $JobRoot
    foreach ($name in @('command_owner', 'command_child', 'relay_owner')) {
        Stop-CasIntOwnerPath -Path ([string]$jobPaths[$name])
    }
    try {
        $stateRoot = Get-TelephoneStateRootFromJobRoot -JobRoot $JobRoot
        $dispatch = (Read-TelephoneJson -Path $jobPaths.dispatch).value
        $lead = Read-TelephoneLeadBinding -Lead $dispatch.lead
        $canonical = Get-TelephoneLeadCanonicalIdentity -Lead $lead
        $mailbox = Get-TelephoneLeadMailboxPaths -StateRoot $stateRoot -LeadKey ([string]$canonical.identity_sha256)
        Stop-CasIntOwnerPath -Path ([string]$mailbox.owner)
    } catch { }
}

function Stop-CasIntTelephoneState {
    param([string]$StateRoot)
    if ([string]::IsNullOrWhiteSpace($StateRoot) -or -not [IO.Directory]::Exists($StateRoot)) { return }
    $jobsRoot = Join-Path $StateRoot 'jobs'
    if ([IO.Directory]::Exists($jobsRoot)) {
        foreach ($dir in @([IO.Directory]::GetDirectories($jobsRoot))) {
            Stop-CasIntTelephoneJob -JobRoot $dir
        }
    }
    $leadsRoot = Join-Path $StateRoot 'leads'
    if ([IO.Directory]::Exists($leadsRoot)) {
        foreach ($dir in @([IO.Directory]::GetDirectories($leadsRoot))) {
            Stop-CasIntOwnerPath -Path (Join-Path $dir 'owner.json')
        }
    }
}

function Get-CasIntFanInLeadKey {
    param($Binding)
    $canonical = Get-TelephoneLeadCanonicalIdentity -Lead $Binding
    return [string]$canonical.identity_sha256
}

function Get-CasIntHoldRoutePath {
    param($Harness)
    $path = Join-Path $Harness.root 'hold-route.ps1'
    if (-not [IO.File]::Exists($path)) {
        $text = @'
# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CounterPath,
    [Parameter(Mandatory = $true)][string]$HoldPath,
    [ValidateRange(0, 30000)][int]$DelayMilliseconds = 0,
    [string]$FinalText = 'MOCK_ROUTE_DONE',
    [int]$ExitCode = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
while (-not [IO.File]::Exists($HoldPath)) { Start-Sleep -Milliseconds 50 }
if ($DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds }
$parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($CounterPath))
if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::AppendAllText($CounterPath, "1`n", [Text.UTF8Encoding]::new($false))
[ordered]@{ success = ($ExitCode -eq 0); final_text = $FinalText } | ConvertTo-Json -Compress
exit $ExitCode
'@
        [IO.File]::WriteAllText($path, $text.TrimStart() + "`n", [Text.UTF8Encoding]::new($false))
    }
    return $path
}

function New-CasIntFanInRequest {
    param(
        $Harness,
        [string]$MockRoute,
        $Binding,
        [string]$BatchId,
        [string[]]$PackageIds,
        [string]$PackageId,
        [int]$N,
        [int]$ExitCode = 0,
        [string]$CounterPath,
        [string]$RetryOf = '',
        [string]$HoldPath = '',
        [string]$TelState
    )
    $jobId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
    $requestPath = Join-Path $Harness.root ('request-' + $PackageId + '-' + $jobId + '.json')
    $batch = [ordered]@{
        protocol_version = 'telephone-line-batch-v1'
        batch_id = [string]$BatchId
        package_id = [string]$PackageId
        package_ids = @($PackageIds)
        n = [int]$N
    }
    if (-not [string]::IsNullOrWhiteSpace($RetryOf)) { $batch['retry_of'] = [string]$RetryOf }
    $routePath = $MockRoute
    $arguments = [Collections.Generic.List[string]]::new()
    [void]$arguments.Add('-NoLogo'); [void]$arguments.Add('-NoProfile'); [void]$arguments.Add('-NonInteractive')
    [void]$arguments.Add('-ExecutionPolicy'); [void]$arguments.Add('Bypass'); [void]$arguments.Add('-File')
    if (-not [string]::IsNullOrWhiteSpace($HoldPath)) {
        $routePath = Get-CasIntHoldRoutePath -Harness $Harness
        [void]$arguments.Add($routePath)
        [void]$arguments.Add('-CounterPath'); [void]$arguments.Add($CounterPath)
        [void]$arguments.Add('-HoldPath'); [void]$arguments.Add($HoldPath)
        [void]$arguments.Add('-DelayMilliseconds'); [void]$arguments.Add('0')
        [void]$arguments.Add('-FinalText'); [void]$arguments.Add('DONE-' + $PackageId)
        [void]$arguments.Add('-ExitCode'); [void]$arguments.Add([string]$ExitCode)
    } else {
        [void]$arguments.Add($routePath)
        [void]$arguments.Add('-CounterPath'); [void]$arguments.Add($CounterPath)
        [void]$arguments.Add('-DelayMilliseconds'); [void]$arguments.Add('0')
        [void]$arguments.Add('-FinalText'); [void]$arguments.Add('DONE-' + $PackageId)
        [void]$arguments.Add('-ExitCode'); [void]$arguments.Add([string]$ExitCode)
    }
    $null = Write-TelephoneJsonCreateNew -Path $requestPath -Value ([ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = $jobId
        project = 'batch-fan-in'
        stage = 'SIMULATION'
        role = 'execution'
        route = 'mock-route'
        summary = ('bounded package ' + $PackageId)
        lead = $Binding
        batch = $batch
        command = [ordered]@{
            executable = $pwsh
            working_directory = [string]$Harness.root
            arguments = @($arguments)
        }
    })
    return [ordered]@{
        package_id = $PackageId
        line_job_id = $jobId
        job_root = Join-Path $TelState ('jobs\' + $jobId)
        counter_path = $CounterPath
        request_path = $requestPath
        hold_path = $HoldPath
    }
}

function Start-CasIntFanInJob {
    param(
        $Harness,
        [string]$TelState,
        [string]$Starter,
        [string]$MockRoute,
        $Binding,
        [string]$BatchId,
        [string[]]$PackageIds,
        [string]$PackageId,
        [int]$N,
        [int]$ExitCode = 0,
        [string]$CounterPath,
        [string]$RetryOf = '',
        [switch]$ForceStartFailed,
        [string]$HoldPath = ''
    )
    $prepared = New-CasIntFanInRequest -Harness $Harness -MockRoute $MockRoute -Binding $Binding -BatchId $BatchId -PackageIds $PackageIds -PackageId $PackageId -N $N -ExitCode $ExitCode -CounterPath $CounterPath -RetryOf $RetryOf -HoldPath $HoldPath -TelState $TelState
    $previousForce = [Environment]::GetEnvironmentVariable('TELEPHONE_TEST_FORCE_COMMAND_START_FAILED', 'Process')
    try {
        if ($ForceStartFailed) {
            [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_FORCE_COMMAND_START_FAILED', $PackageId, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_FORCE_COMMAND_START_FAILED', $null, 'Process')
        }
        $started = Invoke-CasIntScript -ScriptPath $Starter -Arguments @('-RequestFile', [string]$prepared.request_path, '-StateRoot', $TelState)
        Assert-CasInt ($started.exit_code -eq 0) ("Fan-in start $PackageId failed: $($started.stderr) $($started.stdout)")
    } finally {
        [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_FORCE_COMMAND_START_FAILED', $previousForce, 'Process')
    }
    $prepared['started'] = $started
    return $prepared
}

function Start-CasIntFanInJobsNearSimultaneous {
    param(
        $Harness,
        [string]$TelState,
        [string]$Starter,
        [string]$MockRoute,
        $Binding,
        [string]$BatchId,
        [string[]]$PackageIds,
        [object[]]$Specs
    )
    $prepared = [Collections.Generic.List[object]]::new()
    foreach ($spec in @($Specs)) {
        $holdPath = ''
        if ($spec.Contains('hold_path')) { $holdPath = [string]$spec.hold_path }
        $row = New-CasIntFanInRequest -Harness $Harness -MockRoute $MockRoute -Binding $Binding -BatchId $BatchId -PackageIds $PackageIds -PackageId ([string]$spec.id) -N $PackageIds.Count -ExitCode ([int]$spec.exit) -CounterPath ([string]$spec.counter) -HoldPath $holdPath -TelState $TelState
        $row['force_start_failed'] = [bool]$spec.fail
        $prepared.Add($row)
    }
    $handles = [Collections.Generic.List[object]]::new()
    $startedAtUtc = [ordered]@{}
    foreach ($row in $prepared) {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $pwsh
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.CreateNoWindow = $true
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Starter, '-RequestFile', [string]$row.request_path, '-StateRoot', $TelState)) {
            [void]$info.ArgumentList.Add([string]$argument)
        }
        if ([bool]$row.force_start_failed) {
            $info.Environment['TELEPHONE_TEST_FORCE_COMMAND_START_FAILED'] = [string]$row.package_id
        } else {
            $info.Environment['TELEPHONE_TEST_FORCE_COMMAND_START_FAILED'] = ''
        }
        $process = [Diagnostics.Process]::Start($info)
        Assert-CasInt ($null -ne $process) ("Near-simultaneous start $($row.package_id) did not create an OS process.")
        $stamp = $null
        try {
            $process.Refresh()
            $stamp = [DateTimeOffset]::new($process.StartTime.ToUniversalTime())
        } catch { $stamp = $null }
        if ($null -eq $stamp) {
            $live = Get-Process -Id ([int]$process.Id) -ErrorAction SilentlyContinue
            if ($null -ne $live) {
                try { $stamp = [DateTimeOffset]::new($live.StartTime.ToUniversalTime()) } finally { $live.Dispose() }
            }
        }
        Assert-CasInt ($null -ne $stamp -and [int64]$stamp.ToUnixTimeMilliseconds() -gt 0) ("Starter $($row.package_id) missing OS/process start timestamp.")
        $startedAtUtc[[string]$row.package_id] = $stamp.ToString('o')
        $handles.Add([ordered]@{ row = $row; process = $process; started_at_utc = $stamp; stdout = $process.StandardOutput.ReadToEndAsync(); stderr = $process.StandardError.ReadToEndAsync() })
    }
    Assert-CasInt ($startedAtUtc.Count -eq 6) ("Six-route launch did not capture six OS start timestamps: $($startedAtUtc.Count)")
    $startMs = [Collections.Generic.List[int64]]::new()
    foreach ($handle in $handles) {
        [void]$startMs.Add([int64]$handle.started_at_utc.ToUnixTimeMilliseconds())
    }
    $minMs = ($startMs | Measure-Object -Minimum).Minimum
    $maxMs = ($startMs | Measure-Object -Maximum).Maximum
    $spanMs = [int]($maxMs - $minMs)
    $jobs = [ordered]@{}
    foreach ($handle in $handles) {
        $null = $handle.process.WaitForExit(60000)
        $stdout = [string]$handle.stdout.GetAwaiter().GetResult()
        $stderr = [string]$handle.stderr.GetAwaiter().GetResult()
        Assert-CasInt ($handle.process.HasExited -and [int]$handle.process.ExitCode -eq 0) ("Near-simultaneous start $($handle.row.package_id) failed: $stderr $stdout")
        $handle.process.Dispose()
        $jobs[[string]$handle.row.package_id] = $handle.row
    }
    return [ordered]@{ jobs = $jobs; launch_span_ms = $spanMs; launch_started_at_utc = $startedAtUtc }
}

function Get-CasIntTelephoneLiveIdentities {
    param([string]$StateRoot)
    $live = [Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($StateRoot) -or -not [IO.Directory]::Exists($StateRoot)) { return @() }
    $files = [Collections.Generic.List[string]]::new()
    $jobsRoot = Join-Path $StateRoot 'jobs'
    if ([IO.Directory]::Exists($jobsRoot)) {
        foreach ($dir in @([IO.Directory]::GetDirectories($jobsRoot))) {
            $paths = Get-TelephoneJobPaths -JobRoot $dir
            foreach ($name in @('command_owner', 'command_child', 'relay_owner')) {
                if ([IO.File]::Exists([string]$paths[$name])) { [void]$files.Add([string]$paths[$name]) }
            }
        }
    }
    $leadsRoot = Join-Path $StateRoot 'leads'
    if ([IO.Directory]::Exists($leadsRoot)) {
        foreach ($dir in @([IO.Directory]::GetDirectories($leadsRoot))) {
            $ownerPath = Join-Path $dir 'owner.json'
            if ([IO.File]::Exists($ownerPath)) { [void]$files.Add($ownerPath) }
        }
    }
    foreach ($path in @($files)) {
        try {
            $owner = (Read-TelephoneJson -Path $path).value
            if ([int]$owner.pid -eq [int]$PID) { continue }
            if (Test-TelephoneOwnerAlive -Owner $owner) {
                $live.Add([ordered]@{ path = $path; pid = [int]$owner.pid; start_time_utc_ticks = [int64]$owner.start_time_utc_ticks })
            }
        } catch { }
    }
    return @($live)
}

function Get-CasIntTelephoneHeldLocks {
    param([string]$StateRoot)
    $held = [Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($StateRoot) -or -not [IO.Directory]::Exists($StateRoot)) { return @() }
    foreach ($lockFile in @([IO.Directory]::GetFiles($StateRoot, '*.lock', [IO.SearchOption]::AllDirectories))) {
        $stream = $null
        try {
            $stream = [IO.FileStream]::new($lockFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            [void]$held.Add($lockFile)
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    return @($held)
}

function Assert-CasIntTelephoneResidueClear {
    param([string]$StateRoot, [string]$Label)
    Stop-CasIntTelephoneState -StateRoot $StateRoot
    Start-Sleep -Milliseconds 250
    $live = @(Get-CasIntTelephoneLiveIdentities -StateRoot $StateRoot)
    $held = @(Get-CasIntTelephoneHeldLocks -StateRoot $StateRoot)
    Assert-CasInt ($live.Count -eq 0) ("$Label left live PID+start-ticks identities: $(($live | ForEach-Object { [string]$_.pid + ':' + [string]$_.start_time_utc_ticks }) -join ',')")
    Assert-CasInt ($held.Count -eq 0) ("$Label left held locks: $($held -join ',')")
}

function Copy-CasIntLeadBinding {
    param($Binding)
    $text = ($Binding | ConvertTo-Json -Depth 32)
    return ($text | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String)
}

function Set-CasIntLeadBindingProfilePath {
    param($Binding, [string]$ProfilePath)
    $args = [Collections.Generic.List[string]]::new()
    foreach ($item in @($Binding.launcher.arguments)) { [void]$args.Add([string]$item) }
    $found = $false
    for ($i = 0; $i -lt ($args.Count - 1); $i++) {
        if ([string]$args[$i] -ceq '-ProfilePath') {
            $args[$i + 1] = [string]$ProfilePath
            $found = $true
            break
        }
    }
    Assert-CasInt $found 'Lead binding omitted -ProfilePath.'
    $Binding.launcher.arguments = @($args)
    return $Binding
}

function Get-CasIntFanInMailbox {
    param([string]$TelState, [string]$LeadKey)
    return (Get-TelephoneLeadMailboxPaths -StateRoot $TelState -LeadKey $LeadKey)
}

function Wait-CasIntFanInCounted {
    param($Mailbox, [string]$BatchId, [int]$Counted, [int]$TimeoutMs = 40000)
    $batchPaths = Get-TelephoneBatchPaths -MailboxPaths $Mailbox -BatchId $BatchId
    return (Wait-CasIntPredicate -TimeoutMs $TimeoutMs -Predicate {
        if (-not [IO.File]::Exists($batchPaths.collection)) { return $false }
        try {
            $doc = (Read-TelephoneJson -Path $batchPaths.collection).value
            return ([int]$doc.counted -eq $Counted -and [int]$doc.n -ge $Counted)
        } catch { return $false }
    })
}

function Get-CasIntCounterCount {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return 0 }
    return @([IO.File]::ReadAllLines($Path) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
}

function Wait-CasIntFanInJobFirstComplete {
    param($Job, [string]$CounterPath, [int]$TimeoutMs = 40000)
    $paths = Get-TelephoneJobPaths -JobRoot ([string]$Job.job_root)
    return (Wait-CasIntPredicate -TimeoutMs $TimeoutMs -Predicate {
        if ((Get-CasIntCounterCount -Path $CounterPath) -lt 1) { return $false }
        if (-not [IO.File]::Exists([string]$paths.receipt)) { return $false }
        if (-not [IO.File]::Exists([string]$paths.command_child_exit)) { return $false }
        return $true
    })
}

function Test-CasIntFanInJobCommandAlive {
    param($Job)
    $paths = Get-TelephoneJobPaths -JobRoot ([string]$Job.job_root)
    foreach ($name in @('command_owner', 'command_child')) {
        $path = [string]$paths[$name]
        if (-not [IO.File]::Exists($path)) { continue }
        try {
            if (Test-TelephoneOwnerAlive -Owner ((Read-TelephoneJson -Path $path).value)) { return $true }
        } catch { }
    }
    return $false
}

function Wait-CasIntPredicate {
    param([scriptblock]$Predicate, [int]$TimeoutMs = 30000)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $ok = $false
        try { $ok = [bool](& $Predicate) } catch { $ok = $false }
        if ($ok) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Get-CasIntSnapshot {
    param([string[]]$Roots)
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($root in @($Roots)) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not [IO.Directory]::Exists($root)) { continue }
        foreach ($item in [IO.Directory]::GetFileSystemEntries($root, '*', [IO.SearchOption]::AllDirectories)) {
            $rows.Add([string]$item)
        }
    }
    $rows.Sort()
    return [string[]]@($rows)
}

function Get-CasIntTreeFingerprint {
    param([string]$Root)
    $rows = [Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Root) -or -not [IO.Directory]::Exists($Root)) {
        return [string]::Join("`n", @($rows))
    }
    $files = @([IO.Directory]::GetFiles($Root, '*', [IO.SearchOption]::AllDirectories))
    [Array]::Sort($files, [StringComparer]::OrdinalIgnoreCase)
    $sha = [Security.Cryptography.SHA256]::Create()
    foreach ($file in $files) {
        $name = [IO.Path]::GetFileName($file)
        if ($name -ceq 'gate.lock') { continue }
        $rel = [IO.Path]::GetRelativePath($Root, $file).Replace('\', '/')
        $bytes = [IO.File]::ReadAllBytes($file)
        $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
        $rows.Add(($rel + '|' + [string]$bytes.Length + '|' + $hash))
    }
    return [string]::Join("`n", @($rows))
}

function Get-CasIntFileFingerprint {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return '' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    return ([string]$bytes.Length + '|' + $hash)
}

function Write-CasIntHistoryWorld {
    param(
        $Harness,
        [string]$ThreadId,
        [string]$RunId,
        [string]$CurrentPhase,
        [string]$CurrentDisposition,
        [string]$TurnState,
        [bool]$PlantRecovery = $false,
        [string]$RecoveryPhase = '',
        [bool]$PlantFailure = $false,
        [string]$FailurePhase = '',
        [string]$FailureDisposition = '',
        [string]$FailureCode = '',
        [bool]$PlantResult = $false,
        [string]$ResultState = ''
    )
    $paths = Write-CasIntPlantedIntent -Harness $Harness -RunId $RunId -ThreadId $ThreadId
    $turn = 'turn-hist'
    $selected = ''
    $boundState = 'active'
    $fallback = ''
    $target = ''
    $hasRun = -not [string]::IsNullOrEmpty($CurrentDisposition)
    if ($CurrentDisposition -ceq 'fallback_required_cli') { $fallback = 'cli' }
    if ($TurnState -cin @('acked', 'publishing', 'terminal')) { $selected = $turn }
    if ($CurrentPhase -ceq 'terminal_publishing') { $target = 'completed' }
    if ($CurrentPhase -ceq 'terminal') {
        $target = [string]$CurrentDisposition
        $boundState = [string]$CurrentDisposition
    } elseif ($CurrentDisposition -ceq 'recovery_required' -and $TurnState -ceq 'acked') {
        $boundState = 'recovery_required'
    }
    if ($hasRun) {
        Write-CasIntPlantedRun -Paths $paths -Harness $Harness -RunId $RunId -ThreadId $ThreadId -Selected $selected -Disposition $CurrentDisposition -Phase $CurrentPhase -FallbackRequired $fallback -TerminalTarget $target
        if ($TurnState -cin @('bound', 'acked', 'publishing', 'terminal')) {
            Write-CasIntPlantedBound -Paths $paths -ThreadId $ThreadId -TurnId $turn -State $boundState
        }
        if ($TurnState -cin @('acked', 'publishing', 'terminal')) {
            Write-CasIntPlantedAck -Paths $paths -ThreadId $ThreadId -TurnId $turn
        }
        if ($TurnState -ceq 'terminal') {
            $null = Write-TelephoneTextCreateNew -Path $paths.final -Text ($CurrentDisposition + "`n")
        }
    }
    $recordTurn = ''
    if ($TurnState -cne 'prebind') { $recordTurn = $turn }
    if ($PlantRecovery) {
        $recPhase = [string]$RecoveryPhase
        if ([string]::IsNullOrWhiteSpace($recPhase)) { $recPhase = [string]$CurrentPhase }
        Write-CasIntPlantedRecovery -Paths $paths -RunId $RunId -ThreadId $ThreadId -TurnId $recordTurn -Phase $recPhase
    }
    if ($PlantFailure) {
        $failPhase = [string]$FailurePhase
        if ([string]::IsNullOrWhiteSpace($failPhase)) { $failPhase = [string]$CurrentPhase }
        $failDisp = [string]$FailureDisposition
        if ([string]::IsNullOrWhiteSpace($failDisp)) { $failDisp = [string]$CurrentDisposition }
        $failCode = [string]$FailureCode
        if ([string]::IsNullOrWhiteSpace($failCode)) { $failCode = 'worker_failed' }
        Write-CasIntPlantedFailure -Paths $paths -RunId $RunId -ThreadId $ThreadId -TurnId $recordTurn -Phase $failPhase -Disposition $failDisp -Code $failCode
    }
    if ($PlantResult) {
        $state = [string]$ResultState
        if ([string]::IsNullOrWhiteSpace($state)) { $state = [string]$CurrentDisposition }
        Write-CasIntPlantedResult -Paths $paths -RunId $RunId -State $state
    }
    return $paths
}

function Invoke-CasIntDurableChain {
    param($Paths, $Harness, [string]$RunId, [string]$ThreadId)
    Assert-CodexAppServerDurableChain -Paths $Paths -RunId $RunId -ThreadId $ThreadId -Worktree ([string]$Harness.worktree) -CallbackIdentity (Get-TelephoneFileIdentity -Path ([string]$Harness.prompt)) -Marker (Get-CodexAppServerWakeMarker -RunId $RunId) -Profile ((Read-TelephoneJson -Path ([string]$Harness.profile) -SchemaName 'codex-app-server-lead-profile').value) -ProfilePath ([string]$Harness.profile)
}

function Assert-CasIntHistoryRejected {
    param($Harness, [string]$ThreadId, $Paths, [string]$Name)
    $storePath = Join-Path $Harness.state 'app-server-store.json'
    $beforeRoot = Get-CasIntTreeFingerprint -Root ([string]$Paths.run_root)
    $beforeStore = Get-CasIntFileFingerprint -Path $storePath
    $beforeTurns = @(Get-CasIntStoreTurns -Harness $Harness -ThreadId $ThreadId).Count
    $beforeResult = ''
    if ([IO.File]::Exists($Paths.result)) { $beforeResult = [IO.File]::ReadAllText($Paths.result) }
    $beforeRecovery = ''
    if ([IO.File]::Exists($Paths.recovery)) { $beforeRecovery = [IO.File]::ReadAllText($Paths.recovery) }
    $beforeFailure = ''
    if ([IO.File]::Exists($Paths.failure)) { $beforeFailure = [IO.File]::ReadAllText($Paths.failure) }
    $hadOwner = [IO.File]::Exists($Paths.owner)
    $hadChild = [IO.File]::Exists($Paths.child)
    $hadProfileInRun = [IO.File]::Exists((Join-Path $Paths.run_root 'profile.json'))
    $launch = Invoke-CasIntLauncher -Harness $Harness -ThreadId $ThreadId -RunId ([IO.Path]::GetFileName([string]$Paths.run_root))
    Assert-CasInt ($launch.exit_code -ne 0) ("History negative $Name was accepted.")
    Assert-CasInt ((Get-CasIntTreeFingerprint -Root ([string]$Paths.run_root)) -ceq $beforeRoot) ("History negative $Name mutated the run root.")
    Assert-CasInt ((Get-CasIntFileFingerprint -Path $storePath) -ceq $beforeStore) ("History negative $Name mutated mock provider store.")
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $Harness -ThreadId $ThreadId).Count -eq $beforeTurns) ("History negative $Name started a turn.")
    if ($beforeResult -ne '') {
        Assert-CasInt ([IO.File]::Exists($Paths.result)) ("History negative $Name deleted launcher-result.json.")
        Assert-CasInt ([IO.File]::ReadAllText($Paths.result) -ceq $beforeResult) ("History negative $Name mutated launcher-result.json.")
    } else {
        Assert-CasInt (-not [IO.File]::Exists($Paths.result)) ("History negative $Name wrote launcher-result.json.")
    }
    if ($beforeRecovery -ne '') {
        Assert-CasInt ([IO.File]::ReadAllText($Paths.recovery) -ceq $beforeRecovery) ("History negative $Name mutated recovery.json.")
    } else {
        Assert-CasInt (-not [IO.File]::Exists($Paths.recovery)) ("History negative $Name wrote recovery.json.")
    }
    if ($beforeFailure -ne '') {
        Assert-CasInt ([IO.File]::ReadAllText($Paths.failure) -ceq $beforeFailure) ("History negative $Name mutated failure.json.")
    } else {
        Assert-CasInt (-not [IO.File]::Exists($Paths.failure)) ("History negative $Name wrote failure.json.")
    }
    if (-not $hadChild) {
        Assert-CasInt (-not [IO.File]::Exists($Paths.child)) ("History negative $Name created child.json.")
    }
    if (-not $hadOwner) {
        Assert-CasInt (-not [IO.File]::Exists($Paths.owner)) ("History negative $Name created owner.json.")
    }
    if (-not $hadProfileInRun) {
        Assert-CasInt (-not [IO.File]::Exists((Join-Path $Paths.run_root 'profile.json'))) ("History negative $Name created a run-local profile.")
    }
    return $launch
}

function Get-CasIntHistoryKey {
    param($Row)
    return (Get-CodexAppServerDurableHistoryKey `
        -Kind ([string]$Row.kind) `
        -Code ([string]$Row.code) `
        -Category ([string]$Row.category) `
        -RecordedPhase ([string]$Row.recorded_phase) `
        -RecordedDisposition ([string]$Row.recorded_disposition) `
        -RecordedState ([string]$Row.recorded_state) `
        -CurrentPhase ([string]$Row.current_phase) `
        -CurrentDisposition ([string]$Row.current_disposition) `
        -TurnState ([string]$Row.turn_state))
}

function Add-CasIntTupleItems {
    param($Node, $Target)
    if ($null -eq $Node) { return }
    if ($Node -is [Collections.IDictionary]) {
        if ((Get-CodexAppServerDictString -Dict $Node -Key 'kind') -ne '') { $Target.Add($Node) }
        return
    }
    if ($Node -is [Collections.IEnumerable] -and $Node -isnot [string] -and $Node -isnot [byte[]]) {
        foreach ($child in $Node) { Add-CasIntTupleItems -Node $child -Target $Target }
    }
}

function Get-CasIntCapturedHistoryTuples {
    param($Paths)
    $out = [Collections.Generic.List[object]]::new()
    $raw = $null
    try { $raw = Get-CodexAppServerDurableHistoryTuplesFromDisk -Paths $Paths } catch { $raw = $null }
    if ($raw -is [Collections.IDictionary]) {
        if ((Get-CodexAppServerDictString -Dict $raw -Key 'kind') -ne '') { $out.Add($raw) }
        return ,$out
    }
    if ($raw -is [Collections.IEnumerable] -and $raw -isnot [string]) {
        foreach ($item in $raw) {
            if ($item -is [Collections.IDictionary] -and (Get-CodexAppServerDictString -Dict $item -Key 'kind') -ne '') {
                $out.Add($item)
            }
        }
    }
    return ,$out
}

function Add-CasIntObservedTuple {
    param(
        $Tuple,
        [string]$Scenario,
        [string]$Writer,
        [string]$Boundary = '',
        [string]$CallSite = '',
        $ObservedKeys,
        $ObservedRows
    )
    if ($null -eq $Tuple -or $Tuple -isnot [Collections.IDictionary]) { return }
    if ((Get-CodexAppServerDictString -Dict $Tuple -Key 'kind') -eq '') { return }
    $key = Get-CasIntHistoryKey -Row $Tuple
    if ($ObservedKeys.Contains($key)) {
        $first = $null
        foreach ($row in @($script:f02TupleProvenance)) {
            if ([string]$row.key -ceq [string]$key) { $first = $row; break }
        }
        $second = [ordered]@{
            scenario = [string]$Scenario
            writer = [string]$Writer
            boundary = [string]$Boundary
            call_site = [string]$CallSite
            kind = [string]$Tuple.kind
            code = [string]$Tuple.code
            recorded_phase = [string]$Tuple.recorded_phase
            recorded_disposition = [string]$Tuple.recorded_disposition
            recorded_state = [string]$Tuple.recorded_state
            current_phase = [string]$Tuple.current_phase
            current_disposition = [string]$Tuple.current_disposition
            turn_state = [string]$Tuple.turn_state
            key = [string]$key
        }
        $script:f02DuplicateRows += 1
        $script:f02DuplicateProvenance.Add([ordered]@{
            key = [string]$key
            first = $first
            second = $second
        })
        return
    }
    [void]$ObservedKeys.Add($key)
    $ObservedRows.Add($Tuple)
    $script:f02TupleProvenance.Add([ordered]@{
        scenario = [string]$Scenario
        writer = [string]$Writer
        boundary = [string]$Boundary
        call_site = [string]$CallSite
        kind = [string]$Tuple.kind
        code = [string]$Tuple.code
        recorded_phase = [string]$Tuple.recorded_phase
        recorded_disposition = [string]$Tuple.recorded_disposition
        recorded_state = [string]$Tuple.recorded_state
        current_phase = [string]$Tuple.current_phase
        current_disposition = [string]$Tuple.current_disposition
        turn_state = [string]$Tuple.turn_state
        key = [string]$key
    })
    if ([string]$Tuple.kind -ceq 'recovery') { $script:f02LegalRecoveryHistory += 1 }
    else { $script:f02LegalFailureHistory += 1 }
}

function Get-CasIntOptionalFileBytes {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return $null }
    return [IO.File]::ReadAllBytes($Path)
}

function Test-CasIntBytesChanged {
    param($Before, $After)
    if ($null -eq $Before -and $null -eq $After) { return $false }
    if ($null -eq $Before -or $null -eq $After) { return $true }
    $left = [byte[]]$Before
    $right = [byte[]]$After
    if ($left.Length -ne $right.Length) { return $true }
    for ($i = 0; $i -lt $left.Length; $i++) {
        if ([int]$left[$i] -ne [int]$right[$i]) { return $true }
    }
    return $false
}

function Get-CasIntDeclarationPathForTuple {
    param($Paths, $Tuple)
    if ((Get-CodexAppServerDictString -Dict $Tuple -Key 'kind') -ceq 'recovery') {
        return [string]$Paths.recovery
    }
    return [string]$Paths.failure
}

function Get-CasIntPlantedEvidence {
    param($Paths)
    $keySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $keyBytes = @{}
    $captured = Get-CasIntCapturedHistoryTuples -Paths $Paths
    $items = [Collections.Generic.List[object]]::new()
    Add-CasIntTupleItems -Node $captured -Target $items
    foreach ($tuple in $items) {
        $key = Get-CasIntHistoryKey -Row $tuple
        [void]$keySet.Add($key)
        $path = Get-CasIntDeclarationPathForTuple -Paths $Paths -Tuple $tuple
        $keyBytes[$key] = Get-CasIntOptionalFileBytes -Path $path
    }
    return [ordered]@{
        key_set = $keySet
        key_bytes = $keyBytes
        recovery_bytes = (Get-CasIntOptionalFileBytes -Path ([string]$Paths.recovery))
        failure_bytes = (Get-CasIntOptionalFileBytes -Path ([string]$Paths.failure))
    }
}

function Get-CasIntAttributedTuples {
    param($Paths, $BeforeEvidence)
    $out = [Collections.Generic.List[object]]::new()
    $captured = Get-CasIntCapturedHistoryTuples -Paths $Paths
    $items = [Collections.Generic.List[object]]::new()
    Add-CasIntTupleItems -Node $captured -Target $items
    foreach ($tuple in $items) {
        $key = Get-CasIntHistoryKey -Row $tuple
        $path = Get-CasIntDeclarationPathForTuple -Paths $Paths -Tuple $tuple
        $afterBytes = Get-CasIntOptionalFileBytes -Path $path
        if ($null -ne $BeforeEvidence -and $BeforeEvidence.key_set.Contains($key)) {
            $beforeBytes = $null
            if ($BeforeEvidence.key_bytes.Contains($key)) { $beforeBytes = $BeforeEvidence.key_bytes[$key] }
            if (-not (Test-CasIntBytesChanged -Before $beforeBytes -After $afterBytes)) {
                continue
            }
        }
        $out.Add($tuple)
    }
    return ,$out
}

function Invoke-CasIntDirectWriterProcess {
    param(
        [string]$StateRoot,
        [string]$RunId,
        [string]$ThreadId,
        [string]$Invoke,
        [string]$Code = 'worker_failed',
        [string]$CrashAt = '',
        [string]$PublishCrashAt = '',
        [string]$CommitTurn = 'turn-hist'
    )
    $dir = Join-Path $TestRoot 'direct-writers'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $scriptPath = Join-Path $dir ('writer-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    $common = (Join-Path $repoRoot 'src\lead-side\codex-app-server\CodexAppServerLead.Common.ps1').Replace('\', '\\')
    $stateEsc = $StateRoot.Replace('\', '\\')
    $crashEsc = ([string]$CrashAt).Replace("'", "''")
    $publishEsc = ([string]$PublishCrashAt).Replace("'", "''")
    $codeEsc = ([string]$Code).Replace("'", "''")
    $turnEsc = ([string]$CommitTurn).Replace("'", "''")
    $invokeEsc = ([string]$Invoke).Replace("'", "''")
    $runEsc = ([string]$RunId).Replace("'", "''")
    $threadEsc = ([string]$ThreadId).Replace("'", "''")
    $body = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
if ('$crashEsc' -ne '') { `$env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = '$crashEsc' }
if ('$publishEsc' -ne '') { `$env:TELEPHONE_TEST_APP_SERVER_PUBLISH_CRASH_AT = '$publishEsc' }
. '$common'
`$paths = Get-CodexAppServerRunPaths -StateRoot '$stateEsc' -RunId '$runEsc'
if ('$invokeEsc' -ceq 'failure-writer') {
    Write-CodexAppServerFailureRecord -Paths `$paths -Category 'worker' -Code '$codeEsc' -ThreadId '$threadEsc'
} elseif ('$invokeEsc' -ceq 'recovery-writer') {
    Write-CodexAppServerRecoveryRequired -Paths `$paths -ThreadId '$threadEsc'
} elseif ('$invokeEsc' -ceq 'recovery-commit') {
    Complete-CodexAppServerRecoveryCommit -Paths `$paths -ThreadId '$threadEsc' -TurnId '$turnEsc'
}
"@
    [IO.File]::WriteAllText($scriptPath, $body, [Text.UTF8Encoding]::new($false))
    try {
        return Invoke-CasIntScript -ScriptPath $scriptPath -Arguments @() -TimeoutMs 20000
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function New-CasIntAckDeathWorld {
    param([string]$Name, [string]$RunId)
    $attempt = 0
    $lastFail = ''
    while ($attempt -lt 2) {
        $attempt += 1
        Clear-CasIntTestEnv
        $harnessName = $Name
        if ($attempt -gt 1) { $harnessName = ($Name + '-retry') }
        $harness = New-CasIntHarness -Name $harnessName
        $null = Invoke-CasIntProfile -Harness $harness
        $built = Invoke-CasIntBuilder -Harness $harness
        $threadId = [string]$built.json.thread_id
        $hold = Join-Path $harness.root 'hold-completed'
        $eventLog = Join-Path $harness.root 'events.log'
        $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $hold
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLog
        $first = Invoke-CasIntLauncher -Harness $harness -ThreadId $threadId -RunId $RunId
        if ($first.exit_code -eq 0) {
            $bound = Get-CasIntBoundJson -Harness $harness -RunId $RunId
            $paths = Get-CodexAppServerRunPaths -StateRoot ([string]$harness.state) -RunId $RunId
            $childPath = Join-Path $paths.run_root 'child.json'
            Assert-CasInt (Wait-CasIntPath -Path $childPath) 'Ack-death child identity is missing.'
            $child = (Read-TelephoneJson -Path $childPath).value
            try { Stop-Process -Id ([int]$child.pid) -Force -ErrorAction SilentlyContinue } catch { }
            $deadBy = [DateTimeOffset]::UtcNow.AddSeconds(20)
            while ((Test-CasIntOwnerAlive -Harness $harness -RunId $RunId) -and [DateTimeOffset]::UtcNow -lt $deadBy) { Start-Sleep -Milliseconds 50 }
            Assert-CasInt (-not (Test-CasIntOwnerAlive -Harness $harness -RunId $RunId)) 'Ack-death left a live worker.'
            $run = Get-CasIntRunJson -Harness $harness -RunId $RunId
            Assert-CasInt ([string]$run.disposition -ceq 'recovery_required') 'Ack-death did not persist recovery_required.'
            Assert-CasInt ([IO.File]::Exists($paths.recovery)) 'Ack-death did not persist recovery.json.'
            Assert-CasInt ([IO.File]::Exists($paths.failure)) 'Ack-death did not persist failure.json.'
            [IO.File]::WriteAllText($hold, 'release', [Text.UTF8Encoding]::new($false))
            Remove-Item env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH -ErrorAction SilentlyContinue
            return [ordered]@{
                harness = $harness
                thread_id = $threadId
                run_id = $RunId
                paths = $paths
                turn_id = [string]$bound.turn_id
                event_log = $eventLog
                hold = $hold
            }
        }
        $lastFail = ("exit=" + $first.exit_code + " " + $first.stderr + " " + $first.stdout)
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH, env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 250
    }
    Assert-CasInt $false ("Ack-death first launch failed: " + $lastFail)
}

function New-CasIntPreAckRecoveryWorld {
    param([string]$Name, [string]$RunId)
    Clear-CasIntTestEnv
    $harness = New-CasIntHarness -Name $Name
    $null = Invoke-CasIntProfile -Harness $harness
    $built = Invoke-CasIntBuilder -Harness $harness
    $threadId = [string]$built.json.thread_id
    $eventLog = Join-Path $harness.root 'events.log'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLog
    $env:TELEPHONE_TEST_APP_SERVER_LEAD_THROW_AT = 'before-ack'
    $first = Invoke-CasIntLauncher -Harness $harness -ThreadId $threadId -RunId $RunId
    Assert-CasInt ($first.exit_code -ne 0) ("Pre-ack recovery first launch did not fail closed: $($first.stderr) $($first.stdout)")
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $harness -RunId $RunId) 'Pre-ack recovery left a live worker.'
    Stop-CasIntRun -Harness $harness -RunId $RunId
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_THROW_AT -ErrorAction SilentlyContinue
    $paths = Get-CodexAppServerRunPaths -StateRoot ([string]$harness.state) -RunId $RunId
    $run = Get-CasIntRunJson -Harness $harness -RunId $RunId
    $bound = Get-CasIntBoundJson -Harness $harness -RunId $RunId
    Assert-CasInt ([string]$run.callback_write_phase -ceq 'turn_bound') 'Pre-ack recovery did not remain at turn_bound.'
    Assert-CasInt ([string]$run.disposition -ceq 'recovery_required') 'Pre-ack recovery did not persist recovery_required.'
    Assert-CasInt ([IO.File]::Exists($paths.recovery)) 'Pre-ack recovery did not persist recovery.json.'
    Assert-CasInt ([IO.File]::Exists($paths.failure)) 'Pre-ack recovery did not persist failure.json.'
    return [ordered]@{
        harness = $harness
        thread_id = $threadId
        run_id = $RunId
        paths = $paths
        turn_id = [string]$bound.turn_id
        event_log = $eventLog
    }
}

function Get-CasIntRecoverForwardExpectedPhase {
    param([string]$Crash)
    switch ([string]$Crash) {
        'after-turn-bind' { return 'turn_bound' }
        'after-ack-in-progress' { return 'acknowledged' }
        'after-terminal-intent' { return 'terminal_publishing' }
        'after-terminal-run' { return 'terminal' }
        default { return '' }
    }
}

function Get-CasIntTransitionStateCount {
    param([string]$Path, [string]$State)
    if (-not [IO.File]::Exists($Path)) { return 0 }
    $lines = $null
    try { $lines = [IO.File]::ReadAllLines($Path) } catch [IO.IOException] { return -1 } catch { return -1 }
    $count = 0
    foreach ($line in $lines) {
        try {
            $row = $line | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
            if ($row -is [Collections.IDictionary] -and [string]$row.state -ceq $State) { $count += 1 }
        } catch { }
    }
    return $count
}

function Wait-CasIntRecoverForwardCrash {
    param($World, [string]$ExpectedPhase, [int]$OwnerBoundBefore, [string]$OwnerIdentityBefore = '', [int]$TimeoutMs = 60000)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    $phase = ''
    $ownerBound = $OwnerBoundBefore
    $ownerAlive = $false
    $ownerIdentity = $OwnerIdentityBefore
    $ownerChanged = $false
    $observedOwnerIdentity = $OwnerIdentityBefore
    $observedChildIdentity = Get-CasIntChildIdentityKey -Harness $World.harness -RunId $World.run_id
    $runAlive = Test-CasIntIdentityKeyAlive -IdentityKey $observedOwnerIdentity
    $childAlive = Test-CasIntIdentityKeyAlive -IdentityKey $observedChildIdentity
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try { $phase = [string](Get-CasIntRunJson -Harness $World.harness -RunId $World.run_id).callback_write_phase } catch { $phase = '' }
        $ownerBound = Get-CasIntTransitionStateCount -Path ([string]$World.paths.transitions) -State 'owner_bound'
        $ownerIdentity = Get-CasIntRunOwnerIdentityKey -Harness $World.harness -RunId $World.run_id
        $ownerChanged = (-not [string]::IsNullOrWhiteSpace($ownerIdentity) -and $ownerIdentity -cne $OwnerIdentityBefore)
        if ($ownerChanged) { $observedOwnerIdentity = $ownerIdentity }
        $childIdentity = Get-CasIntChildIdentityKey -Harness $World.harness -RunId $World.run_id
        if (-not [string]::IsNullOrWhiteSpace($childIdentity)) { $observedChildIdentity = $childIdentity }
        $runAlive = Test-CasIntIdentityKeyAlive -IdentityKey $observedOwnerIdentity
        $childAlive = Test-CasIntIdentityKeyAlive -IdentityKey $observedChildIdentity
        $ownerAlive = Test-CasIntThreadOwnerAlive -Harness $World.harness -ThreadId $World.thread_id
        if ($ownerBound -gt $OwnerBoundBefore -and $ownerChanged -and $phase -ceq $ExpectedPhase -and -not $ownerAlive -and -not $runAlive -and -not $childAlive) {
            return [ordered]@{ success = $true; phase = $phase; owner_bound = $ownerBound; owner_changed = $ownerChanged; owner_alive = $ownerAlive; run_alive = $runAlive; child_alive = $childAlive }
        }
        Start-Sleep -Milliseconds 50
    }
    return [ordered]@{ success = $false; phase = $phase; owner_bound = $ownerBound; owner_changed = $ownerChanged; owner_alive = $ownerAlive; run_alive = $runAlive; child_alive = $childAlive }
}

function Wait-CasIntOfficialTerminalAndQuiet {
    param($Harness, [string]$RunId, [string]$ThreadId, [string]$TurnId, [string]$Disposition = 'completed', [int]$TimeoutMs = 30000)
    $terminal = Wait-CasIntOfficialTerminal -Harness $Harness -RunId $RunId -ThreadId $ThreadId -TurnId $TurnId -Disposition $Disposition -TimeoutMs $TimeoutMs
    if (-not $terminal) {
        $phase = ''
        $state = ''
        try {
            $run = Get-CasIntRunJson -Harness $Harness -RunId $RunId
            $phase = [string]$run.callback_write_phase
            $state = [string]$run.disposition
        } catch { }
        return [ordered]@{ success = $false; terminal = $false; run_quiet = $false; thread_quiet = $false; phase = $phase; state = $state }
    }
    $runQuiet = Wait-CasIntRunOwnerQuiet -Harness $Harness -RunId $RunId -TimeoutMs $TimeoutMs
    $threadQuiet = Wait-CasIntThreadOwnerQuiet -Harness $Harness -ThreadId $ThreadId -TimeoutMs $TimeoutMs
    return [ordered]@{ success = ($runQuiet -and $threadQuiet); terminal = $true; run_quiet = $runQuiet; thread_quiet = $threadQuiet; phase = 'terminal'; state = $Disposition }
}

function Wait-CasIntOwnerDeathCycle {
    param($Harness, [string]$ThreadId, [string]$RunId, [string]$TransitionsPath, [int]$OwnerBoundBefore, [string]$OwnerIdentityBefore = '', [int]$TimeoutMs = 60000)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    $ownerBound = $OwnerBoundBefore
    $ownerSeen = $false
    $ownerChanged = $false
    $runAlive = $false
    $threadAlive = $false
    $observedOwnerIdentity = $OwnerIdentityBefore
    $observedChildIdentity = Get-CasIntChildIdentityKey -Harness $Harness -RunId $RunId
    $childAlive = Test-CasIntIdentityKeyAlive -IdentityKey $observedChildIdentity
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $ownerBound = Get-CasIntTransitionStateCount -Path $TransitionsPath -State 'owner_bound'
        $ownerIdentity = Get-CasIntRunOwnerIdentityKey -Harness $Harness -RunId $RunId
        $ownerSeen = -not [string]::IsNullOrWhiteSpace($ownerIdentity)
        $ownerChanged = ($ownerSeen -and $ownerIdentity -cne $OwnerIdentityBefore)
        if ($ownerChanged) { $observedOwnerIdentity = $ownerIdentity }
        $childIdentity = Get-CasIntChildIdentityKey -Harness $Harness -RunId $RunId
        if (-not [string]::IsNullOrWhiteSpace($childIdentity)) { $observedChildIdentity = $childIdentity }
        $runAlive = Test-CasIntIdentityKeyAlive -IdentityKey $observedOwnerIdentity
        $childAlive = Test-CasIntIdentityKeyAlive -IdentityKey $observedChildIdentity
        $threadAlive = Test-CasIntThreadOwnerAlive -Harness $Harness -ThreadId $ThreadId
        if ($ownerBound -gt $OwnerBoundBefore -and $ownerChanged -and -not $runAlive -and -not $threadAlive -and -not $childAlive) {
            return [ordered]@{ success = $true; owner_bound = $ownerBound; owner_seen = $ownerSeen; owner_changed = $ownerChanged; run_alive = $runAlive; thread_alive = $threadAlive; child_alive = $childAlive }
        }
        Start-Sleep -Milliseconds 50
    }
    return [ordered]@{ success = $false; owner_bound = $ownerBound; owner_seen = $ownerSeen; owner_changed = $ownerChanged; run_alive = $runAlive; thread_alive = $threadAlive; child_alive = $childAlive }
}

function Wait-CasIntRunStateAndQuiet {
    param($Harness, [string]$ThreadId, [string]$RunId, [string]$Disposition, [string]$Phase, [int]$TimeoutMs = 30000)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    $state = ''
    $phaseNow = ''
    $runQuiet = $false
    $threadQuiet = $false
    $observedOwner = Get-CasIntRunOwnerIdentityKey -Harness $Harness -RunId $RunId
    $observedChild = Get-CasIntChildIdentityKey -Harness $Harness -RunId $RunId
    $observedThread = Get-CasIntThreadOwnerIdentityKey -Harness $Harness -ThreadId $ThreadId
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $run = Get-CasIntRunJson -Harness $Harness -RunId $RunId
            $state = [string]$run.disposition
            $phaseNow = [string]$run.callback_write_phase
        } catch {
            $state = ''
            $phaseNow = ''
        }
        $currentOwner = Get-CasIntRunOwnerIdentityKey -Harness $Harness -RunId $RunId
        $currentChild = Get-CasIntChildIdentityKey -Harness $Harness -RunId $RunId
        $currentThread = Get-CasIntThreadOwnerIdentityKey -Harness $Harness -ThreadId $ThreadId
        if (-not [string]::IsNullOrWhiteSpace($currentOwner)) { $observedOwner = $currentOwner }
        if (-not [string]::IsNullOrWhiteSpace($currentChild)) { $observedChild = $currentChild }
        if (-not [string]::IsNullOrWhiteSpace($currentThread)) { $observedThread = $currentThread }
        $runQuiet = (-not (Test-CasIntOwnerAlive -Harness $Harness -RunId $RunId) -and -not (Test-CasIntIdentityKeyAlive -IdentityKey $observedOwner) -and -not (Test-CasIntIdentityKeyAlive -IdentityKey $observedChild))
        $threadQuiet = (-not (Test-CasIntThreadOwnerAlive -Harness $Harness -ThreadId $ThreadId) -and -not (Test-CasIntIdentityKeyAlive -IdentityKey $observedThread))
        if ($state -ceq $Disposition -and $phaseNow -ceq $Phase -and $runQuiet -and $threadQuiet) {
            return [ordered]@{ success = $true; state = $state; phase = $phaseNow; run_quiet = $runQuiet; thread_quiet = $threadQuiet }
        }
        Start-Sleep -Milliseconds 50
    }
    return [ordered]@{ success = $false; state = $state; phase = $phaseNow; run_quiet = $runQuiet; thread_quiet = $threadQuiet }
}

function Get-CasIntIndependentExpectedHistoryRows {
    $rows = [Collections.Generic.List[object]]::new()
    function Add-CasIntExpectedFailure {
        param(
            [string]$Code,
            [string]$Phase,
            [string]$FromDisposition,
            [string]$ToDisposition,
            [string]$TurnState
        )
        $rows.Add([ordered]@{
            kind = 'failure'
            code = [string]$Code
            category = 'worker'
            recorded_phase = [string]$Phase
            recorded_disposition = [string]$FromDisposition
            recorded_state = ''
            current_phase = [string]$Phase
            current_disposition = [string]$ToDisposition
            turn_state = [string]$TurnState
        })
    }
    function Add-CasIntExpectedRecovery {
        param(
            [string]$Phase,
            [string]$CurrentDisposition,
            [string]$TurnState
        )
        $rows.Add([ordered]@{
            kind = 'recovery'
            code = ''
            category = ''
            recorded_phase = [string]$Phase
            recorded_disposition = ''
            recorded_state = 'recovery_required'
            current_phase = [string]$Phase
            current_disposition = [string]$CurrentDisposition
            turn_state = [string]$TurnState
        })
    }
    $origins = @(
        @{ phase = 'turn_start_sending'; turn = 'prebind' },
        @{ phase = 'turn_start_sending'; turn = 'bound' },
        @{ phase = 'turn_bound'; turn = 'bound' },
        @{ phase = 'acknowledged'; turn = 'acked' }
    )
    foreach ($spec in $origins) {
        foreach ($curDisp in @('in_progress', 'recovery_required', 'recovered')) {
            Add-CasIntExpectedRecovery -Phase ([string]$spec.phase) -CurrentDisposition $curDisp -TurnState ([string]$spec.turn)
        }
    }
    Add-CasIntExpectedFailure -Code 'schema_or_version_mismatch' -Phase 'none' -FromDisposition 'in_progress' -ToDisposition 'fallback_required_cli' -TurnState 'prebind'
    Add-CasIntExpectedFailure -Code 'schema_or_version_mismatch' -Phase 'none' -FromDisposition 'fallback_required_cli' -ToDisposition 'fallback_required_cli' -TurnState 'prebind'
    Add-CasIntExpectedFailure -Code 'schema_or_version_mismatch' -Phase 'none' -FromDisposition 'in_progress' -ToDisposition '' -TurnState 'prebind'
    Add-CasIntExpectedFailure -Code 'schema_or_version_mismatch' -Phase 'none' -FromDisposition 'in_progress' -ToDisposition 'in_progress' -TurnState 'prebind'
    Add-CasIntExpectedFailure -Code 'worker_failed' -Phase 'none' -FromDisposition 'in_progress' -ToDisposition 'in_progress' -TurnState 'prebind'
    Add-CasIntExpectedFailure -Code 'worker_failed' -Phase 'none' -FromDisposition 'fallback_required_cli' -ToDisposition 'fallback_required_cli' -TurnState 'prebind'
    Add-CasIntExpectedFailure -Code 'worker_failed' -Phase 'none' -FromDisposition 'fallback_required_cli' -ToDisposition 'in_progress' -TurnState 'prebind'
    Add-CasIntExpectedFailure -Code 'worker_failed' -Phase 'none' -FromDisposition 'in_progress' -ToDisposition '' -TurnState 'prebind'
    foreach ($closed in $origins) {
        Add-CasIntExpectedFailure -Code 'compatibility_drift_after_bind' -Phase ([string]$closed.phase) -FromDisposition 'in_progress' -ToDisposition 'in_progress' -TurnState ([string]$closed.turn)
        Add-CasIntExpectedFailure -Code 'compatibility_drift_after_bind' -Phase ([string]$closed.phase) -FromDisposition 'in_progress' -ToDisposition 'recovery_required' -TurnState ([string]$closed.turn)
        Add-CasIntExpectedFailure -Code 'compatibility_drift_after_bind' -Phase ([string]$closed.phase) -FromDisposition 'recovery_required' -ToDisposition 'recovery_required' -TurnState ([string]$closed.turn)
    }
    $boundPhases = @(
        @{ phase = 'turn_start_sending'; turn = 'bound' },
        @{ phase = 'turn_bound'; turn = 'bound' },
        @{ phase = 'acknowledged'; turn = 'acked' }
    )
    foreach ($boundPhase in $boundPhases) {
        Add-CasIntExpectedFailure -Code 'transport_lost_before_terminal' -Phase ([string]$boundPhase.phase) -FromDisposition 'in_progress' -ToDisposition 'in_progress' -TurnState ([string]$boundPhase.turn)
        Add-CasIntExpectedFailure -Code 'transport_lost_before_terminal' -Phase ([string]$boundPhase.phase) -FromDisposition 'in_progress' -ToDisposition 'recovery_required' -TurnState ([string]$boundPhase.turn)
        Add-CasIntExpectedFailure -Code 'transport_lost_before_terminal' -Phase ([string]$boundPhase.phase) -FromDisposition 'recovery_required' -ToDisposition 'recovery_required' -TurnState ([string]$boundPhase.turn)
    }
    Add-CasIntExpectedFailure -Code 'worker_failed' -Phase 'turn_start_sending' -FromDisposition 'in_progress' -ToDisposition 'in_progress' -TurnState 'prebind'
    Add-CasIntExpectedFailure -Code 'worker_failed' -Phase 'turn_start_sending' -FromDisposition 'in_progress' -ToDisposition 'recovery_required' -TurnState 'prebind'
    Add-CasIntExpectedFailure -Code 'worker_failed' -Phase 'turn_start_sending' -FromDisposition 'recovery_required' -ToDisposition 'recovery_required' -TurnState 'prebind'
    return @($rows)
}

function Get-CasIntWriterScenarioDefinitions {
    $drift = 'codex-cli 0.148.0-drift'
    $origins = @(
        @{ suffix = 'sending-prebind'; phase = 'turn_start_sending'; turn = 'prebind' },
        @{ suffix = 'sending-bound'; phase = 'turn_start_sending'; turn = 'bound' },
        @{ suffix = 'turn-bound'; phase = 'turn_bound'; turn = 'bound' },
        @{ suffix = 'acked'; phase = 'acknowledged'; turn = 'acked' }
    )
    $boundPhases = @(
        @{ suffix = 'sending-bound'; phase = 'turn_start_sending'; turn = 'bound' },
        @{ suffix = 'turn-bound'; phase = 'turn_bound'; turn = 'bound' },
        @{ suffix = 'acked'; phase = 'acknowledged'; turn = 'acked' }
    )
    $defs = [Collections.Generic.List[object]]::new()
    $defs.Add(@{ name = 'schema-none-in-progress-after-failure'; invoke = 'failure-writer'; plant = $true; phase = 'none'; disp = 'in_progress'; turn = 'prebind'; rec = $false; code = 'schema_or_version_mismatch'; writer = 'failure-writer'; boundary = 'failure-snapshot'; call_site = 'Write-CodexAppServerFailureRecord' })
    $defs.Add(@{ name = 'schema-none-fallback-after-failure'; invoke = 'failure-writer'; plant = $true; phase = 'none'; disp = 'fallback_required_cli'; turn = 'prebind'; rec = $false; code = 'schema_or_version_mismatch'; writer = 'failure-writer'; boundary = 'failure-snapshot'; call_site = 'Write-CodexAppServerFailureRecord' })
    $defs.Add(@{ name = 'schema-none-intent-only-after-failure'; invoke = 'failure-writer'; plant = $true; phase = 'none'; disp = ''; turn = 'prebind'; rec = $false; intent_only = $true; code = 'schema_or_version_mismatch'; writer = 'failure-writer'; boundary = 'failure-snapshot'; call_site = 'Write-CodexAppServerFailureRecord' })
    $defs.Add(@{ name = 'worker-none-in-progress-after-failure'; invoke = 'failure-writer'; plant = $true; phase = 'none'; disp = 'in_progress'; turn = 'prebind'; rec = $false; code = 'worker_failed'; writer = 'failure-writer'; boundary = 'failure-snapshot'; call_site = 'Write-CodexAppServerFailureRecord' })
    $defs.Add(@{ name = 'worker-none-fallback-after-failure'; invoke = 'failure-writer'; plant = $true; phase = 'none'; disp = 'fallback_required_cli'; turn = 'prebind'; rec = $false; code = 'worker_failed'; writer = 'failure-writer'; boundary = 'failure-snapshot'; call_site = 'Write-CodexAppServerFailureRecord' })
    $defs.Add(@{ name = 'worker-none-intent-only-after-failure'; invoke = 'failure-writer'; plant = $true; phase = 'none'; disp = ''; turn = 'prebind'; rec = $false; intent_only = $true; code = 'worker_failed'; writer = 'failure-writer'; boundary = 'failure-snapshot'; call_site = 'Write-CodexAppServerFailureRecord' })
    $defs.Add(@{ name = 'worker-sending-prebind-after-failure'; invoke = 'failure-writer'; plant = $true; phase = 'turn_start_sending'; disp = 'in_progress'; turn = 'prebind'; rec = $false; code = 'worker_failed'; writer = 'failure-writer'; boundary = 'failure-snapshot'; call_site = 'Write-CodexAppServerFailureRecord' })
    $defs.Add(@{ name = 'worker-sending-prebind-already-recovery-failure'; invoke = 'failure-writer'; plant = $true; phase = 'turn_start_sending'; disp = 'recovery_required'; turn = 'prebind'; rec = $true; code = 'worker_failed'; writer = 'failure-writer'; boundary = 'failure-snapshot'; call_site = 'Write-CodexAppServerFailureRecord' })
    foreach ($spec in $origins) {
        $defs.Add(@{ name = ('compat-' + [string]$spec.suffix + '-after-failure'); invoke = 'failure-writer'; plant = $true; phase = [string]$spec.phase; disp = 'in_progress'; turn = [string]$spec.turn; rec = $false; code = 'compatibility_drift_after_bind'; writer = 'failure-writer'; boundary = 'failure-snapshot'; call_site = 'Write-CodexAppServerFailureRecord' })
        $defs.Add(@{ name = ('compat-' + [string]$spec.suffix + '-already-recovery-failure'); invoke = 'failure-writer'; plant = $true; phase = [string]$spec.phase; disp = 'recovery_required'; turn = [string]$spec.turn; rec = $true; code = 'compatibility_drift_after_bind'; writer = 'failure-writer'; boundary = 'failure-snapshot'; call_site = 'Write-CodexAppServerFailureRecord' })
    }
    foreach ($spec in $boundPhases) {
        $defs.Add(@{ name = ('transport-' + [string]$spec.suffix + '-after-failure'); invoke = 'failure-writer'; plant = $true; phase = [string]$spec.phase; disp = 'in_progress'; turn = [string]$spec.turn; rec = $false; code = 'transport_lost_before_terminal'; writer = 'failure-writer'; boundary = 'failure-snapshot'; call_site = 'Write-CodexAppServerFailureRecord' })
        $defs.Add(@{ name = ('transport-' + [string]$spec.suffix + '-already-recovery-failure'); invoke = 'failure-writer'; plant = $true; phase = [string]$spec.phase; disp = 'recovery_required'; turn = [string]$spec.turn; rec = $true; code = 'transport_lost_before_terminal'; writer = 'failure-writer'; boundary = 'failure-snapshot'; call_site = 'Write-CodexAppServerFailureRecord' })
    }
    $defs.Add(@{ name = 'schema-none-in-progress'; invoke = 'worker'; plant = $true; phase = 'none'; disp = 'in_progress'; turn = 'prebind'; rec = $false; mutate_version = $true; version = $drift; writer = 'catch-run'; boundary = 'catch-run'; call_site = 'Invoke-CodexAppServerWorkerCore/catch' })
    $defs.Add(@{ name = 'worker-none-fallback'; invoke = 'worker'; plant = $true; phase = 'none'; disp = 'fallback_required_cli'; turn = 'prebind'; rec = $false; mock_crash_at = 'after-initialize'; writer = 'catch-run'; boundary = 'catch-run'; call_site = 'Invoke-CodexAppServerWorkerCore/catch' })
    $defs.Add(@{ name = 'worker-none-fallback-preloop-no-declaration'; invoke = 'worker'; plant = $true; phase = 'none'; disp = 'fallback_required_cli'; turn = 'prebind'; rec = $false; throw_at = 'before-write'; expect_tuple = $false; writer = 'catch-run'; boundary = 'preloop-no-declaration'; call_site = 'Invoke-CodexAppServerThreadOwnerLoop/before-write'; relation_inventory = $false })
    foreach ($spec in $origins) {
        $defs.Add(@{ name = ('recovery-writer-' + [string]$spec.suffix + '-after-record'); invoke = 'recovery-writer'; plant = $true; phase = [string]$spec.phase; disp = 'in_progress'; turn = [string]$spec.turn; rec = $false; crash_at = 'after-recovery-record'; writer = 'recovery-writer'; boundary = 'after-recovery-record'; call_site = 'Write-CodexAppServerRecoveryRequired' })
        $defs.Add(@{ name = ('recovery-writer-' + [string]$spec.suffix + '-complete'); invoke = 'recovery-writer'; plant = $true; phase = [string]$spec.phase; disp = 'in_progress'; turn = [string]$spec.turn; rec = $false; writer = 'recovery-writer'; boundary = 'recovery-required-run'; call_site = 'Write-CodexAppServerRecoveryRequired'; relation_inventory = $false })
        $defs.Add(@{ name = ('recovery-commit-' + [string]$spec.suffix); invoke = 'recovery-commit'; plant = $true; phase = [string]$spec.phase; disp = 'recovery_required'; turn = [string]$spec.turn; rec = $true; crash_at = 'after-recovery-commit-run'; writer = 'recovery-commit-writer'; boundary = 'after-recovery-commit-run'; call_site = 'Complete-CodexAppServerRecoveryCommit' })
    }
    $originForwards = @(
        @{ suffix = 'sending-prebind'; phase = 'turn_start_sending'; turn = 'prebind'; codes = @('worker_failed', 'compatibility_drift_after_bind') },
        @{ suffix = 'sending-bound'; phase = 'turn_start_sending'; turn = 'bound'; codes = @('compatibility_drift_after_bind', 'transport_lost_before_terminal') },
        @{ suffix = 'turn-bound'; phase = 'turn_bound'; turn = 'bound'; codes = @('compatibility_drift_after_bind', 'transport_lost_before_terminal') },
        @{ suffix = 'acked'; phase = 'acknowledged'; turn = 'acked'; codes = @('compatibility_drift_after_bind', 'transport_lost_before_terminal') }
    )
    foreach ($spec in $originForwards) {
        $codes = @($spec.codes)
        $defs.Add(@{ name = ('origin-' + [string]$spec.suffix + '-recovery-forward'); invoke = 'failure-writer'; then_invoke = 'recovery-writer'; plant = $true; phase = [string]$spec.phase; disp = 'in_progress'; turn = [string]$spec.turn; rec = $false; plant_failure = $false; fail_code = [string]$codes[0]; writer = 'recovery-required-run'; boundary = 'recovery-required-run'; call_site = 'Write-CodexAppServerRecoveryRequired'; expect_raw = 2 })
        $defs.Add(@{ name = ('origin-' + [string]$spec.suffix + '-failure-forward'); invoke = 'failure-writer'; then_invoke = 'recovery-writer'; plant = $true; phase = [string]$spec.phase; disp = 'in_progress'; turn = [string]$spec.turn; rec = $false; plant_failure = $false; fail_code = [string]$codes[1]; writer = 'recovery-required-run'; boundary = 'recovery-required-run'; call_site = 'Write-CodexAppServerRecoveryRequired'; expect_raw = 2 })
    }
    $defs.Add(@{ name = 'compat-publishing-in-progress'; invoke = 'worker'; plant = $true; phase = 'terminal_publishing'; disp = 'in_progress'; turn = 'publishing'; rec = $false; mutate_version = $true; version = $drift; expect_tuple = $false; writer = 'catch-failure-writer'; boundary = 'publishing-no-declaration'; call_site = 'Invoke-CodexAppServerWorkerCore/catch'; relation_inventory = $false })
    foreach ($term in @('completed', 'failed', 'interrupted')) {
        $defs.Add(@{ name = ('compat-terminal-' + $term); invoke = 'worker'; plant = $true; phase = 'terminal'; disp = $term; turn = 'terminal'; rec = $false; mutate_version = $true; version = $drift; expect_tuple = $false; expected_queue_count = 0; writer = 'catch-failure-writer'; boundary = 'terminal-no-declaration'; call_site = 'Invoke-CodexAppServerWorkerCore/catch'; relation_inventory = $false })
    }
    return @($defs)
}

function Invoke-CasIntMutatePlantedVersion {
    param($Paths, [string]$Version = 'codex-cli 0.148.0-drift')
    if ([IO.File]::Exists($Paths.intent)) {
        $intent = Read-CodexAppServerValidated -Path $Paths.intent -SchemaName 'codex-app-server-lead-intent'
        $intent.codex_version = [string]$Version
        $null = Write-CodexAppServerValidatedReplace -Path $Paths.intent -Value $intent -SchemaName 'codex-app-server-lead-intent'
    }
    if ([IO.File]::Exists($Paths.run)) {
        $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
        $run.codex_version = [string]$Version
        $null = Write-CodexAppServerValidatedReplace -Path $Paths.run -Value $run -SchemaName 'codex-app-server-lead-run'
    }
}

function Get-CasIntNonterminalQueue {
    param($Harness, [string]$ThreadId)
    $runsDir = Join-Path $Harness.state 'runs'
    $items = [Collections.Generic.List[object]]::new()
    if (-not [IO.Directory]::Exists($runsDir)) { return @() }
    foreach ($dir in [IO.Directory]::GetDirectories($runsDir)) {
        $runId = [IO.Path]::GetFileName($dir)
        $intentPath = Join-Path $dir 'intent.json'
        $runPath = Join-Path $dir 'run.json'
        if (-not [IO.File]::Exists($intentPath)) { continue }
        $intent = $null
        try { $intent = (Read-TelephoneJson -Path $intentPath -SchemaName 'codex-app-server-lead-intent').value } catch { continue }
        if ((Get-CodexAppServerDictString -Dict $intent -Key 'thread_id') -cne $ThreadId) { continue }
        if ([IO.File]::Exists($runPath)) {
            $run = $null
            try { $run = (Read-TelephoneJson -Path $runPath -SchemaName 'codex-app-server-lead-run').value } catch { continue }
            $disp = Get-CodexAppServerDictString -Dict $run -Key 'disposition'
            if ($disp -ceq 'completed' -or $disp -ceq 'failed' -or $disp -ceq 'interrupted') { continue }
        }
        $created = Get-CodexAppServerDictString -Dict $intent -Key 'created_at_utc'
        if ([string]::IsNullOrWhiteSpace($created)) { $created = '9999-12-31T00:00:00.0000000+00:00' }
        $items.Add([ordered]@{ run_id = [string]$runId; created_at_utc = [string]$created })
    }
    return @($items | Sort-Object { [string]$_.created_at_utc }, { [string]$_.run_id })
}

function Test-CasIntWorkerFixtureQueueClean {
    param($Harness, [string]$ThreadId, [string]$TargetRunId)
    $queue = @(Get-CasIntNonterminalQueue -Harness $Harness -ThreadId $ThreadId)
    $first = ''
    if ($queue.Count -gt 0) { $first = [string]$queue[0].run_id }
    return [ordered]@{
        clean = ($queue.Count -eq 1 -and $first -ceq $TargetRunId)
        count = [int]$queue.Count
        first = $first
        run_ids = @($queue | ForEach-Object { [string]$_.run_id })
    }
}

function Invoke-CasIntWriterScenario {
    param($Harness, [string]$ThreadId, $Spec)
    $rid = 'run-wrs-' + [string]$Spec.name
    Clear-CasIntTestEnv
    $paths = $null
    $activeHarness = $Harness
    $activeThread = $ThreadId
    $live = $false
    if ($Spec.Contains('live')) { $live = [bool]$Spec.live }
    if (([string]$Spec.invoke) -ceq 'worker') { $live = $true }
    if ($live) {
        $activeHarness = New-CasIntHarness -Name ('wrs-' + [string]$Spec.name)
        $null = Invoke-CasIntProfile -Harness $activeHarness
        $built = Invoke-CasIntBuilder -Harness $activeHarness
        $activeThread = [string]$built.json.thread_id
    }
    if ([bool]$Spec.plant) {
        $intentOnly = $false
        if ($Spec.Contains('intent_only')) { $intentOnly = [bool]$Spec.intent_only }
        $disp = [string]$Spec.disp
        $phase = [string]$Spec.phase
        $turn = [string]$Spec.turn
        $rec = [bool]$Spec.rec
        $plantFailure = $false
        $failCode = 'worker_failed'
        if ($Spec.Contains('plant_failure')) { $plantFailure = [bool]$Spec.plant_failure }
        if ($Spec.Contains('fail_code') -and -not [string]::IsNullOrWhiteSpace([string]$Spec.fail_code)) { $failCode = [string]$Spec.fail_code }
        elseif ($Spec.Contains('code') -and -not [string]::IsNullOrWhiteSpace([string]$Spec.code) -and $plantFailure) { $failCode = [string]$Spec.code }
        if ($intentOnly -or [string]::IsNullOrWhiteSpace($disp)) {
            $paths = Write-CasIntPlantedIntent -Harness $activeHarness -RunId $rid -ThreadId $activeThread
        } else {
            $paths = Write-CasIntHistoryWorld `
                -Harness $activeHarness `
                -ThreadId $activeThread `
                -RunId $rid `
                -CurrentPhase $phase `
                -CurrentDisposition $disp `
                -TurnState $turn `
                -PlantRecovery $rec `
                -RecoveryPhase $phase `
                -PlantFailure $plantFailure `
                -FailurePhase $phase `
                -FailureDisposition $disp `
                -FailureCode $failCode `
                -PlantResult ([bool]($turn -ceq 'terminal')) `
                -ResultState $disp
        }
    } else {
        $paths = Get-CodexAppServerRunPaths -StateRoot ([string]$activeHarness.state) -RunId $rid
    }
    if ($Spec.Contains('mutate_version') -and [bool]$Spec.mutate_version) {
        $mutVer = 'codex-cli 0.148.0-drift'
        if ($Spec.Contains('version') -and -not [string]::IsNullOrWhiteSpace([string]$Spec.version)) {
            $mutVer = [string]$Spec.version
        }
        Invoke-CasIntMutatePlantedVersion -Paths $paths -Version $mutVer
    } elseif ($Spec.Contains('version') -and -not [string]::IsNullOrWhiteSpace([string]$Spec.version)) {
        $env:TELEPHONE_TEST_APP_SERVER_VERSION = [string]$Spec.version
    }
    $queueClean = $true
    if (([string]$Spec.invoke) -ceq 'worker') {
        $iso = Test-CasIntWorkerFixtureQueueClean -Harness $activeHarness -ThreadId $activeThread -TargetRunId $rid
        $expectedQueueCount = 1
        if ($Spec.Contains('expected_queue_count')) { $expectedQueueCount = [int]$Spec.expected_queue_count }
        Assert-CasInt ($expectedQueueCount -eq 0 -or $expectedQueueCount -eq 1) ("Worker fixture queue expectation must be zero or one for $($Spec.name): expected=$expectedQueueCount")
        if ($expectedQueueCount -eq 0) {
            Assert-CasInt ($iso.count -eq 0) ("Terminal worker fixture unexpectedly remained queued for $($Spec.name): count=$($iso.count) first=$($iso.first) target=$rid ids=$($iso.run_ids -join ',')")
            $queueClean = ($iso.count -eq 0)
        } else {
            Assert-CasInt ([bool]$iso.clean) ("Worker fixture queue not isolated for $($Spec.name): count=$($iso.count) first=$($iso.first) target=$rid ids=$($iso.run_ids -join ',')")
            $queueClean = [bool]$iso.clean
        }
    }
    if ($Spec.Contains('throw_at') -and -not [string]::IsNullOrWhiteSpace([string]$Spec.throw_at)) {
        $env:TELEPHONE_TEST_APP_SERVER_LEAD_THROW_AT = [string]$Spec.throw_at
    }
    if ($Spec.Contains('crash_at') -and -not [string]::IsNullOrWhiteSpace([string]$Spec.crash_at)) {
        $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = [string]$Spec.crash_at
    }
    if ($Spec.Contains('mock_crash_at') -and -not [string]::IsNullOrWhiteSpace([string]$Spec.mock_crash_at)) {
        $env:TELEPHONE_TEST_APP_SERVER_CRASH_AT = [string]$Spec.mock_crash_at
    }
    if ($Spec.Contains('turn_status') -and -not [string]::IsNullOrWhiteSpace([string]$Spec.turn_status)) {
        $env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS = [string]$Spec.turn_status
    }
    $beforeEvidence = Get-CasIntPlantedEvidence -Paths $paths
    $invoke = [string]$Spec.invoke
    $crashAt = ''
    if ($Spec.Contains('crash_at')) { $crashAt = [string]$Spec.crash_at }
    $code = 'worker_failed'
    if ($Spec.Contains('code') -and -not [string]::IsNullOrWhiteSpace([string]$Spec.code)) { $code = [string]$Spec.code }
    elseif ($Spec.Contains('fail_code') -and -not [string]::IsNullOrWhiteSpace([string]$Spec.fail_code)) { $code = [string]$Spec.fail_code }
    $commitTurn = 'turn-hist'
    if ([string]$Spec.turn -ceq 'prebind') { $commitTurn = 'turn-proven' }
    try {
        $invokeSteps = [Collections.Generic.List[string]]::new()
        $invokeSteps.Add($invoke)
        if ($Spec.Contains('then_invoke') -and -not [string]::IsNullOrWhiteSpace([string]$Spec.then_invoke)) {
            $invokeSteps.Add([string]$Spec.then_invoke)
        }
        foreach ($step in $invokeSteps) {
            if ($step -ceq 'failure-writer' -or $step -ceq 'recovery-writer' -or $step -ceq 'recovery-commit') {
                $null = Invoke-CasIntDirectWriterProcess `
                    -StateRoot ([string]$activeHarness.state) `
                    -RunId $rid `
                    -ThreadId $activeThread `
                    -Invoke $step `
                    -Code $code `
                    -CrashAt $crashAt `
                    -CommitTurn $commitTurn
            } elseif ($step -ceq 'worker') {
                $null = Invoke-CasIntWorker -Harness $activeHarness -ThreadId $activeThread -RunId $rid
            } else {
                $null = Invoke-CasIntLauncher -Harness $activeHarness -ThreadId $activeThread -RunId $rid
                $null = Wait-CasIntRunQuiet -Harness $activeHarness -RunId $rid
                Stop-CasIntRun -Harness $activeHarness -RunId $rid
            }
        }
    } finally {
        Clear-CasIntTestEnv
        Stop-CasIntRun -Harness $activeHarness -RunId $rid
    }
    $captured = $null
    try {
        $captured = Get-CasIntAttributedTuples -Paths $paths -BeforeEvidence $beforeEvidence
    } catch {
        throw ("Writer scenario $([string]$Spec.name) tuple capture failed: " + [string]$_.Exception.Message)
    }
    $rawRows = [Collections.Generic.List[object]]::new()
    Add-CasIntTupleItems -Node $captured -Target $rawRows
    $writer = 'catch-or-recovery-writer'
    if ($Spec.Contains('writer') -and -not [string]::IsNullOrWhiteSpace([string]$Spec.writer)) { $writer = [string]$Spec.writer }
    $boundary = ''
    if ($Spec.Contains('boundary')) { $boundary = [string]$Spec.boundary }
    $callSite = ''
    if ($Spec.Contains('call_site')) { $callSite = [string]$Spec.call_site }
    return [ordered]@{
        name = [string]$Spec.name
        run_id = $rid
        paths = $paths
        tuples = $rawRows
        raw_tuples = $rawRows
        raw_count = [int]$rawRows.Count
        writer = $writer
        boundary = $boundary
        call_site = $callSite
        queue_clean = [bool]$queueClean
        harness = $activeHarness
        thread_id = $activeThread
    }
}

function Get-CasIntOwnerRecord {
    param($Harness, [string]$RunId)
    $path = Join-Path (Get-CasIntRunRoot -Harness $Harness -RunId $RunId) 'owner.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    try { return (Read-TelephoneJson -Path $path).value } catch { return $null }
}

function Get-CasIntRunOwnerIdentityKey {
    param($Harness, [string]$RunId)
    $path = Join-Path (Get-CasIntRunRoot -Harness $Harness -RunId $RunId) 'owner.json'
    return Get-CasIntIdentityKeyFromPath -Path $path
}

function Get-CasIntThreadOwnerIdentityKey {
    param($Harness, [string]$ThreadId)
    return Get-CasIntIdentityKeyFromPath -Path (Get-CasIntThreadOwnerPath -Harness $Harness -ThreadId $ThreadId)
}

function Get-CasIntChildIdentityKey {
    param($Harness, [string]$RunId)
    return Get-CasIntIdentityKeyFromPath -Path (Join-Path (Get-CasIntRunRoot -Harness $Harness -RunId $RunId) 'child.json')
}

function Get-CasIntIdentityKeyFromPath {
    param([string]$Path)
    $path = [string]$Path
    if (-not [IO.File]::Exists($path)) { return '' }
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds(500)
    do {
        $record = $null
        try { $record = (Read-TelephoneJson -Path $path).value } catch { $record = $null }
        if ($null -ne $record) {
            $pidText = Get-CodexAppServerDictString -Dict $record -Key 'pid'
            $ticks = Get-CodexAppServerDictString -Dict $record -Key 'start_time_utc_ticks'
            if (-not [string]::IsNullOrWhiteSpace($pidText) -and -not [string]::IsNullOrWhiteSpace($ticks)) { return ($pidText + ':' + $ticks) }
        }
        Start-Sleep -Milliseconds 25
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    return ''
}

function Test-CasIntIdentityKeyAlive {
    param([string]$IdentityKey)
    $key = [string]$IdentityKey
    if ([string]::IsNullOrWhiteSpace($key) -or $key -notmatch '^(\d+):(\d+)$') { return $false }
    $pidValue = [int]$Matches[1]
    $ticksValue = [int64]$Matches[2]
    try {
        $process = Get-Process -Id $pidValue -ErrorAction Stop
        try { return ($process.StartTime.ToUniversalTime().Ticks -eq $ticksValue) } finally { $process.Dispose() }
    } catch { return $false }
}

function Get-CasIntR8ScopedCutDefinitions {
    $replace = @('after-temp-flush', 'before-replace', 'after-replace', 'durable-publication')
    $delete = @('before-delete', 'after-delete')
    $defs = [Collections.Generic.List[object]]::new()
    foreach ($cut in $replace) {
        $defs.Add(@{ name = ('failure-snapshot:' + $cut); writer = 'failure-snapshot'; cut = $cut; crash_at = ('failure-snapshot:' + $cut); kind = 'live-throw-ambiguous'; expect = 'completed'; throw_at = 'after-ambiguous-write' })
        $defs.Add(@{ name = ('recovery-declaration:' + $cut); writer = 'recovery-declaration'; cut = $cut; crash_at = ('recovery-declaration:' + $cut); kind = 'live-throw-ambiguous'; expect = 'completed'; throw_at = 'after-ambiguous-write' })
        $defs.Add(@{ name = ('recovery-required-run:' + $cut); writer = 'recovery-required-run'; cut = $cut; crash_at = ('recovery-required-run:' + $cut); kind = 'live-throw-ambiguous'; expect = 'completed'; throw_at = 'after-ambiguous-write' })
        $defs.Add(@{ name = ('catch-run:' + $cut); writer = 'catch-run'; cut = $cut; crash_at = ('catch-run:' + $cut); kind = 'planted-throw-before-write'; expect = 'completed'; throw_at = 'before-write' })
        $sendingExpect = 'completed'
        if ($cut -ceq 'after-replace' -or $cut -ceq 'durable-publication') { $sendingExpect = 'recovery_required' }
        $defs.Add(@{ name = ('turn-start-sending:' + $cut); writer = 'turn-start-sending'; cut = $cut; crash_at = ('turn-start-sending:' + $cut); kind = 'fresh'; expect = $sendingExpect; throw_at = '' })
        $defs.Add(@{ name = ('bound:' + $cut); writer = 'bound'; cut = $cut; crash_at = ('bound:' + $cut); kind = 'fresh'; expect = 'completed'; throw_at = '' })
        $defs.Add(@{ name = ('run-bound:' + $cut); writer = 'run-bound'; cut = $cut; crash_at = ('run-bound:' + $cut); kind = 'fresh'; expect = 'completed'; throw_at = '' })
        $defs.Add(@{ name = ('ack:' + $cut); writer = 'ack'; cut = $cut; crash_at = ('ack:' + $cut); kind = 'fresh'; expect = 'completed'; throw_at = '' })
        $defs.Add(@{ name = ('acknowledged:' + $cut); writer = 'acknowledged'; cut = $cut; crash_at = ('acknowledged:' + $cut); kind = 'fresh'; expect = 'completed'; throw_at = '' })
        $defs.Add(@{ name = ('recovery-required-bound:' + $cut); writer = 'recovery-required-bound'; cut = $cut; crash_at = ('recovery-required-bound:' + $cut); kind = 'live-throw-ack'; expect = 'completed'; throw_at = 'after-ack-in-progress' })
        $defs.Add(@{ name = ('recovered-run:' + $cut); writer = 'recovered-run'; cut = $cut; crash_at = ('recovered-run:' + $cut); kind = 'ack-death'; expect = 'completed'; throw_at = '' })
        $defs.Add(@{ name = ('recovered-result:' + $cut); writer = 'recovered-result'; cut = $cut; crash_at = ('recovered-result:' + $cut); kind = 'ack-death-result'; expect = 'completed'; throw_at = '' })
        $defs.Add(@{ name = ('terminal-intent:' + $cut); writer = 'terminal-intent'; cut = $cut; crash_at = ('terminal-intent:' + $cut); kind = 'fresh'; expect = 'completed'; throw_at = '' })
        $defs.Add(@{ name = ('terminal-final:' + $cut); writer = 'terminal-final'; cut = $cut; crash_at = ('terminal-final:' + $cut); kind = 'fresh'; expect = 'completed'; throw_at = '' })
        $defs.Add(@{ name = ('terminal-bound:' + $cut); writer = 'terminal-bound'; cut = $cut; crash_at = ('terminal-bound:' + $cut); kind = 'fresh'; expect = 'completed'; throw_at = '' })
        $defs.Add(@{ name = ('terminal-run:' + $cut); writer = 'terminal-run'; cut = $cut; crash_at = ('terminal-run:' + $cut); kind = 'fresh'; expect = 'completed'; throw_at = '' })
        $defs.Add(@{ name = ('terminal-result:' + $cut); writer = 'terminal-result'; cut = $cut; crash_at = ('terminal-result:' + $cut); kind = 'fresh'; expect = 'completed'; throw_at = '' })
    }
    foreach ($cut in $delete) {
        $defs.Add(@{ name = ('failure-retirement:' + $cut); writer = 'failure-retirement'; cut = $cut; crash_at = ('failure-retirement:' + $cut); kind = 'ack-death'; expect = 'completed'; throw_at = '' })
        $defs.Add(@{ name = ('recovery-retirement:' + $cut); writer = 'recovery-retirement'; cut = $cut; crash_at = ('recovery-retirement:' + $cut); kind = 'ack-death'; expect = 'completed'; throw_at = '' })
    }
    return @($defs)
}

function Invoke-CasIntR8ScopedCutCase {
    param($Spec)
    $name = [string]$Spec.name
    $kind = [string]$Spec.kind
    $expect = [string]$Spec.expect
    $crashAt = [string]$Spec.crash_at
    $throwAt = ''
    if ($Spec.Contains('throw_at')) { $throwAt = [string]$Spec.throw_at }
    Clear-CasIntTestEnv
    $harness = $null
    $threadId = ''
    $runId = 'run-r8-' + ($name.Replace(':', '-'))
    $paths = $null
    $eventLog = ''
    $knownTurn = ''
    if ($kind -ceq 'ack-death' -or $kind -ceq 'ack-death-result') {
        $world = New-CasIntAckDeathWorld -Name ('r8-' + ($name.Replace(':', '-'))) -RunId $runId
        $harness = $world.harness
        $threadId = [string]$world.thread_id
        $paths = $world.paths
        $eventLog = [string]$world.event_log
        $knownTurn = [string]$world.turn_id
        Stop-CasIntThreadOwner -Harness $harness -ThreadId $threadId
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $harness -ThreadId $threadId -TimeoutMs 10000) ("R8 cut $name kept the pre-injection thread owner alive.")
        if ($kind -ceq 'ack-death-result' -and -not [IO.File]::Exists($paths.result)) {
            Write-CasIntPlantedResult -Paths $paths -RunId $runId -State 'in_progress'
        }
    } else {
        $harness = New-CasIntHarness -Name ('r8-' + ($name.Replace(':', '-')))
        $null = Invoke-CasIntProfile -Harness $harness
        $built = Invoke-CasIntBuilder -Harness $harness
        $threadId = [string]$built.json.thread_id
        $eventLog = Join-Path $harness.root 'events.log'
        if ($kind -ceq 'planted-throw-before-write') {
            $paths = Write-CasIntHistoryWorld -Harness $harness -ThreadId $threadId -RunId $runId -CurrentPhase 'none' -CurrentDisposition 'in_progress' -TurnState 'prebind'
        } else {
            $paths = Get-CodexAppServerRunPaths -StateRoot ([string]$harness.state) -RunId $runId
        }
    }
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLog
    if (-not [string]::IsNullOrWhiteSpace($throwAt)) {
        $env:TELEPHONE_TEST_APP_SERVER_LEAD_THROW_AT = $throwAt
    }
    $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = $crashAt
    $ownerBoundBefore = Get-CasIntTransitionStateCount -Path ([string]$paths.transitions) -State 'owner_bound'
    $ownerIdentityBefore = Get-CasIntRunOwnerIdentityKey -Harness $harness -RunId $runId
    $null = Invoke-CasIntLauncher -Harness $harness -ThreadId $threadId -RunId $runId
    $ownerCycle = Wait-CasIntOwnerDeathCycle -Harness $harness -ThreadId $threadId -RunId $runId -TransitionsPath ([string]$paths.transitions) -OwnerBoundBefore $ownerBoundBefore -OwnerIdentityBefore $ownerIdentityBefore
    Assert-CasInt ([bool]$ownerCycle.success) ("R8 cut $name owner death did not converge: owner_bound=$([int]$ownerCycle.owner_bound) baseline=$ownerBoundBefore owner_seen=$([bool]$ownerCycle.owner_seen) owner_changed=$([bool]$ownerCycle.owner_changed) run_alive=$([bool]$ownerCycle.run_alive) thread_alive=$([bool]$ownerCycle.thread_alive).")
    Stop-CasIntRun -Harness $harness -RunId $runId
    $owner = Get-CasIntOwnerRecord -Harness $harness -RunId $runId
    Assert-CasInt ($null -ne $owner) ("R8 cut $name omitted owner identity.")
    $ownerPid = [int](Get-CodexAppServerDictString -Dict $owner -Key 'pid')
    $startTicks = [int64]0
    $tickText = Get-CodexAppServerDictString -Dict $owner -Key 'start_time_utc_ticks'
    if (-not [string]::IsNullOrWhiteSpace($tickText)) { $startTicks = [int64]$tickText }
    Assert-CasInt ($ownerPid -gt 0) ("R8 cut $name owner pid was missing.")
    Assert-CasInt ($startTicks -gt 0) ("R8 cut $name owner start ticks were missing.")
    Assert-CasInt (-not (Test-CasIntOwnerAlive -Harness $harness -RunId $runId)) ("R8 cut $name owner was still alive.")
    $startsAfterCrash = Get-CasIntEventCount -Path $eventLog -Name 'turn/start'
    $runRoot = Get-CasIntRunRoot -Harness $harness -RunId $runId
    $snapshot = Get-CasIntTreeFingerprint -Root $runRoot
    Clear-CasIntTestEnv
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLog
    $reentry = Invoke-CasIntLauncher -Harness $harness -ThreadId $threadId -RunId $runId
    if ($expect -ceq 'completed') {
        Assert-CasInt ($reentry.exit_code -eq 0) ("R8 cut $name re-entry failed: $($reentry.stderr) $($reentry.stdout)")
        $turnForTerminal = $knownTurn
        if ([string]::IsNullOrWhiteSpace($turnForTerminal)) {
            try { $turnForTerminal = [string](Get-CasIntBoundJson -Harness $harness -RunId $runId).turn_id } catch { $turnForTerminal = '' }
        }
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace($turnForTerminal)) ("R8 cut $name re-entry omitted the bound turn.")
        $settled = Wait-CasIntOfficialTerminalAndQuiet -Harness $harness -RunId $runId -ThreadId $threadId -TurnId $turnForTerminal
        Assert-CasInt ([bool]$settled.success) ("R8 cut $name re-entry did not settle: terminal=$([bool]$settled.terminal) run_quiet=$([bool]$settled.run_quiet) thread_quiet=$([bool]$settled.thread_quiet) phase=$([string]$settled.phase) state=$([string]$settled.state).")
    } else {
        $settled = Wait-CasIntRunStateAndQuiet -Harness $harness -ThreadId $threadId -RunId $runId -Disposition 'recovery_required' -Phase 'turn_start_sending'
        Assert-CasInt ([bool]$settled.success) ("R8 cut $name recovery_required did not settle: state=$([string]$settled.state) phase=$([string]$settled.phase) run_quiet=$([bool]$settled.run_quiet) thread_quiet=$([bool]$settled.thread_quiet).")
    }
    Stop-CasIntRun -Harness $harness -RunId $runId
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
    $runNow = $null
    if ([IO.File]::Exists((Join-Path $runRoot 'run.json'))) {
        $runNow = Get-CasIntRunJson -Harness $harness -RunId $runId
        Assert-CasInt ([string]$runNow.thread_id -ceq $threadId) ("R8 cut $name changed thread id.")
        Assert-CasInt ([string]$runNow.fallback_required -ceq '') ("R8 cut $name enabled CLI fallback.")
    }
    $startsAfter = Get-CasIntEventCount -Path $eventLog -Name 'turn/start'
    $turnsAfter = @(Get-CasIntStoreTurns -Harness $harness -ThreadId $threadId).Count
    $successor = ''
    if ($null -ne $runNow) { $successor = [string]$runNow.disposition }
    if ($expect -ceq 'completed') {
        Assert-CasInt ($reentry.exit_code -eq 0) ("R8 cut $name re-entry failed: $($reentry.stderr) $($reentry.stdout)")
        Assert-CasInt ($successor -ceq 'completed') ("R8 cut $name did not reach completed (disposition=$successor).")
        Assert-CasInt ([string]$runNow.callback_write_phase -ceq 'terminal') ("R8 cut $name did not reach terminal phase.")
        Assert-CasInt ($startsAfter -eq 1) ("R8 cut $name did not keep one turn/start (count=$startsAfter, crash=$startsAfterCrash).")
        Assert-CasInt ($turnsAfter -eq 1) ("R8 cut $name did not keep one store turn (count=$turnsAfter).")
        if (-not [string]::IsNullOrWhiteSpace($knownTurn)) {
            Assert-CasInt ([string]$runNow.selected_turn_id -ceq $knownTurn) ("R8 cut $name changed turn id.")
        }
        $repeat = Invoke-CasIntLauncher -Harness $harness -ThreadId $threadId -RunId $runId
        Assert-CasInt ($repeat.exit_code -eq 0) ("R8 cut $name repeat launcher failed: $($repeat.stderr) $($repeat.stdout)")
        Assert-CasInt ($repeat.json.state -ceq 'completed') ("R8 cut $name repeat launcher lost the official terminal.")
        Assert-CasInt (-not (Test-CasIntOwnerAlive -Harness $harness -RunId $runId)) ("R8 cut $name repeat launcher started a per-run owner.")
        Assert-CasInt (-not (Test-CasIntThreadOwnerAlive -Harness $harness -ThreadId $threadId)) ("R8 cut $name repeat launcher started a thread owner.")
        Assert-CasInt ((Get-CasIntEventCount -Path $eventLog -Name 'turn/start') -eq 1) ("R8 cut $name repeat launcher sent another turn/start.")
        Assert-CasInt (-not [IO.File]::Exists($paths.recovery)) ("R8 cut $name leaked recovery.json after terminal.")
        Assert-CasInt (-not [IO.File]::Exists($paths.failure)) ("R8 cut $name leaked failure.json after terminal.")
        Assert-CasInt (Test-CasIntNoTempResidue -RunRoot $runRoot) ("R8 cut $name left temp residue after terminal.")
    } else {
        Assert-CasInt ($successor -ceq 'recovery_required') ("R8 cut $name expected recovery_required (disposition=$successor).")
        Assert-CasInt ($startsAfter -eq 0) ("R8 cut $name started a provider turn after empty-turn death (count=$startsAfter).")
        Assert-CasInt ($turnsAfter -eq 0) ("R8 cut $name created a store turn after empty-turn death.")
        Assert-CasInt ([string]$runNow.callback_write_phase -ceq 'turn_start_sending') ("R8 cut $name lost turn_start_sending.")
        Assert-CasInt ([string]$runNow.selected_turn_id -ceq '') ("R8 cut $name selected a turn before marker proof.")
        Assert-CasInt ([IO.File]::Exists($paths.recovery)) ("R8 cut $name omitted recovery.json on empty-turn recovery_required.")
    }
    $script:f02R8ProcessDeathCuts += 1
    $script:f02R8CutResults.Add([ordered]@{
        name = $name
        writer = [string]$Spec.writer
        cut = [string]$Spec.cut
        crash_at = $crashAt
        kind = $kind
        expect = $expect
        owner_pid = $ownerPid
        start_time_utc_ticks = $startTicks
        starts_after_crash = $startsAfterCrash
        starts_after_reentry = $startsAfter
        successor = $successor
        snapshot_bytes = [int]$snapshot.Length
        ok = $true
    })
}


function Test-CasIntNoTempResidue {
    param([string]$RunRoot)
    if (-not [IO.Directory]::Exists($RunRoot)) { return $true }
    foreach ($file in [IO.Directory]::GetFiles($RunRoot)) {
        $name = [IO.Path]::GetFileName($file)
        if ($name.Contains('.tmp-') -or $name.Contains('.bak-')) { return $false }
    }
    return $true
}

function Assert-CasIntNoSecret {
    param($Harness, [string]$RunId, [string]$Stdout, [string]$Stderr)
    $secretHits = 0
    $needles = @(
        $Harness.secret,
        'sk-SECRETFAKEVALUE1234567890abcd',
        'Bearer FAKESECRET_e1f2g3h4i5j6k7l8m9n0'
    )
    foreach ($file in @(Get-CasIntAdapterFiles -Harness $Harness -RunId $RunId)) {
        $text = [IO.File]::ReadAllText($file)
        foreach ($needle in $needles) {
            if ($text.IndexOf($needle, [StringComparison]::Ordinal) -ge 0) { $secretHits += 1 }
        }
        Assert-CasInt ($text -notmatch 'sk-[A-Za-z0-9]{16,}') "Credential-like value in $file"
        Assert-CasInt ($text.IndexOf('Bearer ', [StringComparison]::OrdinalIgnoreCase) -lt 0) "Bearer token in $file"
    }
    $runRoot = Get-CasIntRunRoot -Harness $Harness -RunId $RunId
    if ([IO.Directory]::Exists($runRoot)) {
        foreach ($file in @([IO.Directory]::GetFiles($runRoot, '*', [IO.SearchOption]::AllDirectories))) {
            $text = [IO.File]::ReadAllText($file)
            foreach ($needle in $needles) {
                if ($text.IndexOf($needle, [StringComparison]::Ordinal) -ge 0) { $secretHits += 1 }
            }
        }
    }
    foreach ($blob in @($Stdout, $Stderr)) {
        foreach ($needle in $needles) {
            if ([string]$blob.IndexOf($needle, [StringComparison]::Ordinal) -ge 0) { $secretHits += 1 }
        }
    }
    Assert-CasInt ($secretHits -eq 0) 'Secret-shaped text leaked into adapter evidence.'
}

function Get-CasIntInstalledCodexCommand {
    if (-not [string]::IsNullOrWhiteSpace($InstalledCodexCommand)) {
        if (-not [IO.File]::Exists($InstalledCodexCommand)) { throw 'Installed Codex command path does not exist.' }
        return [IO.Path]::GetFullPath($InstalledCodexCommand)
    }
    $cmd = Get-Command 'codex.cmd' -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source) -and [IO.File]::Exists([string]$cmd.Source)) {
        return [IO.Path]::GetFullPath([string]$cmd.Source)
    }
    throw 'Installed codex.cmd was not found.'
}

function New-CasIntValidThread {
    param([string]$Id = 'thread-compat-1', [AllowEmptyCollection()][object[]]$Turns = @())
    $now = [int64]1
    return [ordered]@{
        id = $Id
        sessionId = $Id
        forkedFromId = $null
        parentThreadId = $null
        preview = ''
        ephemeral = $false
        section = $null
        sectionEnteredAt = $null
        modelProvider = 'openai'
        createdAt = $now
        updatedAt = $now
        recencyAt = $now
        status = [ordered]@{ type = 'idle' }
        path = $null
        cwd = 'C:\tmp\wt'
        cliVersion = 'codex-cli 0.147.0'
        source = 'appServer'
        threadSource = $null
        agentNickname = $null
        agentRole = $null
        gitInfo = $null
        name = $null
        turns = @($Turns)
    }
}

function New-CasIntValidStartResult {
    param($Thread, [AllowNull()][object]$ServiceTier = $null)
    return [ordered]@{
        thread = $Thread
        model = 'mock-model'
        modelProvider = 'openai'
        serviceTier = $ServiceTier
        cwd = 'C:\tmp\wt'
        instructionSources = @()
        approvalPolicy = 'never'
        approvalsReviewer = 'user'
        sandbox = [ordered]@{ type = 'dangerFullAccess' }
        reasoningEffort = $null
    }
}

function Invoke-CasIntExpectPublic {
    param([scriptblock]$Action, [string]$Code, [string]$Message)
    $failed = $false
    $text = ''
    try { & $Action } catch {
        $failed = $true
        $text = [string]$_.Exception.Message
    }
    Assert-CasInt $failed $Message
    Assert-CasInt ($text -ceq (Get-CodexAppServerPublicMessage -Code $Code)) ("Unexpected public failure: $text")
}

function Get-CasIntManifestRouteIds {
    $manifest = (Read-TelephoneJson -Path (Join-Path $repoRoot 'release-manifest.json') -SchemaName 'release-manifest').value
    return [ordered]@{
        file_count = [int]$manifest.counts.files
        denominator = [int]$manifest.denominator
        route_ids = @($manifest.route_ids | ForEach-Object { [string]$_ })
    }
}

try {
    $fullTestRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
    [IO.Directory]::CreateDirectory($fullTestRoot) | Out-Null
    $TestRoot = $fullTestRoot

    $mock = $packageMock

    $parseTargets = @(
        (Join-Path $repoRoot 'src\lead-side\codex-app-server\CodexAppServerLead.Common.ps1'),
        (Join-Path $repoRoot 'src\lead-side\codex-app-server\CodexAppServerLead.Lifecycle.ps1'),
        $profileScript, $preflightScript, $builderScript, $launcherScript, $statusScript,
        (Join-Path $repoRoot 'src\lead-side\codex-app-server\Invoke-CodexAppServerLeadWorker.ps1'),
        (Join-Path $repoRoot 'src\lead-side\codex-app-server\Invoke-CodexAppServerCompatibilityQualification.ps1'),
        (Join-Path $repoRoot 'src\lead-side\codex-app-server\Invoke-WirelessTelephoneSmoke.ps1'),
        (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1'),
        (Join-Path $repoRoot 'tests\contracts\test_contracts.ps1'),
        (Join-Path $repoRoot 'tests\Invoke-OfflineTests.ps1'),
        (Join-Path $repoRoot 'tests\docs\test_public_docs.ps1'),
        $PSCommandPath,
        $packageMock,
        $cliSpy
    )
    foreach ($path in $parseTargets) {
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        Assert-CasInt ($null -eq $errors -or @($errors).Count -eq 0) "Parse failed: $path"
    }
    $script:parseCheck = 1

    $catalog = (Read-TelephoneJson -Path (Join-Path $repoRoot 'src\catalog\routes.json') -SchemaName 'catalog').value
    Assert-CasInt ([int]$catalog.denominator -eq 8) 'Catalog denominator is not eight.'
    $ids = @($catalog.routes | ForEach-Object { [string]$_.route_id })
    $expected = @('deepsea-codex-cli', 'deepsea-grok-cli', 'deepsea-v4', 'direct-claude-code', 'direct-codex-cli', 'direct-cursor', 'direct-grok-cli', 'direct-pi')
    Assert-CasInt ($ids.Count -eq 8) 'Catalog does not contain eight routes.'
    for ($i = 0; $i -lt 8; $i++) {
        Assert-CasInt ([string]$ids[$i] -ceq [string]$expected[$i]) "Route order drifted at $i."
    }
    $script:denominatorEight = 8

    if ($LegacyHistoryBaselineOnly) {
        $script:legacyHistCompleted = 0
        $script:legacyBusyAtEnqueue = 0
        $script:legacyNoStoreLiveOwner = 0
        $script:legacySnapshotUnproven = 0
        $script:legacyFifoTwo = 0
        $script:legacyRestartOwner = 0
        $script:legacyUnsafeEmpty = 0
        $script:legacyPostAdmissionFailClosed = 0
        $script:legacyLicensedSnapshotExtras = 0
        $script:legacyUnlicensedSnapshotExtras = 0
        $script:legacyZeroResidue = 0
        $script:legacyAutoVarAudit = 0
        $autoForbidden = @('Matches', 'foreach', 'switch', 'input', 'this')
        $lifeAuditPath = Join-Path $repoRoot 'src\lead-side\codex-app-server\CodexAppServerLead.Lifecycle.ps1'
        $lifeAuditTokens = $null
        $lifeAuditErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($lifeAuditPath, [ref]$lifeAuditTokens, [ref]$lifeAuditErrors)
        Assert-CasInt ($null -eq $lifeAuditErrors -or @($lifeAuditErrors).Count -eq 0) 'Lifecycle automatic-variable parse failed.'
        $autoHits = 0
        foreach ($tok in @($lifeAuditTokens)) {
            if ([string]$tok.Kind -cne 'Variable') { continue }
            $hit = $false
            foreach ($name in @($autoForbidden)) {
                if ([string]::Equals([string]$tok.Name, [string]$name, [StringComparison]::Ordinal)) { $hit = $true; break }
            }
            if ($hit) { $autoHits += 1 }
        }
        Assert-CasInt ($autoHits -eq 0) 'Lifecycle used a PowerShell automatic variable by name.'
        $script:legacyAutoVarAudit = 1
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $env:TELEPHONE_TEST_APP_SERVER_ACK_TIMEOUT_SECONDS = '90'

        $hHist = New-CasIntHarness -Name 'legacy-hist-completed'
        $null = Invoke-CasIntProfile -Harness $hHist
        $bHist = Invoke-CasIntBuilder -Harness $hHist
        $tidHist = [string]$bHist.json.thread_id
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace($tidHist)) 'Historical-thread builder omitted thread id.'
        Add-CasIntStoreTurn -Harness $hHist -ThreadId $tidHist -TurnId 'turn-hist-1' -Status 'completed' -StartedAt 1700000000 -CompletedAt 1700000001 -Text 'completed historical turn 1'
        Add-CasIntStoreTurn -Harness $hHist -ThreadId $tidHist -TurnId 'turn-hist-2' -Status 'completed' -StartedAt 1700000002 -CompletedAt 1700000003 -Text 'completed historical turn 2'
        $histLog = Join-Path $hHist.root 'hist-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $histLog
        $histRun = 'run-legacy-hist-completed'
        $wakeHist = Invoke-CasIntLauncher -Harness $hHist -ThreadId $tidHist -RunId $histRun
        Assert-CasInt ($wakeHist.exit_code -eq 0) ("Historical enqueue failed: $($wakeHist.stderr) $($wakeHist.stdout)")
        $histBaseline = @(Get-CasIntIntentBaseline -Harness $hHist -RunId $histRun)
        Assert-CasInt ($histBaseline -contains 'turn-hist-1') 'Admission baseline omitted the first historical turn.'
        Assert-CasInt ($histBaseline -contains 'turn-hist-2') 'Admission baseline omitted the second historical turn.'
        $histRunDoc = Get-CasIntRunJson -Harness $hHist -RunId $histRun
        $histRunBaseline = @(Get-CodexAppServerStringList -Value (Get-CodexAppServerDictObject -Dict $histRunDoc -Key 'baseline_turn_ids'))
        Assert-CasInt ($histRunBaseline -contains 'turn-hist-1' -and $histRunBaseline -contains 'turn-hist-2') 'Persisted run baseline omitted historical turns.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hHist -ThreadId $tidHist -RunId $histRun).Count -eq 1) 'Historical enqueue did not create exactly one callback turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $histLog -Name 'turn/start') -eq 1) 'Historical enqueue did not send exactly once.'
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hHist -RunId $histRun) 'Historical run owner did not quiet.'
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hHist -ThreadId $tidHist) 'Historical thread owner did not quiet.'
        Assert-CasIntTelephoneResidueClear -StateRoot ([string]$hHist.state) -Label 'legacy-hist-completed'
        $script:legacyHistCompleted = 1
        Clear-CasIntTestEnv -Names @('TELEPHONE_TEST_APP_SERVER_EVENT_LOG')

        $hBusy = New-CasIntHarness -Name 'legacy-busy-at-enqueue'
        $null = Invoke-CasIntProfile -Harness $hBusy
        $bBusy = Invoke-CasIntBuilder -Harness $hBusy
        $tidBusy = [string]$bBusy.json.thread_id
        Add-CasIntStoreTurn -Harness $hBusy -ThreadId $tidBusy -TurnId 'turn-busy-hist' -Status 'completed' -StartedAt 1700000100 -CompletedAt 1700000101 -Text 'completed before busy enqueue'
        Add-CasIntStoreTurn -Harness $hBusy -ThreadId $tidBusy -TurnId 'turn-busy-owning' -Status 'inProgress' -StartedAt 1700000102 -Text 'active owning turn at enqueue'
        $busyLog = Join-Path $hBusy.root 'busy-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $busyLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $busyRun = 'run-legacy-busy-enqueue'
        $procBusy = Start-CasIntLauncherProcess -Harness $hBusy -ThreadId $tidBusy -RunId $busyRun
        Assert-CasInt (Wait-CasIntIntentBaselineContains -Harness $hBusy -RunId $busyRun -TurnIds @('turn-busy-hist', 'turn-busy-owning')) 'Busy-at-enqueue baseline omitted history or the active owning turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $busyLog -Name 'turn/start') -eq 0) 'Busy-at-enqueue sent before the owning turn completed.'
        Set-CasIntStoreTurnStatus -Harness $hBusy -ThreadId $tidBusy -TurnId 'turn-busy-owning' -Status 'completed'
        $wakeBusy = Complete-CasIntLauncherProcess -Proc $procBusy -TimeoutMs 90000
        Assert-CasInt ($wakeBusy.exit_code -eq 0) ("Busy-at-enqueue delivery failed: $($wakeBusy.stderr) $($wakeBusy.stdout)")
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hBusy -ThreadId $tidBusy -RunId $busyRun).Count -eq 1) 'Busy-at-enqueue did not deliver exactly one callback turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $busyLog -Name 'turn/start') -eq 1) 'Busy-at-enqueue did not send exactly once after the owning turn completed.'
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hBusy -RunId $busyRun) 'Busy-at-enqueue run owner did not quiet.'
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hBusy -ThreadId $tidBusy -TimeoutMs 20000) 'Busy-at-enqueue thread owner did not quiet.'
        Assert-CasIntTelephoneResidueClear -StateRoot ([string]$hBusy.state) -Label 'legacy-busy-at-enqueue'
        $script:legacyBusyAtEnqueue = 1
        Clear-CasIntTestEnv -Names @('TELEPHONE_TEST_APP_SERVER_EVENT_LOG')

        $hNoStore = New-CasIntHarness -Name 'legacy-nostore-live-owner'
        $null = Invoke-CasIntProfile -Harness $hNoStore
        $bNoStore = Invoke-CasIntBuilder -Harness $hNoStore
        $tidNoStore = [string]$bNoStore.json.thread_id
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hNoStore -ThreadId $tidNoStore) 'No-store builder thread owner did not quiet before admission.'
        Add-CasIntStoreTurn -Harness $hNoStore -ThreadId $tidNoStore -TurnId 'turn-nostore-hist' -Status 'completed' -StartedAt 1700000600 -CompletedAt 1700000601 -Text 'nostore historical turn'
        Add-CasIntStoreTurn -Harness $hNoStore -ThreadId $tidNoStore -TurnId 'turn-nostore-owning' -Status 'inProgress' -StartedAt 1700000602 -Text 'nostore active owning turn'
        $localStore = Join-Path $hNoStore.state 'app-server-store.json'
        $backendStore = Join-Path $hNoStore.root 'backend-store.json'
        Assert-CasInt ([IO.File]::Exists($localStore)) 'No-store case missing the mock backend before hide.'
        [IO.File]::Copy($localStore, $backendStore, $true)
        [IO.File]::Delete($localStore)
        Assert-CasInt (-not [IO.File]::Exists($localStore)) 'No-store case left a local App Server store file.'
        $env:TELEPHONE_TEST_APP_SERVER_STORE = $backendStore
        Remove-Item Env:TELEPHONE_TEST_APP_SERVER_NO_WATCHDOG -ErrorAction SilentlyContinue
        $dummyOwner = $null
        $procNoStore = $null
        try {
            $dummyInfo = [Diagnostics.ProcessStartInfo]::new()
            $dummyInfo.FileName = $pwsh
            $dummyInfo.UseShellExecute = $false
            $dummyInfo.CreateNoWindow = $true
            [void]$dummyInfo.ArgumentList.Add('-NoLogo')
            [void]$dummyInfo.ArgumentList.Add('-NoProfile')
            [void]$dummyInfo.ArgumentList.Add('-NonInteractive')
            [void]$dummyInfo.ArgumentList.Add('-Command')
            [void]$dummyInfo.ArgumentList.Add('Start-Sleep -Seconds 180')
            $dummyOwner = [Diagnostics.Process]::Start($dummyInfo)
            Assert-CasInt ($null -ne $dummyOwner -and [int]$dummyOwner.Id -gt 0) 'No-store live owner dummy failed to start.'
            $threadPathsNoStore = Get-CodexAppServerThreadPaths -StateRoot ([string]$hNoStore.state) -ThreadId $tidNoStore
            [IO.Directory]::CreateDirectory([string]$threadPathsNoStore.thread_root) | Out-Null
            $null = Write-TelephoneJsonReplace -Path ([string]$threadPathsNoStore.owner) -Value ([ordered]@{
                protocol_version = 'telephone-line-codex-app-server-lead-owner-v1'
                pid = [int]$dummyOwner.Id
                start_time_utc_ticks = [int64]$dummyOwner.StartTime.ToUniversalTime().Ticks
                started_at_utc = $dummyOwner.StartTime.ToUniversalTime().ToString('o')
                thread_id = [string]$tidNoStore
            })
            Assert-CasInt (Test-CasIntThreadOwnerAlive -Harness $hNoStore -ThreadId $tidNoStore) 'No-store case did not persist a live thread-owner record.'
            $noStoreLog = Join-Path $hNoStore.root 'nostore-events.log'
            $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $noStoreLog
            $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
            $noStoreRun = 'run-legacy-nostore-owner'
            $procNoStore = Start-CasIntLauncherProcess -Harness $hNoStore -ThreadId $tidNoStore -RunId $noStoreRun
            Assert-CasInt (Wait-CasIntIntentBaselineContains -Harness $hNoStore -RunId $noStoreRun -TurnIds @('turn-nostore-hist', 'turn-nostore-owning')) 'No-store live-owner admission omitted history or the active owning turn.'
            Assert-CasInt (-not [IO.File]::Exists($localStore)) 'No-store admission recreated a local store file.'
            Assert-CasInt ((Get-CasIntEventCount -Path $noStoreLog -Name 'turn/start') -eq 0) 'No-store live owner sent a callback while busy.'
            Assert-CasInt ((Get-CasIntProcessEventCount -Path $noStoreLog -Method 'turn/start') -eq 0) 'No-store live owner sent process turn/start while busy.'
            Assert-CasInt ((Get-CasIntProcessEventCount -Path $noStoreLog -Method 'thread/start') -eq 0) 'No-store admission started a competing thread/start.'
            Assert-CasInt ((Get-CasIntProcessEventCount -Path $noStoreLog -Method 'thread/resume') -eq 0) 'No-store admission called thread/resume against a live owner.'
            Assert-CasInt ((Get-CasIntProcessEventCount -Path $noStoreLog -Method 'thread/read') -ge 1) 'No-store admission did not perform a read-only thread/read snapshot.'
            Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hNoStore -ThreadId $tidNoStore -RunId $noStoreRun -StorePath $backendStore).Count -eq 0) 'No-store live owner created a callback turn while busy.'
            $noStoreRunDoc = Get-CasIntRunJson -Harness $hNoStore -RunId $noStoreRun
            $noStoreRunBaseline = @(Get-CodexAppServerStringList -Value (Get-CodexAppServerDictObject -Dict $noStoreRunDoc -Key 'baseline_turn_ids'))
            Assert-CasInt ($noStoreRunBaseline -contains 'turn-nostore-hist' -and $noStoreRunBaseline -contains 'turn-nostore-owning') 'No-store live-owner run baseline omitted history or the active owning turn.'
            Set-CasIntStoreTurnStatus -Harness $hNoStore -ThreadId $tidNoStore -TurnId 'turn-nostore-owning' -Status 'completed' -StorePath $backendStore
            [IO.File]::Copy($backendStore, $localStore, $true)
            try { Stop-Process -Id ([int]$dummyOwner.Id) -Force -ErrorAction SilentlyContinue } catch { }
            $wakeNoStore = Complete-CasIntLauncherProcess -Proc $procNoStore -TimeoutMs 90000
            $procNoStore = $null
            Assert-CasInt ($wakeNoStore.exit_code -eq 0) ("No-store delivery after owner completion failed: $($wakeNoStore.stderr) $($wakeNoStore.stdout)")
            Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hNoStore -ThreadId $tidNoStore -RunId $noStoreRun).Count -eq 1) 'No-store delivery did not create exactly one callback turn.'
            Assert-CasInt ((Get-CasIntEventCount -Path $noStoreLog -Name 'turn/start') -eq 1) 'No-store delivery did not send exactly once.'
            Assert-CasInt ((Get-CasIntProcessEventCount -Path $noStoreLog -Method 'thread/start') -eq 0) 'No-store delivery started a competing thread/start.'
            $noStoreStarts = @(Get-Content -LiteralPath $noStoreLog | Where-Object { [string]$_ -match '^process:\d+:turn/start$' })
            $noStorePids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($line in @($noStoreStarts)) {
                $pidMatch = [regex]::Match([string]$line, '^process:(\d+):')
                if ($pidMatch.Success) { [void]$noStorePids.Add([string]$pidMatch.Groups[1].Value) }
            }
            Assert-CasInt ($noStorePids.Count -eq 1) 'No-store delivery used more than one app-server client process.'
            Assert-CasInt (Wait-CasIntRunQuiet -Harness $hNoStore -RunId $noStoreRun) 'No-store run owner did not quiet.'
            Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hNoStore -ThreadId $tidNoStore -TimeoutMs 20000) 'No-store thread owner did not quiet.'
            $replayNoStore = Invoke-CasIntLauncher -Harness $hNoStore -ThreadId $tidNoStore -RunId $noStoreRun
            Assert-CasInt ($replayNoStore.exit_code -eq 0) ("No-store replay failed: $($replayNoStore.stderr) $($replayNoStore.stdout)")
            Assert-CasInt ([bool]$replayNoStore.json.existing -eq $true) 'No-store replay did not attach to the existing callback.'
            Assert-CasInt ([string]$replayNoStore.json.state -ceq 'completed') 'No-store replay lost the completed result.'
            Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hNoStore -ThreadId $tidNoStore -RunId $noStoreRun).Count -eq 1) 'No-store replay created a duplicate callback turn.'
            Assert-CasInt ((Get-CasIntEventCount -Path $noStoreLog -Name 'turn/start') -eq 1) 'No-store replay sent another wake.'
            Assert-CasInt (Wait-CasIntRunQuiet -Harness $hNoStore -RunId $noStoreRun) 'No-store replay left a live run owner.'
            Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hNoStore -ThreadId $tidNoStore -TimeoutMs 20000) 'No-store replay left a live thread owner.'
            Assert-CasIntTelephoneResidueClear -StateRoot ([string]$hNoStore.state) -Label 'legacy-nostore-live-owner'
            $script:legacyNoStoreLiveOwner = 1
        } finally {
            if ($null -ne $procNoStore) { $null = Complete-CasIntLauncherProcess -Proc $procNoStore -TimeoutMs 3000 }
            if ($null -ne $dummyOwner) {
                try { if (-not $dummyOwner.HasExited) { Stop-Process -Id ([int]$dummyOwner.Id) -Force -ErrorAction SilentlyContinue } } catch { }
                try { $dummyOwner.Dispose() } catch { }
            }
            $env:TELEPHONE_TEST_APP_SERVER_NO_WATCHDOG = '1'
        }
        Clear-CasIntTestEnv
        $env:TELEPHONE_TEST_APP_SERVER_NO_WATCHDOG = '1'
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $env:TELEPHONE_TEST_APP_SERVER_ACK_TIMEOUT_SECONDS = '90'

        $hUnproven = New-CasIntHarness -Name 'legacy-snapshot-unproven'
        $null = Invoke-CasIntProfile -Harness $hUnproven
        $bUnproven = Invoke-CasIntBuilder -Harness $hUnproven
        $tidUnproven = [string]$bUnproven.json.thread_id
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hUnproven -ThreadId $tidUnproven) 'Snapshot-unproven builder thread owner did not quiet.'
        Add-CasIntStoreTurn -Harness $hUnproven -ThreadId $tidUnproven -TurnId 'turn-unproven-hist' -Status 'completed' -StartedAt 1700000700 -CompletedAt 1700000701 -Text 'history the snapshot must not skip'
        $unprovenLocal = Join-Path $hUnproven.state 'app-server-store.json'
        $unprovenBackend = Join-Path $hUnproven.root 'unproven-backend-store.json'
        [IO.File]::Copy($unprovenLocal, $unprovenBackend, $true)
        [IO.File]::Delete($unprovenLocal)
        $env:TELEPHONE_TEST_APP_SERVER_STORE = $unprovenBackend
        $unprovenLog = Join-Path $hUnproven.root 'unproven-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $unprovenLog
        $env:TELEPHONE_TEST_APP_SERVER_CRASH_AT = 'after-thread-read'
        $unprovenRun = 'run-legacy-snapshot-unproven'
        $wakeUnproven = Invoke-CasIntLauncher -Harness $hUnproven -ThreadId $tidUnproven -RunId $unprovenRun
        Assert-CasInt ($wakeUnproven.exit_code -ne 0) 'Unproven admission snapshot started a worker loop.'
        Assert-CasInt ([string]$wakeUnproven.json.state -ceq 'failed') 'Unproven admission snapshot did not publish a failed result.'
        $unprovenPaths = Get-CodexAppServerRunPaths -StateRoot ([string]$hUnproven.state) -RunId $unprovenRun
        Assert-CasInt ([IO.File]::Exists($unprovenPaths.failure)) 'Unproven admission snapshot omitted the typed failure envelope.'
        $unprovenFail = (Read-TelephoneJson -Path $unprovenPaths.failure -SchemaName 'codex-app-server-lead-failure').value
        Assert-CasInt ([string]$unprovenFail.code -ceq 'worker_failed') 'Unproven admission snapshot failure code drifted.'
        Assert-CasInt ([IO.File]::Exists($unprovenPaths.result)) 'Unproven admission snapshot omitted launcher-result.json.'
        $unprovenResult = (Read-TelephoneJson -Path $unprovenPaths.result -SchemaName 'codex-app-server-lead-result').value
        Assert-CasInt ([string]$unprovenResult.state -ceq 'failed') 'Unproven admission snapshot result was not failed.'
        Assert-CasInt ([bool]$unprovenResult.started -eq $false) 'Unproven admission snapshot claimed a started turn.'
        $unprovenRunDoc = Get-CasIntRunJson -Harness $hUnproven -RunId $unprovenRun
        Assert-CasInt ([string]$unprovenRunDoc.queue_state -ceq 'retired') 'Unproven admission snapshot was not retired.'
        $unprovenTransitions = ''
        if ([IO.File]::Exists($unprovenPaths.transitions)) { $unprovenTransitions = [IO.File]::ReadAllText($unprovenPaths.transitions) }
        Assert-CasInt ($unprovenTransitions.IndexOf('admission_snapshot_unproven', [StringComparison]::Ordinal) -ge 0) 'Unproven admission omitted the durable admission_snapshot_unproven transition.'
        Assert-CasInt (-not [IO.File]::Exists($unprovenPaths.ack)) 'Unproven admission snapshot published an ack.'
        Assert-CasInt (-not [IO.File]::Exists($unprovenPaths.bound_turn)) 'Unproven admission snapshot published a bound-turn.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hUnproven -ThreadId $tidUnproven -RunId $unprovenRun -StorePath $unprovenBackend).Count -eq 0) 'Unproven admission snapshot created a callback turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $unprovenLog -Name 'turn/start') -eq 0) 'Unproven admission snapshot sent a callback.'
        Assert-CasInt ((Get-CasIntProcessEventCount -Path $unprovenLog -Method 'thread/start') -eq 0) 'Unproven admission snapshot started a competing thread/start.'
        Assert-CasInt ((Get-CasIntProcessEventCount -Path $unprovenLog -Method 'thread/resume') -eq 0) 'Unproven admission snapshot called thread/resume.'
        $startsBeforeUnprovenReplay = (Get-CasIntEventCount -Path $unprovenLog -Name 'turn/start')
        $replayUnproven = Invoke-CasIntLauncher -Harness $hUnproven -ThreadId $tidUnproven -RunId $unprovenRun
        Assert-CasInt ($replayUnproven.exit_code -ne 0) 'Unproven admission snapshot replay started a worker loop.'
        Assert-CasInt ([string]$replayUnproven.json.state -ceq 'failed') 'Unproven admission snapshot replay lost the typed failed result.'
        Assert-CasInt ((Get-CasIntEventCount -Path $unprovenLog -Name 'turn/start') -eq $startsBeforeUnprovenReplay) 'Unproven admission snapshot replay sent another turn.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hUnproven -ThreadId $tidUnproven -RunId $unprovenRun -StorePath $unprovenBackend).Count -eq 0) 'Unproven admission snapshot replay created a callback turn.'
        Assert-CasIntTelephoneResidueClear -StateRoot ([string]$hUnproven.state) -Label 'legacy-snapshot-unproven'
        $script:legacySnapshotUnproven = 1
        Clear-CasIntTestEnv
        $env:TELEPHONE_TEST_APP_SERVER_NO_WATCHDOG = '1'
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $env:TELEPHONE_TEST_APP_SERVER_ACK_TIMEOUT_SECONDS = '90'

        $hFifo = New-CasIntHarness -Name 'legacy-fifo-two'
        $null = Invoke-CasIntProfile -Harness $hFifo
        $bFifo = Invoke-CasIntBuilder -Harness $hFifo
        $tidFifo = [string]$bFifo.json.thread_id
        Add-CasIntStoreTurn -Harness $hFifo -ThreadId $tidFifo -TurnId 'turn-fifo-hist' -Status 'completed' -StartedAt 1700000200 -CompletedAt 1700000201 -Text 'fifo historical turn'
        Add-CasIntStoreTurn -Harness $hFifo -ThreadId $tidFifo -TurnId 'turn-fifo-owning' -Status 'inProgress' -StartedAt 1700000202 -Text 'fifo active owning turn'
        $fifoLog = Join-Path $hFifo.root 'fifo-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $fifoLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $fifoA = 'run-legacy-fifo-a'
        $fifoB = 'run-legacy-fifo-b'
        $procFifoA = Start-CasIntLauncherProcess -Harness $hFifo -ThreadId $tidFifo -RunId $fifoA
        $procFifoB = Start-CasIntLauncherProcess -Harness $hFifo -ThreadId $tidFifo -RunId $fifoB
        Assert-CasInt (Wait-CasIntIntentBaselineContains -Harness $hFifo -RunId $fifoA -TurnIds @('turn-fifo-hist', 'turn-fifo-owning')) 'First FIFO callback omitted the admission baseline.'
        Assert-CasInt (Wait-CasIntIntentBaselineContains -Harness $hFifo -RunId $fifoB -TurnIds @('turn-fifo-hist', 'turn-fifo-owning')) 'Second FIFO callback omitted the admission baseline.'
        $baseA = @(Get-CasIntIntentBaseline -Harness $hFifo -RunId $fifoA)
        $baseB = @(Get-CasIntIntentBaseline -Harness $hFifo -RunId $fifoB)
        Assert-CasInt ($baseA.Count -ge 2 -and $baseB.Count -ge 2) 'Near-simultaneous FIFO callbacks did not persist distinct non-empty baselines.'
        Set-CasIntStoreTurnStatus -Harness $hFifo -ThreadId $tidFifo -TurnId 'turn-fifo-owning' -Status 'completed'
        $wakeFifoA = Complete-CasIntLauncherProcess -Proc $procFifoA -TimeoutMs 90000
        $wakeFifoB = Complete-CasIntLauncherProcess -Proc $procFifoB -TimeoutMs 90000
        Assert-CasInt ($wakeFifoA.exit_code -eq 0) ("FIFO A failed: $($wakeFifoA.stderr) $($wakeFifoA.stdout)")
        Assert-CasInt ($wakeFifoB.exit_code -eq 0) ("FIFO B failed: $($wakeFifoB.stderr) $($wakeFifoB.stdout)")
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hFifo -ThreadId $tidFifo -RunId $fifoA).Count -eq 1) 'FIFO A did not deliver once.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hFifo -ThreadId $tidFifo -RunId $fifoB).Count -eq 1) 'FIFO B did not deliver once.'
        Assert-CasInt ((Get-CasIntEventCount -Path $fifoLog -Name 'turn/start') -eq 2) 'FIFO pair did not send exactly twice.'
        $fifoStarts = @(Get-Content -LiteralPath $fifoLog | Where-Object { $_ -match '^process:\d+:turn/start$' })
        $fifoPids = @($fifoStarts | ForEach-Object { [regex]::Match([string]$_, '^process:(\d+):').Groups[1].Value } | Select-Object -Unique)
        Assert-CasInt ($fifoPids.Count -eq 1) 'FIFO used more than one app-server client process.'
        $ackA = (Read-TelephoneJson -Path (Join-Path (Get-CasIntRunRoot -Harness $hFifo -RunId $fifoA) 'lead-wake-ack.json') -SchemaName 'codex-app-server-lead-ack').value
        $ackB = (Read-TelephoneJson -Path (Join-Path (Get-CasIntRunRoot -Harness $hFifo -RunId $fifoB) 'lead-wake-ack.json') -SchemaName 'codex-app-server-lead-ack').value
        Assert-CasInt ([string]$ackA.turn_id -cne [string]$ackB.turn_id) 'FIFO acks were not distinct turns.'
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hFifo -RunId $fifoA) 'FIFO A owner did not quiet.'
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hFifo -RunId $fifoB) 'FIFO B owner did not quiet.'
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hFifo -ThreadId $tidFifo -TimeoutMs 20000) 'FIFO thread owner did not quiet.'
        Assert-CasIntTelephoneResidueClear -StateRoot ([string]$hFifo.state) -Label 'legacy-fifo-two'
        $script:legacyFifoTwo = 1
        Clear-CasIntTestEnv -Names @('TELEPHONE_TEST_APP_SERVER_EVENT_LOG')

        $hRestart = New-CasIntHarness -Name 'legacy-restart-owner'
        $null = Invoke-CasIntProfile -Harness $hRestart
        $bRestart = Invoke-CasIntBuilder -Harness $hRestart
        $tidRestart = [string]$bRestart.json.thread_id
        Add-CasIntStoreTurn -Harness $hRestart -ThreadId $tidRestart -TurnId 'turn-restart-hist' -Status 'completed' -StartedAt 1700000300 -CompletedAt 1700000301 -Text 'restart historical turn'
        Add-CasIntStoreTurn -Harness $hRestart -ThreadId $tidRestart -TurnId 'turn-restart-owning' -Status 'inProgress' -StartedAt 1700000302 -Text 'restart active owning turn'
        $restartLog = Join-Path $hRestart.root 'restart-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $restartLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $restartRun = 'run-legacy-restart'
        $procRestart = Start-CasIntLauncherProcess -Harness $hRestart -ThreadId $tidRestart -RunId $restartRun
        Assert-CasInt (Wait-CasIntIntentBaselineContains -Harness $hRestart -RunId $restartRun -TurnIds @('turn-restart-hist', 'turn-restart-owning')) 'Restart admission did not persist the owning-turn baseline.'
        $restartBaseline = @(Get-CasIntIntentBaseline -Harness $hRestart -RunId $restartRun)
        Stop-CasIntRun -Harness $hRestart -RunId $restartRun
        $null = Complete-CasIntLauncherProcess -Proc $procRestart -TimeoutMs 15000
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hRestart -ThreadId $tidRestart) 'Killed restart owner did not quiet.'
        Set-CasIntStoreTurnStatus -Harness $hRestart -ThreadId $tidRestart -TurnId 'turn-restart-owning' -Status 'completed'
        $wakeRestart = Invoke-CasIntLauncher -Harness $hRestart -ThreadId $tidRestart -RunId $restartRun
        Assert-CasInt ($wakeRestart.exit_code -eq 0) ("Owner-replacement relaunch failed: $($wakeRestart.stderr) $($wakeRestart.stdout)")
        $restartBaselineAfter = @(Get-CasIntIntentBaseline -Harness $hRestart -RunId $restartRun)
        Assert-CasInt ($restartBaselineAfter.Count -eq $restartBaseline.Count) 'Restart mutated the persisted admission baseline.'
        foreach ($id in @($restartBaseline)) {
            Assert-CasInt ($restartBaselineAfter -contains [string]$id) ("Restart lost baseline turn $id.")
        }
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hRestart -ThreadId $tidRestart -RunId $restartRun).Count -eq 1) 'Restart relaunch did not deliver exactly one callback turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $restartLog -Name 'turn/start') -eq 1) 'Restart relaunch did not send exactly once.'
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hRestart -RunId $restartRun) 'Restart run owner did not quiet.'
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hRestart -ThreadId $tidRestart) 'Restart thread owner did not quiet.'
        Assert-CasIntTelephoneResidueClear -StateRoot ([string]$hRestart.state) -Label 'legacy-restart-owner'
        $script:legacyRestartOwner = 1
        Clear-CasIntTestEnv -Names @('TELEPHONE_TEST_APP_SERVER_EVENT_LOG')

        $hUnsafe = New-CasIntHarness -Name 'legacy-unsafe-empty'
        $null = Invoke-CasIntProfile -Harness $hUnsafe
        $bUnsafe = Invoke-CasIntBuilder -Harness $hUnsafe
        $tidUnsafe = [string]$bUnsafe.json.thread_id
        Add-CasIntStoreTurn -Harness $hUnsafe -ThreadId $tidUnsafe -TurnId 'turn-unsafe-hist' -Status 'completed' -Text 'untimestamped historical turn'
        $unsafeLog = Join-Path $hUnsafe.root 'unsafe-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $unsafeLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $unsafeRun = 'run-legacy-unsafe-empty'
        $safeRun = 'run-legacy-safe-after'
        $null = Write-CasIntPlantedIntent -Harness $hUnsafe -RunId $unsafeRun -ThreadId $tidUnsafe -Baseline @()
        Start-Sleep -Milliseconds 50
        $wakeSafeAfter = Invoke-CasIntLauncher -Harness $hUnsafe -ThreadId $tidUnsafe -RunId $safeRun
        Assert-CasInt ($wakeSafeAfter.exit_code -eq 0) ("Safe successor after unsafe legacy failed: $($wakeSafeAfter.stderr) $($wakeSafeAfter.stdout)")
        $unsafePaths = Get-CodexAppServerRunPaths -StateRoot ([string]$hUnsafe.state) -RunId $unsafeRun
        Assert-CasInt ([IO.File]::Exists($unsafePaths.failure)) 'Unsafe legacy empty-baseline omitted the typed failure envelope.'
        $unsafeFail = (Read-TelephoneJson -Path $unsafePaths.failure -SchemaName 'codex-app-server-lead-failure').value
        Assert-CasInt ([string]$unsafeFail.code -ceq 'worker_failed') 'Unsafe legacy failure code drifted.'
        Assert-CasInt ([string]$unsafeFail.category -ceq 'worker') 'Unsafe legacy failure category drifted.'
        Assert-CasInt ([IO.File]::Exists($unsafePaths.result)) 'Unsafe legacy omitted launcher-result.json.'
        $unsafeResult = (Read-TelephoneJson -Path $unsafePaths.result -SchemaName 'codex-app-server-lead-result').value
        Assert-CasInt ([string]$unsafeResult.state -ceq 'failed') 'Unsafe legacy result was not failed.'
        Assert-CasInt ([bool]$unsafeResult.started -eq $false) 'Unsafe legacy result claimed a started turn.'
        $unsafeRunDoc = Get-CasIntRunJson -Harness $hUnsafe -RunId $unsafeRun
        Assert-CasInt ([string]$unsafeRunDoc.queue_state -ceq 'retired') 'Unsafe legacy was not retired from FIFO.'
        $unsafeTransitions = ''
        if ([IO.File]::Exists($unsafePaths.transitions)) { $unsafeTransitions = [IO.File]::ReadAllText($unsafePaths.transitions) }
        Assert-CasInt ($unsafeTransitions.IndexOf('legacy_empty_baseline_terminal', [StringComparison]::Ordinal) -ge 0) 'Unsafe legacy omitted the durable legacy_empty_baseline_terminal transition.'
        Assert-CasInt (-not [IO.File]::Exists($unsafePaths.ack)) 'Unsafe legacy published an ack.'
        Assert-CasInt (-not [IO.File]::Exists($unsafePaths.bound_turn)) 'Unsafe legacy published a bound-turn.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hUnsafe -ThreadId $tidUnsafe -RunId $unsafeRun).Count -eq 0) 'Unsafe legacy created a callback turn.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hUnsafe -ThreadId $tidUnsafe -RunId $safeRun).Count -eq 1) 'Safe successor did not create exactly one callback turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $unsafeLog -Name 'turn/start') -eq 1) 'Unsafe-then-safe did not send exactly once.'
        $startsBeforeReplay = (Get-CasIntEventCount -Path $unsafeLog -Name 'turn/start')
        $replayUnsafe = Invoke-CasIntLauncher -Harness $hUnsafe -ThreadId $tidUnsafe -RunId $unsafeRun
        Assert-CasInt ($replayUnsafe.exit_code -ne 0) 'Unsafe legacy replay started a worker loop.'
        Assert-CasInt ([string]$replayUnsafe.json.state -ceq 'failed') 'Unsafe legacy replay lost the typed failed result.'
        Assert-CasInt ((Get-CasIntEventCount -Path $unsafeLog -Name 'turn/start') -eq $startsBeforeReplay) 'Unsafe legacy replay sent another turn.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hUnsafe -ThreadId $tidUnsafe -RunId $unsafeRun).Count -eq 0) 'Unsafe legacy replay created a callback turn.'
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hUnsafe -RunId $safeRun) 'Safe successor owner did not quiet.'
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hUnsafe -ThreadId $tidUnsafe) 'Unsafe-then-safe thread owner did not quiet.'
        Assert-CasIntTelephoneResidueClear -StateRoot ([string]$hUnsafe.state) -Label 'legacy-unsafe-empty'
        $script:legacyUnsafeEmpty = 1
        Clear-CasIntTestEnv -Names @('TELEPHONE_TEST_APP_SERVER_EVENT_LOG')

        $hPost = New-CasIntHarness -Name 'legacy-post-admission'
        $null = Invoke-CasIntProfile -Harness $hPost
        $bPost = Invoke-CasIntBuilder -Harness $hPost
        $tidPost = [string]$bPost.json.thread_id
        Add-CasIntStoreTurn -Harness $hPost -ThreadId $tidPost -TurnId 'turn-post-hist' -Status 'completed' -StartedAt 1700000400 -CompletedAt 1700000401 -Text 'admitted historical turn'
        Add-CasIntStoreTurn -Harness $hPost -ThreadId $tidPost -TurnId 'turn-post-owning' -Status 'inProgress' -StartedAt 1700000402 -Text 'hold send for post-admission unexplained'
        $postLog = Join-Path $hPost.root 'post-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $postLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $postRun = 'run-legacy-post-admission'
        $procPost = Start-CasIntLauncherProcess -Harness $hPost -ThreadId $tidPost -RunId $postRun
        Assert-CasInt (Wait-CasIntIntentBaselineContains -Harness $hPost -RunId $postRun -TurnIds @('turn-post-hist', 'turn-post-owning')) 'Post-admission case never captured a non-empty baseline.'
        Add-CasIntStoreTurn -Harness $hPost -ThreadId $tidPost -TurnId 'turn-post-unexplained' -Status 'completed' -StartedAt 1700000500 -CompletedAt 1700000501 -Text 'genuinely new unexplained turn after admission'
        Set-CasIntStoreTurnStatus -Harness $hPost -ThreadId $tidPost -TurnId 'turn-post-owning' -Status 'completed'
        $wakePost = Complete-CasIntLauncherProcess -Proc $procPost -TimeoutMs 90000
        Assert-CasInt ($wakePost.exit_code -ne 0) 'Post-admission unexplained turn did not fail closed.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hPost -ThreadId $tidPost -RunId $postRun).Count -eq 0) 'Post-admission unexplained turn created a callback turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $postLog -Name 'turn/start') -eq 0) 'Post-admission unexplained turn sent a callback.'
        $postRunDoc = Get-CasIntRunJson -Harness $hPost -RunId $postRun
        Assert-CasInt ([string]$postRunDoc.queue_state -cne 'retired') 'Post-admission unexplained turn was migrated instead of fail-closed.'
        Stop-CasIntRun -Harness $hPost -RunId $postRun
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hPost -ThreadId $tidPost) 'Post-admission thread owner did not quiet.'
        Assert-CasIntTelephoneResidueClear -StateRoot ([string]$hPost.state) -Label 'legacy-post-admission'
        $script:legacyPostAdmissionFailClosed = 1
        Clear-CasIntTestEnv

        $hLicensed = New-CasIntHarness -Name 'legacy-licensed-snapshot-extras'
        $null = Invoke-CasIntProfile -Harness $hLicensed
        $bLicensed = Invoke-CasIntBuilder -Harness $hLicensed
        $tidLicensed = [string]$bLicensed.json.thread_id
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hLicensed -ThreadId $tidLicensed) 'Licensed-extras builder thread owner did not quiet before admission.'
        Add-CasIntStoreTurn -Harness $hLicensed -ThreadId $tidLicensed -TurnId 'turn-licensed-hist' -Status 'completed' -StartedAt 1700000800 -CompletedAt 1700000801 -Text 'licensed extras historical turn'
        Add-CasIntStoreTurn -Harness $hLicensed -ThreadId $tidLicensed -TurnId 'turn-licensed-owning' -Status 'inProgress' -StartedAt 1700000802 -Text 'licensed extras active owning turn'
        Set-CasIntStoreThreadApprovedOptionalFields -Harness $hLicensed -ThreadId $tidLicensed
        $licensedLocal = Join-Path $hLicensed.state 'app-server-store.json'
        $licensedBackend = Join-Path $hLicensed.root 'licensed-backend-store.json'
        Assert-CasInt ([IO.File]::Exists($licensedLocal)) 'Licensed-extras case missing the mock backend before hide.'
        [IO.File]::Copy($licensedLocal, $licensedBackend, $true)
        [IO.File]::Delete($licensedLocal)
        Assert-CasInt (-not [IO.File]::Exists($licensedLocal)) 'Licensed-extras case left a local App Server store file.'
        $env:TELEPHONE_TEST_APP_SERVER_STORE = $licensedBackend
        Remove-Item Env:TELEPHONE_TEST_APP_SERVER_NO_WATCHDOG -ErrorAction SilentlyContinue
        $dummyLicensed = $null
        $procLicensed = $null
        try {
            $dummyInfoLicensed = [Diagnostics.ProcessStartInfo]::new()
            $dummyInfoLicensed.FileName = $pwsh
            $dummyInfoLicensed.UseShellExecute = $false
            $dummyInfoLicensed.CreateNoWindow = $true
            [void]$dummyInfoLicensed.ArgumentList.Add('-NoLogo')
            [void]$dummyInfoLicensed.ArgumentList.Add('-NoProfile')
            [void]$dummyInfoLicensed.ArgumentList.Add('-NonInteractive')
            [void]$dummyInfoLicensed.ArgumentList.Add('-Command')
            [void]$dummyInfoLicensed.ArgumentList.Add('Start-Sleep -Seconds 180')
            $dummyLicensed = [Diagnostics.Process]::Start($dummyInfoLicensed)
            Assert-CasInt ($null -ne $dummyLicensed -and [int]$dummyLicensed.Id -gt 0) 'Licensed-extras live owner dummy failed to start.'
            $threadPathsLicensed = Get-CodexAppServerThreadPaths -StateRoot ([string]$hLicensed.state) -ThreadId $tidLicensed
            [IO.Directory]::CreateDirectory([string]$threadPathsLicensed.thread_root) | Out-Null
            $null = Write-TelephoneJsonReplace -Path ([string]$threadPathsLicensed.owner) -Value ([ordered]@{
                protocol_version = 'telephone-line-codex-app-server-lead-owner-v1'
                pid = [int]$dummyLicensed.Id
                start_time_utc_ticks = [int64]$dummyLicensed.StartTime.ToUniversalTime().Ticks
                started_at_utc = $dummyLicensed.StartTime.ToUniversalTime().ToString('o')
                thread_id = [string]$tidLicensed
            })
            Assert-CasInt (Test-CasIntThreadOwnerAlive -Harness $hLicensed -ThreadId $tidLicensed) 'Licensed-extras case did not persist a live thread-owner record.'
            $licensedLog = Join-Path $hLicensed.root 'licensed-extras-events.log'
            $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $licensedLog
            $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
            $licensedRun = 'run-legacy-licensed-extras'
            $procLicensed = Start-CasIntLauncherProcess -Harness $hLicensed -ThreadId $tidLicensed -RunId $licensedRun
            Assert-CasInt (Wait-CasIntIntentBaselineContains -Harness $hLicensed -RunId $licensedRun -TurnIds @('turn-licensed-hist', 'turn-licensed-owning')) 'Licensed extras snapshot omitted history or the active owning turn.'
            Assert-CasInt (-not [IO.File]::Exists($licensedLocal)) 'Licensed extras admission recreated a local store file.'
            Assert-CasInt ((Get-CasIntEventCount -Path $licensedLog -Name 'turn/start') -eq 0) 'Licensed extras snapshot sent a callback while busy.'
            Assert-CasInt ((Get-CasIntProcessEventCount -Path $licensedLog -Method 'turn/start') -eq 0) 'Licensed extras snapshot sent process turn/start while busy.'
            Assert-CasInt ((Get-CasIntProcessEventCount -Path $licensedLog -Method 'thread/start') -eq 0) 'Licensed extras snapshot started a competing thread/start.'
            Assert-CasInt ((Get-CasIntProcessEventCount -Path $licensedLog -Method 'thread/resume') -eq 0) 'Licensed extras snapshot called thread/resume against a live owner.'
            Assert-CasInt ((Get-CasIntProcessEventCount -Path $licensedLog -Method 'thread/read') -ge 1) 'Licensed extras admission did not perform a read-only thread/read snapshot.'
            Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hLicensed -ThreadId $tidLicensed -RunId $licensedRun -StorePath $licensedBackend).Count -eq 0) 'Licensed extras snapshot created a callback turn while busy.'
            $licensedRunDoc = Get-CasIntRunJson -Harness $hLicensed -RunId $licensedRun
            $licensedRunBaseline = @(Get-CodexAppServerStringList -Value (Get-CodexAppServerDictObject -Dict $licensedRunDoc -Key 'baseline_turn_ids'))
            Assert-CasInt ($licensedRunBaseline -contains 'turn-licensed-hist' -and $licensedRunBaseline -contains 'turn-licensed-owning') 'Licensed extras run baseline omitted history or the active owning turn.'
            Set-CasIntStoreTurnStatus -Harness $hLicensed -ThreadId $tidLicensed -TurnId 'turn-licensed-owning' -Status 'completed' -StorePath $licensedBackend
            [IO.File]::Copy($licensedBackend, $licensedLocal, $true)
            try { Stop-Process -Id ([int]$dummyLicensed.Id) -Force -ErrorAction SilentlyContinue } catch { }
            $wakeLicensed = Complete-CasIntLauncherProcess -Proc $procLicensed -TimeoutMs 90000
            $procLicensed = $null
            Assert-CasInt ($wakeLicensed.exit_code -eq 0) ("Licensed extras delivery after owner completion failed: $($wakeLicensed.stderr) $($wakeLicensed.stdout)")
            Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hLicensed -ThreadId $tidLicensed -RunId $licensedRun).Count -eq 1) 'Licensed extras delivery did not create exactly one callback turn.'
            Assert-CasInt ((Get-CasIntEventCount -Path $licensedLog -Name 'turn/start') -eq 1) 'Licensed extras delivery did not send exactly once.'
            Assert-CasInt ((Get-CasIntProcessEventCount -Path $licensedLog -Method 'thread/start') -eq 0) 'Licensed extras delivery started a competing thread/start.'
            Assert-CasInt (Wait-CasIntRunQuiet -Harness $hLicensed -RunId $licensedRun) 'Licensed extras run owner did not quiet.'
            Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hLicensed -ThreadId $tidLicensed -TimeoutMs 20000) 'Licensed extras thread owner did not quiet.'
            Assert-CasIntTelephoneResidueClear -StateRoot ([string]$hLicensed.state) -Label 'legacy-licensed-snapshot-extras'
            $script:legacyLicensedSnapshotExtras = 1
        } finally {
            if ($null -ne $procLicensed) { $null = Complete-CasIntLauncherProcess -Proc $procLicensed -TimeoutMs 3000 }
            if ($null -ne $dummyLicensed) {
                try { if (-not $dummyLicensed.HasExited) { Stop-Process -Id ([int]$dummyLicensed.Id) -Force -ErrorAction SilentlyContinue } } catch { }
                try { $dummyLicensed.Dispose() } catch { }
            }
            $env:TELEPHONE_TEST_APP_SERVER_NO_WATCHDOG = '1'
        }
        Clear-CasIntTestEnv
        $env:TELEPHONE_TEST_APP_SERVER_NO_WATCHDOG = '1'
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $env:TELEPHONE_TEST_APP_SERVER_ACK_TIMEOUT_SECONDS = '90'

        $hUnlic = New-CasIntHarness -Name 'legacy-unlicensed-snapshot-extras'
        $null = Invoke-CasIntProfile -Harness $hUnlic
        $bUnlic = Invoke-CasIntBuilder -Harness $hUnlic
        $tidUnlic = [string]$bUnlic.json.thread_id
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hUnlic -ThreadId $tidUnlic) 'Unlicensed-extras builder thread owner did not quiet.'
        Add-CasIntStoreTurn -Harness $hUnlic -ThreadId $tidUnlic -TurnId 'turn-unlic-hist' -Status 'completed' -StartedAt 1700000900 -CompletedAt 1700000901 -Text 'unlicensed extras historical turn'
        Set-CasIntStoreThreadApprovedOptionalFields -Harness $hUnlic -ThreadId $tidUnlic -IncludeNullProjectId
        $unlicStore = Join-Path $hUnlic.state 'app-server-store.json'
        $plantedStoreText = [IO.File]::ReadAllText($unlicStore)
        Assert-CasInt ($plantedStoreText.IndexOf('turn-unlic-hist', [StringComparison]::Ordinal) -ge 0) 'Planted extras store omitted turn-unlic-hist.'
        Assert-CasInt ($plantedStoreText.IndexOf('canAcceptDirectInput', [StringComparison]::Ordinal) -ge 0) 'Planted extras store omitted canAcceptDirectInput.'
        Assert-CasInt ($plantedStoreText.IndexOf('"projectId": null', [StringComparison]::Ordinal) -ge 0) 'Planted extras store omitted null projectId.'
        $approvedLicense = New-CodexAppServerFrozenCompatibilityLicense -CodexVersion 'codex-cli 0.149.1'
        $driftedLicense = New-CodexAppServerFrozenCompatibilityLicense -CodexVersion 'codex-cli 0.149.1'
        $driftedLicense.schema_fingerprint = '0' * 64
        $unlicClient = $null
        $driftClient = $null
        $licClient = $null
        try {
            Invoke-CasIntExpectPublic -Code 'SCHEMA_OR_PROFILE_INVALID' -Message 'Unlicensed snapshot client was accepted without a profile.' -Action {
                $null = Invoke-CodexAppServerReadOnlyThreadSnapshot -CodexCommand $mock -Worktree ([string]$hUnlic.worktree) -ThreadId $tidUnlic -StorePath $unlicStore
            }
            $unlicClient = New-CodexAppServerClient -CodexCommand $mock -WorkingDirectory ([string]$hUnlic.worktree) -StorePath $unlicStore
            Initialize-CodexAppServerSession -Client $unlicClient
            Invoke-CasIntExpectPublic -Code 'SCHEMA_OR_PROFILE_INVALID' -Message 'Unlicensed thread/read admitted approved optional fields.' -Action {
                $null = Invoke-CodexAppServerThreadRead -Client $unlicClient -ThreadId $tidUnlic -IncludeTurns $true
            }
            try { Stop-CodexAppServerClient -Client $unlicClient } catch { }
            $unlicClient = $null
            $driftClient = New-CodexAppServerClient -CodexCommand $mock -WorkingDirectory ([string]$hUnlic.worktree) -StorePath $unlicStore
            $driftClient.compatibility_license = $driftedLicense
            Initialize-CodexAppServerSession -Client $driftClient
            Invoke-CasIntExpectPublic -Code 'SCHEMA_OR_PROFILE_INVALID' -Message 'Drifted snapshot license admitted approved optional fields.' -Action {
                $null = Invoke-CodexAppServerThreadRead -Client $driftClient -ThreadId $tidUnlic -IncludeTurns $true
            }
            try { Stop-CodexAppServerClient -Client $driftClient } catch { }
            $driftClient = $null
            $licClient = New-CodexAppServerClient -CodexCommand $mock -WorkingDirectory ([string]$hUnlic.worktree) -StorePath $unlicStore
            $licClient.compatibility_license = $approvedLicense
            Initialize-CodexAppServerSession -Client $licClient
            $licensedRead = Invoke-CodexAppServerThreadRead -Client $licClient -ThreadId $tidUnlic -IncludeTurns $true
            Assert-CasInt ([string]$licensedRead.thread_id -ceq $tidUnlic) 'Licensed extras thread/read lost the exact thread id.'
            $licensedThread = $licensedRead.thread
            Assert-CasInt ($licensedThread.Contains('canAcceptDirectInput')) 'Licensed extras thread/read omitted canAcceptDirectInput.'
            Assert-CasInt ($licensedThread.Contains('extra')) 'Licensed extras thread/read omitted extra.'
            Assert-CasInt ($licensedThread.Contains('historyMode')) 'Licensed extras thread/read omitted historyMode.'
            Assert-CasInt ($licensedThread.Contains('projectId')) 'Licensed extras thread/read omitted projectId.'
            Assert-CasInt (Test-CodexAppServerJsonNull -Value $licensedThread['projectId']) 'Licensed extras thread/read did not keep null projectId.'
            Assert-CasInt ([bool]$licensedThread['canAcceptDirectInput'] -eq $false) 'Licensed extras thread/read lost canAcceptDirectInput.'
            Assert-CasInt (Test-CodexAppServerJsonEmptyObject -Value $licensedThread['extra']) 'Licensed extras thread/read lost empty extra.'
            Assert-CasInt ([string]$licensedThread['historyMode'] -ceq 'legacy') 'Licensed extras thread/read lost historyMode.'
            $licensedIds = [Collections.Generic.List[string]]::new()
            foreach ($turn in (Get-CodexAppServerJsonArrayItems -Value (Get-CodexAppServerDictObject -Dict $licensedThread -Key 'turns'))) {
                $turnId = Get-CodexAppServerDictString -Dict $turn -Key 'id'
                if (-not [string]::IsNullOrWhiteSpace($turnId)) { $licensedIds.Add($turnId) }
            }
            Assert-CasInt ($licensedIds.Contains('turn-unlic-hist')) ("Licensed extras thread/read omitted the historical turn: " + [string]::Join(',', @($licensedIds)))
            $script:legacyUnlicensedSnapshotExtras = 1
        } finally {
            try { Stop-CodexAppServerClient -Client $unlicClient } catch { }
            try { Stop-CodexAppServerClient -Client $driftClient } catch { }
            try { Stop-CodexAppServerClient -Client $licClient } catch { }
        }
        Clear-CasIntTestEnv
        $env:TELEPHONE_TEST_APP_SERVER_NO_WATCHDOG = '1'
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $env:TELEPHONE_TEST_APP_SERVER_ACK_TIMEOUT_SECONDS = '90'

        $script:legacyZeroResidue = 1
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            legacy_history_baseline_only = $true
            hist_completed = [int]$script:legacyHistCompleted
            busy_at_enqueue = [int]$script:legacyBusyAtEnqueue
            nostore_live_owner = [int]$script:legacyNoStoreLiveOwner
            snapshot_unproven = [int]$script:legacySnapshotUnproven
            fifo_two = [int]$script:legacyFifoTwo
            restart_owner = [int]$script:legacyRestartOwner
            unsafe_empty_terminal = [int]$script:legacyUnsafeEmpty
            post_admission_fail_closed = [int]$script:legacyPostAdmissionFailClosed
            licensed_snapshot_optional_fields = [int]$script:legacyLicensedSnapshotExtras
            unlicensed_snapshot_optional_fields = [int]$script:legacyUnlicensedSnapshotExtras
            zero_residue = [int]$script:legacyZeroResidue
            automatic_variable_audit = [int]$script:legacyAutoVarAudit
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($BatchFanInOnly) {
        $script:batchCollectorCuts = [ordered]@{}
        $script:batchLaunchStartedAtUtc = [ordered]@{}
        $script:batchLaunchSpanMs = 0
        $script:batchFiveOfSix = 0
        $script:batchSixBusyNoMarker = 0
        $script:batchOneDeliveryOnce = 0
        $script:batchRetryOnce = 0
        $script:batchRaceOnce = 0
        $script:batchCollectorRestartOnce = 0
        $script:batchNegativesClosed = 0
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $env:TELEPHONE_TEST_COLLECTOR_IDLE_MS = '8000'
        $starter = Join-Path $runtimeRepoRoot 'src\core\Start-TelephoneLineJob.ps1'
        $resumeScript = Join-Path $runtimeRepoRoot 'src\core\Resume-TelephoneLines.ps1'
        $relayScript = Join-Path $runtimeRepoRoot 'src\core\Invoke-TelephoneLineRelay.ps1'
        $mockRoute = Join-Path $repoRoot 'tests\core\fixtures\mock-route.ps1'
        . (Join-Path $runtimeRepoRoot 'src\dashboard\TelephoneDashboard.Common.ps1')
        . (Join-Path $runtimeRepoRoot 'src\dashboard\TelephoneDashboard.Projection.ps1')

        $hFan = New-CasIntHarness -Name 'batch-fan-in'
        $null = Invoke-CasIntProfile -Harness $hFan
        $bFan = Invoke-CasIntBuilder -Harness $hFan
        $tidFan = [string]$bFan.json.thread_id
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace($tidFan)) 'Batch fan-in did not bind a thread.'
        $fanTurn = 'turn-fanin-owning-1'
        $fanHold = Join-Path $hFan.root 'release-fanin-owning'
        $fanLog = Join-Path $hFan.root 'fanin-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $fanLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '30000'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_TURN_ID = $fanTurn
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_HOLD_PATH = $fanHold
        $telState = Join-Path $hFan.root 'telephone-state'
        [IO.Directory]::CreateDirectory($telState) | Out-Null
        $bindingFan = (Read-TelephoneJson -Path ([string]$hFan.binding) -SchemaName 'lead-binding').value
        $leadKey = Get-CasIntFanInLeadKey -Binding $bindingFan
        $batchId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $packageIds = @('pkg-success-1', 'pkg-success-2', 'pkg-exec-fail', 'pkg-start-failed', 'pkg-success-3', 'pkg-missing')
        $counters = @{}
        foreach ($packageId in $packageIds) { $counters[$packageId] = Join-Path $hFan.root ('count-' + $packageId + '.txt') }
        $missingHold = Join-Path $hFan.root 'release-pkg-missing'
        $launch = Start-CasIntFanInJobsNearSimultaneous -Harness $hFan -TelState $telState -Starter $starter -MockRoute $mockRoute -Binding $bindingFan -BatchId $batchId -PackageIds $packageIds -Specs @(
            @{ id = 'pkg-success-1'; exit = 0; fail = $false; counter = [string]$counters['pkg-success-1'] },
            @{ id = 'pkg-success-2'; exit = 0; fail = $false; counter = [string]$counters['pkg-success-2'] },
            @{ id = 'pkg-exec-fail'; exit = 2; fail = $false; counter = [string]$counters['pkg-exec-fail'] },
            @{ id = 'pkg-start-failed'; exit = 0; fail = $true; counter = [string]$counters['pkg-start-failed'] },
            @{ id = 'pkg-success-3'; exit = 0; fail = $false; counter = [string]$counters['pkg-success-3'] },
            @{ id = 'pkg-missing'; exit = 0; fail = $false; counter = [string]$counters['pkg-missing']; hold_path = $missingHold }
        )
        $jobs = $launch.jobs
        $script:batchLaunchStartedAtUtc = [ordered]@{}
        foreach ($packageId in $packageIds) {
            $stamp = [string]$launch.launch_started_at_utc[$packageId]
            Assert-CasInt (-not [string]::IsNullOrWhiteSpace($stamp)) ("Six-route launch omitted OS start timestamp for $packageId.")
            $parsed = [datetimeoffset]::MinValue
            Assert-CasInt ([datetimeoffset]::TryParse($stamp, [ref]$parsed) -and $parsed -gt [datetimeoffset]::UnixEpoch) ("Six-route launch timestamp was invalid for $packageId : $stamp")
            $script:batchLaunchStartedAtUtc[$packageId] = $stamp
        }
        Assert-CasInt ($script:batchLaunchStartedAtUtc.Count -eq 6) 'Six-route launch did not keep six keyed OS start timestamps.'
        $script:batchLaunchSpanMs = [int]$launch.launch_span_ms
        Assert-CasInt ($script:batchLaunchSpanMs -ge 0 -and $script:batchLaunchSpanMs -le 3000) ("Six-route OS launch span exceeded 3000 ms: $($script:batchLaunchSpanMs) ms")
        $mailbox = Get-CasIntFanInMailbox -TelState $telState -LeadKey $leadKey
        $batchPaths = Get-TelephoneBatchPaths -MailboxPaths $mailbox -BatchId $batchId
        $missingPaths = Get-TelephoneJobPaths -JobRoot ([string]$jobs['pkg-missing'].job_root)
        Assert-CasInt (Wait-CasIntPath -Path $missingPaths.dispatch -TimeoutMs 20000) 'Missing package never froze dispatch ownership.'
        Assert-CasInt (Wait-CasIntPath -Path $missingPaths.command_start_intent -TimeoutMs 20000) 'Missing package never froze command-start ownership.'
        Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 20000 -Predicate {
            return ([IO.File]::Exists($missingPaths.command_owner) -or [IO.File]::Exists($missingPaths.command_launch))
        }) 'Missing package never froze command-owner identity.'
        Assert-CasInt (Wait-CasIntFanInCounted -Mailbox $mailbox -BatchId $batchId -Counted 5) 'Batch fan-in never reached 5/6.'
        $collectionFive = (Read-TelephoneJson -Path $batchPaths.collection).value
        Assert-CasInt ([int]$collectionFive.counted -eq 5 -and [int]$collectionFive.n -eq 6) '5/6 collection denominator drifted.'
        Assert-CasInt ([bool]$collectionFive.closed -eq $false) '5/6 closed the batch early.'
        Assert-CasInt ([bool]$collectionFive.acceptance_eligible -eq $false) '5/6 set acceptance eligibility.'
        $missingFive = @($collectionFive.missing | ForEach-Object { [string]$_.package_id })
        Assert-CasInt ($missingFive.Count -eq 1 -and [string]$missingFive[0] -ceq 'pkg-missing') '5/6 missing identity was not pkg-missing.'
        $missingRow = @($collectionFive.missing)[0]
        Assert-CasInt ([string]$missingRow.line_job_id -ceq [string]$jobs['pkg-missing'].line_job_id) '5/6 missing line-job ownership drifted.'
        Assert-CasInt ([string]$missingRow.route -ceq 'mock-route') '5/6 missing route ownership drifted.'
        Assert-CasInt ([string]$missingRow.job_root -ceq [string]$jobs['pkg-missing'].job_root) '5/6 missing job-root ownership drifted.'
        Assert-CasInt ([bool]$missingRow.receipt_present -eq $false) '5/6 missing package already had a receipt.'
        Assert-CasInt (-not [IO.File]::Exists($missingPaths.receipt)) '5/6 missing package published a receipt.'
        Assert-CasInt ((Get-CasIntCounterCount -Path ([string]$counters['pkg-missing'])) -eq 0) '5/6 missing package invoked the route before recovery.'
        $itemsFive = @(Get-TelephoneMailboxItems -MailboxPaths $mailbox | Where-Object { [string]$_.batch_id -ceq $batchId })
        Assert-CasInt ($itemsFive.Count -eq 5) ("5/6 mailbox item count=$($itemsFive.Count)")
        $seqs = @($itemsFive | ForEach-Object { [int]$_.sequence })
        Assert-CasInt ((@($seqs | Sort-Object -Unique)).Count -eq 5) '5/6 mailbox sequences were not unique FIFO values.'
        Assert-CasInt (-not [IO.File]::Exists($batchPaths.manifest)) '5/6 published a closed manifest.'
        Assert-CasInt (-not [IO.File]::Exists($batchPaths.wake_attempt)) '5/6 published a wake attempt.'
        $wakeRunId = 'telephone-batch-' + $batchId
        Assert-CasInt (-not [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hFan -RunId $wakeRunId) 'intent.json'))) '5/6 persisted a batch wake intent.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hFan -ThreadId $tidFan -RunId $wakeRunId).Count -eq 0) '5/6 started a marker turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $fanLog -Name 'turn/start') -eq 0) '5/6 sent turn/start.'
        foreach ($packageId in @('pkg-success-1', 'pkg-success-2', 'pkg-exec-fail', 'pkg-start-failed', 'pkg-success-3')) {
            $job = $jobs[$packageId]
            $paths = Get-TelephoneJobPaths -JobRoot ([string]$job.job_root)
            Assert-CasInt (-not [IO.File]::Exists($paths.delivery)) ("5/6 delivered $packageId.")
            Assert-CasInt (-not [IO.File]::Exists($paths.relay_error)) ("5/6 published relay-error for $packageId.")
        }
        Assert-CasInt ((Get-CasIntCounterCount -Path ([string]$counters['pkg-success-1'])) -eq 1) 'Completed success-1 command count drifted at 5/6.'
        Assert-CasInt ((Get-CasIntCounterCount -Path ([string]$counters['pkg-success-2'])) -eq 1) 'Completed success-2 command count drifted at 5/6.'
        Assert-CasInt ((Get-CasIntCounterCount -Path ([string]$counters['pkg-exec-fail'])) -eq 1) 'Explicit-failure command count drifted at 5/6.'
        Assert-CasInt ((Get-CasIntCounterCount -Path ([string]$counters['pkg-success-3'])) -eq 1) 'Completed success-3 command count drifted at 5/6.'
        Assert-CasInt ((Get-CasIntCounterCount -Path ([string]$counters['pkg-start-failed'])) -eq 0) 'START_FAILED invoked the route.'
        $stFive = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @('-StateRoot', [string]$hFan.state, '-RunId', $wakeRunId, '-TelephoneStateRoot', $telState)
        Assert-CasInt ($stFive.exit_code -eq 0) ("Status at 5/6 failed: $($stFive.stderr)")
        Assert-CasInt ($stFive.json.mutated -eq $false) 'Status mutated durable state at 5/6.'
        $truthFive = @($stFive.json.batches | Where-Object { [string]$_.batch_id -ceq $batchId })
        Assert-CasInt ($truthFive.Count -eq 1 -and [int]$truthFive[0].counted -eq 5) 'Status omitted collecting 5/6 truth.'
        $statusMissing = @($truthFive[0].missing | ForEach-Object { [string]$_.package_id })
        if ($statusMissing.Count -eq 0) { $statusMissing = @($truthFive[0].missing_package_ids | ForEach-Object { [string]$_ }) }
        Assert-CasInt ($statusMissing -contains 'pkg-missing') 'Status omitted exact missing ownership.'
        $scanFive = Get-TelephoneDashboardJobScan -JobRoot ([string]$jobs['pkg-success-1'].job_root)
        $codesFive = @($scanFive.findings | ForEach-Object { [string]$_.code })
        Assert-CasInt ($codesFive -contains 'CALLBACK_MISSING') 'Dashboard hid collecting callback pending.'
        Assert-CasInt ($codesFive -notcontains 'LOST_RELAY') 'Dashboard classified collecting as lost relay.'
        $script:batchFiveOfSix = 1

        [IO.File]::WriteAllText($missingHold, "release`n", [Text.UTF8Encoding]::new($false))
        Assert-CasInt (Wait-CasIntFanInCounted -Mailbox $mailbox -BatchId $batchId -Counted 6) 'Missing-only recovery never reached 6/6.'
        Assert-CasInt ((Get-CasIntCounterCount -Path ([string]$counters['pkg-success-1'])) -eq 1) 'Missing recovery reran a completed success package.'
        Assert-CasInt ((Get-CasIntCounterCount -Path ([string]$counters['pkg-exec-fail'])) -eq 1) 'Missing recovery reran the explicit-failure package.'
        Assert-CasInt ((Get-CasIntCounterCount -Path ([string]$counters['pkg-start-failed'])) -eq 0) 'Missing recovery invoked START_FAILED.'
        Assert-CasInt ((Get-CasIntCounterCount -Path ([string]$counters['pkg-missing'])) -eq 1) 'Missing package command count was not one.'
        Assert-CasInt (Wait-CasIntPath -Path $batchPaths.manifest -TimeoutMs 40000) '6/6 did not publish one closed manifest while busy.'
        $manifestOne = Read-TelephoneJson -Path $batchPaths.manifest -SchemaName 'telephone-line-batch'
        $manifestBytes = Get-CasIntFileFingerprint -Path $batchPaths.manifest
        Assert-CasInt ([bool]$manifestOne.value.closed -eq $true -and [int]$manifestOne.value.counted -eq 6) 'Closed manifest counted/closed drifted.'
        Assert-CasInt ([string]$manifestOne.value.wake_run_id -ceq $wakeRunId) 'Batch wake_run_id drifted.'
        $fifoHashes = @($manifestOne.value.items | ForEach-Object { [string]$_.receipt.sha256 })
        Assert-CasInt ($fifoHashes.Count -eq 6) 'Closed manifest did not list six receipt hashes.'
        Assert-CasInt ((@($fifoHashes | Select-Object -Unique)).Count -eq 6) 'Closed manifest receipt hashes were not unique.'
        foreach ($item in @($manifestOne.value.items)) {
            Assert-CasInt ([string]$item.lead_identity_sha256 -ceq $leadKey) ("Closed manifest used a non-frozen Lead identity for $($item.package_id).")
            Assert-CasInt ([string]$item.lead_session_id -ceq [string]$bindingFan.session_id) ("Closed manifest omitted per-item session identity for $($item.package_id).")
            Assert-CasInt (-not [string]::IsNullOrWhiteSpace([string]$item.lead_launcher_path)) ("Closed manifest omitted per-item launcher identity for $($item.package_id).")
            Assert-CasInt ($null -ne $item.profile -and [string]$item.profile.sha256 -cmatch '^[0-9a-f]{64}$') ("Closed manifest omitted per-item profile identity for $($item.package_id).")
            Assert-CasInt ($null -ne $item.dispatch -and $null -ne $item.receipt) ("Closed manifest omitted dispatch/receipt identity for $($item.package_id).")
        }
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hFan -ThreadId $tidFan -RunId $wakeRunId).Count -eq 0) '6/6 while busy started a marker turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $fanLog -Name 'turn/start') -eq 0) '6/6 while busy sent turn/start.'
        foreach ($packageId in $packageIds) {
            $paths = Get-TelephoneJobPaths -JobRoot ([string]$jobs[$packageId].job_root)
            Assert-CasInt (-not [IO.File]::Exists($paths.delivery)) ("Busy 6/6 delivered $packageId.")
        }
        $stSix = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @('-StateRoot', [string]$hFan.state, '-RunId', $wakeRunId, '-TelephoneStateRoot', $telState)
        Assert-CasInt ($stSix.exit_code -eq 0) 'Status at busy 6/6 failed.'
        $truthSix = @($stSix.json.batches | Where-Object { [string]$_.batch_id -ceq $batchId })
        Assert-CasInt ($truthSix.Count -eq 1 -and [bool]$truthSix[0].closed -eq $true) 'Status omitted closed-queued-behind-busy truth.'
        $script:batchSixBusyNoMarker = 1

        [IO.File]::WriteAllText($fanHold, "release`n", [Text.UTF8Encoding]::new($false))
        $allDelivered = Wait-CasIntPredicate -TimeoutMs 90000 -Predicate {
            foreach ($packageId in $packageIds) {
                $paths = Get-TelephoneJobPaths -JobRoot ([string]$jobs[$packageId].job_root)
                if (-not [IO.File]::Exists($paths.delivery)) { return $false }
            }
            return $true
        }
        Assert-CasInt $allDelivered 'Batch release never delivered all six jobs.'
        Assert-CasInt (Wait-CasIntPath -Path (Join-Path (Get-CasIntRunRoot -Harness $hFan -RunId $wakeRunId) 'lead-wake-ack.json') -TimeoutMs 30000) 'Batch callback never published ack.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hFan -ThreadId $tidFan -RunId $wakeRunId).Count -eq 1) 'Batch release did not produce exactly one marker turn.'
        $startEventsDone = @(Get-Content -LiteralPath $fanLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($startEventsDone.Count -eq 1) 'Batch release did not send exactly one turn/start.'
        $deliveredHashes = [Collections.Generic.List[string]]::new()
        foreach ($item in @($manifestOne.value.items)) {
            $paths = Get-TelephoneJobPaths -JobRoot ([string]$jobs[[string]$item.package_id].job_root)
            $delivery = (Read-TelephoneJson -Path $paths.delivery).value
            Assert-CasInt ([string]$delivery.wake_run_id -ceq $wakeRunId) ("Delivery wake_run_id drifted for $($item.package_id).")
            Assert-CasInt ($null -ne $delivery.wake_acknowledgment) ("Delivery omitted ack for $($item.package_id).")
            [void]$deliveredHashes.Add([string]$item.receipt.sha256)
        }
        Assert-CasInt ((@($deliveredHashes) -join '|') -ceq (@($fifoHashes) -join '|')) 'Delivered receipt hashes were not mailbox FIFO order.'
        Assert-CasInt ((Get-CasIntFileFingerprint -Path $batchPaths.manifest) -ceq $manifestBytes) 'Batch-one manifest bytes changed after delivery.'
        Stop-CasIntTelephoneState -StateRoot $telState
        Assert-CasIntTelephoneResidueClear -StateRoot $telState -Label 'batch-fan-in 6/6'
        Stop-CasIntRun -Harness $hFan -RunId $wakeRunId
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hFan -ThreadId $tidFan -TimeoutMs 25000) 'Batch thread owner did not quiesce.'
        $script:batchOneDeliveryOnce = 1
        Clear-CasIntTestEnv

        $hRetry = New-CasIntHarness -Name 'batch-fan-in-retry'
        $null = Invoke-CasIntProfile -Harness $hRetry
        $bRetry = Invoke-CasIntBuilder -Harness $hRetry
        $tidRetry = [string]$bRetry.json.thread_id
        $retryHold = Join-Path $hRetry.root 'release-retry-owning'
        $retryLog = Join-Path $hRetry.root 'retry-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $retryLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '20000'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_TURN_ID = 'turn-retry-owning'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_HOLD_PATH = $retryHold
        $telRetry = Join-Path $hRetry.root 'telephone-state'
        [IO.Directory]::CreateDirectory($telRetry) | Out-Null
        $bindingRetry = (Read-TelephoneJson -Path ([string]$hRetry.binding) -SchemaName 'lead-binding').value
        $leadKeyRetry = Get-CasIntFanInLeadKey -Binding $bindingRetry
        $batchRetry = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $retryIds = @('pkg-exec-fail', 'pkg-start-failed')
        $retryJobs = [ordered]@{}
        $retryJobs['pkg-exec-fail'] = Start-CasIntFanInJob -Harness $hRetry -TelState $telRetry -Starter $starter -MockRoute $mockRoute -Binding $bindingRetry -BatchId $batchRetry -PackageIds $retryIds -PackageId 'pkg-exec-fail' -N 2 -ExitCode 2 -CounterPath (Join-Path $hRetry.root 'retry-exec.txt') -RetryOf $batchId
        $retryJobs['pkg-start-failed'] = Start-CasIntFanInJob -Harness $hRetry -TelState $telRetry -Starter $starter -MockRoute $mockRoute -Binding $bindingRetry -BatchId $batchRetry -PackageIds $retryIds -PackageId 'pkg-start-failed' -N 2 -CounterPath (Join-Path $hRetry.root 'retry-start.txt') -RetryOf $batchId -ForceStartFailed
        $mailboxRetry = Get-CasIntFanInMailbox -TelState $telRetry -LeadKey $leadKeyRetry
        $retryPaths = Get-TelephoneBatchPaths -MailboxPaths $mailboxRetry -BatchId $batchRetry
        Assert-CasInt (Wait-CasIntFanInCounted -Mailbox $mailboxRetry -BatchId $batchRetry -Counted 2) 'Retry batch never reached 2/2.'
        Assert-CasInt (Wait-CasIntPath -Path $retryPaths.manifest -TimeoutMs 40000) 'Retry batch omitted its closed manifest.'
        $retryWake = 'telephone-batch-' + $batchRetry
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hRetry -ThreadId $tidRetry -RunId $retryWake).Count -eq 0) 'Retry batch woke while busy.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hFan -ThreadId $tidFan -RunId $wakeRunId).Count -eq 1) 'Retry batch re-woke batch one.'
        Assert-CasInt ((Get-CasIntFileFingerprint -Path $batchPaths.manifest) -ceq $manifestBytes) 'Retry batch mutated batch-one manifest bytes.'
        [IO.File]::WriteAllText($retryHold, "release`n", [Text.UTF8Encoding]::new($false))
        Assert-CasInt (Wait-CasIntPath -Path (Join-Path (Get-CasIntRunRoot -Harness $hRetry -RunId $retryWake) 'lead-wake-ack.json') -TimeoutMs 60000) 'Retry batch never published ack.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hRetry -ThreadId $tidRetry -RunId $retryWake).Count -eq 1) 'Retry batch did not produce exactly one later wake.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hFan -ThreadId $tidFan -RunId $wakeRunId).Count -eq 1) 'Retry wake replaced batch one.'
        $retryStarts = @(Get-Content -LiteralPath $retryLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($retryStarts.Count -eq 1) 'Retry batch sent more than one turn/start.'
        Stop-CasIntTelephoneState -StateRoot $telRetry
        Assert-CasIntTelephoneResidueClear -StateRoot $telRetry -Label 'batch-fan-in retry'
        Stop-CasIntRun -Harness $hRetry -RunId $retryWake
        $script:batchRetryOnce = 1
        Clear-CasIntTestEnv

        $hRace = New-CasIntHarness -Name 'batch-fan-in-race'
        $null = Invoke-CasIntProfile -Harness $hRace
        $bRace = Invoke-CasIntBuilder -Harness $hRace
        $tidRace = [string]$bRace.json.thread_id
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '20000'
        $telRace = Join-Path $hRace.root 'telephone-state'
        [IO.Directory]::CreateDirectory($telRace) | Out-Null
        $bindingRace = (Read-TelephoneJson -Path ([string]$hRace.binding) -SchemaName 'lead-binding').value
        $leadKeyRace = Get-CasIntFanInLeadKey -Binding $bindingRace
        $jobRace = Start-CasIntFanInJob -Harness $hRace -TelState $telRace -Starter $starter -MockRoute $mockRoute -Binding $bindingRace -BatchId ([guid]::NewGuid().ToString('D').ToLowerInvariant()) -PackageIds @('pkg-race') -PackageId 'pkg-race' -N 1 -CounterPath (Join-Path $hRace.root 'race-count.txt')
        $pathsRace = Get-TelephoneJobPaths -JobRoot ([string]$jobRace.job_root)
        Assert-CasInt (Wait-CasIntPath -Path $pathsRace.receipt -TimeoutMs 30000) 'Race job never published a receipt.'
        $procResumeA = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $resumeScript, '-StateRoot', $telRace) -WindowStyle Hidden -PassThru
        $procResumeB = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $resumeScript, '-StateRoot', $telRace) -WindowStyle Hidden -PassThru
        $procColA = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $relayScript, '-Collector', '-StateRoot', $telRace, '-LeadKey', $leadKeyRace) -WindowStyle Hidden -PassThru
        $procColB = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $relayScript, '-Collector', '-StateRoot', $telRace, '-LeadKey', $leadKeyRace) -WindowStyle Hidden -PassThru
        Assert-CasInt (Wait-CasIntPath -Path $pathsRace.delivery -TimeoutMs 60000) 'Raced collector/resume never delivered.'
        $null = $procResumeA.WaitForExit(20000)
        $null = $procResumeB.WaitForExit(20000)
        $null = $procColA.WaitForExit(20000)
        $null = $procColB.WaitForExit(20000)
        $procResumeA.Dispose(); $procResumeB.Dispose(); $procColA.Dispose(); $procColB.Dispose()
        $wakeRace = 'telephone-' + [string]$jobRace.line_job_id
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hRace -ThreadId $tidRace -RunId $wakeRace).Count -eq 1) 'Race did not converge to one marker turn.'
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hRace.root 'race-count.txt')) -eq 1) 'Race reran the executor.'
        Stop-CasIntTelephoneState -StateRoot $telRace
        Assert-CasIntTelephoneResidueClear -StateRoot $telRace -Label 'batch-fan-in race'
        Stop-CasIntRun -Harness $hRace -RunId $wakeRace
        $script:batchRaceOnce = 1
        Clear-CasIntTestEnv

        foreach ($cut in @('owner_claim', 'collection', 'manifest', 'send', 'ack', 'delivery')) {
            $hCut = New-CasIntHarness -Name ('batch-fan-in-cut-' + $cut)
            $null = Invoke-CasIntProfile -Harness $hCut
            $bCut = Invoke-CasIntBuilder -Harness $hCut
            $tidCut = [string]$bCut.json.thread_id
            $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '20000'
            $env:TELEPHONE_TEST_COLLECTOR_CRASH_AFTER = $cut
            $telCut = Join-Path $hCut.root 'telephone-state'
            [IO.Directory]::CreateDirectory($telCut) | Out-Null
            $bindingCut = (Read-TelephoneJson -Path ([string]$hCut.binding) -SchemaName 'lead-binding').value
            $jobCut = Start-CasIntFanInJob -Harness $hCut -TelState $telCut -Starter $starter -MockRoute $mockRoute -Binding $bindingCut -BatchId ([guid]::NewGuid().ToString('D').ToLowerInvariant()) -PackageIds @('pkg-cut') -PackageId 'pkg-cut' -N 1 -CounterPath (Join-Path $hCut.root 'cut-count.txt')
            $pathsCut = Get-TelephoneJobPaths -JobRoot ([string]$jobCut.job_root)
            Assert-CasInt (Wait-CasIntPath -Path $pathsCut.receipt -TimeoutMs 30000) ("Cut $cut never published a receipt.")
            Assert-CasInt (Wait-CasIntPath -Path $pathsCut.mailbox_ref -TimeoutMs 20000) ("Cut $cut never enqueued.")
            $leadKeyCut = Get-CasIntFanInLeadKey -Binding $bindingCut
            $mailboxCut = Get-CasIntFanInMailbox -TelState $telCut -LeadKey $leadKeyCut
            $batchCutId = [string]((Read-TelephoneJson -Path $pathsCut.dispatch).value.batch.batch_id)
            $batchCutPaths = Get-TelephoneBatchPaths -MailboxPaths $mailboxCut -BatchId $batchCutId
            $cutWaitPath = switch ($cut) {
                'owner_claim' { [string]$mailboxCut.owner }
                'collection' { [string]$batchCutPaths.collection }
                'manifest' { [string]$batchCutPaths.manifest }
                'send' { [string]$pathsCut.wake_attempt }
                'ack' { [string]$pathsCut.wake_launch_result }
                default { [string]$pathsCut.delivery }
            }
            $null = Wait-CasIntPath -Path $cutWaitPath -TimeoutMs 15000
            $crashMarker = Join-Path ([string]$mailboxCut.lead_root) ('.collector-crash-' + ($cut -replace '[^A-Za-z0-9_]', '_'))
            Assert-CasInt (Wait-CasIntPath -Path $crashMarker -TimeoutMs 20000) ("Cut $cut never wrote a one-shot mailbox crash marker.")
            $manifestBefore = Get-CasIntFileFingerprint -Path $batchCutPaths.manifest
            $wakeCut = 'telephone-' + [string]$jobCut.line_job_id
            Start-Sleep -Milliseconds 400
            Remove-Item env:TELEPHONE_TEST_COLLECTOR_CRASH_AFTER -ErrorAction SilentlyContinue
            $null = Invoke-CasIntScript -ScriptPath $resumeScript -Arguments @('-StateRoot', $telCut)
            Assert-CasInt (Wait-CasIntPath -Path $pathsCut.delivery -TimeoutMs 60000) ("Cut $cut never delivered after collector restart.")
            Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hCut -ThreadId $tidCut -RunId $wakeCut).Count -eq 1) ("Cut $cut did not keep one marker turn.")
            Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hCut.root 'cut-count.txt')) -eq 1) ("Cut $cut reran the executor.")
            if (-not [string]::IsNullOrWhiteSpace($manifestBefore)) {
                Assert-CasInt ((Get-CasIntFileFingerprint -Path $batchCutPaths.manifest) -ceq $manifestBefore) ("Cut $cut replaced the closed manifest.")
            }
            Assert-CasInt ([IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hCut -RunId $wakeCut) 'lead-wake-ack.json'))) ("Cut $cut lost the exact ack on re-entry.")
            Stop-CasIntTelephoneState -StateRoot $telCut
            Assert-CasIntTelephoneResidueClear -StateRoot $telCut -Label ("batch-fan-in cut " + $cut)
            Stop-CasIntRun -Harness $hCut -RunId $wakeCut
            $script:batchCollectorCuts[$cut] = 1
            Clear-CasIntTestEnv
        }

        foreach ($cut in @('ack', 'delivery')) {
            $hCut = New-CasIntHarness -Name ('batch-fan-in-declared-cut-' + $cut)
            $null = Invoke-CasIntProfile -Harness $hCut
            $bCut = Invoke-CasIntBuilder -Harness $hCut
            $tidCut = [string]$bCut.json.thread_id
            $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '20000'
            $env:TELEPHONE_TEST_COLLECTOR_CRASH_AFTER = $cut
            $telCut = Join-Path $hCut.root 'telephone-state'
            [IO.Directory]::CreateDirectory($telCut) | Out-Null
            $bindingCut = (Read-TelephoneJson -Path ([string]$hCut.binding) -SchemaName 'lead-binding').value
            $batchCutId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
            $cutIds = @('pkg-cut-a', 'pkg-cut-b')
            $jobCutA = Start-CasIntFanInJob -Harness $hCut -TelState $telCut -Starter $starter -MockRoute $mockRoute -Binding $bindingCut -BatchId $batchCutId -PackageIds $cutIds -PackageId 'pkg-cut-a' -N 2 -CounterPath (Join-Path $hCut.root 'cut-a.txt')
            $jobCutB = Start-CasIntFanInJob -Harness $hCut -TelState $telCut -Starter $starter -MockRoute $mockRoute -Binding $bindingCut -BatchId $batchCutId -PackageIds $cutIds -PackageId 'pkg-cut-b' -N 2 -CounterPath (Join-Path $hCut.root 'cut-b.txt')
            $leadKeyCut = Get-CasIntFanInLeadKey -Binding $bindingCut
            $mailboxCut = Get-CasIntFanInMailbox -TelState $telCut -LeadKey $leadKeyCut
            $batchCutPaths = Get-TelephoneBatchPaths -MailboxPaths $mailboxCut -BatchId $batchCutId
            Assert-CasInt (Wait-CasIntFanInCounted -Mailbox $mailboxCut -BatchId $batchCutId -Counted 2) ("Declared-batch cut $cut never reached 2/2.")
            Assert-CasInt (Wait-CasIntPath -Path $batchCutPaths.manifest -TimeoutMs 40000) ("Declared-batch cut $cut never published a manifest.")
            $cutWaitPath = if ($cut -ceq 'ack') { [string]$batchCutPaths.wake_launch_result } else { (Get-TelephoneJobPaths -JobRoot ([string]$jobCutA.job_root)).delivery }
            $null = Wait-CasIntPath -Path $cutWaitPath -TimeoutMs 20000
            $crashMarker = Join-Path ([string]$mailboxCut.lead_root) ('.collector-crash-' + $cut)
            Assert-CasInt (Wait-CasIntPath -Path $crashMarker -TimeoutMs 20000) ("Declared-batch cut $cut never wrote a one-shot mailbox crash marker.")
            $manifestBefore = Get-CasIntFileFingerprint -Path $batchCutPaths.manifest
            $wakeCut = 'telephone-batch-' + $batchCutId
            Start-Sleep -Milliseconds 400
            Remove-Item env:TELEPHONE_TEST_COLLECTOR_CRASH_AFTER -ErrorAction SilentlyContinue
            $null = Invoke-CasIntScript -ScriptPath $resumeScript -Arguments @('-StateRoot', $telCut)
            $pathsCutA = Get-TelephoneJobPaths -JobRoot ([string]$jobCutA.job_root)
            $pathsCutB = Get-TelephoneJobPaths -JobRoot ([string]$jobCutB.job_root)
            Assert-CasInt (Wait-CasIntPath -Path $pathsCutA.delivery -TimeoutMs 60000) ("Declared-batch cut $cut never delivered package A after restart.")
            Assert-CasInt (Wait-CasIntPath -Path $pathsCutB.delivery -TimeoutMs 60000) ("Declared-batch cut $cut never delivered package B after restart.")
            Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hCut -ThreadId $tidCut -RunId $wakeCut).Count -eq 1) ("Declared-batch cut $cut did not keep one marker turn.")
            Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hCut.root 'cut-a.txt')) -eq 1) ("Declared-batch cut $cut reran package A.")
            Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hCut.root 'cut-b.txt')) -eq 1) ("Declared-batch cut $cut reran package B.")
            Assert-CasInt ((Get-CasIntFileFingerprint -Path $batchCutPaths.manifest) -ceq $manifestBefore) ("Declared-batch cut $cut replaced the closed manifest.")
            Assert-CasInt ([IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hCut -RunId $wakeCut) 'lead-wake-ack.json'))) ("Declared-batch cut $cut lost the exact ack on re-entry.")
            Stop-CasIntTelephoneState -StateRoot $telCut
            Assert-CasIntTelephoneResidueClear -StateRoot $telCut -Label ("batch-fan-in declared cut " + $cut)
            Stop-CasIntRun -Harness $hCut -RunId $wakeCut
            $script:batchCollectorCuts[('declared_' + $cut)] = 1
            Clear-CasIntTestEnv
        }
        $script:batchCollectorRestartOnce = 1

        $hNeg = New-CasIntHarness -Name 'batch-fan-in-negatives'
        $null = Invoke-CasIntProfile -Harness $hNeg
        $bNeg = Invoke-CasIntBuilder -Harness $hNeg
        $tidNeg = [string]$bNeg.json.thread_id
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '15000'
        $telNeg = Join-Path $hNeg.root 'telephone-state'
        [IO.Directory]::CreateDirectory($telNeg) | Out-Null
        $bindingNeg = (Read-TelephoneJson -Path ([string]$hNeg.binding) -SchemaName 'lead-binding').value
        $leadKeyNeg = Get-CasIntFanInLeadKey -Binding $bindingNeg
        $dupBatch = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $dupIds = @('pkg-dup', 'pkg-other')
        $dupACounter = Join-Path $hNeg.root 'dup-a.txt'
        $dupBCounter = Join-Path $hNeg.root 'dup-b.txt'
        $dupA = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId $dupBatch -PackageIds $dupIds -PackageId 'pkg-dup' -N 2 -CounterPath $dupACounter
        $dupFailed = $false
        try {
            $null = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId $dupBatch -PackageIds $dupIds -PackageId 'pkg-dup' -N 2 -CounterPath $dupBCounter
        } catch {
            $dupFailed = $true
        }
        Assert-CasInt $dupFailed 'Duplicate package_id was accepted.'
        Assert-CasInt (Wait-CasIntFanInJobFirstComplete -Job $dupA -CounterPath $dupACounter) 'Duplicate package_id never completed the first executor once.'
        Assert-CasInt ((Get-CasIntCounterCount -Path $dupACounter) -eq 1) 'Duplicate package_id reran the first executor.'
        Assert-CasInt ((Get-CasIntCounterCount -Path $dupBCounter) -eq 0) 'Duplicate package_id started a second command.'

        $driftBatch = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $driftACounter = Join-Path $hNeg.root 'drift-a.txt'
        $driftBCounter = Join-Path $hNeg.root 'drift-b.txt'
        $mailboxNeg = Get-CasIntFanInMailbox -TelState $telNeg -LeadKey $leadKeyNeg
        $driftA = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId $driftBatch -PackageIds @('pkg-drift-a', 'pkg-drift-b') -PackageId 'pkg-drift-a' -N 2 -CounterPath $driftACounter
        $driftPaths = Get-TelephoneBatchPaths -MailboxPaths $mailboxNeg -BatchId $driftBatch
        $driftAPaths = Get-TelephoneJobPaths -JobRoot ([string]$driftA.job_root)
        Assert-CasInt (Wait-CasIntFanInJobFirstComplete -Job $driftA -CounterPath $driftACounter) 'Denominator drift never completed package A once.'
        Assert-CasInt (Wait-CasIntFanInCounted -Mailbox $mailboxNeg -BatchId $driftBatch -Counted 1) 'Denominator drift never froze the original 1/2 collection.'
        $driftCollection = (Read-TelephoneJson -Path $driftPaths.collection).value
        Assert-CasInt ([int]$driftCollection.n -eq 2 -and [bool]$driftCollection.closed -eq $false) 'Original drift collection denominator was not n=2.'
        Assert-CasInt ((@($driftCollection.package_ids) -join '|') -ceq 'pkg-drift-a|pkg-drift-b') 'Original drift package identity drifted.'
        $driftB = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId $driftBatch -PackageIds @('pkg-drift-a', 'pkg-drift-b', 'pkg-drift-c') -PackageId 'pkg-drift-b' -N 3 -CounterPath $driftBCounter
        $driftBPaths = Get-TelephoneJobPaths -JobRoot ([string]$driftB.job_root)
        Assert-CasInt (Wait-CasIntPath -Path $driftPaths.fail_closed -TimeoutMs 30000) 'Denominator drift did not fail closed.'
        Assert-CasInt (Wait-CasIntFanInJobFirstComplete -Job $driftB -CounterPath $driftBCounter) 'Denominator drift never completed package B once.'
        Assert-CasInt ((Get-CasIntCounterCount -Path $driftACounter) -eq 1) 'Denominator drift reran package A.'
        Assert-CasInt ((Get-CasIntCounterCount -Path $driftBCounter) -eq 1) 'Denominator drift reran package B.'
        Assert-CasInt ([int]((Read-TelephoneJson -Path $driftAPaths.dispatch).value.batch.n) -eq 2) 'Original drift-A dispatch denominator drifted.'
        $driftCollectionClosed = (Read-TelephoneJson -Path $driftPaths.collection).value
        Assert-CasInt ([int]$driftCollectionClosed.n -eq 2) 'Denominator drift mutated the original collection n.'
        Assert-CasInt ((@($driftCollectionClosed.package_ids) -join '|') -ceq 'pkg-drift-a|pkg-drift-b') 'Denominator drift mutated the original package identity.'
        $driftWake = 'telephone-batch-' + $driftBatch
        Assert-CasInt (-not [IO.File]::Exists($driftPaths.manifest)) 'Denominator drift published a closed manifest.'
        Assert-CasInt (-not [IO.File]::Exists($driftPaths.wake_attempt)) 'Denominator drift published a wake attempt.'
        Assert-CasInt (-not [IO.File]::Exists($driftPaths.wake_launch_result)) 'Denominator drift published a wake launch.'
        Assert-CasInt (-not [IO.File]::Exists($driftAPaths.delivery)) 'Denominator drift delivered package A.'
        Assert-CasInt (-not [IO.File]::Exists($driftBPaths.delivery)) 'Denominator drift delivered package B.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hNeg -ThreadId $tidNeg -RunId $driftWake).Count -eq 0) 'Denominator drift started a marker turn.'
        $null = Invoke-CasIntScript -ScriptPath $resumeScript -Arguments @('-StateRoot', $telNeg)
        try {
            $null = Ensure-TelephoneLeadCollector -StateRoot $telNeg -LeadKey $leadKeyNeg -RelayScript $relayScript
        } catch { }
        Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 20000 -Predicate {
            return (-not (Test-CasIntFanInJobCommandAlive -Job $driftA) -and -not (Test-CasIntFanInJobCommandAlive -Job $driftB))
        }) 'Denominator drift command owners did not quiesce after re-entry.'
        Assert-CasInt ((Get-CasIntCounterCount -Path $driftACounter) -eq 1) 'Denominator drift reran package A after resume/collector re-entry.'
        Assert-CasInt ((Get-CasIntCounterCount -Path $driftBCounter) -eq 1) 'Denominator drift reran package B after resume/collector re-entry.'
        Assert-CasInt ([IO.File]::Exists($driftPaths.fail_closed)) 'Denominator drift lost fail-closed evidence after re-entry.'
        Assert-CasInt ([int]((Read-TelephoneJson -Path $driftAPaths.dispatch).value.batch.n) -eq 2) 'Original drift-A dispatch denominator drifted after re-entry.'
        $driftCollectionAfter = (Read-TelephoneJson -Path $driftPaths.collection).value
        Assert-CasInt ([int]$driftCollectionAfter.n -eq 2) 'Denominator drift mutated n after re-entry.'
        Assert-CasInt ((@($driftCollectionAfter.package_ids) -join '|') -ceq 'pkg-drift-a|pkg-drift-b') 'Denominator drift mutated package identity after re-entry.'
        Assert-CasInt (-not [IO.File]::Exists($driftPaths.manifest)) 'Denominator drift published a closed manifest after re-entry.'
        Assert-CasInt (-not [IO.File]::Exists($driftPaths.wake_attempt)) 'Denominator drift published a wake attempt after re-entry.'
        Assert-CasInt (-not [IO.File]::Exists($driftAPaths.delivery) -and -not [IO.File]::Exists($driftBPaths.delivery)) 'Denominator drift delivered after re-entry.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hNeg -ThreadId $tidNeg -RunId $driftWake).Count -eq 0) 'Denominator drift started a marker turn after re-entry.'

        $ambBatch = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $ambJob = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId $ambBatch -PackageIds @('pkg-amb', 'pkg-amb-2') -PackageId 'pkg-amb' -N 2 -CounterPath (Join-Path $hNeg.root 'amb.txt')
        $ambPaths = Get-TelephoneJobPaths -JobRoot ([string]$ambJob.job_root)
        Assert-CasInt (Wait-CasIntPath -Path $ambPaths.receipt -TimeoutMs 30000) 'Ambiguous fixture never published a receipt.'
        Assert-CasInt (Wait-CasIntFanInJobFirstComplete -Job $ambJob -CounterPath (Join-Path $hNeg.root 'amb.txt')) 'START_AMBIGUOUS never completed the executor once.'
        $ambReceipt = (Read-TelephoneJson -Path $ambPaths.receipt -SchemaName 'receipt').value
        $ambReceipt.command_error_code = 'COMMAND_START_AMBIGUOUS_NO_RERUN'
        $null = Write-TelephoneJsonReplace -Path $ambPaths.receipt -Value $ambReceipt
        $null = Invoke-CasIntScript -ScriptPath $resumeScript -Arguments @('-StateRoot', $telNeg)
        $ambBatchPaths = Get-TelephoneBatchPaths -MailboxPaths $mailboxNeg -BatchId $ambBatch
        Assert-CasInt (Wait-CasIntPath -Path $ambBatchPaths.fail_closed -TimeoutMs 30000) 'START_AMBIGUOUS did not fail closed.'
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hNeg.root 'amb.txt')) -eq 1) 'START_AMBIGUOUS reran the executor.'

        $malBatch = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $malJob = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId $malBatch -PackageIds @('pkg-mal', 'pkg-mal-2') -PackageId 'pkg-mal' -N 2 -CounterPath (Join-Path $hNeg.root 'mal.txt')
        $malPaths = Get-TelephoneJobPaths -JobRoot ([string]$malJob.job_root)
        Assert-CasInt (Wait-CasIntPath -Path $malPaths.mailbox_ref -TimeoutMs 30000) 'Malformed-owner fixture never enqueued.'
        Stop-CasIntOwnerPath -Path ([string]$mailboxNeg.owner)
        [IO.File]::WriteAllText([string]$mailboxNeg.owner, '{not-json', [Text.UTF8Encoding]::new($false))
        $malEnsureFailed = $false
        try {
            $null = Ensure-TelephoneLeadCollector -StateRoot $telNeg -LeadKey $leadKeyNeg -RelayScript $relayScript
        } catch {
            $malEnsureFailed = $true
        }
        Assert-CasInt $malEnsureFailed 'Malformed collector owner was replaced instead of failing closed.'
        Assert-CasInt ([IO.File]::Exists([string]$mailboxNeg.fail_closed)) 'Malformed owner omitted fail-closed evidence.'
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hNeg.root 'mal.txt')) -eq 1) 'Malformed owner reran the executor.'
        if ([IO.File]::Exists([string]$mailboxNeg.fail_closed)) { [IO.File]::Delete([string]$mailboxNeg.fail_closed) }
        if ([IO.File]::Exists([string]$mailboxNeg.owner)) { [IO.File]::Delete([string]$mailboxNeg.owner) }

        $preAck = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId ([guid]::NewGuid().ToString('D').ToLowerInvariant()) -PackageIds @('pkg-preack', 'pkg-preack-2') -PackageId 'pkg-preack' -N 2 -CounterPath (Join-Path $hNeg.root 'preack.txt')
        $prePaths = Get-TelephoneJobPaths -JobRoot ([string]$preAck.job_root)
        Assert-CasInt (Wait-CasIntPath -Path $prePaths.receipt -TimeoutMs 30000) 'Delivery-before-ack fixture never published a receipt.'
        $null = Write-TelephoneJsonCreateNew -Path $prePaths.delivery -Value ([ordered]@{
            protocol_version = 'telephone-line-delivery-v1'
            line_job_id = [string]$preAck.line_job_id
            lead_session_id = [string]$bindingNeg.session_id
            wake_run_id = 'telephone-forged'
            wake_key = ('0' * 64)
            lead_run_root = [string]$hNeg.state
            launcher_state = 'forged'
            delivered_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        })
        $preBatch = Resolve-TelephoneDispatchBatch -Dispatch ((Read-TelephoneJson -Path $prePaths.dispatch).value) -LineJobId ([string]$preAck.line_job_id)
        $preBatchPaths = Get-TelephoneBatchPaths -MailboxPaths $mailboxNeg -BatchId ([string]$preBatch.batch_id)
        $null = Invoke-CasIntScript -ScriptPath $resumeScript -Arguments @('-StateRoot', $telNeg)
        Assert-CasInt (Wait-CasIntPath -Path $preBatchPaths.fail_closed -TimeoutMs 30000) 'Delivery before ack did not fail closed.'
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hNeg.root 'preack.txt')) -eq 1) 'Delivery before ack reran the executor.'

        $wrongLeadFailed = $false
        $wrongBinding = Copy-CasIntLeadBinding $bindingNeg
        $wrongBinding.session_id = 'wrong-session-0001'
        $wrongJob = $null
        try {
            $wrongJob = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $wrongBinding -BatchId $dupBatch -PackageIds $dupIds -PackageId 'pkg-other' -N 2 -CounterPath (Join-Path $hNeg.root 'wrong-lead.txt')
        } catch {
            $wrongLeadFailed = $true
        }
        if (-not $wrongLeadFailed) {
            $wrongKey = Get-CasIntFanInLeadKey -Binding $wrongBinding
            Assert-CasInt ($wrongKey -cne $leadKeyNeg) 'Wrong Lead identity collapsed onto the original mailbox.'
            $dupPaths = Get-TelephoneBatchPaths -MailboxPaths $mailboxNeg -BatchId $dupBatch
            $wrongRelay = if ($null -ne $wrongJob) { (Get-TelephoneJobPaths -JobRoot ([string]$wrongJob.job_root)).relay_error } else { '' }
            Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 30000 -Predicate {
                return ([IO.File]::Exists($dupPaths.fail_closed) -or (-not [string]::IsNullOrWhiteSpace($wrongRelay) -and [IO.File]::Exists($wrongRelay)))
            }) 'Wrong Lead/session did not fail closed.'
        }
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hNeg.root 'dup-a.txt')) -eq 1) 'Wrong-lead negative reran the original duplicate package.'

        $idBatch = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $idIds = @('pkg-id-a', 'pkg-id-b')
        $idA = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId $idBatch -PackageIds $idIds -PackageId 'pkg-id-a' -N 2 -CounterPath (Join-Path $hNeg.root 'id-a.txt')
        $idAPaths = Get-TelephoneJobPaths -JobRoot ([string]$idA.job_root)
        Assert-CasInt (Wait-CasIntPath -Path $idAPaths.mailbox_ref -TimeoutMs 30000) 'Identity-anchor package never enqueued.'
        $idBatchPaths = Get-TelephoneBatchPaths -MailboxPaths $mailboxNeg -BatchId $idBatch

        $wtDir = Join-Path $hNeg.root 'wrong-worktree'
        [IO.Directory]::CreateDirectory($wtDir) | Out-Null
        $wtBind = Copy-CasIntLeadBinding $bindingNeg
        $wtBind.worktree = $wtDir
        $wtJob = $null
        $wtFailed = $false
        try {
            $wtJob = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $wtBind -BatchId $idBatch -PackageIds $idIds -PackageId 'pkg-id-b' -N 2 -CounterPath (Join-Path $hNeg.root 'wrong-wt.txt')
        } catch { $wtFailed = $true }
        if (-not $wtFailed) {
            Assert-CasInt ((Get-CasIntFanInLeadKey -Binding $wtBind) -cne $leadKeyNeg) 'Wrong worktree collapsed onto the original mailbox.'
            $wtRelay = (Get-TelephoneJobPaths -JobRoot ([string]$wtJob.job_root)).relay_error
            Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 30000 -Predicate {
                return ([IO.File]::Exists($idBatchPaths.fail_closed) -or [IO.File]::Exists($wtRelay))
            }) 'Wrong worktree did not fail closed.'
        }
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hNeg.root 'id-a.txt')) -eq 1) 'Wrong worktree reran the identity-anchor package.'

        $lnBatch = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $lnIds = @('pkg-ln-a', 'pkg-ln-b')
        $lnA = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId $lnBatch -PackageIds $lnIds -PackageId 'pkg-ln-a' -N 2 -CounterPath (Join-Path $hNeg.root 'ln-a.txt')
        $lnAPaths = Get-TelephoneJobPaths -JobRoot ([string]$lnA.job_root)
        Assert-CasInt (Wait-CasIntPath -Path $lnAPaths.mailbox_ref -TimeoutMs 30000) 'Launcher-anchor package never enqueued.'
        $lnBatchPaths = Get-TelephoneBatchPaths -MailboxPaths $mailboxNeg -BatchId $lnBatch
        $altLauncher = Join-Path $hNeg.root 'alt-lead-launcher.ps1'
        Copy-Item -LiteralPath ([string]$bindingNeg.launcher.path) -Destination $altLauncher
        $lnBind = Copy-CasIntLeadBinding $bindingNeg
        $lnBind.launcher.path = $altLauncher
        $lnJob = $null
        $lnFailed = $false
        try {
            $lnJob = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $lnBind -BatchId $lnBatch -PackageIds $lnIds -PackageId 'pkg-ln-b' -N 2 -CounterPath (Join-Path $hNeg.root 'wrong-ln.txt')
        } catch { $lnFailed = $true }
        if (-not $lnFailed) {
            Assert-CasInt ((Get-CasIntFanInLeadKey -Binding $lnBind) -cne $leadKeyNeg) 'Wrong launcher collapsed onto the original mailbox.'
            $lnRelay = (Get-TelephoneJobPaths -JobRoot ([string]$lnJob.job_root)).relay_error
            Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 30000 -Predicate {
                return ([IO.File]::Exists($lnBatchPaths.fail_closed) -or [IO.File]::Exists($lnRelay))
            }) 'Wrong launcher did not fail closed.'
        }
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hNeg.root 'ln-a.txt')) -eq 1) 'Wrong launcher reran the launcher-anchor package.'

        $prBatch = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $prIds = @('pkg-pr-a', 'pkg-pr-b')
        $prA = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId $prBatch -PackageIds $prIds -PackageId 'pkg-pr-a' -N 2 -CounterPath (Join-Path $hNeg.root 'pr-a.txt')
        $prAPaths = Get-TelephoneJobPaths -JobRoot ([string]$prA.job_root)
        Assert-CasInt (Wait-CasIntPath -Path $prAPaths.mailbox_ref -TimeoutMs 30000) 'Profile-anchor package never enqueued.'
        $prBatchPaths = Get-TelephoneBatchPaths -MailboxPaths $mailboxNeg -BatchId $prBatch
        $altProfile = Join-Path $hNeg.root 'alt-profile.json'
        Copy-Item -LiteralPath ([string]$hNeg.profile) -Destination $altProfile
        $prBind = Set-CasIntLeadBindingProfilePath -Binding (Copy-CasIntLeadBinding $bindingNeg) -ProfilePath $altProfile
        $prJob = $null
        $prFailed = $false
        try {
            $prJob = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $prBind -BatchId $prBatch -PackageIds $prIds -PackageId 'pkg-pr-b' -N 2 -CounterPath (Join-Path $hNeg.root 'wrong-pr.txt')
        } catch { $prFailed = $true }
        if (-not $prFailed) {
            Assert-CasInt ((Get-CasIntFanInLeadKey -Binding $prBind) -cne $leadKeyNeg) 'Wrong profile path collapsed onto the original mailbox.'
            $prRelay = (Get-TelephoneJobPaths -JobRoot ([string]$prJob.job_root)).relay_error
            Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 30000 -Predicate {
                return ([IO.File]::Exists($prBatchPaths.fail_closed) -or [IO.File]::Exists($prRelay))
            }) 'Wrong profile did not fail closed.'
        }
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hNeg.root 'pr-a.txt')) -eq 1) 'Wrong profile reran the profile-anchor package.'

        $shaBatch = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $shaIds = @('pkg-sha-a', 'pkg-sha-b')
        $isoProfile = Join-Path $hNeg.root 'iso-profile.json'
        Copy-Item -LiteralPath ([string]$hNeg.profile) -Destination $isoProfile
        $shaBind = Set-CasIntLeadBindingProfilePath -Binding (Copy-CasIntLeadBinding $bindingNeg) -ProfilePath $isoProfile
        $shaA = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $shaBind -BatchId $shaBatch -PackageIds $shaIds -PackageId 'pkg-sha-a' -N 2 -CounterPath (Join-Path $hNeg.root 'sha-a.txt')
        $shaKey = Get-CasIntFanInLeadKey -Binding $shaBind
        $shaMailbox = Get-CasIntFanInMailbox -TelState $telNeg -LeadKey $shaKey
        $shaAPaths = Get-TelephoneJobPaths -JobRoot ([string]$shaA.job_root)
        Assert-CasInt (Wait-CasIntPath -Path $shaAPaths.mailbox_ref -TimeoutMs 30000) 'Same-path profile package never enqueued.'
        [IO.File]::AppendAllText($isoProfile, " `n", [Text.UTF8Encoding]::new($false))
        $shaJob = $null
        $shaFailed = $false
        try {
            $shaJob = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $shaBind -BatchId $shaBatch -PackageIds $shaIds -PackageId 'pkg-sha-b' -N 2 -CounterPath (Join-Path $hNeg.root 'sha-b.txt')
        } catch { $shaFailed = $true }
        $shaBatchPaths = Get-TelephoneBatchPaths -MailboxPaths $shaMailbox -BatchId $shaBatch
        if (-not $shaFailed) {
            $shaRelay = (Get-TelephoneJobPaths -JobRoot ([string]$shaJob.job_root)).relay_error
            Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 30000 -Predicate {
                return ([IO.File]::Exists($shaBatchPaths.fail_closed) -or [IO.File]::Exists($shaRelay))
            }) 'Same-path profile byte/SHA drift did not fail closed.'
        }
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hNeg.root 'sha-a.txt')) -eq 1) 'Profile byte/SHA drift reran package A.'

        $unqBatch = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $unq = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId $unqBatch -PackageIds @('pkg-unq', 'pkg-unq-2') -PackageId 'pkg-unq' -N 2 -CounterPath (Join-Path $hNeg.root 'unq.txt')
        $unqPaths = Get-TelephoneJobPaths -JobRoot ([string]$unq.job_root)
        Assert-CasInt (Wait-CasIntPath -Path $unqPaths.receipt -TimeoutMs 30000) 'Unqualified START_FAILED fixture never published a receipt.'
        [IO.File]::WriteAllText([string]$unqPaths.stdout, "unqualified-start`n", [Text.UTF8Encoding]::new($false))
        $unqReceipt = (Read-TelephoneJson -Path $unqPaths.receipt -SchemaName 'receipt').value
        $unqReceipt.command_error_code = 'COMMAND_START_FAILED'
        $null = Write-TelephoneJsonReplace -Path $unqPaths.receipt -Value $unqReceipt
        $null = Invoke-CasIntScript -ScriptPath $resumeScript -Arguments @('-StateRoot', $telNeg)
        $unqBatchPaths = Get-TelephoneBatchPaths -MailboxPaths $mailboxNeg -BatchId $unqBatch
        Assert-CasInt (Wait-CasIntPath -Path $unqBatchPaths.fail_closed -TimeoutMs 30000) 'Unqualified START_FAILED did not fail closed.'
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hNeg.root 'unq.txt')) -eq 1) 'Unqualified START_FAILED reran the executor.'

        $missHold = Join-Path $hNeg.root 'held-missing-receipt'
        $missBatch = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $missIds = @('pkg-miss-a', 'pkg-miss-b')
        $missA = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId $missBatch -PackageIds $missIds -PackageId 'pkg-miss-a' -N 2 -CounterPath (Join-Path $hNeg.root 'miss-a.txt')
        $missB = Start-CasIntFanInJob -Harness $hNeg -TelState $telNeg -Starter $starter -MockRoute $mockRoute -Binding $bindingNeg -BatchId $missBatch -PackageIds $missIds -PackageId 'pkg-miss-b' -N 2 -CounterPath (Join-Path $hNeg.root 'miss-b.txt') -HoldPath $missHold
        $missMailbox = Get-CasIntFanInMailbox -TelState $telNeg -LeadKey $leadKeyNeg
        Assert-CasInt (Wait-CasIntFanInCounted -Mailbox $missMailbox -BatchId $missBatch -Counted 1) 'Missing receipt was counted.'
        $missPaths = Get-TelephoneBatchPaths -MailboxPaths $missMailbox -BatchId $missBatch
        Assert-CasInt (-not [IO.File]::Exists($missPaths.manifest)) 'Missing receipt published a closed manifest.'
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hNeg.root 'miss-b.txt')) -eq 0) 'Missing receipt invoked the held package.'

        Stop-CasIntTelephoneState -StateRoot $telNeg
        Start-Sleep -Milliseconds 250
        $staleOwner = Get-Process -Id $PID
        try {
            $null = Write-TelephoneJsonReplace -Path ([string]$mailboxNeg.owner) -Value ([ordered]@{
                protocol_version = 'telephone-line-mailbox-owner-v1'
                pid = [int]$PID
                start_time_utc_ticks = [int64]$staleOwner.StartTime.ToUniversalTime().Ticks
                started_at_utc = $staleOwner.StartTime.ToUniversalTime().ToString('o')
                lead_identity_sha256 = $leadKeyNeg
            })
        } finally { $staleOwner.Dispose() }
        $staleReturned = Ensure-TelephoneLeadCollector -StateRoot $telNeg -LeadKey $leadKeyNeg -RelayScript $relayScript
        Assert-CasInt ([int]$staleReturned.pid -eq [int]$PID) 'Stale owner was replaced instead of remaining evidentiary.'
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hNeg.root 'id-a.txt')) -eq 1) 'Stale owner reran an earlier executor.'
        if ([IO.File]::Exists([string]$mailboxNeg.owner)) { [IO.File]::Delete([string]$mailboxNeg.owner) }

        $heldGate = Open-TelephoneExclusiveGate -Path ([string]$mailboxNeg.gate) -WaitMilliseconds 0
        Assert-CasInt ($null -ne $heldGate) 'Could not hold the collector gate for the held-lock negative.'
        try {
            $heldFailed = $false
            try {
                $null = Ensure-TelephoneLeadCollector -StateRoot $telNeg -LeadKey $leadKeyNeg -RelayScript $relayScript
            } catch { $heldFailed = $true }
            Assert-CasInt $heldFailed 'Held collector gate was accepted.'
        } finally {
            if ($null -ne $heldGate) { $heldGate.Dispose() }
        }
        Assert-CasInt ((Get-CasIntCounterCount -Path (Join-Path $hNeg.root 'id-a.txt')) -eq 1) 'Held lock reran an earlier executor.'

        Assert-CasInt (@(Get-CasIntAnyMarkerStoreTurns -Harness $hNeg -ThreadId $tidNeg).Count -eq 0) 'Fail-closed negatives started unexplained marker turns.'

        Stop-CasIntTelephoneState -StateRoot $telNeg
        Assert-CasIntTelephoneResidueClear -StateRoot $telNeg -Label 'batch-fan-in negatives'
        $script:batchNegativesClosed = 1
        Clear-CasIntTestEnv

        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            batch_fan_in_only = $true
            batch_five_of_six = [int]$script:batchFiveOfSix
            batch_six_busy_no_marker = [int]$script:batchSixBusyNoMarker
            batch_one_delivery_once = [int]$script:batchOneDeliveryOnce
            batch_retry_once = [int]$script:batchRetryOnce
            batch_race_once = [int]$script:batchRaceOnce
            batch_collector_restart_once = [int]$script:batchCollectorRestartOnce
            batch_collector_cuts = $script:batchCollectorCuts
            batch_negatives_closed = [int]$script:batchNegativesClosed
            batch_launch_started_at_utc = $script:batchLaunchStartedAtUtc
            batch_launch_span_ms = [int]$script:batchLaunchSpanMs
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($AppServerDeathRecoveryOnly) {
        Clear-CasIntTestEnv
        $hNeg = New-CasIntHarness -Name 'quiet-not-terminal'
        $null = Invoke-CasIntProfile -Harness $hNeg
        $pathsNeg = Write-CasIntPlantedIntent -Harness $hNeg -RunId 'run-quiet-not-terminal' -ThreadId 'thread-quiet-not-terminal'
        Write-CasIntPlantedRun -Paths $pathsNeg -Harness $hNeg -RunId 'run-quiet-not-terminal' -ThreadId 'thread-quiet-not-terminal' -Selected 'turn-quiet' -Disposition 'recovery_required' -Phase 'acknowledged'
        Assert-CasInt (-not (Test-CasIntOwnerAlive -Harness $hNeg -RunId 'run-quiet-not-terminal')) 'Planted recovery_required fixture had a live per-run owner.'
        Assert-CasInt ([string](Get-CasIntRunJson -Harness $hNeg -RunId 'run-quiet-not-terminal').disposition -ceq 'recovery_required') 'Planted recovery_required fixture lost its disposition.'
        $quietNeg = Wait-CasIntRunQuiet -Harness $hNeg -RunId 'run-quiet-not-terminal' -TimeoutMs 400
        Assert-CasInt $quietNeg 'Wait-CasIntRunQuiet was false for a nonterminal run with no live per-run owner.'
        $termNeg = Wait-CasIntOfficialTerminal -Harness $hNeg -RunId 'run-quiet-not-terminal' -ThreadId 'thread-quiet-not-terminal' -TurnId 'turn-quiet' -Disposition 'completed' -TimeoutMs 400
        Assert-CasInt (-not $termNeg) 'Official terminal helper treated nonterminal recovery_required as completed.'
        Assert-CasInt ([string](Get-CasIntRunJson -Harness $hNeg -RunId 'run-quiet-not-terminal').disposition -ceq 'recovery_required') 'Official terminal helper mutated planted recovery_required state.'
        $script:quietNotTerminalOracle = 1
        $script:terminalWaitObservationOnly = 1
        Clear-CasIntTestEnv
        $hStuck = New-CasIntHarness -Name 'stuck-owner-no-kill'
        $null = Invoke-CasIntProfile -Harness $hStuck
        $bStuck = Invoke-CasIntBuilder -Harness $hStuck
        $tidStuck = [string]$bStuck.json.thread_id
        $ridStuck = 'run-stuck-owner'
        $holdStuck = Join-Path $hStuck.root 'hold-completed'
        $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdStuck
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '20000'
        $stuckLaunch = Invoke-CasIntLauncher -Harness $hStuck -ThreadId $tidStuck -RunId $ridStuck
        Assert-CasInt ($stuckLaunch.exit_code -eq 0) ("Stuck-owner baseline launch failed: $($stuckLaunch.stderr) $($stuckLaunch.stdout)")
        Assert-CasInt (Test-CasIntOwnerAlive -Harness $hStuck -RunId $ridStuck) 'Stuck-owner fixture has no live per-run owner.'
        Assert-CasInt (Test-CasIntThreadOwnerAlive -Harness $hStuck -ThreadId $tidStuck) 'Stuck-owner fixture has no live thread owner.'
        $stuckRunOwnerPath = Join-Path (Get-CasIntRunRoot -Harness $hStuck -RunId $ridStuck) 'owner.json'
        $stuckThreadOwnerPath = Get-CasIntThreadOwnerPath -Harness $hStuck -ThreadId $tidStuck
        $stuckRunBytes = [IO.File]::ReadAllBytes($stuckRunOwnerPath)
        $stuckThreadBytes = [IO.File]::ReadAllBytes($stuckThreadOwnerPath)
        $stuckRunQuiet = Wait-CasIntRunOwnerQuiet -Harness $hStuck -RunId $ridStuck -TimeoutMs 400
        $stuckThreadQuiet = Wait-CasIntThreadOwnerQuiet -Harness $hStuck -ThreadId $tidStuck -TimeoutMs 400
        $stuckRunAlive = Test-CasIntOwnerAlive -Harness $hStuck -RunId $ridStuck
        $stuckThreadAlive = Test-CasIntThreadOwnerAlive -Harness $hStuck -ThreadId $tidStuck
        $stuckRunBytesAfter = [IO.File]::ReadAllBytes($stuckRunOwnerPath)
        $stuckThreadBytesAfter = [IO.File]::ReadAllBytes($stuckThreadOwnerPath)
        Assert-CasInt (-not $stuckRunQuiet) 'Observation-only per-run quiet returned true while the exact owner was still live.'
        Assert-CasInt (-not $stuckThreadQuiet) 'Observation-only thread-owner quiet returned true while the exact owner was still live.'
        Assert-CasInt $stuckRunAlive 'Observation-only per-run quiet killed or hid the live per-run owner.'
        Assert-CasInt $stuckThreadAlive 'Observation-only thread-owner quiet killed or hid the live thread owner.'
        Assert-CasInt ([Convert]::ToBase64String($stuckRunBytes) -ceq [Convert]::ToBase64String($stuckRunBytesAfter)) 'Observation-only per-run quiet mutated the owner record.'
        Assert-CasInt ([Convert]::ToBase64String($stuckThreadBytes) -ceq [Convert]::ToBase64String($stuckThreadBytesAfter)) 'Observation-only thread-owner quiet mutated the owner record.'
        $script:stuckOwnerExposedWithoutKill = 1
        Stop-CasIntRun -Harness $hStuck -RunId $ridStuck
        Clear-CasIntTestEnv
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        Invoke-CasIntAppServerDeathRecoveryProof -Name 'death-app-server-focused'
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            app_server_death_recovery_focused = $appServerDeathRecoveryFocused
            quiet_not_terminal_oracle = $quietNotTerminalOracle
            terminal_wait_observation_only = $terminalWaitObservationOnly
            natural_quiesce_observation_only = $naturalQuiesceObservationOnly
            stuck_owner_exposed_without_kill = $stuckOwnerExposedWithoutKill
            appserver_death_same_turn = $appserverDeathSameTurn
            recovery_required = $recoveryRequired
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($WorkerDeathRecoveryOnly) {
        Clear-CasIntTestEnv
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        Invoke-CasIntWorkerDeathRecoveryProof -Name 'death-worker-focused'
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            worker_death_official_terminal = $workerDeathOfficialTerminal
            worker_death_natural_quiesce_observation_only = $workerDeathNaturalQuiesceObservationOnly
            worker_death_same_turn = $workerDeathSameTurn
            recovery_required = $recoveryRequired
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($WakeAmbiguityRepairOnly) {
        Clear-CasIntTestEnv
        Invoke-CasIntWakeAmbiguityRepairProof
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            wake_ambiguity_positive_restart = $wakeAmbiguityPositiveRestart
            wake_ambiguity_marker_recovery = $wakeAmbiguityMarkerRecovery
            wake_ambiguity_multiple_markers_closed = $wakeAmbiguityMultipleMarkersClosed
            wake_ambiguity_post_intent_closed = $wakeAmbiguityPostIntentClosed
            wake_ambiguity_identity_mismatch_closed = $wakeAmbiguityIdentityMismatchClosed
            wake_ambiguity_sending_without_marker_closed = $wakeAmbiguitySendingWithoutMarkerClosed
            wake_ambiguity_live_owner_serialized = $wakeAmbiguityLiveOwnerSerialized
            wake_ambiguity_match_conflict_closed = $wakeAmbiguityMatchConflictClosed
            wake_ambiguity_exact_text_attach = $wakeAmbiguityExactTextAttach
            wake_ambiguity_wrong_text_closed = $wakeAmbiguityWrongTextClosed
            wake_ambiguity_exact_plus_wrong_text_closed = $wakeAmbiguityExactPlusWrongTextClosed
            wake_ambiguity_malformed_protocol_closed = $wakeAmbiguityMalformedProtocolClosed
            wake_ambiguity_unrelated_busy_code_closed = $wakeAmbiguityUnrelatedBusyCodeClosed
            wake_ambiguity_quiescence = $wakeAmbiguityQuiescence
            wake_ambiguity_artifacts_agree = $wakeAmbiguityArtifactsAgree
            wake_ambiguity_captured_prior_baseline = $wakeAmbiguityCapturedPriorBaseline
            wake_ambiguity_preintent_predicate_closed = $wakeAmbiguityPreIntentPredicateClosed
            wake_ambiguity_active_started_before_intent_closed = $wakeAmbiguityActiveStartedBeforeIntentClosed
            wake_ambiguity_terminal_without_time_closed = $wakeAmbiguityTerminalWithoutTimeClosed
            wake_ambiguity_intent_time_unparseable_closed = $wakeAmbiguityIntentTimeUnparseableClosed
            wake_ambiguity_completed_after_intent_closed = $wakeAmbiguityCompletedAfterIntentClosed
            wake_ambiguity_same_second_closed = $wakeAmbiguitySameSecondClosed
            wake_ambiguity_archived_resume_once = $wakeAmbiguityArchivedResumeOnce
            wake_ambiguity_archived_repeat_no_second_unarchive = $wakeAmbiguityArchivedRepeatNoSecondUnarchive
            wake_ambiguity_archived_wrong_code_closed = $wakeAmbiguityArchivedWrongCodeClosed
            wake_ambiguity_archived_noncanonical_closed = $wakeAmbiguityArchivedNoncanonicalClosed
            wake_ambiguity_archived_missing_id_closed = $wakeAmbiguityArchivedMissingIdClosed
            wake_ambiguity_archived_mismatched_id_closed = $wakeAmbiguityArchivedMismatchedIdClosed
            wake_ambiguity_archived_unrelated_resume_closed = $wakeAmbiguityArchivedUnrelatedResumeClosed
            wake_ambiguity_archived_unarchive_failed_closed = $wakeAmbiguityArchivedUnarchiveFailedClosed
            wake_ambiguity_archived_retry_failed_closed = $wakeAmbiguityArchivedRetryFailedClosed
            wake_ambiguity_archived_command_boundary = $wakeAmbiguityArchivedCommandBoundary
            wake_ambiguity_archived_raw_json_resume_error = $wakeAmbiguityArchivedRawJsonResumeError
            wake_ambiguity_owner_observe_race_closed = $wakeAmbiguityOwnerObserveRaceClosed
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($F02SchemaNoneInProgressOnly) {
        Clear-CasIntTestEnv
        $schemaSpec = $null
        foreach ($def in @(Get-CasIntWriterScenarioDefinitions)) {
            if ([string]$def.name -ceq 'schema-none-in-progress') { $schemaSpec = $def; break }
        }
        Assert-CasInt ($null -ne $schemaSpec) 'schema-none-in-progress definition is missing.'
        Assert-CasInt (([string]$schemaSpec.invoke) -ceq 'worker') 'schema-none-in-progress is no longer a worker scenario.'
        $requireTuple = $true
        if ($schemaSpec.Contains('expect_tuple')) { $requireTuple = [bool]$schemaSpec.expect_tuple }
        Assert-CasInt $requireTuple 'schema-none-in-progress must remain a required-tuple scenario.'
        $hPos = New-CasIntHarness -Name 'f02-schema-none-isolated'
        $null = Invoke-CasIntProfile -Harness $hPos
        $bPos = Invoke-CasIntBuilder -Harness $hPos
        $executed = Invoke-CasIntWriterScenario -Harness $hPos -ThreadId ([string]$bPos.json.thread_id) -Spec $schemaSpec
        Assert-CasInt ([bool]$executed.queue_clean) 'Isolated schema-none-in-progress was not the sole queued item.'
        Assert-CasInt ([int]$executed.raw_count -eq @($executed.tuples).Count) 'Isolated schema-none-in-progress diverged raw captured tuples from returned tuples.'
        Assert-CasInt ($executed.tuples.Count -gt 0) ("Isolated schema-none-in-progress produced no tuple. recovery=$([IO.File]::Exists($executed.paths.recovery)) failure=$([IO.File]::Exists($executed.paths.failure))")
        Assert-CasInt ([IO.File]::Exists($executed.paths.failure)) 'Isolated schema-none-in-progress omitted failure.json.'
        $matched = $false
        foreach ($tuple in @($executed.tuples)) {
            if (
                [string]$tuple.code -ceq 'schema_or_version_mismatch' -and
                [string]$tuple.current_phase -ceq 'none' -and
                [string]$tuple.turn_state -ceq 'prebind'
            ) { $matched = $true }
        }
        Assert-CasInt $matched 'Isolated schema-none-in-progress did not attribute the expected schema_or_version_mismatch phase-none/prebind failure tuple.'
        $script:f02SchemaNoneInProgressIsolated = 1
        $script:f02WorkerFixtureQueueClean = 1
        Stop-CasIntRun -Harness $executed.harness -RunId ([string]$executed.run_id)

        $hNeg = New-CasIntHarness -Name 'f02-queue-contamination'
        $null = Invoke-CasIntProfile -Harness $hNeg
        $bNeg = Invoke-CasIntBuilder -Harness $hNeg
        $tidNeg = [string]$bNeg.json.thread_id
        $stalePaths = Write-CasIntHistoryWorld -Harness $hNeg -ThreadId $tidNeg -RunId 'run-wrs-older-stale' -CurrentPhase 'none' -CurrentDisposition 'in_progress' -TurnState 'prebind' -PlantRecovery $false
        Start-Sleep -Milliseconds 20
        $targetRid = 'run-wrs-schema-none-in-progress'
        $targetPaths = Write-CasIntHistoryWorld -Harness $hNeg -ThreadId $tidNeg -RunId $targetRid -CurrentPhase 'none' -CurrentDisposition 'in_progress' -TurnState 'prebind' -PlantRecovery $false
        Invoke-CasIntMutatePlantedVersion -Paths $targetPaths -Version 'codex-cli 0.148.0-drift'
        $isoNeg = Test-CasIntWorkerFixtureQueueClean -Harness $hNeg -ThreadId $tidNeg -TargetRunId $targetRid
        Assert-CasInt ($isoNeg.count -ge 2) ("Contamination fixture did not keep two queued items: $($isoNeg.count)")
        Assert-CasInt ([string]$isoNeg.first -cne $targetRid) "Contamination fixture processed the target first instead of the older item: first=$($isoNeg.first)"
        Assert-CasInt (-not [bool]$isoNeg.clean) 'Fixture-isolation gate treated a contaminated queue as clean.'
        Assert-CasInt (-not [IO.File]::Exists($targetPaths.recovery)) 'Contaminated target already had recovery.json.'
        Assert-CasInt (-not [IO.File]::Exists($targetPaths.failure)) 'Contaminated target already had failure.json.'
        $zeroEvidenceSuccess = ([bool]$isoNeg.clean -and -not [IO.File]::Exists($targetPaths.recovery) -and -not [IO.File]::Exists($targetPaths.failure))
        Assert-CasInt (-not $zeroEvidenceSuccess) 'Fixture-isolation gate would treat target zero-evidence as success on a contaminated queue.'
        $script:f02QueueContaminationRejected = 1
        Stop-CasIntRun -Harness $hNeg -RunId 'run-wrs-older-stale'
        Stop-CasIntRun -Harness $hNeg -RunId $targetRid
        Clear-CasIntTestEnv
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            f02_schema_none_in_progress_isolated = $f02SchemaNoneInProgressIsolated
            f02_worker_fixture_queue_clean = $f02WorkerFixtureQueueClean
            f02_queue_contamination_rejected = $f02QueueContaminationRejected
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($F02WorkerNoneFallbackOnly) {
        Clear-CasIntTestEnv
        $inLoopSpec = $null
        $preLoopSpec = $null
        foreach ($def in @(Get-CasIntWriterScenarioDefinitions)) {
            if ([string]$def.name -ceq 'worker-none-fallback') { $inLoopSpec = $def }
            if ([string]$def.name -ceq 'worker-none-fallback-preloop-no-declaration') { $preLoopSpec = $def }
        }
        Assert-CasInt ($null -ne $inLoopSpec) 'worker-none-fallback definition is missing.'
        Assert-CasInt ($null -ne $preLoopSpec) 'worker-none-fallback-preloop-no-declaration definition is missing.'
        Assert-CasInt (([string]$inLoopSpec.invoke) -ceq 'worker') 'worker-none-fallback is no longer a worker scenario.'
        $inLoopRequire = $true
        if ($inLoopSpec.Contains('expect_tuple')) { $inLoopRequire = [bool]$inLoopSpec.expect_tuple }
        Assert-CasInt $inLoopRequire 'worker-none-fallback must remain a required-tuple scenario.'
        $inLoopInventory = $true
        if ($inLoopSpec.Contains('relation_inventory')) { $inLoopInventory = [bool]$inLoopSpec.relation_inventory }
        Assert-CasInt $inLoopInventory 'worker-none-fallback must remain in the F02 relation inventory.'
        Assert-CasInt ([string]$inLoopSpec.mock_crash_at -ceq 'after-initialize') 'worker-none-fallback is not injected at after-initialize.'
        $preLoopRequire = $true
        if ($preLoopSpec.Contains('expect_tuple')) { $preLoopRequire = [bool]$preLoopSpec.expect_tuple }
        Assert-CasInt (-not $preLoopRequire) 'pre-loop no-declaration scenario must not require a tuple.'
        $preLoopInventory = $true
        if ($preLoopSpec.Contains('relation_inventory')) { $preLoopInventory = [bool]$preLoopSpec.relation_inventory }
        Assert-CasInt (-not $preLoopInventory) 'pre-loop no-declaration scenario must stay out of F02 inventory.'
        Assert-CasInt ([string]$preLoopSpec.throw_at -ceq 'before-write') 'pre-loop no-declaration scenario is not Lead before-write.'

        $hPos = New-CasIntHarness -Name 'f02-worker-none-fallback-caught'
        $null = Invoke-CasIntProfile -Harness $hPos
        $bPos = Invoke-CasIntBuilder -Harness $hPos
        $caught = Invoke-CasIntWriterScenario -Harness $hPos -ThreadId ([string]$bPos.json.thread_id) -Spec $inLoopSpec
        Assert-CasInt ([bool]$caught.queue_clean) 'In-loop worker-none-fallback was not the sole queued item.'
        Assert-CasInt ([int]$caught.raw_count -eq @($caught.tuples).Count) 'In-loop worker-none-fallback diverged raw captured tuples from returned tuples.'
        Assert-CasInt ([IO.File]::Exists($caught.paths.failure)) 'In-loop worker-none-fallback omitted failure.json.'
        Assert-CasInt ($caught.tuples.Count -gt 0) ("In-loop worker-none-fallback produced no tuple. recovery=$([IO.File]::Exists($caught.paths.recovery)) failure=$([IO.File]::Exists($caught.paths.failure))")
        $matched = $false
        foreach ($tuple in @($caught.tuples)) {
            if (
                [string]$tuple.code -ceq 'worker_failed' -and
                [string]$tuple.current_phase -ceq 'none' -and
                [string]$tuple.turn_state -ceq 'prebind' -and
                [string]$tuple.recorded_disposition -ceq 'fallback_required_cli' -and
                [string]$tuple.current_disposition -ceq 'in_progress'
            ) { $matched = $true }
        }
        Assert-CasInt $matched 'In-loop worker-none-fallback did not attribute worker_failed phase-none/prebind fallback-to-in-progress.'
        $script:f02WorkerNoneFallbackCaught = 1
        Stop-CasIntRun -Harness $caught.harness -RunId ([string]$caught.run_id)

        $hNeg = New-CasIntHarness -Name 'f02-worker-none-fallback-preloop'
        $null = Invoke-CasIntProfile -Harness $hNeg
        $bNeg = Invoke-CasIntBuilder -Harness $hNeg
        $pre = Invoke-CasIntWriterScenario -Harness $hNeg -ThreadId ([string]$bNeg.json.thread_id) -Spec $preLoopSpec
        Assert-CasInt ([bool]$pre.queue_clean) 'Pre-loop no-declaration fixture was not the sole queued item.'
        $owned = $false
        if ([IO.File]::Exists($pre.paths.transitions)) {
            foreach ($line in [IO.File]::ReadAllLines($pre.paths.transitions)) {
                if ([string]$line -match '"state":"owner_bound"') { $owned = $true; break }
            }
        }
        Assert-CasInt $owned 'Pre-loop before-write never established queue ownership.'
        Assert-CasInt (-not [IO.File]::Exists($pre.paths.recovery)) 'Pre-loop before-write wrote recovery.json.'
        Assert-CasInt (-not [IO.File]::Exists($pre.paths.failure)) 'Pre-loop before-write entered processing catch and wrote failure.json.'
        Assert-CasInt ($pre.tuples.Count -eq 0) ("Pre-loop before-write produced unexpected tuples: $($pre.raw_count)")
        $script:f02PreloopNoDeclaration = 1
        $script:f02WorkerCatchBoundaryDistinguished = 1
        Stop-CasIntRun -Harness $pre.harness -RunId ([string]$pre.run_id)
        Clear-CasIntTestEnv
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            f02_worker_none_fallback_caught = $f02WorkerNoneFallbackCaught
            f02_preloop_no_declaration = $f02PreloopNoDeclaration
            f02_worker_catch_boundary_distinguished = $f02WorkerCatchBoundaryDistinguished
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($F02RecoveryForwardOnly) {
        Clear-CasIntTestEnv
        $world = New-CasIntAckDeathWorld -Name 'recover-forward-focused-turn-bound' -RunId 'run-recover-forward-focused-turn-bound'
        Stop-CasIntThreadOwner -Harness $world.harness -ThreadId $world.thread_id
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $world.harness -ThreadId $world.thread_id -TimeoutMs 10000) 'Recovery-forward focused fixture kept the pre-injection thread owner alive.'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$world.event_log
        $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = 'after-turn-bind'
        $ownerBoundBefore = Get-CasIntTransitionStateCount -Path ([string]$world.paths.transitions) -State 'owner_bound'
        $ownerIdentityBefore = Get-CasIntRunOwnerIdentityKey -Harness $world.harness -RunId $world.run_id
        $null = Invoke-CasIntLauncher -Harness $world.harness -ThreadId $world.thread_id -RunId $world.run_id
        $crashed = Wait-CasIntRecoverForwardCrash -World $world -ExpectedPhase 'turn_bound' -OwnerBoundBefore $ownerBoundBefore -OwnerIdentityBefore $ownerIdentityBefore
        Assert-CasInt ([bool]$crashed.success) ("Recovery-forward focused crash did not converge: phase=$([string]$crashed.phase) owner_bound=$([int]$crashed.owner_bound) baseline=$ownerBoundBefore owner_changed=$([bool]$crashed.owner_changed) owner_alive=$([bool]$crashed.owner_alive).")
        Stop-CasIntRun -Harness $world.harness -RunId $world.run_id
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT -ErrorAction SilentlyContinue
        $runCrash = Get-CasIntRunJson -Harness $world.harness -RunId $world.run_id
        Assert-CasInt ([string]$runCrash.callback_write_phase -ceq 'turn_bound') ("Recovery-forward focused crash phase=$([string]$runCrash.callback_write_phase), expected=turn_bound.")
        Assert-CasInt (-not [IO.File]::Exists($world.paths.recovery)) 'Recovery-forward focused crash leaked recovery.json past recovery-commit.'
        Assert-CasInt (-not [IO.File]::Exists($world.paths.failure)) 'Recovery-forward focused crash leaked failure.json past recovery-commit.'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$world.event_log
        $continued = Invoke-CasIntLauncher -Harness $world.harness -ThreadId $world.thread_id -RunId $world.run_id
        Assert-CasInt ($continued.exit_code -eq 0) ("Recovery-forward focused continuation failed: $($continued.stderr) $($continued.stdout)")
        $settled = Wait-CasIntOfficialTerminalAndQuiet -Harness $world.harness -RunId $world.run_id -ThreadId $world.thread_id -TurnId $world.turn_id
        Assert-CasInt ([bool]$settled.success) ("Recovery-forward focused continuation did not settle: terminal=$([bool]$settled.terminal) run_quiet=$([bool]$settled.run_quiet) thread_quiet=$([bool]$settled.thread_quiet) phase=$([string]$settled.phase) state=$([string]$settled.state).")
        Stop-CasIntRun -Harness $world.harness -RunId $world.run_id
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
        $runNow = Get-CasIntRunJson -Harness $world.harness -RunId $world.run_id
        Assert-CasInt ([string]$runNow.thread_id -ceq $world.thread_id) 'Recovery-forward focused continuation changed thread id.'
        Assert-CasInt ([string]$runNow.selected_turn_id -ceq $world.turn_id) 'Recovery-forward focused continuation changed turn id.'
        Assert-CasInt ([string]$runNow.callback_write_phase -ceq 'terminal') 'Recovery-forward focused continuation did not reach terminal.'
        Assert-CasInt ([string]$runNow.disposition -ceq 'completed') 'Recovery-forward focused continuation did not reach completed.'
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $world.harness -ThreadId $world.thread_id).Count -eq 1) 'Recovery-forward focused continuation started another turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $world.event_log -Name 'turn/start') -eq 1) 'Recovery-forward focused continuation sent another turn/start.'
        Assert-CasInt ([string]$runNow.fallback_required -ceq '') 'Recovery-forward focused continuation enabled CLI fallback.'

        $terminalWorld = New-CasIntAckDeathWorld -Name 'recover-forward-focused-terminal-run' -RunId 'run-recover-forward-focused-terminal-run'
        Stop-CasIntThreadOwner -Harness $terminalWorld.harness -ThreadId $terminalWorld.thread_id
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $terminalWorld.harness -ThreadId $terminalWorld.thread_id -TimeoutMs 10000) 'Recovery-forward terminal-run fixture kept the pre-injection thread owner alive.'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$terminalWorld.event_log
        $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = 'after-terminal-run'
        $ownerBoundBefore = Get-CasIntTransitionStateCount -Path ([string]$terminalWorld.paths.transitions) -State 'owner_bound'
        $ownerIdentityBefore = Get-CasIntRunOwnerIdentityKey -Harness $terminalWorld.harness -RunId $terminalWorld.run_id
        $null = Invoke-CasIntLauncher -Harness $terminalWorld.harness -ThreadId $terminalWorld.thread_id -RunId $terminalWorld.run_id
        $terminalCrashed = Wait-CasIntRecoverForwardCrash -World $terminalWorld -ExpectedPhase 'terminal' -OwnerBoundBefore $ownerBoundBefore -OwnerIdentityBefore $ownerIdentityBefore
        Assert-CasInt ([bool]$terminalCrashed.success) ("Recovery-forward terminal-run crash did not converge: phase=$([string]$terminalCrashed.phase) owner_bound=$([int]$terminalCrashed.owner_bound) baseline=$ownerBoundBefore owner_changed=$([bool]$terminalCrashed.owner_changed) owner_alive=$([bool]$terminalCrashed.owner_alive).")
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT -ErrorAction SilentlyContinue
        $terminalSecond = Invoke-CasIntLauncher -Harness $terminalWorld.harness -ThreadId $terminalWorld.thread_id -RunId $terminalWorld.run_id
        Assert-CasInt ($terminalSecond.exit_code -eq 0) ("Recovery-forward terminal-run re-entry failed: $($terminalSecond.stderr) $($terminalSecond.stdout)")
        $terminalSettled = Wait-CasIntOfficialTerminalAndQuiet -Harness $terminalWorld.harness -RunId $terminalWorld.run_id -ThreadId $terminalWorld.thread_id -TurnId $terminalWorld.turn_id
        Assert-CasInt ([bool]$terminalSettled.success) ("Recovery-forward terminal-run re-entry did not settle: terminal=$([bool]$terminalSettled.terminal) run_quiet=$([bool]$terminalSettled.run_quiet) thread_quiet=$([bool]$terminalSettled.thread_quiet) phase=$([string]$terminalSettled.phase) state=$([string]$terminalSettled.state).")
        $script:f02RecoveryForwardOwnerRebound = 1
        Clear-CasIntTestEnv
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            f02_recovery_forward_owner_rebound = $f02RecoveryForwardOwnerRebound
            f02_recovery_forward_turn_bound = 1
            f02_recovery_forward_terminal_run = 1
            f02_recovery_forward_terminal = 1
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($OfficialTerminalsOnly) {
        Clear-CasIntTestEnv
        $terminalCount = 0
        foreach ($term in @('completed', 'failed', 'interrupted')) {
            $ht = New-CasIntHarness -Name ('focused-terminal-' + $term)
            $null = Invoke-CasIntProfile -Harness $ht
            $bt = Invoke-CasIntBuilder -Harness $ht
            $tidt = [string]$bt.json.thread_id
            $ridt = 'run-focused-term-' + $term
            $env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS = $term
            $t1 = Invoke-CasIntLauncher -Harness $ht -ThreadId $tidt -RunId $ridt
            $terminalDiagnostic = ''
            if ($t1.exit_code -ne 0) { $terminalDiagnostic = (Get-CasIntDurableCreateFailureDiagnostic -Harness $ht -RunId $ridt -Result $t1) | ConvertTo-Json -Depth 8 -Compress }
            Assert-CasInt ($t1.exit_code -eq 0) ("Focused official $term launch failed: diagnostic=$terminalDiagnostic public=$($t1.stdout)")
            $turnId = [string](Get-CasIntBoundJson -Harness $ht -RunId $ridt).turn_id
            $settled = Wait-CasIntOfficialTerminalAndQuiet -Harness $ht -RunId $ridt -ThreadId $tidt -TurnId $turnId -Disposition $term
            Assert-CasInt ([bool]$settled.success) ("Focused official $term did not settle: terminal=$([bool]$settled.terminal) run_quiet=$([bool]$settled.run_quiet) thread_quiet=$([bool]$settled.thread_quiet) phase=$([string]$settled.phase) state=$([string]$settled.state).")
            Remove-Item env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS -ErrorAction SilentlyContinue
            Assert-CasInt ([string](Get-CasIntRunJson -Harness $ht -RunId $ridt).disposition -ceq $term) ("Focused official $term disposition is wrong.")
            Assert-CasInt ([string](Get-CasIntFinalText -Harness $ht -RunId $ridt) -ceq $term) ("Focused official $term final artifact is wrong.")
            $t2 = Invoke-CasIntLauncher -Harness $ht -ThreadId $tidt -RunId $ridt
            Assert-CasInt ($t2.exit_code -eq 0 -and $t2.json.existing -eq $true -and [string]$t2.json.state -ceq $term) ("Focused official $term repeat did not return the existing terminal.")
            Assert-CasInt (@(Get-CasIntStoreTurns -Harness $ht -ThreadId $tidt).Count -eq 1) ("Focused official $term repeat started another turn.")
            $terminalCount += 1
        }
        Clear-CasIntTestEnv
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            official_terminals_only = $true
            official_terminal_count = $terminalCount
            completed = 1
            failed = 1
            interrupted = 1
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($AckObservationRaceOnly) {
        Clear-CasIntTestEnv
        $hAckRace = New-CasIntHarness -Name 'ack-observation-race'
        $null = Invoke-CasIntProfile -Harness $hAckRace
        $bAckRace = Invoke-CasIntBuilder -Harness $hAckRace
        $tidAckRace = [string]$bAckRace.json.thread_id
        $ridAckRace = 'run-ack-observation-race'
        $firstAckRace = Invoke-CasIntLauncher -Harness $hAckRace -ThreadId $tidAckRace -RunId $ridAckRace
        Assert-CasInt ($firstAckRace.exit_code -eq 0) ("Ack-observation baseline launch failed: $($firstAckRace.stderr) $($firstAckRace.stdout)")
        $turnAckRace = [string](Get-CasIntBoundJson -Harness $hAckRace -RunId $ridAckRace).turn_id
        $baselineSettled = Wait-CasIntOfficialTerminalAndQuiet -Harness $hAckRace -RunId $ridAckRace -ThreadId $tidAckRace -TurnId $turnAckRace
        Assert-CasInt ([bool]$baselineSettled.success) 'Ack-observation baseline did not reach a quiet official terminal.'
        $pathsAckRace = Get-CodexAppServerRunPaths -StateRoot ([string]$hAckRace.state) -RunId $ridAckRace
        $probePath = Join-Path $fullTestRoot 'ack-observation-probe.ps1'
        $commonEsc = (Join-Path $runtimeRepoRoot 'src\lead-side\codex-app-server\CodexAppServerLead.Common.ps1').Replace("'", "''")
        $probeBody = @"
param([string]`$StateRoot, [string]`$RunId, [string]`$ThreadId)
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
. '$commonEsc'
`$paths = Get-CodexAppServerRunPaths -StateRoot `$StateRoot -RunId `$RunId
`$result = Wait-CodexAppServerWorkerAck -Paths `$paths -ThreadId `$ThreadId -AckExisted `$true -TimeoutSeconds 5
`$result | ConvertTo-Json -Depth 8 -Compress
"@
        [IO.File]::WriteAllText($probePath, $probeBody, [Text.UTF8Encoding]::new($false))
        $probeInfo = [Diagnostics.ProcessStartInfo]::new()
        $probeInfo.FileName = $pwsh
        $probeInfo.UseShellExecute = $false
        $probeInfo.RedirectStandardOutput = $true
        $probeInfo.RedirectStandardError = $true
        $probeInfo.CreateNoWindow = $true
        foreach ($arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $probePath, '-StateRoot', [string]$hAckRace.state, '-RunId', $ridAckRace, '-ThreadId', $tidAckRace)) { $probeInfo.ArgumentList.Add([string]$arg) }
        $lock = [IO.File]::Open($pathsAckRace.run, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $probe = $null
        try {
            $probe = [Diagnostics.Process]::Start($probeInfo)
            Assert-CasInt ($null -ne $probe) 'Ack-observation probe did not start.'
            $probeOutTask = $probe.StandardOutput.ReadToEndAsync()
            $probeErrTask = $probe.StandardError.ReadToEndAsync()
            Start-Sleep -Milliseconds 500
            Assert-CasInt (-not $probe.HasExited) 'Ack-observation probe failed instead of waiting for the transient run lock.'
        } finally {
            $lock.Dispose()
        }
        Assert-CasInt ($probe.WaitForExit(10000)) 'Ack-observation probe did not finish after the run lock was released.'
        $probeOut = [string]$probeOutTask.GetAwaiter().GetResult()
        $probeErr = [string]$probeErrTask.GetAwaiter().GetResult()
        $probeExit = [int]$probe.ExitCode
        $probe.Dispose()
        Assert-CasInt ($probeExit -eq 0) ("Ack-observation probe failed after lock release: $probeErr $probeOut")
        $probeJson = ($probeOut | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        Assert-CasInt ([bool]$probeJson.started -and [bool]$probeJson.existing) 'Ack-observation probe did not return the existing accepted wake.'
        Assert-CasInt ([string]$probeJson.state -ceq 'completed') 'Ack-observation probe lost the official terminal state.'
        $script:ackObservationRace = 1
        Clear-CasIntTestEnv
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            ack_observation_race = $ackObservationRace
            transient_lock_waited = 1
            exact_existing_ack = 1
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($F03TerminalReentryOnly) {
        Clear-CasIntTestEnv
        $hTerm = New-CasIntHarness -Name 'f03-focused-before-terminal-intent'
        $null = Invoke-CasIntProfile -Harness $hTerm
        $bTerm = Invoke-CasIntBuilder -Harness $hTerm
        $tidTerm = [string]$bTerm.json.thread_id
        $ridTerm = 'run-f03-focused-before-terminal-intent'
        $eventLog = Join-Path $hTerm.root 'events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLog
        $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = 'before-terminal-intent'
        $pathsTerm = Get-CodexAppServerRunPaths -StateRoot ([string]$hTerm.state) -RunId $ridTerm
        $ownerBoundBefore = Get-CasIntTransitionStateCount -Path ([string]$pathsTerm.transitions) -State 'owner_bound'
        $ownerIdentityBefore = Get-CasIntRunOwnerIdentityKey -Harness $hTerm -RunId $ridTerm
        $null = Invoke-CasIntLauncher -Harness $hTerm -ThreadId $tidTerm -RunId $ridTerm
        $world = [ordered]@{ harness = $hTerm; thread_id = $tidTerm; run_id = $ridTerm; paths = $pathsTerm }
        $crashed = Wait-CasIntRecoverForwardCrash -World $world -ExpectedPhase 'acknowledged' -OwnerBoundBefore $ownerBoundBefore -OwnerIdentityBefore $ownerIdentityBefore
        Assert-CasInt ([bool]$crashed.success) ("Focused F03 crash did not converge: phase=$([string]$crashed.phase) owner_bound=$([int]$crashed.owner_bound) baseline=$ownerBoundBefore owner_changed=$([bool]$crashed.owner_changed) owner_alive=$([bool]$crashed.owner_alive).")
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT -ErrorAction SilentlyContinue
        $turnTerm = [string](Get-CasIntBoundJson -Harness $hTerm -RunId $ridTerm).turn_id
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace($turnTerm)) 'Focused F03 crash never bound a turn.'
        $second = Invoke-CasIntLauncher -Harness $hTerm -ThreadId $tidTerm -RunId $ridTerm
        Assert-CasInt ($second.exit_code -eq 0) ("Focused F03 re-entry failed: $($second.stderr) $($second.stdout)")
        $settled = Wait-CasIntOfficialTerminalAndQuiet -Harness $hTerm -RunId $ridTerm -ThreadId $tidTerm -TurnId $turnTerm
        Assert-CasInt ([bool]$settled.success) ("Focused F03 re-entry did not settle: terminal=$([bool]$settled.terminal) run_quiet=$([bool]$settled.run_quiet) thread_quiet=$([bool]$settled.thread_quiet) phase=$([string]$settled.phase) state=$([string]$settled.state).")
        $runTerm = Get-CasIntRunJson -Harness $hTerm -RunId $ridTerm
        Assert-CasInt ([string]$runTerm.callback_write_phase -ceq 'terminal' -and [string]$runTerm.disposition -ceq 'completed') 'Focused F03 re-entry did not reach completed terminal.'
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hTerm -ThreadId $tidTerm).Count -eq 1) 'Focused F03 re-entry started another turn.'

        $declWorld = New-CasIntAckDeathWorld -Name 'f03-focused-declared-after-terminal-final' -RunId 'run-f03-focused-declared-after-terminal-final'
        Stop-CasIntThreadOwner -Harness $declWorld.harness -ThreadId $declWorld.thread_id
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $declWorld.harness -ThreadId $declWorld.thread_id -TimeoutMs 10000) 'Focused declared F03 kept the pre-injection thread owner alive.'
        Set-CasIntStoreTurnStatus -Harness $declWorld.harness -ThreadId $declWorld.thread_id -TurnId $declWorld.turn_id -Status 'completed'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$declWorld.event_log
        $env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS = 'completed'
        $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = 'after-terminal-final'
        $ownerBoundBefore = Get-CasIntTransitionStateCount -Path ([string]$declWorld.paths.transitions) -State 'owner_bound'
        $ownerIdentityBefore = Get-CasIntRunOwnerIdentityKey -Harness $declWorld.harness -RunId $declWorld.run_id
        $null = Invoke-CasIntLauncher -Harness $declWorld.harness -ThreadId $declWorld.thread_id -RunId $declWorld.run_id
        $declCrashed = Wait-CasIntRecoverForwardCrash -World $declWorld -ExpectedPhase 'terminal_publishing' -OwnerBoundBefore $ownerBoundBefore -OwnerIdentityBefore $ownerIdentityBefore
        Assert-CasInt ([bool]$declCrashed.success) ("Focused declared F03 crash did not converge: phase=$([string]$declCrashed.phase) owner_bound=$([int]$declCrashed.owner_bound) baseline=$ownerBoundBefore owner_changed=$([bool]$declCrashed.owner_changed) owner_alive=$([bool]$declCrashed.owner_alive).")
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT -ErrorAction SilentlyContinue
        $declSecond = Invoke-CasIntLauncher -Harness $declWorld.harness -ThreadId $declWorld.thread_id -RunId $declWorld.run_id
        Assert-CasInt ($declSecond.exit_code -eq 0) ("Focused declared F03 re-entry failed: $($declSecond.stderr) $($declSecond.stdout)")
        $declSettled = Wait-CasIntOfficialTerminalAndQuiet -Harness $declWorld.harness -RunId $declWorld.run_id -ThreadId $declWorld.thread_id -TurnId $declWorld.turn_id
        Assert-CasInt ([bool]$declSettled.success) ("Focused declared F03 re-entry did not settle: terminal=$([bool]$declSettled.terminal) run_quiet=$([bool]$declSettled.run_quiet) thread_quiet=$([bool]$declSettled.thread_quiet) phase=$([string]$declSettled.phase) state=$([string]$declSettled.state).")
        $declRun = Get-CasIntRunJson -Harness $declWorld.harness -RunId $declWorld.run_id
        Assert-CasInt ([string]$declRun.callback_write_phase -ceq 'terminal' -and [string]$declRun.disposition -ceq 'completed') 'Focused declared F03 re-entry did not reach completed terminal.'
        Clear-CasIntTestEnv
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            f03_terminal_reentry_only = $true
            crash_observed = 2
            official_terminal = 2
            owner_quiet = 2
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($R8ScopedCutOnly) {
        Clear-CasIntTestEnv
        $script:f02R8CutResults = [Collections.Generic.List[object]]::new()
        $script:f02R8ProcessDeathCuts = 0
        $focusedCut = $null
        foreach ($spec in @(Get-CasIntR8ScopedCutDefinitions)) {
            if ([string]$spec.name -ceq 'acknowledged:after-temp-flush') { $focusedCut = $spec; break }
        }
        Assert-CasInt ($null -ne $focusedCut) 'Focused R8 acknowledged:after-temp-flush cut is missing.'
        Invoke-CasIntR8ScopedCutCase -Spec $focusedCut
        Assert-CasInt ($script:f02R8ProcessDeathCuts -eq 1) 'Focused R8 cut did not execute exactly once.'
        Assert-CasInt ($script:f02R8CutResults.Count -eq 1 -and [bool]$script:f02R8CutResults[0].ok) 'Focused R8 cut did not record one successful result.'
        Clear-CasIntTestEnv
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            r8_scoped_cut_only = $true
            cut = [string]$focusedCut.name
            process_death_cuts = $f02R8ProcessDeathCuts
            successor = [string]$script:f02R8CutResults[0].successor
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($R8RecoveryRequiredCutOnly) {
        Clear-CasIntTestEnv
        $script:f02R8CutResults = [Collections.Generic.List[object]]::new()
        $script:f02R8ProcessDeathCuts = 0
        $focusedCut = $null
        foreach ($spec in @(Get-CasIntR8ScopedCutDefinitions)) {
            if ([string]$spec.name -ceq 'turn-start-sending:after-replace') { $focusedCut = $spec; break }
        }
        Assert-CasInt ($null -ne $focusedCut) 'Focused R8 turn-start-sending:after-replace cut is missing.'
        Invoke-CasIntR8ScopedCutCase -Spec $focusedCut
        Assert-CasInt ($script:f02R8ProcessDeathCuts -eq 1) 'Focused recovery_required R8 cut did not execute exactly once.'
        Assert-CasInt ($script:f02R8CutResults.Count -eq 1 -and [bool]$script:f02R8CutResults[0].ok) 'Focused recovery_required R8 cut did not record one successful result.'
        Clear-CasIntTestEnv
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            r8_recovery_required_cut_only = $true
            cut = [string]$focusedCut.name
            process_death_cuts = $f02R8ProcessDeathCuts
            successor = [string]$script:f02R8CutResults[0].successor
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($CallbackOwnerOnly) {
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $hCreate = New-CasIntHarness -Name 'owner-durable-create'
        $null = Invoke-CasIntProfile -Harness $hCreate
        $createLog = Join-Path $hCreate.root 'durable-create-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $createLog
        $createRunId = 'durable-create-owner-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1'
        $created = Invoke-CasIntDurableCreate -Harness $hCreate -RunId $createRunId
        Clear-CasIntTestEnv -Names @('TELEPHONE_TEST_APP_SERVER_EVENT_LOG')
        $createFailureDiagnostic = ''
        if ($created.exit_code -ne 0) { $createFailureDiagnostic = (Get-CasIntDurableCreateFailureDiagnostic -Harness $hCreate -RunId $createRunId -Result $created) | ConvertTo-Json -Depth 8 -Compress }
        Assert-CasInt ($created.exit_code -eq 0) ("Durable create failed: diagnostic=$createFailureDiagnostic public=$($created.stdout)")
        Assert-CasInt ($created.json.started -eq $true) 'Durable create did not start its first turn.'
        $createThread = [string]$created.json.thread_id
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace($createThread)) 'Durable create did not return a thread id.'
        Assert-CasInt ([IO.File]::Exists((Join-Path $hCreate.state ('runs\' + $createRunId + '\lead-wake-ack.json')))) 'Durable create did not publish first-turn acknowledgment.'
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hCreate -ThreadId $createThread).Count -eq 1) 'Durable create did not converge to exactly one first turn.'
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hCreate -RunId $createRunId) 'Durable create worker did not reach a coherent terminal.'
        $script:durableCreateSameProcess = 1
        $script:callbackOnce = 1

        $hCreateDiag = New-CasIntHarness -Name 'owner-durable-create-diagnostic'
        $null = Invoke-CasIntProfile -Harness $hCreateDiag
        $createDiagRunId = 'durable-create-owner-diagnostic'
        $env:TELEPHONE_TEST_APP_SERVER_CRASH_AT = 'before-thread-start'
        $createdDiag = Invoke-CasIntDurableCreate -Harness $hCreateDiag -RunId $createDiagRunId
        Clear-CasIntTestEnv
        Assert-CasInt ($createdDiag.exit_code -ne 0) 'Durable create diagnostic negative unexpectedly succeeded.'
        Assert-CasInt ([string]$script:casIntLastInvocation.kind -ceq 'durable-create' -and [string]$script:casIntLastInvocation.run_id -ceq $createDiagRunId -and [int]$script:casIntLastInvocation.result.exit_code -ne 0) 'Last-invocation diagnostic registry lost the durable-create negative.'
        $createDiag = Get-CasIntDurableCreateFailureDiagnostic -Harness $hCreateDiag -RunId $createDiagRunId -Result $createdDiag
        Assert-CasInt ([int]$createDiag.exit_code -ne 0) 'Durable create diagnostic lost the failing exit code.'
        Assert-CasInt ([bool]$createDiag.run_root_exists) 'Durable create diagnostic omitted the attempted run root.'
        Assert-CasInt (-not [bool]$createDiag.binding_exists) 'Durable create diagnostic negative published a binding.'
        Assert-CasInt (-not [bool]$createDiag.owner_alive -and -not [bool]$createDiag.child_alive) 'Durable create diagnostic negative left a live owner or child.'
        $script:durableCreateFailureDiagnostic = 1

        $hFifo = New-CasIntHarness -Name 'owner-fifo'
        $null = Invoke-CasIntProfile -Harness $hFifo
        $bFifo = Invoke-CasIntBuilder -Harness $hFifo
        $tidFifo = [string]$bFifo.json.thread_id
        $fifoLog = Join-Path $hFifo.root 'fifo-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $fifoLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '90000'
        $fifoIds = @('run-fifo-a', 'run-fifo-b', 'run-fifo-c')
        foreach ($rid in $fifoIds) {
            $wake = Invoke-CasIntLauncher -Harness $hFifo -ThreadId $tidFifo -RunId $rid
            Assert-CasInt ($wake.exit_code -eq 0) ("FIFO launcher $rid failed: $($wake.stderr) $($wake.stdout)")
            Assert-CasInt ([IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hFifo -RunId $rid) 'lead-wake-ack.json'))) ("FIFO $rid missing ack.")
        }
        $turnsFifo = @(Get-CasIntStoreTurns -Harness $hFifo -ThreadId $tidFifo)
        Assert-CasInt ($turnsFifo.Count -eq 3) ("FIFO did not produce three turns: $($turnsFifo.Count)")
        $startEvents = @(Get-Content -LiteralPath $fifoLog | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($startEvents.Count -eq 3) 'FIFO did not send exactly three turn/start records.'
        $fifoPids = @($startEvents | ForEach-Object { [regex]::Match([string]$_, '^process:(\d+):').Groups[1].Value } | Select-Object -Unique)
        Assert-CasInt ($fifoPids.Count -eq 1) 'FIFO used more than one app-server client process.'
        $acks = @()
        foreach ($rid in $fifoIds) {
            $ack = (Read-TelephoneJson -Path (Join-Path (Get-CasIntRunRoot -Harness $hFifo -RunId $rid) 'lead-wake-ack.json') -SchemaName 'codex-app-server-lead-ack').value
            $acks += [string]$ack.turn_id
        }
        Assert-CasInt ((@($acks | Select-Object -Unique)).Count -eq 3) 'FIFO acks were not three distinct turns.'
        $replay = Invoke-CasIntLauncher -Harness $hFifo -ThreadId $tidFifo -RunId 'run-fifo-a'
        Assert-CasInt ($replay.exit_code -eq 0) 'Same-intent replay failed.'
        Assert-CasInt ($replay.json.existing -eq $true) 'Same-intent replay did not attach.'
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hFifo -ThreadId $tidFifo).Count -eq 3) 'Same-intent replay started another turn.'
        $procA = Start-CasIntLauncherProcess -Harness $hFifo -ThreadId $tidFifo -RunId 'run-fifo-a'
        $procB = Start-CasIntLauncherProcess -Harness $hFifo -ThreadId $tidFifo -RunId 'run-fifo-a'
        $procA.process.WaitForExit()
        $procB.process.WaitForExit()
        $procA.process.Dispose()
        $procB.process.Dispose()
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hFifo -ThreadId $tidFifo).Count -eq 3) 'Concurrent replay created another turn.'
        foreach ($rid in $fifoIds) {
            Assert-CasInt (Wait-CasIntRunQuiet -Harness $hFifo -RunId $rid) ("FIFO $rid left a live per-run owner.")
        }
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hFifo -ThreadId $tidFifo -TimeoutMs 105000) 'FIFO thread owner did not quiesce.'
        Assert-CasInt (-not (Test-CasIntThreadOwnerAlive -Harness $hFifo -ThreadId $tidFifo)) 'Quiesce left a thread owner.'
        Clear-CasIntTestEnv

        $hCrash = New-CasIntHarness -Name 'owner-prebind-death'
        $null = Invoke-CasIntProfile -Harness $hCrash
        $bCrash = Invoke-CasIntBuilder -Harness $hCrash
        $tidCrash = [string]$bCrash.json.thread_id
        $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = 'before-write'
        $firstCrash = Invoke-CasIntLauncher -Harness $hCrash -ThreadId $tidCrash -RunId 'run-prebind-death'
        Clear-CasIntTestEnv
        Assert-CasInt ($firstCrash.exit_code -ne 0) 'Owner death before bind did not fail closed.'
        Assert-CasInt ([IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hCrash -RunId 'run-prebind-death') 'intent.json'))) 'Pre-bind death lost the durable queue item.'
        Stop-CasIntRun -Harness $hCrash -RunId 'run-prebind-death'
        $secondCrash = Invoke-CasIntLauncher -Harness $hCrash -ThreadId $tidCrash -RunId 'run-prebind-death'
        Assert-CasInt ($secondCrash.exit_code -eq 0) ("Pre-bind recovery failed: $($secondCrash.stderr) $($secondCrash.stdout)")
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hCrash -ThreadId $tidCrash).Count -eq 1) 'Pre-bind recovery did not keep one turn.'
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hCrash -RunId 'run-prebind-death') 'Pre-bind recovery left a live owner.'
        Stop-CasIntRun -Harness $hCrash -RunId 'run-prebind-death'

        $hPost = New-CasIntHarness -Name 'owner-post-send-loss'
        $null = Invoke-CasIntProfile -Harness $hPost
        $bPost = Invoke-CasIntBuilder -Harness $hPost
        $tidPost = [string]$bPost.json.thread_id
        $postLog = Join-Path $hPost.root 'post-send.log'
        $postHold = Join-Path $hPost.root 'post-send-hold'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $postLog
        $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $postHold
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $firstPost = Invoke-CasIntLauncher -Harness $hPost -ThreadId $tidPost -RunId 'run-post-send'
        Assert-CasInt ($firstPost.exit_code -eq 0) ("Post-send ack launch failed: $($firstPost.stderr) $($firstPost.stdout)")
        $boundPath = Join-Path (Get-CasIntRunRoot -Harness $hPost -RunId 'run-post-send') 'bound-turn.json'
        $ackPath = Join-Path (Get-CasIntRunRoot -Harness $hPost -RunId 'run-post-send') 'lead-wake-ack.json'
        $childPath = Join-Path (Get-CasIntRunRoot -Harness $hPost -RunId 'run-post-send') 'child.json'
        Assert-CasInt (Wait-CasIntPath -Path $boundPath) 'Post-send never bound a turn.'
        Assert-CasInt (Wait-CasIntPath -Path $ackPath) 'Post-send never published ack.'
        Assert-CasInt (Wait-CasIntPath -Path $childPath) 'Post-send child identity is missing.'
        $turnAfterSend = [string]((Read-TelephoneJson -Path $boundPath -SchemaName 'codex-app-server-lead-bound-turn').value.turn_id)
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace($turnAfterSend)) 'Post-send bound turn id was empty.'
        Assert-CasInt (Test-CasIntThreadOwnerAlive -Harness $hPost -ThreadId $tidPost) 'Post-send lost the live thread owner before child death.'
        $child = (Read-TelephoneJson -Path $childPath).value
        try { Stop-Process -Id ([int]$child.pid) -Force -ErrorAction SilentlyContinue } catch { }
        $deadBy = [DateTimeOffset]::UtcNow.AddSeconds(20)
        $postDisp = ''
        while ([DateTimeOffset]::UtcNow -lt $deadBy) {
            $postDisp = ''
            try { $postDisp = [string](Get-CasIntRunJson -Harness $hPost -RunId 'run-post-send').disposition } catch { $postDisp = '' }
            if ((-not (Test-CasIntThreadOwnerAlive -Harness $hPost -ThreadId $tidPost)) -and $postDisp -ceq 'recovery_required') { break }
            Start-Sleep -Milliseconds 50
        }
        Assert-CasInt (-not (Test-CasIntThreadOwnerAlive -Harness $hPost -ThreadId $tidPost)) 'Child/stdio loss left a live thread owner.'
        $runAfterLoss = Get-CasIntRunJson -Harness $hPost -RunId 'run-post-send'
        $boundAfterLoss = Get-CasIntBoundJson -Harness $hPost -RunId 'run-post-send'
        $failPath = Join-Path (Get-CasIntRunRoot -Harness $hPost -RunId 'run-post-send') 'failure.json'
        $recPath = Join-Path (Get-CasIntRunRoot -Harness $hPost -RunId 'run-post-send') 'recovery.json'
        $resPath = Join-Path (Get-CasIntRunRoot -Harness $hPost -RunId 'run-post-send') 'launcher-result.json'
        Assert-CasInt ([string]$runAfterLoss.disposition -ceq 'recovery_required') 'Child/stdio loss did not persist recovery_required on run.'
        Assert-CasInt ([string]$runAfterLoss.disposition -cne 'in_progress') 'Child/stdio loss left stale in_progress.'
        Assert-CasInt ([string]$boundAfterLoss.state -ceq 'recovery_required') 'Child/stdio loss bound state was not recovery_required.'
        Assert-CasInt ([string]$boundAfterLoss.turn_id -ceq $turnAfterSend) 'Child/stdio loss changed the bound turn.'
        Assert-CasInt ([string]$boundAfterLoss.thread_id -ceq $tidPost) 'Child/stdio loss bound a different thread.'
        Assert-CasInt ([IO.File]::Exists($failPath)) 'Child/stdio loss omitted failure.json.'
        Assert-CasInt ([IO.File]::Exists($recPath)) 'Child/stdio loss omitted recovery.json.'
        Assert-CasInt ([IO.File]::Exists($resPath)) 'Child/stdio loss omitted result.json.'
        $failAfterLoss = (Read-TelephoneJson -Path $failPath -SchemaName 'codex-app-server-lead-failure').value
        $recAfterLoss = (Read-TelephoneJson -Path $recPath -SchemaName 'codex-app-server-lead-recovery').value
        $resAfterLoss = (Read-TelephoneJson -Path $resPath -SchemaName 'codex-app-server-lead-result').value
        Assert-CasInt ([string]$failAfterLoss.thread_id -ceq $tidPost -and [string]$failAfterLoss.turn_id -ceq $turnAfterSend) 'Failure snapshot thread/turn drifted.'
        Assert-CasInt ([string]$recAfterLoss.thread_id -ceq $tidPost -and [string]$recAfterLoss.turn_id -ceq $turnAfterSend) 'Recovery declaration thread/turn drifted.'
        Assert-CasInt ([string]$resAfterLoss.state -ceq 'recovery_required') 'Official result was not recovery_required after child/stdio loss.'
        Assert-CasInt ([IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hPost -RunId 'run-post-send') 'intent.json'))) 'Child/stdio loss dropped the durable queue item.'
        $stLoss = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @('-StateRoot', [string]$hPost.state, '-RunId', 'run-post-send')
        Assert-CasInt ($stLoss.exit_code -eq 0) ("Status after child/stdio loss failed: $($stLoss.stderr)")
        Assert-CasInt ([string]$stLoss.json.items[0].callback_owner_state -ceq 'recovery_required') 'Status hid recovery_required after child/stdio loss.'
        Assert-CasInt ($stLoss.json.mutated -eq $false) 'Status mutated durable state after child/stdio loss.'
        $secondPost = Invoke-CasIntLauncher -Harness $hPost -ThreadId $tidPost -RunId 'run-post-send'
        Assert-CasInt ($secondPost.exit_code -eq 0) ("Post-send recovery failed: $($secondPost.stderr) $($secondPost.stdout)")
        $turnRecovered = [string]((Read-TelephoneJson -Path $ackPath -SchemaName 'codex-app-server-lead-ack').value.turn_id)
        Assert-CasInt ($turnRecovered -ceq $turnAfterSend) 'Post-send recovery replaced the bound turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $postLog -Name 'turn/start') -eq 1) 'Post-send recovery sent a replacement turn/start.'
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hPost -ThreadId $tidPost).Count -eq 1) 'Post-send recovery created another turn.'
        [IO.File]::WriteAllText($postHold, "release`n", [Text.UTF8Encoding]::new($false))
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hPost -RunId 'run-post-send') 'Post-send recovery left a live per-run owner.'
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hPost -ThreadId $tidPost -TimeoutMs 20000) 'Post-send recovery thread owner did not quiesce naturally.'
        Stop-CasIntRun -Harness $hPost -RunId 'run-post-send'
        Clear-CasIntTestEnv

        $hHold = New-CasIntHarness -Name 'owner-queued-behind-active'
        $null = Invoke-CasIntProfile -Harness $hHold
        $bHold = Invoke-CasIntBuilder -Harness $hHold
        $tidHold = [string]$bHold.json.thread_id
        $holdPath = Join-Path $hHold.root 'release-completed'
        $holdLog = Join-Path $hHold.root 'hold-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdPath
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $holdLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '20000'
        # This case proves queue ownership, not a two-second process-start SLA.
        # Leave enough room for a fresh hosted runner to start the mock client
        # while keeping the failure window bounded.
        $env:TELEPHONE_TEST_APP_SERVER_ACK_TIMEOUT_SECONDS = '15'
        $firstHold = Invoke-CasIntLauncher -Harness $hHold -ThreadId $tidHold -RunId 'run-hold-a'
        Assert-CasInt ($firstHold.exit_code -eq 0) ("Held first callback failed: $($firstHold.stderr) $($firstHold.stdout)")
        Assert-CasInt (Test-CasIntThreadOwnerAlive -Harness $hHold -ThreadId $tidHold) 'Held first callback has no live thread owner.'
        $threadPathsHold = Get-CodexAppServerThreadPaths -StateRoot ([string]$hHold.state) -ThreadId $tidHold
        $claimFailed = $false
        $claimCode = ''
        try {
            $null = Enter-CodexAppServerThreadOwner -ThreadPaths $threadPathsHold -ThreadId $tidHold -ActiveRunId 'run-second-claim'
        } catch {
            $claimFailed = $true
            $claimCode = [string]$_.Exception.Message
        }
        Assert-CasInt $claimFailed 'A second owner claim against a live exact owner was accepted.'
        Assert-CasInt ($claimCode -ceq (Get-CodexAppServerPublicMessage -Code 'THREAD_OWNER_CONFLICT')) 'Second owner claim omitted THREAD_OWNER_CONFLICT.'
        $competing = Invoke-CasIntWorker -Harness $hHold -ThreadId $tidHold -RunId 'run-second-claim'
        Assert-CasInt ($competing.exit_code -ne 0) 'Competing worker did not fail at the atomic owner claim.'
        Assert-CasInt (-not [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hHold -RunId 'run-second-claim') 'child.json'))) 'Competing owner claim started a second app-server client.'
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hHold -ThreadId $tidHold).Count -eq 1) 'Competing owner claim started a second turn.'
        $procQueued = Start-CasIntLauncherProcess -Harness $hHold -ThreadId $tidHold -RunId 'run-hold-b'
        Start-Sleep -Seconds 5
        Assert-CasInt (-not $procQueued.process.HasExited) 'Queued callback behind a live exact owner failed instead of remaining pending.'
        Assert-CasInt ([IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hHold -RunId 'run-hold-b') 'intent.json'))) 'Queued-behind-active callback dropped the durable item.'
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hHold -ThreadId $tidHold).Count -eq 1) 'Queued-behind-active callback started a second turn before the first finished.'
        [IO.File]::WriteAllText($holdPath, "release`n", [Text.UTF8Encoding]::new($false))
        $null = $procQueued.process.WaitForExit(120000)
        $queuedExit = [int]$procQueued.process.ExitCode
        $queuedOut = [string]$procQueued.stdout.GetAwaiter().GetResult()
        $procQueued.process.Dispose()
        Assert-CasInt ($queuedExit -eq 0) ("Queued callback did not complete after the prior turn: $queuedOut")
        Assert-CasInt (Wait-CasIntPath -Path (Join-Path (Get-CasIntRunRoot -Harness $hHold -RunId 'run-hold-b') 'lead-wake-ack.json')) 'Queued callback never received an ack.'
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hHold -ThreadId $tidHold).Count -eq 2) 'Queued callback did not produce exactly one additional marker turn.'
        $holdStarts = @(Get-Content -LiteralPath $holdLog | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($holdStarts.Count -eq 2) 'Queued-behind-active did not send exactly two turn/start records.'
        $holdPids = @($holdStarts | ForEach-Object { [regex]::Match([string]$_, '^process:(\d+):').Groups[1].Value } | Select-Object -Unique)
        Assert-CasInt ($holdPids.Count -eq 1) 'Queued-behind-active used more than one app-server client.'
        Stop-CasIntRun -Harness $hHold -RunId 'run-hold-a'
        Stop-CasIntRun -Harness $hHold -RunId 'run-hold-b'
        Clear-CasIntTestEnv

        $hOv = New-CasIntHarness -Name 'owner-overlap-b-attach'
        $null = Invoke-CasIntProfile -Harness $hOv
        $bOv = Invoke-CasIntBuilder -Harness $hOv
        $tidOv = [string]$bOv.json.thread_id
        $ovHold = Join-Path $hOv.root 'overlap-hold'
        $ovLog = Join-Path $hOv.root 'overlap-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $ovHold
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $ovLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $firstOv = Invoke-CasIntLauncher -Harness $hOv -ThreadId $tidOv -RunId 'run-overlap-a'
        Assert-CasInt ($firstOv.exit_code -eq 0) ("Overlap A failed: $($firstOv.stderr) $($firstOv.stdout)")
        Assert-CasInt (Test-CasIntThreadOwnerAlive -Harness $hOv -ThreadId $tidOv) 'Overlap A has no live thread owner.'
        $quietBusy = Wait-CasIntThreadOwnerQuiet -Harness $hOv -ThreadId $tidOv -TimeoutMs 400
        Assert-CasInt (-not $quietBusy) 'Wait-CasIntThreadOwnerQuiet returned true while the owner was still live.'
        Assert-CasInt (Test-CasIntThreadOwnerAlive -Harness $hOv -ThreadId $tidOv) 'Wait-CasIntThreadOwnerQuiet killed a live owner on timeout.'
        $pathsOvB = Get-CodexAppServerRunPaths -StateRoot ([string]$hOv.state) -RunId 'run-overlap-b'
        $procB1 = Start-CasIntLauncherProcess -Harness $hOv -ThreadId $tidOv -RunId 'run-overlap-b'
        $queuedBy = [DateTimeOffset]::UtcNow.AddSeconds(15)
        while ([DateTimeOffset]::UtcNow -lt $queuedBy) {
            if (
                [IO.File]::Exists($pathsOvB.intent) -and
                [IO.File]::Exists($pathsOvB.run) -and
                -not $procB1.process.HasExited
            ) { break }
            Start-Sleep -Milliseconds 50
        }
        Assert-CasInt (-not $procB1.process.HasExited) 'Overlap B launcher 1 exited before enqueue/ack wait.'
        Assert-CasInt ([IO.File]::Exists($pathsOvB.intent)) 'Overlap B dropped the durable intent.'
        Assert-CasInt ([IO.File]::Exists($pathsOvB.run)) 'Overlap B dropped the durable run.'
        Assert-CasInt (-not [IO.File]::Exists($pathsOvB.ack)) 'Overlap B received ack while A was still held.'
        $gateProbe = $null
        try {
            $gateProbe = Open-TelephoneExclusiveGate -Path ([string]$pathsOvB.gate) -WaitMilliseconds 500
            Assert-CasInt ($null -ne $gateProbe) 'Overlap B per-run gate was still held during ack wait; rejected pre-correction placement would fail this probe.'
            $f1GateReleasedBeforeAckWait = 1
        } finally {
            if ($null -ne $gateProbe) { $gateProbe.Dispose() }
        }
        Assert-CasInt ($f1GateReleasedBeforeAckWait -eq 1) 'F1 gate-release oracle did not record success.'
        $procB2 = Start-CasIntLauncherProcess -Harness $hOv -ThreadId $tidOv -RunId 'run-overlap-b'
        Start-Sleep -Milliseconds 400
        Assert-CasInt (-not $procB1.process.HasExited) 'Overlap B launcher 1 exited before A completed.'
        Assert-CasInt (-not $procB2.process.HasExited) 'Overlap B launcher 2 exited before A completed.'
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hOv -ThreadId $tidOv).Count -eq 1) 'Overlap B started a turn while A was still held.'
        $ovStartsHeld = @(Get-Content -LiteralPath $ovLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($ovStartsHeld.Count -eq 1) 'Overlap B sent turn/start while A was still held.'
        [IO.File]::WriteAllText($ovHold, "release`n", [Text.UTF8Encoding]::new($false))
        $null = $procB1.process.WaitForExit(120000)
        $null = $procB2.process.WaitForExit(120000)
        $b1Exit = [int]$procB1.process.ExitCode
        $b2Exit = [int]$procB2.process.ExitCode
        $b1Out = [string]$procB1.stdout.GetAwaiter().GetResult()
        $b2Out = [string]$procB2.stdout.GetAwaiter().GetResult()
        $procB1.process.Dispose()
        $procB2.process.Dispose()
        Assert-CasInt ($b1Exit -eq 0) ("Overlap B launcher 1 failed: $b1Out")
        Assert-CasInt ($b2Exit -eq 0) ("Overlap B launcher 2 failed: $b2Out")
        $ackB = Join-Path (Get-CasIntRunRoot -Harness $hOv -RunId 'run-overlap-b') 'lead-wake-ack.json'
        Assert-CasInt (Wait-CasIntPath -Path $ackB) 'Overlap B never published one ack.'
        $turnB = [string]((Read-TelephoneJson -Path $ackB -SchemaName 'codex-app-server-lead-ack').value.turn_id)
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace($turnB)) 'Overlap B ack turn id was empty.'
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hOv -ThreadId $tidOv).Count -eq 2) 'Overlap A/B did not converge to exactly two turns.'
        $ovStarts = @(Get-Content -LiteralPath $ovLog | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($ovStarts.Count -eq 2) 'Overlap A/B did not send exactly two turn/start records.'
        $ovPids = @($ovStarts | ForEach-Object { [regex]::Match([string]$_, '^process:(\d+):').Groups[1].Value } | Select-Object -Unique)
        Assert-CasInt ($ovPids.Count -eq 1) 'Overlap A/B used more than one app-server client.'
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hOv -RunId 'run-overlap-a') 'Overlap A left a live per-run owner.'
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hOv -RunId 'run-overlap-b') 'Overlap B left a live per-run owner.'
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hOv -ThreadId $tidOv -TimeoutMs 20000) 'Overlap thread owner did not quiesce naturally.'
        Assert-CasInt (-not (Test-CasIntThreadOwnerAlive -Harness $hOv -ThreadId $tidOv)) 'Overlap quiesce left a live thread owner.'
        Stop-CasIntRun -Harness $hOv -RunId 'run-overlap-a'
        Stop-CasIntRun -Harness $hOv -RunId 'run-overlap-b'
        Clear-CasIntTestEnv

        $hSt = New-CasIntHarness -Name 'owner-status-authoritative'
        $null = Invoke-CasIntProfile -Harness $hSt
        $bSt = Invoke-CasIntBuilder -Harness $hSt
        $tidSt = [string]$bSt.json.thread_id
        $statusCases = @(
            @{ run = 'run-status-completed'; disp = 'completed'; phase = 'terminal'; target = 'completed'; expect = 'completed' },
            @{ run = 'run-status-failed'; disp = 'failed'; phase = 'terminal'; target = 'failed'; expect = 'failed' },
            @{ run = 'run-status-interrupted'; disp = 'interrupted'; phase = 'terminal'; target = 'interrupted'; expect = 'failed' },
            @{ run = 'run-status-recovery'; disp = 'recovery_required'; phase = 'acknowledged'; target = ''; expect = 'recovery_required' },
            @{ run = 'run-status-recovered'; disp = 'recovered'; phase = 'acknowledged'; target = ''; expect = 'recovered' }
        )
        foreach ($sc in $statusCases) {
            $sp = Write-CasIntPlantedIntent -Harness $hSt -RunId ([string]$sc.run) -ThreadId $tidSt
            Write-CasIntPlantedRun -Paths $sp -Harness $hSt -RunId ([string]$sc.run) -ThreadId $tidSt -Selected 'turn-status' -Disposition ([string]$sc.disp) -Phase ([string]$sc.phase) -TerminalTarget ([string]$sc.target)
            $null = Write-CodexAppServerProjectedStatus -Path $sp.status -ThreadId $tidSt -Status 'active' -ActiveFlags @() -Pending @() -CallbackOwnerState 'callback_active'
            $st = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @('-StateRoot', [string]$hSt.state, '-RunId', [string]$sc.run)
            Assert-CasInt ($st.exit_code -eq 0) ("Authoritative status $($sc.expect) failed: $($st.stderr)")
            Assert-CasInt ([string]$st.json.items[0].callback_owner_state -ceq [string]$sc.expect) ("Stale callback_active overrode durable $($sc.expect).")
            Assert-CasInt ($st.json.mutated -eq $false) 'Status mutated planted durable state.'
        }

        Clear-CasIntTestEnv
        $hFail = New-CasIntHarness -Name 'owner-fail-closed'
        $null = Invoke-CasIntProfile -Harness $hFail
        $bFail = Invoke-CasIntBuilder -Harness $hFail
        $tidFail = [string]$bFail.json.thread_id
        $firstFail = Invoke-CasIntLauncher -Harness $hFail -ThreadId $tidFail -RunId 'run-cross-thread'
        Assert-CasInt ($firstFail.exit_code -eq 0) ("Cross-thread baseline callback failed: $($firstFail.stderr) $($firstFail.stdout)")
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hFail -RunId 'run-cross-thread') 'Cross-thread baseline left a live owner.'
        Stop-CasIntRun -Harness $hFail -RunId 'run-cross-thread'
        $badThread = Invoke-CasIntLauncher -Harness $hFail -ThreadId 'thread-other-id' -RunId 'run-cross-thread'
        Assert-CasInt ($badThread.exit_code -ne 0) 'Cross-thread callback was not fail-closed.'
        Clear-CasIntTestEnv
        $hMis = New-CasIntHarness -Name 'owner-identity-drift'
        $null = Invoke-CasIntProfile -Harness $hMis
        $bMis = Invoke-CasIntBuilder -Harness $hMis
        $tidMis = [string]$bMis.json.thread_id
        $firstMis = Invoke-CasIntLauncher -Harness $hMis -ThreadId $tidMis -RunId 'run-identity'
        Assert-CasInt ($firstMis.exit_code -eq 0) ("Identity baseline callback failed: $($firstMis.stderr) $($firstMis.stdout)")
        Wait-CasIntRunQuiet -Harness $hMis -RunId 'run-identity' | Out-Null
        Stop-CasIntRun -Harness $hMis -RunId 'run-identity'
        [IO.File]::WriteAllText($hMis.prompt, "changed callback bytes`n", [Text.UTF8Encoding]::new($false))
        $drift = Invoke-CasIntLauncher -Harness $hMis -ThreadId $tidMis -RunId 'run-identity'
        Assert-CasInt ($drift.exit_code -ne 0) 'Changed callback content was not fail-closed.'
        $hWt = New-CasIntHarness -Name 'owner-cross-worktree'
        $null = Invoke-CasIntProfile -Harness $hWt
        $bWt = Invoke-CasIntBuilder -Harness $hWt
        $tidWt = [string]$bWt.json.thread_id
        $pathsWt = Get-CodexAppServerRunPaths -StateRoot ([string]$hWt.state) -RunId 'run-cross-worktree'
        [IO.Directory]::CreateDirectory($pathsWt.run_root) | Out-Null
        $identityWt = Get-TelephoneFileIdentity -Path ([string]$hWt.prompt)
        $profileWt = (Read-TelephoneJson -Path ([string]$hWt.profile) -SchemaName 'codex-app-server-lead-profile').value
        $compatWt = Get-CodexAppServerCompatibilityIdentity -Profile $profileWt -ProfilePath ([string]$hWt.profile)
        $null = Write-CodexAppServerValidatedReplace -Path $pathsWt.intent -Value ([ordered]@{
            protocol_version = 'telephone-line-codex-app-server-lead-intent-v1'
            run_id = 'run-cross-worktree'
            thread_id = $tidWt
            worktree = (Join-Path $hWt.root 'other-worktree')
            callback = [ordered]@{ path = [string]$identityWt.path; bytes = [int64]$identityWt.bytes; sha256 = [string]$identityWt.sha256 }
            wake_marker = Get-CodexAppServerWakeMarker -RunId 'run-cross-worktree'
            profile_fingerprint = [string]$compatWt.profile_fingerprint
            codex_version = [string]$compatWt.codex_version
            executable_sha256 = [string]$compatWt.executable_sha256
            profile_sha256 = [string]$compatWt.profile_sha256
            codex_command = [string]$compatWt.codex_command
            service_tier = [string]$compatWt.service_tier
            baseline_turn_ids = @()
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }) -SchemaName 'codex-app-server-lead-intent'
        $crossWt = Invoke-CasIntLauncher -Harness $hWt -ThreadId $tidWt -RunId 'run-cross-worktree'
        Assert-CasInt ($crossWt.exit_code -ne 0) 'Cross-worktree queue state was not fail-closed.'
        $malOwner = Get-CodexAppServerThreadPaths -StateRoot ([string]$hFail.state) -ThreadId $tidFail
        [IO.Directory]::CreateDirectory($malOwner.thread_root) | Out-Null
        [IO.File]::WriteAllText($malOwner.owner, "{`"pid`":1}`n", [Text.UTF8Encoding]::new($false))
        $beforeMal = [IO.File]::ReadAllText($malOwner.owner)
        $mal = Invoke-CasIntLauncher -Harness $hFail -ThreadId $tidFail -RunId 'run-malformed-owner'
        Assert-CasInt ($mal.exit_code -ne 0) 'Malformed thread owner was treated as replaceable.'
        Assert-CasInt ([IO.File]::ReadAllText($malOwner.owner) -ceq $beforeMal) 'Malformed thread owner was replaced.'

        $identitySpecs = @(
            @{ name = 'wrong-thread'; thread_id = 'thread-other-id'; omit = $false },
            @{ name = 'missing-thread'; thread_id = ''; omit = $true }
        )
        foreach ($spec in $identitySpecs) {
            Clear-CasIntTestEnv
            $hId = New-CasIntHarness -Name ('owner-identity-' + [string]$spec.name)
            $null = Invoke-CasIntProfile -Harness $hId
            $bId = Invoke-CasIntBuilder -Harness $hId
            $tidId = [string]$bId.json.thread_id
            $idPaths = Get-CodexAppServerThreadPaths -StateRoot ([string]$hId.state) -ThreadId $tidId
            [IO.Directory]::CreateDirectory($idPaths.thread_root) | Out-Null
            if ([bool]$spec.omit) {
                $plantedOwner = New-CodexAppServerOwnerRecord
            } else {
                $plantedOwner = New-CodexAppServerOwnerRecord -ThreadId ([string]$spec.thread_id)
            }
            $null = Write-CodexAppServerValidatedReplace -Path $idPaths.owner -Value $plantedOwner -SchemaName 'codex-app-server-lead-owner'
            $beforeOwner = [IO.File]::ReadAllText($idPaths.owner)
            $aliveThrew = $false
            try { $null = Test-CodexAppServerThreadOwnerAlive -ThreadPaths $idPaths } catch { $aliveThrew = $true }
            Assert-CasInt $aliveThrew ("Invalid $($spec.name) thread owner was treated as ordinary dead/absent.")
            $enterThrew = $false
            $enterMsg = ''
            try {
                $null = Enter-CodexAppServerThreadOwner -ThreadPaths $idPaths -ThreadId $tidId -ActiveRunId ('run-' + [string]$spec.name)
            } catch {
                $enterThrew = $true
                $enterMsg = [string]$_.Exception.Message
            }
            Assert-CasInt $enterThrew ("Invalid $($spec.name) thread owner was replaceable by Enter.")
            Assert-CasInt ($enterMsg -ceq (Get-CodexAppServerPublicMessage -Code 'OWNER_INVALID')) ("Invalid $($spec.name) owner omitted OWNER_INVALID.")
            Assert-CasInt ([IO.File]::ReadAllText($idPaths.owner) -ceq $beforeOwner) ("Enter replaced the $($spec.name) owner record.")
            $idLaunch = Invoke-CasIntLauncher -Harness $hId -ThreadId $tidId -RunId ('run-' + [string]$spec.name)
            Assert-CasInt ($idLaunch.exit_code -ne 0) ("Launcher did not fail closed on $($spec.name) thread owner.")
            Assert-CasInt ([string]$idLaunch.json.code -ceq 'OWNER_INVALID' -or [string]$idLaunch.json.error -ceq (Get-CodexAppServerPublicMessage -Code 'OWNER_INVALID')) ("Launcher omitted OWNER_INVALID for $($spec.name).")
            Assert-CasInt ([IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hId -RunId ('run-' + [string]$spec.name)) 'intent.json'))) ("Launcher dropped the queued item for $($spec.name).")
            Assert-CasInt ([IO.File]::ReadAllText($idPaths.owner) -ceq $beforeOwner) ("Launcher mutated the $($spec.name) owner evidence.")
            Assert-CasInt (-not [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hId -RunId ('run-' + [string]$spec.name)) 'child.json'))) ("Invalid $($spec.name) owner started an app-server client.")
            Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hId -ThreadId $tidId).Count -eq 0) ("Invalid $($spec.name) owner started a turn.")
            Complete-CodexAppServerThreadOwnerQuiesce -ThreadPaths $idPaths -Client $null
            Assert-CasInt ([IO.File]::Exists($idPaths.owner) -and ([IO.File]::ReadAllText($idPaths.owner) -ceq $beforeOwner)) ("Quiesce deleted the $($spec.name) owner record.")
            [IO.File]::Delete($idPaths.owner)
            $idRecover = Invoke-CasIntLauncher -Harness $hId -ThreadId $tidId -RunId ('run-' + [string]$spec.name)
            Assert-CasInt ($idRecover.exit_code -eq 0) ("Recovery after removing $($spec.name) owner failed: $($idRecover.stderr) $($idRecover.stdout)")
            Assert-CasInt (Wait-CasIntPath -Path (Join-Path (Get-CasIntRunRoot -Harness $hId -RunId ('run-' + [string]$spec.name)) 'lead-wake-ack.json')) ("Recovery after $($spec.name) did not publish ack.")
            Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hId -ThreadId $tidId).Count -eq 1) ("Recovery after $($spec.name) did not consume the queued item exactly once.")
            Stop-CasIntRun -Harness $hId -RunId ('run-' + [string]$spec.name)
        }

        $hCli = New-CasIntHarness -Name 'owner-cli-fallback'
        $null = Invoke-CasIntProfile -Harness $hCli
        $cliBinding = Invoke-CasIntBuilder -Harness $hCli -ResumeSessionId 'cli-session-1' -Transport 'cli' -CliLauncher $cliSpy
        Assert-CasInt ($cliBinding.exit_code -eq 0) ("Explicit CLI binding failed: $($cliBinding.stderr)")
        Assert-CasInt ([string]$cliBinding.json.callback_transport -ceq 'cli') 'Explicit CLI transport was not recorded.'
        $script:explicitFallback = 1

        $statusH = New-CasIntHarness -Name 'owner-status'
        $null = Invoke-CasIntProfile -Harness $statusH
        $statusPaths = Write-CasIntPlantedIntent -Harness $statusH -RunId 'run-status-queued' -ThreadId 'thread-status'
        Write-CasIntPlantedRun -Paths $statusPaths -Harness $statusH -RunId 'run-status-queued' -ThreadId 'thread-status' -Disposition 'in_progress' -Phase 'none' -QueueState 'queued'
        $null = Write-CodexAppServerProjectedStatus -Path $statusPaths.status -ThreadId 'thread-status' -Status 'idle' -ActiveFlags @() -Pending @() -CallbackOwnerState 'queued'
        $st = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @('-StateRoot', [string]$statusH.state, '-RunId', 'run-status-queued')
        Assert-CasInt ($st.exit_code -eq 0) 'Status probe failed.'
        Assert-CasInt ([string]$st.json.items[0].callback_owner_state -ceq 'queued') 'Status did not project queued.'
        Assert-CasInt ($st.json.mutated -eq $false -and $st.json.started -eq $false) 'Status mutated callback state.'
        Assert-CasInt ([IO.File]::Exists($statusPaths.intent) -and [IO.File]::Exists($statusPaths.run)) 'Queued status omitted durable intent/run.'
        Assert-CasInt ([string](Get-CasIntRunJson -Harness $statusH -RunId 'run-status-queued').queue_state -ceq 'queued') 'Queued status run was not queue_state=queued.'

        $starter = Join-Path $runtimeRepoRoot 'src\core\Start-TelephoneLineJob.ps1'
        $resumeScript = Join-Path $runtimeRepoRoot 'src\core\Resume-TelephoneLines.ps1'
        $mockRoute = Join-Path $repoRoot 'tests\core\fixtures\mock-route.ps1'
        . (Join-Path $runtimeRepoRoot 'src\dashboard\TelephoneDashboard.Common.ps1')
        . (Join-Path $runtimeRepoRoot 'src\dashboard\TelephoneDashboard.Projection.ps1')

        $hNative = New-CasIntHarness -Name 'owner-app-native-active-turn'
        $null = Invoke-CasIntProfile -Harness $hNative
        $bNative = Invoke-CasIntBuilder -Harness $hNative
        $tidNative = [string]$bNative.json.thread_id
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace($tidNative)) 'App-native oracle did not bind a thread.'
        $nativeTurn = 'turn-dispatch-owning-1'
        $nativeHold = Join-Path $hNative.root 'release-owning-turn'
        $nativeLog = Join-Path $hNative.root 'native-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $nativeLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '20000'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_TURN_ID = $nativeTurn
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_HOLD_PATH = $nativeHold
        $telState = Join-Path $hNative.root 'telephone-state'
        [IO.Directory]::CreateDirectory($telState) | Out-Null
        $counterPath = Join-Path $hNative.root 'route-count.txt'
        $bindingNative = (Read-TelephoneJson -Path ([string]$hNative.binding) -SchemaName 'lead-binding').value
        $jobIdNative = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        $requestPath = Join-Path $hNative.root 'request.json'
        $launcherArgs = @()
        if ($null -ne $bindingNative.launcher.arguments) {
            $launcherArgs = @($bindingNative.launcher.arguments | ForEach-Object { [string]$_ })
        }
        $null = Write-TelephoneJsonCreateNew -Path $requestPath -Value ([ordered]@{
            protocol_version = 'telephone-line-dispatch-v1'
            line_job_id = $jobIdNative
            project = 'app-native-active-turn'
            stage = 'SIMULATION'
            role = 'execution'
            route = 'mock-route'
            summary = 'bounded no-product receipt'
            lead = $bindingNative
            command = [ordered]@{
                executable = $pwsh
                working_directory = [string]$hNative.root
                arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $mockRoute, '-CounterPath', $counterPath, '-DelayMilliseconds', '0', '-FinalText', 'DONE-execution')
            }
        })
        $startedJob = Invoke-CasIntScript -ScriptPath $starter -Arguments @('-RequestFile', $requestPath, '-StateRoot', $telState)
        Assert-CasInt ($startedJob.exit_code -eq 0) ("App-native telephone start failed: $($startedJob.stderr) $($startedJob.stdout)")
        $jobRootNative = Join-Path $telState ('jobs\' + $jobIdNative)
        $jobPathsNative = Get-TelephoneJobPaths -JobRoot $jobRootNative
        $wakeRunId = 'telephone-' + $jobIdNative
        Assert-CasInt (Wait-CasIntPath -Path $jobPathsNative.receipt -TimeoutMs 30000) 'App-native oracle never published a receipt.'
        Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 20000 -Predicate {
            [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hNative -RunId $wakeRunId) 'intent.json'))
        }) 'App-native pending callback did not persist intent.'
        Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 20000 -Predicate {
            try {
                $runNow = Get-CasIntRunJson -Harness $hNative -RunId $wakeRunId
                return ([string]$runNow.queue_state -ceq 'queued' -and [string]$runNow.callback_write_phase -ceq 'none')
            } catch { return $false }
        }) 'App-native pending callback was not queue_state=queued.'
        $stPending = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @('-StateRoot', [string]$hNative.state, '-RunId', $wakeRunId)
        Assert-CasInt ($stPending.exit_code -eq 0) ("Pending status probe failed: $($stPending.stderr)")
        Assert-CasInt ([string]$stPending.json.items[0].callback_owner_state -ceq 'queued') 'Owner-alive pending wait was not projected queued.'
        Assert-CasInt (-not [IO.File]::Exists($jobPathsNative.delivery)) 'App-native pending published delivery before the owning turn released.'
        Assert-CasInt (-not [IO.File]::Exists($jobPathsNative.relay_error)) 'App-native pending published LEAD_WAKE_AMBIGUOUS/relay-error.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hNative -ThreadId $tidNative -RunId $wakeRunId).Count -eq 0) 'App-native pending started a marker callback turn.'
        Assert-CasInt ((Get-CasIntEventCount -Path $nativeLog -Name ('process:' + '*')) -eq 0 -or (Get-CasIntEventCount -Path $nativeLog -Name 'turn/start') -eq 0) 'App-native pending sent turn/start.'
        $startEventsHeld = @(Get-Content -LiteralPath $nativeLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($startEventsHeld.Count -eq 0) 'App-native pending sent a process turn/start while the owning turn was active.'
        Assert-CasInt ((Get-CasIntCounterCount -Path $counterPath) -eq 1) 'App-native executor invocation count was not exactly one during pending.'
        $pendingScan = Get-TelephoneDashboardJobScan -JobRoot $jobRootNative
        $pendingCodes = @($pendingScan.findings | ForEach-Object { [string]$_.code })
        Assert-CasInt ($pendingCodes -contains 'CALLBACK_MISSING') 'Dashboard hid Telephone callback pending.'
        Assert-CasInt ($pendingCodes -notcontains 'LOST_RELAY') 'Dashboard classified pending as lost relay/product failure.'
        $script:dashboardPendingNotExecutorFailure = 1
        $script:appNativeActiveTurnPending = 1

        [IO.File]::WriteAllText($nativeHold, "release`n", [Text.UTF8Encoding]::new($false))
        $delivered = Wait-CasIntPath -Path $jobPathsNative.delivery -TimeoutMs 60000
        if (-not $delivered) {
            $runRootNow = Get-CasIntRunRoot -Harness $hNative -RunId $wakeRunId
            $diag = [ordered]@{
                owner_alive = (Test-CasIntThreadOwnerAlive -Harness $hNative -ThreadId $tidNative)
                ack = [IO.File]::Exists((Join-Path $runRootNow 'lead-wake-ack.json'))
                relay_error = [IO.File]::Exists($jobPathsNative.relay_error)
                launch_result = [IO.File]::Exists($jobPathsNative.wake_launch_result)
                queue_state = ''
                phase = ''
                turns = @(Get-CasIntStoreTurns -Harness $hNative -ThreadId $tidNative | ForEach-Object { [string]$_.id + ':' + [string]$_.status })
            }
            try {
                $runNow = Get-CasIntRunJson -Harness $hNative -RunId $wakeRunId
                $diag.queue_state = [string]$runNow.queue_state
                $diag.phase = [string]$runNow.callback_write_phase
            } catch { }
            if ([IO.File]::Exists($jobPathsNative.relay_error)) { $diag.relay_error_body = (Get-Content -LiteralPath $jobPathsNative.relay_error -Raw) }
            throw ("App-native callback never delivered after the owning turn released: " + ($diag | ConvertTo-Json -Compress -Depth 6))
        }
        Assert-CasInt (Wait-CasIntPath -Path (Join-Path (Get-CasIntRunRoot -Harness $hNative -RunId $wakeRunId) 'lead-wake-ack.json') -TimeoutMs 30000) 'App-native callback never published ack.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hNative -ThreadId $tidNative -RunId $wakeRunId).Count -eq 1) 'App-native release did not produce exactly one marker turn.'
        $startEventsDone = @(Get-Content -LiteralPath $nativeLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($startEventsDone.Count -eq 1) 'App-native release did not send exactly one turn/start.'
        Assert-CasInt (-not [IO.File]::Exists($jobPathsNative.relay_error)) 'App-native delivery left a relay-error.'
        $receiptDoc = (Read-TelephoneJson -Path $jobPathsNative.receipt -SchemaName 'receipt').value
        $deliveryDoc = (Read-TelephoneJson -Path $jobPathsNative.delivery).value
        Assert-CasInt ([string]$receiptDoc.line_job_id -ceq $jobIdNative) 'Delivered receipt job id drifted.'
        Assert-CasInt ([string]$deliveryDoc.wake_run_id -ceq $wakeRunId) 'Delivery wake run drifted.'
        Assert-CasInt ((Get-CasIntCounterCount -Path $counterPath) -eq 1) 'App-native delivery reran the executor.'
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hNative -RunId $wakeRunId) 'App-native delivery left a live per-run owner.'
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hNative -ThreadId $tidNative -TimeoutMs 25000) 'App-native thread owner did not quiesce.'
        Stop-CasIntTelephoneJob -JobRoot $jobRootNative
        Stop-CasIntRun -Harness $hNative -RunId $wakeRunId
        $script:appNativeActiveTurnDelivery = 1
        $script:appNativeExecutorOnce = 1
        Clear-CasIntTestEnv

        $hRs = New-CasIntHarness -Name 'owner-pending-restart'
        $null = Invoke-CasIntProfile -Harness $hRs
        $bRs = Invoke-CasIntBuilder -Harness $hRs
        $tidRs = [string]$bRs.json.thread_id
        $rsHold = Join-Path $hRs.root 'release-restart-owning'
        $rsLog = Join-Path $hRs.root 'restart-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $rsLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '20000'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_TURN_ID = 'turn-restart-owning'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_HOLD_PATH = $rsHold
        $procRs1 = Start-CasIntLauncherProcess -Harness $hRs -ThreadId $tidRs -RunId 'run-pending-restart'
        Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 15000 -Predicate {
            try {
                $runNow = Get-CasIntRunJson -Harness $hRs -RunId 'run-pending-restart'
                return ([string]$runNow.queue_state -ceq 'queued' -and [string]$runNow.callback_write_phase -ceq 'none')
            } catch { return $false }
        }) 'Pending-restart launcher did not persist queued state.'
        Stop-CasIntRun -Harness $hRs -RunId 'run-pending-restart'
        $procRs2 = Start-CasIntLauncherProcess -Harness $hRs -ThreadId $tidRs -RunId 'run-pending-restart'
        $procRs3 = Start-CasIntLauncherProcess -Harness $hRs -ThreadId $tidRs -RunId 'run-pending-restart'
        Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 15000 -Predicate {
            -not $procRs2.process.HasExited -and -not $procRs3.process.HasExited
        }) 'Pending-restart recovery launchers exited before release.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hRs -ThreadId $tidRs -RunId 'run-pending-restart').Count -eq 0) 'Pending restart sent a marker before release.'
        [IO.File]::WriteAllText($rsHold, "release`n", [Text.UTF8Encoding]::new($false))
        $null = $procRs2.process.WaitForExit(120000)
        $null = $procRs3.process.WaitForExit(120000)
        if (-not $procRs1.process.HasExited) { $null = $procRs1.process.WaitForExit(5000) }
        Assert-CasInt ([int]$procRs2.process.ExitCode -eq 0 -or [int]$procRs3.process.ExitCode -eq 0) 'Pending-restart recovery did not complete a launcher.'
        $procRs1.process.Dispose()
        $procRs2.process.Dispose()
        $procRs3.process.Dispose()
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hRs -ThreadId $tidRs -RunId 'run-pending-restart').Count -eq 1) 'Pending restart did not converge to one marker turn.'
        $rsStarts = @(Get-Content -LiteralPath $rsLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($rsStarts.Count -eq 1) 'Pending restart sent more than one turn/start.'
        Stop-CasIntRun -Harness $hRs -RunId 'run-pending-restart'
        $script:pendingRestartRecovery = 1
        Clear-CasIntTestEnv

        $hDup = New-CasIntHarness -Name 'owner-app-native-duplicate-launcher'
        $null = Invoke-CasIntProfile -Harness $hDup
        $bDup = Invoke-CasIntBuilder -Harness $hDup
        $tidDup = [string]$bDup.json.thread_id
        $dupHold = Join-Path $hDup.root 'release-dup-owning'
        $dupLog = Join-Path $hDup.root 'dup-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $dupLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '20000'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_TURN_ID = 'turn-dup-owning'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_HOLD_PATH = $dupHold
        $procDup1 = Start-CasIntLauncherProcess -Harness $hDup -ThreadId $tidDup -RunId 'run-dup-a'
        $procDup2 = Start-CasIntLauncherProcess -Harness $hDup -ThreadId $tidDup -RunId 'run-dup-a'
        Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 15000 -Predicate {
            [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hDup -RunId 'run-dup-a') 'intent.json')) -and
            -not $procDup1.process.HasExited -and
            -not $procDup2.process.HasExited
        }) 'Duplicate launchers did not remain pending behind the App-native owning turn.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hDup -ThreadId $tidDup -RunId 'run-dup-a').Count -eq 0) 'Duplicate launchers started a callback turn before release.'
        [IO.File]::WriteAllText($dupHold, "release`n", [Text.UTF8Encoding]::new($false))
        $null = $procDup1.process.WaitForExit(120000)
        $null = $procDup2.process.WaitForExit(120000)
        Assert-CasInt ([int]$procDup1.process.ExitCode -eq 0) 'Duplicate launcher 1 failed after release.'
        Assert-CasInt ([int]$procDup2.process.ExitCode -eq 0) 'Duplicate launcher 2 failed after release.'
        $procDup1.process.Dispose()
        $procDup2.process.Dispose()
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hDup -ThreadId $tidDup -RunId 'run-dup-a').Count -eq 1) 'Duplicate launchers did not converge to one marker turn.'
        $dupStarts = @(Get-Content -LiteralPath $dupLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($dupStarts.Count -eq 1) 'Duplicate launchers sent more than one turn/start.'
        Stop-CasIntRun -Harness $hDup -RunId 'run-dup-a'
        $script:pendingDuplicateLauncher = 1
        Clear-CasIntTestEnv

        $hFifoN = New-CasIntHarness -Name 'owner-fifo-after-app-native'
        $null = Invoke-CasIntProfile -Harness $hFifoN
        $bFifoN = Invoke-CasIntBuilder -Harness $hFifoN
        $tidFifoN = [string]$bFifoN.json.thread_id
        $fifoNHold = Join-Path $hFifoN.root 'release-fifo-owning'
        $fifoNLog = Join-Path $hFifoN.root 'fifo-native.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $fifoNLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '20000'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_TURN_ID = 'turn-fifo-owning'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_HOLD_PATH = $fifoNHold
        $procFa = Start-CasIntLauncherProcess -Harness $hFifoN -ThreadId $tidFifoN -RunId 'run-fifo-native-a'
        $procFb = Start-CasIntLauncherProcess -Harness $hFifoN -ThreadId $tidFifoN -RunId 'run-fifo-native-b'
        Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 15000 -Predicate {
            [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hFifoN -RunId 'run-fifo-native-a') 'intent.json')) -and
            [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hFifoN -RunId 'run-fifo-native-b') 'intent.json'))
        }) 'FIFO-behind-native did not persist both queued intents.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hFifoN -ThreadId $tidFifoN -RunId 'run-fifo-native-a').Count -eq 0 -and @(Get-CasIntMarkerStoreTurns -Harness $hFifoN -ThreadId $tidFifoN -RunId 'run-fifo-native-b').Count -eq 0) 'FIFO-behind-native started a callback before the owning turn released.'
        [IO.File]::WriteAllText($fifoNHold, "release`n", [Text.UTF8Encoding]::new($false))
        $null = $procFa.process.WaitForExit(120000)
        $null = $procFb.process.WaitForExit(120000)
        Assert-CasInt ([int]$procFa.process.ExitCode -eq 0) 'FIFO-native A failed after release.'
        Assert-CasInt ([int]$procFb.process.ExitCode -eq 0) 'FIFO-native B failed after release.'
        $procFa.process.Dispose()
        $procFb.process.Dispose()
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hFifoN -ThreadId $tidFifoN -RunId 'run-fifo-native-a').Count -eq 1) 'FIFO-native A missing marker.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hFifoN -ThreadId $tidFifoN -RunId 'run-fifo-native-b').Count -eq 1) 'FIFO-native B missing marker.'
        $fifoNStarts = @(Get-Content -LiteralPath $fifoNLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($fifoNStarts.Count -eq 2) 'FIFO-behind-native did not send exactly two marker turns after release.'
        Stop-CasIntRun -Harness $hFifoN -RunId 'run-fifo-native-a'
        Stop-CasIntRun -Harness $hFifoN -RunId 'run-fifo-native-b'
        $script:fifoAfterAppNativeActive = 1
        Clear-CasIntTestEnv

        $hAtt = New-CasIntHarness -Name 'owner-attach-behind-native'
        $null = Invoke-CasIntProfile -Harness $hAtt
        $bAtt = Invoke-CasIntBuilder -Harness $hAtt
        $tidAtt = [string]$bAtt.json.thread_id
        $attRun = 'run-attach-native'
        $attMarker = Get-CodexAppServerWakeMarker -RunId $attRun
        $attText = New-CodexAppServerTurnInputText -PromptText ([Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes([string]$hAtt.prompt))) -RunId $attRun
        $attHold = Join-Path $hAtt.root 'release-attach-owning'
        Add-CasIntStoreTurn -Harness $hAtt -ThreadId $tidAtt -TurnId 'turn-attach-existing' -Status 'completed' -StartedAt ([double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 5.0) -CompletedAt ([double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 4.0) -Text $attText
        $attLog = Join-Path $hAtt.root 'attach-native.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $attLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '8000'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_TURN_ID = 'turn-attach-owning'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_HOLD_PATH = $attHold
        $attLaunch = Invoke-CasIntLauncher -Harness $hAtt -ThreadId $tidAtt -RunId $attRun
        Assert-CasInt ($attLaunch.exit_code -eq 0) ("Existing matching attach behind native failed: $($attLaunch.stderr) $($attLaunch.stdout)")
        Assert-CasInt ([string]((Read-TelephoneJson -Path (Join-Path (Get-CasIntRunRoot -Harness $hAtt -RunId $attRun) 'lead-wake-ack.json') -SchemaName 'codex-app-server-lead-ack').value.turn_id) -ceq 'turn-attach-existing') 'Attach did not keep the existing matching turn.'
        $attStarts = @(Get-Content -LiteralPath $attLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($attStarts.Count -eq 0) 'Existing matching attach sent another turn/start.'
        Stop-CasIntRun -Harness $hAtt -RunId $attRun
        $script:matchingAttachBehindActive = 1
        Clear-CasIntTestEnv

        $hBusy = New-CasIntHarness -Name 'owner-busy-client-reconnect'
        $null = Invoke-CasIntProfile -Harness $hBusy
        $bBusy = Invoke-CasIntBuilder -Harness $hBusy
        $tidBusy = [string]$bBusy.json.thread_id
        $busyHold = Join-Path $hBusy.root 'release-busy-reconnect'
        $busyLog = Join-Path $hBusy.root 'busy-reconnect.log'
        $busyCount = Join-Path $hBusy.root 'busy-crash-count.txt'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $busyLog
        $env:TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS = '20000'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_TURN_ID = 'turn-busy-reconnect-owning'
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_HOLD_PATH = $busyHold
        $env:TELEPHONE_TEST_APP_SERVER_CRASH_AT = 'after-thread-read'
        $env:TELEPHONE_TEST_APP_SERVER_CRASH_ON_NTH = '2'
        $env:TELEPHONE_TEST_APP_SERVER_CRASH_COUNT_PATH = $busyCount
        $procBusy = Start-CasIntLauncherProcess -Harness $hBusy -ThreadId $tidBusy -RunId 'run-busy-reconnect'
        Assert-CasInt (Wait-CasIntPredicate -TimeoutMs 30000 -Predicate {
            try {
                $runNow = Get-CasIntRunJson -Harness $hBusy -RunId 'run-busy-reconnect'
                if ([string]$runNow.queue_state -cne 'queued' -or [string]$runNow.callback_write_phase -cne 'none') { return $false }
            } catch { return $false }
            $pids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            if ([IO.File]::Exists($busyLog)) {
                foreach ($line in [IO.File]::ReadAllLines($busyLog)) {
                    if ([string]$line -match '^process:(\d+):thread/read$') { [void]$pids.Add([string]$Matches[1]) }
                }
            }
            return ($pids.Count -ge 2)
        }) 'Busy-reconnect did not persist queued state on a replacement client after crash.'
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hBusy -ThreadId $tidBusy -RunId 'run-busy-reconnect').Count -eq 0) 'Busy-reconnect sent a marker before release.'
        $readPids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        if ([IO.File]::Exists($busyLog)) {
            foreach ($line in [IO.File]::ReadAllLines($busyLog)) {
                if ([string]$line -match '^process:(\d+):thread/read$') { [void]$readPids.Add([string]$Matches[1]) }
            }
        }
        Assert-CasInt ($readPids.Count -ge 2) ("Busy-reconnect did not reconnect a replacement client. pids=$($readPids.Count)")
        Assert-CasInt ((Get-CasIntEventCount -Path $busyLog -Name 'turn/start') -eq 0) 'Busy-reconnect sent turn/start before release.'
        [IO.File]::WriteAllText($busyHold, "release`n", [Text.UTF8Encoding]::new($false))
        $null = $procBusy.process.WaitForExit(120000)
        $busyExit = [int]$procBusy.process.ExitCode
        $busyOut = [string]$procBusy.stdout.GetAwaiter().GetResult()
        $procBusy.process.Dispose()
        Assert-CasInt ($busyExit -eq 0) ("Busy-reconnect launcher failed: $busyOut")
        Assert-CasInt (@(Get-CasIntMarkerStoreTurns -Harness $hBusy -ThreadId $tidBusy -RunId 'run-busy-reconnect').Count -eq 1) 'Busy-reconnect did not produce exactly one marker turn.'
        $busyStarts = @(Get-Content -LiteralPath $busyLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^process:\d+:turn/start$' })
        Assert-CasInt ($busyStarts.Count -eq 1) 'Busy-reconnect did not send exactly one turn/start.'
        Assert-CasInt (Wait-CasIntPath -Path (Join-Path (Get-CasIntRunRoot -Harness $hBusy -RunId 'run-busy-reconnect') 'lead-wake-ack.json') -TimeoutMs 30000) 'Busy-reconnect omitted ack.'
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $hBusy -RunId 'run-busy-reconnect') 'Busy-reconnect left a live per-run owner.'
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $hBusy -ThreadId $tidBusy -TimeoutMs 25000) 'Busy-reconnect thread owner did not quiesce.'
        Stop-CasIntRun -Harness $hBusy -RunId 'run-busy-reconnect'
        $script:busyClientReconnectOnce = 1
        Clear-CasIntTestEnv

        $dashPend = Join-Path $TestRoot 'dash-pending-job'
        $dashFail = Join-Path $TestRoot 'dash-failed-job'
        $dashDone = Join-Path $TestRoot 'dash-delivered-job'
        $dashExec = Join-Path $TestRoot 'dash-executor-fail-job'
        foreach ($dir in @($dashPend, $dashFail, $dashDone, $dashExec)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
        $dashBinding = [ordered]@{
            protocol_version = 'telephone-line-lead-binding-v1'
            session_id = '01a04b2b-7b8c-7a91-81a8-eeedaeda2321'
            worktree = [string]$statusH.worktree
            launcher = [ordered]@{ path = $launcherScript; arguments = @() }
        }
        $dashDispatch = [ordered]@{
            protocol_version = 'telephone-line-dispatch-v1'
            line_job_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1'
            project = 'dash-class'
            stage = 'SIMULATION'
            role = 'execution'
            route = 'mock-route'
            summary = 'classification'
            lead = $dashBinding
            command = [ordered]@{ executable = $pwsh; working_directory = [string]$statusH.root; arguments = @(); stdin = $null }
            source_request = [ordered]@{ path = 'request.json'; bytes = 1; sha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
            lead_binding = [ordered]@{ path = 'lead-binding.json'; bytes = 1; sha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            absolute_task_timeout = $false
            project_judgment = $false
        }
        $dashReceipt = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'tests\contracts\fixtures\valid\receipt.json') | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        $dashReceipt.project = 'dash-class'
        $dashReceipt.line_job_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1'
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashPend 'dispatch.json') -Value $dashDispatch
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashPend 'lead-binding.json') -Value $dashBinding
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashPend 'receipt.json') -Value $dashReceipt
        $selfOwner = New-CodexAppServerOwnerRecord
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashPend 'relay-owner.json') -Value $selfOwner
        $scanPend = Get-TelephoneDashboardJobScan -JobRoot $dashPend
        $codesPend = @($scanPend.findings | ForEach-Object { [string]$_.code })
        Assert-CasInt ($codesPend -contains 'CALLBACK_MISSING') 'Planted pending job omitted CALLBACK_MISSING.'
        Assert-CasInt ($codesPend -notcontains 'LOST_RELAY') 'Planted pending job with live relay was classified lost relay.'
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashFail 'dispatch.json') -Value $dashDispatch
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashFail 'lead-binding.json') -Value $dashBinding
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashFail 'receipt.json') -Value $dashReceipt
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashFail 'relay-error.json') -Value ([ordered]@{ protocol_version = 'telephone-line-relay-error-v1'; retrying = $false; error_code = 'LEAD_WAKE_AMBIGUOUS' })
        $scanFail = Get-TelephoneDashboardJobScan -JobRoot $dashFail
        $codesFail = @($scanFail.findings | ForEach-Object { [string]$_.code })
        Assert-CasInt ($codesFail -contains 'LOST_RELAY') 'Callback failed job omitted LOST_RELAY.'
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashDone 'dispatch.json') -Value $dashDispatch
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashDone 'lead-binding.json') -Value $dashBinding
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashDone 'receipt.json') -Value $dashReceipt
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashDone 'delivery.json') -Value ([ordered]@{ protocol_version = 'telephone-line-delivery-v1'; delivered = $true })
        $scanDone = Get-TelephoneDashboardJobScan -JobRoot $dashDone
        $codesDone = @($scanDone.findings | ForEach-Object { [string]$_.code })
        Assert-CasInt ($codesDone -notcontains 'CALLBACK_MISSING' -and $codesDone -notcontains 'LOST_RELAY') 'Delivered job kept pending/failed findings.'
        $failReceipt = $dashReceipt | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        $failReceipt.transport_complete = $false
        $failReceipt.command_exit_code = 2
        $failReceipt.command_error_code = 'ROUTE_FAILED'
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashExec 'dispatch.json') -Value $dashDispatch
        $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashExec 'lead-binding.json') -Value $dashBinding
        try {
            $null = Write-TelephoneJsonCreateNew -Path (Join-Path $dashExec 'receipt.json') -Value $failReceipt
            $execReceiptOk = $true
        } catch {
            $execReceiptOk = $false
        }
        if ($execReceiptOk) {
            $scanExec = Get-TelephoneDashboardJobScan -JobRoot $dashExec
            Assert-CasInt ($null -ne $scanExec) 'Executor-failure scan returned nothing.'
        }
        $script:dashboardClassification = 1

        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            callback_owner_only = $true
            durable_create_same_process = $durableCreateSameProcess
            durable_create_failure_diagnostic = $durableCreateFailureDiagnostic
            callback_once = $callbackOnce
            fifo_three = 1
            same_intent_replay = 1
            concurrent_attach = 1
            owner_death_prebind = 1
            post_send_recovery = 1
            live_owner_conflict = 1
            queued_behind_active = 1
            overlap_same_run_attach = 1
            f1_gate_released_before_ack_wait = [int]$f1GateReleasedBeforeAckWait
            thread_owner_quiet_observation_only = 1
            queued_status_durable = 1
            status_authoritative = 1
            fail_closed_identity = 1
            thread_owner_exact_identity = 1
            terminal_quiesce = 1
            explicit_fallback = $explicitFallback
            app_native_active_turn_pending = [int]$script:appNativeActiveTurnPending
            app_native_active_turn_delivery = [int]$script:appNativeActiveTurnDelivery
            app_native_executor_once = [int]$script:appNativeExecutorOnce
            pending_restart_recovery = [int]$script:pendingRestartRecovery
            pending_duplicate_launcher = [int]$script:pendingDuplicateLauncher
            fifo_after_app_native_active = [int]$script:fifoAfterAppNativeActive
            matching_attach_behind_active = [int]$script:matchingAttachBehindActive
            busy_client_reconnect_once = [int]$script:busyClientReconnectOnce
            dashboard_pending_not_executor_failure = [int]$script:dashboardPendingNotExecutorFailure
            dashboard_classification = [int]$script:dashboardClassification
            denominator_eight = $denominatorEight
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    if ($Compatibility0147Only) {
        $installedCodex = Get-CasIntInstalledCodexCommand
        $version = Get-CodexAppServerVersion -CodexCommand $installedCodex
        $expectedEntry = Get-CodexAppServerApprovedCompatibilityEntryByVersion -CodexVersion $version
        Assert-CasInt ($null -ne $expectedEntry) ("Installed Codex version is not approved: $version")
        Assert-CasInt ($script:CodexAppServerApprovedCompatibilityEntries.Count -ge 3) 'Versioned compatibility catalog does not retain all approved versions.'
        $license147 = New-CodexAppServerFrozenCompatibilityLicense -CodexVersion 'codex-cli 0.147.0'
        $license149 = New-CodexAppServerFrozenCompatibilityLicense -CodexVersion 'codex-cli 0.149.0'
        $license1491 = New-CodexAppServerFrozenCompatibilityLicense -CodexVersion 'codex-cli 0.149.1'
        Assert-CasInt (Test-CodexAppServerCompatibilityLicense -License $license147) '0.147 catalog record is not approved.'
        Assert-CasInt (Test-CodexAppServerCompatibilityLicense -License $license149) '0.149 catalog record is not approved.'
        Assert-CasInt (Test-CodexAppServerCompatibilityLicense -License $license1491) '0.149.1 catalog record is not approved.'
        Assert-CasInt ([string]$license149.schema_fingerprint -ceq [string]$license1491.schema_fingerprint) '0.149 patch schema identities drifted.'
        Assert-CasInt ([string](Get-CodexAppServerApprovedCompatibilityEntry -License $license1491).NotificationEnvelopeMode -ceq 'emitted-at-ms-optional') '0.149.1 notification-envelope rule drifted.'
        Assert-CasInt (Test-CodexAppServer0147CompatibilityLicense -License $license147) '0.147 adapter rule did not remain version-scoped.'
        Assert-CasInt (-not (Test-CodexAppServer0147CompatibilityLicense -License $license149)) '0.149 was mislabeled as the 0.147 adapter rule.'
        $expectedFingerprint = [string]$expectedEntry.SchemaFingerprint
        $frozenLicense = New-CodexAppServerFrozenCompatibilityLicense -CodexVersion $version
        $ownedClient = [ordered]@{}
        Set-CodexAppServerTestOwnedCompatibilityLicense -Client $ownedClient -License $frozenLicense
        $ownedLicense = Get-CodexAppServerCompatibilityLicenseFromClient -Client $ownedClient
        Assert-CasInt (Test-CodexAppServerCompatibilityLicense -License $ownedLicense) 'Test-owned frozen license seam did not attach an approved version.'
        Invoke-CasIntExpectPublic -Code 'SCHEMA_OR_PROFILE_INVALID' -Message 'Test-owned seam accepted a mismatched license.' -Action {
            $badClient = [ordered]@{}
            $badOwned = New-CodexAppServerFrozenCompatibilityLicense -CodexVersion $version
            $badOwned.schema_fingerprint = '0' * 64
            Set-CodexAppServerTestOwnedCompatibilityLicense -Client $badClient -License $badOwned
        }
        $schemaDir = Join-Path $TestRoot 'installed-schema'
        $fingerprint = Invoke-CodexAppServerGenerateSchema -CodexCommand $installedCodex -OutputDirectory $schemaDir
        Assert-CasInt ([string]$fingerprint.fingerprint -ceq $expectedFingerprint) 'Installed schema fingerprint drifted.'
        Assert-CasInt ([int]$fingerprint.file_count -eq [int]$expectedEntry.SchemaFileCount) 'Installed schema file count drifted.'
        Assert-CasInt ([int64]$fingerprint.schema_bytes -eq [int64]$expectedEntry.SchemaBytes) 'Installed schema byte count drifted.'
        $surfaceFingerprint = Get-CodexAppServerSchemaSurfaceFingerprint -SchemaDirectory $schemaDir
        Assert-CasInt ([string]$surfaceFingerprint.fingerprint -ceq [string]$expectedEntry.SurfaceFingerprint) 'Installed relevant schema surface drifted.'
        $schemaEvidence = Get-CodexAppServerCompatibilitySchemaEvidence -SchemaDirectory $schemaDir
        Assert-CasInt ([bool]$schemaEvidence.start_response_open) 'ThreadStartResponse container is not open.'
        Assert-CasInt ([bool]$schemaEvidence.resume_response_open) 'ThreadResumeResponse container is not open.'
        Assert-CasInt ([bool]$schemaEvidence.thread_open) 'Nested Thread container is not open.'
        Assert-CasInt ([bool]$schemaEvidence.service_tier_nullable) 'Generated serviceTier is not nullable.'
        Assert-CasInt ([bool]$schemaEvidence.notification_emitted_at_ms_int64) 'ServerNotification emittedAtMs is not an int64 in the generated schema.'
        Assert-CasInt (-not [bool]$schemaEvidence.extras_are_stable_schema_properties) 'Serializer extras were claimed as stable schema properties.'
        Assert-CasInt ([string]$schemaEvidence.compatibility_kind -ceq 'passive-serializer-extras') 'Compatibility kind drifted.'
        Assert-CasInt ([bool]$schemaEvidence.containers_open_and_service_tier_nullable) 'Open-container/nullable-tier evidence failed.'
        $startKeys = @(Get-CodexAppServer0147SerializerExtraRootKeys -Method 'thread/start')
        $resumeKeys = @(Get-CodexAppServer0147SerializerExtraRootKeys -Method 'thread/resume')
        foreach ($key in @('runtimeWorkspaceRoots', 'activePermissionProfile', 'multiAgentMode')) {
            Assert-CasInt ($startKeys -contains $key) ("Start allowlist omitted $key.")
            Assert-CasInt ($resumeKeys -contains $key) ("Resume allowlist omitted $key.")
        }
        foreach ($key in @('initialTurnsPage', 'turnsBackwardsCursor', 'itemsBackwardsCursor')) {
            Assert-CasInt ($startKeys -notcontains $key) ("Start allowlist admitted resume-only $key.")
            Assert-CasInt ($resumeKeys -contains $key) ("Resume allowlist omitted $key.")
        }
        foreach ($key in @('backwardsCursor', 'nextCursor', 'selectedCapabilityRoots')) {
            Assert-CasInt ($startKeys -notcontains $key) ("Start allowlist admitted rejected $key.")
            Assert-CasInt ($resumeKeys -notcontains $key) ("Resume allowlist admitted rejected $key.")
        }
        Remove-CodexAppServerDirectoryNative -Path $schemaDir -Label 'schema output'

        $defaultStartParams = New-CodexAppServerThreadStartParams -Worktree 'C:\tmp\wt'
        $defaultResumeParams = New-CodexAppServerThreadResumeParams -ThreadId 'thread-compat-1'
        Assert-CasInt (Test-CodexAppServerRequestExplicitDefaultServiceTier -RequestParams $defaultStartParams) 'Start request factory omitted exact default serviceTier.'
        Assert-CasInt (Test-CodexAppServerRequestExplicitDefaultServiceTier -RequestParams $defaultResumeParams) 'Resume request factory omitted exact default serviceTier.'
        Assert-CasInt ($defaultStartParams.Contains('serviceTier') -and [string]$defaultStartParams.serviceTier -ceq 'default') 'Start params dict is not exact default.'
        Assert-CasInt ($defaultResumeParams.Contains('serviceTier') -and [string]$defaultResumeParams.serviceTier -ceq 'default') 'Resume params dict is not exact default.'

        $cleanNull = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
        $parsedClean = Assert-CodexAppServerThreadStartOrResumeResponse -Result $cleanNull -RequestParams $defaultStartParams -Method 'thread/start'
        Assert-CasInt ([string]$parsedClean.thread_id -ceq 'thread-compat-1') 'Null-tier start did not bind the exact thread id.'
        Assert-CasInt (Test-CodexAppServerJsonArray -Value $parsedClean.thread.turns) 'Zero-turn start turns is not an array.'
        Assert-CasInt ([int]$parsedClean.thread.turns.Count -eq 0) 'Zero-turn start did not stay zero turns.'
        $defaultResult = New-CasIntValidStartResult -Thread (New-CasIntValidThread -Id 'thread-compat-1') -ServiceTier 'default'
        $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $defaultResult -RequestParams $defaultStartParams -Method 'thread/start'

        $startExtras = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
        $startExtras['activePermissionProfile'] = [ordered]@{ id = ':workspace'; extends = $null }
        $startExtras['multiAgentMode'] = 'explicitRequestOnly'
        $startExtras['runtimeWorkspaceRoots'] = @()
        $startExtras.thread['canAcceptDirectInput'] = $false
        $startExtras.thread['extra'] = [ordered]@{}
        $startExtras.thread['historyMode'] = 'legacy'
        $parsedStartExtras = Assert-CodexAppServerThreadStartOrResumeResponse -Result $startExtras -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $ownedLicense
        Assert-CasInt ([string]$parsedStartExtras.thread_id -ceq 'thread-compat-1') 'Licensed start extras did not bind the exact thread id.'

        $resumeExtras = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
        $resumeExtras['activePermissionProfile'] = [ordered]@{ id = ':workspace'; extends = $null }
        $resumeExtras['multiAgentMode'] = 'explicitRequestOnly'
        $resumeExtras['runtimeWorkspaceRoots'] = @()
        $resumeExtras['initialTurnsPage'] = [ordered]@{ data = @(); backwardsCursor = $null; nextCursor = $null }
        $resumeExtras['turnsBackwardsCursor'] = $null
        $resumeExtras['itemsBackwardsCursor'] = $null
        $resumeExtras.thread['canAcceptDirectInput'] = $false
        $resumeExtras.thread['extra'] = [ordered]@{}
        $resumeExtras.thread['historyMode'] = 'legacy'
        $parsedResumeExtras = Assert-CodexAppServerThreadStartOrResumeResponse -Result $resumeExtras -RequestParams $defaultResumeParams -ExpectedId 'thread-compat-1' -Method 'thread/resume' -CompatibilityLicense $ownedLicense
        Assert-CasInt ([string]$parsedResumeExtras.thread_id -ceq 'thread-compat-1') 'Licensed resume extras did not bind the exact thread id.'
        Assert-CasInt ($script:CodexAppServerThreadKeys -notcontains 'projectId') 'Stable thread projection still requires projectId.'
        Assert-CasInt ($script:CodexAppServerThreadOptionalKeys -contains 'projectId') 'Version-scoped projectId serializer field is not represented.'
        Assert-CasInt (-not $parsedClean.thread.Contains('projectId')) 'Omitted projectId was synthesized on start.'
        Assert-CasInt (-not $parsedStartExtras.thread.Contains('projectId')) 'Licensed start extras synthesized projectId.'
        Assert-CasInt (-not $parsedResumeExtras.thread.Contains('projectId')) 'Licensed resume extras synthesized projectId.'
        $readOmit = Assert-CodexAppServerThreadReadResponse -Result ([ordered]@{ thread = (New-CasIntValidThread) }) -ExpectedId 'thread-compat-1' -CompatibilityLicense $ownedLicense
        Assert-CasInt ([string]$readOmit.thread_id -ceq 'thread-compat-1') 'Licensed read without projectId failed.'
        Assert-CasInt (-not $readOmit.thread.Contains('projectId')) 'Licensed read synthesized projectId.'

        $nullableStart = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
        $nullableStart['activePermissionProfile'] = $null
        $nullableStart.thread['extra'] = $null
        $nullableStart.thread['canAcceptDirectInput'] = $null
        $parsedNullableStart = Assert-CodexAppServerThreadStartOrResumeResponse -Result $nullableStart -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $ownedLicense
        Assert-CasInt ([string]$parsedNullableStart.thread_id -ceq 'thread-compat-1') 'Allowed-null start extras did not bind the exact thread id.'

        $nullableResume = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
        $nullableResume['initialTurnsPage'] = $null
        $nullableResume['turnsBackwardsCursor'] = $null
        $nullableResume['itemsBackwardsCursor'] = $null
        $parsedNullableResume = Assert-CodexAppServerThreadStartOrResumeResponse -Result $nullableResume -RequestParams $defaultResumeParams -ExpectedId 'thread-compat-1' -Method 'thread/resume' -CompatibilityLicense $ownedLicense
        Assert-CasInt ([string]$parsedNullableResume.thread_id -ceq 'thread-compat-1') 'Allowed-null resume extras did not bind the exact thread id.'

        $driveRoots = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
        $driveRoots['runtimeWorkspaceRoots'] = @('C:\tmp\wt')
        $parsedDriveRoots = Assert-CodexAppServerThreadStartOrResumeResponse -Result $driveRoots -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $ownedLicense
        Assert-CasInt ([string]$parsedDriveRoots.thread_id -ceq 'thread-compat-1') 'Fully qualified drive runtime root was rejected.'

        $uncRoots = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
        $uncRoots['runtimeWorkspaceRoots'] = @('\\server\share\wt')
        $parsedUncRoots = Assert-CodexAppServerThreadStartOrResumeResponse -Result $uncRoots -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $ownedLicense
        Assert-CasInt ([string]$parsedUncRoots.thread_id -ceq 'thread-compat-1') 'Fully qualified UNC runtime root was rejected.'

        Invoke-CasIntExpectPublic -Code 'SERVICE_TIER_INVALID' -Message 'Blank response serviceTier was accepted.' -Action {
            $blank = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier ''
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $blank -RequestParams $defaultStartParams -Method 'thread/start'
        }
        Invoke-CasIntExpectPublic -Code 'SCHEMA_OR_PROFILE_INVALID' -Message 'Serializer extras were admitted without a compatibility license.' -Action {
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $startExtras -RequestParams $defaultStartParams -Method 'thread/start'
        }
        Invoke-CasIntExpectPublic -Code 'SCHEMA_OR_PROFILE_INVALID' -Message 'Serializer extras were admitted with a mismatched fingerprint.' -Action {
            $badLicense = New-CodexAppServer0147FrozenCompatibilityLicense
            $badLicense.schema_fingerprint = '0' * 64
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $startExtras -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $badLicense
        }
        Invoke-CasIntExpectPublic -Code 'SCHEMA_OR_PROFILE_INVALID' -Message 'Environment bypass admitted extras without exact frozen evidence.' -Action {
            $env:TELEPHONE_TEST_APP_SERVER_0147_COMPAT = '1'
            try {
                $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $startExtras -RequestParams $defaultStartParams -Method 'thread/start'
            } finally {
                Remove-Item env:TELEPHONE_TEST_APP_SERVER_0147_COMPAT -ErrorAction SilentlyContinue
            }
        }
        Invoke-CasIntExpectPublic -Code 'SCHEMA_OR_PROFILE_INVALID' -Message 'Environment bypass admitted extras with a mismatched fingerprint.' -Action {
            $env:TELEPHONE_TEST_APP_SERVER_0147_COMPAT = '1'
            try {
                $badLicense = New-CodexAppServer0147FrozenCompatibilityLicense
                $badLicense.schema_fingerprint = '0' * 64
                $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $startExtras -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $badLicense
            } finally {
                Remove-Item env:TELEPHONE_TEST_APP_SERVER_0147_COMPAT -ErrorAction SilentlyContinue
            }
        }

        foreach ($badRequest in @(
            @{ name = 'omitted'; params = [ordered]@{ cwd = 'C:\tmp\wt' } },
            @{ name = 'inherited'; params = [ordered]@{ cwd = 'C:\tmp\wt'; other = 'default' } },
            @{ name = 'blank'; params = [ordered]@{ cwd = 'C:\tmp\wt'; serviceTier = '' } },
            @{ name = 'null-request'; params = [ordered]@{ cwd = 'C:\tmp\wt'; serviceTier = $null } },
            @{ name = 'priority-request'; params = [ordered]@{ cwd = 'C:\tmp\wt'; serviceTier = 'priority' } },
            @{ name = 'fast-request'; params = [ordered]@{ cwd = 'C:\tmp\wt'; serviceTier = 'fast' } },
            @{ name = 'flex-request'; params = [ordered]@{ cwd = 'C:\tmp\wt'; serviceTier = 'flex' } },
            @{ name = 'ultrafast-request'; params = [ordered]@{ cwd = 'C:\tmp\wt'; serviceTier = 'ultrafast' } }
        )) {
            $requestName = [string]$badRequest.name
            $requestParams = $badRequest.params
            Invoke-CasIntExpectPublic -Code 'SERVICE_TIER_INVALID' -Message ("Null response with $requestName request was accepted.") -Action {
                $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $cleanNull -RequestParams $requestParams -Method 'thread/start'
            }
        }
        foreach ($badTier in @('priority', 'fast', 'flex', 'ultrafast', 'other')) {
            $responseTier = [string]$badTier
            Invoke-CasIntExpectPublic -Code 'SERVICE_TIER_INVALID' -Message ("Explicit nondefault response $responseTier was accepted.") -Action {
                $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $responseTier
                $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start'
            }
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Unknown wrapper key was accepted.' -Action {
            $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
            $bad['notARealKey'] = $true
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start'
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Unknown thread key was accepted.' -Action {
            $thread = New-CasIntValidThread
            $thread['mockExperimentalField'] = $true
            $bad = New-CasIntValidStartResult -Thread $thread -ServiceTier $null
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start'
        }
        foreach ($rejected in @('backwardsCursor', 'nextCursor', 'selectedCapabilityRoots')) {
            $rejectedKey = [string]$rejected
            Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message ("Rejected root key $rejectedKey was accepted.") -Action {
                $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
                $bad[$rejectedKey] = $true
                $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $frozenLicense
            }
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Malformed permission profile was accepted.' -Action {
            $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
            $bad['activePermissionProfile'] = 'not-an-object'
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $frozenLicense
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Malformed multiAgentMode was accepted.' -Action {
            $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
            $bad['multiAgentMode'] = 123
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $frozenLicense
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Malformed runtimeWorkspaceRoots was accepted.' -Action {
            $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
            $bad['runtimeWorkspaceRoots'] = @('relative-root')
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $ownedLicense
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Drive-relative runtime root was accepted.' -Action {
            $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
            $bad['runtimeWorkspaceRoots'] = @('C:relative')
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $ownedLicense
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Current-drive-rooted runtime root was accepted.' -Action {
            $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
            $bad['runtimeWorkspaceRoots'] = @('\relative-to-current-drive')
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $ownedLicense
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Null runtimeWorkspaceRoots was accepted.' -Action {
            $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
            $bad['runtimeWorkspaceRoots'] = $null
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $ownedLicense
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Null multiAgentMode was accepted.' -Action {
            $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
            $bad['multiAgentMode'] = $null
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $ownedLicense
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Null historyMode was accepted.' -Action {
            $thread = New-CasIntValidThread
            $thread['historyMode'] = $null
            $bad = New-CasIntValidStartResult -Thread $thread -ServiceTier $null
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $ownedLicense
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Non-empty extra object was accepted.' -Action {
            $thread = New-CasIntValidThread
            $thread['extra'] = [ordered]@{ leftover = '1' }
            $bad = New-CasIntValidStartResult -Thread $thread -ServiceTier $null
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $frozenLicense
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Malformed historyMode was accepted.' -Action {
            $thread = New-CasIntValidThread
            $thread['historyMode'] = 'bogus'
            $bad = New-CasIntValidStartResult -Thread $thread -ServiceTier $null
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $frozenLicense
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Malformed canAcceptDirectInput was accepted.' -Action {
            $thread = New-CasIntValidThread
            $thread['canAcceptDirectInput'] = 'yes'
            $bad = New-CasIntValidStartResult -Thread $thread -ServiceTier $null
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $frozenLicense
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Malformed initialTurnsPage was accepted.' -Action {
            $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
            $bad['initialTurnsPage'] = 1
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultResumeParams -Method 'thread/resume' -CompatibilityLicense $frozenLicense
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Missing required wrapper key was accepted.' -Action {
            $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread) -ServiceTier $null
            $kept = [ordered]@{}
            foreach ($key in @($bad.Keys)) { if ([string]$key -cne 'model') { $kept[$key] = $bad[$key] } }
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $kept -RequestParams $defaultStartParams -Method 'thread/start'
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message 'Wrong resume thread id was accepted.' -Action {
            $bad = New-CasIntValidStartResult -Thread (New-CasIntValidThread -Id 'thread-compat-1') -ServiceTier $null
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultResumeParams -ExpectedId 'other-thread-id' -Method 'thread/resume'
        }
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message '0.147 accepted null thread.projectId.' -Action {
            $thread = New-CasIntValidThread
            $thread['projectId'] = $null
            $bad = New-CasIntValidStartResult -Thread $thread -ServiceTier $null
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $license147
        }
        $thread149 = New-CasIntValidThread
        $thread149['projectId'] = $null
        $result149 = New-CasIntValidStartResult -Thread $thread149 -ServiceTier $null
        $parsed149 = Assert-CodexAppServerThreadStartOrResumeResponse -Result $result149 -RequestParams $defaultStartParams -Method 'thread/start' -CompatibilityLicense $license149
        Assert-CasInt ([string]$parsed149.thread_id -ceq 'thread-compat-1') '0.149 null projectId did not bind the exact thread.'
        $read149 = Assert-CodexAppServerThreadReadResponse -Result ([ordered]@{ thread = $thread149 }) -ExpectedId 'thread-compat-1' -CompatibilityLicense $license149
        Assert-CasInt ([string]$read149.thread_id -ceq 'thread-compat-1') '0.149 read rejected null projectId.'
        $status149Client = [ordered]@{
            compatibility_license = $license1491
            pending = [Collections.Generic.List[object]]::new()
            last_status = [ordered]@{ status = 'notLoaded'; active_flags = @() }
            bound_thread_id = 'thread-envelope-1'
            bound_turn_id = ''
        }
        $status149Message = [ordered]@{
            method = 'thread/status/changed'
            params = [ordered]@{ threadId = 'thread-envelope-1'; status = [ordered]@{ type = 'active'; activeFlags = @() } }
            emittedAtMs = [int64]1
        }
        $status149Applied = Apply-CodexAppServerInboundMessage -Client $status149Client -Message $status149Message
        Assert-CasInt ([string]$status149Applied.kind -ceq 'status') '0.149.1 valid emittedAtMs notification was not accepted.'
        $status147Client = [ordered]@{
            compatibility_license = $license147
            pending = [Collections.Generic.List[object]]::new()
            last_status = [ordered]@{ status = 'notLoaded'; active_flags = @() }
            bound_thread_id = 'thread-envelope-1'
            bound_turn_id = ''
        }
        $status147Applied = Apply-CodexAppServerInboundMessage -Client $status147Client -Message $status149Message
        Assert-CasInt ([string]$status147Applied.kind -ceq 'ignored') '0.147 admitted the 0.149 notification envelope.'
        $badEmittedAt = [ordered]@{
            method = 'thread/status/changed'
            params = [ordered]@{ threadId = 'thread-envelope-1'; status = [ordered]@{ type = 'active'; activeFlags = @() } }
            emittedAtMs = '1'
        }
        $badEmittedApplied = Apply-CodexAppServerInboundMessage -Client $status149Client -Message $badEmittedAt
        Assert-CasInt ([string]$badEmittedApplied.kind -ceq 'ignored') '0.149.1 admitted malformed emittedAtMs.'
        Invoke-CasIntExpectPublic -Code 'STABLE_PROTOCOL_INVALID' -Message '0.149 accepted nonempty thread.projectId.' -Action {
            $thread = New-CasIntValidThread
            $thread['projectId'] = 'proj-1'
            $bad = New-CasIntValidStartResult -Thread $thread -ServiceTier $null
            $null = Assert-CodexAppServerThreadStartOrResumeResponse -Result $bad -RequestParams $defaultResumeParams -ExpectedId 'thread-compat-1' -Method 'thread/resume' -CompatibilityLicense $license149
        }

        $hStart = New-CasIntHarness -Name 'compat-start'
        $null = Invoke-CasIntProfile -Harness $hStart
        $startLog = Join-Path $hStart.root 'start-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $startLog
        $env:TELEPHONE_TEST_APP_SERVER_RETURN_NULL_TIER = '1'
        $started = Invoke-CasIntBuilder -Harness $hStart
        Assert-CasInt ($started.exit_code -eq 0) ("Optional/null start failed: $($started.stderr) $($started.stdout)")
        Assert-CasInt ($started.json.started -eq $false) 'Start published a wake/turn.'
        $startId = [string]$started.json.thread_id
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace($startId)) 'Start did not bind a thread id.'
        Assert-CasInt ([IO.File]::Exists([string]$hStart.binding)) 'Start did not publish a binding file.'
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hStart -ThreadId $startId).Count -eq 0) 'Start with zero turns did not stay zero turns.'
        Assert-CasInt ((Get-CasIntEventCount -Path $startLog -Name 'explicit_default_tier:thread/start') -eq 1) 'Start request did not carry explicit exact default.'
        Assert-CasInt ((Get-CasIntEventCount -Path $startLog -Name 'turn/start') -eq 0) 'Start created a callback turn.'
        Assert-CasInt (-not [IO.File]::Exists((Join-Path $hStart.state 'runs'))) 'Start created a run owner root.'
        Clear-CasIntTestEnv

        $hResume = New-CasIntHarness -Name 'compat-resume'
        $null = Invoke-CasIntProfile -Harness $hResume
        $seed = Invoke-CasIntBuilder -Harness $hResume
        Assert-CasInt ($seed.exit_code -eq 0) ("Resume seed start failed: $($seed.stderr)")
        $resumeId = [string]$seed.json.thread_id
        $hResume.binding = Join-Path $hResume.root 'lead-binding-resume.json'
        $resumeLog = Join-Path $hResume.root 'resume-events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $resumeLog
        $env:TELEPHONE_TEST_APP_SERVER_RETURN_NULL_TIER = '1'
        $resumed = Invoke-CasIntBuilder -Harness $hResume -ResumeSessionId $resumeId
        Assert-CasInt ($resumed.exit_code -eq 0) ("Optional/null resume failed: $($resumed.stderr) $($resumed.stdout)")
        Assert-CasInt ([string]$resumed.json.thread_id -ceq $resumeId) 'Resume did not bind the exact requested id.'
        Assert-CasInt ((Get-CasIntEventCount -Path $resumeLog -Name 'explicit_default_tier:thread/resume') -eq 1) 'Resume request did not carry explicit exact default.'
        Assert-CasInt ((Get-CasIntEventCount -Path $resumeLog -Name 'turn/start') -eq 0) 'Resume created a callback turn.'
        Clear-CasIntTestEnv

        $hProfileDrift = New-CasIntHarness -Name 'compat-profile-drift'
        $null = Invoke-CasIntProfile -Harness $hProfileDrift
        $driftedProfile = (Read-TelephoneJson -Path $hProfileDrift.profile).value
        $driftedProfile.schema_fingerprint = '0' * 64
        $null = Write-CodexAppServerJsonReplace -Path $hProfileDrift.profile -Value $driftedProfile
        $profileDrift = Invoke-CasIntBuilder -Harness $hProfileDrift
        Assert-CasInt ($profileDrift.exit_code -ne 0) 'Unknown profile identity produced a binding.'
        Assert-CasInt ([string]$profileDrift.json.error -ceq (Get-CodexAppServerPublicMessage -Code 'COMPATIBILITY_DRIFT')) 'Unknown profile identity leaked a raw error.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hProfileDrift.binding)) 'Unknown profile identity published a binding.'

        $hUnknown = New-CasIntHarness -Name 'compat-unknown'
        $null = Invoke-CasIntProfile -Harness $hUnknown
        $env:TELEPHONE_TEST_APP_SERVER_UNKNOWN_WRAPPER_KEY = 'notARealKey'
        $unknownWrap = Invoke-CasIntBuilder -Harness $hUnknown
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_UNKNOWN_WRAPPER_KEY -ErrorAction SilentlyContinue
        Assert-CasInt ($unknownWrap.exit_code -ne 0) 'Unknown wrapper key produced a binding.'
        Assert-CasInt ([string]$unknownWrap.json.error -ceq (Get-CodexAppServerPublicMessage -Code 'STABLE_PROTOCOL_INVALID')) 'Unknown wrapper key leaked a raw error.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hUnknown.binding)) 'Unknown wrapper key published a binding.'

        $hUnknownT = New-CasIntHarness -Name 'compat-unknown-thread'
        $null = Invoke-CasIntProfile -Harness $hUnknownT
        $env:TELEPHONE_TEST_APP_SERVER_UNKNOWN_THREAD_KEY = 'mockExperimentalField'
        $unknownThread = Invoke-CasIntBuilder -Harness $hUnknownT
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_UNKNOWN_THREAD_KEY -ErrorAction SilentlyContinue
        Assert-CasInt ($unknownThread.exit_code -ne 0) 'Unknown thread key produced a binding.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hUnknownT.binding)) 'Unknown thread key published a binding.'

        $hProjectId = New-CasIntHarness -Name 'compat-projectid'
        $null = Invoke-CasIntProfile -Harness $hProjectId
        $env:TELEPHONE_TEST_APP_SERVER_UNKNOWN_THREAD_KEY = 'projectId'
        $projectIdPresent = Invoke-CasIntBuilder -Harness $hProjectId
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_UNKNOWN_THREAD_KEY -ErrorAction SilentlyContinue
        Assert-CasInt ($projectIdPresent.exit_code -ne 0) 'Present thread.projectId produced a binding.'
        Assert-CasInt ([string]$projectIdPresent.json.error -ceq (Get-CodexAppServerPublicMessage -Code 'STABLE_PROTOCOL_INVALID')) 'Forbidden projectId response leaked a raw error.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hProjectId.binding)) 'Present thread.projectId published a binding.'

        $hMalformed = New-CasIntHarness -Name 'compat-malformed'
        $null = Invoke-CasIntProfile -Harness $hMalformed
        $env:TELEPHONE_TEST_APP_SERVER_MALFORMED_OPTIONAL = 'activePermissionProfile'
        $malformed = Invoke-CasIntBuilder -Harness $hMalformed
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_MALFORMED_OPTIONAL -ErrorAction SilentlyContinue
        Assert-CasInt ($malformed.exit_code -ne 0) 'Malformed optional value produced a binding.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hMalformed.binding)) 'Malformed optional value published a binding.'

        $hMalformedExtra = New-CasIntHarness -Name 'compat-malformed-extra'
        $null = Invoke-CasIntProfile -Harness $hMalformedExtra
        $env:TELEPHONE_TEST_APP_SERVER_MALFORMED_OPTIONAL = 'extra'
        $malformedExtra = Invoke-CasIntBuilder -Harness $hMalformedExtra
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_MALFORMED_OPTIONAL -ErrorAction SilentlyContinue
        Assert-CasInt ($malformedExtra.exit_code -ne 0) 'Non-empty extra object produced a binding.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hMalformedExtra.binding)) 'Non-empty extra object published a binding.'

        $hMalformedRoots = New-CasIntHarness -Name 'compat-malformed-roots'
        $null = Invoke-CasIntProfile -Harness $hMalformedRoots
        $env:TELEPHONE_TEST_APP_SERVER_MALFORMED_OPTIONAL = 'runtimeWorkspaceRoots'
        $malformedRoots = Invoke-CasIntBuilder -Harness $hMalformedRoots
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_MALFORMED_OPTIONAL -ErrorAction SilentlyContinue
        Assert-CasInt ($malformedRoots.exit_code -ne 0) 'Malformed runtime roots produced a binding.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hMalformedRoots.binding)) 'Malformed runtime roots published a binding.'

        $hRejected = New-CasIntHarness -Name 'compat-rejected-root'
        $null = Invoke-CasIntProfile -Harness $hRejected
        $env:TELEPHONE_TEST_APP_SERVER_UNKNOWN_WRAPPER_KEY = 'selectedCapabilityRoots'
        $rejectedRoot = Invoke-CasIntBuilder -Harness $hRejected
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_UNKNOWN_WRAPPER_KEY -ErrorAction SilentlyContinue
        Assert-CasInt ($rejectedRoot.exit_code -ne 0) 'Rejected root key produced a binding.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hRejected.binding)) 'Rejected root key published a binding.'

        $hBlankTier = New-CasIntHarness -Name 'compat-blank-tier'
        $null = Invoke-CasIntProfile -Harness $hBlankTier
        $env:TELEPHONE_TEST_APP_SERVER_RETURN_EMPTY_TIER = '1'
        $blankTier = Invoke-CasIntBuilder -Harness $hBlankTier
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_RETURN_EMPTY_TIER -ErrorAction SilentlyContinue
        Assert-CasInt ($blankTier.exit_code -ne 0) 'Blank response serviceTier produced a binding.'
        Assert-CasInt ([string]$blankTier.json.error -ceq (Get-CodexAppServerPublicMessage -Code 'SERVICE_TIER_INVALID')) 'Blank response leaked a raw error.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hBlankTier.binding)) 'Blank response published a binding.'

        $hMissing = New-CasIntHarness -Name 'compat-missing'
        $null = Invoke-CasIntProfile -Harness $hMissing
        $env:TELEPHONE_TEST_APP_SERVER_OMIT_WRAPPER_FIELD = 'model'
        $missing = Invoke-CasIntBuilder -Harness $hMissing
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_OMIT_WRAPPER_FIELD -ErrorAction SilentlyContinue
        Assert-CasInt ($missing.exit_code -ne 0) 'Missing required key produced a binding.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hMissing.binding)) 'Missing required key published a binding.'

        $hWrong = New-CasIntHarness -Name 'compat-wrong-id'
        $null = Invoke-CasIntProfile -Harness $hWrong
        $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_THREAD_ID = '1'
        $wrong = Invoke-CasIntBuilder -Harness $hWrong -ResumeSessionId 'thread-known'
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_FOREIGN_THREAD_ID -ErrorAction SilentlyContinue
        Assert-CasInt ($wrong.exit_code -ne 0) 'Wrong thread id produced a binding.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hWrong.binding)) 'Wrong thread id published a binding.'

        $hDrift = New-CasIntHarness -Name 'compat-drift'
        $null = Invoke-CasIntProfile -Harness $hDrift
        $env:TELEPHONE_TEST_APP_SERVER_SCHEMA_EXTRA = '{"drift":true}'
        $env:TELEPHONE_TEST_CLI_FALLBACK_MARKER = (Join-Path $hDrift.root 'cli-marker.txt')
        $drift = Invoke-CasIntBuilder -Harness $hDrift
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_SCHEMA_EXTRA, env:TELEPHONE_TEST_CLI_FALLBACK_MARKER -ErrorAction SilentlyContinue
        Assert-CasInt ($drift.exit_code -ne 0) 'Profile/schema mismatch did not fail closed.'
        Assert-CasInt ([string]$drift.json.fallback_required -ceq 'cli') 'Profile/schema mismatch did not request explicit CLI fallback.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hDrift.binding)) 'Profile/schema mismatch published a binding.'
        Assert-CasInt (-not [IO.File]::Exists((Join-Path $hDrift.root 'cli-marker.txt'))) 'CLI launcher ran automatically after mismatch.'

        $hTier = New-CasIntHarness -Name 'compat-nondefault-response'
        $null = Invoke-CasIntProfile -Harness $hTier
        $env:TELEPHONE_TEST_APP_SERVER_RETURN_TIER = 'priority'
        $tierFail = Invoke-CasIntBuilder -Harness $hTier
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_RETURN_TIER -ErrorAction SilentlyContinue
        Assert-CasInt ($tierFail.exit_code -ne 0) 'Nondefault response tier produced a binding.'
        Assert-CasInt ([string]$tierFail.json.error -ceq (Get-CodexAppServerPublicMessage -Code 'SERVICE_TIER_INVALID')) 'Nondefault response leaked a raw error.'
        Assert-CasInt (-not [IO.File]::Exists([string]$hTier.binding)) 'Nondefault response published a binding.'

        $profileRoot = Join-Path $TestRoot 'installed-profile'
        [IO.Directory]::CreateDirectory($profileRoot) | Out-Null
        $profilePath = Join-Path $profileRoot 'profile.json'
        $preflightState = Join-Path $profileRoot 'state'
        [IO.Directory]::CreateDirectory($preflightState) | Out-Null
        $preflightWork = Join-Path $profileRoot 'worktree'
        [IO.Directory]::CreateDirectory($preflightWork) | Out-Null
        $bound = Invoke-CasIntScript -ScriptPath $profileScript -Arguments @(
            '-CodexCommand', $installedCodex, '-OutputPath', $profilePath
        )
        Assert-CasInt ($bound.exit_code -eq 0) ("Installed profile bind failed: $($bound.stderr) $($bound.stdout)")
        Assert-CasInt ($bound.json.started -eq $false) 'Installed profile bind started a thread.'
        Assert-CasInt ($bound.json.residue -eq $false) 'Installed profile bind left schema residue.'
        Assert-CasInt ([string]$bound.json.profile.service_tier -ceq 'default') 'Installed profile did not bind service_tier=default.'
        Assert-CasInt ([string]$bound.json.profile.schema_fingerprint -ceq $expectedFingerprint) 'Installed profile fingerprint drifted.'
        Assert-CasInt ([string]$bound.json.profile.codex_version -ceq $version) 'Installed profile version drifted.'
        $qualified = Invoke-CasIntScript -ScriptPath $qualificationScript -Arguments @('-CodexCommand', $installedCodex)
        Assert-CasInt ($qualified.exit_code -eq 0 -and $qualified.json.approved -eq $true) ("Installed qualification failed: $($qualified.stderr) $($qualified.stdout)")
        Assert-CasInt ([string]$qualified.json.codex_version -ceq $version) 'Qualification reported another Codex version.'
        Assert-CasInt ([string]$qualified.json.schema_fingerprint -ceq $expectedFingerprint) 'Qualification schema identity drifted.'
        Assert-CasInt ([string]$qualified.json.surface_fingerprint -ceq [string]$expectedEntry.SurfaceFingerprint) 'Qualification surface identity drifted.'
        Assert-CasInt ([string]$qualified.json.approved_notification_envelope_mode -ceq [string]$expectedEntry.NotificationEnvelopeMode) 'Qualification notification-envelope mode drifted.'
        Assert-CasInt ($qualified.json.record_only_candidate -eq $false -and $qualified.json.requires_adapter_change -eq $false) 'Approved version was classified as an upgrade candidate.'
        $pre = Invoke-CasIntScript -ScriptPath $preflightScript -Arguments @(
            '-CodexCommand', $installedCodex, '-WorktreePath', $preflightWork, '-StateRoot', $preflightState, '-ProfilePath', $profilePath
        )
        Assert-CasInt ($pre.exit_code -eq 0 -and $pre.json.ready -eq $true) ("Installed preflight failed: $($pre.stderr) $($pre.stdout)")
        Assert-CasInt ($pre.json.allow_fast -eq $false) 'Installed preflight allowed Fast.'
        Assert-CasInt ($pre.json.started -eq $false) 'Installed preflight started a thread or turn.'
        Assert-CasInt ([string]$pre.json.callback_transport -ceq 'app-server') 'Installed preflight did not keep app-server transport.'
        Assert-CasInt ($pre.json.absolute_task_timeout -eq $false) 'Installed preflight enabled an absolute timeout.'
        $stdioCheck = @($pre.json.checks | Where-Object { [string]$_.id -ceq 'stdio_only' })
        Assert-CasInt ($stdioCheck.Count -eq 1 -and [string]$stdioCheck[0].status -ceq 'pass') 'Installed preflight omitted stable stdio.'
        Assert-CasInt (-not [IO.File]::Exists((Join-Path $preflightState 'app-server-store.json'))) 'Installed preflight created a provider store.'
        Assert-CasInt (-not [IO.Directory]::Exists((Join-Path $preflightState 'runs'))) 'Installed preflight created run state.'
        Assert-CasInt (@([IO.Directory]::GetFiles($profileRoot, '*', [IO.SearchOption]::AllDirectories) | Where-Object { [IO.Path]::GetFileName($_) -ceq 'owner.json' }).Count -eq 0) 'Installed probes created an owner.'
        Assert-CasInt (@([IO.Directory]::GetFiles($profileRoot, '*', [IO.SearchOption]::AllDirectories) | Where-Object { [IO.Path]::GetFileName($_) -ceq 'lead-wake-ack.json' }).Count -eq 0) 'Installed probes created callback state.'
        $installedBinding = Join-Path $profileRoot 'installed-thread-binding.json'
        $installedStart = Invoke-CasIntScript -ScriptPath $builderScript -Arguments @(
            '-WorktreePath', $preflightWork,
            '-StateRoot', $preflightState,
            '-BindingOutputPath', $installedBinding,
            '-CallbackTransport', 'app-server',
            '-CodexCommand', $installedCodex,
            '-ProfilePath', $profilePath
        )
        Assert-CasInt ($installedStart.exit_code -eq 0) ("Installed thread/start qualification failed: $($installedStart.stderr) $($installedStart.stdout)")
        Assert-CasInt ($installedStart.json.started -eq $false) 'Installed thread/start unexpectedly started a model turn.'
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace([string]$installedStart.json.thread_id)) 'Installed thread/start returned no thread id.'
        Assert-CasInt ([IO.File]::Exists($installedBinding)) 'Installed thread/start did not publish its binding.'

        $changedParse = @(
            (Join-Path $repoRoot 'src\lead-side\codex-app-server\CodexAppServerLead.Common.ps1'),
            (Join-Path $repoRoot 'src\lead-side\codex-app-server\CodexAppServerLead.Lifecycle.ps1'),
            (Join-Path $repoRoot 'src\lead-side\codex-app-server\Invoke-CodexAppServerCompatibilityQualification.ps1'),
            (Join-Path $repoRoot 'src\lead-side\codex-app-server\Invoke-WirelessTelephoneSmoke.ps1'),
            (Join-Path $repoRoot 'tests\lead-side\codex-app-server\fixtures\Mock-CodexAppServer.ps1'),
            $PSCommandPath
        )
        foreach ($path in $changedParse) {
            $tokens = $null
            $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            Assert-CasInt ($null -eq $errors -or @($errors).Count -eq 0) "Changed parse failed: $path"
        }
        $gitInfo = [Diagnostics.ProcessStartInfo]::new()
        $gitInfo.FileName = 'git'
        $gitInfo.WorkingDirectory = $repoRoot
        $gitInfo.UseShellExecute = $false
        $gitInfo.RedirectStandardOutput = $true
        $gitInfo.RedirectStandardError = $true
        $gitInfo.CreateNoWindow = $true
        [void]$gitInfo.ArgumentList.Add('diff')
        [void]$gitInfo.ArgumentList.Add('--check')
        $gitProc = [Diagnostics.Process]::Start($gitInfo)
        $gitOut = $gitProc.StandardOutput.ReadToEnd()
        $gitErr = $gitProc.StandardError.ReadToEnd()
        $gitProc.WaitForExit()
        Assert-CasInt ([int]$gitProc.ExitCode -eq 0) ("git diff --check failed: $gitOut $gitErr")
        $gitProc.Dispose()

        $status = & git -C $repoRoot status --porcelain=v1
        $changed = @()
        foreach ($line in @($status)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $changed += $line.Substring(3).Trim().Replace('\', '/')
        }
        $allowed = @(
            '.github/workflows/ci.yml',
            'docs/architecture.md',
            'docs/codex-app-server-lead.md',
            'docs/quick-start.md',
            'release-manifest.json',
            'src/lead-side/codex-app-server/CodexAppServerLead.Common.ps1',
            'src/lead-side/codex-app-server/CodexAppServerLead.Lifecycle.ps1',
            'src/lead-side/codex-app-server/CodexAppServerCompatibility.psd1',
            'src/lead-side/codex-app-server/Invoke-CodexAppServerCompatibilityQualification.ps1',
            'src/lead-side/codex-app-server/Invoke-WirelessTelephoneSmoke.ps1',
            'tests/lead-side/codex-app-server/fixtures/Mock-CodexAppServer.ps1',
            'tests/lead-side/codex-app-server/test_codex_app_server_lead.ps1'
        )
        foreach ($path in $changed) {
            Assert-CasInt ($allowed -contains $path) "Unallowed path changed: $path"
        }
        Assert-CasInt (-not [IO.File]::Exists((Join-Path $repoRoot '.git/index.lock'))) 'Index lock is present.'
        $manifestFacts = Get-CasIntManifestRouteIds
        Assert-CasInt ([int]$manifestFacts.file_count -eq 208) 'Manifest file count drifted from 208.'
        Assert-CasInt ([int]$manifestFacts.denominator -eq 8) 'Manifest denominator drifted.'
        for ($i = 0; $i -lt 8; $i++) {
            Assert-CasInt ([string]$manifestFacts.route_ids[$i] -ceq [string]$expected[$i]) "Manifest route order drifted at $i."
        }
        Assert-CasInt (@([IO.Directory]::GetFiles($TestRoot, 'owner.json', [IO.SearchOption]::AllDirectories)).Count -eq 0) 'Compatibility run left an owner.json.'

        $docs = [IO.File]::ReadAllText((Join-Path $repoRoot 'docs\codex-app-server-lead.md'))
        Assert-CasInt ($docs.Contains('serializer')) 'Docs omit serializer-extra language.'
        Assert-CasInt ($docs.ToLowerInvariant().Contains('ignored')) 'Docs omit passive ignore of extras.'
        Assert-CasInt ($docs.Contains('serviceTier')) 'Docs omit default service-tier binding.'
        Assert-CasInt ($docs.ToLowerInvariant().Contains('null')) 'Docs omit JSON-null default echo.'
        Assert-CasInt (-not $docs.ToLowerInvariant().Contains('optional generated 0.147 wrapper')) 'Docs still call extras stable generated fields.'

        $personalHits = 0
        $homeRoot = 'C:' + [char]92 + 'Users' + [char]92
        $npmFrag = 'AppData' + [char]92 + 'Roaming' + [char]92 + 'npm'
        foreach ($path in $allowed) {
            $text = [IO.File]::ReadAllText((Join-Path $repoRoot ($path.Replace('/', '\'))))
            if ($text.Contains($homeRoot) -or $text.Contains($npmFrag)) { $personalHits += 1 }
        }
        Assert-CasInt ($personalHits -eq 0) 'Changed package files contain a personal absolute path.'

        $boundedInputs = @(
            @{ path = 'tests/lead-side/codex-app-server/fixtures/Mock-CodexAppServer.ps1'; bytes = 40456; sha256 = '10a740e0ea3fccec1951db35f123e2c670fc20058a88571b5ce480a428da2509' },
            @{ path = 'docs/codex-app-server-lead.md'; bytes = 21954; sha256 = '83336bc6fed698f07d5623291d6968e9661a67f550b32f884b2e0ed0a2b016af' },
            @{ path = 'docs/architecture.md'; bytes = 10532; sha256 = '963035932a18dbc94f5b059c176c275b32d02bcec3ce70ec079b8f716e634d0a' }
        )
        foreach ($item in $boundedInputs) {
            $full = Join-Path $repoRoot ([string]$item.path.Replace('/', '\'))
            $len = [int64](Get-Item -LiteralPath $full).Length
            $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-CasInt ($len -eq [int64]$item.bytes) ("Retained input bytes drifted: $($item.path)")
            Assert-CasInt ($hash -ceq [string]$item.sha256) ("Retained input hash drifted: $($item.path)")
        }

        [ordered]@{
            success = $true
            mode = 'compatibility-approved-version'
            assertions = $assertions
            parse_check = $parseCheck
            denominator_eight = $denominatorEight
            installed_version = $version
            schema_fingerprint = [string]$fingerprint.fingerprint
            schema_file_count = [int]$fingerprint.file_count
            schema_bytes = [int64]$fingerprint.schema_bytes
            compatibility_kind = [string]$schemaEvidence.compatibility_kind
            extras_are_stable_schema_properties = [bool]$schemaEvidence.extras_are_stable_schema_properties
            start_response_open = [bool]$schemaEvidence.start_response_open
            resume_response_open = [bool]$schemaEvidence.resume_response_open
            thread_open = [bool]$schemaEvidence.thread_open
            service_tier_nullable = [bool]$schemaEvidence.service_tier_nullable
            start_serializer_extra_keys = @($schemaEvidence.start_serializer_extra_keys)
            resume_serializer_extra_keys = @($schemaEvidence.resume_serializer_extra_keys)
            thread_serializer_extra_keys = @($schemaEvidence.thread_serializer_extra_keys)
            rejected_root_extra_keys = @($schemaEvidence.rejected_root_extra_keys)
            explicit_default_start = $true
            explicit_default_resume = $true
            null_tier_start_id = $startId
            null_tier_resume_id = $resumeId
            zero_turn_start = $true
            profile_service_tier = [string]$bound.json.profile.service_tier
            profile_fingerprint = [string]$bound.json.profile.schema_fingerprint
            preflight_ready = [bool]$pre.json.ready
            preflight_allow_fast = [bool]$pre.json.allow_fast
            preflight_started = [bool]$pre.json.started
            preflight_residue = $false
            no_provider = $true
            no_owner = $true
            no_binding_on_negatives = $true
            git_diff_check = $true
            test_owned_license_seam = $true
            production_env_bypass_removed = $true
            bounded_inputs_exact = $true
            project_id_omitted_from_stable_thread = $true
            manifest_file_count = [int]$manifestFacts.file_count
            manifest_route_ids = @($manifestFacts.route_ids)
            changed_paths = @($changed)
        } | ConvertTo-Json -Depth 16 -Compress
        return
    }

    if (-not $F02WriterOracleOnly) {
    $script:noProvider = 0

    $hd = New-CasIntHarness -Name 'durable-create'
    $null = Invoke-CasIntProfile -Harness $hd
    $durableLog = Join-Path $hd.root 'durable-create-events.log'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $durableLog
    $durableRunId = 'durable-create-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1'
    $created = Invoke-CasIntDurableCreate -Harness $hd -RunId $durableRunId
    Clear-CasIntTestEnv
    $durableFailureDiagnosticText = ''
    if ($created.exit_code -ne 0) { $durableFailureDiagnosticText = (Get-CasIntDurableCreateFailureDiagnostic -Harness $hd -RunId $durableRunId -Result $created) | ConvertTo-Json -Depth 8 -Compress }
    Assert-CasInt ($created.exit_code -eq 0) ("Durable create failed: diagnostic=$durableFailureDiagnosticText public=$($created.stdout)")
    Assert-CasInt ($created.json.started -eq $true) 'Durable create did not start its first turn.'
    $durableThreadId = [string]$created.json.thread_id
    Assert-CasInt (-not [string]::IsNullOrWhiteSpace($durableThreadId)) 'Durable create did not return a thread id.'
    Assert-CasInt ([IO.File]::Exists([string]$hd.binding)) 'Durable create did not publish its binding.'
    $durableBinding = (Read-TelephoneJson -Path $hd.binding -SchemaName 'lead-binding').value
    Assert-CasInt ([string]$durableBinding.session_id -ceq $durableThreadId) 'Durable create binding points at another thread.'
    $durableAckPath = Join-Path $hd.state ('runs\' + $durableRunId + '\lead-wake-ack.json')
    Assert-CasInt ([IO.File]::Exists($durableAckPath)) 'Durable create did not publish first-turn acknowledgment.'
    $durableAck = (Read-TelephoneJson -Path $durableAckPath -SchemaName 'codex-app-server-lead-ack').value
    Assert-CasInt ([string]$durableAck.session_id -ceq $durableThreadId) 'Durable create acknowledgment points at another thread.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hd -ThreadId $durableThreadId).Count -eq 1) 'Durable create did not converge to exactly one first turn.'
    $processEvents = @(Get-Content -LiteralPath $durableLog | Where-Object { $_ -match '^process:\d+:(thread/start|turn/start)$' })
    Assert-CasInt ($processEvents.Count -eq 2) 'Durable create did not emit one thread/start and one turn/start process record.'
    $threadStartPid = [regex]::Match([string]$processEvents[0], '^process:(\d+):').Groups[1].Value
    $turnStartPid = [regex]::Match([string]$processEvents[1], '^process:(\d+):').Groups[1].Value
    Assert-CasInt (-not [string]::IsNullOrWhiteSpace($threadStartPid) -and $threadStartPid -ceq $turnStartPid) 'Durable create crossed an app-server process boundary before first turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $durableLog -Name 'explicit_default_tier:thread/start') -eq 1) 'Durable create thread/start did not carry explicit default tier.'
    Assert-CasInt ((Get-CasIntEventCount -Path $durableLog -Name 'explicit_default_tier:turn/start') -eq 1) 'Durable create turn/start did not carry explicit default tier.'
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hd -RunId $durableRunId) 'Durable create worker did not reach a coherent terminal.'
    $script:durableCreateSameProcess = 1

    $hd.binding = Join-Path $hd.root 'durable-create-resume-binding.json'
    $durableResumed = Invoke-CasIntBuilder -Harness $hd -ResumeSessionId $durableThreadId
    Assert-CasInt ($durableResumed.exit_code -eq 0) ("Durable create restart resume failed: $($durableResumed.stderr) $($durableResumed.stdout)")
    Assert-CasInt ([string]$durableResumed.json.thread_id -ceq $durableThreadId) 'Durable create restart resumed another thread.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hd -ThreadId $durableThreadId).Count -eq 1) 'Durable create restart resume created another turn.'
    $script:durableCreateRestartResume = 1

    $hf = New-CasIntHarness -Name 'durable-create-fail-closed'
    $null = Invoke-CasIntProfile -Harness $hf
    $env:TELEPHONE_TEST_APP_SERVER_CRASH_AT = 'before-thread-start'
    $failedCreate = Invoke-CasIntDurableCreate -Harness $hf -RunId 'durable-create-fail-closed'
    Clear-CasIntTestEnv
    Assert-CasInt ($failedCreate.exit_code -ne 0) 'Durable create provider failure did not fail closed.'
    Assert-CasInt (-not [IO.File]::Exists([string]$hf.binding)) 'Failed durable create published a binding.'
    $failedOwner = Join-Path $hf.state 'runs\durable-create-fail-closed\owner.json'
    Assert-CasInt (-not [IO.File]::Exists($failedOwner)) 'Failed durable create published an owner before a thread existed.'
    $failedStore = Join-Path $hf.state 'app-server-store.json'
    if ([IO.File]::Exists($failedStore)) {
        $failedStoreDoc = (Read-TelephoneJson -Path $failedStore).value
        Assert-CasInt (@($failedStoreDoc.threads.Keys).Count -eq 0) 'Failed durable create persisted a replacement thread.'
    }
    $script:durableCreateFailClosed = 1

    $h1 = New-CasIntHarness -Name 'direct-thread'
    $null = Invoke-CasIntProfile -Harness $h1
    $built = Invoke-CasIntBuilder -Harness $h1
    Assert-CasInt ($built.exit_code -eq 0) ("Builder failed: $($built.stderr) $($built.stdout)")
    Assert-CasInt ($built.json.started -eq $false) 'Builder started a wake.'
    $threadId = [string]$built.json.thread_id
    Assert-CasInt (-not [string]::IsNullOrWhiteSpace($threadId)) 'Builder did not return a thread id.'
    $script:threadIdDirect = 1

    $h1.binding = Join-Path $h1.root 'lead-binding-resume.json'
    $resumed = Invoke-CasIntBuilder -Harness $h1 -ResumeSessionId $threadId
    Assert-CasInt ($resumed.exit_code -eq 0) ("Resume builder failed: $($resumed.stderr)")
    Assert-CasInt ([string]$resumed.json.thread_id -ceq $threadId) 'Resume returned a different thread id.'
    $script:restartResume = 1

    $runId = 'telephone-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1'
    $wake = Invoke-CasIntLauncher -Harness $h1 -ThreadId $threadId -RunId $runId
    Assert-CasInt ($wake.exit_code -eq 0) ("Launcher failed: $($wake.stderr) $($wake.stdout)")
    Assert-CasInt ($wake.json.started -eq $true) 'Launcher did not start.'
    $ackPath = Join-Path $h1.state ('runs\' + $runId + '\lead-wake-ack.json')
    Assert-CasInt ([IO.File]::Exists($ackPath)) 'Wake ack is missing.'
    $ack = (Read-TelephoneJson -Path $ackPath).value
    Assert-CasInt ([string]$ack.session_id -ceq $threadId) 'Wake ack session is wrong.'
    Assert-CasInt ([string]$ack.event -ceq 'turn.started') 'Wake ack event is wrong.'
    $runAfterAck = Get-CasIntRunJson -Harness $h1 -RunId $runId
    $null = $runAfterAck
    $finalAfterAck = Join-Path (Get-CasIntRunRoot -Harness $h1 -RunId $runId) 'launcher-final.txt'
    $null = $finalAfterAck
    $turns = @(Get-CasIntStoreTurns -Harness $h1 -ThreadId $threadId)
    Assert-CasInt ($turns.Count -eq 1) 'Callback did not produce exactly one turn.'
    $script:callbackOnce = 1

    $wake2 = Invoke-CasIntLauncher -Harness $h1 -ThreadId $threadId -RunId $runId
    Assert-CasInt ($wake2.exit_code -eq 0) 'Idempotent launcher failed.'
    Assert-CasInt ($wake2.json.existing -eq $true) 'Second launcher did not attach to the existing run.'
    $turns = @(Get-CasIntStoreTurns -Harness $h1 -ThreadId $threadId)
    Assert-CasInt ($turns.Count -eq 1) 'Idempotent wake created another turn.'
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $h1 -RunId $runId) 'Worker did not exit after the first callback.'

    $crashCases = @(
        @{ name = 'before-write'; env = 'TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT'; value = 'before-write'; counter = 'crashBeforeWrite' },
        @{ name = 'after-ambiguous-write'; env = 'TELEPHONE_TEST_APP_SERVER_CRASH_AT'; value = 'after-turn-start'; counter = 'crashAfterAmbiguousWrite' },
        @{ name = 'after-turn-bind'; env = 'TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT'; value = 'after-turn-bind'; counter = 'crashAfterTurnBind' },
        @{ name = 'before-ack'; env = 'TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT'; value = 'before-ack'; counter = 'crashBeforeAck' }
    )
    foreach ($case in $crashCases) {
        $h = New-CasIntHarness -Name ('crash-' + $case.name)
        $null = Invoke-CasIntProfile -Harness $h
        $b = Invoke-CasIntBuilder -Harness $h
        $tid = [string]$b.json.thread_id
        $rid = 'run-' + $case.name
        Clear-CasIntTestEnv
        Set-Item -Path ('env:' + $case.env) -Value ([string]$case.value)
        $first = Invoke-CasIntLauncher -Harness $h -ThreadId $tid -RunId $rid
        Clear-CasIntTestEnv
        Assert-CasInt ($first.exit_code -ne 0) ("Crash $($case.name) did not fail closed on the first launch.")
        $null = Wait-CasIntRunQuiet -Harness $h -RunId $rid
        Stop-CasIntRun -Harness $h -RunId $rid
        $second = Invoke-CasIntLauncher -Harness $h -ThreadId $tid -RunId $rid
        Assert-CasInt ($second.exit_code -eq 0) ("Crash $($case.name) did not recover: $($second.stderr) $($second.stdout)")
        $recoveredTurns = @(Get-CasIntStoreTurns -Harness $h -ThreadId $tid)
        Assert-CasInt ($recoveredTurns.Count -eq 1) ("Crash $($case.name) did not converge to one turn.")
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $h -RunId $rid) ("Crash $($case.name) left a live worker.")
        Stop-CasIntRun -Harness $h -RunId $rid
        Set-Variable -Name $case.counter -Scope Script -Value 1
    }

    $hc = New-CasIntHarness -Name 'concurrent'
    $null = Invoke-CasIntProfile -Harness $hc
    $bc = Invoke-CasIntBuilder -Harness $hc
    $tidc = [string]$bc.json.thread_id
    $ridc = 'run-concurrent'
    $procA = Start-CasIntLauncherProcess -Harness $hc -ThreadId $tidc -RunId $ridc
    $procB = Start-CasIntLauncherProcess -Harness $hc -ThreadId $tidc -RunId $ridc
    $procA.process.WaitForExit()
    $procB.process.WaitForExit()
    $outA = [string]$procA.stdout.GetAwaiter().GetResult()
    $outB = [string]$procB.stdout.GetAwaiter().GetResult()
    $procA.process.Dispose()
    $procB.process.Dispose()
    $concTurns = @(Get-CasIntStoreTurns -Harness $hc -ThreadId $tidc)
    Assert-CasInt ($concTurns.Count -eq 1) ("Concurrent launchers created $($concTurns.Count) turns. A=$outA B=$outB")
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hc -RunId $ridc) 'Concurrent worker did not exit.'
    $script:concurrencyOnce = 1

    $zeroThread = [ordered]@{ id = 't'; turns = @() }
    $zeroFound = Find-CodexAppServerMatchingTurns -Thread $zeroThread -Marker 'tl-wake:r1' -BaselineTurnIds @()
    Assert-CasInt (@($zeroFound.matches).Count -eq 0) 'Zero-match helper returned a match.'
    $script:failClosedZero = 1

    $multiThread = [ordered]@{
        id = 't'
        turns = @(
            [ordered]@{ id = 'a'; items = @(, (New-CasIntOfficialUserMessage -Text 'tl-wake:r1' -Id 'um-a')) },
            [ordered]@{ id = 'b'; items = @(, (New-CasIntOfficialUserMessage -Text 'tl-wake:r1' -Id 'um-b')) }
        )
    }
    $multiFound = Find-CodexAppServerMatchingTurns -Thread $multiThread -Marker 'tl-wake:r1' -BaselineTurnIds @()
    Assert-CasInt (@($multiFound.matches).Count -eq 2) 'Multiple-match helper did not see two turns.'
    $script:failClosedMultiple = 1

    $echoThread = [ordered]@{
        id = 't'
        turns = @(
            [ordered]@{ id = 'asst'; items = @([ordered]@{ type = 'assistantMessage'; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1' }) }) },
            [ordered]@{ id = 'tool'; items = @([ordered]@{ type = 'tool'; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1' }) }) },
            [ordered]@{ id = 'err'; items = @([ordered]@{ type = 'error'; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1' }) }) }
        )
    }
    $echoFound = Find-CodexAppServerMatchingTurns -Thread $echoThread -Marker 'tl-wake:r1' -BaselineTurnIds @()
    Assert-CasInt (@($echoFound.matches).Count -eq 0) 'Assistant/tool/error marker echoes were treated as user input.'
    Assert-CasInt (@($echoFound.unexplained).Count -eq 3) 'Echo turns were not unexplained.'
    $script:markerEchoRejected = 1

    $userExact = [ordered]@{
        id = 't'
        turns = @(
            [ordered]@{ id = 'u1'; items = @(, (New-CasIntOfficialUserMessage -Text 'tl-wake:r1' -Id 'um-u1')) }
        )
    }
    $userFound = Find-CodexAppServerMatchingTurns -Thread $userExact -Marker 'tl-wake:r1' -BaselineTurnIds @()
    Assert-CasInt (@($userFound.matches).Count -eq 1) 'Exact user input did not match.'
    $script:markerUserExact = 1

    foreach ($aliasType in @('user', 'input_text', 'inputText')) {
        $aliasThread = [ordered]@{
            id = 't'
            turns = @(
                [ordered]@{ id = 'alias'; items = @([ordered]@{ type = $aliasType; id = 'um-alias'; clientId = $null; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1'; text_elements = @() }) }) }
            )
        }
        $aliasFailed = $false
        try {
            $null = Find-CodexAppServerMatchingTurns -Thread $aliasThread -Marker 'tl-wake:r1' -BaselineTurnIds @()
        } catch { $aliasFailed = $true }
        Assert-CasInt $aliasFailed ("Marker alias $aliasType was not rejected before recovery.")
    }
    $aliasTextThread = [ordered]@{
        id = 't'
        turns = @(
            [ordered]@{ id = 'alias-text'; items = @([ordered]@{ type = 'userMessage'; id = 'um-alias-text'; clientId = $null; content = @([ordered]@{ type = 'input_text'; text = 'tl-wake:r1'; text_elements = @() }) }) }
        )
    }
    $aliasTextFailed = $false
    try {
        $null = Find-CodexAppServerMatchingTurns -Thread $aliasTextThread -Marker 'tl-wake:r1' -BaselineTurnIds @()
    } catch { $aliasTextFailed = $true }
    Assert-CasInt $aliasTextFailed 'input_text content alias was not rejected before marker authorization.'

    $f01Negatives = @(
        @{ name = 'missing-item-id'; item = [ordered]@{ type = 'userMessage'; clientId = $null; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1'; text_elements = @() }) } },
        @{ name = 'extra-item-key'; item = [ordered]@{ type = 'userMessage'; id = 'um-x'; clientId = $null; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1'; text_elements = @() }); extra = $true } },
        @{ name = 'missing-text-elements'; item = [ordered]@{ type = 'userMessage'; id = 'um-x'; clientId = $null; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1' }) } },
        @{ name = 'extra-text-key'; item = [ordered]@{ type = 'userMessage'; id = 'um-x'; clientId = $null; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1'; text_elements = @(); extra = $true }) } },
        @{ name = 'invalid-id-type'; item = [ordered]@{ type = 'userMessage'; id = 1; clientId = $null; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1'; text_elements = @() }) } },
        @{ name = 'invalid-clientId-type'; item = [ordered]@{ type = 'userMessage'; id = 'um-x'; clientId = 1; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1'; text_elements = @() }) } },
        @{ name = 'content-not-array'; item = [ordered]@{ type = 'userMessage'; id = 'um-x'; clientId = $null; content = [ordered]@{ type = 'text'; text = 'tl-wake:r1'; text_elements = @() } } },
        @{ name = 'text-not-string'; item = [ordered]@{ type = 'userMessage'; id = 'um-x'; clientId = $null; content = @([ordered]@{ type = 'text'; text = 12; text_elements = @() }) } },
        @{ name = 'text-elements-not-array'; item = [ordered]@{ type = 'userMessage'; id = 'um-x'; clientId = $null; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1'; text_elements = [ordered]@{ byteRange = [ordered]@{ start = 0; end = 1 }; placeholder = $null } }) } },
        @{ name = 'malformed-text-element'; item = [ordered]@{ type = 'userMessage'; id = 'um-x'; clientId = $null; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1'; text_elements = @([ordered]@{ placeholder = 'x' }) }) } },
        @{ name = 'malformed-nested-union'; item = [ordered]@{ type = 'userMessage'; id = 'um-x'; clientId = $null; content = @([ordered]@{ type = 'image'; url = 1 }) } },
        @{ name = 'malformed-marker-item'; item = [ordered]@{ type = 'userMessage'; id = 'um-x'; clientId = $null; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1'; text_elements = @() }); extra = $true } }
    )
    foreach ($neg in $f01Negatives) {
        $negFailed = $false
        try {
            $null = Find-CodexAppServerMatchingTurns -Thread ([ordered]@{
                id = 't'
                turns = @(
                    [ordered]@{ id = 'n1'; items = @(, $neg.item) }
                )
            }) -Marker 'tl-wake:r1' -BaselineTurnIds @()
        } catch { $negFailed = $true }
        Assert-CasInt $negFailed ("F01 negative $($neg.name) was accepted.")
    }
    $mixedValid = New-CasIntOfficialUserMessage -Text 'tl-wake:r1' -Id 'um-good'
    $mixedBad = [ordered]@{ type = 'userMessage'; id = 'um-bad'; clientId = $null; content = @([ordered]@{ type = 'text'; text = 'tl-wake:r1' }) }
    $mixedFailed = $false
    try {
        $null = Find-CodexAppServerMatchingTurns -Thread ([ordered]@{
            id = 't'
            turns = @(
                [ordered]@{ id = 'mix'; items = @($mixedValid, $mixedBad) }
            )
        }) -Marker 'tl-wake:r1' -BaselineTurnIds @()
    } catch { $mixedFailed = $true }
    Assert-CasInt $mixedFailed 'Malformed sibling userMessage still authorized a marker.'

    $emptyFailed = $false
    try {
        $null = Find-CodexAppServerMatchingTurns -Thread ([ordered]@{
            id = 't'
            turns = @(
                [ordered]@{ id = ''; items = @(, (New-CasIntOfficialUserMessage -Text 'tl-wake:r1' -Id 'um-empty-turn')) }
            )
        }) -Marker 'tl-wake:r1' -BaselineTurnIds @()
    } catch { $emptyFailed = $true }
    Assert-CasInt $emptyFailed 'Empty turn id was accepted during recovery.'
    $script:failClosedEmpty = 1

    $conflictThread = [ordered]@{
        id = 't'
        turns = @(
            [ordered]@{ id = 'old'; items = @() },
            [ordered]@{ id = 'new'; items = @(, (New-CasIntOfficialUserMessage -Text 'unrelated' -Id 'um-new')) }
        )
    }
    $conflictFound = Find-CodexAppServerMatchingTurns -Thread $conflictThread -Marker 'tl-wake:r1' -BaselineTurnIds @('old')
    Assert-CasInt (@($conflictFound.unexplained).Count -eq 1) 'Unexplained new turn was not detected.'
    $script:failClosedUnexplained = 1

    $hm = New-CasIntHarness -Name 'multi-closed'
    $null = Invoke-CasIntProfile -Harness $hm
    $bm = Invoke-CasIntBuilder -Harness $hm
    $tidm = [string]$bm.json.thread_id
    $multiPrompt = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes([string]$hm.prompt))
    $multiText = New-CodexAppServerTurnInputText -PromptText $multiPrompt -RunId 'run-multi'
    $env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS = (@(
        [ordered]@{ id = 'x1'; items = @(, (New-CasIntOfficialUserMessage -Text $multiText -Id 'um-x1')) },
        [ordered]@{ id = 'x2'; items = @(, (New-CasIntOfficialUserMessage -Text $multiText -Id 'um-x2')) }
    ) | ConvertTo-Json -Depth 16 -Compress)
    $multiLaunch = Invoke-CasIntLauncher -Harness $hm -ThreadId $tidm -RunId 'run-multi'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS -ErrorAction SilentlyContinue
    Assert-CasInt ($multiLaunch.exit_code -ne 0) 'Multiple matching turns were not fail-closed.'

    $hs = New-CasIntHarness -Name 'status'
    foreach ($pair in @(
        @{ file = 'notLoaded'; status = 'notLoaded'; flags = @(); pending = @() },
        @{ file = 'idle'; status = 'idle'; flags = @(); pending = @() },
        @{ file = 'systemError'; status = 'systemError'; flags = @(); pending = @() },
        @{ file = 'active'; status = 'active'; flags = @('waitingOnApproval', 'waitingOnUserInput'); pending = @(
            [ordered]@{ method = 'item/commandExecution/requestApproval'; id = 'req-a' },
            [ordered]@{ method = 'item/tool/requestUserInput'; id = 'req-u' }
        ) }
    )) {
        $runRoot = Join-Path $hs.state ('runs\' + $pair.file)
        [IO.Directory]::CreateDirectory($runRoot) | Out-Null
        $null = Write-CodexAppServerProjectedStatus -Path (Join-Path $runRoot 'status.json') -ThreadId 'thread-status' -Status $pair.status -ActiveFlags @($pair.flags) -Pending @($pair.pending)
    }
    $sources = Join-Path $hs.root 'sources.json'
    $null = Write-TelephoneJsonCreateNew -Path $sources -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-status-sources-v1'
        sources = @(
            [ordered]@{ id = 'runs'; kind = 'codex-app-server-lead-runs'; root = (Join-Path $hs.state 'runs') }
        )
    })
    $beforeDirs = @([IO.Directory]::GetDirectories((Join-Path $hs.state 'runs')))
    $st = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @('-SourcesPath', $sources)
    Assert-CasInt ($st.exit_code -eq 0) ("Status failed: $($st.stderr)")
    Assert-CasInt ($st.json.started -eq $false) 'Status started a process.'
    Assert-CasInt ($st.json.mutated -eq $false) 'Status mutated state.'
    $afterDirs = @([IO.Directory]::GetDirectories((Join-Path $hs.state 'runs')))
    Assert-CasInt ($afterDirs.Count -eq $beforeDirs.Count) 'Status created a run.'
    $byStatus = @{}
    foreach ($item in @($st.json.items)) { $byStatus[[string]$item.status] = $item }
    Assert-CasInt ($byStatus.Contains('notLoaded')) 'Status omitted notLoaded.'
    $script:statusNotLoaded = 1
    Assert-CasInt ($byStatus.Contains('idle')) 'Status omitted idle.'
    $script:statusIdle = 1
    Assert-CasInt ($byStatus.Contains('systemError')) 'Status omitted systemError.'
    $script:statusSystemError = 1
    Assert-CasInt ($byStatus.Contains('active')) 'Status omitted active.'
    $script:statusActive = 1
    $active = $byStatus['active']
    Assert-CasInt (@($active.active_flags) -contains 'waitingOnApproval') 'waitingOnApproval was not projected.'
    $script:flagApproval = 1
    Assert-CasInt (@($active.active_flags) -contains 'waitingOnUserInput') 'waitingOnUserInput was not projected.'
    $script:flagUserInput = 1
    $methods = @($active.pending | ForEach-Object { [string]$_.method })
    Assert-CasInt ($methods -contains 'item/commandExecution/requestApproval') 'Approval pending method was not projected.'
    Assert-CasInt ($methods -contains 'item/tool/requestUserInput') 'User-input pending method was not projected.'
    $script:pendingProjected = 1
    $script:statusObservational = 1

    $hp = New-CasIntHarness -Name 'pending-live'
    $null = Invoke-CasIntProfile -Harness $hp
    $bp = Invoke-CasIntBuilder -Harness $hp
    $holdPending = Join-Path $hp.root 'hold-completed'
    $eventLog = Join-Path $hp.root 'events.log'
    Clear-CasIntTestEnv
    $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdPending
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLog
    $env:TELEPHONE_TEST_APP_SERVER_STATUS = 'active'
    $env:TELEPHONE_TEST_APP_SERVER_ACTIVE_FLAGS = 'waitingOnApproval,waitingOnUserInput'
    $env:TELEPHONE_TEST_APP_SERVER_POST_START_SEQUENCE = 'full'
    $env:TELEPHONE_TEST_APP_SERVER_PENDING_METHODS = 'item/commandExecution/requestApproval,item/fileChange/requestApproval,item/permissions/requestApproval,item/tool/requestUserInput,item/unknownExperimental/requestApproval'
    $env:TELEPHONE_TEST_APP_SERVER_PENDING_METHOD = 'item/commandExecution/requestApproval'
    $env:TELEPHONE_TEST_APP_SERVER_PENDING_ID = 'live-pending-1'
    $lp = Invoke-CasIntLauncher -Harness $hp -ThreadId ([string]$bp.json.thread_id) -RunId 'run-pending'
    Assert-CasInt ($lp.exit_code -eq 0) ("Pending live wake failed: $($lp.stderr) $($lp.stdout)")
    Assert-CasInt ([string]$lp.json.state -cne 'completed') 'Pending live launcher completed before turn terminal.'
    $liveStatus = Wait-CasIntStatus -Harness $hp -RunId 'run-pending' -Message 'Live pending methods were not projected after turn/start.' -Predicate {
        param($st)
        $methods = @($st.pending | ForEach-Object { [string]$_.method })
        return (
            $methods -contains 'item/commandExecution/requestApproval' -and
            $methods -contains 'item/fileChange/requestApproval' -and
            $methods -contains 'item/permissions/requestApproval' -and
            $methods -contains 'item/tool/requestUserInput'
        )
    }
    Assert-CasInt (@($liveStatus.active_flags) -contains 'waitingOnApproval') 'Live approval flag was not recorded.'
    Assert-CasInt (@($liveStatus.active_flags) -contains 'waitingOnUserInput') 'Live user-input flag was not recorded.'
    $liveMethods = @($liveStatus.pending | ForEach-Object { [string]$_.method })
    foreach ($needed in @(
        'item/commandExecution/requestApproval',
        'item/fileChange/requestApproval',
        'item/permissions/requestApproval',
        'item/tool/requestUserInput'
    )) {
        Assert-CasInt ($liveMethods -contains $needed) ("Pending method $needed was not projected.")
    }
    Assert-CasInt ($liveMethods -notcontains 'item/unknownExperimental/requestApproval') 'Unknown pending method was trusted.'
    $script:pendingFourMethods = 1
    $script:pendingUnknownIgnored = 1
    $script:pendingProjected = 1
    $obsBefore = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @(
        '-StateRoot', [string]$hp.state, '-RunId', 'run-pending'
    )
    Assert-CasInt ($obsBefore.exit_code -eq 0 -and $obsBefore.json.started -eq $false -and $obsBefore.json.mutated -eq $false) 'Status mutated or started during the live turn.'
    $obsIds = @()
    foreach ($item in @($obsBefore.json.items)) {
        foreach ($p in @($item.pending)) { $obsIds += [string]$p.id }
    }
    Assert-CasInt (($obsIds -contains 'live-pending-1' -or $obsIds -contains 'pending-1')) 'Observational status dropped pending state.'
    $eventText = if ([IO.File]::Exists($eventLog)) { [IO.File]::ReadAllText($eventLog) } else { '' }
    $startAt = $eventText.IndexOf('turn_start_result', [StringComparison]::Ordinal)
    $statusAt = $eventText.IndexOf('status_changed', [StringComparison]::Ordinal)
    $completedAt = $eventText.IndexOf('turn_completed', [StringComparison]::Ordinal)
    Assert-CasInt ($startAt -ge 0 -and $statusAt -gt $startAt) 'Post-start status arrived before the turn/start response.'
    Assert-CasInt ($completedAt -lt 0) 'Mock emitted turn/completed before the hold was released.'
    [IO.File]::WriteAllText($holdPending, 'release', [Text.UTF8Encoding]::new($false))
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hp -RunId 'run-pending') 'Pending-live worker did not exit.'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_STATUS, env:TELEPHONE_TEST_APP_SERVER_ACTIVE_FLAGS, env:TELEPHONE_TEST_APP_SERVER_PENDING_METHOD, env:TELEPHONE_TEST_APP_SERVER_PENDING_ID, env:TELEPHONE_TEST_APP_SERVER_PENDING_METHODS, env:TELEPHONE_TEST_APP_SERVER_POST_START_SEQUENCE, env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH, env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
    $eventText = [IO.File]::ReadAllText($eventLog)
    Assert-CasInt ($eventText.IndexOf('turn_completed', [StringComparison]::Ordinal) -gt $eventText.IndexOf('turn_start_result', [StringComparison]::Ordinal)) 'turn/completed was not after turn/start.'
    $afterPending = (Read-TelephoneJson -Path (Join-Path $hp.state 'runs\run-pending\status.json') -SchemaName 'codex-app-server-lead-status').value
    Assert-CasInt (@($afterPending.pending).Count -eq 0 -or $null -eq $afterPending.pending) 'Pending records were not cleared after terminal.'

    $hr = New-CasIntHarness -Name 'pending-resolve'
    $null = Invoke-CasIntProfile -Harness $hr
    $br = Invoke-CasIntBuilder -Harness $hr
    $holdResolve = Join-Path $hr.root 'hold-completed'
    $resolveLog = Join-Path $hr.root 'resolve-events.log'
    Clear-CasIntTestEnv
    $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdResolve
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $resolveLog
    $env:TELEPHONE_TEST_APP_SERVER_PENDING_METHOD = 'item/tool/requestUserInput'
    $env:TELEPHONE_TEST_APP_SERVER_PENDING_ID = 'resolve-me'
    $env:TELEPHONE_TEST_APP_SERVER_RESOLVE_PENDING = '1'
    $lr = Invoke-CasIntLauncher -Harness $hr -ThreadId ([string]$br.json.thread_id) -RunId 'run-resolve'
    Assert-CasInt ($lr.exit_code -eq 0) ("Resolve wake failed: $($lr.stderr) $($lr.stdout)")
    $deadlineResolve = [DateTimeOffset]::UtcNow.AddSeconds(20)
    $sawResolved = $false
    while ([DateTimeOffset]::UtcNow -lt $deadlineResolve) {
        if ([IO.File]::Exists($resolveLog) -and [IO.File]::ReadAllText($resolveLog).Contains('resolved:resolve-me')) {
            $sawResolved = $true
            break
        }
        Start-Sleep -Milliseconds 50
    }
    Assert-CasInt $sawResolved 'serverRequest/resolved was not emitted after turn/start.'
    $resolvedStatus = Wait-CasIntStatus -Harness $hr -RunId 'run-resolve' -Message 'Resolved pending id remained in status.' -Predicate {
        param($st)
        $ids = @($st.pending | ForEach-Object { [string]$_.id })
        return ($ids -notcontains 'resolve-me')
    }
    $resolvedIds = @($resolvedStatus.pending | ForEach-Object { [string]$_.id })
    Assert-CasInt ($resolvedIds -notcontains 'resolve-me') 'Resolved pending id remained in status.'
    [IO.File]::WriteAllText($holdResolve, 'release', [Text.UTF8Encoding]::new($false))
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hr -RunId 'run-resolve') 'Resolve worker did not exit.'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH, env:TELEPHONE_TEST_APP_SERVER_PENDING_METHOD, env:TELEPHONE_TEST_APP_SERVER_PENDING_ID, env:TELEPHONE_TEST_APP_SERVER_RESOLVE_PENDING, env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
    $script:pendingResolvedCleared = 1
    $null = $resolvedStatus

    $hl = New-CasIntHarness -Name 'lifecycle-hold'
    $null = Invoke-CasIntProfile -Harness $hl
    $bl = Invoke-CasIntBuilder -Harness $hl
    $tidl = [string]$bl.json.thread_id
    $ridl = 'run-lifecycle'
    $holdLife = Join-Path $hl.root 'hold-completed'
    $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdLife
    $life1 = Invoke-CasIntLauncher -Harness $hl -ThreadId $tidl -RunId $ridl
    Assert-CasInt ($life1.exit_code -eq 0) ("Lifecycle launcher failed: $($life1.stderr)")
    Assert-CasInt ([IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hl -RunId $ridl) 'lead-wake-ack.json'))) 'Lifecycle ack missing.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hl -RunId $ridl) 'launcher-final.txt'))) 'Lifecycle wrote launcher-final before terminal.'
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hl -RunId $ridl).disposition -ceq 'in_progress') 'Lifecycle run was terminal at ack.'
    $bound1 = Get-CasIntBoundJson -Harness $hl -RunId $ridl
    $life2 = Invoke-CasIntLauncher -Harness $hl -ThreadId $tidl -RunId $ridl
    Assert-CasInt ($life2.exit_code -eq 0 -and $life2.json.existing -eq $true) 'Launcher-exit attach failed.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hl -ThreadId $tidl).Count -eq 1) 'Launcher-exit attach started a second turn.'
    $script:launcherExitSameTurn = 1
    $script:durableAckBeforeTerminal = 1
    [IO.File]::WriteAllText($holdLife, 'release', [Text.UTF8Encoding]::new($false))
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hl -RunId $ridl) 'Lifecycle worker did not exit.'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH -ErrorAction SilentlyContinue

    Invoke-CasIntAppServerDeathRecoveryProof -Name 'death-app-server'

    Invoke-CasIntWorkerDeathRecoveryProof -Name 'death-worker'

    Invoke-CasIntCallbackContinuationProof

    foreach ($term in @('completed', 'failed', 'interrupted')) {
        $ht = New-CasIntHarness -Name ('terminal-' + $term)
        $null = Invoke-CasIntProfile -Harness $ht
        $bt = Invoke-CasIntBuilder -Harness $ht
        $tidt = [string]$bt.json.thread_id
        $ridt = 'run-term-' + $term
        $env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS = $term
        $t1 = Invoke-CasIntLauncher -Harness $ht -ThreadId $tidt -RunId $ridt
        $terminalDiagnostic = ''
        if ($t1.exit_code -ne 0) { $terminalDiagnostic = (Get-CasIntDurableCreateFailureDiagnostic -Harness $ht -RunId $ridt -Result $t1) | ConvertTo-Json -Depth 8 -Compress }
        Assert-CasInt ($t1.exit_code -eq 0) ("Official $term first launch failed: diagnostic=$terminalDiagnostic public=$($t1.stdout)")
        $turnId = [string](Get-CasIntBoundJson -Harness $ht -RunId $ridt).turn_id
        $terminalSettled = Wait-CasIntOfficialTerminalAndQuiet -Harness $ht -RunId $ridt -ThreadId $tidt -TurnId $turnId -Disposition $term
        Assert-CasInt ([bool]$terminalSettled.success) ("Official $term did not settle: terminal=$([bool]$terminalSettled.terminal) run_quiet=$([bool]$terminalSettled.run_quiet) thread_quiet=$([bool]$terminalSettled.thread_quiet) phase=$([string]$terminalSettled.phase) state=$([string]$terminalSettled.state).")
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS -ErrorAction SilentlyContinue
        Assert-CasInt ([string](Get-CasIntRunJson -Harness $ht -RunId $ridt).disposition -ceq $term) ("Official $term run disposition is wrong.")
        Assert-CasInt ([string](Get-CasIntBoundJson -Harness $ht -RunId $ridt).state -ceq $term) ("Official $term bound state is wrong.")
        Assert-CasInt ([string](Get-CasIntBoundJson -Harness $ht -RunId $ridt).turn_id -ceq [string](Get-CasIntRunJson -Harness $ht -RunId $ridt).selected_turn_id) ("Official $term selected turn drifted.")
        Assert-CasInt ([string](Get-CasIntFinalText -Harness $ht -RunId $ridt) -ceq $term) ("Official $term final artifact is wrong.")
        $afterPending = (Read-TelephoneJson -Path (Join-Path $ht.state ('runs\' + $ridt + '\status.json')) -SchemaName 'codex-app-server-lead-status').value
        Assert-CasInt (@($afterPending.pending).Count -eq 0 -or $null -eq $afterPending.pending) ("Official $term left pending state.")
        $t2 = Invoke-CasIntLauncher -Harness $ht -ThreadId $tidt -RunId $ridt
        Assert-CasInt ($t2.exit_code -eq 0 -and $t2.json.existing -eq $true) ("Official $term repeat did not return existing.")
        Assert-CasInt ([string]$t2.json.state -ceq $term) ("Official $term repeat state is wrong.")
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $ht -ThreadId $tidt).Count -eq 1) ("Official $term repeat started a second turn.")
        Assert-CasInt (-not (Test-CasIntOwnerAlive -Harness $ht -RunId $ridt)) ("Official $term repeat started a worker.")
        if ($term -ceq 'completed') { $script:officialCompleted = 1 }
        if ($term -ceq 'failed') { $script:officialFailed = 1 }
        if ($term -ceq 'interrupted') { $script:officialInterrupted = 1 }
    }

    Clear-CasIntTestEnv
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT, env:TELEPHONE_TEST_APP_SERVER_CRASH_AT, env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS, env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH -ErrorAction SilentlyContinue
    $hq = New-CasIntHarness -Name 'quiet-read'
    $null = Invoke-CasIntProfile -Harness $hq
    $bq = Invoke-CasIntBuilder -Harness $hq
    $tidq = [string]$bq.json.thread_id
    $ridq = 'run-quiet'
    $holdQuiet = Join-Path $hq.root 'hold-completed'
    $quietLog = Join-Path $hq.root 'quiet-events.log'
    $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdQuiet
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $quietLog
    $env:TELEPHONE_TEST_APP_SERVER_FORMER_READ_TIMEOUT_MS = '80'
    $env:TELEPHONE_TEST_APP_SERVER_POST_START_DELAY_MS = '250'
    $q1 = Invoke-CasIntLauncher -Harness $hq -ThreadId $tidq -RunId $ridq
    if ($q1.exit_code -ne 0) {
        $qPaths = Get-CodexAppServerRunPaths -StateRoot ([string]$hq.state) -RunId $ridq
        $qErr = ''
        if ([IO.File]::Exists($qPaths.stderr_evidence)) { $qErr = [IO.File]::ReadAllText($qPaths.stderr_evidence) }
        $qTrans = ''
        if ([IO.File]::Exists($qPaths.transitions)) { $qTrans = [IO.File]::ReadAllText($qPaths.transitions) }
        Assert-CasInt $false ("Quiet-read launch failed: $($q1.stderr) $($q1.stdout) stderr_evidence=$qErr transitions=$qTrans")
    }
    Start-Sleep -Milliseconds 150
    Assert-CasInt (Test-CasIntOwnerAlive -Harness $hq -RunId $ridq) 'Quiet interval ended the worker.'
    Assert-CasInt ([string](Get-CasIntFinalText -Harness $hq -RunId $ridq) -ceq '') 'Quiet interval wrote a false final.'
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hq -RunId $ridq).disposition -cne 'failed') 'Quiet interval marked the run failed.'
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hq -RunId $ridq).disposition -cne 'interrupted') 'Quiet interval marked the run interrupted.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hq -ThreadId $tidq).Count -eq 1) 'Quiet interval started a second turn.'
    $selectedQuiet = [string](Get-CasIntBoundJson -Harness $hq -RunId $ridq).turn_id
    $null = Wait-CasIntStatus -Harness $hq -RunId $ridq -Message 'Quiet-read worker did not consume the delayed matching events.' -Predicate {
        param($st)
        return ([string]$st.status -ceq 'active' -or @($st.pending).Count -ge 0)
    }
    Assert-CasInt (Test-CasIntOwnerAlive -Harness $hq -RunId $ridq) 'Delayed events ended the worker before the matching terminal.'
    Assert-CasInt ([string](Get-CasIntBoundJson -Harness $hq -RunId $ridq).turn_id -ceq $selectedQuiet) 'Quiet interval altered the selected turn.'
    $lifePath = Join-Path (Get-CasIntRunRoot -Harness $hq -RunId $ridq) 'read-lifetime.json'
    Assert-CasInt (Wait-CasIntPath -Path $lifePath) 'Read-lifetime evidence is missing.'
    $life = (Read-TelephoneJson -Path $lifePath).value
    Assert-CasInt ([bool]$life.accepted_turn_unbounded -eq $true) 'Accepted-turn read was not unbounded.'
    Assert-CasInt ([bool]$life.absolute_task_timeout -eq $false) 'Accepted-turn read recorded an absolute timeout.'
    Assert-CasInt ([int]$life.concurrent_stdout_read_starts -eq 0) 'A competing stdout read was started.'
    Assert-CasInt ([int]$life.former_threshold_ms -eq 80) 'Former threshold was not recorded for the quiet-read proof.'
    [IO.File]::WriteAllText($holdQuiet, 'release', [Text.UTF8Encoding]::new($false))
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hq -RunId $ridq) 'Quiet-read worker did not converge.'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH, env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG, env:TELEPHONE_TEST_APP_SERVER_FORMER_READ_TIMEOUT_MS, env:TELEPHONE_TEST_APP_SERVER_POST_START_DELAY_MS -ErrorAction SilentlyContinue
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hq -RunId $ridq).disposition -ceq 'completed') 'Quiet-read did not converge on the matching terminal.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hq -ThreadId $tidq).Count -eq 1) 'Quiet-read convergence started a second turn.'
    $script:quietReadSurvived = 1
    $script:noConcurrentStdoutRead = 1
    $script:noAbsoluteTurnTimeout = 1

    $hx = New-CasIntHarness -Name 'cross-identity'
    $null = Invoke-CasIntProfile -Harness $hx
    $bx = Invoke-CasIntBuilder -Harness $hx
    $tidx = [string]$bx.json.thread_id
    $ridx = 'run-cross'
    $holdCross = Join-Path $hx.root 'hold-completed'
    $crossLog = Join-Path $hx.root 'cross-events.log'
    $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdCross
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $crossLog
    $env:TELEPHONE_TEST_APP_SERVER_INJECT_FOREIGN = '1'
    $env:TELEPHONE_TEST_APP_SERVER_PENDING_METHOD = 'item/commandExecution/requestApproval'
    $env:TELEPHONE_TEST_APP_SERVER_PENDING_ID = 'bound-pending-1'
    $x1 = Invoke-CasIntLauncher -Harness $hx -ThreadId $tidx -RunId $ridx
    Assert-CasInt ($x1.exit_code -eq 0) ("Cross-identity launch failed: $($x1.stderr)")
    $crossStatus = Wait-CasIntStatus -Harness $hx -RunId $ridx -Message 'Bound pending was not projected before foreign traffic.' -Predicate {
        param($st)
        $ids = @($st.pending | ForEach-Object { [string]$_.id })
        return ($ids -contains 'bound-pending-1')
    }
    $deadlineForeign = [DateTimeOffset]::UtcNow.AddSeconds(15)
    $sawForeign = $false
    while ([DateTimeOffset]::UtcNow -lt $deadlineForeign) {
        if ([IO.File]::Exists($crossLog) -and [IO.File]::ReadAllText($crossLog).Contains('unknown_terminal')) {
            $sawForeign = $true
            break
        }
        Start-Sleep -Milliseconds 50
    }
    Assert-CasInt $sawForeign 'Foreign/malformed terminal traffic was not emitted after turn/start.'
    Start-Sleep -Milliseconds 200
    $afterForeign = (Read-TelephoneJson -Path (Join-Path $hx.state 'runs\run-cross\status.json') -SchemaName 'codex-app-server-lead-status').value
    $afterIds = @($afterForeign.pending | ForEach-Object { [string]$_.id })
    Assert-CasInt ($afterIds -contains 'bound-pending-1') 'Bound pending was cleared by foreign traffic.'
    Assert-CasInt ($afterIds -notcontains 'foreign-pending') 'Cross-thread pending mutated the bound callback.'
    Assert-CasInt ($afterIds -notcontains 'cross-turn-pending') 'Cross-turn pending mutated the bound callback.'
    Assert-CasInt ([string]$afterForeign.status -cne 'systemError') 'Cross-thread status mutated the bound callback.'
    Assert-CasInt ([string](Get-CasIntFinalText -Harness $hx -RunId $ridx) -ceq '') 'Malformed terminal wrote a final artifact.'
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hx -RunId $ridx).disposition -cne 'completed') 'Malformed or unknown terminal defaulted to completed.'
    Assert-CasInt ([string](Get-CasIntBoundJson -Harness $hx -RunId $ridx).state -cne 'completed') 'Malformed terminal mutated bound state to completed.'
    $script:crossIdentityIgnored = 1
    $script:malformedTerminalNotCompleted = 1
    [IO.File]::WriteAllText($holdCross, 'release', [Text.UTF8Encoding]::new($false))
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hx -RunId $ridx) 'Cross-identity worker did not exit.'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH, env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG, env:TELEPHONE_TEST_APP_SERVER_INJECT_FOREIGN, env:TELEPHONE_TEST_APP_SERVER_PENDING_METHOD, env:TELEPHONE_TEST_APP_SERVER_PENDING_ID -ErrorAction SilentlyContinue
    Assert-CasInt ([string](Get-CasIntRunJson -Harness $hx -RunId $ridx).disposition -ceq 'completed') 'Bound callback did not converge after ignoring foreign traffic.'

    $hcw = New-CasIntHarness -Name 'chain-windows'
    $null = Invoke-CasIntProfile -Harness $hcw
    $bcw = Invoke-CasIntBuilder -Harness $hcw
    $tidcw = [string]$bcw.json.thread_id

    $hIntent = New-CasIntHarness -Name 'chain-intent-only'
    $null = Invoke-CasIntProfile -Harness $hIntent
    $bIntent = Invoke-CasIntBuilder -Harness $hIntent
    $validIntentOnly = 'run-chain-intent'
    $null = Write-CasIntPlantedIntent -Harness $hIntent -RunId $validIntentOnly -ThreadId ([string]$bIntent.json.thread_id)
    $v1 = Invoke-CasIntLauncher -Harness $hIntent -ThreadId ([string]$bIntent.json.thread_id) -RunId $validIntentOnly
    Assert-CasInt ($v1.exit_code -eq 0) ("Intent-only crash window failed: $($v1.stderr) $($v1.stdout)")
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hIntent -RunId $validIntentOnly) 'Intent-only worker did not exit.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hIntent -ThreadId ([string]$bIntent.json.thread_id)).Count -eq 1) 'Intent-only window did not send exactly one turn.'
    $script:chainValidRecovered = 1

    $hIR = New-CasIntHarness -Name 'chain-intent-run'
    $null = Invoke-CasIntProfile -Harness $hIR
    $bIR = Invoke-CasIntBuilder -Harness $hIR
    $validIntentRun = 'run-chain-intent-run'
    $p2 = Write-CasIntPlantedIntent -Harness $hIR -RunId $validIntentRun -ThreadId ([string]$bIR.json.thread_id)
    Write-CasIntPlantedRun -Paths $p2 -Harness $hIR -RunId $validIntentRun -ThreadId ([string]$bIR.json.thread_id)
    $v2 = Invoke-CasIntLauncher -Harness $hIR -ThreadId ([string]$bIR.json.thread_id) -RunId $validIntentRun
    Assert-CasInt ($v2.exit_code -eq 0) ("Intent/run crash window failed: $($v2.stderr)")
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hIR -RunId $validIntentRun) 'Intent/run worker did not exit.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hIR -ThreadId ([string]$bIR.json.thread_id)).Count -eq 1) 'Intent/run window did not send exactly one turn.'

    $orphanAck = 'run-orphan-ack'
    $poa = Get-CodexAppServerRunPaths -StateRoot ([string]$hcw.state) -RunId $orphanAck
    [IO.Directory]::CreateDirectory($poa.run_root) | Out-Null
    Write-CasIntPlantedAck -Paths $poa -ThreadId $tidcw -TurnId 'turn-orphan-ack'
    $turnsOrphan = @(Get-CasIntStoreTurns -Harness $hcw -ThreadId $tidcw).Count
    $oa = Invoke-CasIntLauncher -Harness $hcw -ThreadId $tidcw -RunId $orphanAck
    Assert-CasInt ($oa.exit_code -ne 0) 'Orphan ack was not fail-closed.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path $poa.run_root 'child.json'))) 'Orphan ack contacted app-server.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hcw -ThreadId $tidcw).Count -eq $turnsOrphan) 'Orphan ack started a turn.'
    $script:chainOrphanAckClosed = 1

    $orphanBound = 'run-orphan-bound'
    $pob = Get-CodexAppServerRunPaths -StateRoot ([string]$hcw.state) -RunId $orphanBound
    [IO.Directory]::CreateDirectory($pob.run_root) | Out-Null
    Write-CasIntPlantedBound -Paths $pob -ThreadId $tidcw -TurnId 'turn-orphan-bound'
    $turnsBound = @(Get-CasIntStoreTurns -Harness $hcw -ThreadId $tidcw).Count
    $ob = Invoke-CasIntLauncher -Harness $hcw -ThreadId $tidcw -RunId $orphanBound
    Assert-CasInt ($ob.exit_code -ne 0) 'Orphan bound was not fail-closed.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path $pob.run_root 'child.json'))) 'Orphan bound contacted app-server.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hcw -ThreadId $tidcw).Count -eq $turnsBound) 'Orphan bound started a turn.'
    $script:chainOrphanBoundClosed = 1

    $conflict = 'run-conflict'
    $pc = Write-CasIntPlantedIntent -Harness $hcw -RunId $conflict -ThreadId $tidcw
    Write-CasIntPlantedRun -Paths $pc -Harness $hcw -RunId $conflict -ThreadId $tidcw -Selected 'turn-selected' -Disposition 'in_progress'
    Write-CasIntPlantedBound -Paths $pc -ThreadId $tidcw -TurnId 'turn-bound'
    Write-CasIntPlantedAck -Paths $pc -ThreadId $tidcw -TurnId 'turn-ack'
    $turnsConflict = @(Get-CasIntStoreTurns -Harness $hcw -ThreadId $tidcw).Count
    $cf = Invoke-CasIntLauncher -Harness $hcw -ThreadId $tidcw -RunId $conflict
    Assert-CasInt ($cf.exit_code -ne 0) 'Selected/bound/ack conflict was not fail-closed.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path $pc.run_root 'child.json'))) 'Selected/bound/ack conflict contacted app-server.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hcw -ThreadId $tidcw).Count -eq $turnsConflict) 'Conflict started a turn.'
    $script:chainConflictClosed = 1

    $termNoChain = 'run-term-no-chain'
    $ptn = Write-CasIntPlantedIntent -Harness $hcw -RunId $termNoChain -ThreadId $tidcw
    Write-CasIntPlantedRun -Paths $ptn -Harness $hcw -RunId $termNoChain -ThreadId $tidcw -Selected '' -Disposition 'completed'
    $null = Write-TelephoneTextCreateNew -Path $ptn.final -Text "completed`n"
    $turnsTerm = @(Get-CasIntStoreTurns -Harness $hcw -ThreadId $tidcw).Count
    $tn = Invoke-CasIntLauncher -Harness $hcw -ThreadId $tidcw -RunId $termNoChain
    Assert-CasInt ($tn.exit_code -ne 0) 'Terminal without the full chain was not fail-closed.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path $ptn.run_root 'child.json'))) 'Terminal without the full chain contacted app-server.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hcw -ThreadId $tidcw).Count -eq $turnsTerm) 'Terminal without the full chain started a turn.'
    $script:chainTerminalWithoutChainClosed = 1

    $liveBypass = 'run-live-bypass'
    $plb = Get-CodexAppServerRunPaths -StateRoot ([string]$hcw.state) -RunId $liveBypass
    [IO.Directory]::CreateDirectory($plb.run_root) | Out-Null
    Write-CasIntPlantedAck -Paths $plb -ThreadId $tidcw -TurnId 'turn-live-bypass'
    $null = Write-TelephoneJsonCreateNew -Path $plb.owner -Value (New-CodexAppServerOwnerRecord)
    $turnsLive = @(Get-CasIntStoreTurns -Harness $hcw -ThreadId $tidcw).Count
    $lb = Invoke-CasIntLauncher -Harness $hcw -ThreadId $tidcw -RunId $liveBypass
    Assert-CasInt ($lb.exit_code -ne 0) 'Ack plus live owner did not fail closed before attach.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path $plb.run_root 'child.json'))) 'Ack plus live owner contacted app-server.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hcw -ThreadId $tidcw).Count -eq $turnsLive) 'Ack plus live owner started a turn.'
    $script:chainLiveOwnerBypassClosed = 1

    $hF01 = New-CasIntHarness -Name 'f01-protocol'
    $null = Invoke-CasIntProfile -Harness $hF01
    $env:TELEPHONE_TEST_APP_SERVER_OMIT_THREAD_ID = '1'
    $omitStart = Invoke-CasIntBuilder -Harness $hF01
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_OMIT_THREAD_ID -ErrorAction SilentlyContinue
    Assert-CasInt ($omitStart.exit_code -ne 0) 'Missing thread id was accepted.'
    Assert-CasInt ([string]$omitStart.json.error -ceq (Get-CodexAppServerPublicMessage -Code 'STABLE_PROTOCOL_INVALID')) 'Missing thread id leaked a raw protocol error.'
    $hF01b = New-CasIntHarness -Name 'f01-foreign-thread'
    $null = Invoke-CasIntProfile -Harness $hF01b
    $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_THREAD_ID = '1'
    $foreignStart = Invoke-CasIntBuilder -Harness $hF01b -ResumeSessionId 'thread-known'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_FOREIGN_THREAD_ID -ErrorAction SilentlyContinue
    Assert-CasInt ($foreignStart.exit_code -ne 0) 'Foreign thread id was accepted.'
    $hF01c = New-CasIntHarness -Name 'f01-turn'
    $null = Invoke-CasIntProfile -Harness $hF01c
    $bF01c = Invoke-CasIntBuilder -Harness $hF01c
    $env:TELEPHONE_TEST_APP_SERVER_OMIT_TURN_ID = '1'
    $omitTurn = Invoke-CasIntLauncher -Harness $hF01c -ThreadId ([string]$bF01c.json.thread_id) -RunId 'run-omit-turn'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_OMIT_TURN_ID -ErrorAction SilentlyContinue
    Assert-CasInt ($omitTurn.exit_code -ne 0) 'Idless turn was acknowledged.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hF01c -RunId 'run-omit-turn') 'lead-wake-ack.json'))) 'Idless turn wrote ack.'
    $hF01d = New-CasIntHarness -Name 'f01-foreign-turn'
    $null = Invoke-CasIntProfile -Harness $hF01d
    $bF01d = Invoke-CasIntBuilder -Harness $hF01d
    $env:TELEPHONE_TEST_APP_SERVER_FOREIGN_TURN_ID = 'foreign-turn-id'
    $foreignTurn = Invoke-CasIntLauncher -Harness $hF01d -ThreadId ([string]$bF01d.json.thread_id) -RunId 'run-foreign-turn'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_FOREIGN_TURN_ID -ErrorAction SilentlyContinue
    Assert-CasInt ($foreignTurn.exit_code -ne 0) 'Foreign turn id was acknowledged.'
    $clientF01 = [ordered]@{
        pending = [Collections.Generic.List[object]]::new()
        last_status = [ordered]@{ status = 'active'; active_flags = @('waitingOnApproval') }
        bound_thread_id = 'thread-f01'
        bound_turn_id = 'turn-f01'
        last_terminal = $null
    }
    $null = Add-CodexAppServerPending -Client $clientF01 -Method 'item/commandExecution/requestApproval' -Id 'req-f01'
    $beforePending = @($clientF01.pending).Count
    $beforeStatus = [string]$clientF01.last_status.status
    foreach ($alias in @('complete', 'success', 'error', 'systemError', 'cancelled', 'canceled')) {
        $appliedAlias = Apply-CodexAppServerInboundMessage -Client $clientF01 -Message ([ordered]@{
            method = 'turn/completed'
            params = [ordered]@{ threadId = 'thread-f01'; turn = [ordered]@{ id = 'turn-f01'; status = $alias } }
        }) -BoundThreadId 'thread-f01' -BoundTurnId 'turn-f01'
        Assert-CasInt ([string]$appliedAlias.kind -ceq 'ignored') ("Alias $alias was treated as an official terminal.")
    }
    $appliedErr = Apply-CodexAppServerInboundMessage -Client $clientF01 -Message ([ordered]@{
        method = 'turn/completed'
        params = [ordered]@{ threadId = 'thread-f01'; turn = [ordered]@{ id = 'turn-f01'; error = [ordered]@{ message = 'boom' } }
        }
    }) -BoundThreadId 'thread-f01' -BoundTurnId 'turn-f01'
    Assert-CasInt ([string]$appliedErr.kind -ceq 'ignored') 'Error-only terminal was inferred as failed.'
    $appliedResolved = Apply-CodexAppServerInboundMessage -Client $clientF01 -Message ([ordered]@{
        method = 'serverRequest/resolved'
        params = [ordered]@{ requestId = 'req-f01' }
    }) -BoundThreadId 'thread-f01' -BoundTurnId 'turn-f01'
    Assert-CasInt ([string]$appliedResolved.kind -ceq 'ignored') 'Resolved without threadId cleared pending.'
    Assert-CasInt (@($clientF01.pending).Count -eq $beforePending) 'Pending was cleared by a missing-thread resolution.'
    $appliedBadStatus = Apply-CodexAppServerInboundMessage -Client $clientF01 -Message ([ordered]@{
        method = 'thread/status/changed'
        params = [ordered]@{ threadId = 'thread-f01'; status = [ordered]@{ type = 'idle'; extra = $true } }
    }) -BoundThreadId 'thread-f01' -BoundTurnId 'turn-f01'
    Assert-CasInt ([string]$appliedBadStatus.kind -ceq 'ignored') 'Malformed same-thread status mutated state.'
    Assert-CasInt ([string]$clientF01.last_status.status -ceq $beforeStatus) 'Malformed same-thread status changed last_status.'
    $appliedTurnIdResolved = Apply-CodexAppServerInboundMessage -Client $clientF01 -Message ([ordered]@{
        method = 'serverRequest/resolved'
        params = [ordered]@{ threadId = 'thread-f01'; requestId = 'req-f01'; turnId = 'turn-f01' }
    }) -BoundThreadId 'thread-f01' -BoundTurnId 'turn-f01'
    Assert-CasInt ([string]$appliedTurnIdResolved.kind -ceq 'ignored') 'Resolved with invented turnId cleared pending.'
    Assert-CasInt (@($clientF01.pending).Count -eq $beforePending) 'Pending was cleared by a turnId resolution.'
    $unwrappedIgnored = Apply-CodexAppServerInboundMessage -Client $clientF01 -Message ([ordered]@{
        threadId = 'thread-f01'
        status = [ordered]@{ type = 'idle' }
    }) -BoundThreadId 'thread-f01' -BoundTurnId 'turn-f01'
    Assert-CasInt ([string]$unwrappedIgnored.kind -ceq 'ignored') 'Unwrapped status object mutated state.'
    $hF01e = New-CasIntHarness -Name 'f01-unwrap'
    $null = Invoke-CasIntProfile -Harness $hF01e
    $env:TELEPHONE_TEST_APP_SERVER_UNWRAP_THREAD = '1'
    $unwrapStart = Invoke-CasIntBuilder -Harness $hF01e
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_UNWRAP_THREAD -ErrorAction SilentlyContinue
    Assert-CasInt ($unwrapStart.exit_code -ne 0) 'Unwrapped thread start was accepted.'
    $hF01f = New-CasIntHarness -Name 'f01-turn-extra'
    $null = Invoke-CasIntProfile -Harness $hF01f
    $bF01f = Invoke-CasIntBuilder -Harness $hF01f
    $env:TELEPHONE_TEST_APP_SERVER_TURN_START_EXTRA = '1'
    $extraTurn = Invoke-CasIntLauncher -Harness $hF01f -ThreadId ([string]$bF01f.json.thread_id) -RunId 'run-turn-extra'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_TURN_START_EXTRA -ErrorAction SilentlyContinue
    Assert-CasInt ($extraTurn.exit_code -ne 0) 'TurnStartResponse extra fields were accepted.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hF01f -RunId 'run-turn-extra') 'lead-wake-ack.json'))) 'TurnStart extra fields wrote ack.'
    $hF01g = New-CasIntHarness -Name 'f01-omit-wrapper'
    $null = Invoke-CasIntProfile -Harness $hF01g
    $env:TELEPHONE_TEST_APP_SERVER_OMIT_WRAPPER_FIELD = 'model'
    $omitWrap = Invoke-CasIntBuilder -Harness $hF01g
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_OMIT_WRAPPER_FIELD -ErrorAction SilentlyContinue
    Assert-CasInt ($omitWrap.exit_code -ne 0) 'Missing wrapper field was accepted.'
    $hF01m = New-CasIntHarness -Name 'f01-malformed-marker-launch'
    $null = Invoke-CasIntProfile -Harness $hF01m
    $bF01m = Invoke-CasIntBuilder -Harness $hF01m
    $tidF01m = [string]$bF01m.json.thread_id
    $malPrompt = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes([string]$hF01m.prompt))
    $malText = New-CodexAppServerTurnInputText -PromptText $malPrompt -RunId 'run-malformed-marker'
    $env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS = (@(
        [ordered]@{ id = 'mal-1'; items = @(, [ordered]@{ type = 'userMessage'; id = 'um-mal'; clientId = $null; content = @([ordered]@{ type = 'text'; text = $malText }) }) },
        [ordered]@{ id = 'mal-2'; items = @(, (New-CasIntOfficialUserMessage -Text $malText -Id 'um-ok')) }
    ) | ConvertTo-Json -Depth 16 -Compress)
    $malLaunch = Invoke-CasIntLauncher -Harness $hF01m -ThreadId $tidF01m -RunId 'run-malformed-marker'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS -ErrorAction SilentlyContinue
    Assert-CasInt ($malLaunch.exit_code -ne 0) 'Malformed marker-bearing userMessage was accepted.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hF01m -RunId 'run-malformed-marker') 'lead-wake-ack.json'))) 'Malformed marker wrote ack.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hF01m -RunId 'run-malformed-marker') 'recovery.json'))) 'Malformed marker wrote recovery.'
    $script:f01StableProtocol = 1

    $hF02 = New-CasIntHarness -Name 'f02-chain'
    $null = Invoke-CasIntProfile -Harness $hF02
    $bF02 = Invoke-CasIntBuilder -Harness $hF02
    $tidF02 = [string]$bF02.json.thread_id
    $wrongProto = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-wrong-protocol' -ThreadId $tidF02
    $intentDoc = Get-Content -LiteralPath $wrongProto.intent -Raw | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $intentDoc.protocol_version = 'telephone-line-codex-app-server-lead-intent-v0'
    [IO.File]::WriteAllText($wrongProto.intent, ((ConvertTo-Json $intentDoc -Depth 32).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $wp = Invoke-CasIntLauncher -Harness $hF02 -ThreadId $tidF02 -RunId 'run-wrong-protocol'
    Assert-CasInt ($wp.exit_code -ne 0) 'Wrong intent protocol was accepted.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path $wrongProto.run_root 'child.json'))) 'Wrong protocol contacted app-server.'
    $extraIntent = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-extra-field' -ThreadId $tidF02
    $extraDoc = Get-Content -LiteralPath $extraIntent.intent -Raw | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $extraDoc.extra = $true
    [IO.File]::WriteAllText($extraIntent.intent, ((ConvertTo-Json $extraDoc -Depth 32).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $ef = Invoke-CasIntLauncher -Harness $hF02 -ThreadId $tidF02 -RunId 'run-extra-field'
    Assert-CasInt ($ef.exit_code -ne 0) 'Extra intent field was accepted.'
    $badBound = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-bad-bound-state' -ThreadId $tidF02
    Write-CasIntPlantedRun -Paths $badBound -Harness $hF02 -RunId 'run-bad-bound-state' -ThreadId $tidF02
    Write-CasIntPlantedBound -Paths $badBound -ThreadId $tidF02 -TurnId 'turn-bad' -State 'banana'
    $bb = Invoke-CasIntLauncher -Harness $hF02 -ThreadId $tidF02 -RunId 'run-bad-bound-state'
    Assert-CasInt ($bb.exit_code -ne 0) 'Invalid bound state was accepted.'
    $noAck = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-term-no-ack' -ThreadId $tidF02
    Write-CasIntPlantedRun -Paths $noAck -Harness $hF02 -RunId 'run-term-no-ack' -ThreadId $tidF02 -Selected 'turn-term' -Disposition 'completed'
    Write-CasIntPlantedBound -Paths $noAck -ThreadId $tidF02 -TurnId 'turn-term' -State 'completed'
    $null = Write-TelephoneTextCreateNew -Path $noAck.final -Text "completed`n"
    $na = Invoke-CasIntLauncher -Harness $hF02 -ThreadId $tidF02 -RunId 'run-term-no-ack'
    Assert-CasInt ($na.exit_code -ne 0) 'Terminal without ack was accepted.'
    $noFinal = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-term-no-final' -ThreadId $tidF02
    Write-CasIntPlantedRun -Paths $noFinal -Harness $hF02 -RunId 'run-term-no-final' -ThreadId $tidF02 -Selected 'turn-term' -Disposition 'completed'
    Write-CasIntPlantedBound -Paths $noFinal -ThreadId $tidF02 -TurnId 'turn-term' -State 'completed'
    Write-CasIntPlantedAck -Paths $noFinal -ThreadId $tidF02 -TurnId 'turn-term'
    $nf = Invoke-CasIntLauncher -Harness $hF02 -ThreadId $tidF02 -RunId 'run-term-no-final'
    Assert-CasInt ($nf.exit_code -ne 0) 'Terminal without final was accepted.'
    $malOwner = Get-CodexAppServerRunPaths -StateRoot ([string]$hF02.state) -RunId 'run-malformed-owner'
    [IO.Directory]::CreateDirectory($malOwner.run_root) | Out-Null
    [IO.File]::WriteAllText($malOwner.owner, "{`"pid`":1}`n", [Text.UTF8Encoding]::new($false))
    $beforeOwner = [IO.File]::ReadAllText($malOwner.owner)
    $mo = Invoke-CasIntLauncher -Harness $hF02 -ThreadId $tidF02 -RunId 'run-malformed-owner'
    Assert-CasInt ($mo.exit_code -ne 0) 'Malformed owner was treated as replaceable.'
    Assert-CasInt ([IO.File]::ReadAllText($malOwner.owner) -ceq $beforeOwner) 'Malformed owner was replaced.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path $malOwner.run_root 'child.json'))) 'Malformed owner contacted app-server.'
    $badFail = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-malformed-failure' -ThreadId $tidF02
    Write-CasIntPlantedRun -Paths $badFail -Harness $hF02 -RunId 'run-malformed-failure' -ThreadId $tidF02
    [IO.File]::WriteAllText($badFail.failure, "{`"category`":`"worker`"}`n", [Text.UTF8Encoding]::new($false))
    $mf = Invoke-CasIntLauncher -Harness $hF02 -ThreadId $tidF02 -RunId 'run-malformed-failure'
    Assert-CasInt ($mf.exit_code -ne 0) 'Malformed failure.json was accepted.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path $badFail.run_root 'child.json'))) 'Malformed failure.json contacted app-server.'
    $pendingBound = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-pending-before-ack' -ThreadId $tidF02
    Write-CasIntPlantedRun -Paths $pendingBound -Harness $hF02 -RunId 'run-pending-before-ack' -ThreadId $tidF02 -Phase 'turn_bound'
    Write-CasIntPlantedBound -Paths $pendingBound -ThreadId $tidF02 -TurnId 'turn-pending' -State 'pending'
    $pb = Invoke-CasIntLauncher -Harness $hF02 -ThreadId $tidF02 -RunId 'run-pending-before-ack'
    Assert-CasInt ($pb.exit_code -ne 0) 'Pending bound before ack was accepted.'
    $termBound = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-term-before-ack' -ThreadId $tidF02
    Write-CasIntPlantedRun -Paths $termBound -Harness $hF02 -RunId 'run-term-before-ack' -ThreadId $tidF02 -Phase 'turn_bound'
    Write-CasIntPlantedBound -Paths $termBound -ThreadId $tidF02 -TurnId 'turn-term-early' -State 'completed'
    $tb = Invoke-CasIntLauncher -Harness $hF02 -ThreadId $tidF02 -RunId 'run-term-before-ack'
    Assert-CasInt ($tb.exit_code -ne 0) 'Terminal bound before ack was accepted.'
    $unauthRec = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-unauth-recovery' -ThreadId $tidF02
    Write-CasIntPlantedRun -Paths $unauthRec -Harness $hF02 -RunId 'run-unauth-recovery' -ThreadId $tidF02 -Disposition 'recovery_required'
    $ur = Invoke-CasIntLauncher -Harness $hF02 -ThreadId $tidF02 -RunId 'run-unauth-recovery'
    Assert-CasInt ($ur.exit_code -ne 0) 'Intent+run recovery_required was accepted in an unauthorized window.'
    $unauthFb = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-unauth-fallback' -ThreadId $tidF02
    Write-CasIntPlantedRun -Paths $unauthFb -Harness $hF02 -RunId 'run-unauth-fallback' -ThreadId $tidF02 -Disposition 'fallback_required_cli' -Phase 'turn_start_sending'
    $uf = Invoke-CasIntLauncher -Harness $hF02 -ThreadId $tidF02 -RunId 'run-unauth-fallback'
    Assert-CasInt ($uf.exit_code -ne 0) 'CLI fallback after turn_start_sending was accepted.'
    $validTerm = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-valid-terminal' -ThreadId $tidF02
    Write-CasIntPlantedRun -Paths $validTerm -Harness $hF02 -RunId 'run-valid-terminal' -ThreadId $tidF02 -Selected 'turn-ok' -Disposition 'completed' -Phase 'terminal' -TerminalTarget 'completed'
    Write-CasIntPlantedBound -Paths $validTerm -ThreadId $tidF02 -TurnId 'turn-ok' -State 'completed'
    Write-CasIntPlantedAck -Paths $validTerm -ThreadId $tidF02 -TurnId 'turn-ok'
    $null = Write-TelephoneTextCreateNew -Path $validTerm.final -Text "completed`n"
    Write-CasIntPlantedResult -Paths $validTerm -RunId 'run-valid-terminal' -State 'completed'
    Assert-CodexAppServerDurableChain -Paths $validTerm -RunId 'run-valid-terminal' -ThreadId $tidF02 -Worktree ([string]$hF02.worktree) -CallbackIdentity (Get-TelephoneFileIdentity -Path ([string]$hF02.prompt)) -Marker (Get-CodexAppServerWakeMarker -RunId 'run-valid-terminal') -Profile ((Read-TelephoneJson -Path ([string]$hF02.profile) -SchemaName 'codex-app-server-lead-profile').value) -ProfilePath ([string]$hF02.profile)
    $validPub = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-valid-publishing' -ThreadId $tidF02
    Write-CasIntPlantedRun -Paths $validPub -Harness $hF02 -RunId 'run-valid-publishing' -ThreadId $tidF02 -Selected 'turn-pub' -Disposition 'in_progress' -Phase 'terminal_publishing' -TerminalTarget 'completed'
    Write-CasIntPlantedBound -Paths $validPub -ThreadId $tidF02 -TurnId 'turn-pub' -State 'active'
    Write-CasIntPlantedAck -Paths $validPub -ThreadId $tidF02 -TurnId 'turn-pub'
    Assert-CodexAppServerDurableChain -Paths $validPub -RunId 'run-valid-publishing' -ThreadId $tidF02 -Worktree ([string]$hF02.worktree) -CallbackIdentity (Get-TelephoneFileIdentity -Path ([string]$hF02.prompt)) -Marker (Get-CodexAppServerWakeMarker -RunId 'run-valid-publishing') -Profile ((Read-TelephoneJson -Path ([string]$hF02.profile) -SchemaName 'codex-app-server-lead-profile').value) -ProfilePath ([string]$hF02.profile)
    $validRec = Write-CasIntPlantedIntent -Harness $hF02 -RunId 'run-valid-recovery' -ThreadId $tidF02
    Write-CasIntPlantedRun -Paths $validRec -Harness $hF02 -RunId 'run-valid-recovery' -ThreadId $tidF02 -Selected 'turn-rec' -Disposition 'recovery_required' -Phase 'acknowledged'
    Write-CasIntPlantedBound -Paths $validRec -ThreadId $tidF02 -TurnId 'turn-rec' -State 'recovery_required'
    Write-CasIntPlantedAck -Paths $validRec -ThreadId $tidF02 -TurnId 'turn-rec'
    Write-CasIntPlantedRecovery -Paths $validRec -RunId 'run-valid-recovery' -ThreadId $tidF02 -TurnId 'turn-rec' -Phase 'acknowledged'
    Assert-CodexAppServerDurableChain -Paths $validRec -RunId 'run-valid-recovery' -ThreadId $tidF02 -Worktree ([string]$hF02.worktree) -CallbackIdentity (Get-TelephoneFileIdentity -Path ([string]$hF02.prompt)) -Marker (Get-CodexAppServerWakeMarker -RunId 'run-valid-recovery') -Profile ((Read-TelephoneJson -Path ([string]$hF02.profile) -SchemaName 'codex-app-server-lead-profile').value) -ProfilePath ([string]$hF02.profile)
    $f02Neg = @(
        @{ name = 'cross-run-result'; mutate = { param($p,$h,$rid,$tid) Write-CasIntPlantedResult -Paths $p -RunId 'other-run' -State 'in_progress' } },
        @{ name = 'wrong-root-result'; mutate = { param($p,$h,$rid,$tid) Write-CasIntPlantedResult -Paths $p -RunId $rid -State 'in_progress' -RunRoot 'C:\other\state\runs\other-run' } },
        @{ name = 'stale-result'; mutate = { param($p,$h,$rid,$tid) Write-CasIntPlantedBound -Paths $p -ThreadId $tid -TurnId 'turn-stale'; Write-CasIntPlantedAck -Paths $p -ThreadId $tid -TurnId 'turn-stale'; Write-CasIntPlantedRun -Paths $p -Harness $h -RunId $rid -ThreadId $tid -Selected 'turn-stale' -Disposition 'in_progress' -Phase 'acknowledged'; Write-CasIntPlantedResult -Paths $p -RunId $rid -State 'completed' } },
        @{ name = 'cross-run-recovery'; mutate = { param($p,$h,$rid,$tid) Write-CasIntPlantedRecovery -Paths $p -RunId 'other-run' -ThreadId $tid -TurnId '' -Phase 'none' } },
        @{ name = 'wrong-root-recovery'; mutate = { param($p,$h,$rid,$tid) Write-CasIntPlantedRecovery -Paths $p -RunId $rid -ThreadId $tid -TurnId '' -Phase 'none' -RunRoot 'C:\other\state\runs\other-run' } },
        @{ name = 'wrong-thread-recovery'; mutate = { param($p,$h,$rid,$tid) Write-CasIntPlantedRecovery -Paths $p -RunId $rid -ThreadId 'other-thread' -TurnId '' -Phase 'none' } },
        @{ name = 'wrong-turn-recovery'; mutate = { param($p,$h,$rid,$tid) Write-CasIntPlantedBound -Paths $p -ThreadId $tid -TurnId 'turn-keep'; Write-CasIntPlantedAck -Paths $p -ThreadId $tid -TurnId 'turn-keep'; Write-CasIntPlantedRun -Paths $p -Harness $h -RunId $rid -ThreadId $tid -Selected 'turn-keep' -Disposition 'recovery_required' -Phase 'acknowledged'; Write-CasIntPlantedRecovery -Paths $p -RunId $rid -ThreadId $tid -TurnId 'other-turn' -Phase 'acknowledged' } },
        @{ name = 'cross-run-failure'; mutate = { param($p,$h,$rid,$tid) Write-CasIntPlantedFailure -Paths $p -RunId 'other-run' -ThreadId $tid -Phase 'none' -Disposition 'in_progress' -Code 'worker_failed' } },
        @{ name = 'wrong-root-failure'; mutate = { param($p,$h,$rid,$tid) Write-CasIntPlantedFailure -Paths $p -RunId $rid -ThreadId $tid -Phase 'none' -Disposition 'in_progress' -Code 'worker_failed' -RunRoot 'C:\other\state\runs\other-run' } },
        @{ name = 'impossible-failure-code'; mutate = { param($p,$h,$rid,$tid) Write-CasIntPlantedFailure -Paths $p -RunId $rid -ThreadId $tid -Phase 'acknowledged' -Disposition 'in_progress' -Code 'schema_or_version_mismatch' } },
        @{ name = 'impossible-state'; mutate = { param($p,$h,$rid,$tid) Write-CasIntPlantedBound -Paths $p -ThreadId $tid -TurnId 'turn-imp'; Write-CasIntPlantedAck -Paths $p -ThreadId $tid -TurnId 'turn-imp'; Write-CasIntPlantedRun -Paths $p -Harness $h -RunId $rid -ThreadId $tid -Selected 'turn-imp' -Disposition 'completed' -Phase 'acknowledged' } }
    )
    $f02SkipDefaultRun = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($skip in @('wrong-turn-recovery', 'stale-result', 'impossible-state')) { [void]$f02SkipDefaultRun.Add($skip) }
    foreach ($neg in $f02Neg) {
        $rid = 'run-' + [string]$neg.name
        $planted = Write-CasIntPlantedIntent -Harness $hF02 -RunId $rid -ThreadId $tidF02
        if (-not $f02SkipDefaultRun.Contains([string]$neg.name)) {
            Write-CasIntPlantedRun -Paths $planted -Harness $hF02 -RunId $rid -ThreadId $tidF02
        }
        & $neg.mutate $planted $hF02 $rid $tidF02
        $beforeResult = ''
        if ([IO.File]::Exists($planted.result)) { $beforeResult = [IO.File]::ReadAllText($planted.result) }
        $beforeRecovery = ''
        if ([IO.File]::Exists($planted.recovery)) { $beforeRecovery = [IO.File]::ReadAllText($planted.recovery) }
        $beforeFailure = ''
        if ([IO.File]::Exists($planted.failure)) { $beforeFailure = [IO.File]::ReadAllText($planted.failure) }
        $negLaunch = Invoke-CasIntLauncher -Harness $hF02 -ThreadId $tidF02 -RunId $rid
        Assert-CasInt ($negLaunch.exit_code -ne 0) ("F02 negative $($neg.name) was accepted.")
        Assert-CasInt (-not [IO.File]::Exists((Join-Path $planted.run_root 'child.json'))) ("F02 negative $($neg.name) contacted app-server.")
        if ($beforeResult -ne '') {
            Assert-CasInt ([IO.File]::Exists($planted.result)) ("F02 negative $($neg.name) deleted launcher-result.json.")
            Assert-CasInt ([IO.File]::ReadAllText($planted.result) -ceq $beforeResult) ("F02 negative $($neg.name) mutated launcher-result.json.")
        }
        if ($beforeRecovery -ne '') {
            Assert-CasInt ([IO.File]::ReadAllText($planted.recovery) -ceq $beforeRecovery) ("F02 negative $($neg.name) mutated recovery.json.")
        }
        if ($beforeFailure -ne '') {
            Assert-CasInt ([IO.File]::ReadAllText($planted.failure) -ceq $beforeFailure) ("F02 negative $($neg.name) mutated failure.json.")
        }
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hF02 -ThreadId $tidF02).Count -eq 0) ("F02 negative $($neg.name) started a turn.")
    }
    }

    $hF02Hist = New-CasIntHarness -Name 'f02-history'
    $null = Invoke-CasIntProfile -Harness $hF02Hist
    $bF02Hist = Invoke-CasIntBuilder -Harness $hF02Hist
    $tidF02Hist = [string]$bF02Hist.json.thread_id
    $observedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $observedRows = [Collections.Generic.List[object]]::new()
    $script:f02DuplicateRows = 0
    $script:f02RawObservationCount = 0
    $script:f02SubmittedCount = 0
    $script:f02DuplicateProvenance = [Collections.Generic.List[object]]::new()
    $script:f02TupleProvenance = [Collections.Generic.List[object]]::new()
    $script:f02LegalRecoveryHistory = 0
    $script:f02LegalFailureHistory = 0
    $scenarioDefs = @(Get-CasIntWriterScenarioDefinitions)
    $relationNames = [Collections.Generic.List[string]]::new()
    foreach ($spec in $scenarioDefs) {
        $inInventory = $true
        if ($spec.Contains('relation_inventory')) { $inInventory = [bool]$spec.relation_inventory }
        if ($inInventory) { $relationNames.Add([string]$spec.name) }
    }
    $script:f02ScenarioCount = [int]$relationNames.Count
    $script:f02ScenarioNames = @($relationNames)
    $captureNeedle = 'capture' + '_' + 'kinds'
    $ledgerNeedle = 'ledger' + '_' + 'kinds'
    $tableNeedle = 'CodexAppServerDurable' + 'HistoryRows'
    $originNeedle = 'origin' + '_' + 'codes'
    $ownedNeedle = 'owned' + 'Keys'
    $ownedFnNeedle = 'Invoke-CasInt' + 'Owned' + 'WriterScenario'
    $beforeKeysNeedle = 'Before' + 'Keys'
    $testSrc = [IO.File]::ReadAllText($PSCommandPath)
    Assert-CasInt ($testSrc.IndexOf($captureNeedle, [StringComparison]::Ordinal) -lt 0) 'A capture-kind filter was reintroduced into the writer oracle.'
    Assert-CasInt ($testSrc.IndexOf($ledgerNeedle, [StringComparison]::Ordinal) -lt 0) 'A ledger-kind filter was reintroduced into the writer oracle.'
    Assert-CasInt ($testSrc.IndexOf($originNeedle, [StringComparison]::Ordinal) -lt 0) 'Origin-forward still fans out multiple worlds for later unique projection.'
    Assert-CasInt ($testSrc.IndexOf($ownedNeedle, [StringComparison]::Ordinal) -lt 0) 'Owner-local key set unique projection was reintroduced.'
    Assert-CasInt ($testSrc.IndexOf($ownedFnNeedle, [StringComparison]::Ordinal) -lt 0) 'Owner-local writer wrapper was reintroduced.'
    $defSrc = [string]((Get-Command Get-CasIntWriterScenarioDefinitions).ScriptBlock)
    $invokeSrc = [string]((Get-Command Invoke-CasIntWriterScenario).ScriptBlock)
    $attrSrc = [string]((Get-Command Get-CasIntAttributedTuples).ScriptBlock)
    $indSrc = [string]((Get-Command Get-CasIntIndependentExpectedHistoryRows).ScriptBlock)
    Assert-CasInt ($null -eq (Get-Command -Name $ownedFnNeedle -ErrorAction SilentlyContinue)) 'Owner-local writer wrapper command is still present.'
    Assert-CasInt ($defSrc.IndexOf($tableNeedle, [StringComparison]::Ordinal) -lt 0) 'Relation inventory scenarios were generated from the production history table.'
    Assert-CasInt ($indSrc.IndexOf($tableNeedle, [StringComparison]::Ordinal) -lt 0) 'Independent expected relation was generated from the production history table.'
    Assert-CasInt ($defSrc.IndexOf($captureNeedle, [StringComparison]::Ordinal) -lt 0) 'Relation inventory still names a capture-kind filter.'
    Assert-CasInt ($defSrc.IndexOf($originNeedle, [StringComparison]::Ordinal) -lt 0) 'Relation inventory still names a multi-code origin fan-out.'
    Assert-CasInt ($invokeSrc.IndexOf($captureNeedle, [StringComparison]::Ordinal) -lt 0) 'Writer scenario capture still names a capture-kind filter.'
    Assert-CasInt ($invokeSrc.IndexOf($ledgerNeedle, [StringComparison]::Ordinal) -lt 0) 'Writer scenario capture still names a ledger-kind filter.'
    Assert-CasInt ($invokeSrc.IndexOf($ownedNeedle, [StringComparison]::Ordinal) -lt 0) 'Writer scenario capture still unique-projects through an owner-local set.'
    Assert-CasInt ($attrSrc.IndexOf('Test-CasIntBytesChanged', [StringComparison]::Ordinal) -ge 0) 'Planted exclusion no longer compares declaration bytes.'
    Assert-CasInt ($attrSrc.IndexOf($beforeKeysNeedle, [StringComparison]::Ordinal) -lt 0) 'Key-only planted exclusion was reintroduced.'
    $recoveredCmpNeedle = '-cne ' + "'" + 'recovered' + "'"
    $kindRecoveryNeedle = '$kind -ceq ' + "'" + 'recovery' + "'"
    Assert-CasInt ($attrSrc.IndexOf($recoveredCmpNeedle, [StringComparison]::Ordinal) -lt 0) 'Changed-key recovery suppression compared current_disposition to recovered.'
    Assert-CasInt ($attrSrc.IndexOf($kindRecoveryNeedle, [StringComparison]::Ordinal) -lt 0) 'A recovery-kind pre-submission filter was reintroduced.'
    Assert-CasInt ($attrSrc.IndexOf('recoveryChanged', [StringComparison]::Ordinal) -lt 0) 'Unchanged-declaration recovery suppression was reintroduced.'
    Assert-CasInt ($attrSrc.IndexOf('failureChanged', [StringComparison]::Ordinal) -lt 0) 'Unchanged-declaration failure suppression was reintroduced.'
    Assert-CasInt (([regex]::Matches($attrSrc, '\bcontinue\b')).Count -eq 1) 'Get-CasIntAttributedTuples has extra pre-submission continues.'
    $ffwNeedle = 'failure' + '-' + 'forward' + '-' + 'writer'
    $directSrc = [string]((Get-Command Invoke-CasIntDirectWriterProcess).ScriptBlock)
    Assert-CasInt ($testSrc.IndexOf($ffwNeedle, [StringComparison]::Ordinal) -lt 0) 'A test-only failure-forward writer was reintroduced.'
    Assert-CasInt ($defSrc.IndexOf($ffwNeedle, [StringComparison]::Ordinal) -lt 0) 'Relation inventory still names a test-only failure-forward writer.'
    Assert-CasInt ($invokeSrc.IndexOf($ffwNeedle, [StringComparison]::Ordinal) -lt 0) 'Writer scenario capture still names a test-only failure-forward writer.'
    Assert-CasInt ($directSrc.IndexOf($ffwNeedle, [StringComparison]::Ordinal) -lt 0) 'Direct writer process still contains a test-only failure-forward writer.'
    $script:f02CaptureFilterAbsent = 1
    $script:f02OwnerLocalDedupeAbsent = 1
    $script:f02PerCallRaw = [Collections.Generic.List[object]]::new()

    $sameKeySpec = @{
        name = 'probe-same-key-byte'
        invoke = 'failure-writer'
        plant = $true
        phase = 'none'
        disp = 'in_progress'
        turn = 'prebind'
        rec = $false
        plant_failure = $true
        code = 'schema_or_version_mismatch'
        writer = 'failure-writer'
        boundary = 'failure-snapshot'
        call_site = 'Write-CodexAppServerFailureRecord'
    }
    $sameKeyExec = Invoke-CasIntWriterScenario -Harness $hF02Hist -ThreadId $tidF02Hist -Spec $sameKeySpec
    Assert-CasInt ([int]$sameKeyExec.raw_count -ge 1) 'Same-key byte-changing rewrite was suppressed before submission.'
    $script:f02SameKeyByteObservation = 1

    $changedKeyOrigins = @(
        @{ suffix = 'sending-prebind'; phase = 'turn_start_sending'; turn = 'prebind'; code = 'compatibility_drift_after_bind' },
        @{ suffix = 'sending-bound'; phase = 'turn_start_sending'; turn = 'bound'; code = 'transport_lost_before_terminal' },
        @{ suffix = 'turn-bound'; phase = 'turn_bound'; turn = 'bound'; code = 'transport_lost_before_terminal' },
        @{ suffix = 'acked'; phase = 'acknowledged'; turn = 'acked'; code = 'transport_lost_before_terminal' }
    )
    $changedKeySeen = 0
    foreach ($origin in $changedKeyOrigins) {
        $changedKeySpec = @{
            name = ('probe-changed-key-recovery-' + [string]$origin.suffix)
            invoke = 'recovery-writer'
            plant = $true
            phase = [string]$origin.phase
            disp = 'in_progress'
            turn = [string]$origin.turn
            rec = $true
            plant_failure = $true
            fail_code = [string]$origin.code
            writer = 'recovery-required-run'
            boundary = 'recovery-required-run'
            call_site = 'Write-CodexAppServerRecoveryRequired'
        }
        $changedKeyExec = Invoke-CasIntWriterScenario -Harness $hF02Hist -ThreadId $tidF02Hist -Spec $changedKeySpec
        Assert-CasInt ([int]$changedKeyExec.raw_count -ge 2) ("Changed-key recovery origin $($origin.suffix) was suppressed before raw submission. raw=$($changedKeyExec.raw_count)")
        $sawChangedRecovery = $false
        $sawFailForward = $false
        foreach ($tuple in @($changedKeyExec.raw_tuples)) {
            $kind = Get-CodexAppServerDictString -Dict $tuple -Key 'kind'
            $currentDisp = Get-CodexAppServerDictString -Dict $tuple -Key 'current_disposition'
            $recordedDisp = Get-CodexAppServerDictString -Dict $tuple -Key 'recorded_disposition'
            if ($kind -ceq 'recovery' -and $currentDisp -ceq 'recovery_required') { $sawChangedRecovery = $true }
            if ($kind -ceq 'failure' -and $recordedDisp -ceq 'in_progress' -and $currentDisp -ceq 'recovery_required') { $sawFailForward = $true }
        }
        Assert-CasInt $sawChangedRecovery ("Changed-key recovery origin $($origin.suffix) omitted the recovery observation.")
        Assert-CasInt $sawFailForward ("Changed-key recovery origin $($origin.suffix) omitted the fail-forward observation.")
        $changedKeySeen += 1
    }
    Assert-CasInt ($changedKeySeen -eq 4) 'The four formerly suppressed origin recovery cases did not all reach raw submission.'
    $script:f02ChangedKeyRecoveryObservation = 1

    $probeKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $probeRows = [Collections.Generic.List[object]]::new()
    $script:f02DuplicateRows = 0
    $script:f02DuplicateProvenance = [Collections.Generic.List[object]]::new()
    $script:f02TupleProvenance = [Collections.Generic.List[object]]::new()
    $script:f02LegalRecoveryHistory = 0
    $script:f02LegalFailureHistory = 0
    $dupSpecA = @{
        name = 'probe-dup-a'
        invoke = 'failure-writer'
        plant = $true
        phase = 'none'
        disp = 'in_progress'
        turn = 'prebind'
        rec = $false
        code = 'schema_or_version_mismatch'
        writer = 'failure-writer'
        boundary = 'failure-snapshot'
        call_site = 'Write-CodexAppServerFailureRecord'
    }
    $dupSpecB = @{
        name = 'probe-dup-b'
        invoke = 'failure-writer'
        plant = $true
        phase = 'none'
        disp = 'in_progress'
        turn = 'prebind'
        rec = $false
        code = 'schema_or_version_mismatch'
        writer = 'failure-writer'
        boundary = 'failure-snapshot'
        call_site = 'Write-CodexAppServerFailureRecord'
    }
    $dupExecA = Invoke-CasIntWriterScenario -Harness $hF02Hist -ThreadId $tidF02Hist -Spec $dupSpecA
    $dupExecB = Invoke-CasIntWriterScenario -Harness $hF02Hist -ThreadId $tidF02Hist -Spec $dupSpecB
    Assert-CasInt ($dupExecA.raw_count -ge 1) 'Duplicate-probe first writer emitted no tuple.'
    Assert-CasInt ($dupExecB.raw_count -ge 1) 'Duplicate-probe second writer emitted no tuple.'
    foreach ($tuple in @($dupExecA.tuples)) {
        Add-CasIntObservedTuple -Tuple $tuple -Scenario 'probe-dup-a' -Writer 'failure-writer' -Boundary 'failure-snapshot' -CallSite 'Write-CodexAppServerFailureRecord' -ObservedKeys $probeKeys -ObservedRows $probeRows
    }
    foreach ($tuple in @($dupExecB.tuples)) {
        Add-CasIntObservedTuple -Tuple $tuple -Scenario 'probe-dup-b' -Writer 'failure-writer' -Boundary 'failure-snapshot' -CallSite 'Write-CodexAppServerFailureRecord' -ObservedKeys $probeKeys -ObservedRows $probeRows
    }
    Assert-CasInt ($script:f02DuplicateRows -ge 1) 'Deliberate duplicated writer observation did not reach duplicate accounting.'
    Assert-CasInt ($script:f02DuplicateProvenance.Count -ge 1) 'Duplicate accounting omitted provenance.'
    $probeDup = $script:f02DuplicateProvenance[0]
    Assert-CasInt ($null -ne $probeDup.first) 'Duplicate accounting omitted first provenance.'
    Assert-CasInt ($null -ne $probeDup.second) 'Duplicate accounting omitted second provenance.'
    Assert-CasInt ([string]$probeDup.first.scenario -ceq 'probe-dup-a') 'Duplicate first provenance is not the first writer call.'
    Assert-CasInt ([string]$probeDup.second.scenario -ceq 'probe-dup-b') 'Duplicate second provenance is not the second writer call.'
    Assert-CasInt ([string]$probeDup.first.key -ceq [string]$probeDup.second.key) 'Duplicate provenances do not share the canonical key.'
    $script:f02DuplicateProbe = 1
    $script:f02DuplicateProbeProvenance = @($script:f02DuplicateProvenance)
    $script:f02DuplicateRows = 0
    $script:f02DuplicateProvenance = [Collections.Generic.List[object]]::new()
    $script:f02TupleProvenance = [Collections.Generic.List[object]]::new()
    $script:f02LegalRecoveryHistory = 0
    $script:f02LegalFailureHistory = 0
    $script:f02RawObservationCount = 0
    $script:f02SubmittedCount = 0

    foreach ($spec in $scenarioDefs) {
        $inInventory = $true
        if ($spec.Contains('relation_inventory')) { $inInventory = [bool]$spec.relation_inventory }
        try {
            $executed = Invoke-CasIntWriterScenario -Harness $hF02Hist -ThreadId $tidF02Hist -Spec $spec
        } catch {
            throw ("Writer scenario $([string]$spec.name) failed: " + [string]$_.Exception.Message)
        }
        Assert-CasInt ([int]$executed.raw_count -eq @($executed.tuples).Count) ("Writer scenario $($spec.name) diverged raw captured tuples from returned tuples.")
        Assert-CasInt ([int]$executed.raw_count -eq @($executed.raw_tuples).Count) ("Writer scenario $($spec.name) reassigned raw_count away from the raw stream.")
        $requireTuple = $true
        if ($spec.Contains('expect_tuple')) { $requireTuple = [bool]$spec.expect_tuple }
        if ($requireTuple) {
            $recExists = [IO.File]::Exists($executed.paths.recovery)
            $failExists = [IO.File]::Exists($executed.paths.failure)
            Assert-CasInt ($executed.tuples.Count -gt 0) ("Writer scenario $($spec.name) produced no recovery or failure tuple. recovery=$recExists failure=$failExists tuples=$($executed.tuples.Count)")
        } else {
            Assert-CasInt (-not [IO.File]::Exists($executed.paths.recovery)) ("Writer scenario $($spec.name) wrote unmatched recovery.json.")
        }
        if ($spec.Contains('expect_raw')) {
            Assert-CasInt ([int]$executed.raw_count -eq [int]$spec.expect_raw) ("Writer scenario $($spec.name) raw_count=$($executed.raw_count) expected $($spec.expect_raw).")
        }
        if (-not $inInventory) { continue }
        $script:f02RawObservationCount += [int]$executed.raw_count
        $seq = $spec.Contains('then_invoke') -and -not [string]::IsNullOrWhiteSpace([string]$spec.then_invoke)
        $writer = 'catch-or-recovery-writer'
        if ($executed.Contains('writer') -and -not [string]::IsNullOrWhiteSpace([string]$executed.writer)) { $writer = [string]$executed.writer }
        $boundary = ''
        if ($executed.Contains('boundary')) { $boundary = [string]$executed.boundary }
        $callSite = ''
        if ($executed.Contains('call_site')) { $callSite = [string]$executed.call_site }
        $callKeys = [Collections.Generic.List[string]]::new()
        foreach ($tuple in $executed.tuples) {
            $rowWriter = $writer
            $rowBoundary = $boundary
            $rowCallSite = $callSite
            if ($seq) {
                $kind = Get-CodexAppServerDictString -Dict $tuple -Key 'kind'
                if ($kind -ceq 'recovery') {
                    $rowWriter = 'recovery-required-run'
                    $rowBoundary = 'recovery-required-run'
                    $rowCallSite = 'Write-CodexAppServerRecoveryRequired'
                } else {
                    $rowWriter = 'failure-snapshot'
                    $rowBoundary = 'failure-snapshot'
                    $rowCallSite = 'Write-CodexAppServerFailureRecord'
                }
            }
            $script:f02SubmittedCount += 1
            $callKeys.Add((Get-CasIntHistoryKey -Row $tuple))
            Add-CasIntObservedTuple -Tuple $tuple -Scenario ([string]$spec.name) -Writer $rowWriter -Boundary $rowBoundary -CallSite $rowCallSite -ObservedKeys $observedKeys -ObservedRows $observedRows
        }
        $script:f02PerCallRaw.Add([ordered]@{
            scenario = [string]$spec.name
            writer = [string]$writer
            boundary = [string]$boundary
            call_site = [string]$callSite
            raw_count = [int]$executed.raw_count
            submitted = [int]$callKeys.Count
            keys = @($callKeys)
        })
    }

    if (-not $F02WriterOracleOnly) {
    $hR5a = New-CasIntHarness -Name 'f02-r5-prebind'
    $null = Invoke-CasIntProfile -Harness $hR5a
    $bR5a = Invoke-CasIntBuilder -Harness $hR5a
    $tidR5a = [string]$bR5a.json.thread_id
    $ridR5a = 'run-r5-prebind-recovery'
    $pathsR5a = Write-CasIntHistoryWorld -Harness $hR5a -ThreadId $tidR5a -RunId $ridR5a -CurrentPhase 'turn_start_sending' -CurrentDisposition 'recovery_required' -TurnState 'prebind' -PlantRecovery:$true -RecoveryPhase 'turn_start_sending'
    Invoke-CasIntDurableChain -Paths $pathsR5a -Harness $hR5a -RunId $ridR5a -ThreadId $tidR5a
    $turnsBeforeR5a = @(Get-CasIntStoreTurns -Harness $hR5a -ThreadId $tidR5a).Count
    $firstR5a = Invoke-CasIntLauncher -Harness $hR5a -ThreadId $tidR5a -RunId $ridR5a
    Assert-CasInt ($firstR5a.exit_code -ne 0) 'R5 prebind recovery launcher accepted a second turn window.'
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hR5a -RunId $ridR5a) 'R5 prebind recovery worker stayed alive.'
    Stop-CasIntRun -Harness $hR5a -RunId $ridR5a
    $runR5a = Get-CasIntRunJson -Harness $hR5a -RunId $ridR5a
    Assert-CasInt ([string]$runR5a.disposition -ceq 'recovery_required') 'R5 prebind worker_failed rolled recovery_required back.'
    Assert-CasInt ([string]$runR5a.callback_write_phase -ceq 'turn_start_sending') 'R5 prebind changed callback_write_phase.'
    Assert-CasInt ([string]$runR5a.fallback_required -ceq '') 'R5 prebind enabled CLI fallback.'
    Assert-CasInt ([IO.File]::Exists($pathsR5a.recovery)) 'R5 prebind cleared recovery.json.'
    $failR5a = Read-CodexAppServerValidated -Path $pathsR5a.failure -SchemaName 'codex-app-server-lead-failure'
    Assert-CasInt ((Get-CodexAppServerDictString -Dict $failR5a -Key 'code') -ceq 'worker_failed') 'R5 prebind did not snapshot worker_failed.'
    Assert-CasInt ((Get-CodexAppServerDictString -Dict $failR5a -Key 'disposition') -ceq 'recovery_required') 'R5 prebind failure snapshot lost recovery_required.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hR5a -ThreadId $tidR5a).Count -eq $turnsBeforeR5a) 'R5 prebind started another turn on the first reload.'
    Invoke-CasIntDurableChain -Paths $pathsR5a -Harness $hR5a -RunId $ridR5a -ThreadId $tidR5a
    $secondR5a = Invoke-CasIntLauncher -Harness $hR5a -ThreadId $tidR5a -RunId $ridR5a
    Assert-CasInt ($secondR5a.exit_code -ne 0) 'R5 prebind second launch started another turn window.'
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hR5a -RunId $ridR5a) 'R5 prebind second worker stayed alive.'
    Stop-CasIntRun -Harness $hR5a -RunId $ridR5a
    $runR5a2 = Get-CasIntRunJson -Harness $hR5a -RunId $ridR5a
    Assert-CasInt ([string]$runR5a2.disposition -ceq 'recovery_required') 'R5 prebind second launch lost recovery_required.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hR5a -ThreadId $tidR5a).Count -eq $turnsBeforeR5a) 'R5 prebind second launch started another turn.'
    Invoke-CasIntDurableChain -Paths $pathsR5a -Harness $hR5a -RunId $ridR5a -ThreadId $tidR5a
    $script:f02R5PrebindRecoveryPreserved = 1

    $hR5b = New-CasIntHarness -Name 'f02-r5-publishing'
    $null = Invoke-CasIntProfile -Harness $hR5b
    $bR5b = Invoke-CasIntBuilder -Harness $hR5b
    $tidR5b = [string]$bR5b.json.thread_id
    $ridR5b = 'run-r5-terminal-publishing'
    $eventLogR5b = Join-Path $hR5b.root 'events.log'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLogR5b
    $env:TELEPHONE_TEST_APP_SERVER_LEAD_THROW_AT = 'after-terminal-intent'
    $firstR5b = Invoke-CasIntLauncher -Harness $hR5b -ThreadId $tidR5b -RunId $ridR5b
    Assert-CasInt ($firstR5b.exit_code -eq 0) ("R5 publishing first launch failed before ack: $($firstR5b.stderr) $($firstR5b.stdout)")
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hR5b -RunId $ridR5b) 'R5 publishing worker stayed alive after the ordinary exception.'
    Stop-CasIntRun -Harness $hR5b -RunId $ridR5b
    Clear-CasIntTestEnv
    $pathsR5b = Get-CodexAppServerRunPaths -StateRoot ([string]$hR5b.state) -RunId $ridR5b
    $runR5b = Get-CasIntRunJson -Harness $hR5b -RunId $ridR5b
    Assert-CasInt ([string]$runR5b.callback_write_phase -ceq 'terminal_publishing') 'R5 publishing lost terminal_publishing authority.'
    Assert-CasInt ([string]$runR5b.terminal_target -ceq 'completed') 'R5 publishing cleared terminal_target.'
    Assert-CasInt ([string]$runR5b.disposition -ceq 'in_progress' -or [string]$runR5b.disposition -ceq 'recovered') 'R5 publishing did not keep an allowed publication disposition.'
    Assert-CasInt (-not [IO.File]::Exists($pathsR5b.recovery)) 'R5 publishing wrote unmatched recovery.json.'
    $ackR5b = Read-CodexAppServerValidated -Path $pathsR5b.ack -SchemaName 'codex-app-server-lead-ack'
    $turnR5b = Get-CodexAppServerDictString -Dict $ackR5b -Key 'turn_id'
    Assert-CasInt (-not [string]::IsNullOrWhiteSpace($turnR5b)) 'R5 publishing never bound a turn.'
    Assert-CasInt ([string]$runR5b.selected_turn_id -ceq $turnR5b) 'R5 publishing selected a different turn.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hR5b -ThreadId $tidR5b).Count -eq 1) 'R5 publishing did not keep one turn after the exception.'
    Assert-CasInt ((Get-CasIntEventCount -Path $eventLogR5b -Name 'turn/start') -eq 1) 'R5 publishing sent another turn/start after the exception.'
    Invoke-CasIntDurableChain -Paths $pathsR5b -Harness $hR5b -RunId $ridR5b -ThreadId $tidR5b
    $storePathR5b = Join-Path $hR5b.state 'app-server-store.json'
    $storeBeforeR5b = ''
    if ([IO.File]::Exists($storePathR5b)) { $storeBeforeR5b = [IO.File]::ReadAllText($storePathR5b) }
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLogR5b
    $secondR5b = Invoke-CasIntLauncher -Harness $hR5b -ThreadId $tidR5b -RunId $ridR5b
    Assert-CasInt ($secondR5b.exit_code -eq 0) ("R5 publishing second launch did not complete from disk: $($secondR5b.stderr) $($secondR5b.stdout)")
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hR5b -RunId $ridR5b) 'R5 publishing completion worker stayed alive.'
    Stop-CasIntRun -Harness $hR5b -RunId $ridR5b
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
    $runR5b2 = Get-CasIntRunJson -Harness $hR5b -RunId $ridR5b
    Assert-CasInt ([string]$runR5b2.thread_id -ceq $tidR5b) 'R5 publishing completion changed thread id.'
    Assert-CasInt ([string]$runR5b2.selected_turn_id -ceq $turnR5b) 'R5 publishing completion changed turn id.'
    Assert-CasInt ([string]$runR5b2.callback_write_phase -ceq 'terminal') 'R5 publishing completion did not reach terminal.'
    Assert-CasInt ([string]$runR5b2.disposition -ceq 'completed') 'R5 publishing completion did not converge to the official terminal.'
    Assert-CasInt ([string]$runR5b2.terminal_target -ceq 'completed') 'R5 publishing completion lost terminal_target.'
    Assert-CasInt ([string](Get-CasIntFinalText -Harness $hR5b -RunId $ridR5b) -ceq 'completed') 'R5 publishing completion omitted launcher-final.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hR5b -ThreadId $tidR5b).Count -eq 1) 'R5 publishing completion started another turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $eventLogR5b -Name 'turn/start') -eq 1) 'R5 publishing completion sent another turn/start.'
    if ($storeBeforeR5b -ne '') {
        Assert-CasInt ([IO.File]::ReadAllText($storePathR5b) -ceq $storeBeforeR5b) 'R5 publishing completion mutated the mock provider store.'
    }
    Assert-CasInt (-not [IO.File]::Exists($pathsR5b.recovery)) 'R5 publishing completion created unmatched recovery.json.'
    $script:f02R5TerminalPublishingPreserved = 1

    $recoverForwardOracle = @(
        @{ name = 'recover-forward-crash-turn-bound'; crash = 'after-turn-bind'; counter = 'f02R6RecoverForwardTurnBoundCrash'; origin = 'ack-death' },
        @{ name = 'recover-forward-crash-in-progress'; crash = 'after-ack-in-progress'; counter = 'f02R6RecoverForwardInProgressCrash'; origin = 'ack-death' },
        @{ name = 'recover-forward-crash-publishing'; crash = 'after-terminal-intent'; counter = 'f02R6RecoverForwardPublishingCrash'; origin = 'ack-death' },
        @{ name = 'recover-forward-crash-terminal-run'; crash = 'after-terminal-run'; counter = ''; origin = 'ack-death' },
        @{ name = 'recover-forward-turn-bound-origin-in-progress'; crash = 'after-ack-in-progress'; counter = ''; origin = 'pre-ack' },
        @{ name = 'recover-forward-turn-bound-origin-publishing'; crash = 'after-terminal-intent'; counter = ''; origin = 'pre-ack' },
        @{ name = 'recover-forward-turn-bound-origin-terminal'; crash = 'after-terminal-run'; counter = ''; origin = 'pre-ack' }
    )
    foreach ($spec in $recoverForwardOracle) {
        if ([string]$spec.origin -ceq 'pre-ack') {
            $world = New-CasIntPreAckRecoveryWorld -Name ([string]$spec.name) -RunId ('run-' + [string]$spec.name)
        } else {
            $world = New-CasIntAckDeathWorld -Name ([string]$spec.name) -RunId ('run-' + [string]$spec.name)
            Stop-CasIntThreadOwner -Harness $world.harness -ThreadId $world.thread_id
            Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $world.harness -ThreadId $world.thread_id -TimeoutMs 10000) ("Recovery-forward $($spec.name) kept the pre-injection thread owner alive.")
            $script:f02RecoveryForwardOwnerRebound = 1
        }
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$world.event_log
        $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = [string]$spec.crash
        $ownerBoundBefore = Get-CasIntTransitionStateCount -Path ([string]$world.paths.transitions) -State 'owner_bound'
        $ownerIdentityBefore = Get-CasIntRunOwnerIdentityKey -Harness $world.harness -RunId $world.run_id
        $null = Invoke-CasIntLauncher -Harness $world.harness -ThreadId $world.thread_id -RunId $world.run_id
        $expectedPhase = Get-CasIntRecoverForwardExpectedPhase -Crash ([string]$spec.crash)
        $crashed = Wait-CasIntRecoverForwardCrash -World $world -ExpectedPhase $expectedPhase -OwnerBoundBefore $ownerBoundBefore -OwnerIdentityBefore $ownerIdentityBefore
        Assert-CasInt ([bool]$crashed.success) ("Recovery-forward $($spec.name) did not converge: phase=$([string]$crashed.phase) expected=$expectedPhase owner_bound=$([int]$crashed.owner_bound) baseline=$ownerBoundBefore owner_changed=$([bool]$crashed.owner_changed) owner_alive=$([bool]$crashed.owner_alive).")
        Stop-CasIntRun -Harness $world.harness -RunId $world.run_id
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT -ErrorAction SilentlyContinue
        $runCrash = Get-CasIntRunJson -Harness $world.harness -RunId $world.run_id
        Assert-CasInt ([string]$runCrash.callback_write_phase -ceq $expectedPhase) ("Recovery-forward $($spec.name) phase=$([string]$runCrash.callback_write_phase), expected=$expectedPhase.")
        Assert-CasInt (-not [IO.File]::Exists($world.paths.recovery)) ("Recovery-forward $($spec.name) leaked recovery.json past recovery-commit.")
        Assert-CasInt (-not [IO.File]::Exists($world.paths.failure)) ("Recovery-forward $($spec.name) leaked failure.json past recovery-commit.")
        $storeBefore = ''
        $storePath = Join-Path $world.harness.state 'app-server-store.json'
        $assertStore = ([string]$spec.crash -ceq 'after-terminal-intent' -or [string]$spec.crash -ceq 'after-terminal-run')
        if ($assertStore -and [IO.File]::Exists($storePath)) { $storeBefore = [IO.File]::ReadAllText($storePath) }
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$world.event_log
        $continued = Invoke-CasIntLauncher -Harness $world.harness -ThreadId $world.thread_id -RunId $world.run_id
        Assert-CasInt ($continued.exit_code -eq 0) ("Recovery-forward $($spec.name) did not continue: $($continued.stderr) $($continued.stdout)")
        $settled = Wait-CasIntOfficialTerminalAndQuiet -Harness $world.harness -RunId $world.run_id -ThreadId $world.thread_id -TurnId $world.turn_id
        Assert-CasInt ([bool]$settled.success) ("Recovery-forward $($spec.name) continuation did not settle: terminal=$([bool]$settled.terminal) run_quiet=$([bool]$settled.run_quiet) thread_quiet=$([bool]$settled.thread_quiet) phase=$([string]$settled.phase) state=$([string]$settled.state).")
        Stop-CasIntRun -Harness $world.harness -RunId $world.run_id
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
        $runNow = Get-CasIntRunJson -Harness $world.harness -RunId $world.run_id
        Assert-CasInt ([string]$runNow.thread_id -ceq $world.thread_id) ("Recovery-forward $($spec.name) changed thread id.")
        Assert-CasInt ([string]$runNow.selected_turn_id -ceq $world.turn_id) ("Recovery-forward $($spec.name) changed turn id.")
        Assert-CasInt ([string]$runNow.callback_write_phase -ceq 'terminal') ("Recovery-forward $($spec.name) did not reach terminal.")
        Assert-CasInt ([string]$runNow.disposition -ceq 'completed') ("Recovery-forward $($spec.name) did not reach completed.")
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $world.harness -ThreadId $world.thread_id).Count -eq 1) ("Recovery-forward $($spec.name) started another turn.")
        Assert-CasInt ((Get-CasIntEventCount -Path $world.event_log -Name 'turn/start') -eq 1) ("Recovery-forward $($spec.name) sent another turn/start.")
        Assert-CasInt ([string]$runNow.fallback_required -ceq '') ("Recovery-forward $($spec.name) enabled CLI fallback.")
        if ($assertStore -and $storeBefore -ne '') {
            Assert-CasInt ([IO.File]::ReadAllText($storePath) -ceq $storeBefore) ("Recovery-forward $($spec.name) mutated the mock provider store.")
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$spec.counter)) {
            Set-Variable -Name $spec.counter -Scope Script -Value 1
        }
    }

    $repeatWorld = New-CasIntAckDeathWorld -Name 'recover-forward-repeat-terminal' -RunId 'run-recover-forward-repeat'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$repeatWorld.event_log
    $recovered = Invoke-CasIntLauncher -Harness $repeatWorld.harness -ThreadId $repeatWorld.thread_id -RunId $repeatWorld.run_id
    Assert-CasInt ($recovered.exit_code -eq 0) ("Recovery-forward complete launch failed: $($recovered.stderr) $($recovered.stdout)")
    $repeatSettled = Wait-CasIntOfficialTerminalAndQuiet -Harness $repeatWorld.harness -RunId $repeatWorld.run_id -ThreadId $repeatWorld.thread_id -TurnId $repeatWorld.turn_id
    Assert-CasInt ([bool]$repeatSettled.success) ("Recovery-forward complete did not settle: terminal=$([bool]$repeatSettled.terminal) run_quiet=$([bool]$repeatSettled.run_quiet) thread_quiet=$([bool]$repeatSettled.thread_quiet) phase=$([string]$repeatSettled.phase) state=$([string]$repeatSettled.state).")
    Stop-CasIntRun -Harness $repeatWorld.harness -RunId $repeatWorld.run_id
    $runRepeat = Get-CasIntRunJson -Harness $repeatWorld.harness -RunId $repeatWorld.run_id
    Assert-CasInt ([string]$runRepeat.disposition -ceq 'completed') 'Recovery-forward complete did not reach official terminal.'
    Assert-CasInt ([string]$runRepeat.selected_turn_id -ceq $repeatWorld.turn_id) 'Recovery-forward complete changed turn id.'
    Assert-CasInt (-not [IO.File]::Exists($repeatWorld.paths.recovery)) 'Official recovered terminal did not retire recovery.json.'
    Assert-CasInt (-not [IO.File]::Exists($repeatWorld.paths.failure)) 'Official recovered terminal did not retire failure.json.'
    $storeRepeat = Join-Path $repeatWorld.harness.state 'app-server-store.json'
    $storeRepeatBefore = ''
    if ([IO.File]::Exists($storeRepeat)) { $storeRepeatBefore = [IO.File]::ReadAllText($storeRepeat) }
    $third = Invoke-CasIntLauncher -Harness $repeatWorld.harness -ThreadId $repeatWorld.thread_id -RunId $repeatWorld.run_id
    Assert-CasInt ($third.exit_code -eq 0) ("Repeat launcher after recovered terminal failed: $($third.stderr) $($third.stdout)")
    Assert-CasInt ($third.json.state -ceq 'completed') 'Repeat launcher did not return the official terminal.'
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $repeatWorld.harness -RunId $repeatWorld.run_id) 'Repeat launcher left a live worker.'
    Stop-CasIntRun -Harness $repeatWorld.harness -RunId $repeatWorld.run_id
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
    $runThird = Get-CasIntRunJson -Harness $repeatWorld.harness -RunId $repeatWorld.run_id
    Assert-CasInt ([string]$runThird.thread_id -ceq $repeatWorld.thread_id) 'Repeat launcher changed thread id.'
    Assert-CasInt ([string]$runThird.selected_turn_id -ceq $repeatWorld.turn_id) 'Repeat launcher changed turn id.'
    Assert-CasInt ([string]$runThird.disposition -ceq 'completed') 'Repeat launcher lost official terminal.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $repeatWorld.harness -ThreadId $repeatWorld.thread_id).Count -eq 1) 'Repeat launcher started another turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $repeatWorld.event_log -Name 'turn/start') -eq 1) 'Repeat launcher sent another turn/start.'
    Assert-CasInt ([string]$runThird.fallback_required -ceq '') 'Repeat launcher enabled CLI fallback.'
    if ($storeRepeatBefore -ne '') {
        Assert-CasInt ([IO.File]::ReadAllText($storeRepeat) -ceq $storeRepeatBefore) 'Repeat launcher mutated the mock provider store.'
    }
    $script:f02R6RecoverForwardRepeatTerminal = 1

    $hMarker = New-CasIntHarness -Name 'f02-r7-marker-prebind'
    $null = Invoke-CasIntProfile -Harness $hMarker
    $bMarker = Invoke-CasIntBuilder -Harness $hMarker
    $tidMarker = [string]$bMarker.json.thread_id
    $ridMarker = 'run-r7-marker-prebind'
    $eventLogMarker = Join-Path $hMarker.root 'events.log'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLogMarker
    $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = 'after-ambiguous-write'
    $firstMarker = Invoke-CasIntLauncher -Harness $hMarker -ThreadId $tidMarker -RunId $ridMarker
    Assert-CasInt ($firstMarker.exit_code -ne 0) 'Marker-prebind first launch did not fail closed after turn/start.'
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hMarker -RunId $ridMarker) 'Marker-prebind first worker stayed alive.'
    Stop-CasIntRun -Harness $hMarker -RunId $ridMarker
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT -ErrorAction SilentlyContinue
    $pathsMarker = Get-CodexAppServerRunPaths -StateRoot ([string]$hMarker.state) -RunId $ridMarker
    $runMarker = Get-CasIntRunJson -Harness $hMarker -RunId $ridMarker
    Assert-CasInt ([string]$runMarker.callback_write_phase -ceq 'turn_start_sending') 'Marker-prebind lost turn_start_sending.'
    Assert-CasInt ([string]$runMarker.selected_turn_id -ceq '') 'Marker-prebind persisted a selected turn before marker proof.'
    Assert-CasInt ([string]$runMarker.disposition -ceq 'in_progress' -or [string]$runMarker.disposition -ceq 'recovery_required') 'Marker-prebind left a disallowed disposition after fail-fast.'
    Assert-CasInt ([string]$runMarker.fallback_required -ceq '') 'Marker-prebind enabled CLI fallback.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hMarker -ThreadId $tidMarker).Count -eq 1) 'Marker-prebind did not keep the original marker turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $eventLogMarker -Name 'turn/start') -eq 1) 'Marker-prebind sent more than one turn/start before recovery.'
    $storeTurnsMarker = @(Get-CasIntStoreTurns -Harness $hMarker -ThreadId $tidMarker)
    $originalTurnMarker = ''
    if ($storeTurnsMarker.Count -gt 0) {
        $originalTurnMarker = Get-CodexAppServerDictString -Dict $storeTurnsMarker[0] -Key 'id'
    }
    Assert-CasInt (-not [string]::IsNullOrWhiteSpace($originalTurnMarker)) 'Marker-prebind store omitted the original turn id.'
    Invoke-CasIntDurableChain -Paths $pathsMarker -Harness $hMarker -RunId $ridMarker -ThreadId $tidMarker
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLogMarker
    $secondMarker = Invoke-CasIntLauncher -Harness $hMarker -ThreadId $tidMarker -RunId $ridMarker
    Assert-CasInt ($secondMarker.exit_code -eq 0) ("Marker-prebind recovery did not complete: $($secondMarker.stderr) $($secondMarker.stdout)")
    $markerSettled = Wait-CasIntOfficialTerminalAndQuiet -Harness $hMarker -RunId $ridMarker -ThreadId $tidMarker -TurnId $originalTurnMarker
    Assert-CasInt ([bool]$markerSettled.success) ("Marker-prebind recovery did not settle: terminal=$([bool]$markerSettled.terminal) run_quiet=$([bool]$markerSettled.run_quiet) thread_quiet=$([bool]$markerSettled.thread_quiet) phase=$([string]$markerSettled.phase) state=$([string]$markerSettled.state).")
    Stop-CasIntRun -Harness $hMarker -RunId $ridMarker
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
    $runMarker2 = Get-CasIntRunJson -Harness $hMarker -RunId $ridMarker
    Assert-CasInt ([string]$runMarker2.thread_id -ceq $tidMarker) 'Marker-prebind recovery changed thread id.'
    Assert-CasInt ([string]$runMarker2.selected_turn_id -ceq $originalTurnMarker) 'Marker-prebind recovery bound a different turn.'
    Assert-CasInt ([string]$runMarker2.disposition -ceq 'completed') 'Marker-prebind recovery did not reach completed.'
    Assert-CasInt ([string]$runMarker2.callback_write_phase -ceq 'terminal') 'Marker-prebind recovery did not reach terminal.'
    Assert-CasInt (-not [IO.File]::Exists($pathsMarker.recovery)) 'Marker-prebind leaked recovery.json into terminal.'
    Assert-CasInt (-not [IO.File]::Exists($pathsMarker.failure)) 'Marker-prebind leaked failure.json into terminal.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hMarker -ThreadId $tidMarker).Count -eq 1) 'Marker-prebind recovery started another turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $eventLogMarker -Name 'turn/start') -eq 1) 'Marker-prebind recovery sent another turn/start.'
    Assert-CasInt ([string]$runMarker2.fallback_required -ceq '') 'Marker-prebind recovery enabled CLI fallback.'
    $script:f02R7MarkerPrebindRecovery = 1
    $script:f02R7RecoveryCommitLifecycle = 1

    $succWorld = New-CasIntAckDeathWorld -Name 'f02-r7-successive' -RunId 'run-r7-successive'
    Stop-CasIntThreadOwner -Harness $succWorld.harness -ThreadId $succWorld.thread_id
    Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $succWorld.harness -ThreadId $succWorld.thread_id -TimeoutMs 10000) 'Successive recovery fixture kept the pre-injection thread owner alive.'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$succWorld.event_log
    $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = 'after-recovery-commit-run'
    $ownerBoundBefore = Get-CasIntTransitionStateCount -Path ([string]$succWorld.paths.transitions) -State 'owner_bound'
    $ownerIdentityBefore = Get-CasIntRunOwnerIdentityKey -Harness $succWorld.harness -RunId $succWorld.run_id
    $null = Invoke-CasIntLauncher -Harness $succWorld.harness -ThreadId $succWorld.thread_id -RunId $succWorld.run_id
    $succCrash1 = Wait-CasIntRecoverForwardCrash -World $succWorld -ExpectedPhase 'acknowledged' -OwnerBoundBefore $ownerBoundBefore -OwnerIdentityBefore $ownerIdentityBefore
    Assert-CasInt ([bool]$succCrash1.success) ("Successive recovery first crash did not converge: phase=$([string]$succCrash1.phase) owner_bound=$([int]$succCrash1.owner_bound) baseline=$ownerBoundBefore owner_changed=$([bool]$succCrash1.owner_changed) owner_alive=$([bool]$succCrash1.owner_alive).")
    Stop-CasIntRun -Harness $succWorld.harness -RunId $succWorld.run_id
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT -ErrorAction SilentlyContinue
    $runSucc1 = Get-CasIntRunJson -Harness $succWorld.harness -RunId $succWorld.run_id
    Assert-CasInt ([string]$runSucc1.disposition -ceq 'recovered') 'Successive recovery first crash did not persist recovery-commit.'
    Assert-CasInt ([IO.File]::Exists($succWorld.paths.recovery)) 'Successive recovery first crash retired recovery.json too early.'
    Assert-CasInt (-not [IO.File]::Exists($succWorld.paths.failure)) 'Successive recovery first crash kept failure.json after retirement.'
    Invoke-CasIntDurableChain -Paths $succWorld.paths -Harness $succWorld.harness -RunId $succWorld.run_id -ThreadId $succWorld.thread_id
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$succWorld.event_log
    $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = 'after-turn-bind'
    $ownerBoundBefore = Get-CasIntTransitionStateCount -Path ([string]$succWorld.paths.transitions) -State 'owner_bound'
    $ownerIdentityBefore = Get-CasIntRunOwnerIdentityKey -Harness $succWorld.harness -RunId $succWorld.run_id
    $null = Invoke-CasIntLauncher -Harness $succWorld.harness -ThreadId $succWorld.thread_id -RunId $succWorld.run_id
    $succCrash2 = Wait-CasIntRecoverForwardCrash -World $succWorld -ExpectedPhase 'turn_bound' -OwnerBoundBefore $ownerBoundBefore -OwnerIdentityBefore $ownerIdentityBefore
    Assert-CasInt ([bool]$succCrash2.success) ("Successive recovery second crash did not converge: phase=$([string]$succCrash2.phase) owner_bound=$([int]$succCrash2.owner_bound) baseline=$ownerBoundBefore owner_changed=$([bool]$succCrash2.owner_changed) owner_alive=$([bool]$succCrash2.owner_alive).")
    Stop-CasIntRun -Harness $succWorld.harness -RunId $succWorld.run_id
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT -ErrorAction SilentlyContinue
    $runSucc2 = Get-CasIntRunJson -Harness $succWorld.harness -RunId $succWorld.run_id
    Assert-CasInt ([string]$runSucc2.callback_write_phase -ceq 'turn_bound') 'Successive recovery second crash did not stop at turn_bound.'
    Assert-CasInt (-not [IO.File]::Exists($succWorld.paths.recovery)) 'Successive recovery second crash leaked recovery.json past Bind.'
    Assert-CasInt (-not [IO.File]::Exists($succWorld.paths.failure)) 'Successive recovery second crash leaked failure.json past Bind.'
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$succWorld.event_log
    $thirdSucc = Invoke-CasIntLauncher -Harness $succWorld.harness -ThreadId $succWorld.thread_id -RunId $succWorld.run_id
    Assert-CasInt ($thirdSucc.exit_code -eq 0) ("Successive recovery third launch failed: $($thirdSucc.stderr) $($thirdSucc.stdout)")
    $succSettled = Wait-CasIntOfficialTerminalAndQuiet -Harness $succWorld.harness -RunId $succWorld.run_id -ThreadId $succWorld.thread_id -TurnId $succWorld.turn_id
    Assert-CasInt ([bool]$succSettled.success) ("Successive recovery third launch did not settle: terminal=$([bool]$succSettled.terminal) run_quiet=$([bool]$succSettled.run_quiet) thread_quiet=$([bool]$succSettled.thread_quiet) phase=$([string]$succSettled.phase) state=$([string]$succSettled.state).")
    Stop-CasIntRun -Harness $succWorld.harness -RunId $succWorld.run_id
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
    $runSucc3 = Get-CasIntRunJson -Harness $succWorld.harness -RunId $succWorld.run_id
    Assert-CasInt ([string]$runSucc3.thread_id -ceq $succWorld.thread_id) 'Successive recovery changed thread id.'
    Assert-CasInt ([string]$runSucc3.selected_turn_id -ceq $succWorld.turn_id) 'Successive recovery changed turn id.'
    Assert-CasInt ([string]$runSucc3.disposition -ceq 'completed') 'Successive recovery third launch did not complete.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $succWorld.harness -ThreadId $succWorld.thread_id).Count -eq 1) 'Successive recovery started another turn.'
    Assert-CasInt ((Get-CasIntEventCount -Path $succWorld.event_log -Name 'turn/start') -eq 1) 'Successive recovery sent another turn/start.'
    Assert-CasInt ([string]$runSucc3.fallback_required -ceq '') 'Successive recovery enabled CLI fallback.'
    $script:f02R7SuccessiveRecoveryCrashes = 1

    foreach ($termSpec in @(
        @{ name = 'failed'; counter = 'f02R7RecoveredFailed' },
        @{ name = 'interrupted'; counter = 'f02R7RecoveredInterrupted' }
    )) {
        $termWorld = New-CasIntAckDeathWorld -Name ('f02-r7-term-' + [string]$termSpec.name) -RunId ('run-r7-term-' + [string]$termSpec.name)
        Stop-CasIntThreadOwner -Harness $termWorld.harness -ThreadId $termWorld.thread_id
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $termWorld.harness -ThreadId $termWorld.thread_id -TimeoutMs 10000) ("Recovered $($termSpec.name) fixture kept the pre-injection thread owner alive.")
        Set-CasIntStoreTurnStatus -Harness $termWorld.harness -ThreadId $termWorld.thread_id -TurnId $termWorld.turn_id -Status ([string]$termSpec.name)
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$termWorld.event_log
        $env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS = [string]$termSpec.name
        $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = 'after-terminal-intent'
        $ownerBoundBefore = Get-CasIntTransitionStateCount -Path ([string]$termWorld.paths.transitions) -State 'owner_bound'
        $ownerIdentityBefore = Get-CasIntRunOwnerIdentityKey -Harness $termWorld.harness -RunId $termWorld.run_id
        $null = Invoke-CasIntLauncher -Harness $termWorld.harness -ThreadId $termWorld.thread_id -RunId $termWorld.run_id
        $termCrash = Wait-CasIntRecoverForwardCrash -World $termWorld -ExpectedPhase 'terminal_publishing' -OwnerBoundBefore $ownerBoundBefore -OwnerIdentityBefore $ownerIdentityBefore
        Assert-CasInt ([bool]$termCrash.success) ("Recovered $($termSpec.name) publication crash did not converge: phase=$([string]$termCrash.phase) owner_bound=$([int]$termCrash.owner_bound) baseline=$ownerBoundBefore owner_changed=$([bool]$termCrash.owner_changed) owner_alive=$([bool]$termCrash.owner_alive).")
        Stop-CasIntRun -Harness $termWorld.harness -RunId $termWorld.run_id
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT -ErrorAction SilentlyContinue
        Assert-CasInt (-not [IO.File]::Exists($termWorld.paths.recovery)) ("Recovered $($termSpec.name) leaked recovery.json into publication.")
        Assert-CasInt (-not [IO.File]::Exists($termWorld.paths.failure)) ("Recovered $($termSpec.name) leaked failure.json into publication.")
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$termWorld.event_log
        $env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS = [string]$termSpec.name
        $termDone = Invoke-CasIntLauncher -Harness $termWorld.harness -ThreadId $termWorld.thread_id -RunId $termWorld.run_id
        Assert-CasInt ($termDone.exit_code -eq 0) ("Recovered $($termSpec.name) did not finish: $($termDone.stderr) $($termDone.stdout)")
        $termSettled = Wait-CasIntOfficialTerminalAndQuiet -Harness $termWorld.harness -RunId $termWorld.run_id -ThreadId $termWorld.thread_id -TurnId $termWorld.turn_id -Disposition ([string]$termSpec.name)
        Assert-CasInt ([bool]$termSettled.success) ("Recovered $($termSpec.name) did not settle: terminal=$([bool]$termSettled.terminal) run_quiet=$([bool]$termSettled.run_quiet) thread_quiet=$([bool]$termSettled.thread_quiet) phase=$([string]$termSettled.phase) state=$([string]$termSettled.state).")
        Stop-CasIntRun -Harness $termWorld.harness -RunId $termWorld.run_id
        $runTermR7 = Get-CasIntRunJson -Harness $termWorld.harness -RunId $termWorld.run_id
        Assert-CasInt ([string]$runTermR7.thread_id -ceq $termWorld.thread_id) ("Recovered $($termSpec.name) changed thread id.")
        Assert-CasInt ([string]$runTermR7.selected_turn_id -ceq $termWorld.turn_id) ("Recovered $($termSpec.name) changed turn id.")
        Assert-CasInt ([string]$runTermR7.disposition -ceq [string]$termSpec.name) ("Recovered $($termSpec.name) did not reach the official terminal.")
        Assert-CasInt ([string]$runTermR7.callback_write_phase -ceq 'terminal') ("Recovered $($termSpec.name) did not reach terminal phase.")
        Assert-CasInt ([string](Get-CasIntFinalText -Harness $termWorld.harness -RunId $termWorld.run_id) -ceq [string]$termSpec.name) ("Recovered $($termSpec.name) omitted launcher-final.")
        Assert-CasInt (-not [IO.File]::Exists($termWorld.paths.recovery)) ("Recovered $($termSpec.name) terminal leaked recovery.json.")
        Assert-CasInt (-not [IO.File]::Exists($termWorld.paths.failure)) ("Recovered $($termSpec.name) terminal leaked failure.json.")
        $storeTerm = Join-Path $termWorld.harness.state 'app-server-store.json'
        $storeTermBefore = ''
        if ([IO.File]::Exists($storeTerm)) { $storeTermBefore = [IO.File]::ReadAllText($storeTerm) }
        $repeatTerm = Invoke-CasIntLauncher -Harness $termWorld.harness -ThreadId $termWorld.thread_id -RunId $termWorld.run_id
        Assert-CasInt ($repeatTerm.exit_code -eq 0) ("Repeat recovered $($termSpec.name) launcher failed: $($repeatTerm.stderr) $($repeatTerm.stdout)")
        Assert-CasInt ($repeatTerm.json.state -ceq [string]$termSpec.name) ("Repeat recovered $($termSpec.name) did not return the official terminal.")
        Assert-CasInt (Wait-CasIntRunQuiet -Harness $termWorld.harness -RunId $termWorld.run_id) ("Repeat recovered $($termSpec.name) left a live worker.")
        Stop-CasIntRun -Harness $termWorld.harness -RunId $termWorld.run_id
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS -ErrorAction SilentlyContinue
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $termWorld.harness -ThreadId $termWorld.thread_id).Count -eq 1) ("Repeat recovered $($termSpec.name) started another turn.")
        Assert-CasInt ((Get-CasIntEventCount -Path $termWorld.event_log -Name 'turn/start') -eq 1) ("Repeat recovered $($termSpec.name) sent another turn/start.")
        if ($storeTermBefore -ne '') {
            Assert-CasInt ([IO.File]::ReadAllText($storeTerm) -ceq $storeTermBefore) ("Repeat recovered $($termSpec.name) mutated the mock provider store.")
        }
        Set-Variable -Name $termSpec.counter -Scope Script -Value 1
    }
    }

    $tableKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $script:f02ProductionDuplicateCount = 0
    foreach ($row in @($script:CodexAppServerDurableHistoryRows)) {
        $key = Get-CasIntHistoryKey -Row $row
        if ($tableKeys.Contains($key)) { $script:f02ProductionDuplicateCount += 1 }
        Assert-CasInt (-not $tableKeys.Contains($key)) 'Production durable-history table contains duplicate rows.'
        [void]$tableKeys.Add($key)
    }
    $missing = [Collections.Generic.List[string]]::new()
    $extra = [Collections.Generic.List[string]]::new()
    foreach ($key in @($observedKeys)) {
        if (-not $tableKeys.Contains($key)) { $missing.Add($key) }
    }
    foreach ($key in @($tableKeys)) {
        if (-not $observedKeys.Contains($key)) { $extra.Add($key) }
    }
    $independentRows = @(Get-CasIntIndependentExpectedHistoryRows)
    $independentKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $independentRows) {
        $key = Get-CasIntHistoryKey -Row $row
        Assert-CasInt (-not $independentKeys.Contains($key)) 'Independent expected relation contains duplicate rows.'
        [void]$independentKeys.Add($key)
    }
    $script:f02IndependentExpectedCount = [int]$independentKeys.Count
    $missingIndependent = [Collections.Generic.List[string]]::new()
    $extraIndependent = [Collections.Generic.List[string]]::new()
    foreach ($key in @($observedKeys)) {
        if (-not $independentKeys.Contains($key)) { $missingIndependent.Add($key) }
    }
    foreach ($key in @($independentKeys)) {
        if (-not $observedKeys.Contains($key)) { $extraIndependent.Add($key) }
    }
    $script:f02WriterObservedCount = [int]$observedKeys.Count
    $script:f02WriterUniqueCount = [int]$observedKeys.Count
    $script:f02TableCount = [int]$tableKeys.Count
    $script:f02ExpectedCount = [int]$independentKeys.Count
    $script:f02MissingRows = [int]$missing.Count
    $script:f02ExtraRows = [int]$extra.Count
    $script:f02WriterObservedRows = @($observedRows)
    $script:f02TableRows = @($script:CodexAppServerDurableHistoryRows)
    Assert-CasInt ($script:f02MissingRows -eq 0) ('Writer-observed tuples missing from production: ' + [string]::Join('; ', @($missing)))
    Assert-CasInt ($script:f02ExtraRows -eq 0) ('Production tuples not produced by independent writer scenarios: ' + [string]::Join('; ', @($extra)))
    Assert-CasInt ($missingIndependent.Count -eq 0) ('Writer-observed tuples missing from the independent expected relation: ' + [string]::Join('; ', @($missingIndependent)))
    Assert-CasInt ($extraIndependent.Count -eq 0) ('Independent expected tuples not produced by writer scenarios: ' + [string]::Join('; ', @($extraIndependent)))
    Assert-CasInt ($script:f02DuplicateRows -eq 4) ('Writer scenarios produced ' + [string]$script:f02DuplicateRows + ' scenario duplicates; expected 4 recovery pairs.')
    Assert-CasInt ($script:f02DuplicateProvenance.Count -eq 4) 'Scenario-duplicate provenance does not contain exactly four records.'
    $expectedDupPairs = @(
        @{ suffix = 'sending-prebind'; first = 'origin-sending-prebind-recovery-forward'; second = 'origin-sending-prebind-failure-forward' },
        @{ suffix = 'sending-bound'; first = 'origin-sending-bound-recovery-forward'; second = 'origin-sending-bound-failure-forward' },
        @{ suffix = 'turn-bound'; first = 'origin-turn-bound-recovery-forward'; second = 'origin-turn-bound-failure-forward' },
        @{ suffix = 'acked'; first = 'origin-acked-recovery-forward'; second = 'origin-acked-failure-forward' }
    )
    $seenDupKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($i = 0; $i -lt 4; $i++) {
        $dup = $script:f02DuplicateProvenance[$i]
        $pair = $expectedDupPairs[$i]
        Assert-CasInt ($null -ne $dup.first) ("Duplicate pair $($pair.suffix) omitted first provenance.")
        Assert-CasInt ($null -ne $dup.second) ("Duplicate pair $($pair.suffix) omitted second provenance.")
        Assert-CasInt ([string]$dup.first.kind -ceq 'recovery') ("Duplicate pair $($pair.suffix) first kind is not recovery.")
        Assert-CasInt ([string]$dup.second.kind -ceq 'recovery') ("Duplicate pair $($pair.suffix) second kind is not recovery.")
        Assert-CasInt ([string]$dup.first.key -ceq [string]$dup.second.key) ("Duplicate pair $($pair.suffix) keys do not match.")
        Assert-CasInt ([string]$dup.key -ceq [string]$dup.first.key) ("Duplicate pair $($pair.suffix) record key drifted from first provenance.")
        Assert-CasInt ([string]$dup.first.scenario -ceq [string]$pair.first) ("Duplicate pair $($pair.suffix) first scenario is $([string]$dup.first.scenario).")
        Assert-CasInt ([string]$dup.second.scenario -ceq [string]$pair.second) ("Duplicate pair $($pair.suffix) second scenario is $([string]$dup.second.scenario).")
        Assert-CasInt ([string]$dup.first.call_site -ceq 'Write-CodexAppServerRecoveryRequired') ("Duplicate pair $($pair.suffix) first call-site is not the recovery writer.")
        Assert-CasInt ([string]$dup.second.call_site -ceq 'Write-CodexAppServerRecoveryRequired') ("Duplicate pair $($pair.suffix) second call-site is not the recovery writer.")
        Assert-CasInt ($seenDupKeys.Add([string]$dup.key)) ("Duplicate pair $($pair.suffix) reused another origin recovery key.")
    }
    Assert-CasInt ($script:f02ProductionDuplicateCount -eq 0) 'Production durable-history table contains duplicate rows.'
    Assert-CasInt ($script:f02WriterObservedCount -eq $script:f02TableCount) 'Writer-observed set size does not equal the production relation.'
    Assert-CasInt ($script:f02WriterUniqueCount -eq $script:f02IndependentExpectedCount) 'Writer-observed set size does not equal the independent expected relation.'
    Assert-CasInt ($script:f02IndependentExpectedCount -eq 44) 'Independent expected relation is not the frozen 44-row writer/call-site model.'
    Assert-CasInt ($script:f02LegalRecoveryHistory -eq 12) 'Independent writer scenarios did not observe exactly 12 recovery histories.'
    Assert-CasInt ($script:f02LegalFailureHistory -eq 32) 'Independent writer scenarios did not observe exactly 32 failure histories.'
    Assert-CasInt ($script:f02RawObservationCount -eq 48) 'Raw captured count is not the truthful 48 observations.'
    Assert-CasInt ($script:f02SubmittedCount -eq 48) 'Submitted count is not the truthful 48 observations.'
    Assert-CasInt ($script:f02WriterUniqueCount -eq 44) 'Unique count is not the frozen 44-row relation.'
    Assert-CasInt ($script:f02RawObservationCount -eq $script:f02SubmittedCount) 'Raw captured count diverged from submitted count.'
    Assert-CasInt ($script:f02SubmittedCount -eq ($script:f02WriterUniqueCount + $script:f02DuplicateRows)) 'Submitted count is not unique plus duplicates.'
    $script:f02ClosedAccounting = 1
    $script:f02R7UnfilteredWriterEquality = 1
    $script:f02R8IndependentOracle = 1

    if ($F02WriterOracleOnly) {
        [ordered]@{
            success = $true
            assertions = $assertions
            parse_check = $parseCheck
            f02_raw_observation_count = $f02RawObservationCount
            f02_submitted_count = $f02SubmittedCount
            f02_writer_unique_count = $f02WriterUniqueCount
            f02_duplicate_rows = $f02DuplicateRows
            f02_writer_observed_count = $f02WriterObservedCount
            f02_table_count = $f02TableCount
            f02_expected_count = $f02ExpectedCount
            f02_independent_expected_count = $f02IndependentExpectedCount
            f02_missing_rows = $f02MissingRows
            f02_extra_rows = $f02ExtraRows
            f02_legal_recovery_history = $f02LegalRecoveryHistory
            f02_legal_failure_history = $f02LegalFailureHistory
            f02_closed_accounting = $f02ClosedAccounting
            f02_capture_filter_absent = $f02CaptureFilterAbsent
            f02_owner_local_dedupe_absent = $f02OwnerLocalDedupeAbsent
            f02_same_key_byte_observation = $f02SameKeyByteObservation
            f02_changed_key_recovery_observation = $f02ChangedKeyRecoveryObservation
            f02_duplicate_probe = $f02DuplicateProbe
            f02_production_duplicate_count = $f02ProductionDuplicateCount
            f02_scenario_count = $f02ScenarioCount
            f02_r7_unfiltered_writer_equality = $f02R7UnfilteredWriterEquality
            f02_r8_independent_oracle = $f02R8IndependentOracle
            f02_duplicate_provenance = @($f02DuplicateProvenance)
            f02_duplicate_probe_provenance = @($f02DuplicateProbeProvenance)
            f02_per_call_raw = @($f02PerCallRaw)
            f02_tuple_provenance = @($f02TupleProvenance)
            denominator_eight = $denominatorEight
            oracle_only = $true
        } | ConvertTo-Json -Depth 16 -Compress
        return
    }

    $illegalRecovery = @(
        @{ name = 'rec-future-terminal-vs-ack'; phase = 'acknowledged'; disp = 'recovery_required'; turn = 'acked'; recPhase = 'terminal'; rec = $true },
        @{ name = 'rec-stale-none-vs-bound'; phase = 'turn_bound'; disp = 'recovery_required'; turn = 'bound'; recPhase = 'none'; rec = $true },
        @{ name = 'rec-stale-sending-vs-acked'; phase = 'acknowledged'; disp = 'recovery_required'; turn = 'acked'; recPhase = 'turn_start_sending'; rec = $true },
        @{ name = 'rec-skipped-bound-vs-acked-recovery'; phase = 'acknowledged'; disp = 'recovery_required'; turn = 'acked'; recPhase = 'turn_bound'; rec = $true },
        @{ name = 'rec-acked-vs-failed'; phase = 'acknowledged'; disp = 'failed'; turn = 'acked'; recPhase = 'acknowledged'; rec = $true }
    )
    foreach ($neg in $illegalRecovery) {
        $paths = Write-CasIntHistoryWorld -Harness $hF02Hist -ThreadId $tidF02Hist -RunId ('run-' + [string]$neg.name) -CurrentPhase ([string]$neg.phase) -CurrentDisposition ([string]$neg.disp) -TurnState ([string]$neg.turn) -PlantRecovery:$true -RecoveryPhase ([string]$neg.recPhase)
        $null = Assert-CasIntHistoryRejected -Harness $hF02Hist -ThreadId $tidF02Hist -Paths $paths -Name ([string]$neg.name)
        $script:f02IllegalRecoveryHistory += 1
    }
    $illegalFailure = @(
        @{ name = 'fail-future-publishing-vs-ack'; phase = 'acknowledged'; disp = 'in_progress'; turn = 'acked'; rec = $false; failPhase = 'terminal_publishing'; failDisp = 'in_progress'; failCode = 'transport_lost_before_terminal' },
        @{ name = 'fail-stale-sending-vs-ack'; phase = 'acknowledged'; disp = 'in_progress'; turn = 'acked'; rec = $false; failPhase = 'turn_start_sending'; failDisp = 'in_progress'; failCode = 'transport_lost_before_terminal' },
        @{ name = 'fail-skipped-none-vs-acked'; phase = 'acknowledged'; disp = 'in_progress'; turn = 'acked'; rec = $false; failPhase = 'none'; failDisp = 'in_progress'; failCode = 'transport_lost_before_terminal' },
        @{ name = 'fail-unreachable-recovery-to-in-progress'; phase = 'acknowledged'; disp = 'in_progress'; turn = 'acked'; rec = $false; failPhase = 'acknowledged'; failDisp = 'recovery_required'; failCode = 'transport_lost_before_terminal' },
        @{ name = 'fail-terminal-failed-vs-preterminal'; phase = 'acknowledged'; disp = 'recovery_required'; turn = 'acked'; rec = $true; recPhase = 'acknowledged'; failPhase = 'terminal'; failDisp = 'failed'; failCode = 'worker_failed' }
    )
    foreach ($neg in $illegalFailure) {
        $recPhase = ''
        if ([bool]$neg.rec) { $recPhase = [string]$neg.recPhase }
        $paths = Write-CasIntHistoryWorld `
            -Harness $hF02Hist `
            -ThreadId $tidF02Hist `
            -RunId ('run-' + [string]$neg.name) `
            -CurrentPhase ([string]$neg.phase) `
            -CurrentDisposition ([string]$neg.disp) `
            -TurnState ([string]$neg.turn) `
            -PlantRecovery:([bool]$neg.rec) `
            -RecoveryPhase $recPhase `
            -PlantFailure:$true `
            -FailurePhase ([string]$neg.failPhase) `
            -FailureDisposition ([string]$neg.failDisp) `
            -FailureCode ([string]$neg.failCode)
        $null = Assert-CasIntHistoryRejected -Harness $hF02Hist -ThreadId $tidF02Hist -Paths $paths -Name ([string]$neg.name)
        $script:f02IllegalFailureHistory += 1
    }
    Assert-CasInt ($script:f02IllegalRecoveryHistory -ge 4) 'Illegal recovery history did not cover future, stale, skipped, and wrong-disposition records.'
    Assert-CasInt ($script:f02IllegalFailureHistory -ge 5) 'Illegal failure history did not cover future, stale, skipped, reverse, and terminal-to-preterminal records.'
    $script:f02DurableChain = 1

    $pubRoot = Join-Path $TestRoot 'f03-publish-helper'
    [IO.Directory]::CreateDirectory($pubRoot) | Out-Null
    $oldDoc = [ordered]@{ protocol_version = 'telephone-line-codex-app-server-lead-owner-v1'; pid = 8; start_time_utc_ticks = 1; started_at_utc = '2026-08-21T00:00:00.0000000+00:00' }
    $pubPath = Join-Path $pubRoot 'owner.json'
    $null = Write-CodexAppServerValidatedReplace -Path $pubPath -Value $oldDoc -SchemaName 'codex-app-server-lead-owner'
    $crashScript = Join-Path $pubRoot 'crash.ps1'
    $commonPath = Join-Path $repoRoot 'src\lead-side\codex-app-server\CodexAppServerLead.Common.ps1'
    [IO.File]::WriteAllText($crashScript, @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$env:TELEPHONE_TEST_APP_SERVER_PUBLISH_CRASH_AT = 'before-replace'
. '$($commonPath.Replace('\','\\'))'
Write-CodexAppServerJsonReplace -Path '$($pubPath.Replace('\','\\'))' -Value ([ordered]@{ protocol_version = 'telephone-line-codex-app-server-lead-owner-v1'; pid = 9; start_time_utc_ticks = 2; started_at_utc = '2026-08-21T00:00:01.0000000+00:00' })
"@, [Text.UTF8Encoding]::new($false))
    $crash = Invoke-CasIntScript -ScriptPath $crashScript -Arguments @() -TimeoutMs 15000
    Assert-CasInt ($crash.exit_code -ne 0) 'Demoted publish-helper crash injection did not kill the publisher.'
    Clear-CodexAppServerPublishResidue -Directory $pubRoot
    $recovered = (Read-TelephoneJson -Path $pubPath -SchemaName 'codex-app-server-lead-owner').value
    $pidNow = [int]$recovered.pid
    Assert-CasInt ($pidNow -eq 8 -or $pidNow -eq 9) 'Demoted publish-helper crash left a truncated owner record.'
    $f03CrashPoints = @(
        @{ point = 'before-terminal-intent'; counter = 'f03CrashBeforeTerminalIntent' },
        @{ point = 'after-terminal-intent'; counter = 'f03CrashAfterTerminalIntent' },
        @{ point = 'after-terminal-final'; counter = 'f03CrashAfterTerminalFinal' },
        @{ point = 'after-terminal-bound'; counter = 'f03CrashAfterTerminalBound' },
        @{ point = 'after-terminal-run'; counter = 'f03CrashAfterTerminalRun' },
        @{ point = 'after-terminal-result'; counter = 'f03CrashAfterTerminalResult' }
    )
    foreach ($case in $f03CrashPoints) {
        $hTerm = New-CasIntHarness -Name ('f03-' + [string]$case.point)
        $null = Invoke-CasIntProfile -Harness $hTerm
        $bTerm = Invoke-CasIntBuilder -Harness $hTerm
        $tidTerm = [string]$bTerm.json.thread_id
        $ridTerm = 'run-' + [string]$case.point
        $eventLog = Join-Path $hTerm.root 'events.log'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = $eventLog
        $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = [string]$case.point
        $pathsTerm = Get-CodexAppServerRunPaths -StateRoot ([string]$hTerm.state) -RunId $ridTerm
        $ownerBoundBefore = Get-CasIntTransitionStateCount -Path ([string]$pathsTerm.transitions) -State 'owner_bound'
        $ownerIdentityBefore = Get-CasIntRunOwnerIdentityKey -Harness $hTerm -RunId $ridTerm
        $null = Invoke-CasIntLauncher -Harness $hTerm -ThreadId $tidTerm -RunId $ridTerm
        $expectedCrashPhase = switch ([string]$case.point) {
            'before-terminal-intent' { 'acknowledged' }
            'after-terminal-intent' { 'terminal_publishing' }
            'after-terminal-final' { 'terminal_publishing' }
            'after-terminal-bound' { 'terminal_publishing' }
            default { 'terminal' }
        }
        $crashWorld = [ordered]@{ harness = $hTerm; thread_id = $tidTerm; run_id = $ridTerm; paths = $pathsTerm }
        $crashed = Wait-CasIntRecoverForwardCrash -World $crashWorld -ExpectedPhase $expectedCrashPhase -OwnerBoundBefore $ownerBoundBefore -OwnerIdentityBefore $ownerIdentityBefore
        Assert-CasInt ([bool]$crashed.success) ("Terminal crash $($case.point) did not converge: phase=$([string]$crashed.phase) expected=$expectedCrashPhase owner_bound=$([int]$crashed.owner_bound) baseline=$ownerBoundBefore owner_changed=$([bool]$crashed.owner_changed) owner_alive=$([bool]$crashed.owner_alive).")
        Stop-CasIntRun -Harness $hTerm -RunId $ridTerm
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT -ErrorAction SilentlyContinue
        $ackTerm = Get-Content -LiteralPath (Join-Path (Get-CasIntRunRoot -Harness $hTerm -RunId $ridTerm) 'lead-wake-ack.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        $turnTerm = [string]$ackTerm.turn_id
        Assert-CasInt (-not [string]::IsNullOrWhiteSpace($turnTerm)) ("Terminal crash $($case.point) never bound a turn.")
        $turnsAfterCrash = @(Get-CasIntStoreTurns -Harness $hTerm -ThreadId $tidTerm)
        Assert-CasInt ($turnsAfterCrash.Count -eq 1) ("Terminal crash $($case.point) did not keep one turn.")
        $startsAfterCrash = Get-CasIntEventCount -Path $eventLog -Name 'turn/start'
        Assert-CasInt ($startsAfterCrash -eq 1) ("Terminal crash $($case.point) did not send exactly one turn/start.")
        $storeBefore = ''
        $storePath = Join-Path $hTerm.state 'app-server-store.json'
        if ([IO.File]::Exists($storePath)) { $storeBefore = [IO.File]::ReadAllText($storePath) }
        $second = Invoke-CasIntLauncher -Harness $hTerm -ThreadId $tidTerm -RunId $ridTerm
        Assert-CasInt ($second.exit_code -eq 0) ("Terminal crash $($case.point) did not finish forward: $($second.stderr) $($second.stdout)")
        $settled = Wait-CasIntOfficialTerminalAndQuiet -Harness $hTerm -RunId $ridTerm -ThreadId $tidTerm -TurnId $turnTerm
        Assert-CasInt ([bool]$settled.success) ("Terminal re-entry $($case.point) did not settle: terminal=$([bool]$settled.terminal) run_quiet=$([bool]$settled.run_quiet) thread_quiet=$([bool]$settled.thread_quiet) phase=$([string]$settled.phase) state=$([string]$settled.state).")
        Stop-CasIntRun -Harness $hTerm -RunId $ridTerm
        $runTerm = Get-CasIntRunJson -Harness $hTerm -RunId $ridTerm
        Assert-CasInt ([string]$runTerm.thread_id -ceq $tidTerm) ("Terminal re-entry $($case.point) changed thread id.")
        Assert-CasInt ([string]$runTerm.selected_turn_id -ceq $turnTerm) ("Terminal re-entry $($case.point) changed turn id.")
        Assert-CasInt ([string]$runTerm.callback_write_phase -ceq 'terminal') ("Terminal re-entry $($case.point) did not reach terminal phase.")
        Assert-CasInt ([string]$runTerm.disposition -ceq 'completed') ("Terminal re-entry $($case.point) did not reach completed.")
        Assert-CasInt ([string]$runTerm.terminal_target -ceq 'completed') ("Terminal re-entry $($case.point) omitted terminal_target.")
        Assert-CasInt ([string](Get-CasIntFinalText -Harness $hTerm -RunId $ridTerm) -ceq 'completed') ("Terminal re-entry $($case.point) omitted launcher-final.")
        $resultTerm = (Read-TelephoneJson -Path (Join-Path (Get-CasIntRunRoot -Harness $hTerm -RunId $ridTerm) 'launcher-result.json') -SchemaName 'codex-app-server-lead-result').value
        Assert-CasInt ([string]$resultTerm.state -ceq 'completed') ("Terminal re-entry $($case.point) omitted completed launcher-result.")
        $ackAfter = (Read-TelephoneJson -Path (Join-Path (Get-CasIntRunRoot -Harness $hTerm -RunId $ridTerm) 'lead-wake-ack.json')).value
        Assert-CasInt ([string]$ackAfter.turn_id -ceq $turnTerm) ("Terminal re-entry $($case.point) rewrote ack turn.")
        $turnsAfterSecond = @(Get-CasIntStoreTurns -Harness $hTerm -ThreadId $tidTerm)
        Assert-CasInt ($turnsAfterSecond.Count -eq 1) ("Terminal re-entry $($case.point) started a second turn.")
        $startsAfterSecond = Get-CasIntEventCount -Path $eventLog -Name 'turn/start'
        Assert-CasInt ($startsAfterSecond -eq 1) ("Terminal re-entry $($case.point) sent another turn/start.")
        if ([string]$case.point -cne 'before-terminal-intent' -and $storeBefore -ne '') {
            Assert-CasInt ([IO.File]::ReadAllText($storePath) -ceq $storeBefore) ("Terminal re-entry $($case.point) mutated the provider store.")
        }
        Assert-CasInt (Test-CasIntNoTempResidue -RunRoot (Get-CasIntRunRoot -Harness $hTerm -RunId $ridTerm)) ("Terminal re-entry $($case.point) left temp residue.")
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
        Set-Variable -Name $case.counter -Scope Script -Value 1
    }
    foreach ($point in @('before-terminal-intent', 'after-terminal-intent', 'after-terminal-final', 'after-terminal-bound', 'after-terminal-run', 'after-terminal-result')) {
        $declWorld = New-CasIntAckDeathWorld -Name ('f03-decl-' + $point) -RunId ('run-f03-decl-' + $point)
        Stop-CasIntThreadOwner -Harness $declWorld.harness -ThreadId $declWorld.thread_id
        Assert-CasInt (Wait-CasIntThreadOwnerQuiet -Harness $declWorld.harness -ThreadId $declWorld.thread_id -TimeoutMs 10000) ("Declared terminal crash $point kept the pre-injection thread owner alive.")
        Set-CasIntStoreTurnStatus -Harness $declWorld.harness -ThreadId $declWorld.thread_id -TurnId $declWorld.turn_id -Status 'completed'
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$declWorld.event_log
        $env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS = 'completed'
        $env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT = $point
        $ownerBoundBefore = Get-CasIntTransitionStateCount -Path ([string]$declWorld.paths.transitions) -State 'owner_bound'
        $ownerIdentityBefore = Get-CasIntRunOwnerIdentityKey -Harness $declWorld.harness -RunId $declWorld.run_id
        $null = Invoke-CasIntLauncher -Harness $declWorld.harness -ThreadId $declWorld.thread_id -RunId $declWorld.run_id
        $expectedCrashPhase = switch ($point) {
            'before-terminal-intent' { 'acknowledged' }
            'after-terminal-intent' { 'terminal_publishing' }
            'after-terminal-final' { 'terminal_publishing' }
            'after-terminal-bound' { 'terminal_publishing' }
            default { 'terminal' }
        }
        $declCrashed = Wait-CasIntRecoverForwardCrash -World $declWorld -ExpectedPhase $expectedCrashPhase -OwnerBoundBefore $ownerBoundBefore -OwnerIdentityBefore $ownerIdentityBefore
        Assert-CasInt ([bool]$declCrashed.success) ("Declared terminal crash $point did not converge: phase=$([string]$declCrashed.phase) expected=$expectedCrashPhase owner_bound=$([int]$declCrashed.owner_bound) baseline=$ownerBoundBefore owner_changed=$([bool]$declCrashed.owner_changed) owner_alive=$([bool]$declCrashed.owner_alive).")
        Stop-CasIntRun -Harness $declWorld.harness -RunId $declWorld.run_id
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT -ErrorAction SilentlyContinue
        Assert-CasInt (-not [IO.File]::Exists($declWorld.paths.recovery)) ("Declared terminal crash $point leaked recovery.json into publication.")
        Assert-CasInt (-not [IO.File]::Exists($declWorld.paths.failure)) ("Declared terminal crash $point leaked failure.json into publication.")
        $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = [string]$declWorld.event_log
        $declSecond = Invoke-CasIntLauncher -Harness $declWorld.harness -ThreadId $declWorld.thread_id -RunId $declWorld.run_id
        Assert-CasInt ($declSecond.exit_code -eq 0) ("Declared terminal crash $point did not finish: $($declSecond.stderr) $($declSecond.stdout)")
        $declSettled = Wait-CasIntOfficialTerminalAndQuiet -Harness $declWorld.harness -RunId $declWorld.run_id -ThreadId $declWorld.thread_id -TurnId $declWorld.turn_id
        Assert-CasInt ([bool]$declSettled.success) ("Declared terminal re-entry $point did not settle: terminal=$([bool]$declSettled.terminal) run_quiet=$([bool]$declSettled.run_quiet) thread_quiet=$([bool]$declSettled.thread_quiet) phase=$([string]$declSettled.phase) state=$([string]$declSettled.state).")
        Stop-CasIntRun -Harness $declWorld.harness -RunId $declWorld.run_id
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
        Remove-Item env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS -ErrorAction SilentlyContinue
        $declRun = Get-CasIntRunJson -Harness $declWorld.harness -RunId $declWorld.run_id
        Assert-CasInt ([string]$declRun.thread_id -ceq $declWorld.thread_id) ("Declared terminal re-entry $point changed thread id.")
        Assert-CasInt ([string]$declRun.selected_turn_id -ceq $declWorld.turn_id) ("Declared terminal re-entry $point changed turn id.")
        Assert-CasInt ([string]$declRun.callback_write_phase -ceq 'terminal') ("Declared terminal re-entry $point did not reach terminal.")
        Assert-CasInt ([string]$declRun.disposition -ceq 'completed') ("Declared terminal re-entry $point did not reach completed.")
        Assert-CasInt (@(Get-CasIntStoreTurns -Harness $declWorld.harness -ThreadId $declWorld.thread_id).Count -eq 1) ("Declared terminal re-entry $point started another turn.")
        Assert-CasInt ((Get-CasIntEventCount -Path $declWorld.event_log -Name 'turn/start') -eq 1) ("Declared terminal re-entry $point sent another turn/start.")
        Assert-CasInt ([string]$declRun.fallback_required -ceq '') ("Declared terminal re-entry $point enabled CLI fallback.")
        Invoke-CasIntDurableChain -Paths $declWorld.paths -Harness $declWorld.harness -RunId $declWorld.run_id -ThreadId $declWorld.thread_id
    }
    $script:f03AtomicPublish = 1

    $script:f02R8CutResults = [Collections.Generic.List[object]]::new()
    $script:f02R8ProcessDeathCuts = 0
    foreach ($cutSpec in @(Get-CasIntR8ScopedCutDefinitions)) {
        Invoke-CasIntR8ScopedCutCase -Spec $cutSpec
    }
    Assert-CasInt ($script:f02R8ProcessDeathCuts -ge 72) ("R8 writer-scoped cut matrix was incomplete: $($script:f02R8ProcessDeathCuts)")
    $script:f02R8WriterScopedCuts = 1

    $hF04 = New-CasIntHarness -Name 'f04-tier'
    $null = Invoke-CasIntProfile -Harness $hF04
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = (Join-Path $hF04.root 'tier-events.log')
    $env:TELEPHONE_TEST_APP_SERVER_RETURN_TIER = 'priority'
    $tierFail = Invoke-CasIntBuilder -Harness $hF04
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_RETURN_TIER -ErrorAction SilentlyContinue
    Assert-CasInt ($tierFail.exit_code -ne 0) 'Inherited priority tier was accepted.'
    Assert-CasInt ([string]$tierFail.json.error -ceq (Get-CodexAppServerPublicMessage -Code 'SERVICE_TIER_INVALID')) 'Nondefault tier leaked a raw error.'
    $events = ''
    if ([IO.File]::Exists($env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG)) { $events = [IO.File]::ReadAllText($env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG) }
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
    Assert-CasInt ($events.IndexOf('nondefault_tier:turn/start', [StringComparison]::Ordinal) -lt 0) 'A nondefault turn/start was sent.'
    $hF04ok = New-CasIntHarness -Name 'f04-default'
    $null = Invoke-CasIntProfile -Harness $hF04ok
    $env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG = (Join-Path $hF04ok.root 'default-events.log')
    $bF04ok = Invoke-CasIntBuilder -Harness $hF04ok
    $lF04ok = Invoke-CasIntLauncher -Harness $hF04ok -ThreadId ([string]$bF04ok.json.thread_id) -RunId 'run-default-tier'
    Assert-CasInt ($lF04ok.exit_code -eq 0) ("Default tier launch failed: $($lF04ok.stderr)")
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hF04ok -RunId 'run-default-tier') 'Default tier worker did not exit.'
    $okEvents = [IO.File]::ReadAllText($env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG)
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG -ErrorAction SilentlyContinue
    Assert-CasInt ($okEvents.IndexOf('nondefault_tier:turn/start', [StringComparison]::Ordinal) -lt 0) 'Default path sent a nondefault turn/start.'
    $runTier = Get-CasIntRunJson -Harness $hF04ok -RunId 'run-default-tier'
    Assert-CasInt ([string]$runTier.service_tier -ceq 'default') 'Run identity omitted the default service tier.'
    $script:nondefaultTurnStarts = 0
    $script:f04ServiceTierDefault = 1

    $hF05 = New-CasIntHarness -Name 'f05-compat'
    $null = Invoke-CasIntProfile -Harness $hF05
    $bF05 = Invoke-CasIntBuilder -Harness $hF05
    $env:TELEPHONE_TEST_APP_SERVER_VERSION = 'codex-cli 0.148.0-drift'
    $verDrift = Invoke-CasIntLauncher -Harness $hF05 -ThreadId ([string]$bF05.json.thread_id) -RunId 'run-version-drift'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_VERSION -ErrorAction SilentlyContinue
    Assert-CasInt ($verDrift.exit_code -ne 0) 'Same-fingerprint version drift was accepted.'
    Assert-CasInt ([string]$verDrift.json.fallback_required -ceq 'cli') 'Pre-bind version drift did not request CLI fallback.'
    Assert-CasInt (-not [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hF05 -RunId 'run-version-drift') 'launcher-final.txt'))) 'Pre-bind fallback wrote launcher-final.'
    $hF05b = New-CasIntHarness -Name 'f05-post-ack'
    $null = Invoke-CasIntProfile -Harness $hF05b
    $bF05b = Invoke-CasIntBuilder -Harness $hF05b
    $holdF05 = Join-Path $hF05b.root 'hold-completed'
    $env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH = $holdF05
    $startedF05 = Start-CasIntLauncherProcess -Harness $hF05b -ThreadId ([string]$bF05b.json.thread_id) -RunId 'run-post-ack-drift'
    $null = Wait-CasIntStatus -Harness $hF05b -RunId 'run-post-ack-drift' -Predicate { param($s) $true } -Message 'post-ack status missing' -TimeoutMs 20000
    $deadlineAck = [DateTimeOffset]::UtcNow.AddSeconds(20)
    while (-not [IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hF05b -RunId 'run-post-ack-drift') 'lead-wake-ack.json')) -and [DateTimeOffset]::UtcNow -lt $deadlineAck) {
        Start-Sleep -Milliseconds 50
    }
    Assert-CasInt ([IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hF05b -RunId 'run-post-ack-drift') 'lead-wake-ack.json'))) 'Post-ack drift never bound a turn.'
    Stop-CasIntRun -Harness $hF05b -RunId 'run-post-ack-drift'
    $deadF05 = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while ((Test-CasIntOwnerAlive -Harness $hF05b -RunId 'run-post-ack-drift') -and [DateTimeOffset]::UtcNow -lt $deadF05) { Start-Sleep -Milliseconds 50 }
    Assert-CasInt (-not (Test-CasIntOwnerAlive -Harness $hF05b -RunId 'run-post-ack-drift')) 'Post-ack worker was still alive.'
    $null = $startedF05
    $env:TELEPHONE_TEST_APP_SERVER_VERSION = 'codex-cli 0.148.0-drift'
    $postAck = Invoke-CasIntLauncher -Harness $hF05b -ThreadId ([string]$bF05b.json.thread_id) -RunId 'run-post-ack-drift'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_VERSION, env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH -ErrorAction SilentlyContinue
    Assert-CasInt ($postAck.exit_code -ne 0) 'Post-ack version drift was accepted.'
    $postAckFallback = ''
    if ($null -ne $postAck.json -and $postAck.json -is [Collections.IDictionary] -and $postAck.json.Contains('fallback_required')) {
        $postAckFallback = [string]$postAck.json.fallback_required
    }
    Assert-CasInt ($postAckFallback -cne 'cli') 'Post-ack drift advertised CLI fallback.'
    Assert-CasInt ([IO.File]::Exists((Join-Path (Get-CasIntRunRoot -Harness $hF05b -RunId 'run-post-ack-drift') 'recovery.json'))) 'Post-ack drift did not write recovery.json.'
    Assert-CasInt ([string](Get-CasIntFinalText -Harness $hF05b -RunId 'run-post-ack-drift') -ceq '') 'Post-ack recovery wrote launcher-final.'
    $script:f05CompatibilityIdentity = 1

    $travFailed = $false
    try { $null = Get-CodexAppServerRunPaths -StateRoot ([string]$hF02.state) -RunId '..\escape' } catch { $travFailed = $true }
    Assert-CasInt $travFailed 'Traversal RunId was accepted.'
    $pkgFailed = $false
    try { $null = Get-CodexAppServerRunPaths -StateRoot $repoRoot -RunId 'run-package' } catch { $pkgFailed = $true }
    Assert-CasInt $pkgFailed 'Package-local state was accepted.'
    $siblingRoot = Join-Path $TestRoot 'state-sibling'
    $statePrefix = Join-Path $TestRoot 'state'
    [IO.Directory]::CreateDirectory((Join-Path $siblingRoot 'runs\run-sib')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $statePrefix 'runs\run-real')) | Out-Null
    $sibSources = Join-Path $TestRoot 'sources-sibling.json'
    [IO.File]::WriteAllText($sibSources, (([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-status-sources-v1'
        sources = @([ordered]@{ id = 'runs'; kind = 'codex-app-server-lead-runs'; root = (Join-Path $statePrefix 'runs') })
    } | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $sibStatus = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @('-SourcesPath', $sibSources)
    Assert-CasInt ($sibStatus.exit_code -eq 0) 'Sibling-prefix status read failed.'
    foreach ($item in @($sibStatus.json.items)) {
        Assert-CasInt ([string]$item.item_root -notlike '*state-sibling*') 'Sibling-prefix source leaked a neighboring root.'
    }
    $juncReal = Join-Path $TestRoot 'junc-real'
    $juncLink = Join-Path $TestRoot 'junc-link'
    [IO.Directory]::CreateDirectory($juncReal) | Out-Null
    cmd.exe /c "mklink /J `"$juncLink`" `"$juncReal`"" | Out-Null
    Assert-CasInt ((Test-Path -LiteralPath $juncLink) -and (Test-CodexAppServerReparsePoint -Path $juncLink)) 'Junction fixture was not created.'
    $juncFailed = $false
    try { $null = Get-CodexAppServerRunPaths -StateRoot $juncLink -RunId 'run-junc' } catch { $juncFailed = $true }
    Assert-CasInt $juncFailed 'Junction state root was accepted.'
    $badSources = Join-Path $TestRoot 'sources-extra.json'
    [IO.File]::WriteAllText($badSources, "{`"protocol_version`":`"telephone-line-codex-app-server-lead-status-sources-v1`",`"sources`":[{`"id`":`"runs`",`"kind`":`"codex-app-server-lead-runs`",`"root`":`"C:\\example\\runs`"}],`"extra`":true}`n", [Text.UTF8Encoding]::new($false))
    $srcFail = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @('-SourcesPath', $badSources)
    Assert-CasInt ($srcFail.exit_code -ne 0) 'Extra-field status sources were accepted.'
    $tamperRoot = Join-Path $TestRoot 'tamper-run'
    [IO.Directory]::CreateDirectory($tamperRoot) | Out-Null
    $tamperStatus = Join-Path $tamperRoot 'status.json'
    [IO.File]::WriteAllText($tamperStatus, (([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-status-v1'
        thread_id = 'thread-tamper'
        status = 'active'
        active_flags = @()
        pending = @([ordered]@{ method = 'item/hack/request'; id = 'bad-1' })
        started = $false
        mutated = $false
    } | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $tamperSources = Join-Path $TestRoot 'sources-tamper.json'
    [IO.File]::WriteAllText($tamperSources, (([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-status-sources-v1'
        sources = @([ordered]@{ id = 'runs'; kind = 'codex-app-server-lead-runs'; root = $tamperRoot })
    } | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $tamperRead = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @('-SourcesPath', $tamperSources)
    Assert-CasInt ($tamperRead.exit_code -eq 0) 'Tampered pending status read failed closed instead of filtering.'
    $pendingOut = @($tamperRead.json.items | ForEach-Object { @($_.pending) })
    foreach ($p in $pendingOut) {
        if ($null -eq $p) { continue }
        Assert-CasInt ([string]$p.method -cne 'item/hack/request') 'Tampered pending method escaped status output.'
    }
    $runsJuncRoot = Join-Path $TestRoot 'runs-junc-state'
    $runsJuncReal = Join-Path $TestRoot 'runs-junc-real'
    [IO.Directory]::CreateDirectory($runsJuncRoot) | Out-Null
    [IO.Directory]::CreateDirectory($runsJuncReal) | Out-Null
    cmd.exe /c "mklink /J `"$(Join-Path $runsJuncRoot 'runs')`" `"$runsJuncReal`"" | Out-Null
    $runsJuncFailed = $false
    try { $null = Get-CodexAppServerRunPaths -StateRoot $runsJuncRoot -RunId 'run-missing-leaf' } catch { $runsJuncFailed = $true }
    Assert-CasInt $runsJuncFailed 'Runs-directory junction with a missing leaf was accepted.'
    $pkgPre = Invoke-CasIntScript -ScriptPath $preflightScript -Arguments @('-CodexCommand', $mock, '-WorktreePath', [string]$hF02.worktree, '-StateRoot', $runtimeRepoRoot)
    Assert-CasInt ($pkgPre.exit_code -ne 0 -or $pkgPre.json.ready -eq $false) 'Package-local preflight StateRoot was accepted.'
    $pkgProfilePath = Join-Path $runtimeRepoRoot 'profile-package-local.json'
    $pkgProf = Invoke-CasIntScript -ScriptPath $profileScript -Arguments @('-CodexCommand', $mock, '-OutputPath', $pkgProfilePath)
    Assert-CasInt ($pkgProf.exit_code -ne 0) 'Package-local profile OutputPath was accepted.'
    Assert-CasInt (-not [IO.File]::Exists($pkgProfilePath)) 'Package-local profile file was created.'
    $hAckBad = New-CasIntHarness -Name 'f06-bad-ack'
    $null = Invoke-CasIntProfile -Harness $hAckBad
    $bAckBad = Invoke-CasIntBuilder -Harness $hAckBad
    $tidAckBad = [string]$bAckBad.json.thread_id
    $pAckBad = Write-CasIntPlantedIntent -Harness $hAckBad -RunId 'run-bad-ack' -ThreadId $tidAckBad
    Write-CasIntPlantedRun -Paths $pAckBad -Harness $hAckBad -RunId 'run-bad-ack' -ThreadId $tidAckBad -Selected 'turn-ack' -Disposition 'in_progress' -Phase 'acknowledged'
    Write-CasIntPlantedBound -Paths $pAckBad -ThreadId $tidAckBad -TurnId 'turn-ack'
    Write-CasIntPlantedAck -Paths $pAckBad -ThreadId $tidAckBad -TurnId 'turn-ack'
    $ackDoc = Get-Content -LiteralPath $pAckBad.ack -Raw | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    $ackDoc.extra = $true
    [IO.File]::WriteAllText($pAckBad.ack, ((ConvertTo-Json $ackDoc -Depth 32).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $ackStatus = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @('-StateRoot', [string]$hAckBad.state, '-RunId', 'run-bad-ack')
    Assert-CasInt ($ackStatus.exit_code -eq 0) 'Malformed ack status read failed closed.'
    foreach ($item in @($ackStatus.json.items)) {
        Assert-CasInt ([bool]$item.acknowledged -eq $false) 'Malformed ack was reported as acknowledged.'
    }
    $hBindOk = New-CasIntHarness -Name 'f06-bind-ok'
    $null = Invoke-CasIntProfile -Harness $hBindOk
    $sibBindDir = Join-Path $TestRoot 'f06-bind-sibling'
    [IO.Directory]::CreateDirectory($sibBindDir) | Out-Null
    $sibBind = Join-Path $sibBindDir 'lead-binding.json'
    $okBind = Invoke-CasIntBuilder -Harness $hBindOk -BindingOutputPath $sibBind
    Assert-CasInt ($okBind.exit_code -eq 0) ("Sibling-outside app-server binding failed: $($okBind.stderr)")
    Assert-CasInt ([IO.File]::Exists($sibBind)) 'Sibling-outside app-server binding was not written.'
    Assert-CasInt (-not [IO.File]::Exists([string]$hBindOk.binding)) 'Sibling-outside app-server binding wrote the default harness path.'
    $hBindCli = New-CasIntHarness -Name 'f06-bind-cli'
    $cliBindDir = Join-Path $TestRoot 'f06-bind-cli-sibling'
    [IO.Directory]::CreateDirectory($cliBindDir) | Out-Null
    $cliBind = Join-Path $cliBindDir 'lead-binding.json'
    $okCliBind = Invoke-CasIntBuilder -Harness $hBindCli -Transport 'cli' -CliLauncher $cliSpy -ResumeSessionId 'cli-session-f06' -BindingOutputPath $cliBind
    Assert-CasInt ($okCliBind.exit_code -eq 0) ("Sibling-outside CLI binding failed: $($okCliBind.stderr)")
    Assert-CasInt ([IO.File]::Exists($cliBind)) 'Sibling-outside CLI binding was not written.'
    $bindJuncReal = Join-Path $TestRoot 'f06-bind-junc-real'
    $bindJuncLink = Join-Path $TestRoot 'f06-bind-junc-link'
    [IO.Directory]::CreateDirectory($bindJuncReal) | Out-Null
    cmd.exe /c "mklink /J `"$bindJuncLink`" `"$bindJuncReal`"" | Out-Null
    $f06BindNeg = @(
        @{ name = 'package-root'; path = $runtimeRepoRoot },
        @{ name = 'nested'; path = (Join-Path $runtimeRepoRoot 'schemas\f06-nested-binding.json') },
        @{ name = 'traversal'; path = (Join-Path $runtimeRepoRoot ('..\' + [IO.Path]::GetFileName($runtimeRepoRoot) + '\f06-trav-binding.json')) },
        @{ name = 'reparse'; path = (Join-Path $bindJuncLink 'binding.json') }
    )
    foreach ($transport in @('app-server', 'cli')) {
        foreach ($neg in $f06BindNeg) {
            $hNeg = New-CasIntHarness -Name ('f06-' + $transport + '-' + [string]$neg.name)
            $requested = [IO.Path]::GetFullPath([string]$neg.path)
            $snapBefore = Get-CasIntSnapshot @([string]$hNeg.state, [string]$hNeg.root)
            $storePath = Join-Path $hNeg.state 'app-server-store.json'
            $leafBefore = ([IO.File]::Exists($requested) -or [IO.Directory]::Exists($requested))
            $cliArgs = @{}
            if ($transport -ceq 'cli') {
                $got = Invoke-CasIntBuilder -Harness $hNeg -Transport 'cli' -CliLauncher $cliSpy -ResumeSessionId 'cli-session-neg' -BindingOutputPath $requested
            } else {
                $got = Invoke-CasIntBuilder -Harness $hNeg -BindingOutputPath $requested
            }
            Assert-CasInt ($got.exit_code -ne 0) ("F06 $transport $($neg.name) binding was accepted.")
            if (-not $leafBefore) {
                Assert-CasInt (-not [IO.File]::Exists($requested) -and -not [IO.Directory]::Exists($requested)) ("F06 $transport $($neg.name) created the requested binding.")
            }
            Assert-CasInt (-not [IO.File]::Exists($storePath)) ("F06 $transport $($neg.name) created an app-server store.")
            Assert-CasInt (-not [IO.File]::Exists([string]$hNeg.profile)) ("F06 $transport $($neg.name) created a profile.")
            Assert-CasInt (-not [IO.File]::Exists([string]$hNeg.binding)) ("F06 $transport $($neg.name) created the default binding.")
            $snapAfter = Get-CasIntSnapshot @([string]$hNeg.state, [string]$hNeg.root)
            Assert-CasInt (($snapAfter -join '|') -ceq ($snapBefore -join '|')) ("F06 $transport $($neg.name) mutated output or state roots.")
            $null = $cliArgs
        }
    }
    $script:f06StatusContainment = 1

    $needleSecret = 'sk-NEEDLESECRET1234567890abcd'
    $needlePath = 'C:\NeedleAbs\hidden\codex.cmd'
    $hF07 = New-CasIntHarness -Name 'f07-privacy'
    $env:TELEPHONE_TEST_APP_SERVER_VERSION_FAIL = '1'
    $env:TELEPHONE_TEST_APP_SERVER_VERSION = $needleSecret
    $preV = Invoke-CasIntScript -ScriptPath $preflightScript -Arguments @('-CodexCommand', $mock, '-WorktreePath', [string]$hF07.worktree, '-StateRoot', [string]$hF07.state)
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_VERSION_FAIL, env:TELEPHONE_TEST_APP_SERVER_VERSION -ErrorAction SilentlyContinue
    $env:TELEPHONE_TEST_APP_SERVER_SCHEMA_FAIL = '1'
    $preS = Invoke-CasIntScript -ScriptPath $preflightScript -Arguments @('-CodexCommand', $mock, '-WorktreePath', [string]$hF07.worktree, '-StateRoot', [string]$hF07.state)
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_SCHEMA_FAIL -ErrorAction SilentlyContinue
    $missing = Invoke-CasIntScript -ScriptPath $preflightScript -Arguments @('-CodexCommand', $needlePath, '-WorktreePath', [string]$hF07.worktree, '-StateRoot', [string]$hF07.state)
    $null = Invoke-CasIntProfile -Harness $hF07
    $env:TELEPHONE_TEST_APP_SERVER_OMIT_THREAD_ID = '1'
    $bNeedle = Invoke-CasIntBuilder -Harness $hF07
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_OMIT_THREAD_ID -ErrorAction SilentlyContinue
    $srcNeedle = Join-Path $hF07.root 'sources-needle.json'
    [IO.File]::WriteAllText($srcNeedle, "{`"protocol_version`":`"telephone-line-codex-app-server-lead-status-sources-v1`",`"sources`":[{`"id`":`"runs`",`"kind`":`"codex-app-server-lead-runs`",`"root`":`"$($needlePath.Replace('\','\\'))`"}],`"extra`":true}`n", [Text.UTF8Encoding]::new($false))
    $stNeedle = Invoke-CasIntScript -ScriptPath $statusScript -Arguments @('-SourcesPath', $srcNeedle)
    $blobs = @($preV.stdout, $preV.stderr, $preS.stdout, $preS.stderr, $missing.stdout, $missing.stderr, $bNeedle.stdout, $bNeedle.stderr, $stNeedle.stdout, $stNeedle.stderr)
    $needleHits = 0
    foreach ($blob in $blobs) {
        if ([string]$blob.IndexOf($needleSecret, [StringComparison]::Ordinal) -ge 0) { $needleHits += 1 }
        if ([string]$blob.IndexOf($needlePath, [StringComparison]::Ordinal) -ge 0) { $needleHits += 1 }
    }
    Assert-CasInt ($needleHits -eq 0) 'Secret or absolute-path needles leaked through public errors.'
    $script:privacyNeedleHits = $needleHits
    $profNeedle = Invoke-CasIntScript -ScriptPath $profileScript -Arguments @('-CodexCommand', $needlePath, '-OutputPath', (Join-Path $hF07.root 'profile-missing.json'))
    $env:TELEPHONE_TEST_APP_SERVER_SCHEMA_FAIL = '1'
    $profSchema = Invoke-CasIntScript -ScriptPath $profileScript -Arguments @('-CodexCommand', $mock, '-OutputPath', (Join-Path $hF07.root 'profile-schema.json'))
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_SCHEMA_FAIL -ErrorAction SilentlyContinue
    $launchNeedle = Invoke-CasIntScript -ScriptPath $launcherScript -Arguments @(
        '-WorktreePath', [string]$hF07.worktree, '-PromptFile', [string]$hF07.prompt,
        '-ResumeSessionId', 'thread-missing', '-RunId', 'run-entry-privacy',
        '-StateRoot', $runtimeRepoRoot, '-CodexCommand', $needlePath, '-ProfilePath', [string]$hF07.profile
    )
    $entryBlobs = @($profNeedle.stdout, $profNeedle.stderr, $profSchema.stdout, $profSchema.stderr, $launchNeedle.stdout, $launchNeedle.stderr)
    $entryHits = 0
    foreach ($blob in $entryBlobs) {
        if ([string]$blob.IndexOf($needleSecret, [StringComparison]::Ordinal) -ge 0) { $entryHits += 1 }
        if ([string]$blob.IndexOf($needlePath, [StringComparison]::Ordinal) -ge 0) { $entryHits += 1 }
        if ([string]$blob.IndexOf($repoRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $entryHits += 1 }
        if ([string]$blob.IndexOf($runtimeRepoRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $entryHits += 1 }
    }
    Assert-CasInt ($entryHits -eq 0) 'Profile or launcher entry leaked raw paths or secrets.'
    Assert-CasInt ($profNeedle.exit_code -ne 0 -and $profSchema.exit_code -ne 0 -and $launchNeedle.exit_code -ne 0) 'Injected entry-point failures did not fail closed.'
    $script:f07PublicErrorPrivacy = 1

    $hmis = New-CasIntHarness -Name 'intent-mismatch'
    $null = Invoke-CasIntProfile -Harness $hmis
    $bmis = Invoke-CasIntBuilder -Harness $hmis
    $tidm = [string]$bmis.json.thread_id
    $ridm = 'run-mismatch'
    $m1 = Invoke-CasIntLauncher -Harness $hmis -ThreadId $tidm -RunId $ridm
    Assert-CasInt ($m1.exit_code -eq 0) ("Intent baseline launch failed: $($m1.stderr)")
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hmis -RunId $ridm) 'Intent baseline worker did not exit.'
    $mismatchCases = @(
        @{ name = 'thread'; args = @{ ThreadId = 'other-thread-id' } },
        @{ name = 'worktree'; mutate = { param($h) $h.worktree = (Join-Path $h.root 'other-worktree'); [IO.Directory]::CreateDirectory($h.worktree) | Out-Null } }
    )
    $threadMismatch = Invoke-CasIntLauncher -Harness $hmis -ThreadId 'other-thread-id' -RunId $ridm
    Assert-CasInt ($threadMismatch.exit_code -ne 0) 'Changed thread was not fail-closed.'
    $otherTree = Join-Path $hmis.root 'other-worktree'
    [IO.Directory]::CreateDirectory($otherTree) | Out-Null
    $origTree = [string]$hmis.worktree
    $hmis.worktree = $otherTree
    $treeMismatch = Invoke-CasIntLauncher -Harness $hmis -ThreadId $tidm -RunId $ridm
    $hmis.worktree = $origTree
    Assert-CasInt ($treeMismatch.exit_code -ne 0) 'Changed worktree was not fail-closed.'
    $origPrompt = [string]$hmis.prompt
    $otherPrompt = Join-Path $hmis.root 'other-callback.md'
    [IO.File]::WriteAllText($otherPrompt, "other callback`n", [Text.UTF8Encoding]::new($false))
    $hmis.prompt = $otherPrompt
    $pathMismatch = Invoke-CasIntLauncher -Harness $hmis -ThreadId $tidm -RunId $ridm
    $hmis.prompt = $origPrompt
    Assert-CasInt ($pathMismatch.exit_code -ne 0) 'Changed callback path was not fail-closed.'
    [IO.File]::WriteAllText($origPrompt, "changed callback bytes`n", [Text.UTF8Encoding]::new($false))
    $bytesMismatch = Invoke-CasIntLauncher -Harness $hmis -ThreadId $tidm -RunId $ridm
    [IO.File]::WriteAllText($origPrompt, ("Telephone Line callback identity only.`n$($hmis.secret)`n"), [Text.UTF8Encoding]::new($false))
    Assert-CasInt ($bytesMismatch.exit_code -ne 0) 'Changed callback content was not fail-closed.'
    $profileObj = (Read-TelephoneJson -Path $hmis.profile -SchemaName 'codex-app-server-lead-profile').value
    $savedFp = [string]$profileObj.schema_fingerprint
    $profileObj.schema_fingerprint = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
    $null = Write-CodexAppServerJsonReplace -Path $hmis.profile -Value $profileObj
    $profileMismatch = Invoke-CasIntLauncher -Harness $hmis -ThreadId $tidm -RunId $ridm
    $profileObj.schema_fingerprint = $savedFp
    $null = Write-CodexAppServerJsonReplace -Path $hmis.profile -Value $profileObj
    Assert-CasInt ($profileMismatch.exit_code -ne 0) 'Changed profile fingerprint was not fail-closed.'
    $ackMis = Join-Path (Get-CasIntRunRoot -Harness $hmis -RunId $ridm) 'lead-wake-ack.json'
    $ackObj = (Read-TelephoneJson -Path $ackMis).value
    $savedTurn = [string]$ackObj.turn_id
    $ackObj.turn_id = 'other-turn'
    $null = Write-CodexAppServerJsonReplace -Path $ackMis -Value $ackObj
    $ackMismatch = Invoke-CasIntLauncher -Harness $hmis -ThreadId $tidm -RunId $ridm
    $ackObj.turn_id = $savedTurn
    $null = Write-CodexAppServerJsonReplace -Path $ackMis -Value $ackObj
    Assert-CasInt ($ackMismatch.exit_code -ne 0) 'Changed ack turn was not fail-closed.'
    Assert-CasInt (@(Get-CasIntStoreTurns -Harness $hmis -ThreadId $tidm).Count -eq 1) 'Identity mismatch started another turn.'
    $script:intentMismatchClosed = 1
    $null = $mismatchCases

    $hd = New-CasIntHarness -Name 'drift'
    $null = Invoke-CasIntProfile -Harness $hd
    $bd = Invoke-CasIntBuilder -Harness $hd
    $cliMarker = Join-Path $hd.root 'cli-marker.txt'
    $env:TELEPHONE_TEST_CLI_FALLBACK_MARKER = $cliMarker
    $env:TELEPHONE_TEST_APP_SERVER_SCHEMA_EXTRA = '{"drift":true}'
    $drift = Invoke-CasIntLauncher -Harness $hd -ThreadId ([string]$bd.json.thread_id) -RunId 'run-drift'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_SCHEMA_EXTRA, env:TELEPHONE_TEST_CLI_FALLBACK_MARKER -ErrorAction SilentlyContinue
    Assert-CasInt ($drift.exit_code -ne 0) 'Schema mismatch did not fail closed.'
    Assert-CasInt ([string]$drift.json.fallback_required -ceq 'cli') 'Schema mismatch did not request explicit CLI fallback.'
    Assert-CasInt (-not [IO.File]::Exists($cliMarker)) 'CLI launcher ran automatically after mismatch.'
    $driftTurns = @(Get-CasIntStoreTurns -Harness $hd -ThreadId ([string]$bd.json.thread_id))
    Assert-CasInt ($driftTurns.Count -eq 0) 'Schema mismatch still sent a turn.'
    $script:schemaMismatch = 1
    $script:automaticFallbackAbsent = 1

    $hf = New-CasIntHarness -Name 'explicit-cli'
    $cliBinding = Invoke-CasIntBuilder -Harness $hf -ResumeSessionId 'cli-session-1' -Transport 'cli' -CliLauncher $cliSpy
    Assert-CasInt ($cliBinding.exit_code -eq 0) ("Explicit CLI binding failed: $($cliBinding.stderr)")
    $bound = (Read-TelephoneJson -Path $hf.binding -SchemaName 'lead-binding').value
    Assert-CasInt ([string]$bound.launcher.path -ceq $cliSpy) 'Explicit CLI binding did not use the CLI launcher.'
    Assert-CasInt ([string]$cliBinding.json.callback_transport -ceq 'cli') 'Explicit CLI transport was not recorded.'
    $script:explicitFallback = 1

    $listenFailed = $false
    try { Assert-CodexAppServerListenStdioOnly -Arguments @('app-server', '--listen', 'ws://127.0.0.1:1') } catch { $listenFailed = $true }
    Assert-CasInt $listenFailed 'WebSocket listen was accepted.'
    $unixFailed = $false
    try { Assert-CodexAppServerListenStdioOnly -Arguments @('--listen', 'unix:///tmp/codex.sock') } catch { $unixFailed = $true }
    Assert-CasInt $unixFailed 'Unix listen was accepted.'
    Assert-CodexAppServerListenStdioOnly -Arguments @('app-server', '--listen', 'stdio://')
    $script:stdioOnly = 1

    $expFailed = $false
    try { Assert-CodexAppServerStablePayload -Payload ([ordered]@{ excludeTurns = $true }) -Label 'exp' } catch { $expFailed = $true }
    Assert-CasInt $expFailed 'excludeTurns was accepted.'
    $apiFailed = $false
    try { Assert-CodexAppServerStablePayload -Payload ([ordered]@{ capabilities = [ordered]@{ experimentalApi = $true } }) -Label 'api' } catch { $apiFailed = $true }
    Assert-CasInt $apiFailed 'experimentalApi true was accepted.'
    $pageFailed = $false
    try { Assert-CodexAppServerStablePayload -Payload ([ordered]@{ initialTurnsPage = 1 }) -Label 'page' } catch { $pageFailed = $true }
    Assert-CasInt $pageFailed 'Experimental pagination was accepted.'
    $script:experimentalExcluded = 1

    $pre = Invoke-CasIntScript -ScriptPath $preflightScript -Arguments @(
        '-CodexCommand', $mock, '-WorktreePath', [string]$h1.worktree, '-StateRoot', [string]$h1.state, '-ProfilePath', [string]$h1.profile
    )
    Assert-CasInt ($pre.exit_code -eq 0 -and $pre.json.ready -eq $true) ("Preflight failed: $($pre.stderr)")
    Assert-CasInt ($pre.json.allow_fast -eq $false) 'Preflight allowed Fast.'
    Assert-CasInt ($pre.json.started -eq $false) 'Preflight started work.'

    $commonText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\lead-side\codex-app-server\CodexAppServerLead.Common.ps1'))
    $lifeText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\lead-side\codex-app-server\CodexAppServerLead.Lifecycle.ps1'))
    $workerText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\lead-side\codex-app-server\Invoke-CodexAppServerLeadWorker.ps1'))
    Assert-CasInt ($commonText.Contains('"jsonrpc"') -eq $true) 'jsonrpc rejection is missing.'
    Assert-CasInt ($commonText.Contains('experimentalApi = $true') -eq $false) 'Adapter enables experimentalApi.'
    Assert-CasInt ($commonText.Contains('ws://') -eq $false) 'Adapter contains a websocket URL.'
    Assert-CasInt ($lifeText.Contains('CliLauncher') -eq $false) 'Wake lifecycle references CliLauncher.'
    Assert-CasInt ($workerText.Contains('CliLauncher') -eq $false) 'Worker references CliLauncher.'
    Assert-CasInt ($commonText.Contains('codex exec') -eq $false) 'Adapter contains automatic CLI exec fallback.'
    Assert-CasInt ($lifeText.Contains('codex exec') -eq $false) 'Lifecycle contains automatic CLI exec fallback.'
    Assert-CasInt ($lifeText.Contains("-ceq 'interrupted'")) 'Official interrupted is not a proven terminal.'
    Assert-CasInt ($lifeText.Contains('recovery_required')) 'Transport-loss recovery_required state is missing.'
    Assert-CasInt ($lifeText.Contains("`$disp = 'completed'") -eq $false) 'Malformed terminal still defaults to completed.'
    Assert-CasInt ($commonText.Contains('accepted_turn_read')) 'Accepted-turn unbounded read flag is missing.'
    Assert-CasInt ($commonText.Contains('stdout_read_task')) 'Outstanding stdout read is not preserved.'
    Assert-CasInt ($commonText.Contains('[Threading.Timeout]::Infinite')) 'Accepted-turn read is not unbounded.'

    $hpriv = New-CasIntHarness -Name 'privacy-volume'
    $null = Invoke-CasIntProfile -Harness $hpriv
    $bpriv = Invoke-CasIntBuilder -Harness $hpriv
    $env:TELEPHONE_TEST_APP_SERVER_STDERR_SECRET = 'sk-SECRETFAKEVALUE1234567890abcd'
    $env:TELEPHONE_TEST_APP_SERVER_STDERR_BYTES = '262144'
    $env:TELEPHONE_TEST_APP_SERVER_PENDING_SECRET = 'Bearer FAKESECRET_e1f2g3h4i5j6k7l8m9n0'
    $env:TELEPHONE_TEST_APP_SERVER_ERROR_SECRET = 'sk-SECRETFAKEVALUE1234567890abcd'
    $env:TELEPHONE_TEST_APP_SERVER_HISTORY_SECRET = 'sk-SECRETFAKEVALUE1234567890abcd'
    $env:TELEPHONE_TEST_APP_SERVER_PENDING_METHOD = 'item/fileChange/requestApproval'
    $env:TELEPHONE_TEST_APP_SERVER_PENDING_ID = 'priv-pending'
    $privLaunch = Invoke-CasIntLauncher -Harness $hpriv -ThreadId ([string]$bpriv.json.thread_id) -RunId 'run-privacy'
    Remove-Item env:TELEPHONE_TEST_APP_SERVER_STDERR_SECRET, env:TELEPHONE_TEST_APP_SERVER_STDERR_BYTES, env:TELEPHONE_TEST_APP_SERVER_PENDING_SECRET, env:TELEPHONE_TEST_APP_SERVER_ERROR_SECRET, env:TELEPHONE_TEST_APP_SERVER_HISTORY_SECRET, env:TELEPHONE_TEST_APP_SERVER_PENDING_METHOD, env:TELEPHONE_TEST_APP_SERVER_PENDING_ID -ErrorAction SilentlyContinue
    Assert-CasInt ($privLaunch.exit_code -eq 0) ("Privacy/volume wake failed: $($privLaunch.stderr)")
    Assert-CasInt (Wait-CasIntRunQuiet -Harness $hpriv -RunId 'run-privacy') 'Privacy worker did not exit.'
    $evidencePath = Join-Path (Get-CasIntRunRoot -Harness $hpriv -RunId 'run-privacy') 'stderr-evidence.json'
    Assert-CasInt ([IO.File]::Exists($evidencePath)) 'Stderr evidence is missing.'
    $evidence = (Read-TelephoneJson -Path $evidencePath).value
    Assert-CasInt ([int]$evidence.line_count -gt 100) 'Stderr was not drained.'
    Assert-CasInt ([int64]$evidence.byte_count -ge 262144) 'Stderr volume was not fully drained.'
    Assert-CasInt ([string]$evidence.category -ceq 'drained') 'Stderr evidence is not categorical.'
    Assert-CasIntNoSecret -Harness $hpriv -RunId 'run-privacy' -Stdout ([string]$privLaunch.stdout) -Stderr ([string]$privLaunch.stderr)
    Assert-CasIntNoSecret -Harness $h1 -RunId $runId -Stdout ([string]$wake.stdout) -Stderr ([string]$wake.stderr)
    $script:stderrDrained = 1
    $script:privacyClean = 1

    $docs = [IO.File]::ReadAllText((Join-Path $repoRoot 'docs\codex-app-server-lead.md'))
    Assert-CasInt ($docs.Contains('Lead-side adapter')) 'Docs do not call this a Lead-side adapter.'
    Assert-CasInt ($docs.Contains('exactly eight routes')) 'Docs omit eight-route denominator.'
    Assert-CasInt ($docs.Contains('no ninth is planned')) 'Docs omit ninth-route denial.'
    Assert-CasInt ($docs.Contains('explicit') -and $docs.ToLowerInvariant().Contains('fallback')) 'Docs omit explicit CLI fallback.'
    Assert-CasInt ($docs.Contains('serviceTier') -or $docs.Contains('service_tier')) 'Docs omit default service-tier binding.'
    Assert-CasInt ($docs.Contains('recovery.json')) 'Docs omit the distinct recovery artifact.'
    Assert-CasInt ($docs.Contains('callback_write_phase') -or $docs.Contains('run.json')) 'Docs omit run.json phase authority.'
    Assert-CasInt ($docs.ToLowerInvariant().Contains('diagnostic') -or $docs.Contains('transitions.jsonl')) 'Docs omit diagnostic transitions.jsonl.'
    Assert-CasInt ($docs.Contains('userMessage')) 'Docs omit exact userMessage recovery input.'
    Assert-CasInt ($docs.Contains('clientId')) 'Docs omit generated userMessage clientId.'
    Assert-CasInt ($docs.Contains('text_elements')) 'Docs omit generated text_elements.'
    Assert-CasInt ($docs.Contains('terminal_publishing')) 'Docs omit terminal_publishing phase.'
    Assert-CasInt ($docs.Contains('terminal_target')) 'Docs omit terminal_target authority.'
    Assert-CasInt ($docs.Contains('launcher-result.json')) 'Docs omit launcher-result identity binding.'
    Assert-CasInt ($docs.Contains('writer-derived') -or $docs.Contains('history table')) 'Docs omit the writer-derived durable history table.'
    Assert-CasInt ($docs.Contains('TurnStartResponse') -or $docs.Contains('turn/start')) 'Docs omit exact turn/start response shape.'

    $boundProfile = (Read-TelephoneJson -Path $h1.profile -SchemaName 'codex-app-server-lead-profile').value
    Assert-CasInt ([string]$boundProfile.codex_command -ceq [IO.Path]::GetFullPath($mock)) 'Profile bound a Codex executable other than the mock.'
    $script:noProvider = 1

    [ordered]@{
        success = $true
        assertions = $assertions
        parse_check = $parseCheck
        thread_id_direct = $threadIdDirect
        restart_resume = $restartResume
        callback_once = $callbackOnce
        durable_create_same_process = $durableCreateSameProcess
        durable_create_restart_resume = $durableCreateRestartResume
        durable_create_fail_closed = $durableCreateFailClosed
        crash_before_write = $crashBeforeWrite
        crash_after_ambiguous_write = $crashAfterAmbiguousWrite
        crash_after_turn_bind = $crashAfterTurnBind
        crash_before_ack = $crashBeforeAck
        concurrency_once = $concurrencyOnce
        fail_closed_zero = $failClosedZero
        fail_closed_multiple = $failClosedMultiple
        fail_closed_unexplained = $failClosedUnexplained
        status_not_loaded = $statusNotLoaded
        status_idle = $statusIdle
        status_system_error = $statusSystemError
        status_active = $statusActive
        flag_waiting_on_approval = $flagApproval
        flag_waiting_on_user_input = $flagUserInput
        pending_projected = $pendingProjected
        status_observational = $statusObservational
        schema_mismatch = $schemaMismatch
        explicit_fallback = $explicitFallback
        automatic_fallback_absent = $automaticFallbackAbsent
        stdio_only = $stdioOnly
        experimental_excluded = $experimentalExcluded
        privacy_clean = $privacyClean
        no_provider = $noProvider
        denominator_eight = $denominatorEight
        durable_ack_before_terminal = $durableAckBeforeTerminal
        launcher_exit_same_turn = $launcherExitSameTurn
        appserver_death_same_turn = $appserverDeathSameTurn
        worker_death_same_turn = $workerDeathSameTurn
        callback_continuation_same_session = $callbackContinuationSameSession
        callback_continuation_mismatch_refused = $callbackContinuationMismatchRefused
        intent_mismatch_closed = $intentMismatchClosed
        marker_user_exact = $markerUserExact
        marker_echo_rejected = $markerEchoRejected
        pending_four_methods = $pendingFourMethods
        pending_unknown_ignored = $pendingUnknownIgnored
        pending_resolved_cleared = $pendingResolvedCleared
        stderr_drained = $stderrDrained
        fail_closed_empty = $failClosedEmpty
        official_completed = $officialCompleted
        official_failed = $officialFailed
        official_interrupted = $officialInterrupted
        recovery_required = $recoveryRequired
        quiet_read_survived = $quietReadSurvived
        no_concurrent_stdout_read = $noConcurrentStdoutRead
        no_absolute_turn_timeout = $noAbsoluteTurnTimeout
        cross_identity_ignored = $crossIdentityIgnored
        malformed_terminal_not_completed = $malformedTerminalNotCompleted
        chain_valid_recovered = $chainValidRecovered
        chain_orphan_ack_closed = $chainOrphanAckClosed
        chain_orphan_bound_closed = $chainOrphanBoundClosed
        chain_conflict_closed = $chainConflictClosed
        chain_terminal_without_chain_closed = $chainTerminalWithoutChainClosed
        chain_live_owner_bypass_closed = $chainLiveOwnerBypassClosed
        f01_stable_protocol = $f01StableProtocol
        f02_durable_chain = $f02DurableChain
        f02_illegal_recovery_history = $f02IllegalRecoveryHistory
        f02_illegal_failure_history = $f02IllegalFailureHistory
        f02_legal_recovery_history = $f02LegalRecoveryHistory
        f02_legal_failure_history = $f02LegalFailureHistory
        f02_writer_observed_count = $f02WriterObservedCount
        f02_table_count = $f02TableCount
        f02_expected_count = $f02ExpectedCount
        f02_missing_rows = $f02MissingRows
        f02_extra_rows = $f02ExtraRows
        f02_duplicate_rows = $f02DuplicateRows
        f02_r5_prebind_recovery_preserved = $f02R5PrebindRecoveryPreserved
        f02_r5_terminal_publishing_preserved = $f02R5TerminalPublishingPreserved
        f02_raw_observation_count = $f02RawObservationCount
        f02_submitted_count = $f02SubmittedCount
        f02_writer_unique_count = $f02WriterUniqueCount
        f02_production_duplicate_count = $f02ProductionDuplicateCount
        f02_duplicate_provenance = @($f02DuplicateProvenance)
        f02_tuple_provenance = @($f02TupleProvenance)
        f02_closed_accounting = $f02ClosedAccounting
        f02_capture_filter_absent = $f02CaptureFilterAbsent
        f02_owner_local_dedupe_absent = $f02OwnerLocalDedupeAbsent
        f02_same_key_byte_observation = $f02SameKeyByteObservation
        f02_changed_key_recovery_observation = $f02ChangedKeyRecoveryObservation
        f02_duplicate_probe = $f02DuplicateProbe
        f02_duplicate_probe_provenance = @($f02DuplicateProbeProvenance)
        f02_per_call_raw = @($f02PerCallRaw)
        f02_independent_expected_count = $f02IndependentExpectedCount
        f02_r6_recover_forward_turn_bound_crash = $f02R6RecoverForwardTurnBoundCrash
        f02_r6_recover_forward_in_progress_crash = $f02R6RecoverForwardInProgressCrash
        f02_r6_recover_forward_repeat_terminal = $f02R6RecoverForwardRepeatTerminal
        f02_r6_recover_forward_publishing_crash = $f02R6RecoverForwardPublishingCrash
        f02_r7_recovery_commit_lifecycle = $f02R7RecoveryCommitLifecycle
        f02_r7_marker_prebind_recovery = $f02R7MarkerPrebindRecovery
        f02_r7_successive_recovery_crashes = $f02R7SuccessiveRecoveryCrashes
        f02_r7_recovered_failed = $f02R7RecoveredFailed
        f02_r7_recovered_interrupted = $f02R7RecoveredInterrupted
        f02_r7_unfiltered_writer_equality = $f02R7UnfilteredWriterEquality
        f02_r8_independent_oracle = $f02R8IndependentOracle
        f02_r8_writer_scoped_cuts = $f02R8WriterScopedCuts
        f02_r8_process_death_cuts = $f02R8ProcessDeathCuts
        f02_r8_cut_results = @($f02R8CutResults)
        f02_scenario_count = $f02ScenarioCount
        f02_scenario_names = @($f02ScenarioNames)
        f02_writer_observed_rows = @($f02WriterObservedRows)
        f02_table_rows = @($f02TableRows)
        f03_atomic_publish = $f03AtomicPublish
        f03_crash_before_terminal_intent = $f03CrashBeforeTerminalIntent
        f03_crash_after_terminal_intent = $f03CrashAfterTerminalIntent
        f03_crash_after_terminal_final = $f03CrashAfterTerminalFinal
        f03_crash_after_terminal_bound = $f03CrashAfterTerminalBound
        f03_crash_after_terminal_run = $f03CrashAfterTerminalRun
        f03_crash_after_terminal_result = $f03CrashAfterTerminalResult
        f04_service_tier_default = $f04ServiceTierDefault
        f05_compatibility_identity = $f05CompatibilityIdentity
        f06_status_containment = $f06StatusContainment
        f07_public_error_privacy = $f07PublicErrorPrivacy
        nondefault_turn_starts = $nondefaultTurnStarts
        privacy_needle_hits = $privacyNeedleHits
    } | ConvertTo-Json -Depth 16 -Compress
} catch {
    $caughtError = $_
    $lastInvocationDiagnostic = $null
    if ($null -ne $script:casIntLastInvocation) {
        try {
            $lastResult = $script:casIntLastInvocation.result
            if ($null -eq $lastResult) { $lastResult = [ordered]@{ exit_code = -1 } }
            $lastInvocationDiagnostic = [ordered]@{
                kind = [string]$script:casIntLastInvocation.kind
                run_id = [string]$script:casIntLastInvocation.run_id
                thread_id = [string]$script:casIntLastInvocation.thread_id
                state = Get-CasIntDurableCreateFailureDiagnostic -Harness $script:casIntLastInvocation.harness -RunId ([string]$script:casIntLastInvocation.run_id) -Result $lastResult
            }
        } catch {
            $lastInvocationDiagnostic = [ordered]@{ kind = 'diagnostic'; run_id = ''; thread_id = ''; state = [ordered]@{ diagnostic_error = 'categorical_read_failed' } }
        }
    }
    [ordered]@{
        success = $false
        error = [string]$caughtError.Exception.Message
        script_stack = [string]$caughtError.ScriptStackTrace
        assertions = $assertions
        last_invocation_diagnostic = $lastInvocationDiagnostic
    } | ConvertTo-Json -Depth 16 -Compress
    exit 1
} finally {
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY', $script:PreviousDashboardProcessEnvOnly, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_OPT_OUT', $script:PreviousDashboardOptOut, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_STATE', $script:PreviousDashboardState, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_DASHBOARD_HEADLESS', $script:PreviousDashboardHeadless, 'Process')
    foreach ($name in @(
        'TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT', 'TELEPHONE_TEST_APP_SERVER_LEAD_THROW_AT', 'TELEPHONE_TEST_APP_SERVER_CRASH_AT',
        'TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS', 'TELEPHONE_TEST_APP_SERVER_SCHEMA_EXTRA',
        'TELEPHONE_TEST_APP_SERVER_STATUS', 'TELEPHONE_TEST_APP_SERVER_ACTIVE_FLAGS',
        'TELEPHONE_TEST_APP_SERVER_PENDING_METHOD', 'TELEPHONE_TEST_APP_SERVER_PENDING_ID',
        'TELEPHONE_TEST_APP_SERVER_PENDING_METHODS', 'TELEPHONE_TEST_APP_SERVER_POST_START_SEQUENCE',
        'TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH', 'TELEPHONE_TEST_APP_SERVER_EVENT_LOG',
        'TELEPHONE_TEST_APP_SERVER_RESOLVE_PENDING', 'TELEPHONE_TEST_APP_SERVER_STDERR_SECRET',
        'TELEPHONE_TEST_APP_SERVER_STDERR_BYTES', 'TELEPHONE_TEST_APP_SERVER_PENDING_SECRET',
        'TELEPHONE_TEST_APP_SERVER_ERROR_SECRET', 'TELEPHONE_TEST_APP_SERVER_HISTORY_SECRET',
        'TELEPHONE_TEST_CLI_FALLBACK_MARKER', 'TELEPHONE_TEST_APP_SERVER_TURN_STATUS',
        'TELEPHONE_TEST_APP_SERVER_POST_START_DELAY_MS', 'TELEPHONE_TEST_APP_SERVER_FORMER_READ_TIMEOUT_MS',
        'TELEPHONE_TEST_APP_SERVER_INJECT_FOREIGN', 'TELEPHONE_TEST_APP_SERVER_OMIT_THREAD_ID',
        'TELEPHONE_TEST_APP_SERVER_FOREIGN_THREAD_ID', 'TELEPHONE_TEST_APP_SERVER_OMIT_TURN_ID',
        'TELEPHONE_TEST_APP_SERVER_FOREIGN_TURN_ID', 'TELEPHONE_TEST_APP_SERVER_RETURN_TIER',
        'TELEPHONE_TEST_APP_SERVER_INHERITED_TIER', 'TELEPHONE_TEST_APP_SERVER_OMIT_SERVICE_TIER',
        'TELEPHONE_TEST_APP_SERVER_INJECT_PROTOCOL_NEGATIVES', 'TELEPHONE_TEST_APP_SERVER_PUBLISH_CRASH_AT',
        'TELEPHONE_TEST_APP_SERVER_SCHEMA_FAIL', 'TELEPHONE_TEST_APP_SERVER_VERSION_FAIL',
        'TELEPHONE_TEST_APP_SERVER_VERSION', 'TELEPHONE_TEST_APP_SERVER_UNWRAP_THREAD',
        'TELEPHONE_TEST_APP_SERVER_UNWRAP_TURN', 'TELEPHONE_TEST_APP_SERVER_TURN_START_EXTRA',
        'TELEPHONE_TEST_APP_SERVER_OMIT_WRAPPER_FIELD',
        'TELEPHONE_TEST_APP_SERVER_EMIT_OPTIONAL_0147', 'TELEPHONE_TEST_APP_SERVER_RETURN_NULL_TIER',
        'TELEPHONE_TEST_APP_SERVER_RETURN_EMPTY_TIER', 'TELEPHONE_TEST_APP_SERVER_UNKNOWN_WRAPPER_KEY',
        'TELEPHONE_TEST_APP_SERVER_UNKNOWN_THREAD_KEY', 'TELEPHONE_TEST_APP_SERVER_MALFORMED_OPTIONAL',
        'TELEPHONE_TEST_APP_SERVER_0147_COMPAT', 'TELEPHONE_TEST_APP_SERVER_PROJECT_ID_NULL',
        'TELEPHONE_TEST_APP_SERVER_ARCHIVED_RESUME_ONCE', 'TELEPHONE_TEST_APP_SERVER_ARCHIVED_RESUME_JSON_ONCE',
        'TELEPHONE_TEST_CODEX_COMMAND_LOG',
        'TELEPHONE_TEST_UNARCHIVE_EXIT', 'TELEPHONE_APP_SERVER_THREAD_STORE', 'TELEPHONE_TEST_APP_SERVER_STORE'
    )) {
        Remove-Item -Path ("env:$name") -ErrorAction SilentlyContinue
    }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
    if ($full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($full)) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
