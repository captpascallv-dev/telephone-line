# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'tests\adapters\AdapterTest.Common.ps1')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
$adapterCopy = Join-Path $testRoot 'adapter'
$outsideRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('TelephoneLineDirectCursorTest-' + [Guid]::NewGuid().ToString('N'))
$workspace = Join-Path $outsideRoot 'workspace'
$appDataWorkspace = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TelephoneLineDirectCursorTest-' + [Guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $testRoot 'state'
$promptPath = Join-Path $testRoot 'prompt.txt'
$writePromptPath = Join-Path $testRoot 'write-prompt.txt'
$counterPath = Join-Path $testRoot 'mock-count.txt'
$promptText = 'Return the transport nonce only: DIRECT-CURSOR-MOCK'
$powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

try {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    Copy-AdapterForTest -Source (Join-Path $repoRoot 'src\adapters\direct-cursor') -Destination $adapterCopy
    [IO.File]::WriteAllText($promptPath, $promptText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($writePromptPath, $promptText, [Text.UTF8Encoding]::new($false))

    $tokens = $null
    $parseErrors = $null
    $productionAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'src\adapters\direct-cursor\invoke_cursor_agent.ps1'), [ref]$tokens, [ref]$parseErrors)
    $canonicalizerAsts = @($productionAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'ConvertTo-StableCursorModelDisplay'
    }, $true))
    Assert-AdapterTest ($canonicalizerAsts.Count -eq 1 -and $parseErrors.Count -eq 0) 'Production canonicalizer is missing, duplicated, or unparsable.'
    . ([ScriptBlock]::Create($canonicalizerAsts[0].Extent.Text))
    $baseDisplay = 'Cursor Grok 4.6 Extra High'
    Assert-AdapterTest ([string]::Equals((ConvertTo-StableCursorModelDisplay -Display "  $baseDisplay  "), $baseDisplay, [StringComparison]::Ordinal)) 'Canonical stable display changed.'
    $emptyFailedClosed = $false
    try { $null = ConvertTo-StableCursorModelDisplay -Display '   ' } catch { $emptyFailedClosed = $true }
    Assert-AdapterTest $emptyFailedClosed 'Empty canonical model display did not fail closed.'

    $source = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-cursor\invoke_cursor_agent.ps1'))
    $routeSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-cursor\Invoke-DirectCursorRoute.ps1'))
    $routeDocs = [IO.File]::ReadAllText((Join-Path $repoRoot 'docs\adapters\direct-cursor.md'))
    Assert-AdapterTest ($source.Contains('Direct Cursor Fast mode is disabled.')) 'Fast-disabled guard is missing.'
    Assert-AdapterTest (-not $source.Contains('AllowFast.IsPresent')) 'Wrapper still treats Fast as an embeddable default.'
    Assert-AdapterTest ($routeSource.Contains('[int]$CursorTimeoutSeconds = 0') -and $routeSource.Contains('[int]$WaitTimeoutSeconds = 0')) 'Direct Cursor still ships a whole-task timeout default.'
    Assert-AdapterTest ($routeDocs.Contains('project-isolated `StateRoot`')) 'Direct Cursor docs do not distinguish the catalog StateRoot contract.'
    Assert-AdapterTest (-not $stateRoot.StartsWith($adapterCopy.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) 'Direct Cursor state-root regression fixture is not project-isolated from the adapter.'

    $mockWrapper = @'
# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkspacePath,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [string]$Mode,
    [string]$Model,
    [string]$ExpectedAccount,
    [string]$ExpectedSubscription,
    [string]$ResumeSessionId,
    [string]$SessionRoot,
    [string[]]$AllowedWritePath,
    [switch]$AllowWrite,
    [switch]$AllowFast,
    [string]$CursorAgentRoot,
    [int]$TimeoutSeconds,
    [int]$MaxOutputBytes
)
if ($AllowFast) { throw 'Direct Cursor Fast mode is disabled.' }
$count = if ([IO.File]::Exists($env:DIRECT_CURSOR_MOCK_COUNTER)) { [int][IO.File]::ReadAllText($env:DIRECT_CURSOR_MOCK_COUNTER) } else { 0 }
[IO.File]::WriteAllText($env:DIRECT_CURSOR_MOCK_COUNTER, [string]($count + 1), [Text.UTF8Encoding]::new($false))
$promptBytes = [IO.File]::ReadAllBytes($PromptFile)
$promptSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes)).ToLowerInvariant()
$session = if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) { $ResumeSessionId } else { 'cursor-native-' + [Guid]::NewGuid().ToString('N') }
[ordered]@{
    success = $true
    prompt_sha256 = $promptSha
    prompt = [ordered]@{ path = [IO.Path]::GetFullPath($PromptFile); bytes = [int64]$promptBytes.Length; sha256 = $promptSha }
    fast_disabled = $true
    model_id = $Model
    workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\')
    mode = $Mode
    allowed_write_paths = @($AllowedWritePath | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    session_id = $session
    resumed = -not [string]::IsNullOrWhiteSpace($ResumeSessionId)
} | ConvertTo-Json -Depth 8
'@
    [IO.File]::WriteAllText((Join-Path $adapterCopy 'invoke_cursor_agent.ps1'), $mockWrapper.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_COUNTER', $counterPath, 'Process')
    $invoke = Join-Path $adapterCopy 'Invoke-DirectCursorRoute.ps1'

    $jobId = [Guid]::NewGuid().ToString('D')
    $first = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $jobId, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($first.exit_code -eq 0) "Direct Cursor start failed: $($first.stderr) $($first.stdout)"
    Assert-AdapterTest ($first.value.transport_complete -eq $true) 'Start was not transport complete.'
    Assert-AdapterTest ($first.value.fast_disabled -eq $true) 'Fast was not disabled.'
    Assert-AdapterTest (-not [string]::IsNullOrWhiteSpace([string]$first.value.native_session_id)) 'Start did not capture a native session id.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '1') 'Start did not execute the mock once.'
    Assert-NoPromptBody -RequestPath (Join-Path $stateRoot ("jobs\$jobId\request.json")) -PromptText $promptText
    $request = Get-Content -LiteralPath (Join-Path $stateRoot ("jobs\$jobId\request.json")) -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ($request.allow_fast -eq $false) 'Request did not freeze Fast disabled.'
    Assert-AdapterTest (@($request.allowed_write_paths).Count -eq 0) 'ReadOnly carried a write scope.'

    $session = [string]$first.value.native_session_id
    $followJob = [Guid]::NewGuid().ToString('D')
    $follow = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-JobId', $followJob, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($follow.exit_code -eq 0) "Follow-up failed: $($follow.stderr)"
    Assert-AdapterTest ([string]$follow.value.native_session_id -ceq $session) 'Follow-up used another native session id.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Follow-up did not execute once.'

    $wrong = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', 'wrong-session', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-JobId', ([Guid]::NewGuid().ToString('D')), '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($wrong.exit_code -ne 0) 'Wrong native session id was accepted.'

    $missing = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-StateRoot', $stateRoot
    )
    Assert-AdapterTest ($missing.exit_code -ne 0) 'Recover without a native session id was accepted.'

    $recovered = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($recovered.exit_code -eq 0) "Recover failed: $($recovered.stderr)"
    Assert-AdapterTest ($recovered.value.replacement_started -eq $false) 'Recover started a replacement process.'
    Assert-AdapterTest ($recovered.value.automatic_rerun -eq $false) 'Recover advertised automatic rerun.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Recover reran Cursor.'

    $duplicate = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $jobId, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($duplicate.exit_code -eq 0) 'Duplicate start was not directed to existing state.'
    Assert-AdapterTest ($duplicate.value.automatic_rerun -eq $false) 'Duplicate start reran.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Duplicate start executed the mock again.'

    $writeDir = Join-Path $workspace 'allowed'
    [IO.Directory]::CreateDirectory($writeDir) | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace '.git'), "gitdir: /nonexistent-test-gitdir`n", [Text.UTF8Encoding]::new($false))
    $writeJob = [Guid]::NewGuid().ToString('D')
    $write = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $writePromptPath,
        '-Mode', 'Write', '-AllowedWritePath', 'allowed', '-JobId', $writeJob, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($write.exit_code -eq 0) "Write-scope start failed: $($write.stderr)"
    $writeRequest = Get-Content -LiteralPath (Join-Path $stateRoot ("jobs\$writeJob\request.json")) -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest (@($writeRequest.allowed_write_paths) -contains 'allowed') 'Write allowlist was not persisted.'
    Assert-AdapterTest ($writeRequest.allow_fast -eq $false) 'Write request enabled Fast.'

    $readonlyWrite = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-AllowedWritePath', 'allowed', '-JobId', ([Guid]::NewGuid().ToString('D')), '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($readonlyWrite.exit_code -ne 0) 'ReadOnly accepted a write allowlist.'

    $agentSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-cursor\invoke_cursor_agent.ps1'))
    $routeEntrySource = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-cursor\Invoke-DirectCursorRoute.ps1'))
    Assert-AdapterTest ($agentSource.Contains('Get-DirectPublicError')) 'Direct Cursor still writes raw exception text.'
    Assert-AdapterTest (-not $agentSource.Contains('error = $_.Exception.Message')) 'Direct Cursor catch still copies Exception.Message.'
    Assert-AdapterTest ($agentSource.Contains('failure_stage') -and $agentSource.Contains('failure_code')) 'Direct Cursor failure result is not typed by stage and code.'
    Assert-AdapterTest ($routeEntrySource.Contains("Get-DirectNoteValue -Object `$cursorResult -Name 'prompt'")) 'Adapter result still dereferences optional failure prompt fields.'

    $sentinels = New-AdapterRuntimeSentinels
    $failWrapper = @'
# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkspacePath,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [string]$Mode,
    [string]$Model,
    [string]$ExpectedAccount,
    [string]$ExpectedSubscription,
    [string]$ResumeSessionId,
    [string]$SessionRoot,
    [string[]]$AllowedWritePath,
    [switch]$AllowWrite,
    [switch]$AllowFast,
    [string]$CursorAgentRoot,
    [int]$TimeoutSeconds,
    [int]$MaxOutputBytes
)
. (Join-Path $PSScriptRoot 'DirectCursor.Common.ps1')
$promptBytes = [IO.File]::ReadAllBytes($PromptFile)
$promptSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes)).ToLowerInvariant()
try { throw [string]$env:DIRECT_CURSOR_FAIL_TEXT } catch {
    [ordered]@{
        success = $false
        prompt_sha256 = $promptSha
        prompt = [ordered]@{ path = [IO.Path]::GetFullPath($PromptFile); bytes = [int64]$promptBytes.Length; sha256 = $promptSha }
        failure_kind = 'transport'
        failure_code = 'cursor_model_capacity'
        failure_stage = 'cursor_execution'
        error = Get-DirectPublicError -ErrorCode 'DIRECT_CURSOR_MODEL_CAPACITY'
        workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\')
        mode = $Mode
        model_id = $Model
        allowed_write_paths = @($AllowedWritePath | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        fast_disabled = $true
        session_id = ''
    } | ConvertTo-Json -Depth 8
    exit 1
}
'@
    [IO.File]::WriteAllText((Join-Path $adapterCopy 'invoke_cursor_agent.ps1'), $failWrapper.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_FAIL_TEXT', ($sentinels.prompt + ' ' + $sentinels.email + ' ' + $sentinels.path + ' ' + $sentinels.key), 'Process')
    $failState = Join-Path $testRoot 'fail-state'
    $failJob = [Guid]::NewGuid().ToString('D')
    $failed = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $failState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $failJob, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($failed.exit_code -eq 2) 'Forced Cursor failure did not return the typed adapter-failure exit.'
    Assert-AdapterTest ([string]$failed.value.protocol_version -ceq 'telephone-line-adapter-result-v1') 'Forced failure did not return adapter-result JSON.'
    Assert-AdapterTest ([string]$failed.value.failure_kind -ceq 'transport') 'Forced failure lost failure_kind.'
    Assert-AdapterTest ([string]$failed.value.failure_code -ceq 'cursor_model_capacity') 'Forced failure lost the safe root cause.'
    Assert-AdapterTest ([string]$failed.value.failure_stage -ceq 'cursor_execution') 'Forced failure lost the failing stage.'
    Assert-AdapterTest ([string]$failed.value.prompt.sha256 -ceq (Get-FileHash -LiteralPath $promptPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'Forced failure lost prompt identity.'
    Assert-AdapterTest ([string]$failed.value.transport_error -ceq 'Direct Cursor selected model is temporarily at capacity.') 'Forced failure did not preserve the public transport classification.'
    Assert-AdapterTest ([string]::IsNullOrWhiteSpace([string]$failed.stderr)) 'Forced failure still crashed through stderr.'
    $failCount = Get-AdapterArtifactSentinelCount -Root $failState -Sentinels @($sentinels.prompt, $sentinels.email, $sentinels.path, $sentinels.key)
    Assert-AdapterTest ($failCount -eq 0) 'Direct Cursor durable failure artifacts retained a synthetic sentinel.'
    $baselineAssertions = $assertions
    Assert-AdapterTest ($baselineAssertions -eq 46) "Direct Cursor baseline assertion count drifted: $baselineAssertions"

    . (Join-Path $repoRoot 'src\adapters\direct-cursor\DirectCursor.Common.ps1')
    $namedCounts = [ordered]@{
        verify_command_capable_nonmutating = 0
        verify_mutation_fail_closed = 0
        scope_violation_evidence_preserved = 0
        scope_violation_transport_complete = 0
        preflight_valid_no_launch = 0
        preflight_all_blockers = 0
        preflight_observed_state_read_only = 0
        preflight_launch_parity = 0
        legacy_modes_recovery_preserved = 0
        sensitive_output_absent = 0
        terminal_validation_precedes_policy = 0
        preflight_probe_trust_bound = 0
        policy_recover_operation_exact = 0
        preflight_sensitive_root_parity = 0
        qualified_job_host_blocker = 0
        launch_gate_revalidation = 0
        missing_session_failure = 0
        runtime_volatile_snapshot = 0
    }
    function Assert-Named {
        param([string]$Name, [bool]$Condition, [string]$Message)
        Assert-AdapterTest -Condition $Condition -Message $Message
        $namedCounts[$Name] += 1
    }

    $volatileWorkspace = Join-Path $outsideRoot 'volatile-workspace'
    $volatileRuntime = Join-Path $volatileWorkspace 'runtime'
    [IO.Directory]::CreateDirectory($volatileRuntime) | Out-Null
    & git -C $volatileWorkspace init --quiet
    [IO.File]::WriteAllText((Join-Path $volatileWorkspace '.gitignore'), "runtime/`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $volatileWorkspace 'stable.txt'), 'stable', [Text.UTF8Encoding]::new($false))
    $lockedIgnored = Join-Path $volatileRuntime 'active.log'
    [IO.File]::WriteAllText($lockedIgnored, 'runtime', [Text.UTF8Encoding]::new($false))
    $ignoredLock = [IO.File]::Open($lockedIgnored, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $volatileRows = @()
        $volatileSnapshot = Get-DirectWorkspaceSnapshot -Root $volatileWorkspace -AllowedWriteRelative @() -VolatileExclusions ([ref]$volatileRows)
        Assert-Named 'runtime_volatile_snapshot' ($volatileRows.Count -eq 1) 'Locked ignored runtime file was not recorded as one exclusion.'
        Assert-Named 'runtime_volatile_snapshot' ([string]$volatileRows[0].path -ceq 'runtime/active.log') 'Locked runtime exclusion path drifted.'
        Assert-Named 'runtime_volatile_snapshot' ([string]$volatileRows[0].reason -ceq 'locked_gitignored_nonlease_runtime_file') 'Locked runtime exclusion reason drifted.'
        Assert-Named 'runtime_volatile_snapshot' ([string]$volatileSnapshot['runtime/active.log'] -ceq 'file:volatile=locked_gitignored_nonlease:reparse=0') 'Locked runtime snapshot placeholder drifted.'
        $leasedLockedFailed = $false
        try { $null = Get-DirectWorkspaceSnapshot -Root $volatileWorkspace -AllowedWriteRelative @('runtime/active.log') } catch { $leasedLockedFailed = $true }
        Assert-Named 'runtime_volatile_snapshot' $leasedLockedFailed 'Locked file inside the declared write lease was silently excluded.'
    } finally {
        $ignoredLock.Dispose()
    }
    $lockedUnignored = Join-Path $volatileWorkspace 'locked-unignored.log'
    [IO.File]::WriteAllText($lockedUnignored, 'locked', [Text.UTF8Encoding]::new($false))
    $unignoredLock = [IO.File]::Open($lockedUnignored, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $unignoredFailed = $false
        try { $null = Get-DirectWorkspaceSnapshot -Root $volatileWorkspace } catch { $unignoredFailed = $true }
        Assert-Named 'runtime_volatile_snapshot' $unignoredFailed 'Locked non-ignored file was silently excluded.'
    } finally {
        $unignoredLock.Dispose()
    }
    $trackedIgnoredDirectory = Join-Path $volatileWorkspace 'tracked-runtime'
    [IO.Directory]::CreateDirectory($trackedIgnoredDirectory) | Out-Null
    $lockedTrackedIgnored = Join-Path $trackedIgnoredDirectory 'tracked.log'
    [IO.File]::WriteAllText($lockedTrackedIgnored, 'tracked-runtime', [Text.UTF8Encoding]::new($false))
    & git -C $volatileWorkspace add -f -- 'tracked-runtime/tracked.log'
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the tracked-ignore snapshot fixture.' }
    [IO.File]::AppendAllText((Join-Path $volatileWorkspace '.gitignore'), "tracked-runtime/`n", [Text.UTF8Encoding]::new($false))
    $trackedIgnoredLock = [IO.File]::Open($lockedTrackedIgnored, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $trackedIgnoredFailed = $false
        try { $null = Get-DirectWorkspaceSnapshot -Root $volatileWorkspace } catch { $trackedIgnoredFailed = $true }
        Assert-Named 'runtime_volatile_snapshot' $trackedIgnoredFailed 'Locked tracked file matching an ignore rule was silently excluded.'
    } finally {
        $trackedIgnoredLock.Dispose()
    }
    Assert-Named 'runtime_volatile_snapshot' ((Get-DirectCursorPreflightCheckCodes) -contains 'workspace_snapshot_qualification') 'Preflight omitted workspace snapshot qualification.'

    $dualMock = @'
# SPDX-License-Identifier: MPL-2.0
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true)][string]$WorkspacePath,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)][string]$PromptFile,
    [Parameter(ParameterSetName = 'QualifiedProbe')][switch]$QualifiedProbe,
    [string]$Mode,
    [string]$Model,
    [string]$ExpectedAccount,
    [string]$ExpectedSubscription,
    [string]$ResumeSessionId,
    [string]$SessionRoot,
    [string[]]$AllowedWritePath,
    [switch]$AllowWrite,
    [switch]$AllowFast,
    [string]$CursorAgentRoot,
    [int]$TimeoutSeconds,
    [int]$MaxOutputBytes
)
if ($AllowFast) { throw 'Direct Cursor Fast mode is disabled.' }
if ($QualifiedProbe) {
    $probeMode = [string]$env:DIRECT_CURSOR_MOCK_PROBE
    $facts = [ordered]@{
        protocol_version = 'telephone-line-direct-cursor-qualified-probe-v1'
        wrapper_present = $true
        wrapper_identity_match = $true
        index_present = $true
        index_identity_match = $true
        node_present = $true
        node_identity_match = $true
        job_host_present = $true
        job_host_identity_match = $true
        cli_version_match = $true
        account_bound = $true
        subscription_bound = $true
        model_available = $true
    }
    if ([string]::IsNullOrWhiteSpace($probeMode) -or $probeMode -ceq 'valid') {
        $facts | ConvertTo-Json -Depth 6
        exit 0
    }
    if ($probeMode -ceq 'malformed') { '<<<not-json>>>'; exit 0 }
    if ($probeMode -ceq 'incomplete') {
        $facts.Remove('account_bound')
        $facts.Remove('subscription_bound')
        $facts.Remove('model_available')
        $facts | ConvertTo-Json -Depth 6
        exit 0
    }
    if ($probeMode -ceq 'wrong-protocol') {
        $facts.protocol_version = 'telephone-line-direct-cursor-qualified-probe-v0'
        $facts | ConvertTo-Json -Depth 6
        exit 0
    }
    if ($probeMode -ceq 'wrong-case') {
        $renamed = [ordered]@{}
        foreach ($key in @($facts.Keys)) {
            if ($key -ceq 'protocol_version') { $renamed['Protocol_Version'] = $facts[$key] }
            else { $renamed[$key] = $facts[$key] }
        }
        $renamed | ConvertTo-Json -Depth 6
        exit 0
    }
    if ($probeMode -ceq 'non-boolean') {
        $facts.account_bound = 'true'
        $facts | ConvertTo-Json -Depth 6
        exit 0
    }
    if ($probeMode -ceq 'extra-key') {
        $facts['command_line'] = 'cursor-agent'
        $facts | ConvertTo-Json -Depth 6
        exit 0
    }
    if ($probeMode -ceq 'false-binding') {
        $facts.account_bound = $false
        $facts.subscription_bound = $false
        $facts.model_available = $false
        $facts | ConvertTo-Json -Depth 6
        exit 0
    }
    '{"error":"unknown-mock-probe-mode"}'
    exit 1
}
$launchGate = [string]$env:DIRECT_CURSOR_MOCK_LAUNCH_GATE
if ($launchGate -ceq 'models-fail') { throw 'Cursor model catalog probe failed.' }
if ($launchGate -ceq 'models-missing') { throw 'Requested Cursor model is not available.' }
if ($launchGate -ceq 'subscription' -and -not [string]::IsNullOrWhiteSpace([string]$ExpectedSubscription)) {
    throw 'Cursor subscription does not match the caller-supplied expected identity.'
}
$count = if ([IO.File]::Exists($env:DIRECT_CURSOR_MOCK_COUNTER)) { [int][IO.File]::ReadAllText($env:DIRECT_CURSOR_MOCK_COUNTER) } else { 0 }
[IO.File]::WriteAllText($env:DIRECT_CURSOR_MOCK_COUNTER, [string]($count + 1), [Text.UTF8Encoding]::new($false))
$promptBytes = [IO.File]::ReadAllBytes($PromptFile)
$promptSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes)).ToLowerInvariant()
$session = if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) { $ResumeSessionId } else { 'cursor-native-' + [Guid]::NewGuid().ToString('N') }
$allowed = @()
if ($null -ne $AllowedWritePath) {
    $allowed = @($AllowedWritePath | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}
$summary = [ordered]@{
    success = $true
    dispatch_id = [Guid]::NewGuid().ToString('D')
    prompt_sha256 = $promptSha
    prompt = [ordered]@{ path = [IO.Path]::GetFullPath($PromptFile); bytes = [int64]$promptBytes.Length; sha256 = $promptSha }
    fast_disabled = $true
    model_id = $Model
    model_display = 'Cursor Grok 4.6 Extra High'
    workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\')
    mode = $Mode
    allowed_write_paths = $allowed
    session_id = $session
    resumed = -not [string]::IsNullOrWhiteSpace($ResumeSessionId)
    result = 'DIRECT-CURSOR-MOCK'
    usage = [ordered]@{ inputTokens = 1; outputTokens = 1 }
    duration_ms = 1
    changed_files = @()
}
if ($env:DIRECT_CURSOR_MOCK_POLICY -ceq 'write_scope') {
    $summary.success = $false
    $summary.result = 'SCOPE-NONCE-XYZ'
    $summary.usage = [ordered]@{ inputTokens = 3; outputTokens = 5 }
    $summary.failure_kind = 'policy'
    $summary.failure_code = 'write_scope_violation'
    $summary.violating_paths = @('secret.txt')
    $summary.changed_files = @(
        [ordered]@{ path = 'allowed/ok.txt'; change = 'added' },
        [ordered]@{ path = 'secret.txt'; change = 'added' }
    )
    $summary.evidence = [ordered]@{
        agent_result = 'available'
        usage = 'available'
        session = 'available'
        model = 'available'
        changed_files = 'available'
        exit_status = 'available'
        stderr = 'empty'
    }
    $summary.cursor_exit_code = 0
    $summary.stderr_present = $false
}
if ($env:DIRECT_CURSOR_MOCK_POLICY -ceq 'verify_mutation') {
    $summary.success = $false
    $summary.result = 'VERIFY-NONCE'
    $summary.usage = [ordered]@{ inputTokens = 4; outputTokens = 6 }
    $summary.failure_kind = 'policy'
    $summary.failure_code = 'verify_workspace_mutated'
    $summary.violating_paths = @('touched.txt')
    $summary.changed_files = @(
        [ordered]@{ path = 'touched.txt'; change = 'added' }
    )
    $summary.evidence = [ordered]@{
        agent_result = 'available'
        usage = 'available'
        session = 'available'
        model = 'available'
        changed_files = 'available'
        exit_status = 'available'
        stderr = 'empty'
    }
    $summary.cursor_exit_code = 0
    $summary.stderr_present = $false
}
$summary | ConvertTo-Json -Depth 8
'@
    [IO.File]::WriteAllText((Join-Path $adapterCopy 'invoke_cursor_agent.ps1'), $dualMock.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($counterPath, '2', [Text.UTF8Encoding]::new($false))

    $missingSessionWrapper = @'
# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkspacePath,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [string]$Mode,
    [string]$Model,
    [string]$ExpectedAccount,
    [string]$ExpectedSubscription,
    [string]$ResumeSessionId,
    [string]$SessionRoot,
    [string[]]$AllowedWritePath,
    [switch]$AllowWrite,
    [switch]$AllowFast,
    [string]$CursorAgentRoot,
    [int]$TimeoutSeconds,
    [int]$MaxOutputBytes
)
. (Join-Path $PSScriptRoot 'DirectCursor.Common.ps1')
$promptBytes = [IO.File]::ReadAllBytes($PromptFile)
$promptSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes)).ToLowerInvariant()
    [ordered]@{
        success = $false
        prompt_sha256 = $promptSha
        failure_kind = 'transport'
        failure_code = 'adapter_transport_failure'
        failure_stage = 'cursor_execution'
        error = 'cursor-missing-session-failure'
    workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\')
    mode = $Mode
    model_id = $Model
    allowed_write_paths = @($AllowedWritePath | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    fast_disabled = $true
} | ConvertTo-Json -Depth 8
exit 1
'@
    [IO.File]::WriteAllText((Join-Path $adapterCopy 'invoke_cursor_agent.ps1'), $missingSessionWrapper.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    $missingState = Join-Path $testRoot 'missing-session-state'
    $missingJob = [Guid]::NewGuid().ToString('D')
    $missing = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $missingState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $missingJob, '-WaitTimeoutSeconds', '60'
    )
    Assert-Named 'missing_session_failure' ($missing.exit_code -eq 2) 'Missing-session failure did not return the typed adapter-failure exit.'
    Assert-Named 'missing_session_failure' ([string]$missing.value.failure_code -ceq 'adapter_transport_failure') 'Missing-session adapter result lost failure_code.'
    Assert-Named 'missing_session_failure' ([string]$missing.value.failure_stage -ceq 'cursor_execution') 'Missing-session adapter result lost failure_stage.'
    Assert-Named 'missing_session_failure' (-not $missing.value.PSObject.Properties['prompt']) 'Legacy missing-prompt failure invented a prompt object.'
    Assert-Named 'missing_session_failure' (-not [string]::IsNullOrWhiteSpace([string]$missing.value.prompt_sha256)) 'Legacy missing-prompt failure lost prompt_sha256.'
    Assert-Named 'missing_session_failure' ([string]::IsNullOrWhiteSpace([string]$missing.stderr)) 'Legacy missing-prompt failure still crashed through stderr.'
    $missingReceiptPath = Join-Path $missingState ("jobs\$missingJob\receipt.json")
    Assert-Named 'missing_session_failure' ([IO.File]::Exists($missingReceiptPath)) 'Missing-session failure did not publish a durable receipt.'
    $missingReceipt = (Read-DirectJson -Path $missingReceiptPath).value
    Assert-Named 'missing_session_failure' ($missingReceipt.transport_complete -eq $false) 'Missing-session receipt set transport_complete.'
    Assert-Named 'missing_session_failure' ($missingReceipt.cursor_success -eq $false) 'Missing-session receipt did not keep cursor_success=false.'
    Assert-Named 'missing_session_failure' ([string]$missingReceipt.native_session_id -ceq '') 'Missing-session receipt invented a native session id.'
    Assert-Named 'missing_session_failure' ($null -ne $missingReceipt.cursor_result -and $missingReceipt.cursor_result.success -eq $false) 'Missing-session receipt dropped the failure result.'
    Assert-Named 'missing_session_failure' ($missingReceipt.cursor_result.Contains('error') -and -not [string]::IsNullOrWhiteSpace([string]$missingReceipt.cursor_result.error)) 'Missing-session receipt dropped the preserved error.'
    Assert-Named 'missing_session_failure' ($missingReceipt.automatic_rerun -eq $false) 'Missing-session receipt advertised automatic rerun.'
    Assert-Named 'missing_session_failure' (-not $missingReceipt.cursor_result.Contains('session_id')) 'Missing-session fixture accidentally included session_id.'
    [IO.File]::WriteAllText((Join-Path $adapterCopy 'invoke_cursor_agent.ps1'), $dualMock.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($counterPath, '2', [Text.UTF8Encoding]::new($false))

    $verifyAuthority = Resolve-DirectCursorModeAuthority -Mode Verify -AllowWrite $false -AllowedWritePath @() -WorkspacePath $workspace
    $writeAuthority = Resolve-DirectCursorModeAuthority -Mode Write -AllowWrite $true -AllowedWritePath @('allowed') -WorkspacePath $workspace
    $readAuthority = Resolve-DirectCursorModeAuthority -Mode ReadOnly -AllowWrite $false -AllowedWritePath @() -WorkspacePath $workspace
    $verifyCli = @(Get-DirectCursorCliInvocationArgs -Authority $verifyAuthority)
    $writeCli = @(Get-DirectCursorCliInvocationArgs -Authority $writeAuthority)
    $readCli = @(Get-DirectCursorCliInvocationArgs -Authority $readAuthority)
    Assert-Named 'verify_command_capable_nonmutating' ($true -eq $verifyAuthority.command_capable) 'Verify is not command-capable.'
    Assert-Named 'verify_command_capable_nonmutating' ($false -eq $verifyAuthority.allow_write) 'Verify carried a write grant.'
    Assert-Named 'verify_command_capable_nonmutating' (@($verifyAuthority.allowed_write_paths).Count -eq 0) 'Verify carried a write scope.'
    Assert-Named 'verify_command_capable_nonmutating' ($false -eq $verifyAuthority.requires_linked_worktree) 'Verify required a linked-worktree leaf.'
    Assert-Named 'verify_command_capable_nonmutating' (($verifyCli -join ' ') -ceq ($writeCli -join ' ')) 'Verify did not share the Write command-capable CLI branch.'
    Assert-Named 'verify_command_capable_nonmutating' (($verifyCli -join ' ') -cne ($readCli -join ' ')) 'Verify mapped onto the ReadOnly ask branch.'
    Assert-Named 'verify_command_capable_nonmutating' (($verifyCli -join ' ') -ceq '--force') 'Verify CLI branch was not --force.'
    $runtimeText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-cursor\invoke_cursor_agent.ps1'))
    Assert-Named 'verify_command_capable_nonmutating' ($runtimeText -match 'Resolve-DirectCursorModeAuthority') 'Runtime does not call the shared mode authority resolver.'
    Assert-Named 'verify_command_capable_nonmutating' ($runtimeText -match 'Get-DirectCursorCliInvocationArgs') 'Runtime does not call the shared CLI invocation helper.'
    Assert-Named 'verify_command_capable_nonmutating' ($runtimeText -match 'Complete-DirectCursorAgentRun') 'Runtime does not call the shared terminal completion helper.'

    $verifyBefore = Get-DirectWorkspaceSnapshot -Root $workspace
    $verifyJob = [Guid]::NewGuid().ToString('D')
    $verify = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'Verify', '-JobId', $verifyJob, '-WaitTimeoutSeconds', '60'
    )
    Assert-Named 'verify_command_capable_nonmutating' ($verify.exit_code -eq 0) "Verify start failed: $($verify.stderr)"
    Assert-Named 'verify_command_capable_nonmutating' ($verify.value.transport_complete -eq $true) 'Verify start was not transport complete.'
    Assert-Named 'verify_command_capable_nonmutating' ($verify.value.cursor_success -eq $true) 'Verify start did not return cursor_success.'
    Assert-Named 'verify_command_capable_nonmutating' ([IO.File]::ReadAllText($counterPath) -ceq '3') 'Verify did not execute exactly once after the baseline dispatch.'
    $verifyRequest = Get-Content -LiteralPath (Join-Path $stateRoot ("jobs\$verifyJob\request.json")) -Raw | ConvertFrom-Json -AsHashtable
    Assert-Named 'verify_command_capable_nonmutating' ([string]$verifyRequest.mode -ceq 'Verify') 'Verify request did not persist mode Verify.'
    Assert-Named 'verify_command_capable_nonmutating' ($verifyRequest.allow_write -eq $false) 'Verify request carried write authority.'
    Assert-Named 'verify_command_capable_nonmutating' (@($verifyRequest.allowed_write_paths).Count -eq 0) 'Verify request carried declared write paths.'
    $verifyAfter = Get-DirectWorkspaceSnapshot -Root $workspace
    Assert-Named 'verify_command_capable_nonmutating' (@(Compare-DirectWorkspaceSnapshot -Before $verifyBefore -After $verifyAfter).Count -eq 0) 'Verify mutated the workspace.'
    Assert-Named 'verify_command_capable_nonmutating' (@(Compare-DirectWorkspaceSnapshot -Before $verifyAfter -After (Get-DirectWorkspaceSnapshot -Root $workspace)).Count -eq 0) 'Verify left a workspace delta.'

    $ndjson = @(
        '{"type":"system","subtype":"init","apiKeySource":"login","cwd":"C:\\verify-ws","model":"Cursor Grok 4.6 Extra High","session_id":"sess-verify"}',
        '{"type":"result","subtype":"success","is_error":false,"session_id":"sess-verify","result":"VERIFY-NONCE","usage":{"inputTokens":4,"outputTokens":6}}'
    ) -join "`n"
    $verifyCompleted = Complete-DirectCursorAgentRun -Mode Verify -Workspace 'C:\verify-ws' -AllowedWriteRelative @() -Run ([pscustomobject]@{ ExitCode = 0; Stdout = $ndjson; Stderr = ''; DurationMs = 12 }) -Changes @([ordered]@{ path = 'touched.txt'; change = 'added' }) -Model 'cursor-grok-4.6-xhigh' -DispatchId '00000000-0000-0000-0000-000000000001' -PromptSha256 ('c' * 64) -ExpectedModelDisplay 'Cursor Grok 4.6 Extra High'
    Assert-Named 'verify_mutation_fail_closed' ($verifyCompleted.outcome -ceq 'policy_failure') 'Verify mutation was not a policy failure.'
    Assert-Named 'verify_mutation_fail_closed' ($verifyCompleted.result.success -eq $false) 'Verify mutation returned success.'
    Assert-Named 'verify_mutation_fail_closed' ([string]$verifyCompleted.result.failure_code -ceq 'verify_workspace_mutated') 'Verify mutation used the wrong policy code.'
    Assert-Named 'verify_mutation_fail_closed' (($verifyCompleted.result.violating_paths -join '|') -ceq 'touched.txt') 'Verify mutation did not report the exact changed path.'
    Assert-Named 'verify_mutation_fail_closed' (($verifyCompleted.result.changed_files | ForEach-Object { $_.path + ':' + $_.change }) -join '|' -ceq 'touched.txt:added') 'Verify mutation lost the changed-file inventory.'
    Assert-Named 'verify_mutation_fail_closed' ($verifyCompleted.register_session -eq $false) 'Verify mutation registered a session.'

    $scopeNdjson = @(
        '{"type":"system","subtype":"init","apiKeySource":"login","cwd":"C:\\write-ws","model":"Cursor Grok 4.6 Extra High","session_id":"sess-write"}',
        '{"type":"result","subtype":"success","is_error":false,"session_id":"sess-write","result":"SCOPE-NONCE-XYZ","usage":{"inputTokens":3,"outputTokens":5}}'
    ) -join "`n"
    $scopeChanges = @(
        [ordered]@{ path = 'allowed/ok.txt'; change = 'added' },
        [ordered]@{ path = 'secret.txt'; change = 'added' }
    )
    $scopeCompleted = Complete-DirectCursorAgentRun -Mode Write -Workspace 'C:\write-ws' -AllowedWriteRelative @('allowed') -Run ([pscustomobject]@{ ExitCode = 0; Stdout = $scopeNdjson; Stderr = ''; DurationMs = 15 }) -Changes $scopeChanges -Model 'cursor-grok-4.6-xhigh' -DispatchId '00000000-0000-0000-0000-000000000002' -PromptSha256 ('f' * 64) -ExpectedModelDisplay 'Cursor Grok 4.6 Extra High'
    Assert-Named 'scope_violation_evidence_preserved' ($scopeCompleted.outcome -ceq 'policy_failure') 'Write scope violation was not a policy failure.'
    Assert-Named 'scope_violation_evidence_preserved' ($scopeCompleted.result.success -eq $false) 'Write scope violation returned success.'
    Assert-Named 'scope_violation_evidence_preserved' ([string]$scopeCompleted.result.failure_code -ceq 'write_scope_violation') 'Write scope violation used the wrong policy code.'
    Assert-Named 'scope_violation_evidence_preserved' ([string]$scopeCompleted.result.result -ceq 'SCOPE-NONCE-XYZ') 'Write scope violation discarded the terminal report nonce.'
    Assert-Named 'scope_violation_evidence_preserved' ([int]$scopeCompleted.result.usage.inputTokens -eq 3 -and [int]$scopeCompleted.result.usage.outputTokens -eq 5) 'Write scope violation discarded usage.'
    Assert-Named 'scope_violation_evidence_preserved' ([string]$scopeCompleted.result.session_id -ceq 'sess-write') 'Write scope violation discarded session evidence.'
    Assert-Named 'scope_violation_evidence_preserved' ([string]$scopeCompleted.result.model_display -ceq 'Cursor Grok 4.6 Extra High') 'Write scope violation discarded model evidence.'
    $scopeChangeText = ($scopeCompleted.result.changed_files | ForEach-Object { $_.path + ':' + $_.change } | Sort-Object) -join '|'
    Assert-Named 'scope_violation_evidence_preserved' ($scopeChangeText -ceq 'allowed/ok.txt:added|secret.txt:added') 'Write scope violation lost the complete changed-file inventory.'
    Assert-Named 'scope_violation_evidence_preserved' (($scopeCompleted.result.violating_paths -join '|') -ceq 'secret.txt') 'Write scope violation did not isolate the undeclared path.'
    Assert-Named 'scope_violation_evidence_preserved' (
        [string]$scopeCompleted.result.evidence.agent_result -ceq 'available' -and
        [string]$scopeCompleted.result.evidence.usage -ceq 'available' -and
        [string]$scopeCompleted.result.evidence.session -ceq 'available' -and
        [string]$scopeCompleted.result.evidence.model -ceq 'available'
    ) 'Write scope violation marked captured evidence unavailable.'
    Assert-Named 'scope_violation_evidence_preserved' ($scopeCompleted.register_session -eq $false) 'Write scope violation registered a session.'

    $deltaChanges = @(
        [ordered]@{ path = 'allowed/ok.txt'; change = 'added' },
        [ordered]@{ path = 'secret.txt'; change = 'added' }
    )
    $deltaInventory = 'allowed/ok.txt:added|secret.txt:added'
    $completeBase = @{
        Mode = 'Write'
        Workspace = 'C:\write-ws'
        AllowedWriteRelative = @('allowed')
        Model = 'cursor-grok-4.6-xhigh'
        PromptSha256 = ('f' * 64)
        ExpectedModelDisplay = 'Cursor Grok 4.6 Extra High'
    }
    function Get-TestNdjson {
        param(
            [string]$Cwd = 'C:\write-ws',
            [string]$ModelDisplay = 'Cursor Grok 4.6 Extra High',
            [string]$InitSession = 'sess-write',
            [string]$ResultSession = 'sess-write',
            [string]$Subtype = 'success',
            [bool]$IsError = $false,
            [string]$ResultText = 'SCOPE-NONCE-XYZ',
            [switch]$OmitModel
        )
        $init = [ordered]@{
            type = 'system'
            subtype = 'init'
            apiKeySource = 'login'
            cwd = $Cwd
            session_id = $InitSession
        }
        if (-not $OmitModel) { $init.model = $ModelDisplay }
        $res = [ordered]@{
            type = 'result'
            subtype = $Subtype
            is_error = $IsError
            session_id = $ResultSession
            result = $ResultText
            usage = [ordered]@{ inputTokens = 3; outputTokens = 5 }
        }
        return (($init | ConvertTo-Json -Compress) + "`n" + ($res | ConvertTo-Json -Compress))
    }
    function Assert-NotPolicyFailure {
        param($Completed, [string]$Label)
        Assert-Named 'terminal_validation_precedes_policy' ($Completed.outcome -cne 'policy_failure') "$Label was relabeled as policy_failure."
        Assert-Named 'terminal_validation_precedes_policy' ($Completed.register_session -eq $false) "$Label registered a session."
        $inv = @($Completed.changed_files | ForEach-Object { $_.path + ':' + $_.change } | Sort-Object) -join '|'
        Assert-Named 'terminal_validation_precedes_policy' ($inv -ceq $deltaInventory) "$Label lost the changed-file inventory."
        $display = $null
        $modelEvidence = $null
        if ($null -ne $Completed.result) {
            $display = $Completed.result.model_display
            if ($null -ne $Completed.result.evidence) { $modelEvidence = [string]$Completed.result.evidence.model }
            Assert-Named 'terminal_validation_precedes_policy' ([string]$Completed.result.failure_kind -cne 'policy') "$Label returned a policy failure object."
        }
        if ($null -eq $Completed.result -or $modelEvidence -ceq 'unavailable') {
            Assert-Named 'terminal_validation_precedes_policy' (
                $null -eq $display -or [string]::IsNullOrWhiteSpace([string]$display)
            ) "$Label invented a model display while evidence was unavailable."
            Assert-Named 'terminal_validation_precedes_policy' (
                [string]$display -cne 'Cursor Grok 4.6 Extra High'
            ) "$Label substituted the expected model display."
        }
    }

    $malformedCompleted = Complete-DirectCursorAgentRun @completeBase -DispatchId '00000000-0000-0000-0000-000000000011' -Run ([pscustomobject]@{ ExitCode = 0; Stdout = '{bad'; Stderr = ''; DurationMs = 9 }) -Changes $deltaChanges
    Assert-NotPolicyFailure -Completed $malformedCompleted -Label 'Malformed NDJSON with out-of-scope changes'
    Assert-Named 'terminal_validation_precedes_policy' ([string]$malformedCompleted.evidence.model -ceq 'unavailable') 'Malformed NDJSON invented model evidence.'

    $wrongWsCompleted = Complete-DirectCursorAgentRun @completeBase -DispatchId '00000000-0000-0000-0000-000000000012' -Run ([pscustomobject]@{ ExitCode = 0; Stdout = (Get-TestNdjson -Cwd 'C:\other-ws'); Stderr = ''; DurationMs = 9 }) -Changes $deltaChanges
    Assert-NotPolicyFailure -Completed $wrongWsCompleted -Label 'Wrong workspace with out-of-scope changes'

    $wrongModelCompleted = Complete-DirectCursorAgentRun @completeBase -DispatchId '00000000-0000-0000-0000-000000000013' -Run ([pscustomobject]@{ ExitCode = 0; Stdout = (Get-TestNdjson -ModelDisplay 'Cursor Claude 4.6 Extra High'); Stderr = ''; DurationMs = 9 }) -Changes $deltaChanges
    Assert-NotPolicyFailure -Completed $wrongModelCompleted -Label 'Wrong model with out-of-scope changes'

    $sessionCompleted = Complete-DirectCursorAgentRun @completeBase -DispatchId '00000000-0000-0000-0000-000000000014' -Run ([pscustomobject]@{ ExitCode = 0; Stdout = (Get-TestNdjson -InitSession 'sess-a' -ResultSession 'sess-b'); Stderr = ''; DurationMs = 9 }) -Changes $deltaChanges
    Assert-NotPolicyFailure -Completed $sessionCompleted -Label 'Inconsistent session with out-of-scope changes'

    $errorCompleted = Complete-DirectCursorAgentRun @completeBase -DispatchId '00000000-0000-0000-0000-000000000015' -Run ([pscustomobject]@{ ExitCode = 0; Stdout = (Get-TestNdjson -Subtype 'error' -IsError $true); Stderr = ''; DurationMs = 9 }) -Changes $deltaChanges
    Assert-NotPolicyFailure -Completed $errorCompleted -Label 'Non-success terminal with out-of-scope changes'

    $missingModelCompleted = Complete-DirectCursorAgentRun @completeBase -DispatchId '00000000-0000-0000-0000-000000000016' -Run ([pscustomobject]@{ ExitCode = 0; Stdout = (Get-TestNdjson -OmitModel); Stderr = ''; DurationMs = 9 }) -Changes $deltaChanges
    Assert-NotPolicyFailure -Completed $missingModelCompleted -Label 'Missing model with out-of-scope changes'
    Assert-Named 'terminal_validation_precedes_policy' ([string]$missingModelCompleted.evidence.model -ceq 'unavailable') 'Missing model evidence was marked available.'

    Assert-Named 'terminal_validation_precedes_policy' ($scopeCompleted.outcome -ceq 'policy_failure') 'Valid bound terminal with out-of-scope changes lost the policy failure.'
    Assert-Named 'terminal_validation_precedes_policy' ([string]$scopeCompleted.result.model_display -ceq 'Cursor Grok 4.6 Extra High') 'Valid bound policy failure lost observed model evidence.'
    Assert-Named 'terminal_validation_precedes_policy' ([string]$scopeCompleted.result.evidence.model -ceq 'available') 'Valid bound policy failure marked observed model unavailable.'
    Assert-Named 'terminal_validation_precedes_policy' ($scopeCompleted.register_session -eq $false) 'Valid bound policy failure registered a session.'

    function Get-InventoryText {
        param([string]$Root)
        if (-not [IO.Directory]::Exists($Root)) { return '' }
        $snap = Get-DirectWorkspaceSnapshot -Root $Root
        return ((@($snap.Keys) | Sort-Object | ForEach-Object { $_ + "`t" + $snap[$_] }) -join "`n")
    }
    $beforeWorkspaceInv = Get-InventoryText -Root $workspace
    $beforeRouteInv = Get-InventoryText -Root $adapterCopy
    $beforeStateInv = Get-InventoryText -Root $stateRoot
    $counterBeforePreflight = [IO.File]::ReadAllText($counterPath)

    $preflightJobId = [Guid]::NewGuid().ToString('D')
    $preflight = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Preflight', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $preflightJobId, '-CursorTimeoutSeconds', '90', '-WaitTimeoutSeconds', '60', '-MaxOutputBytes', '16777216'
    )
    Assert-Named 'preflight_valid_no_launch' ($preflight.exit_code -eq 0) "Valid preflight exited $($preflight.exit_code)."
    Assert-Named 'preflight_valid_no_launch' ($preflight.value.launchable -eq $true) 'Valid preflight was not launchable.'
    Assert-Named 'preflight_valid_no_launch' ([string]$preflight.value.protocol_version -ceq 'telephone-line-direct-cursor-preflight-v1') 'Valid preflight used the wrong protocol.'
    Assert-Named 'preflight_valid_no_launch' ($preflight.value.state_changes -eq $false) 'Valid preflight did not assert state_changes=false.'
    Assert-Named 'preflight_valid_no_launch' ($preflight.value.model_session_created -eq $false) 'Valid preflight did not assert model_session_created=false.'
    Assert-Named 'preflight_valid_no_launch' (-not [IO.Directory]::Exists((Join-Path $stateRoot ("jobs\$preflightJobId")))) 'Valid preflight created a job directory.'
    Assert-Named 'preflight_valid_no_launch' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforePreflight) 'Valid preflight invoked the Cursor wrapper run path.'
    $preflightChecks = @($preflight.value.checks)
    $preflightCodes = @(Get-DirectCursorPreflightCheckCodes)
    Assert-Named 'preflight_valid_no_launch' ($preflightChecks.Count -eq $preflightCodes.Count) 'Valid preflight omitted a required check.'
    $failedChecks = @($preflightChecks | Where-Object { $_.status -ceq 'fail' })
    Assert-Named 'preflight_valid_no_launch' ($failedChecks.Count -eq 0) 'Valid preflight reported a failed check.'
    $blockingUnevaluated = @($preflightChecks | Where-Object {
        $_.status -ceq 'not_evaluated' -and $_.code -notin @(
            'write_scope_normalization', 'write_scope_containment', 'write_scope_existence', 'write_scope_non_reparse',
            'linked_worktree_leaf', 'resume_session_exists', 'resume_session_binding'
        )
    })
    Assert-Named 'preflight_valid_no_launch' ($blockingUnevaluated.Count -eq 0) 'Valid preflight left a required check unevaluated.'
    Assert-Named 'preflight_valid_no_launch' (@($preflight.value.blockers).Count -eq 0) 'Valid preflight returned blockers.'

    $gitPath = Join-Path $workspace '.git'
    $gitBackup = [IO.File]::ReadAllBytes($gitPath)
    [IO.File]::Delete($gitPath)
    $blocker = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Preflight', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'Write', '-AllowedWritePath', 'missing-root', '-JobId', $jobId, '-CursorTimeoutSeconds', '90', '-WaitTimeoutSeconds', '60'
    )
    Assert-Named 'preflight_all_blockers' ($blocker.exit_code -eq 2) "Blocker preflight exited $($blocker.exit_code)."
    Assert-Named 'preflight_all_blockers' ($blocker.value.launchable -eq $false) 'Blocker preflight was launchable.'
    $blockerMap = @{}
    foreach ($check in @($blocker.value.checks)) { $blockerMap[[string]$check.code] = $check }
    Assert-Named 'preflight_all_blockers' ([string]$blockerMap['job_id_collision'].status -ceq 'fail') 'Blocker preflight missed job collision.'
    Assert-Named 'preflight_all_blockers' ([string]$blockerMap['linked_worktree_leaf'].status -ceq 'fail') 'Blocker preflight missed the missing linked-worktree leaf.'
    Assert-Named 'preflight_all_blockers' ([string]$blockerMap['write_scope_existence'].status -ceq 'fail') 'Blocker preflight missed the missing allowed root.'
    Assert-Named 'preflight_all_blockers' ([string]$blockerMap['write_scope_non_reparse'].status -ceq 'not_evaluated') 'Dependent write-scope non-reparse check was not marked.'
    $blockerCodes = @($blocker.value.blockers | ForEach-Object { [string]$_.code })
    Assert-Named 'preflight_all_blockers' (
        $blockerCodes -contains 'job_id_collision' -and
        $blockerCodes -contains 'linked_worktree_leaf' -and
        $blockerCodes -contains 'write_scope_existence'
    ) 'Blocker preflight did not aggregate the required blockers.'
    Assert-Named 'preflight_all_blockers' ($blockerCodes.Count -ge 3) 'Blocker preflight did not report multiple blockers.'
    [IO.File]::WriteAllBytes($gitPath, $gitBackup)

    $afterWorkspaceInv = Get-InventoryText -Root $workspace
    $afterRouteInv = Get-InventoryText -Root $adapterCopy
    $afterStateInv = Get-InventoryText -Root $stateRoot
    Assert-Named 'preflight_observed_state_read_only' ($beforeWorkspaceInv -ceq $afterWorkspaceInv) 'Preflight mutated the prospective workspace.'
    Assert-Named 'preflight_observed_state_read_only' ($beforeRouteInv -ceq $afterRouteInv) 'Preflight mutated the route fixture.'
    Assert-Named 'preflight_observed_state_read_only' ($beforeStateInv -ceq $afterStateInv) 'Preflight mutated the state fixture.'
    Assert-Named 'preflight_observed_state_read_only' ($blocker.value.state_changes -eq $false -and $preflight.value.state_changes -eq $false) 'Preflight did not keep state_changes=false.'

    $productionEntryText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-cursor\Invoke-DirectCursorRoute.ps1'))
    Assert-Named 'preflight_probe_trust_bound' ($productionEntryText -notmatch 'DIRECT_CURSOR_PREFLIGHT_EVIDENCE') 'Production entry still accepts a preflight evidence environment file.'
    Assert-Named 'preflight_probe_trust_bound' ($productionEntryText -notmatch "(?i)GetEnvironmentVariable\('DIRECT_CURSOR") 'Production entry still reads a caller-controlled Direct Cursor evidence environment variable.'
    Assert-Named 'preflight_probe_trust_bound' ($productionEntryText -match '-QualifiedProbe') 'Production preflight does not invoke the bound QualifiedProbe parameter set.'
    Assert-Named 'preflight_probe_trust_bound' ($preflight.exit_code -eq 0 -and $preflight.value.launchable -eq $true) 'Bound QualifiedProbe did not yield a launchable no-state report.'
    Assert-Named 'preflight_probe_trust_bound' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforePreflight) 'Bound QualifiedProbe incremented the execution counter.'
    Assert-Named 'preflight_probe_trust_bound' (-not [IO.Directory]::Exists((Join-Path $stateRoot ("jobs\$preflightJobId")))) 'Bound QualifiedProbe created a job directory.'
    Assert-Named 'preflight_probe_trust_bound' ($preflight.value.model_session_created -eq $false) 'Bound QualifiedProbe created a model session.'

    function Invoke-CopiedPreflightProbe {
        param([string]$ProbeMode, [string]$PreflightMode = 'ReadOnly', [string]$Id)
        [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_PROBE', $ProbeMode, 'Process')
        try {
            return Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
                '-Preflight', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
                '-Mode', $PreflightMode, '-JobId', $Id, '-CursorTimeoutSeconds', '90', '-WaitTimeoutSeconds', '60'
            )
        } finally {
            [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_PROBE', $null, 'Process')
        }
    }

    $counterBeforeProbeTrust = [IO.File]::ReadAllText($counterPath)
    foreach ($probeCase in @('malformed', 'incomplete', 'wrong-protocol', 'wrong-case', 'non-boolean', 'extra-key')) {
        $probeJob = [Guid]::NewGuid().ToString('D')
        $got = Invoke-CopiedPreflightProbe -ProbeMode $probeCase -Id $probeJob
        Assert-Named 'preflight_probe_trust_bound' ($got.exit_code -ne 0 -and $got.exit_code -ne 2) "Probe $probeCase exited $($got.exit_code)."
        Assert-Named 'preflight_probe_trust_bound' (-not [IO.Directory]::Exists((Join-Path $stateRoot ("jobs\$probeJob")))) "Probe $probeCase created a job."
    }
    Assert-Named 'preflight_probe_trust_bound' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforeProbeTrust) 'Untrustworthy probe cases incremented the execution counter.'

    $falseJob = [Guid]::NewGuid().ToString('D')
    $falseGot = Invoke-CopiedPreflightProbe -ProbeMode 'false-binding' -Id $falseJob
    Assert-Named 'preflight_probe_trust_bound' ($falseGot.exit_code -eq 2) "False-binding preflight exited $($falseGot.exit_code)."
    Assert-Named 'preflight_probe_trust_bound' ($falseGot.value.launchable -eq $false) 'False-binding preflight was launchable.'
    Assert-Named 'preflight_probe_trust_bound' (@($falseGot.value.blockers).Count -ge 1) 'False-binding preflight returned no blockers.'
    $falseMap = @{}
    foreach ($check in @($falseGot.value.checks)) { $falseMap[[string]$check.code] = $check }
    Assert-Named 'preflight_probe_trust_bound' (
        [string]$falseMap['write_scope_normalization'].status -ceq 'not_evaluated' -and
        [string]$falseMap['write_scope_containment'].status -ceq 'not_evaluated' -and
        [string]$falseMap['resume_session_exists'].status -ceq 'not_evaluated' -and
        [string]$falseMap['resume_session_binding'].status -ceq 'not_evaluated'
    ) 'False-binding preflight invented PASS for dependent checks.'
    Assert-Named 'preflight_probe_trust_bound' ($falseGot.value.state_changes -eq $false -and $falseGot.value.model_session_created -eq $false) 'False-binding preflight created state or a model session.'
    Assert-Named 'preflight_probe_trust_bound' (-not [IO.Directory]::Exists((Join-Path $stateRoot ("jobs\$falseJob")))) 'False-binding preflight created a job directory.'
    Assert-Named 'preflight_probe_trust_bound' (
        $blocker.exit_code -eq 2 -and
        $blocker.value.launchable -eq $false -and
        @($blocker.value.blockers).Count -ge 1
    ) 'Exit-2 blocker report lacked launchable=false or blockers.'
    Assert-Named 'preflight_probe_trust_bound' ([string]$blockerMap['write_scope_non_reparse'].status -ceq 'not_evaluated') 'Dependent write-scope check was not left not_evaluated.'
    Assert-Named 'preflight_probe_trust_bound' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforeProbeTrust) 'Probe-trust preflights incremented the execution counter.'

    $parityJobId = [Guid]::NewGuid().ToString('D')
    $parityPre = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Preflight', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $parityJobId, '-CursorTimeoutSeconds', '90'
    )
    Assert-Named 'preflight_launch_parity' ($parityPre.exit_code -eq 0 -and $parityPre.value.launchable -eq $true) 'Parity preflight was not launchable.'
    $counterBeforeParityNew = [IO.File]::ReadAllText($counterPath)
    $parityNew = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $parityJobId, '-WaitTimeoutSeconds', '60'
    )
    Assert-Named 'preflight_launch_parity' ($parityNew.exit_code -eq 0) "Parity start after preflight exited $($parityNew.exit_code)."
    Assert-Named 'preflight_launch_parity' ($parityNew.value.transport_complete -eq $true -and $parityNew.value.cursor_success -eq $true) 'Parity start after preflight was not a successful transport.'
    Assert-Named 'preflight_launch_parity' ([IO.File]::ReadAllText($counterPath) -ceq ([string]([int]$counterBeforeParityNew + 1))) 'Parity start did not execute exactly once.'

    $staleJobId = [Guid]::NewGuid().ToString('D')
    $stalePre = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Preflight', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $staleJobId, '-CursorTimeoutSeconds', '90'
    )
    Assert-Named 'preflight_launch_parity' ($stalePre.exit_code -eq 0) 'Stale-input preflight was not launchable.'
    $counterBeforeStale = [IO.File]::ReadAllText($counterPath)
    $staleNew = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'Write', '-JobId', $staleJobId, '-WaitTimeoutSeconds', '15'
    )
    Assert-Named 'preflight_launch_parity' ($staleNew.exit_code -ne 0) 'Changing a bound input between preflight and start did not fail closed.'
    Assert-Named 'preflight_launch_parity' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforeStale) 'Stale-input start executed Cursor.'
    Assert-Named 'preflight_launch_parity' (-not [IO.Directory]::Exists((Join-Path $stateRoot ("jobs\$staleJobId")))) 'Stale-input start created a job after failing closed.'

    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_POLICY', 'write_scope', 'Process')
    $scopeJobId = [Guid]::NewGuid().ToString('D')
    $scopeTransport = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $writePromptPath,
        '-Mode', 'Write', '-AllowedWritePath', 'allowed', '-JobId', $scopeJobId, '-WaitTimeoutSeconds', '60'
    )
    Assert-Named 'scope_violation_transport_complete' ($scopeTransport.exit_code -eq 0) "Write policy-failure transport exited $($scopeTransport.exit_code)."
    Assert-Named 'scope_violation_transport_complete' ($scopeTransport.value.transport_complete -eq $true) 'Write policy-failure receipt was not transport complete.'
    Assert-Named 'scope_violation_transport_complete' ($scopeTransport.value.cursor_success -eq $false) 'Write policy-failure receipt did not carry cursor_success=false.'
    $scopeReceipt = (Read-DirectJson -Path ([string]$scopeTransport.value.receipt.path)).value
    Assert-Named 'scope_violation_transport_complete' ($null -eq $scopeReceipt.transport_error -or [string]$scopeReceipt.transport_error -eq '') 'Write policy-failure receipt kept a transport error.'
    Assert-Named 'scope_violation_transport_complete' ([string]$scopeReceipt.cursor_result.result -ceq 'SCOPE-NONCE-XYZ') 'Write policy-failure receipt lost the terminal nonce.'
    Assert-Named 'scope_violation_transport_complete' ([string]$scopeReceipt.cursor_result.failure_code -ceq 'write_scope_violation') 'Write policy-failure receipt lost the policy code.'
    $scopeReceiptBytes = [IO.File]::ReadAllBytes([string]$scopeTransport.value.receipt.path)
    $scopeReceiptSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($scopeReceiptBytes)).ToLowerInvariant()
    $counterBeforeRecover = [IO.File]::ReadAllText($counterPath)
    $scopeRecovered = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $writePromptPath,
        '-Mode', 'Write', '-AllowedWritePath', 'allowed', '-JobId', $scopeJobId, '-WaitTimeoutSeconds', '15'
    )
    Assert-Named 'scope_violation_transport_complete' ($scopeRecovered.exit_code -eq 0) "Write policy-failure recovery exited $($scopeRecovered.exit_code)."
    $scopeRecoveredSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes([string]$scopeTransport.value.receipt.path))).ToLowerInvariant()
    Assert-Named 'scope_violation_transport_complete' ($scopeRecoveredSha -ceq $scopeReceiptSha) 'Write policy-failure recovery mutated the receipt.'
    Assert-Named 'scope_violation_transport_complete' ([string]$scopeRecovered.value.receipt.path -ceq [string]$scopeTransport.value.receipt.path) 'Write policy-failure recovery returned another receipt path.'
    Assert-Named 'scope_violation_transport_complete' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforeRecover) 'Write policy-failure recovery reran Cursor.'
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_POLICY', $null, 'Process')

    $writeNoScope = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'Write', '-JobId', ([Guid]::NewGuid().ToString('D')), '-WaitTimeoutSeconds', '15'
    )
    Assert-Named 'legacy_modes_recovery_preserved' ($writeNoScope.exit_code -ne 0) 'Write without a scope was accepted.'
    [IO.File]::Delete($gitPath)
    $writeNoGit = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'Write', '-AllowedWritePath', 'allowed', '-JobId', ([Guid]::NewGuid().ToString('D')), '-WaitTimeoutSeconds', '15'
    )
    Assert-Named 'legacy_modes_recovery_preserved' ($writeNoGit.exit_code -ne 0) 'Write without a linked-worktree leaf was accepted.'
    [IO.File]::WriteAllBytes($gitPath, $gitBackup)

    $cross = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-Mode', 'Verify', '-JobId', ([Guid]::NewGuid().ToString('D')), '-WaitTimeoutSeconds', '15'
    )
    Assert-Named 'legacy_modes_recovery_preserved' ($cross.exit_code -ne 0) 'ReadOnly session resume under Verify was accepted.'
    $readReplay = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WaitTimeoutSeconds', '15'
    )
    Assert-Named 'legacy_modes_recovery_preserved' ($readReplay.exit_code -eq 0) 'Legacy ReadOnly recovery failed.'
    Assert-Named 'legacy_modes_recovery_preserved' ([string]$readReplay.value.native_session_id -ceq $session) 'Legacy ReadOnly recovery returned another session.'
    Assert-Named 'legacy_modes_recovery_preserved' ($false -eq $readAuthority.command_capable) 'ReadOnly became command-capable.'
    Assert-Named 'legacy_modes_recovery_preserved' ($true -eq $writeAuthority.requires_linked_worktree) 'Write no longer requires a linked-worktree leaf.'

    $prodHaystack = (
        [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-cursor\DirectCursor.Common.ps1')) + "`n" +
        [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-cursor\Invoke-DirectCursorRoute.ps1')) + "`n" +
        [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-cursor\invoke_cursor_agent.ps1')) + "`n" +
        [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-cursor\invoke_cursor_request.ps1')) + "`n" +
        [IO.File]::ReadAllText((Join-Path $repoRoot 'docs\adapters\direct-cursor.md')) + "`n" +
        [IO.File]::ReadAllText((Join-Path $repoRoot 'docs\quick-start.md'))
    )
    $preflightText = [string]$preflight.stdout + "`n" + [string]$blocker.stdout + "`n" + [string]$falseGot.stdout
    $policyNewFields = ($scopeCompleted.result.failure_kind, $scopeCompleted.result.failure_code, ($scopeCompleted.result.violating_paths -join ','), ($scopeCompleted.result.evidence | ConvertTo-Json -Compress)) -join "`n"
    $privateAccountNeedle = [regex]::Escape('private-account-identifier')
    $privateRouteNeedle = [regex]::Escape('private-control-route')
    Assert-Named 'sensitive_output_absent' ($prodHaystack -notmatch $privateAccountNeedle) 'Production source leaked a private account identifier.'
    Assert-Named 'sensitive_output_absent' ($prodHaystack -notmatch ('(?i)' + $privateRouteNeedle + '|Invoke-DshSecure|ninth route|T4 compatibility|AllowFast\.IsPresent')) 'Production source made a private-protocol, Fast, ninth-route, or T4 compatibility claim.'
    Assert-Named 'sensitive_output_absent' (($preflightText + "`n" + $policyNewFields) -notmatch '(?i)User Email|Subscription Tier|CURSOR_API_KEY|HTTP_PROXY|HTTPS_PROXY|stack trace') 'Preflight or policy-failure output leaked probe or environment material.'

    function Get-TestFileSha256 {
        param([string]$Path)
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
    }
    function Get-SessionBindingPath {
        param([string]$Root, [string]$SessionId)
        return Join-Path $Root ('sessions\' + $SessionId + '\binding.json')
    }

    $scopeNative = [string]$scopeTransport.value.native_session_id
    $scopeSessionBinding = Get-SessionBindingPath -Root $stateRoot -SessionId $scopeNative
    Assert-Named 'policy_recover_operation_exact' (-not [IO.File]::Exists($scopeSessionBinding)) 'Write policy-failure created a successful session binding.'
    Assert-Named 'policy_recover_operation_exact' ([string]$scopeRecovered.value.operation -ceq 'start') 'Duplicate JobId replay was not a start replay.'
    $counterBeforePolicyRecover = [IO.File]::ReadAllText($counterPath)
    $policyRecover = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $scopeNative, '-StateRoot', $stateRoot, '-WaitTimeoutSeconds', '15'
    )
    Assert-Named 'policy_recover_operation_exact' ($policyRecover.exit_code -eq 0) "Write policy recover exited $($policyRecover.exit_code)."
    Assert-Named 'policy_recover_operation_exact' ([string]$policyRecover.value.operation -ceq 'recover') 'Policy recover did not use operation recover.'
    Assert-Named 'policy_recover_operation_exact' ($policyRecover.value.transport_complete -eq $true) 'Policy recover was not transport complete.'
    Assert-Named 'policy_recover_operation_exact' ($policyRecover.value.cursor_success -eq $false) 'Policy recover did not keep cursor_success=false.'
    Assert-Named 'policy_recover_operation_exact' ([string]$policyRecover.value.receipt.path -ceq [string]$scopeTransport.value.receipt.path) 'Policy recover returned another receipt path.'
    Assert-Named 'policy_recover_operation_exact' ((Get-TestFileSha256 -Path ([string]$scopeTransport.value.receipt.path)) -ceq $scopeReceiptSha) 'Policy recover mutated the receipt.'
    Assert-Named 'policy_recover_operation_exact' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforePolicyRecover) 'Policy recover reran the wrapper.'

    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_POLICY', 'verify_mutation', 'Process')
    $verifyPolicyJob = [Guid]::NewGuid().ToString('D')
    $counterBeforeVerifyPolicy = [IO.File]::ReadAllText($counterPath)
    $verifyPolicy = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'Verify', '-JobId', $verifyPolicyJob, '-WaitTimeoutSeconds', '60'
    )
    Assert-Named 'policy_recover_operation_exact' ($verifyPolicy.exit_code -eq 0) "Verify policy durable start exited $($verifyPolicy.exit_code)."
    Assert-Named 'policy_recover_operation_exact' ($verifyPolicy.value.transport_complete -eq $true -and $verifyPolicy.value.cursor_success -eq $false) 'Verify policy durable path was not a transport-complete policy terminal.'
    $verifyNative = [string]$verifyPolicy.value.native_session_id
    Assert-Named 'policy_recover_operation_exact' (-not [IO.File]::Exists((Get-SessionBindingPath -Root $stateRoot -SessionId $verifyNative))) 'Verify policy created a successful session binding.'
    $verifyReceiptSha = Get-TestFileSha256 -Path ([string]$verifyPolicy.value.receipt.path)
    $verifyDuplicate = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'Verify', '-JobId', $verifyPolicyJob, '-WaitTimeoutSeconds', '15'
    )
    Assert-Named 'policy_recover_operation_exact' ($verifyDuplicate.exit_code -eq 0 -and [string]$verifyDuplicate.value.operation -ceq 'start') 'Verify policy duplicate JobId replay failed.'
    Assert-Named 'policy_recover_operation_exact' ((Get-TestFileSha256 -Path ([string]$verifyPolicy.value.receipt.path)) -ceq $verifyReceiptSha) 'Verify policy duplicate replay mutated the receipt.'
    $verifyRecover = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $verifyNative, '-StateRoot', $stateRoot, '-WaitTimeoutSeconds', '15'
    )
    Assert-Named 'policy_recover_operation_exact' ($verifyRecover.exit_code -eq 0 -and [string]$verifyRecover.value.operation -ceq 'recover') 'Verify policy recover failed.'
    Assert-Named 'policy_recover_operation_exact' ([string]$verifyRecover.value.receipt.path -ceq [string]$verifyPolicy.value.receipt.path) 'Verify policy recover returned another receipt path.'
    Assert-Named 'policy_recover_operation_exact' ((Get-TestFileSha256 -Path ([string]$verifyPolicy.value.receipt.path)) -ceq $verifyReceiptSha) 'Verify policy recover mutated the receipt.'
    Assert-Named 'policy_recover_operation_exact' ([IO.File]::ReadAllText($counterPath) -ceq ([string]([int]$counterBeforeVerifyPolicy + 1))) 'Verify policy durable path reran on duplicate replay or recover.'
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_POLICY', $null, 'Process')

    $followSuccessJob = [Guid]::NewGuid().ToString('D')
    $followSuccess = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $writePromptPath,
        '-Mode', 'Write', '-AllowedWritePath', 'allowed', '-JobId', $followSuccessJob, '-WaitTimeoutSeconds', '60'
    )
    Assert-Named 'policy_recover_operation_exact' ($followSuccess.exit_code -eq 0 -and $followSuccess.value.cursor_success -eq $true) 'Follow-up policy setup start failed.'
    $followNative = [string]$followSuccess.value.native_session_id
    $followBindingPath = Get-SessionBindingPath -Root $stateRoot -SessionId $followNative
    Assert-Named 'policy_recover_operation_exact' ([IO.File]::Exists($followBindingPath)) 'Successful Write start did not register a session binding.'
    $followBindingBefore = (Read-DirectJson -Path $followBindingPath).value
    Assert-Named 'policy_recover_operation_exact' ([string]$followBindingBefore.latest_job_id -ceq $followSuccessJob) 'Successful Write start bound the wrong job.'
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_POLICY', 'write_scope', 'Process')
    $followPolicyJob = [Guid]::NewGuid().ToString('D')
    $followPolicy = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', $followNative, '-StateRoot', $stateRoot, '-WorkspacePath', $workspace,
        '-PromptFile', $writePromptPath, '-Mode', 'Write', '-AllowedWritePath', 'allowed', '-JobId', $followPolicyJob, '-WaitTimeoutSeconds', '60'
    )
    Assert-Named 'policy_recover_operation_exact' ($followPolicy.exit_code -eq 0 -and $followPolicy.value.transport_complete -eq $true -and $followPolicy.value.cursor_success -eq $false) 'Follow-up policy was not a transport-complete policy terminal.'
    $followBindingAfter = (Read-DirectJson -Path $followBindingPath).value
    Assert-Named 'policy_recover_operation_exact' ([string]$followBindingAfter.latest_job_id -ceq $followSuccessJob) 'Follow-up policy updated the successful session binding.'
    $counterBeforeFollowRecover = [IO.File]::ReadAllText($counterPath)
    $followRecover = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $followNative, '-StateRoot', $stateRoot, '-WaitTimeoutSeconds', '15'
    )
    Assert-Named 'policy_recover_operation_exact' ($followRecover.exit_code -eq 0 -and [string]$followRecover.value.operation -ceq 'recover') 'Follow-up policy recover failed.'
    Assert-Named 'policy_recover_operation_exact' ([string]$followRecover.value.receipt.path -ceq [string]$followPolicy.value.receipt.path) 'Follow-up policy recover returned the earlier success receipt.'
    Assert-Named 'policy_recover_operation_exact' ($followRecover.value.cursor_success -eq $false) 'Follow-up policy recover did not keep cursor_success=false.'
    Assert-Named 'policy_recover_operation_exact' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforeFollowRecover) 'Follow-up policy recover reran the wrapper.'
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_POLICY', $null, 'Process')

    $profileAppData = Join-Path $env:USERPROFILE 'AppData'
    Assert-Named 'preflight_sensitive_root_parity' (
        -not $workspace.StartsWith($profileAppData + '\', [StringComparison]::OrdinalIgnoreCase) -and
        -not $workspace.Equals($profileAppData, [StringComparison]::OrdinalIgnoreCase)
    ) 'Valid fixture workspace was placed under AppData.'
    $counterBeforeSensitive = [IO.File]::ReadAllText($counterPath)
    $beforeSensitiveState = Get-InventoryText -Root $stateRoot
    $sensitivePreJob = [Guid]::NewGuid().ToString('D')
    [IO.Directory]::CreateDirectory($appDataWorkspace) | Out-Null
    $sensitivePre = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Preflight', '-StateRoot', $stateRoot, '-WorkspacePath', $appDataWorkspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $sensitivePreJob, '-CursorTimeoutSeconds', '90'
    )
    Assert-Named 'preflight_sensitive_root_parity' ($sensitivePre.exit_code -eq 2) "AppData preflight exited $($sensitivePre.exit_code)."
    Assert-Named 'preflight_sensitive_root_parity' ($sensitivePre.value.launchable -eq $false) 'AppData preflight was launchable.'
    $sensitiveBlockers = @($sensitivePre.value.blockers | ForEach-Object { [string]$_.code })
    Assert-Named 'preflight_sensitive_root_parity' ($sensitiveBlockers -contains 'workspace_sensitive_root') 'AppData preflight missed workspace_sensitive_root.'
    Assert-Named 'preflight_sensitive_root_parity' (@($sensitivePre.value.blockers).Count -ge 1) 'AppData exit-2 report had no blockers.'
    Assert-Named 'preflight_sensitive_root_parity' (-not [IO.Directory]::Exists((Join-Path $stateRoot ("jobs\$sensitivePreJob")))) 'AppData preflight created a job directory.'
    Assert-Named 'preflight_sensitive_root_parity' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforeSensitive) 'AppData preflight incremented the run counter.'
    Assert-Named 'preflight_sensitive_root_parity' ((Get-InventoryText -Root $stateRoot) -ceq $beforeSensitiveState) 'AppData preflight mutated adapter state.'
    $sensitiveRunJob = [Guid]::NewGuid().ToString('D')
    $sensitiveRun = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $appDataWorkspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $sensitiveRunJob, '-WaitTimeoutSeconds', '15'
    )
    Assert-Named 'preflight_sensitive_root_parity' ($sensitiveRun.exit_code -ne 0) 'AppData Run/New was accepted.'
    Assert-Named 'preflight_sensitive_root_parity' (-not [IO.Directory]::Exists((Join-Path $stateRoot ("jobs\$sensitiveRunJob")))) 'AppData Run/New created a job directory.'
    Assert-Named 'preflight_sensitive_root_parity' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforeSensitive) 'AppData Run/New executed the wrapper.'
    $outsidePreJob = [Guid]::NewGuid().ToString('D')
    $beforeOutsideInv = Get-InventoryText -Root $stateRoot
    $outsidePre = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Preflight', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $outsidePreJob, '-CursorTimeoutSeconds', '90'
    )
    Assert-Named 'preflight_sensitive_root_parity' ($outsidePre.exit_code -eq 0 -and $outsidePre.value.launchable -eq $true) 'Workspace outside AppData was not launchable.'
    Assert-Named 'preflight_sensitive_root_parity' ((Get-InventoryText -Root $stateRoot) -ceq $beforeOutsideInv) 'Valid outside-AppData preflight mutated inventories.'
    Assert-Named 'preflight_sensitive_root_parity' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforeSensitive) 'Valid outside-AppData preflight incremented the run counter.'

    $prodMissingHost = Join-Path $testRoot 'prod-missing-host'
    Copy-AdapterForTest -Source (Join-Path $repoRoot 'src\adapters\direct-cursor') -Destination $prodMissingHost
    Remove-Item -LiteralPath (Join-Path $prodMissingHost 'cursor_job_host.ps1') -Force
    $fakeAgentRoot = Join-Path $testRoot 'fake-cursor-agent'
    [IO.Directory]::CreateDirectory($fakeAgentRoot) | Out-Null
    $probeSessionRoot = Join-Path $testRoot 'prod-probe-session'
    [IO.Directory]::CreateDirectory($probeSessionRoot) | Out-Null
    $prodProbe = Invoke-AdapterEntrypoint -Entrypoint (Join-Path $prodMissingHost 'invoke_cursor_agent.ps1') -Arguments @(
        '-QualifiedProbe', '-WorkspacePath', $workspace, '-SessionRoot', $probeSessionRoot, '-Mode', 'ReadOnly',
        '-CursorAgentRoot', $fakeAgentRoot
    )
    Assert-Named 'qualified_job_host_blocker' ($prodProbe.exit_code -eq 0) "Production missing-host QualifiedProbe exited $($prodProbe.exit_code)."
    Assert-Named 'qualified_job_host_blocker' ([string]$prodProbe.value.protocol_version -ceq 'telephone-line-direct-cursor-qualified-probe-v1') 'Missing-host probe used the wrong protocol.'
    Assert-Named 'qualified_job_host_blocker' ($prodProbe.value.job_host_present -eq $false) 'Missing-host probe did not report job_host_present=false.'
    Assert-Named 'qualified_job_host_blocker' ($prodProbe.value.job_host_identity_match -eq $false) 'Missing-host probe did not report job_host_identity_match=false.'
    $missingHostState = Join-Path $testRoot 'missing-host-state'
    $missingHostJob = [Guid]::NewGuid().ToString('D')
    $missingHostPre = Invoke-AdapterEntrypoint -Entrypoint (Join-Path $prodMissingHost 'Invoke-DirectCursorRoute.ps1') -Arguments @(
        '-Preflight', '-StateRoot', $missingHostState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $missingHostJob, '-CursorTimeoutSeconds', '90', '-CursorAgentRoot', $fakeAgentRoot
    )
    Assert-Named 'qualified_job_host_blocker' ($missingHostPre.exit_code -eq 2) "Missing-host preflight exited $($missingHostPre.exit_code)."
    Assert-Named 'qualified_job_host_blocker' ($missingHostPre.value.launchable -eq $false) 'Missing-host preflight was launchable.'
    Assert-Named 'qualified_job_host_blocker' (@($missingHostPre.value.blockers).Count -ge 1) 'Missing-host exit-2 report had no blockers.'
    Assert-Named 'qualified_job_host_blocker' (-not [IO.Directory]::Exists((Join-Path $missingHostState ("jobs\$missingHostJob")))) 'Missing-host preflight created a job.'
    $missingHostRunJob = [Guid]::NewGuid().ToString('D')
    $counterBeforeMissingHostRun = [IO.File]::ReadAllText($counterPath)
    $missingHostRun = Invoke-AdapterEntrypoint -Entrypoint (Join-Path $prodMissingHost 'Invoke-DirectCursorRoute.ps1') -Arguments @(
        '-Operation', 'start', '-StateRoot', $missingHostState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $missingHostRunJob, '-WaitTimeoutSeconds', '15', '-CursorAgentRoot', $fakeAgentRoot
    )
    Assert-Named 'qualified_job_host_blocker' ($missingHostRun.exit_code -ne 0) 'Missing-host Run/New was accepted.'
    Assert-Named 'qualified_job_host_blocker' (-not [IO.Directory]::Exists((Join-Path $missingHostState ("jobs\$missingHostRunJob")))) 'Missing-host Run/New created a job.'
    Assert-Named 'qualified_job_host_blocker' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforeMissingHostRun) 'Missing-host Run/New incremented the copied-adapter run counter.'

    $runtimeSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-cursor\invoke_cursor_agent.ps1'))
    Assert-Named 'launch_gate_revalidation' ($runtimeSource -notmatch '\$expectedModelDisplay = \$Model') 'Run path still falls back to the request model id.'
    Assert-Named 'launch_gate_revalidation' ($runtimeSource -match 'ExpectedAccount\) -or -not \[string\]::IsNullOrWhiteSpace\(\$ExpectedSubscription\)') 'Subscription binding is not independently revalidated.'
    Assert-Named 'launch_gate_revalidation' ($runtimeSource -match 'Cursor model catalog probe failed') 'Model catalog failure is not fail-closed.'
    $counterBeforeGates = [IO.File]::ReadAllText($counterPath)
    foreach ($gateCase in @(
        @{ gate = 'models-fail'; extra = @() },
        @{ gate = 'models-missing'; extra = @() },
        @{ gate = 'subscription'; extra = @('-ExpectedSubscription', 'pro') }
    )) {
        [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_LAUNCH_GATE', [string]$gateCase.gate, 'Process')
        try {
            $gateJob = [Guid]::NewGuid().ToString('D')
            $gateRun = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments (@(
                '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
                '-Mode', 'ReadOnly', '-JobId', $gateJob, '-WaitTimeoutSeconds', '15'
            ) + $gateCase.extra)
            Assert-Named 'launch_gate_revalidation' ($gateRun.exit_code -ne 0) "Launch gate $($gateCase.gate) was accepted."
            Assert-Named 'launch_gate_revalidation' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforeGates) "Launch gate $($gateCase.gate) reached the main Run counter."
        } finally {
            [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_LAUNCH_GATE', $null, 'Process')
        }
    }
    $changedInputJob = [Guid]::NewGuid().ToString('D')
    $changedPre = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Preflight', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $changedInputJob, '-CursorTimeoutSeconds', '90'
    )
    Assert-Named 'launch_gate_revalidation' ($changedPre.exit_code -eq 0 -and $changedPre.value.launchable -eq $true) 'Revalidation preflight was not launchable.'
    $changedRun = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $appDataWorkspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $changedInputJob, '-WaitTimeoutSeconds', '15'
    )
    Assert-Named 'launch_gate_revalidation' ($changedRun.exit_code -ne 0) 'Changed launch workspace was not revalidated.'
    Assert-Named 'launch_gate_revalidation' (-not [IO.Directory]::Exists((Join-Path $stateRoot ("jobs\$changedInputJob")))) 'Changed launch workspace created a job.'
    Assert-Named 'launch_gate_revalidation' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforeGates) 'Changed launch workspace executed the wrapper.'
    $driftJob = [Guid]::NewGuid().ToString('D')
    $jobHostCopy = Join-Path $adapterCopy 'cursor_job_host.ps1'
    $jobHostBackup = [IO.File]::ReadAllBytes($jobHostCopy)
    [IO.File]::Delete($jobHostCopy)
    try {
        $driftRun = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
            '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
            '-Mode', 'ReadOnly', '-JobId', $driftJob, '-WaitTimeoutSeconds', '15'
        )
        Assert-Named 'launch_gate_revalidation' ($driftRun.exit_code -ne 0) 'Missing route job host was accepted on Run/New.'
        Assert-Named 'launch_gate_revalidation' (-not [IO.Directory]::Exists((Join-Path $stateRoot ("jobs\$driftJob")))) 'Missing route job host created a job.'
        Assert-Named 'launch_gate_revalidation' ([IO.File]::ReadAllText($counterPath) -ceq $counterBeforeGates) 'Missing route job host executed the wrapper.'
    } finally {
        [IO.File]::WriteAllBytes($jobHostCopy, $jobHostBackup)
    }

    $namedFlags = [ordered]@{}
    foreach ($key in @($namedCounts.Keys)) {
        Assert-AdapterTest ($namedCounts[$key] -gt 0) "Named counter $key has no backing assertions."
        $namedFlags[$key] = 1
    }

    [ordered]@{
        success = $true
        exact_session = 1
        recover_no_rerun = 1
        fast_disabled = 1
        write_allowlist = 1
        project_isolated_state_root = 1
        durable_generic_error_privacy = 1
        verify_command_capable_nonmutating = [int]$namedFlags.verify_command_capable_nonmutating
        verify_mutation_fail_closed = [int]$namedFlags.verify_mutation_fail_closed
        scope_violation_evidence_preserved = [int]$namedFlags.scope_violation_evidence_preserved
        scope_violation_transport_complete = [int]$namedFlags.scope_violation_transport_complete
        preflight_valid_no_launch = [int]$namedFlags.preflight_valid_no_launch
        preflight_all_blockers = [int]$namedFlags.preflight_all_blockers
        preflight_observed_state_read_only = [int]$namedFlags.preflight_observed_state_read_only
        preflight_launch_parity = [int]$namedFlags.preflight_launch_parity
        legacy_modes_recovery_preserved = [int]$namedFlags.legacy_modes_recovery_preserved
        sensitive_output_absent = [int]$namedFlags.sensitive_output_absent
        terminal_validation_precedes_policy = [int]$namedFlags.terminal_validation_precedes_policy
        preflight_probe_trust_bound = [int]$namedFlags.preflight_probe_trust_bound
        policy_recover_operation_exact = [int]$namedFlags.policy_recover_operation_exact
        preflight_sensitive_root_parity = [int]$namedFlags.preflight_sensitive_root_parity
        qualified_job_host_blocker = [int]$namedFlags.qualified_job_host_blocker
        launch_gate_revalidation = [int]$namedFlags.launch_gate_revalidation
        missing_session_failure = [int]$namedFlags.missing_session_failure
        runtime_volatile_snapshot = [int]$namedFlags.runtime_volatile_snapshot
        named_assertion_counts = $namedCounts
        baseline_assertions = $baselineAssertions
        assertions = $assertions
    } | ConvertTo-Json -Compress -Depth 6
} finally {
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_COUNTER', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_FAIL_TEXT', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_POLICY', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_PROBE', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_MOCK_LAUNCH_GATE', $null, 'Process')
    foreach ($cleanupRoot in @($testRoot, $outsideRoot, $appDataWorkspace)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$cleanupRoot) -and [IO.Directory]::Exists($cleanupRoot)) {
            Remove-Item -LiteralPath $cleanupRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
