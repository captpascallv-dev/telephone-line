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
$mockCliPath = Join-Path $testRoot 'mock-pi-cli.ps1'
$counterPath = Join-Path $testRoot 'mock-count.txt'
$promptText = 'please-echo-pi-mock'
$invoke = Join-Path $repoRoot 'src\adapters\direct-pi\Invoke-DirectPiRoute.ps1'

try {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    [IO.File]::WriteAllText($promptPath, $promptText, [Text.UTF8Encoding]::new($false))
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
if ($argsList -notcontains '--offline' -or $argsList -notcontains '--approve') { throw 'required transport flags are missing' }
if ($argsList -contains '-c' -or $argsList -contains '-r' -or $argsList -contains '--last') { throw 'forbidden session selector used' }
$stdin = [Console]::In.ReadToEnd()
$sessionDir = [IO.Path]::GetFullPath((ValueOf '--session-dir'))
[IO.Directory]::CreateDirectory($sessionDir) | Out-Null
$requestedId = ValueOf '--session-id'
$requestedPath = ValueOf '--session'
$sessionId = $null
$sessionPath = $null
if (-not [string]::IsNullOrWhiteSpace($requestedId)) {
    $sessionId = $requestedId
    $sessionPath = Join-Path $sessionDir ('session-' + $sessionId + '.jsonl')
    $header = '{"type":"session","version":3,"id":"' + $sessionId + '","cwd":"' + (($PWD.Path).Replace('\','\\')) + '"}' + "`n"
    [IO.File]::WriteAllText($sessionPath, $header, [Text.UTF8Encoding]::new($false))
} else {
    $sessionPath = [IO.Path]::GetFullPath($requestedPath)
    $first = ([IO.File]::ReadAllLines($sessionPath)[0] | ConvertFrom-Json -AsHashtable)
    $sessionId = [string]$first.id
}
$count = if ([IO.File]::Exists($env:DIRECT_PI_MOCK_COUNTER)) { [int][IO.File]::ReadAllText($env:DIRECT_PI_MOCK_COUNTER) } else { 0 }
[IO.File]::WriteAllText($env:DIRECT_PI_MOCK_COUNTER, [string]($count + 1), [Text.UTF8Encoding]::new($false))
$cwdJson = ($PWD.Path).Replace('\','\\')
$nl = [char]10
$nativeProvider = ValueOf '--provider'
$nativeModel = ValueOf '--model'
if (-not [string]::IsNullOrWhiteSpace($env:DIRECT_PI_MOCK_PROVIDER)) { $nativeProvider = [string]$env:DIRECT_PI_MOCK_PROVIDER }
if (-not [string]::IsNullOrWhiteSpace($env:DIRECT_PI_MOCK_MODEL)) { $nativeModel = [string]$env:DIRECT_PI_MOCK_MODEL }
if ($env:DIRECT_PI_MOCK_OMIT_IDENTITY -ceq '1') {
    $assistantJson = '{"role":"assistant","content":[{"type":"text","text":"pi-mock-ok"}],"stopReason":"stop"}'
} else {
    $assistantJson = '{"role":"assistant","provider":"' + $nativeProvider + '","model":"' + $nativeModel + '","content":[{"type":"text","text":"pi-mock-ok"}],"stopReason":"stop"}'
}
$headerJson = '{"type":"session","version":3,"id":"' + $sessionId + '","cwd":"' + $cwdJson + '"}'
$builder = [Text.StringBuilder]::new()
[void]$builder.Append($headerJson).Append($nl)
if ($env:DIRECT_PI_MOCK_LARGE -ceq '1') {
    $update = '{"type":"message_update","fixture":"' + ('x' * 65536) + '"}'
    for ($i = 0; $i -lt 280; $i++) { [void]$builder.Append($update).Append($nl) }
} else {
    [void]$builder.Append('{"type":"agent_start"}').Append($nl)
}
[void]$builder.Append('{"type":"message_end","message":' + $assistantJson + '}').Append($nl)
[void]$builder.Append('{"type":"agent_end"}').Append($nl)
$payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes($builder.ToString())
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($payloadBytes, 0, $payloadBytes.Length)
$stdout.Flush()
'@
    [IO.File]::WriteAllText($mockCliPath, $mockCli.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_COUNTER', $counterPath, 'Process')

    $routeSource = [IO.File]::ReadAllText($invoke)
    Assert-AdapterTest ($routeSource.Contains('[int]$PiTimeoutSeconds = 0') -and $routeSource.Contains('[int]$WaitTimeoutSeconds = 0')) 'Direct PI still ships a whole-task timeout default.'
    Assert-AdapterTest (-not $routeSource.Contains('AppData\Roaming') -and -not $routeSource.Contains('Program Files')) 'Direct PI pins a live install or session path.'

    $jobId = [Guid]::NewGuid().ToString('D')
    $first = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $jobId, '-MockCliPath', $mockCliPath, '-WaitTimeoutSeconds', '60'
    )
    $piDetail = ''
    foreach ($name in @('receipt.json', 'pi-result.json', 'wrapper-stderr.txt')) {
        $path = Join-Path $stateRoot ("jobs\$jobId\$name")
        if ([IO.File]::Exists($path)) { $piDetail += " $name=" + [IO.File]::ReadAllText($path) }
    }
    Assert-AdapterTest ($first.exit_code -eq 0) "Direct PI start failed: $($first.stderr) $($first.stdout)$piDetail"
    Assert-AdapterTest (-not [string]::IsNullOrWhiteSpace([string]$first.value.native_session_id)) 'Start did not capture a native session id.'
    Assert-AdapterTest ([IO.Path]::GetFullPath([string]$first.value.session_path).StartsWith((Join-Path $stateRoot 'sessions') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'Session file escaped the test state root.'
    Assert-NoPromptBody -RequestPath (Join-Path $stateRoot ("jobs\$jobId\request.json")) -PromptText $promptText
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '1') 'Start did not execute once.'

    $session = [string]$first.value.native_session_id
    $sessionPath = [string]$first.value.session_path
    $follow = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', $session, '-ResumeSessionPath', $sessionPath,
        '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', ([Guid]::NewGuid().ToString('D')), '-MockCliPath', $mockCliPath, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($follow.exit_code -eq 0) "Follow-up failed: $($follow.stderr) $($follow.stdout)"
    Assert-AdapterTest ([string]$follow.value.native_session_id -ceq $session) 'Follow-up used another session.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Follow-up did not execute once.'

    $wrong = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', '00000000-0000-4000-8000-000000000099',
        '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', ([Guid]::NewGuid().ToString('D')), '-MockCliPath', $mockCliPath, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($wrong.exit_code -ne 0) 'Wrong native session id was accepted.'

    $recovered = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($recovered.exit_code -eq 0) "Recover failed: $($recovered.stderr)"
    Assert-AdapterTest ($recovered.value.replacement_started -eq $false -and $recovered.value.automatic_rerun -eq $false) 'Recover reran PI.'
    Assert-AdapterTest ([IO.File]::ReadAllText($counterPath) -ceq '2') 'Recover executed the mock.'

    $duplicate = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $jobId, '-MockCliPath', $mockCliPath, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($duplicate.exit_code -eq 0 -and [IO.File]::ReadAllText($counterPath) -ceq '2') 'Duplicate start reran PI.'

    $defaultReq = Get-Content -LiteralPath (Join-Path $stateRoot ("jobs\$jobId\request.json")) -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ([string]$defaultReq.provider -ceq 'xai' -and [string]$defaultReq.model -ceq 'grok-4.6' -and [string]$defaultReq.thinking -ceq 'xhigh') 'Default PI provider/model/thinking drifted.'

    $dsState = Join-Path $testRoot 'ds-state'
    $dsJob = [Guid]::NewGuid().ToString('D')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_COUNTER', (Join-Path $testRoot 'ds-count.txt'), 'Process')
    $dsStart = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $dsState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $dsJob, '-MockCliPath', $mockCliPath, '-WaitTimeoutSeconds', '60',
        '-Provider', 'deepseek', '-Model', 'deepseek-flash', '-ThinkingLevel', 'max'
    )
    Assert-AdapterTest ($dsStart.exit_code -eq 0) "Explicit DeepSeek PI start failed: $($dsStart.stderr) $($dsStart.stdout)"
    $dsReq = Get-Content -LiteralPath (Join-Path $dsState ("jobs\$dsJob\request.json")) -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ([string]$dsReq.provider -ceq 'deepseek' -and [string]$dsReq.model -ceq 'deepseek-flash' -and [string]$dsReq.thinking -ceq 'max') 'Explicit PI provider/model/thinking did not enter the request.'
    $dsFollow = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', [string]$dsStart.value.native_session_id,
        '-ResumeSessionPath', [string]$dsStart.value.session_path,
        '-StateRoot', $dsState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', ([Guid]::NewGuid().ToString('D')), '-MockCliPath', $mockCliPath, '-WaitTimeoutSeconds', '60',
        '-Provider', 'deepseek', '-Model', 'deepseek-flash', '-ThinkingLevel', 'max'
    )
    Assert-AdapterTest ($dsFollow.exit_code -eq 0 -and [string]$dsFollow.value.native_session_id -ceq [string]$dsStart.value.native_session_id) 'DeepSeek PI follow-up did not keep the native session.'
    $dsMismatch = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', [string]$dsStart.value.native_session_id,
        '-ResumeSessionPath', [string]$dsStart.value.session_path,
        '-StateRoot', $dsState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', ([Guid]::NewGuid().ToString('D')), '-MockCliPath', $mockCliPath, '-WaitTimeoutSeconds', '15',
        '-Provider', 'xai', '-Model', 'grok-4.6', '-ThinkingLevel', 'xhigh'
    )
    Assert-AdapterTest ($dsMismatch.exit_code -ne 0) 'PI follow-up accepted a different model binding.'
    $dsResult = Get-Content -LiteralPath (Join-Path $dsState ("jobs\$dsJob\pi-result.json")) -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ([bool]$dsResult.success -eq $true) 'Matching native PI result was not success.'
    Assert-AdapterTest ([string]$dsResult.assistant_message.provider -ceq 'deepseek' -and [string]$dsResult.assistant_message.model -ceq 'deepseek-flash') 'Successful PI result omitted observed native assistant identity.'
    Assert-AdapterTest ([string]$dsResult.provider -ceq 'deepseek' -and [string]$dsResult.model -ceq 'deepseek-flash') 'Successful PI result did not keep observed native identity.'

    $wrongNativeState = Join-Path $testRoot 'wrong-native-state'
    $wrongNativeJob = [Guid]::NewGuid().ToString('D')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_COUNTER', (Join-Path $testRoot 'wrong-native-count.txt'), 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_PROVIDER', 'wrong-provider', 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_MODEL', 'wrong-model', 'Process')
    $wrongNative = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $wrongNativeState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $wrongNativeJob, '-MockCliPath', $mockCliPath, '-WaitTimeoutSeconds', '60',
        '-Provider', 'deepseek', '-Model', 'deepseek-flash', '-ThinkingLevel', 'max'
    )
    Assert-AdapterTest ($wrongNative.exit_code -ne 0) 'Native assistant provider/model mismatch was accepted.'
    $wrongReceipt = Get-Content -LiteralPath (Join-Path $wrongNativeState ("jobs\$wrongNativeJob\receipt.json")) -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ([bool]$wrongReceipt.transport_complete -eq $false -and [bool]$wrongReceipt.pi_success -eq $false) 'Native mismatch receipt claimed success.'
    $wrongTerminal = Get-Content -LiteralPath (Join-Path $wrongNativeState ("jobs\$wrongNativeJob\pi-result.json")) -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ([bool]$wrongTerminal.success -eq $false) 'Native mismatch terminal still reported success.'
    Assert-AdapterTest ([string]$wrongTerminal.assistant_message.provider -ceq 'wrong-provider' -and [string]$wrongTerminal.assistant_message.model -ceq 'wrong-model') 'Native mismatch did not preserve the observed assistant identity on the failed terminal.'
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_PROVIDER', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_MODEL', $null, 'Process')

    $missingNativeState = Join-Path $testRoot 'missing-native-state'
    $missingNativeJob = [Guid]::NewGuid().ToString('D')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_COUNTER', (Join-Path $testRoot 'missing-native-count.txt'), 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_OMIT_IDENTITY', '1', 'Process')
    $missingNative = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $missingNativeState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $missingNativeJob, '-MockCliPath', $mockCliPath, '-WaitTimeoutSeconds', '60',
        '-Provider', 'deepseek', '-Model', 'deepseek-flash', '-ThinkingLevel', 'max'
    )
    Assert-AdapterTest ($missingNative.exit_code -ne 0) 'Missing native assistant provider/model was accepted.'
    $missingReceipt = Get-Content -LiteralPath (Join-Path $missingNativeState ("jobs\$missingNativeJob\receipt.json")) -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ([bool]$missingReceipt.transport_complete -eq $false -and [bool]$missingReceipt.pi_success -eq $false) 'Missing native identity receipt claimed success.'
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_OMIT_IDENTITY', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_COUNTER', $counterPath, 'Process')

    $pathDir = Join-Path $testRoot 'path-bin'
    [IO.Directory]::CreateDirectory($pathDir) | Out-Null
    $pathLauncher = Join-Path $pathDir 'pi.ps1'
    [IO.File]::Copy($mockCliPath, $pathLauncher, $true)
    $explicitCli = Join-Path $testRoot 'explicit-pi.ps1'
    [IO.File]::Copy($mockCliPath, $explicitCli, $true)
    $savedPath = [string]$env:PATH
    $piPathDiscovery = 0
    try {
        $env:PATH = $pathDir + ';' + $savedPath
        $pathState = Join-Path $testRoot 'path-state'
        $pathJob = [Guid]::NewGuid().ToString('D')
        [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_COUNTER', (Join-Path $testRoot 'path-count.txt'), 'Process')
        $pathStart = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
            '-Operation', 'start', '-StateRoot', $pathState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
            '-JobId', $pathJob, '-WaitTimeoutSeconds', '60'
        )
        Assert-AdapterTest ($pathStart.exit_code -eq 0) "PATH PI start failed: $($pathStart.stderr) $($pathStart.stdout)"
        $pathSession = [string]$pathStart.value.native_session_id
        $pathFollow = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
            '-Operation', 'follow_up', '-NativeSessionId', $pathSession, '-ResumeSessionPath', [string]$pathStart.value.session_path,
            '-StateRoot', $pathState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
            '-JobId', ([Guid]::NewGuid().ToString('D')), '-WaitTimeoutSeconds', '60'
        )
        Assert-AdapterTest ($pathFollow.exit_code -eq 0 -and [string]$pathFollow.value.native_session_id -ceq $pathSession) 'PATH PI follow-up failed.'
        Assert-AdapterTest ([IO.File]::ReadAllText((Join-Path $testRoot 'path-count.txt')) -ceq '2') 'PATH discovery did not execute the launcher twice.'

        $explicitState = Join-Path $testRoot 'explicit-state'
        $explicitJob = [Guid]::NewGuid().ToString('D')
        [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_COUNTER', (Join-Path $testRoot 'explicit-count.txt'), 'Process')
        $explicitStart = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
            '-Operation', 'start', '-StateRoot', $explicitState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
            '-JobId', $explicitJob, '-PiCliPath', $explicitCli, '-WaitTimeoutSeconds', '60'
        )
        Assert-AdapterTest ($explicitStart.exit_code -eq 0) "Explicit PI start failed: $($explicitStart.stderr) $($explicitStart.stdout)"
        $explicitSession = [string]$explicitStart.value.native_session_id
        $explicitFollow = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
            '-Operation', 'follow_up', '-NativeSessionId', $explicitSession, '-ResumeSessionPath', [string]$explicitStart.value.session_path,
            '-StateRoot', $explicitState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
            '-JobId', ([Guid]::NewGuid().ToString('D')), '-PiCliPath', $explicitCli, '-WaitTimeoutSeconds', '60'
        )
        Assert-AdapterTest ($explicitFollow.exit_code -eq 0 -and [string]$explicitFollow.value.native_session_id -ceq $explicitSession) 'Explicit PI follow-up failed.'
        $piPathDiscovery = 1
    } finally {
        $env:PATH = $savedPath
        [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_COUNTER', $counterPath, 'Process')
    }

    $sentinels = New-AdapterRuntimeSentinels
    $failCli = Join-Path $testRoot 'fail-pi.ps1'
    [IO.File]::WriteAllText($failCli, @"
# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
`$argsList = @(`$args)
function ValueOf([string]`$Flag) {
    `$index = [Array]::IndexOf(`$argsList, `$Flag)
    if (`$index -ge 0 -and (`$index + 1) -lt `$argsList.Count) { return [string]`$argsList[`$index + 1] }
    return `$null
}
`$stdin = [Console]::In.ReadToEnd()
`$sessionDir = [IO.Path]::GetFullPath((ValueOf '--session-dir'))
[IO.Directory]::CreateDirectory(`$sessionDir) | Out-Null
`$sessionId = ValueOf '--session-id'
`$sessionPath = Join-Path `$sessionDir ('session-' + `$sessionId + '.jsonl')
`$header = '{"type":"session","version":3,"id":"' + `$sessionId + '","cwd":"' + ((`$PWD.Path).Replace('\','\\')) + '"}' + [char]10
[IO.File]::WriteAllText(`$sessionPath, `$header, [Text.UTF8Encoding]::new(`$false))
Write-Output ([string]`$env:DIRECT_PI_FAIL_TEXT)
exit 0
"@, [Text.UTF8Encoding]::new($false))
    $failLine = $sentinels.prompt + ' ' + $sentinels.email + ' ' + $sentinels.path + ' ' + $sentinels.key
    [Environment]::SetEnvironmentVariable('DIRECT_PI_FAIL_TEXT', $failLine, 'Process')
    $failState = Join-Path $testRoot 'fail-state'
    $failJob = [Guid]::NewGuid().ToString('D')
    $failed = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $failState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $failJob, '-MockCliPath', $failCli, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($failed.exit_code -ne 0) 'Forced PI failure was treated as success.'
    $failCount = Get-AdapterArtifactSentinelCount -Root $failState -Sentinels @($sentinels.prompt, $sentinels.email, $sentinels.path, $sentinels.key)
    Assert-AdapterTest ($failCount -eq 0) 'Direct PI durable failure artifacts retained a synthetic sentinel.'
    Assert-AdapterTest ([IO.File]::Exists((Join-Path $failState ("jobs\$failJob\receipt.json")))) 'Forced PI failure omitted generic receipt state.'

    . (Join-Path $repoRoot 'src\adapters\direct-pi\DirectPi.Common.ps1')
    $utf8 = [Text.UTF8Encoding]::new($false)
    function New-PiStreamBytes([string]$Text) { return $utf8.GetBytes($Text.Replace("`r`n", "`n")) }
    $header = '{"type":"session","version":3,"id":"sess-stream","cwd":"C:\\tmp"}'
    $message = '{"type":"message_end","message":{"role":"assistant","provider":"xai","model":"grok-4.6","stopReason":"stop","content":[{"type":"text","text":"ok"}]}}'
    $agentEnd = '{"type":"agent_end","messages":[]}'
    $okStream = ConvertFrom-DirectPiTerminalStream -Bytes (New-PiStreamBytes "$header`n$message`n$agentEnd`n") -MaxRecordBytes 16777216
    Assert-AdapterTest ($okStream.event_count -eq 3 -and $okStream.retained_events -eq 3) 'Normal stream did not retain header/assistant/end.'
    foreach ($case in @(
        @{ name = 'missing-agent-end'; text = "$header`n$message`n"; stage = 'end' },
        @{ name = 'end-before-final'; text = "$header`n$agentEnd`n$message`n"; stage = 'order' },
        @{ name = 'malformed-json'; text = "$header`n{broken}`n$message`n$agentEnd`n"; stage = 'json' },
        @{ name = 'wrong-model'; text = "$header`n$($message.Replace('grok-4.6','wrong-model'))`n$agentEnd`n"; stage = 'model' },
        @{ name = 'late-header'; text = "$header`n$message`n$header`n$agentEnd`n"; stage = 'header' },
        @{ name = 'nonterminal'; text = "$header`n$($message.Replace('"stop"','"error"'))`n$agentEnd`n"; stage = 'stop' }
    )) {
        $rejected = $false
        try {
            $parsed = ConvertFrom-DirectPiTerminalStream -Bytes (New-PiStreamBytes $case.text) -MaxRecordBytes 16777216
            if ($case.name -eq 'malformed-json' -or $case.name -eq 'late-header') { throw 'should have failed in parser' }
            $events = @($parsed.events)
            if ($events.Count -lt 1) { throw 'no header' }
            $assistant = $null
            foreach ($event in $events) {
                if ($event.Contains('type') -and [string]$event.type -ceq 'message_end' -and $event.message.role -ceq 'assistant') { $assistant = $event.message }
            }
            if ($null -eq $assistant) { throw 'no assistant' }
            if ([string]$assistant.model -cne 'grok-4.6') { throw 'PI final assistant model differs.' }
            $stopReason = [string]$assistant.stopReason
            if ([string]::IsNullOrWhiteSpace($stopReason) -or $stopReason -in @('error', 'aborted', 'pending')) { throw 'PI final assistant has a non-terminal stopReason.' }
            if ([int]$parsed.agent_end_count -lt 1 -or [int]$parsed.last_agent_end_index -le [int]$parsed.last_assistant_index) {
                throw 'PI JSON event stream has no agent_end after the final assistant.'
            }
        } catch { $rejected = $true }
        Assert-AdapterTest $rejected "Negative fixture accepted: $($case.name)"
    }

    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_LARGE', '1', 'Process')
    $largeState = Join-Path $testRoot 'large-state'
    $largeJob = [Guid]::NewGuid().ToString('D')
    $largeCountBefore = if ([IO.File]::Exists($counterPath)) { [int][IO.File]::ReadAllText($counterPath) } else { 0 }
    $large = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $largeState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $largeJob, '-MockCliPath', $mockCliPath, '-WaitTimeoutSeconds', '60'
    )
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_LARGE', $null, 'Process')
    Assert-AdapterTest ($large.exit_code -eq 0) "Large PI stream failed: $($large.stderr) $($large.stdout)"
    $largeResult = Get-Content -LiteralPath (Join-Path $largeState ("jobs\$largeJob\pi-result.json")) -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ([int]$largeResult.event_count -eq 283) "Large stream event_count=$($largeResult.event_count)"
    $largeDiag = Get-Content -LiteralPath (Join-Path $largeState ("jobs\$largeJob\transport-diagnostics.json")) -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ([int64]$largeDiag.stdout_bytes -gt 16777216) "Large stream bytes=$($largeDiag.stdout_bytes)"
    $largeDiagText = [IO.File]::ReadAllText((Join-Path $largeState ("jobs\$largeJob\transport-diagnostics.json")))
    Assert-AdapterTest ($largeDiagText.Contains('pi-mock-ok') -eq $false -and $largeDiagText.Contains($promptText) -eq $false) 'Transport diagnostics copied stream or prompt text.'
    Assert-AdapterTest ([int][IO.File]::ReadAllText($counterPath) -eq ($largeCountBefore + 1)) 'Large stream did not execute the wrapper once.'

    $recoverState = Join-Path $testRoot 'recover-state'
    $recoverJob = [Guid]::NewGuid().ToString('D')
    $recoverSession = [Guid]::NewGuid().ToString('D')
    $recoverJobRoot = Join-Path $recoverState "jobs\$recoverJob"
    $recoverSessionDir = Join-Path $recoverState 'sessions'
    [IO.Directory]::CreateDirectory($recoverJobRoot) | Out-Null
    [IO.Directory]::CreateDirectory($recoverSessionDir) | Out-Null
    $recoverSessionPath = Join-Path $recoverSessionDir ("session-$recoverSession.jsonl")
    $cwdJson = $workspace.Replace('\', '\\')
    $sessionBody = '{"type":"session","version":3,"id":"' + $recoverSession + '","cwd":"' + $cwdJson + '"}' + [char]10 +
        '{"type":"thinking_level_change","thinkingLevel":"xhigh"}' + [char]10 +
        '{"type":"message","id":"n1","message":{"role":"assistant","provider":"xai","model":"grok-4.6","stopReason":"stop","content":[{"type":"text","text":"native-done"}]}}' + [char]10 +
        '{"type":"thinking_level_change","thinkingLevel":"xhigh"}' + [char]10
    [IO.File]::WriteAllText($recoverSessionPath, $sessionBody.Replace("`r`n", "`n"), $utf8)
    $promptId = Get-DirectPiFileIdentity -Path $promptPath
    $wrapperId = Get-DirectPiFileIdentity -Path (Join-Path $repoRoot 'src\adapters\direct-pi\invoke_pi.ps1')
    $cliId = Get-DirectPiFileIdentity -Path $mockCliPath
    $nodeId = Get-DirectPiFileIdentity -Path ([string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName))
    $recoverRequest = [ordered]@{
        protocol_version = 'telephone-line-direct-pi-request-v1'
        job_id = $recoverJob
        workspace = $workspace
        prompt = $promptId
        provider = 'xai'
        model = 'grok-4.6'
        thinking = 'xhigh'
        session_id = $recoverSession
        session_path = $recoverSessionPath
        resume = $false
        session_dir = $recoverSessionDir
        timeout_seconds = 0
        max_output_bytes = 16777216
        node = $nodeId
        cli = $cliId
        wrapper = $wrapperId
        mock_mode = $true
        execution_count = 1
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $recoverRequestId = Write-DirectPiJsonCreateNew -Path (Join-Path $recoverJobRoot 'request.json') -Value $recoverRequest
    $recoverResult = [ordered]@{
        protocol_version = 'telephone-line-direct-pi-result-v1'
        job_id = $recoverJob
        success = $false
        error = 'Telephone-line adapter transport failed.'
        workspace = $workspace
        prompt = $promptId
        provider = 'xai'
        model = 'grok-4.6'
        thinking = 'xhigh'
        session_id = $recoverSession
        session_path = $recoverSessionPath
        resumed = $false
        pi_exit_code = 0
        stop_reason = 'stop'
        assistant_text = ''
        assistant_message = $null
        execution_count = 1
        event_count = 0
        agent_end_count = 0
        stderr_bytes = 0
        duration_ms = 1
    }
    $null = Write-DirectPiJsonCreateNew -Path (Join-Path $recoverJobRoot 'pi-result.json') -Value $recoverResult
    $null = Write-DirectPiJsonCreateNew -Path (Join-Path $recoverJobRoot 'receipt.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-direct-pi-receipt-v1'
        job_id = $recoverJob
        request = $recoverRequestId
        transport_complete = $false
        transport_error = 'Telephone-line adapter transport failed.'
        pi_success = $false
        native_session_id = $recoverSession
        session_path = $recoverSessionPath
        stop_reason = 'stop'
        execution_count = 1
        terminal_result = (Get-DirectPiFileIdentity -Path (Join-Path $recoverJobRoot 'pi-result.json'))
        owner = $null
        automatic_rerun = $false
        replacement_started = $false
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $beforeReceipt = Get-DirectPiFileIdentity -Path (Join-Path $recoverJobRoot 'receipt.json')
    $beforeResult = Get-DirectPiFileIdentity -Path (Join-Path $recoverJobRoot 'pi-result.json')
    $countBeforeRecover = [int][IO.File]::ReadAllText($counterPath)
    $recoveredMissing = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $recoverSession, '-StateRoot', $recoverState,
        '-JobId', $recoverJob, '-ResumeSessionPath', $recoverSessionPath, '-WaitTimeoutSeconds', '15'
    )
    Assert-AdapterTest ($recoveredMissing.exit_code -eq 4) "Missing-binding recover exit=$($recoveredMissing.exit_code) $($recoveredMissing.stderr) $($recoveredMissing.stdout)"
    Assert-AdapterTest ([IO.File]::Exists((Join-Path $recoverState "bindings\$recoverSession\binding.json"))) 'Missing binding was not restored.'
    Assert-AdapterTest ([IO.File]::Exists((Join-Path $recoverJobRoot 'binding-recovery.json'))) 'Binding recovery evidence is missing.'
    $afterReceipt = Get-DirectPiFileIdentity -Path (Join-Path $recoverJobRoot 'receipt.json')
    $afterResult = Get-DirectPiFileIdentity -Path (Join-Path $recoverJobRoot 'pi-result.json')
    Assert-AdapterTest ([string]$afterReceipt.sha256 -ceq [string]$beforeReceipt.sha256 -and [string]$afterResult.sha256 -ceq [string]$beforeResult.sha256) 'Recovery changed original failed bytes.'
    Assert-AdapterTest ([int][IO.File]::ReadAllText($counterPath) -eq $countBeforeRecover) 'Recovery invoked the model.'
    $recoveryText = [IO.File]::ReadAllText((Join-Path $recoverJobRoot 'binding-recovery.json'))
    Assert-AdapterTest ($recoveryText.Contains('native-done') -eq $false -and $recoveryText.Contains($promptText) -eq $false) 'Recovery evidence copied native text.'

    $liveOwner = [ordered]@{
        protocol_version = 'telephone-line-direct-pi-owner-v1'
        pid = [int]$PID
        start_time_utc_ticks = [int64](Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
        started_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $liveState = Join-Path $testRoot 'live-owner-state'
    $liveJob = [Guid]::NewGuid().ToString('D')
    $liveSession = [Guid]::NewGuid().ToString('D')
    $liveRoot = Join-Path $liveState "jobs\$liveJob"
    $liveSessionDir = Join-Path $liveState 'sessions'
    [IO.Directory]::CreateDirectory($liveRoot) | Out-Null
    [IO.Directory]::CreateDirectory($liveSessionDir) | Out-Null
    $liveSessionPath = Join-Path $liveSessionDir ("session-$liveSession.jsonl")
    [IO.File]::WriteAllText($liveSessionPath, $sessionBody.Replace($recoverSession, $liveSession).Replace("`r`n", "`n"), $utf8)
    $liveRequest = [ordered]@{}
    foreach ($key in @($recoverRequest.Keys)) { $liveRequest[$key] = $recoverRequest[$key] }
    $liveRequest.job_id = $liveJob
    $liveRequest.session_id = $liveSession
    $liveRequest.session_path = $liveSessionPath
    $liveRequest.session_dir = $liveSessionDir
    $liveRequestId = Write-DirectPiJsonCreateNew -Path (Join-Path $liveRoot 'request.json') -Value $liveRequest
    $liveResult = [ordered]@{}
    foreach ($key in @($recoverResult.Keys)) { $liveResult[$key] = $recoverResult[$key] }
    $liveResult.job_id = $liveJob
    $liveResult.session_id = $liveSession
    $liveResult.session_path = $liveSessionPath
    $null = Write-DirectPiJsonCreateNew -Path (Join-Path $liveRoot 'pi-result.json') -Value $liveResult
    $null = Write-DirectPiJsonCreateNew -Path (Join-Path $liveRoot 'receipt.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-direct-pi-receipt-v1'
        job_id = $liveJob
        request = $liveRequestId
        transport_complete = $false
        transport_error = 'Telephone-line adapter transport failed.'
        pi_success = $false
        native_session_id = $liveSession
        session_path = $liveSessionPath
        stop_reason = 'stop'
        execution_count = 1
        terminal_result = (Get-DirectPiFileIdentity -Path (Join-Path $liveRoot 'pi-result.json'))
        owner = $liveOwner
        automatic_rerun = $false
        replacement_started = $false
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $null = Write-DirectPiJsonCreateNew -Path (Join-Path $liveRoot 'owner.json') -Value $liveOwner
    $countBeforeLive = [int][IO.File]::ReadAllText($counterPath)
    $liveRecover = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $liveSession, '-StateRoot', $liveState,
        '-JobId', $liveJob, '-ResumeSessionPath', $liveSessionPath, '-WaitTimeoutSeconds', '5'
    )
    Assert-AdapterTest ($liveRecover.exit_code -ne 0) 'Live-owner recovery was accepted.'
    Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $liveState "bindings\$liveSession\binding.json"))) 'Live-owner recovery wrote a binding.'
    Assert-AdapterTest ([int][IO.File]::ReadAllText($counterPath) -eq $countBeforeLive) 'Live-owner recovery invoked the model.'

    $openState = Join-Path $testRoot 'open-turn-state'
    $openJob = [Guid]::NewGuid().ToString('D')
    $openSession = [Guid]::NewGuid().ToString('D')
    $openRoot = Join-Path $openState "jobs\$openJob"
    $openSessionDir = Join-Path $openState 'sessions'
    [IO.Directory]::CreateDirectory($openRoot) | Out-Null
    [IO.Directory]::CreateDirectory($openSessionDir) | Out-Null
    $openSessionPath = Join-Path $openSessionDir ("session-$openSession.jsonl")
    $openBody = '{"type":"session","version":3,"id":"' + $openSession + '","cwd":"' + $cwdJson + '"}' + [char]10 +
        '{"type":"message","message":{"role":"assistant","provider":"xai","model":"grok-4.6","stopReason":"pending"}}' + [char]10
    [IO.File]::WriteAllText($openSessionPath, $openBody.Replace("`r`n", "`n"), $utf8)
    $openRequest = [ordered]@{}
    foreach ($key in @($recoverRequest.Keys)) { $openRequest[$key] = $recoverRequest[$key] }
    $openRequest.job_id = $openJob
    $openRequest.session_id = $openSession
    $openRequest.session_path = $openSessionPath
    $openRequest.session_dir = $openSessionDir
    $openRequestId = Write-DirectPiJsonCreateNew -Path (Join-Path $openRoot 'request.json') -Value $openRequest
    $openResult = [ordered]@{}
    foreach ($key in @($recoverResult.Keys)) { $openResult[$key] = $recoverResult[$key] }
    $openResult.job_id = $openJob
    $openResult.session_id = $openSession
    $openResult.session_path = $openSessionPath
    $null = Write-DirectPiJsonCreateNew -Path (Join-Path $openRoot 'pi-result.json') -Value $openResult
    $null = Write-DirectPiJsonCreateNew -Path (Join-Path $openRoot 'receipt.json') -Value ([ordered]@{
        protocol_version = 'telephone-line-direct-pi-receipt-v1'
        job_id = $openJob
        request = $openRequestId
        transport_complete = $false
        transport_error = 'Telephone-line adapter transport failed.'
        pi_success = $false
        native_session_id = $openSession
        session_path = $openSessionPath
        stop_reason = ''
        execution_count = 1
        terminal_result = (Get-DirectPiFileIdentity -Path (Join-Path $openRoot 'pi-result.json'))
        owner = $null
        automatic_rerun = $false
        replacement_started = $false
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $countBeforeOpen = [int][IO.File]::ReadAllText($counterPath)
    $openRecover = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $openSession, '-StateRoot', $openState,
        '-JobId', $openJob, '-ResumeSessionPath', $openSessionPath, '-WaitTimeoutSeconds', '5'
    )
    Assert-AdapterTest ($openRecover.exit_code -ne 0) 'Unclosed native recovery was accepted.'
    Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $openState "bindings\$openSession\binding.json"))) 'Unclosed recovery wrote a binding.'
    Assert-AdapterTest ([int][IO.File]::ReadAllText($counterPath) -eq $countBeforeOpen) 'Unclosed recovery invoked the model.'

    function New-DirectPiRecoverFixture {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter(Mandatory = $true)][string]$SessionText,
            [scriptblock]$MutateResult
        )
        $fxState = Join-Path $testRoot $Name
        $fxJob = [Guid]::NewGuid().ToString('D')
        $fxSession = [Guid]::NewGuid().ToString('D')
        $fxRoot = Join-Path $fxState "jobs\$fxJob"
        $fxSessionDir = Join-Path $fxState 'sessions'
        [IO.Directory]::CreateDirectory($fxRoot) | Out-Null
        [IO.Directory]::CreateDirectory($fxSessionDir) | Out-Null
        $fxSessionPath = Join-Path $fxSessionDir ("session-$fxSession.jsonl")
        $fxBody = $SessionText.Replace($recoverSession, $fxSession).Replace($cwdJson, ([IO.Path]::GetFullPath($workspace)).Replace('\', '\\'))
        [IO.File]::WriteAllText($fxSessionPath, $fxBody.Replace("`r`n", "`n"), $utf8)
        $fxRequest = [ordered]@{}
        foreach ($key in @($recoverRequest.Keys)) { $fxRequest[$key] = $recoverRequest[$key] }
        $fxRequest.job_id = $fxJob
        $fxRequest.session_id = $fxSession
        $fxRequest.session_path = $fxSessionPath
        $fxRequest.session_dir = $fxSessionDir
        $fxRequestId = Write-DirectPiJsonCreateNew -Path (Join-Path $fxRoot 'request.json') -Value $fxRequest
        $fxResult = [ordered]@{}
        foreach ($key in @($recoverResult.Keys)) { $fxResult[$key] = $recoverResult[$key] }
        $fxResult.job_id = $fxJob
        $fxResult.session_id = $fxSession
        $fxResult.session_path = $fxSessionPath
        $null = Write-DirectPiJsonCreateNew -Path (Join-Path $fxRoot 'pi-result.json') -Value $fxResult
        $terminalBeforeMutate = Get-DirectPiFileIdentity -Path (Join-Path $fxRoot 'pi-result.json')
        $null = Write-DirectPiJsonCreateNew -Path (Join-Path $fxRoot 'receipt.json') -Value ([ordered]@{
            protocol_version = 'telephone-line-direct-pi-receipt-v1'
            job_id = $fxJob
            request = $fxRequestId
            transport_complete = $false
            transport_error = 'Telephone-line adapter transport failed.'
            pi_success = $false
            native_session_id = $fxSession
            session_path = $fxSessionPath
            stop_reason = 'stop'
            execution_count = 1
            terminal_result = $terminalBeforeMutate
            owner = $null
            automatic_rerun = $false
            replacement_started = $false
            completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        })
        if ($null -ne $MutateResult) {
            & $MutateResult $fxRoot $fxResult
        }
        return [ordered]@{
            state = $fxState
            job = $fxJob
            session = $fxSession
            session_path = $fxSessionPath
            root = $fxRoot
            before_receipt = (Get-DirectPiFileIdentity -Path (Join-Path $fxRoot 'receipt.json'))
            before_result = (Get-DirectPiFileIdentity -Path (Join-Path $fxRoot 'pi-result.json'))
        }
    }

    $newUserBody = '{"type":"session","version":3,"id":"' + $recoverSession + '","cwd":"' + $cwdJson + '"}' + [char]10 +
        '{"type":"thinking_level_change","thinkingLevel":"xhigh"}' + [char]10 +
        '{"type":"message","id":"n1","message":{"role":"assistant","provider":"xai","model":"grok-4.6","stopReason":"stop","content":[{"type":"text","text":"native-done"}]}}' + [char]10 +
        '{"type":"message","id":"n2","message":{"role":"user","content":[{"type":"text","text":"next-turn"}]}}' + [char]10
    $newUser = New-DirectPiRecoverFixture -Name 'new-user-after-old-stop' -SessionText $newUserBody
    $countBeforeNewUser = [int][IO.File]::ReadAllText($counterPath)
    $newUserRecover = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $newUser.session, '-StateRoot', $newUser.state,
        '-JobId', $newUser.job, '-ResumeSessionPath', $newUser.session_path, '-WaitTimeoutSeconds', '5'
    )
    Assert-AdapterTest ($newUserRecover.exit_code -ne 0) 'New-user-after-old-stop recovery was accepted.'
    Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $newUser.state "bindings\$($newUser.session)\binding.json"))) 'New-user-after-old-stop recovery wrote a binding.'
    Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $newUser.root 'binding-recovery.json'))) 'New-user-after-old-stop recovery wrote recovery evidence.'
    $afterNewUserReceipt = Get-DirectPiFileIdentity -Path (Join-Path $newUser.root 'receipt.json')
    $afterNewUserResult = Get-DirectPiFileIdentity -Path (Join-Path $newUser.root 'pi-result.json')
    Assert-AdapterTest ([string]$afterNewUserReceipt.sha256 -ceq [string]$newUser.before_receipt.sha256 -and [string]$afterNewUserResult.sha256 -ceq [string]$newUser.before_result.sha256) 'New-user recovery changed original failed bytes.'
    Assert-AdapterTest ([int][IO.File]::ReadAllText($counterPath) -eq $countBeforeNewUser) 'New-user recovery invoked the model.'

    $hashMismatch = New-DirectPiRecoverFixture -Name 'result-hash-mismatch' -SessionText $sessionBody -MutateResult {
        param($fxRoot, $fxResult)
        $rewritten = [ordered]@{}
        foreach ($key in @($fxResult.Keys)) { $rewritten[$key] = $fxResult[$key] }
        $rewritten.pi_exit_code = 0
        $rewritten.error = 'rewritten-success-label'
        [IO.File]::Delete((Join-Path $fxRoot 'pi-result.json'))
        $null = Write-DirectPiJsonCreateNew -Path (Join-Path $fxRoot 'pi-result.json') -Value $rewritten
    }
    $countBeforeHash = [int][IO.File]::ReadAllText($counterPath)
    $hashRecover = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $hashMismatch.session, '-StateRoot', $hashMismatch.state,
        '-JobId', $hashMismatch.job, '-ResumeSessionPath', $hashMismatch.session_path, '-WaitTimeoutSeconds', '5'
    )
    Assert-AdapterTest ($hashRecover.exit_code -ne 0) 'Result-hash-mismatch recovery was accepted.'
    Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $hashMismatch.state "bindings\$($hashMismatch.session)\binding.json"))) 'Result-hash-mismatch recovery wrote a binding.'
    $afterHashReceipt = Get-DirectPiFileIdentity -Path (Join-Path $hashMismatch.root 'receipt.json')
    $afterHashResult = Get-DirectPiFileIdentity -Path (Join-Path $hashMismatch.root 'pi-result.json')
    Assert-AdapterTest ([string]$afterHashReceipt.sha256 -ceq [string]$hashMismatch.before_receipt.sha256) 'Hash-mismatch recovery changed original receipt bytes.'
    Assert-AdapterTest ([string]$afterHashResult.sha256 -ceq [string]$hashMismatch.before_result.sha256) 'Hash-mismatch recovery changed rewritten result bytes.'
    Assert-AdapterTest ([int][IO.File]::ReadAllText($counterPath) -eq $countBeforeHash) 'Hash-mismatch recovery invoked the model.'

    $noThinkBody = '{"type":"session","version":3,"id":"' + $recoverSession + '","cwd":"' + $cwdJson + '"}' + [char]10 +
        '{"type":"message","id":"n1","message":{"role":"assistant","provider":"xai","model":"grok-4.6","stopReason":"stop","content":[{"type":"text","text":"native-done"}]}}' + [char]10
    $noThink = New-DirectPiRecoverFixture -Name 'missing-native-thinking' -SessionText $noThinkBody
    $countBeforeThink = [int][IO.File]::ReadAllText($counterPath)
    $noThinkRecover = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $noThink.session, '-StateRoot', $noThink.state,
        '-JobId', $noThink.job, '-ResumeSessionPath', $noThink.session_path, '-WaitTimeoutSeconds', '5'
    )
    Assert-AdapterTest ($noThinkRecover.exit_code -ne 0) 'Missing-thinking recovery was accepted.'
    Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $noThink.state "bindings\$($noThink.session)\binding.json"))) 'Missing-thinking recovery wrote a binding.'
    Assert-AdapterTest ([int][IO.File]::ReadAllText($counterPath) -eq $countBeforeThink) 'Missing-thinking recovery invoked the model.'

    [ordered]@{
        success = $true
        session_file = 1
        exact_session = 1
        recover_no_rerun = 1
        recover_new_user_refused = 1
        recover_hash_mismatch_refused = 1
        recover_missing_thinking_refused = 1
        pi_path_discovery = $piPathDiscovery
        durable_generic_error_privacy = 1
        assertions = $assertions
    } | ConvertTo-Json -Compress
} finally {
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_COUNTER', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_LARGE', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_FAIL_TEXT', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_PROVIDER', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_MODEL', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_OMIT_IDENTITY', $null, 'Process')
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
