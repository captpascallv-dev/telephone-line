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
$mockCliPath = Join-Path $testRoot 'mock-claude.ps1'
$promptText = 'Return the transport nonce only: DIRECT-CLAUDE-MOCK'
$invoke = Join-Path $repoRoot 'src\adapters\direct-claude-code\Invoke-DirectClaudeCodeRoute.ps1'

try {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    [IO.File]::WriteAllText($promptPath, $promptText, [Text.UTF8Encoding]::new($false))

    $common = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-claude-code\DirectClaude.Common.ps1'))
    Assert-AdapterTest ($common.Contains('Resolve-DirectClaudeCommand')) 'Claude Code CLI discovery helper is missing.'
    Assert-AdapterTest (-not $common.Contains('.claude\') -and -not $common.Contains('CLAUDE_CONFIG_DIR=')) 'Claude Code CLI discovery still pins a profile path.'
    $routeSource = [IO.File]::ReadAllText($invoke)
    Assert-AdapterTest ($routeSource.Contains('[int]$ClaudeTimeoutSeconds = 0') -and $routeSource.Contains('[int]$WaitTimeoutSeconds = 0')) 'Direct Claude still ships a whole-task timeout default.'
    $wrapperSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-claude-code\invoke_claude.ps1'))
    Assert-AdapterTest ($wrapperSource.Contains('Get-DirectClaudePublicError')) 'Direct Claude still writes raw diagnostic text.'
    Assert-AdapterTest ($wrapperSource.Contains('Get-DirectClaudeNativeSessionIdFromResult')) 'Direct Claude wrapper does not read session_id from JSON.'

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
if ($argsList -contains '--no-session-persistence' -or $argsList -contains '--fork-session') { throw 'forbidden session flag' }
if ($argsList -notcontains '-p' -or $argsList -notcontains '--output-format') { throw 'print json flags are required' }
$stdin = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($stdin)) { throw 'prompt stdin is required' }
$count = if ([IO.File]::Exists($env:DIRECT_CLAUDE_MOCK_COUNTER)) { [int][IO.File]::ReadAllText($env:DIRECT_CLAUDE_MOCK_COUNTER) } else { 0 }
[IO.File]::WriteAllText($env:DIRECT_CLAUDE_MOCK_COUNTER, [string]($count + 1), [Text.UTF8Encoding]::new($false))
$sessionId = ValueOf '--resume'
if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = ValueOf '-r' }
$supplied = ValueOf '--session-id'
if ([string]::IsNullOrWhiteSpace($sessionId)) {
    if (-not [string]::IsNullOrWhiteSpace($supplied)) { $sessionId = $supplied }
    else { $sessionId = [guid]::NewGuid().ToString('D') }
}
$result = [ordered]@{
    type = 'result'
    subtype = 'success'
    is_error = $false
    session_id = $sessionId
}
if ($env:DIRECT_CLAUDE_OMIT_RESULT -cne '1') { $result['result'] = 'claude-mock-ok' }
$payload = ($result | ConvertTo-Json -Compress -Depth 8) + "`n"
$payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes($payload)
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($payloadBytes, 0, $payloadBytes.Length)
$stdout.Flush()
'@
    [IO.File]::WriteAllText($mockCliPath, $mockCli.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('DIRECT_CLAUDE_MOCK_COUNTER', $counterPath, 'Process')

    $jobId = [Guid]::NewGuid().ToString('D')
    $first = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $jobId, '-ClaudeCommand', $mockCliPath, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($first.exit_code -eq 0) "Direct Claude start failed: $($first.stderr) $($first.stdout)"
    Assert-AdapterTest ($first.value.official_cli -eq $true) 'Official CLI boundary was not advertised.'
    Assert-AdapterTest (-not [string]::IsNullOrWhiteSpace([string]$first.value.native_session_id)) 'Start did not capture a native session id.'
    Assert-AdapterTest ([string]$first.value.assistant_text -ceq 'claude-mock-ok') 'Start did not return the exact assistant text.'
    $request = Get-Content -LiteralPath (Join-Path $stateRoot ("jobs\$jobId\request.json")) -Raw | ConvertFrom-Json -AsHashtable -Depth 32
    $terminalResult = Get-Content -LiteralPath (Join-Path $stateRoot ("jobs\$jobId\claude-result.json")) -Raw | ConvertFrom-Json -AsHashtable -Depth 32
    $routeReceipt = Get-Content -LiteralPath (Join-Path $stateRoot ("jobs\$jobId\receipt.json")) -Raw | ConvertFrom-Json -AsHashtable -Depth 32
    Assert-AdapterTest ([string]::IsNullOrEmpty([string]$request.session_id)) 'Start synthesized a native session id.'
    Assert-AdapterTest ([string]$terminalResult.assistant_text -ceq 'claude-mock-ok') 'Durable terminal result omitted assistant text.'
    Assert-AdapterTest ([string]$routeReceipt.assistant_text -ceq 'claude-mock-ok') 'Durable receipt omitted assistant text.'
    Assert-NoPromptBody -RequestPath (Join-Path $stateRoot ("jobs\$jobId\request.json")) -PromptText $promptText
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '1') 'Start did not execute once.'

    $session = [string]$first.value.native_session_id
    $follow = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-JobId', ([Guid]::NewGuid().ToString('D')), '-ClaudeCommand', $mockCliPath, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($follow.exit_code -eq 0) "Follow-up failed: $($follow.stderr) $($follow.stdout)"
    Assert-AdapterTest ([string]$follow.value.native_session_id -ceq $session) 'Follow-up used another session.'
    Assert-AdapterTest ([string]$follow.value.assistant_text -ceq 'claude-mock-ok') 'Follow-up omitted assistant text.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Follow-up did not execute once.'

    $wrong = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', '00000000-0000-4000-8000-000000000099', '-StateRoot', $stateRoot,
        '-WorkspacePath', $workspace, '-PromptFile', $promptPath, '-JobId', ([Guid]::NewGuid().ToString('D')),
        '-ClaudeCommand', $mockCliPath, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($wrong.exit_code -ne 0) 'Wrong native session id was accepted.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Wrong native session id executed the mock.'

    $recovered = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($recovered.exit_code -eq 0) "Recover failed: $($recovered.stderr)"
    Assert-AdapterTest ($recovered.value.replacement_started -eq $false -and $recovered.value.automatic_rerun -eq $false) 'Recover reran.'
    Assert-AdapterTest ([string]$recovered.value.assistant_text -ceq 'claude-mock-ok') 'Recover omitted durable assistant text.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Recover executed the mock.'

    $duplicate = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $jobId, '-ClaudeCommand', $mockCliPath, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($duplicate.exit_code -eq 0 -and [IO.File]::ReadAllText($counterPath) -ceq '2') 'Duplicate start reran Claude.'
    Assert-AdapterTest ([string]$duplicate.value.assistant_text -ceq 'claude-mock-ok') 'Duplicate replay omitted durable assistant text.'

    [Environment]::SetEnvironmentVariable('DIRECT_CLAUDE_OMIT_RESULT', '1', 'Process')
    $missingTextState = Join-Path $testRoot 'missing-text-state'
    $missingText = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $missingTextState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', ([Guid]::NewGuid().ToString('D')), '-ClaudeCommand', $mockCliPath, '-WaitTimeoutSeconds', '60'
    )
    [Environment]::SetEnvironmentVariable('DIRECT_CLAUDE_OMIT_RESULT', $null, 'Process')
    Assert-AdapterTest ($missingText.exit_code -ne 0) 'Missing Claude assistant text was accepted.'
    Assert-AdapterTest ([string]::IsNullOrEmpty([string]$missingText.value.assistant_text)) 'Missing-text failure synthesized assistant text.'

    $sentinels = New-AdapterRuntimeSentinels
    $failCmd = Join-Path $testRoot 'fail-claude.cmd'
    [IO.File]::WriteAllText($failCmd, "@echo off`r`necho %DIRECT_CLAUDE_FAIL_TEXT%`r`necho %DIRECT_CLAUDE_FAIL_TEXT% 1>&2`r`nexit /b 1`r`n", [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('DIRECT_CLAUDE_FAIL_TEXT', ($sentinels.prompt + ' ' + $sentinels.email + ' ' + $sentinels.path + ' ' + $sentinels.key), 'Process')
    $failState = Join-Path $testRoot 'fail-state'
    $failJob = [Guid]::NewGuid().ToString('D')
    $failed = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $failState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $failJob, '-ClaudeCommand', $failCmd, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($failed.exit_code -ne 0) 'Forced Claude failure was treated as success.'
    $failCount = Get-AdapterArtifactSentinelCount -Root $failState -Sentinels @($sentinels.prompt, $sentinels.email, $sentinels.path, $sentinels.key)
    Assert-AdapterTest ($failCount -eq 0) 'Direct Claude durable failure artifacts retained a synthetic sentinel.'

    [ordered]@{
        success = $true
        official_cli = 1
        claude_exact_session = 1
        claude_assistant_text = 1
        claude_missing_text_fail_closed = 1
        claude_recover_no_rerun = 1
        durable_generic_error_privacy = 1
        assertions = $assertions
    } | ConvertTo-Json -Compress
} finally {
    [Environment]::SetEnvironmentVariable('DIRECT_CLAUDE_MOCK_COUNTER', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CLAUDE_FAIL_TEXT', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CLAUDE_OMIT_RESULT', $null, 'Process')
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
