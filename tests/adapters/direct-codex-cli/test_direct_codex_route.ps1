# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'tests\adapters\AdapterTest.Common.ps1')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
$workspace = Join-Path $testRoot 'workspace'
$stateRoot = Join-Path $testRoot 'state'
$promptPath = Join-Path $testRoot 'prompt.txt'
$counterPath = Join-Path $testRoot 'mock-count.txt'
$mockCliPath = Join-Path $testRoot 'mock-codex.ps1'
$promptText = 'Return the transport nonce only: DIRECT-CODEX-MOCK'
$invoke = Join-Path $repoRoot 'src\adapters\direct-codex-cli\Invoke-DirectCodexCliRoute.ps1'

try {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    [IO.File]::WriteAllText($promptPath, $promptText, [Text.UTF8Encoding]::new($false))

    $common = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-codex-cli\DirectCodex.Common.ps1'))
    Assert-AdapterTest ($common.Contains('Resolve-DirectCodexCommand')) 'Codex CLI discovery helper is missing.'
    Assert-AdapterTest (-not $common.Contains('.codex\') -and -not $common.Contains('CODEX_HOME=')) 'Codex CLI discovery still pins a profile path.'
    $routeSource = [IO.File]::ReadAllText($invoke)
    Assert-AdapterTest ($routeSource.Contains('[int]$CodexTimeoutSeconds = 0') -and $routeSource.Contains('[int]$WaitTimeoutSeconds = 0')) 'Direct Codex still ships a whole-task timeout default.'
    $wrapperSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-codex-cli\invoke_codex_exec.ps1'))
    Assert-AdapterTest ($wrapperSource.Contains('Get-DirectCodexPublicError')) 'Direct Codex still writes raw diagnostic text.'
    Assert-AdapterTest ($wrapperSource.Contains('Get-DirectCodexNativeSessionIdFromEvents')) 'Direct Codex wrapper does not parse a native session id from JSONL.'
    Assert-AdapterTest (-not $wrapperSource.Contains("Add('--ask-for-approval')") -and $wrapperSource.Contains("'approval_policy='")) 'Direct Codex approval policy still uses the removed 0.149.1 CLI flag.'

    $mockCli = @'
# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$argsList = @($args)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
function ValueOf([string]$Flag) {
    $index = [Array]::IndexOf($argsList, $Flag)
    if ($index -ge 0 -and ($index + 1) -lt $argsList.Count) { return [string]$argsList[$index + 1] }
    return $null
}
if ($argsList -contains '--ephemeral') { throw 'ephemeral is forbidden' }
if ($argsList.Count -lt 1 -or [string]$argsList[0] -cne 'exec') { throw 'exec is required' }
if ($argsList -contains '--ask-for-approval') { throw 'removed approval flag was emitted' }
if ($env:DIRECT_CODEX_REQUIRE_APPROVAL_CONFIG -ceq '1') {
    $approvalBound = $false
    for ($i = 0; $i -lt ($argsList.Count - 1); $i++) {
        if ([string]$argsList[$i] -ceq '-c' -and [string]$argsList[$i + 1] -ceq 'approval_policy=never') { $approvalBound = $true }
    }
    if (-not $approvalBound) { throw 'approval policy config override is missing' }
}
if ($env:DIRECT_CODEX_REQUIRE_SKIP_GIT -ceq '1' -and $argsList -notcontains '--skip-git-repo-check') {
    throw 'skip-git-repo-check is missing'
}
$stdin = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($stdin)) { throw 'prompt stdin is required' }
$count = if ([IO.File]::Exists($env:DIRECT_CODEX_MOCK_COUNTER)) { [int][IO.File]::ReadAllText($env:DIRECT_CODEX_MOCK_COUNTER) } else { 0 }
[IO.File]::WriteAllText($env:DIRECT_CODEX_MOCK_COUNTER, [string]($count + 1), [Text.UTF8Encoding]::new($false))
$sessionId = $null
$resumeIndex = [Array]::IndexOf($argsList, 'resume')
if ($resumeIndex -ge 0) {
    if (($resumeIndex + 1) -ge $argsList.Count) { throw 'resume is missing a session id' }
    $sessionId = [string]$argsList[$resumeIndex + 1]
} else {
    $sessionId = [guid]::NewGuid().ToString('D')
}
$lastMessage = ValueOf '--output-last-message'
if ([string]::IsNullOrWhiteSpace($lastMessage)) { throw 'output-last-message is required' }
[IO.File]::WriteAllText($lastMessage, 'codex-mock-ok', [Text.UTF8Encoding]::new($false))
$nl = [char]10
$payload = '{"type":"thread.started","thread_id":"' + $sessionId + '"}' + $nl + '{"type":"turn.completed"}' + $nl
$payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes($payload)
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($payloadBytes, 0, $payloadBytes.Length)
$stdout.Flush()
'@
    [IO.File]::WriteAllText($mockCliPath, $mockCli.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('DIRECT_CODEX_MOCK_COUNTER', $counterPath, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CODEX_REQUIRE_APPROVAL_CONFIG', '1', 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CODEX_REQUIRE_SKIP_GIT', '1', 'Process')

    $jobId = [Guid]::NewGuid().ToString('D')
    $first = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $jobId, '-CodexCommand', $mockCliPath, '-ApprovalPolicy', 'never', '-SkipGitRepoCheck', '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($first.exit_code -eq 0) "Direct Codex start failed: $($first.stderr) $($first.stdout)"
    Assert-AdapterTest ($first.value.official_cli -eq $true) 'Official CLI boundary was not advertised.'
    Assert-AdapterTest (-not [string]::IsNullOrWhiteSpace([string]$first.value.native_session_id)) 'Start did not capture a native session id.'
    $request = Get-Content -LiteralPath (Join-Path $stateRoot ("jobs\$jobId\request.json")) -Raw | ConvertFrom-Json -AsHashtable -Depth 32
    Assert-AdapterTest ([string]::IsNullOrEmpty([string]$request.session_id)) 'Start synthesized a native session id.'
    Assert-AdapterTest ([string]$request.approval_policy -ceq 'never') 'Request did not freeze the approval policy.'
    Assert-AdapterTest ($request.skip_git_repo_check -eq $true) 'Request did not freeze the skip-Git control.'
    Assert-NoPromptBody -RequestPath (Join-Path $stateRoot ("jobs\$jobId\request.json")) -PromptText $promptText
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '1') 'Start did not execute once.'

    $session = [string]$first.value.native_session_id
    $follow = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-JobId', ([Guid]::NewGuid().ToString('D')), '-CodexCommand', $mockCliPath,
        '-ApprovalPolicy', 'never', '-SkipGitRepoCheck', '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($follow.exit_code -eq 0) "Follow-up failed: $($follow.stderr) $($follow.stdout)"
    Assert-AdapterTest ([string]$follow.value.native_session_id -ceq $session) 'Follow-up used another session.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Follow-up did not execute once.'
    [Environment]::SetEnvironmentVariable('DIRECT_CODEX_REQUIRE_APPROVAL_CONFIG', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CODEX_REQUIRE_SKIP_GIT', $null, 'Process')

    $wrong = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', '00000000-0000-4000-8000-000000000099', '-StateRoot', $stateRoot,
        '-WorkspacePath', $workspace, '-PromptFile', $promptPath, '-JobId', ([Guid]::NewGuid().ToString('D')),
        '-CodexCommand', $mockCliPath, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($wrong.exit_code -ne 0) 'Wrong native session id was accepted.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Wrong native session id executed the mock.'

    $recovered = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($recovered.exit_code -eq 0) "Recover failed: $($recovered.stderr)"
    Assert-AdapterTest ($recovered.value.replacement_started -eq $false -and $recovered.value.automatic_rerun -eq $false) 'Recover reran.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Recover executed the mock.'

    $duplicate = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $jobId, '-CodexCommand', $mockCliPath, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($duplicate.exit_code -eq 0 -and [IO.File]::ReadAllText($counterPath) -ceq '2') 'Duplicate start reran Codex.'

    $sentinels = New-AdapterRuntimeSentinels
    $failCmd = Join-Path $testRoot 'fail-codex.cmd'
    [IO.File]::WriteAllText($failCmd, "@echo off`r`necho %DIRECT_CODEX_FAIL_TEXT%`r`necho %DIRECT_CODEX_FAIL_TEXT% 1>&2`r`nexit /b 1`r`n", [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('DIRECT_CODEX_FAIL_TEXT', ($sentinels.prompt + ' ' + $sentinels.email + ' ' + $sentinels.path + ' ' + $sentinels.key), 'Process')
    $failState = Join-Path $testRoot 'fail-state'
    $failJob = [Guid]::NewGuid().ToString('D')
    $failed = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $failState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $failJob, '-CodexCommand', $failCmd, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($failed.exit_code -ne 0) 'Forced Codex failure was treated as success.'
    $failCount = Get-AdapterArtifactSentinelCount -Root $failState -Sentinels @($sentinels.prompt, $sentinels.email, $sentinels.path, $sentinels.key)
    Assert-AdapterTest ($failCount -eq 0) 'Direct Codex durable failure artifacts retained a synthetic sentinel.'

    [ordered]@{
        success = $true
        official_cli = 1
        codex_exact_session = 1
        codex_0149_approval_config = 1
        codex_isolated_workspace = 1
        codex_recover_no_rerun = 1
        durable_generic_error_privacy = 1
        assertions = $assertions
    } | ConvertTo-Json -Compress
} finally {
    [Environment]::SetEnvironmentVariable('DIRECT_CODEX_MOCK_COUNTER', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CODEX_FAIL_TEXT', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CODEX_REQUIRE_APPROVAL_CONFIG', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CODEX_REQUIRE_SKIP_GIT', $null, 'Process')
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
