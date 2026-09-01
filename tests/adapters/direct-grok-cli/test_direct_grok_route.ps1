# SPDX-License-Identifier: MPL-2.0
# Current Understanding (execution, 2026-08-27 terminal lineage closure):
# 1. Phase: close residual Direct Grok terminal-lineage FAIL on candidate 34ace90; preserve wireless, nested unbounded wait, and passing event-chain; amend the same one commit over 6c9d25e.
# 2. Denominator: successful terminals require a round-trip-valid exact created_at_utc and a durable cli_stdout identity proven against captured output. Unparsable matching timestamps fail closed. No CE/smoke/GitHub/release.
# 3. Only next step: implement that matcher/resolve closure, extend focused Direct Grok negatives, amend the same candidate.
# 4. Frozen non-goals: no App Server/dashboard/core mutation, no runtime activation, black-box smoke, docs/catalog/package.
# 5. Exit: focused proof union + dashboard no-delta, clean one commit over 6c9d25e, self_accepted=false; not project PASS.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'tests\adapters\AdapterTest.Common.ps1')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
$adapterCopy = Join-Path $testRoot 'adapter'
$workspace = Join-Path $testRoot 'workspace'
$stateRoot = Join-Path $testRoot 'state'
$promptPath = Join-Path $testRoot 'prompt.txt'
$counterPath = Join-Path $testRoot 'mock-count.txt'
$dummyGrok = Join-Path $testRoot 'grok-dummy.exe'
$promptText = 'Return the transport nonce only: DIRECT-GROK-MOCK'

try {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    Copy-AdapterForTest -Source (Join-Path $repoRoot 'src\adapters\direct-grok-cli') -Destination $adapterCopy
    [IO.File]::WriteAllText($promptPath, $promptText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes($dummyGrok, [byte[]]@(0x4D, 0x5A))

    $common = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-grok-cli\DirectGrok.Common.ps1'))
    Assert-AdapterTest ($common.Contains('Resolve-DirectGrokOfficialCommand')) 'Official CLI discovery helper is missing.'
    Assert-AdapterTest (-not $common.Contains('.grok\bin\grok.exe')) 'Official CLI discovery still pins a profile path.'
    $routeSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-grok-cli\Invoke-DirectGrokRoute.ps1'))
    Assert-AdapterTest ($routeSource.Contains('[int]$GrokTimeoutSeconds = 0') -and $routeSource.Contains('[int]$WaitTimeoutSeconds = 0')) 'Direct Grok still ships a whole-task timeout default.'
    . (Join-Path $repoRoot 'src\adapters\direct-grok-cli\DirectGrok.Common.ps1')
    $probeTs = [DateTimeOffset]::Parse('2026-08-27T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime().ToString('o')
    Assert-AdapterTest (Test-DirectGrokRoundTripTimestamp -Value $probeTs) 'Canonical round-trip timestamp was rejected.'
    Assert-AdapterTest (-not (Test-DirectGrokRoundTripTimestamp -Value 'not-a-timestamp')) 'Unparsable timestamp was treated as round-trip valid.'
    $probePrompt = [ordered]@{ path = $promptPath; bytes = 1; sha256 = ('a' * 64) }
    $probeReq = [ordered]@{
        job_id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        created_at_utc = $probeTs
        session_id = 'session-1'
        resume = $false
        workspace = $workspace
        prompt = $probePrompt
    }
    $probeTerm = [ordered]@{
        protocol_version = 'telephone-line-direct-grok-result-v1'
        success = $true
        official_cli = $true
        job_id = [string]$probeReq.job_id
        session_id = [string]$probeReq.session_id
        resumed = $false
        workspace = $workspace
        prompt = $probePrompt
        created_at_utc = $probeTs
        automatic_rerun = $false
        replacement_started = $false
    }
    $unparsableReq = [ordered]@{
        job_id = [string]$probeReq.job_id
        created_at_utc = 'not-a-timestamp'
        session_id = [string]$probeReq.session_id
        resume = $false
        workspace = $workspace
        prompt = $probePrompt
    }
    $unparsableTerm = [ordered]@{
        protocol_version = 'telephone-line-direct-grok-result-v1'
        success = $true
        official_cli = $true
        job_id = [string]$probeReq.job_id
        session_id = [string]$probeReq.session_id
        resumed = $false
        workspace = $workspace
        prompt = $probePrompt
        created_at_utc = 'not-a-timestamp'
        automatic_rerun = $false
        replacement_started = $false
    }
    Assert-AdapterTest (-not (Test-DirectGrokTerminalMatchesRequest -Request $unparsableReq -Terminal $unparsableTerm -CliStdoutPath $promptPath)) 'Matching unparsable timestamps were accepted.'
    Assert-AdapterTest (-not (Test-DirectGrokTerminalMatchesRequest -Request $probeReq -Terminal $probeTerm -CliStdoutPath $promptPath)) 'Successful terminal missing cli_stdout identity was accepted.'

    $mockWrapper = @'
# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$RequestPath,
    [long]$ExpectedRequestBytes,
    [string]$ExpectedRequestSha256,
    [long]$ExpectedWrapperBytes,
    [string]$ExpectedWrapperSha256
)
$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
$count = if ([IO.File]::Exists($env:DIRECT_GROK_MOCK_COUNTER)) { [int][IO.File]::ReadAllText($env:DIRECT_GROK_MOCK_COUNTER) } else { 0 }
[IO.File]::WriteAllText($env:DIRECT_GROK_MOCK_COUNTER, [string]($count + 1), [Text.UTF8Encoding]::new($false))
$jobRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($RequestPath))
$cliPath = Join-Path $jobRoot 'cli-stdout.json'
$cliBytes = [Text.UTF8Encoding]::new($false).GetBytes((([ordered]@{ sessionId = [string]$request.session_id; ok = $true } | ConvertTo-Json -Compress) + "`n"))
if (-not [IO.File]::Exists($cliPath)) { [IO.File]::WriteAllBytes($cliPath, $cliBytes) }
$cliItem = Get-Item -LiteralPath $cliPath
$cliRead = [IO.File]::ReadAllBytes($cliItem.FullName)
$cliIdentity = [ordered]@{
    path = $cliItem.FullName
    bytes = [int64]$cliRead.Length
    sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($cliRead)).ToLowerInvariant()
}
[ordered]@{
    protocol_version = 'telephone-line-direct-grok-result-v1'
    job_id = [string]$request.job_id
    success = $true
    error = $null
    workspace = [string]$request.workspace
    prompt = $request.prompt
    model_id = [string]$request.model
    reasoning_effort = [string]$request.reasoning_effort
    session_id = [string]$request.session_id
    resumed = [bool]$request.resume
    grok_exit_code = 0
    response = [ordered]@{ sessionId = [string]$request.session_id }
    diagnostic = ''
    duration_ms = 1
    official_cli = $true
    created_at_utc = [string]$request.created_at_utc
    cli_stdout = $cliIdentity
    automatic_rerun = $false
    replacement_started = $false
} | ConvertTo-Json -Depth 20
'@
    [IO.File]::WriteAllText((Join-Path $adapterCopy 'invoke_grok_build.ps1'), $mockWrapper.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('DIRECT_GROK_MOCK_COUNTER', $counterPath, 'Process')
    $invoke = Join-Path $adapterCopy 'Invoke-DirectGrokRoute.ps1'
    $jobId = [Guid]::NewGuid().ToString('D')
    $first = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $jobId, '-GrokCommand', $dummyGrok, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($first.exit_code -eq 0) "Direct Grok start failed: $($first.stderr) $($first.stdout)"
    Assert-AdapterTest ($first.value.official_cli -eq $true) 'Official CLI boundary was not advertised.'
    Assert-AdapterTest (-not [string]::IsNullOrWhiteSpace([string]$first.value.native_session_id)) 'Start did not capture a native session id.'
    Assert-NoPromptBody -RequestPath (Join-Path $stateRoot ("jobs\$jobId\request.json")) -PromptText $promptText
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '1') 'Start did not execute once.'

    $session = [string]$first.value.native_session_id
    $follow = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-JobId', ([Guid]::NewGuid().ToString('D')), '-GrokCommand', $dummyGrok, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($follow.exit_code -eq 0) "Follow-up failed: $($follow.stderr)"
    Assert-AdapterTest ([string]$follow.value.native_session_id -ceq $session) 'Follow-up used another session.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Follow-up did not execute once.'

    $wrong = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', 'wrong-session', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-JobId', ([Guid]::NewGuid().ToString('D')), '-GrokCommand', $dummyGrok, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($wrong.exit_code -ne 0) 'Wrong native session id was accepted.'

    $recovered = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($recovered.exit_code -eq 0) "Recover failed: $($recovered.stderr)"
    Assert-AdapterTest ($recovered.value.replacement_started -eq $false -and $recovered.value.automatic_rerun -eq $false) 'Recover reran.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Recover executed the mock.'

    $duplicate = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $jobId, '-GrokCommand', $dummyGrok, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($duplicate.exit_code -eq 0 -and [IO.File]::ReadAllText($counterPath) -ceq '2') 'Duplicate start reran Grok.'

    $wrapperSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\direct-grok-cli\invoke_grok_build.ps1'))
    Assert-AdapterTest ($wrapperSource.Contains('Get-DirectGrokPublicError')) 'Direct Grok still writes raw diagnostic text.'

    $sentinels = New-AdapterRuntimeSentinels
    $failCopy = Join-Path $testRoot 'fail-adapter'
    Copy-AdapterForTest -Source (Join-Path $repoRoot 'src\adapters\direct-grok-cli') -Destination $failCopy
    $failCmd = Join-Path $testRoot 'fail-grok.cmd'
    [IO.File]::WriteAllText($failCmd, "@echo off`r`necho %DIRECT_GROK_FAIL_TEXT%`r`necho %DIRECT_GROK_FAIL_TEXT% 1>&2`r`nexit /b 1`r`n", [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('DIRECT_GROK_FAIL_TEXT', ($sentinels.prompt + ' ' + $sentinels.email + ' ' + $sentinels.path + ' ' + $sentinels.key), 'Process')
    $failState = Join-Path $testRoot 'fail-state'
    $failJob = [Guid]::NewGuid().ToString('D')
    $failed = Invoke-AdapterEntrypoint -Entrypoint (Join-Path $failCopy 'Invoke-DirectGrokRoute.ps1') -Arguments @(
        '-Operation', 'start', '-StateRoot', $failState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $failJob, '-GrokCommand', $failCmd, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($failed.exit_code -ne 0) 'Forced Grok failure was treated as success.'
    $failCount = Get-AdapterArtifactSentinelCount -Root $failState -Sentinels @($sentinels.prompt, $sentinels.email, $sentinels.path, $sentinels.key)
    Assert-AdapterTest ($failCount -eq 0) 'Direct Grok durable failure artifacts retained a synthetic sentinel.'

    $durableCopy = Join-Path $testRoot 'durable-adapter'
    Copy-AdapterForTest -Source (Join-Path $repoRoot 'src\adapters\direct-grok-cli') -Destination $durableCopy
    $durableState = Join-Path $testRoot 'durable-state'
    $durableCounter = Join-Path $testRoot 'durable-count.txt'
    $mockGrokPs1 = Join-Path $testRoot 'mock-grok.ps1'
    $mockGrokCmd = Join-Path $testRoot 'mock-grok.cmd'
    $pwshPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    [IO.File]::WriteAllText($mockGrokPs1, @'
$script:session = ''
for ($i = 0; $i -lt $args.Count; $i++) {
    if ([string]$args[$i] -ceq '--session-id' -or [string]$args[$i] -ceq '--resume') {
        $script:session = [string]$args[$i + 1]
    }
}
$mode = [string]$env:TELEPHONE_TEST_DIRECT_GROK_MOCK_MODE
if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'success' }
$counter = [string]$env:DIRECT_GROK_MOCK_COUNTER
if (-not [string]::IsNullOrWhiteSpace($counter)) {
    $n = if ([IO.File]::Exists($counter)) { [int][IO.File]::ReadAllText($counter) } else { 0 }
    [IO.File]::WriteAllText($counter, [string]($n + 1), [Text.UTF8Encoding]::new($false))
}
if ($mode -ceq 'sleep') { Start-Sleep -Seconds 25 }
if ($mode -ceq 'empty') { exit 0 }
if ($mode -ceq 'partial') { [Console]::Out.Write('{'); exit 0 }
if ($mode -ceq 'fail') { [Console]::Error.WriteLine('mock grok failed'); exit 1 }
[ordered]@{ sessionId = $script:session; ok = $true } | ConvertTo-Json -Compress
exit 0
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($mockGrokCmd, "@echo off`r`n`"$pwshPath`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$mockGrokPs1`" %*`r`nexit /b %ERRORLEVEL%`r`n", [Text.UTF8Encoding]::new($false))
    $durableInvoke = Join-Path $durableCopy 'Invoke-DirectGrokRoute.ps1'
    $durableEntry = Join-Path $durableCopy 'Invoke-DirectGrokCliEntry.ps1'
    [Environment]::SetEnvironmentVariable('DIRECT_GROK_MOCK_COUNTER', $durableCounter, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_MOCK_MODE', 'success', 'Process')

    function Get-DurableCount { if ([IO.File]::Exists($durableCounter)) { return [int][IO.File]::ReadAllText($durableCounter) } return 0 }
    function Clear-DurableCrashEnv {
        foreach ($name in @('TELEPHONE_TEST_DIRECT_GROK_CRASH_BEFORE_CLI', 'TELEPHONE_TEST_DIRECT_GROK_CRASH_AFTER_CLI_STDOUT', 'TELEPHONE_TEST_DIRECT_GROK_CRASH_AFTER_CHECKPOINT')) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }

    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_CRASH_AFTER_CLI_STDOUT', '1', 'Process')
    $cliJob = [Guid]::NewGuid().ToString('D')
    $cliCrash = Invoke-AdapterEntrypoint -Entrypoint $durableInvoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $durableState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $cliJob, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '30'
    )
    Assert-AdapterTest ($cliCrash.exit_code -eq 0) "Crash after cli-stdout was not reconciled: $($cliCrash.stderr) $($cliCrash.stdout)"
    Assert-AdapterTest ($cliCrash.value.transport_complete -eq $true) 'Crash after cli-stdout did not reconcile a complete receipt.'
    Assert-AdapterTest ((Get-DurableCount) -eq 1) 'Crash after cli-stdout did not invoke Grok once.'
    $cliJobRoot = Join-Path $durableState ("jobs\$cliJob")
    Assert-AdapterTest ([IO.File]::Exists((Join-Path $cliJobRoot 'cli-stdout.json'))) 'Crash after cli-stdout did not persist CLI stdout.'
    Clear-DurableCrashEnv
    $cliRecover = Invoke-AdapterEntrypoint -Entrypoint $durableInvoke -Arguments @(
        '-Operation', 'recover', '-JobId', $cliJob, '-StateRoot', $durableState, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($cliRecover.exit_code -eq 0) "Recover after cli-stdout crash failed: $($cliRecover.stderr) $($cliRecover.stdout)"
    Assert-AdapterTest ($cliRecover.value.transport_complete -eq $true) 'Recover after cli-stdout crash was not transport complete.'
    Assert-AdapterTest ($cliRecover.value.automatic_rerun -eq $false -and $cliRecover.value.replacement_started -eq $false) 'Recover after cli-stdout advertised a replacement.'
    Assert-AdapterTest ((Get-DurableCount) -eq 1) 'Recover after cli-stdout crash reran Grok.'
    $cliReceipt = (Get-Content -LiteralPath (Join-Path $cliJobRoot 'receipt.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 32)
    Assert-AdapterTest ($cliReceipt.automatic_rerun -eq $false -and $cliReceipt.replacement_started -eq $false) 'Receipt after cli-stdout recover advertised a rerun.'
    Assert-AdapterTest ($cliReceipt.transport_complete -eq $true) 'Receipt after cli-stdout recover was not complete.'
    Assert-AdapterTest ([IO.File]::Exists((Join-Path $cliJobRoot 'session-proof.json'))) 'Crash after cli-stdout omitted session-proof.'
    Assert-AdapterTest (-not [string]::IsNullOrWhiteSpace([string]$cliReceipt.grok_result.created_at_utc)) 'Reconciled success omitted request-time lineage.'
    Assert-AdapterTest ([string]$cliReceipt.grok_result.created_at_utc -ceq [string]((Get-Content -LiteralPath (Join-Path $cliJobRoot 'request.json') -Raw | ConvertFrom-Json -AsHashtable).created_at_utc)) 'Reconciled success time lineage did not match the frozen request.'

    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_CRASH_AFTER_CHECKPOINT', '1', 'Process')
    $ckptJob = [Guid]::NewGuid().ToString('D')
    $ckptCrash = Invoke-AdapterEntrypoint -Entrypoint $durableInvoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $durableState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $ckptJob, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '30'
    )
    Assert-AdapterTest ($ckptCrash.exit_code -eq 0) "Crash after checkpoint was not reconciled: $($ckptCrash.stderr) $($ckptCrash.stdout)"
    Assert-AdapterTest ($ckptCrash.value.transport_complete -eq $true) 'Crash after checkpoint did not reconcile a complete receipt.'
    Assert-AdapterTest ((Get-DurableCount) -eq 2) 'Crash after checkpoint did not invoke Grok once more.'
    Clear-DurableCrashEnv
    $entryRecover = Invoke-AdapterEntrypoint -Entrypoint $durableEntry -Arguments @(
        '-RecoverJobId', $ckptJob, '-StateRoot', $durableState, '-WaitTimeoutSeconds', '15', '-GrokCommand', $mockGrokCmd
    )
    Assert-AdapterTest ($entryRecover.exit_code -eq 0) "CliEntry RecoverJobId failed: $($entryRecover.stderr) $($entryRecover.stdout)"
    Assert-AdapterTest ($entryRecover.value.transport_complete -eq $true) 'CliEntry recover was not transport complete.'
    Assert-AdapterTest ($entryRecover.value.automatic_rerun -eq $false -and $entryRecover.value.replacement_started -eq $false) 'CliEntry recover advertised a replacement.'
    Assert-AdapterTest ((Get-DurableCount) -eq 2) 'CliEntry recover reran Grok.'

    $ckptReceiptPath = Join-Path $durableState ("jobs\$ckptJob\receipt.json")
    $restartRecover = Invoke-AdapterEntrypoint -Entrypoint $durableInvoke -Arguments @(
        '-Operation', 'recover', '-JobId', $ckptJob, '-StateRoot', $durableState, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($restartRecover.exit_code -eq 0 -and (Get-DurableCount) -eq 2) 'Restart after receipt reran Grok.'
    Assert-AdapterTest ((Get-Item -LiteralPath $ckptReceiptPath).Length -gt 0) 'Restart after receipt lost the receipt.'

    $p1Info = [Diagnostics.ProcessStartInfo]::new()
    $p1Info.FileName = $pwshPath
    $p1Info.UseShellExecute = $false
    $p1Info.RedirectStandardOutput = $true
    $p1Info.RedirectStandardError = $true
    $p1Info.CreateNoWindow = $true
    $p2Info = [Diagnostics.ProcessStartInfo]::new()
    $p2Info.FileName = $pwshPath
    $p2Info.UseShellExecute = $false
    $p2Info.RedirectStandardOutput = $true
    $p2Info.RedirectStandardError = $true
    $p2Info.CreateNoWindow = $true
    foreach ($info in @($p1Info, $p2Info)) {
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $durableInvoke, '-Operation', 'recover', '-JobId', $ckptJob, '-StateRoot', $durableState, '-WaitTimeoutSeconds', '15')) {
            [void]$info.ArgumentList.Add($argument)
        }
    }
    $p1 = [Diagnostics.Process]::Start($p1Info)
    $p2 = [Diagnostics.Process]::Start($p2Info)
    try {
        $null = $p1.StandardOutput.ReadToEnd()
        $null = $p2.StandardOutput.ReadToEnd()
        $p1.WaitForExit()
        $p2.WaitForExit()
        Assert-AdapterTest ($p1.ExitCode -eq 0 -and $p2.ExitCode -eq 0) 'Concurrent recoverers did not both attach the same receipt.'
    } finally {
        $p1.Dispose()
        $p2.Dispose()
    }
    Assert-AdapterTest ((Get-DurableCount) -eq 2) 'Concurrent recoverers reran Grok.'

    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_CRASH_BEFORE_CLI', '1', 'Process')
    $beforeJob = [Guid]::NewGuid().ToString('D')
    $beforeCrash = Invoke-AdapterEntrypoint -Entrypoint $durableInvoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $durableState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $beforeJob, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '30'
    )
    Assert-AdapterTest ($beforeCrash.exit_code -ne 0) 'Death before a conclusive turn was treated as success.'
    Clear-DurableCrashEnv
    $beforeRecover = Invoke-AdapterEntrypoint -Entrypoint $durableInvoke -Arguments @(
        '-Operation', 'recover', '-JobId', $beforeJob, '-StateRoot', $durableState, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($beforeRecover.exit_code -ne 0) 'Death before a conclusive turn was promoted to success.'
    Assert-AdapterTest ($beforeRecover.value.transport_complete -ne $true) 'Inconclusive recover advertised transport complete.'
    Assert-AdapterTest ($beforeRecover.value.automatic_rerun -eq $false -and $beforeRecover.value.replacement_started -eq $false) 'Inconclusive recover advertised a replacement.'

    function Copy-HashtableDeep {
        param([Collections.IDictionary]$Value)
        return $Value | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32
    }
    function Invoke-LineageFailCase {
        param([string]$Name, [scriptblock]$Mutate)
        $job = [Guid]::NewGuid().ToString('D')
        $root = Join-Path $durableState ("jobs\$job")
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $req = Copy-HashtableDeep $goodRequest
        $term = Copy-HashtableDeep $goodTerminal
        $req.job_id = $job
        $term.job_id = $job
        $writeCheckpoint = $true
        & $Mutate $req $term $root ([ref]$writeCheckpoint)
        [IO.File]::WriteAllText((Join-Path $root 'request.json'), (($req | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        if ([bool]$writeCheckpoint) {
            [IO.File]::WriteAllText((Join-Path $root 'completion-checkpoint.json'), (($term | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        }
        if (-not [IO.File]::Exists((Join-Path $root 'grok-result.json'))) {
            [IO.File]::WriteAllBytes((Join-Path $root 'grok-result.json'), [byte[]]@())
        }
        $recovered = Invoke-AdapterEntrypoint -Entrypoint $durableInvoke -Arguments @(
            '-Operation', 'recover', '-JobId', $job, '-StateRoot', $durableState, '-WaitTimeoutSeconds', '10'
        )
        Assert-AdapterTest ($recovered.exit_code -ne 0) "$Name was promoted to success."
        Assert-AdapterTest ($recovered.value.transport_complete -ne $true) "$Name advertised transport complete."
        Assert-AdapterTest ($recovered.value.automatic_rerun -eq $false -and $recovered.value.replacement_started -eq $false) "$Name advertised a replacement."
        Assert-AdapterTest ((Get-DurableCount) -eq $lineageBaseline) "$Name reran Grok."
    }
    $goodRequest = Get-Content -LiteralPath (Join-Path $cliJobRoot 'request.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 32
    $goodTerminalPath = if ([IO.File]::Exists((Join-Path $cliJobRoot 'completion-checkpoint.json'))) {
        Join-Path $cliJobRoot 'completion-checkpoint.json'
    } else {
        Join-Path $cliJobRoot 'grok-result.json'
    }
    $goodTerminal = Get-Content -LiteralPath $goodTerminalPath -Raw | ConvertFrom-Json -AsHashtable -Depth 32
    $lineageBaseline = Get-DurableCount
    Invoke-LineageFailCase -Name 'missing-time' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $term.Remove('created_at_utc')
    }
    Invoke-LineageFailCase -Name 'wrong-time-only' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $term.created_at_utc = '2000-01-01T00:00:00.0000000+00:00'
    }
    Invoke-LineageFailCase -Name 'wrong-job-only' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $term.job_id = [Guid]::NewGuid().ToString('D')
    }
    Invoke-LineageFailCase -Name 'wrong-session-only' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $term.session_id = 'wrong-session'
    }
    Invoke-LineageFailCase -Name 'wrong-workspace-only' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $term.workspace = $testRoot
    }
    Invoke-LineageFailCase -Name 'wrong-prompt-only' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $term.prompt = @{ path = [string]$term.prompt.path; bytes = [int64]$term.prompt.bytes; sha256 = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' }
    }
    Invoke-LineageFailCase -Name 'stale-foreign-output' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $writeCheckpoint.Value = $false
        $stdoutPath = Join-Path $root 'cli-stdout.json'
        [IO.File]::WriteAllText($stdoutPath, (([ordered]@{ sessionId = [string]$req.session_id; ok = $true } | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $proof = [ordered]@{
            protocol_version = 'telephone-line-direct-grok-session-proof-v1'
            job_id = [string]$req.job_id
            session_id = [string]$req.session_id
            workspace = [string]$req.workspace
            prompt = $req.prompt
            created_at_utc = [string]$req.created_at_utc
            cli_stdout = @{ path = $stdoutPath; bytes = 1; sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
            automatic_rerun = $false
            replacement_started = $false
        }
        [IO.File]::WriteAllText((Join-Path $root 'session-proof.json'), (($proof | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    }
    Invoke-LineageFailCase -Name 'zero-partial-output' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $writeCheckpoint.Value = $false
        [IO.File]::WriteAllText((Join-Path $root 'cli-stdout.json'), '{', [Text.UTF8Encoding]::new($false))
    }
    Invoke-LineageFailCase -Name 'matching-unparsable-time' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $req.created_at_utc = 'not-a-timestamp'
        $term.created_at_utc = 'not-a-timestamp'
    }
    Invoke-LineageFailCase -Name 'success-checkpoint-missing-cli-stdout' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        if ($term.Contains('cli_stdout')) { $term.Remove('cli_stdout') }
        $stdoutPath = Join-Path $root 'cli-stdout.json'
        [IO.File]::WriteAllText($stdoutPath, (([ordered]@{ sessionId = [string]$req.session_id; ok = $true } | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    }
    Invoke-LineageFailCase -Name 'success-checkpoint-wrong-cli-path' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $stdoutPath = Join-Path $root 'cli-stdout.json'
        [IO.File]::WriteAllText($stdoutPath, (([ordered]@{ sessionId = [string]$req.session_id; ok = $true } | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $foreign = Get-DirectGrokFileIdentity -Path $promptPath
        $term.cli_stdout = $foreign
    }
    Invoke-LineageFailCase -Name 'success-checkpoint-wrong-cli-bytes' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $stdoutPath = Join-Path $root 'cli-stdout.json'
        [IO.File]::WriteAllText($stdoutPath, (([ordered]@{ sessionId = [string]$req.session_id; ok = $true } | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $actual = Get-DirectGrokFileIdentity -Path $stdoutPath
        $term.cli_stdout = @{ path = [string]$actual.path; bytes = ([int64]$actual.bytes + 7); sha256 = [string]$actual.sha256 }
    }
    Invoke-LineageFailCase -Name 'success-checkpoint-wrong-cli-hash' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $stdoutPath = Join-Path $root 'cli-stdout.json'
        [IO.File]::WriteAllText($stdoutPath, (([ordered]@{ sessionId = [string]$req.session_id; ok = $true } | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $actual = Get-DirectGrokFileIdentity -Path $stdoutPath
        $term.cli_stdout = @{ path = [string]$actual.path; bytes = [int64]$actual.bytes; sha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
    }
    Invoke-LineageFailCase -Name 'success-checkpoint-absent-captured-output' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $term.cli_stdout = @{ path = (Join-Path $root 'cli-stdout.json'); bytes = 12; sha256 = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' }
    }
    Invoke-LineageFailCase -Name 'success-checkpoint-zero-captured-output' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $stdoutPath = Join-Path $root 'cli-stdout.json'
        [IO.File]::WriteAllBytes($stdoutPath, [byte[]]@())
        $term.cli_stdout = Get-DirectGrokFileIdentity -Path $stdoutPath
    }
    Invoke-LineageFailCase -Name 'success-checkpoint-partial-captured-output' -Mutate {
        param($req, $term, $root, [ref]$writeCheckpoint)
        $stdoutPath = Join-Path $root 'cli-stdout.json'
        [IO.File]::WriteAllBytes($stdoutPath, [byte[]]@(0x7B))
        $term.cli_stdout = Get-DirectGrokFileIdentity -Path $stdoutPath
    }

    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_MOCK_MODE', 'sleep', 'Process')
    $liveJob = [Guid]::NewGuid().ToString('D')
    $liveInfo = [Diagnostics.ProcessStartInfo]::new()
    $liveInfo.FileName = $pwshPath
    $liveInfo.UseShellExecute = $false
    $liveInfo.RedirectStandardOutput = $true
    $liveInfo.RedirectStandardError = $true
    $liveInfo.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $durableInvoke, '-Operation', 'start', '-StateRoot', $durableState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath, '-JobId', $liveJob, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '0')) {
        [void]$liveInfo.ArgumentList.Add($argument)
    }
    $liveProc = [Diagnostics.Process]::Start($liveInfo)
    try {
        $liveOwnerPath = Join-Path $durableState ("jobs\$liveJob\owner.json")
        $liveDeadline = [DateTimeOffset]::UtcNow.AddSeconds(20)
        while ([DateTimeOffset]::UtcNow -lt $liveDeadline -and -not [IO.File]::Exists($liveOwnerPath)) { Start-Sleep -Milliseconds 100 }
        Assert-AdapterTest ([IO.File]::Exists($liveOwnerPath)) 'Live owner did not publish owner.json.'
        $liveRecover = Invoke-AdapterEntrypoint -Entrypoint $durableInvoke -Arguments @(
            '-Operation', 'recover', '-JobId', $liveJob, '-StateRoot', $durableState, '-WaitTimeoutSeconds', '2'
        )
        Assert-AdapterTest ($liveRecover.exit_code -eq 3) "Live owner recover did not serialize: $($liveRecover.stderr) $($liveRecover.stdout)"
        Assert-AdapterTest ([string]$liveRecover.value.protocol_version -ceq 'telephone-line-adapter-result-v1') 'Live owner recover did not return an adapter result.'
        Assert-AdapterTest ($liveRecover.value.transport_complete -ne $true) 'Live owner recover advertised transport complete.'
        Assert-AdapterTest ($liveRecover.value.automatic_rerun -eq $false -and $liveRecover.value.replacement_started -eq $false) 'Live owner recover advertised a replacement.'
        Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $durableState ("jobs\$liveJob\receipt.json")))) 'Live owner recover promoted a receipt.'
    } finally {
        try { Stop-Process -Id $liveProc.Id -Force -ErrorAction SilentlyContinue } catch { }
        try {
            $liveOwner = Get-Content -LiteralPath (Join-Path $durableState ("jobs\$liveJob\owner.json")) -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -AsHashtable
            if ($null -ne $liveOwner) { Stop-Process -Id ([int]$liveOwner.pid) -Force -ErrorAction SilentlyContinue }
        } catch { }
        $liveProc.Dispose()
    }

    [ordered]@{
        success = $true
        official_cli = 1
        exact_session = 1
        recover_no_rerun = 1
        durable_generic_error_privacy = 1
        crash_after_cli_stdout_recovered = 1
        crash_after_checkpoint_recovered = 1
        death_before_conclusive_fail_closed = 1
        missing_time_fail_closed = 1
        wrong_time_only_fail_closed = 1
        wrong_job_only_fail_closed = 1
        wrong_session_only_fail_closed = 1
        wrong_workspace_only_fail_closed = 1
        wrong_prompt_only_fail_closed = 1
        stale_foreign_output_fail_closed = 1
        zero_partial_fail_closed = 1
        matching_unparsable_time_fail_closed = 1
        missing_cli_stdout_identity_fail_closed = 1
        wrong_cli_path_fail_closed = 1
        wrong_cli_bytes_fail_closed = 1
        wrong_cli_hash_fail_closed = 1
        absent_captured_output_fail_closed = 1
        zero_captured_output_fail_closed = 1
        partial_captured_output_fail_closed = 1
        live_owner_serialized = 1
        concurrent_recoverers = 1
        cli_entry_recover_job_id = 1
        grok_invocations = (Get-DurableCount)
        assertions = $assertions
    } | ConvertTo-Json -Compress
} finally {
    [Environment]::SetEnvironmentVariable('DIRECT_GROK_MOCK_COUNTER', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_GROK_FAIL_TEXT', $null, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_MOCK_MODE', $null, 'Process')
    foreach ($name in @('TELEPHONE_TEST_DIRECT_GROK_CRASH_BEFORE_CLI', 'TELEPHONE_TEST_DIRECT_GROK_CRASH_AFTER_CLI_STDOUT', 'TELEPHONE_TEST_DIRECT_GROK_CRASH_AFTER_CHECKPOINT')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
