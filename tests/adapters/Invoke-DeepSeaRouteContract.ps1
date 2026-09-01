# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TestRoot,
    [Parameter(Mandatory = $true)][string]$RouteId,
    [Parameter(Mandatory = $true)][string]$AdapterDir,
    [Parameter(Mandatory = $true)][string]$EntrypointName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'tests\adapters\AdapterTest.Common.ps1')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
$workspace = Join-Path $testRoot 'workspace'
$stateRoot = Join-Path $testRoot 'state'
$promptPath = Join-Path $testRoot 'prompt.txt'
$counterPath = Join-Path $testRoot 'mock-count.txt'
$capturePath = Join-Path $testRoot 'mock-capture.json'
$mockStatePath = Join-Path $testRoot 'mock-state.json'
$sidecarPath = Join-Path $testRoot 'direct-plugin.mjs'
$sentinels = New-AdapterRuntimeSentinels
$promptText = [string]$sentinels.prompt
$invoke = Join-Path $repoRoot ('src\adapters\' + $AdapterDir + '\' + $EntrypointName)
$mockHeadless = Join-Path $repoRoot 'tests\adapters\fixtures\mock-headless.ps1'
$mockDsh = Join-Path $repoRoot 'tests\adapters\fixtures\mock-dsh.cmd'
$deepseaPromptTransport = 0
$deepseaResultReferenced = 0
$deepseaNativeBinding = 0
$productionShapedDsh = 0
$durableGenericErrorPrivacy = 0
$followUpRejected = 0
$recoverNoProvider = 0
$cursorUnavailable = 0
$cursorProcessLaunch = 0
$v4ExactSession = 0
$providerModelBound = 0
$reasoningEffortBound = 0
$deepseaModelEffortOverride = 0
$deepseaModelEffortRejected = 0
$profileContained = 0
$childHarnessLaunch = 0

$routeCaps = @{
    'deepsea-codex-cli' = @{
        start = $true; follow_up = $false; recover = $true; exact_native_session = $false
        provider = 'openai-codex'; model = 'gpt-5.6-luna'; reasoning_effort = 'high'
        override_model = 'gpt-5.4'; override_effort = 'xhigh'
        forbidden_model = 'gpt-5.6-luna-priority'; malformed_model = 'gpt/not-valid'; rejected_effort = 'off'
    }
    'deepsea-grok-cli' = @{
        start = $true; follow_up = $false; recover = $true; exact_native_session = $false
        provider = 'xai'; model = 'grok-4.6'; reasoning_effort = 'xhigh'
        override_model = 'grok-4.5'; override_effort = 'high'
        forbidden_model = 'grok-4.6-fast'; malformed_model = 'grok/not-valid'; rejected_effort = 'max'
    }
    'deepsea-v4' = @{
        start = $true; follow_up = $true; recover = $true; exact_native_session = $true
        provider = 'deepseek-official'; model = 'deepseek-v4-flash'; reasoning_effort = ''
        override_model = 'deepseek-v4-pro'; override_effort = 'max'; override_effort_off = 'off'
        forbidden_model = 'deepseek-v4-ultrafast'; malformed_model = 'deepseek/not-valid'; rejected_effort = 'xhigh'
    }
}
$caps = $routeCaps[$RouteId]

try {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    [IO.File]::WriteAllText($promptPath, $promptText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($sidecarPath, 'throw "sidecar"', [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_COUNTER', $counterPath, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_CAPTURE', $capturePath, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_STATE', $mockStatePath, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_PROMPT_SENTINEL', $promptText, 'Process')

    $source = [IO.File]::ReadAllText($invoke)
    $commonSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\adapters\deepsea-common\DeepSea.Common.ps1'))
    Assert-AdapterTest ($commonSource.Contains('--profile') -and $commonSource.Contains('headless')) 'Executable DSH profile surface is missing.'
    Assert-AdapterTest ($commonSource.Contains('-Profile') -and $commonSource.Contains('headless')) 'PowerShell Headless profile surface is missing.'
    Assert-AdapterTest ($commonSource.Contains('--session-out') -and $commonSource.Contains('-SessionOut')) 'DSH session-out surface is missing.'
    Assert-AdapterTest ($commonSource.Contains('reject sidecar or direct-plugin') -or $source.Contains('reject sidecar or direct-plugin')) 'Sidecar rejection is missing.'
    Assert-AdapterTest (-not $source.Contains('EncodedCommand') -and -not $commonSource.Contains('EncodedCommand')) 'EncodedCommand bypass is present.'
    Assert-AdapterTest (-not $commonSource.Contains('Select route')) 'Adapter still asks a model to choose a route.'
    Assert-AdapterTest ($source.Contains([string]$caps.provider) -and $source.Contains([string]$caps.model)) 'Route configuration does not bind provider/model.'
    if ([string]::IsNullOrEmpty([string]$caps.reasoning_effort)) {
        Assert-AdapterTest ($source.Contains("reasoning_effort = ''")) 'Route configuration does not keep the default reasoning effort empty.'
        Assert-AdapterTest ($source.Contains("reasoning_effort = 'high'") -eq $false) 'Route configuration still defaults reasoning effort to high.'
    } else {
        Assert-AdapterTest ($source.Contains([string]$caps.reasoning_effort)) 'Route configuration does not bind the declared reasoning effort.'
    }
    if ($RouteId -ceq 'deepsea-v4') {
        Assert-AdapterTest ([string]$caps.model -ceq 'deepseek-v4-flash') 'DeepSea V4 default model is not deepseek-v4-flash.'
        Assert-AdapterTest ([string]$caps.model -inotmatch '(^|[^A-Za-z0-9])(fast|priority|ultrafast)([^A-Za-z0-9]|$)') 'deepseek-v4-flash was treated as a Fast variant.'
    }
    if ($RouteId -ceq 'deepsea-grok-cli') {
        Assert-AdapterTest ($source.Contains('grok-4.3') -eq $false) 'DeepSea Grok still pins grok-4.3.'
    }

    function Get-MockCount {
        if (-not [IO.File]::Exists($counterPath)) { return 0 }
        return [int][IO.File]::ReadAllText($counterPath)
    }

    $jobId = [Guid]::NewGuid().ToString('D')
    $startArgs = @(
        '-Operation', 'start', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $jobId, '-MockHeadlessPath', $mockHeadless
    )
    $first = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments $startArgs
    Assert-AdapterTest ($first.exit_code -eq 0) "$RouteId start failed: $($first.stderr) $($first.stdout)"
    Assert-AdapterTest ($first.value.headless_only -eq $true) 'Headless-only flag missing.'
    Assert-AdapterTest ($first.value.dsh_owned -eq $true) 'DSH-owned flag missing.'
    Assert-AdapterTest ($first.value.child_harness_launched -eq $false) 'Start launched a child Harness.'
    Assert-AdapterTest ([bool]$first.value.exact_native_session -eq [bool]$caps.exact_native_session) 'Start exact_native_session differed from the descriptor.'
    Assert-AdapterTest ([string]$first.value.provider -ceq [string]$caps.provider) 'Start provider was not bound from route configuration.'
    Assert-AdapterTest ([string]$first.value.model -ceq [string]$caps.model) 'Start model was not bound from route configuration.'
    Assert-AdapterTest ([string]$first.value.reasoning_effort -ceq [string]$caps.reasoning_effort) 'Start reasoning effort was not bound from route configuration.'
    $session = [string]$first.value.native_session_id
    Assert-AdapterTest ($session.StartsWith('dsh-native-')) 'Start inferred a wrapper id instead of a Headless native binding.'
    Assert-NoPromptBody -RequestPath (Join-Path $stateRoot ("jobs\$jobId\request.json")) -PromptText $promptText
    Assert-AdapterTest ((Get-MockCount) -eq 1) 'Start did not execute Headless once.'
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ($capture.used_profile_headless -eq $true -and $capture.used_prompt_argument -eq $true -and $capture.used_prompt_file -eq $false) 'Start did not use the Headless profile surface.'
    Assert-AdapterTest ($capture.prompt_sentinel_present -eq $true) 'Start did not carry the caller prompt to Headless.'
    Assert-AdapterTest ([string]$capture.provider -ceq [string]$caps.provider -and [string]$capture.model -ceq [string]$caps.model) 'Mock DSH did not receive the declared provider/model.'
    if ([string]::IsNullOrEmpty([string]$caps.reasoning_effort)) {
        Assert-AdapterTest ([string]::IsNullOrEmpty([string]$capture.reasoning_effort)) 'Mock DSH carried a reasoning effort on the default start.'
    } else {
        Assert-AdapterTest ([string]$capture.reasoning_effort -ceq [string]$caps.reasoning_effort) 'Mock DSH did not receive the declared reasoning effort.'
    }
    Assert-AdapterTest ($capture.launched_codex_cli -eq $false -and $capture.launched_grok_cli -eq $false -and $capture.launched_cursor_agent -eq $false) 'Mock DSH launched a child Harness.'
    Assert-AdapterTest ($capture.plugin_contained -eq $true) 'Profile plugin path was not contained.'
    $pluginDir = Join-Path $stateRoot ("jobs\$jobId\dsh-home\profiles\headless\plugins\telephone-line")
    $pluginItem = Get-Item -LiteralPath $pluginDir -Force
    Assert-AdapterTest ($pluginItem.PSIsContainer -and (($pluginItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Contained plugin path is not a regular directory.'
    $patchText = [IO.File]::ReadAllText((Join-Path $stateRoot ("jobs\$jobId\dsh-home\profiles\headless\cordis.patch.yml")))
    Assert-AdapterTest ($patchText.Contains('./plugins/telephone-line/')) 'Contained plugin names are not relative ESM specifiers.'
    if ([string]::IsNullOrEmpty([string]$caps.reasoning_effort)) {
        Assert-AdapterTest ($patchText -cnotmatch '(?m)^\s+reasoningEffort\s*:') 'Default start emitted a reasoningEffort line.'
    } else {
        Assert-AdapterTest ($patchText -cmatch ('(?m)^\s+reasoningEffort:\s+' + [regex]::Escape([string]$caps.reasoning_effort) + '\s*$')) 'Contained profile omitted the declared reasoning effort.'
    }
    if ($RouteId -cin @('deepsea-grok-cli', 'deepsea-codex-cli')) {
        foreach ($name in @('subscription-store.mjs', 'subscription-llm.mjs', 'llm-plugin.mjs', 'resolve-modules.mjs')) {
            Assert-AdapterTest ([IO.File]::Exists((Join-Path $pluginDir $name))) "$RouteId contained plugin omitted $name."
        }
        Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $pluginDir 'process-only-store.mjs'))) "$RouteId still copied the PI process-only store."
        Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $pluginDir 'pi-oauth-llm.mjs'))) "$RouteId still copied the PI OAuth LLM adapter."
        $resolveText = [IO.File]::ReadAllText((Join-Path $pluginDir 'resolve-modules.mjs'))
        Assert-AdapterTest ($resolveText.Contains('pi-coding-agent') -eq $false) "$RouteId resolve-modules still loads PI coding-agent."
        $llmText = [IO.File]::ReadAllText((Join-Path $pluginDir 'llm-plugin.mjs'))
        Assert-AdapterTest ($llmText.Contains('telephone-line-llm-subscription')) "$RouteId llm plugin id is not the DSH subscription plugin."
    }
    if ($RouteId -ceq 'deepsea-v4') {
        Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $pluginDir 'llm-plugin.mjs'))) 'DeepSea V4 copied the subscription LLM plugin.'
    }
    $resultPath = Join-Path $stateRoot ("jobs\$jobId\result.json")
    Assert-AdapterTest ([IO.File]::Exists($resultPath)) 'Start did not persist a Headless result.'
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ([string]$result.result_text -ceq 'dsh-result-1') 'Start did not persist the Headless result nonce.'
    Assert-AdapterTest ([string]$result.provider -ceq [string]$caps.provider) 'Result provider drifted from route configuration.'
    $receipt = Get-Content -LiteralPath (Join-Path $stateRoot ("jobs\$jobId\receipt.json")) -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ($null -ne $receipt.result) 'Receipt did not bind the result identity.'
    $stateSentinelCount = Get-AdapterArtifactSentinelCount -Root $stateRoot -Sentinels @($promptText)
    Assert-AdapterTest ($stateSentinelCount -eq 0) 'Adapter state copied the prompt sentinel.'
    $deepseaPromptTransport = 1
    $deepseaResultReferenced = 1
    $deepseaNativeBinding = 1
    $providerModelBound = 1
    $reasoningEffortBound = 1
    $profileContained = 1
    $childHarnessLaunch = 0

    if ([bool]$caps.follow_up) {
        $followArgs = @(
            '-Operation', 'follow_up', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WorkspacePath', $workspace,
            '-PromptFile', $promptPath, '-JobId', ([Guid]::NewGuid().ToString('D')), '-MockHeadlessPath', $mockHeadless
        )
        $follow = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments $followArgs
        Assert-AdapterTest ($follow.exit_code -eq 0) "$RouteId follow-up failed: $($follow.stderr)"
        Assert-AdapterTest ([string]$follow.value.native_session_id -ceq $session) 'Follow-up used another session.'
        Assert-AdapterTest ((Get-MockCount) -eq 2) 'Follow-up did not execute once.'
        $followResult = Get-Content -LiteralPath (Join-Path $stateRoot ("jobs\$($follow.value.job_id)\result.json")) -Raw | ConvertFrom-Json -AsHashtable
        Assert-AdapterTest ([string]$followResult.result_text -ceq 'dsh-result-2') 'Follow-up did not persist a distinct result nonce.'
        $v4ExactSession = 1
        $wrong = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
            '-Operation', 'follow_up', '-NativeSessionId', 'wrong-session', '-StateRoot', $stateRoot, '-WorkspacePath', $workspace,
            '-PromptFile', $promptPath, '-JobId', ([Guid]::NewGuid().ToString('D')), '-MockHeadlessPath', $mockHeadless
        )
        Assert-AdapterTest ($wrong.exit_code -ne 0) 'Wrong native session id was accepted.'
    } else {
        $followArgs = @(
            '-Operation', 'follow_up', '-NativeSessionId', $session, '-StateRoot', $stateRoot, '-WorkspacePath', $workspace,
            '-PromptFile', $promptPath, '-JobId', ([Guid]::NewGuid().ToString('D')), '-MockHeadlessPath', $mockHeadless
        )
        $follow = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments $followArgs
        Assert-AdapterTest ($follow.exit_code -ne 0) "$RouteId follow-up was accepted."
        Assert-AdapterTest ([string]$follow.value.error_code -ceq 'ADAPTER_OPERATION_UNSUPPORTED') 'Follow-up used the wrong error code.'
        Assert-AdapterTest ((Get-MockCount) -eq 1) 'Unsupported follow-up launched a process.'
        $followUpRejected = 1
    }

    $recovered = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $session, '-StateRoot', $stateRoot
    )
    Assert-AdapterTest ($recovered.exit_code -eq 0) "$RouteId recover failed: $($recovered.stderr)"
    Assert-AdapterTest ($recovered.value.replacement_started -eq $false -and $recovered.value.automatic_rerun -eq $false) 'Recover reran Headless.'
    Assert-AdapterTest ([bool]$recovered.value.exact_native_session -eq [bool]$caps.exact_native_session) 'Recover implied a different native-session capability.'
    $countAfterRecover = Get-MockCount
    $expectedAfterRecover = if ([bool]$caps.follow_up) { 2 } else { 1 }
    Assert-AdapterTest ($countAfterRecover -eq $expectedAfterRecover) 'Recover executed Headless or contacted a provider.'
    Assert-AdapterTest ($null -ne $recovered.value.result) 'Recover omitted the result reference.'
    $recoverNoProvider = 1

    $duplicate = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments $startArgs
    Assert-AdapterTest ($duplicate.exit_code -eq 0 -and (Get-MockCount) -eq $expectedAfterRecover) 'Duplicate start reran Headless.'

    $sidecar = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', (Join-Path $testRoot 'sidecar-state'), '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-JobId', ([Guid]::NewGuid().ToString('D')), '-MockHeadlessPath', $sidecarPath
    )
    Assert-AdapterTest ($sidecar.exit_code -ne 0) 'Sidecar or direct-plugin shape was accepted.'

    $malformedRoot = Join-Path $testRoot 'malformed'
    $malformedMock = Join-Path $testRoot 'mock-malformed.ps1'
    [IO.File]::WriteAllText($malformedMock, @"
# SPDX-License-Identifier: MPL-2.0
param([string]`$Profile,[string]`$Resume,[string]`$SessionOut,[string]`$Task)
'not-a-headless-result'
exit 0
"@, [Text.UTF8Encoding]::new($false))
    $malformedJob = [Guid]::NewGuid().ToString('D')
    $malformed = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $malformedRoot, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $malformedJob, '-MockHeadlessPath', $malformedMock
    )
    Assert-AdapterTest ($malformed.exit_code -ne 0) 'Malformed Headless output created a binding.'
    Assert-AdapterTest (-not [IO.Directory]::Exists((Join-Path $malformedRoot 'sessions'))) 'Malformed Headless output created a session directory.'

    $escapeProbe = Join-Path $testRoot 'escape-probe'
    $escapeState = Join-Path $escapeProbe 'state'
    $escapedDir = Join-Path $escapeProbe 'outside\escaped-job'
    [IO.Directory]::CreateDirectory($escapeState) | Out-Null
    $escapeStart = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $escapeState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', '..\..\outside\escaped-job', '-MockHeadlessPath', $mockHeadless
    )
    Assert-AdapterTest ($escapeStart.exit_code -ne 0) "$RouteId escaped JobId was accepted."
    Assert-AdapterTest (-not [IO.Directory]::Exists($escapedDir)) "$RouteId escaped JobId wrote outside StateRoot."
    Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $escapedDir 'receipt.json'))) "$RouteId escaped JobId wrote a receipt outside StateRoot."

    if ($RouteId -cne 'deepsea-v4') {
        $requestRoot = Join-Path $testRoot 'request-file'
        [IO.Directory]::CreateDirectory($requestRoot) | Out-Null
        $requestJob = [Guid]::NewGuid().ToString('D')
        $requestState = Join-Path $testRoot 'request-state'
        [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_STATE', (Join-Path $testRoot 'request-mock-state.json'), 'Process')
        [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_COUNTER', (Join-Path $testRoot 'request-count.txt'), 'Process')
        $requestBody = [ordered]@{
            operation = 'start'
            job_id = $requestJob
            binding_id = 'request-binding'
            cwd = $workspace
            prompt = $promptText
        }
        $requestPath = Join-Path $requestRoot 'start.json'
        [IO.File]::WriteAllText($requestPath, (($requestBody | ConvertTo-Json -Depth 8 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $requested = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
            '-Operation', 'start', '-StateRoot', $requestState, '-RequestFile', $requestPath, '-MockHeadlessPath', $mockHeadless
        )
        Assert-AdapterTest ($requested.exit_code -eq 0) "$RouteId request-file start failed: $($requested.stderr) $($requested.stdout)"
        $requestSession = [string]$requested.value.native_session_id
        Assert-AdapterTest ($requestSession.StartsWith('dsh-native-')) 'Request-file start lacked a Headless native binding.'
        $followRequest = [ordered]@{
            operation = 'followup'
            job_id = [Guid]::NewGuid().ToString('D')
            binding_id = $requestSession
            cwd = $workspace
            prompt = $promptText
        }
        $followRequestPath = Join-Path $requestRoot 'followup.json'
        [IO.File]::WriteAllText($followRequestPath, (($followRequest | ConvertTo-Json -Depth 8 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $requestFollow = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
            '-Operation', 'follow_up', '-NativeSessionId', $requestSession, '-StateRoot', $requestState,
            '-RequestFile', $followRequestPath, '-MockHeadlessPath', $mockHeadless
        )
        Assert-AdapterTest ($requestFollow.exit_code -ne 0) "$RouteId request-file follow-up was accepted."
        $escapeRequestPath = Join-Path $requestRoot 'escape.json'
        $escapeRequest = [ordered]@{
            operation = 'start'
            job_id = '..\..\outside\escaped-job'
            binding_id = 'escape-binding'
            cwd = $workspace
            prompt = $promptText
        }
        [IO.File]::WriteAllText($escapeRequestPath, (($escapeRequest | ConvertTo-Json -Depth 8 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $escapeRequested = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
            '-Operation', 'start', '-StateRoot', $escapeState, '-RequestFile', $escapeRequestPath, '-MockHeadlessPath', $mockHeadless
        )
        Assert-AdapterTest ($escapeRequested.exit_code -ne 0) "$RouteId escaped request job_id was accepted."
        Assert-AdapterTest (-not [IO.Directory]::Exists($escapedDir)) "$RouteId escaped request job_id wrote outside StateRoot."
        Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $escapedDir 'receipt.json'))) "$RouteId escaped request job_id wrote a receipt outside StateRoot."
        $badRequest = [ordered]@{}
        foreach ($key in @($requestBody.Keys)) { $badRequest[$key] = $requestBody[$key] }
        $badRequest['timeout_seconds'] = 1
        $badPath = Join-Path $requestRoot 'bad.json'
        [IO.File]::WriteAllText($badPath, (($badRequest | ConvertTo-Json -Depth 8 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        $bad = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
            '-Operation', 'start', '-StateRoot', (Join-Path $testRoot 'bad-request-state'), '-RequestFile', $badPath, '-MockHeadlessPath', $mockHeadless
        )
        Assert-AdapterTest ($bad.exit_code -ne 0) 'Request file with an extra field was accepted.'
        [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_STATE', $mockStatePath, 'Process')
        [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_COUNTER', $counterPath, 'Process')
        [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_CAPTURE', $capturePath, 'Process')
    }

    $execState = Join-Path $testRoot 'exec-state'
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_STATE', (Join-Path $testRoot 'exec-mock-state.json'), 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_COUNTER', (Join-Path $testRoot 'exec-count.txt'), 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_CAPTURE', (Join-Path $testRoot 'exec-capture.json'), 'Process')
    $execJob = [Guid]::NewGuid().ToString('D')
    $exec = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $execState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $execJob, '-DshCommand', $mockDsh
    )
    Assert-AdapterTest ($exec.exit_code -eq 0) "$RouteId executable DSH start failed: $($exec.stderr) $($exec.stdout)"
    $execCapture = Get-Content -LiteralPath (Join-Path $testRoot 'exec-capture.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ($execCapture.used_profile_headless -eq $true -and $execCapture.used_prompt_file -eq $false) 'Executable DSH command surface was not used.'
    Assert-AdapterTest ([string]$execCapture.provider -ceq [string]$caps.provider) 'Executable DSH did not register the frozen provider.'
    Assert-AdapterTest ([string]$execCapture.model -ceq [string]$caps.model) 'Executable DSH did not register the declared model.'
    if ([string]::IsNullOrEmpty([string]$caps.reasoning_effort)) {
        Assert-AdapterTest ([string]::IsNullOrEmpty([string]$execCapture.reasoning_effort)) 'Executable DSH carried a reasoning effort on the default start.'
    } else {
        Assert-AdapterTest ([string]$execCapture.reasoning_effort -ceq [string]$caps.reasoning_effort) 'Executable DSH did not register the declared reasoning effort.'
    }
    $productionShapedDsh = 1

    $promptFileDirect = Invoke-AdapterEntrypoint -Entrypoint $mockHeadless -Arguments @('-Mode', 'Headless', '-PromptFile', $promptPath)
    Assert-AdapterTest ($promptFileDirect.exit_code -ne 0) 'Headless fixture accepted an out-of-root PromptFile.'

    if ($RouteId -ceq 'deepsea-v4') {
        Assert-AdapterTest ($first.value.secret_file_loaded -eq $false) 'DeepSea V4 loaded a secret file.'
        Assert-AdapterTest (-not $source.Contains('API_KEY')) 'DeepSea V4 still reads a secret file.'
    }

    $failState = Join-Path $testRoot 'fail-state'
    $failMock = Join-Path $testRoot 'fail-mock.ps1'
    $failSentinelLine = ($sentinels.prompt + ' ' + $sentinels.email + ' ' + $sentinels.path + ' ' + $sentinels.key)
    [IO.File]::WriteAllText($failMock, @"
# SPDX-License-Identifier: MPL-2.0
param([string]`$Profile,[string]`$Resume,[string]`$SessionOut,[string]`$Task)
`$host.UI.WriteErrorLine([string]`$env:TELEPHONE_LINE_MOCK_FAIL_TEXT)
exit 1
"@, [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_FAIL_TEXT', $failSentinelLine, 'Process')
    $failJob = [Guid]::NewGuid().ToString('D')
    $failed = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $failState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $failJob, '-MockHeadlessPath', $failMock
    )
    Assert-AdapterTest ($failed.exit_code -ne 0) 'Forced Headless failure was treated as success.'
    $failCount = Get-AdapterArtifactSentinelCount -Root $failState -Sentinels @($sentinels.prompt, $sentinels.email, $sentinels.path, $sentinels.key)
    Assert-AdapterTest ($failCount -eq 0) 'DeepSea durable failure artifacts retained a synthetic sentinel.'
    $failReceiptPath = Join-Path $failState ("jobs\$failJob\receipt.json")
    Assert-AdapterTest ([IO.File]::Exists($failReceiptPath)) 'Forced Headless failure did not preserve generic receipt state.'
    $failReceipt = Get-Content -LiteralPath $failReceiptPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest (-not [string]::IsNullOrWhiteSpace([string]$failReceipt.error_code)) 'Forced Headless failure omitted an error code.'
    $durableGenericErrorPrivacy = 1

    $overrideState = Join-Path $testRoot 'override-state'
    $overrideCapture = Join-Path $testRoot 'override-capture.json'
    $overrideCounter = Join-Path $testRoot 'override-count.txt'
    $overrideMockState = Join-Path $testRoot 'override-mock-state.json'
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_STATE', $overrideMockState, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_COUNTER', $overrideCounter, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_CAPTURE', $overrideCapture, 'Process')
    $overrideJob = [Guid]::NewGuid().ToString('D')
    $overridden = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $overrideState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $overrideJob, '-MockHeadlessPath', $mockHeadless,
        '-Model', [string]$caps.override_model, '-ReasoningEffort', [string]$caps.override_effort
    )
    Assert-AdapterTest ($overridden.exit_code -eq 0) "$RouteId override start failed: $($overridden.stderr) $($overridden.stdout)"
    Assert-AdapterTest ([string]$overridden.value.model -ceq [string]$caps.override_model) 'Override model did not bind on the adapter result.'
    Assert-AdapterTest ([string]$overridden.value.reasoning_effort -ceq [string]$caps.override_effort) 'Override reasoning effort did not bind on the adapter result.'
    $overrideCaptureValue = Get-Content -LiteralPath $overrideCapture -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ([string]$overrideCaptureValue.model -ceq [string]$caps.override_model) 'Mock DSH did not receive the override model.'
    Assert-AdapterTest ([string]$overrideCaptureValue.reasoning_effort -ceq [string]$caps.override_effort) 'Mock DSH did not receive the override reasoning effort.'
    $overridePatch = [IO.File]::ReadAllText((Join-Path $overrideState ("jobs\$overrideJob\dsh-home\profiles\headless\cordis.patch.yml")))
    Assert-AdapterTest ($overridePatch -cmatch ('(?m)^\s+reasoningEffort:\s+' + [regex]::Escape([string]$caps.override_effort) + '\s*$')) 'Override start omitted the configured reasoningEffort line.'
    $deepseaModelEffortOverride = 1

    if ($RouteId -ceq 'deepsea-v4') {
        $offState = Join-Path $testRoot 'override-off-state'
        $offCapture = Join-Path $testRoot 'override-off-capture.json'
        $offCounter = Join-Path $testRoot 'override-off-count.txt'
        $offMockState = Join-Path $testRoot 'override-off-mock-state.json'
        [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_STATE', $offMockState, 'Process')
        [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_COUNTER', $offCounter, 'Process')
        [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_CAPTURE', $offCapture, 'Process')
        $offJob = [Guid]::NewGuid().ToString('D')
        $offOverridden = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments @(
            '-Operation', 'start', '-StateRoot', $offState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
            '-JobId', $offJob, '-MockHeadlessPath', $mockHeadless,
            '-ReasoningEffort', [string]$caps.override_effort_off
        )
        Assert-AdapterTest ($offOverridden.exit_code -eq 0) "$RouteId explicit off start failed: $($offOverridden.stderr) $($offOverridden.stdout)"
        Assert-AdapterTest ([string]$offOverridden.value.model -ceq [string]$caps.model) 'Explicit off changed the default V4 model.'
        Assert-AdapterTest ([string]$offOverridden.value.reasoning_effort -ceq [string]$caps.override_effort_off) 'Explicit off did not bind on the adapter result.'
        $offCaptureValue = Get-Content -LiteralPath $offCapture -Raw | ConvertFrom-Json -AsHashtable
        Assert-AdapterTest ([string]$offCaptureValue.reasoning_effort -ceq [string]$caps.override_effort_off) 'Mock DSH did not receive explicit off.'
        $offPatch = [IO.File]::ReadAllText((Join-Path $offState ("jobs\$offJob\dsh-home\profiles\headless\cordis.patch.yml")))
        Assert-AdapterTest ($offPatch -cmatch '(?m)^\s+reasoningEffort:\s+off\s*$') 'Explicit off omitted the reasoningEffort line.'
    }

    function Invoke-RejectedDeepSeaStart {
        param(
            [Parameter(Mandatory = $true)][string]$Label,
            [Parameter(Mandatory = $true)][string]$ChildRoot,
            [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$ExtraArguments,
            [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Sentinels
        )
        $rejectState = Join-Path $ChildRoot 'state'
        $rejectJob = [Guid]::NewGuid().ToString('D')
        [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_STATE', (Join-Path $ChildRoot 'mock-state.json'), 'Process')
        [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_COUNTER', (Join-Path $ChildRoot 'count.txt'), 'Process')
        [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_CAPTURE', (Join-Path $ChildRoot 'capture.json'), 'Process')
        $rejectArgs = @(
            '-Operation', 'start', '-StateRoot', $rejectState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
            '-JobId', $rejectJob, '-MockHeadlessPath', $mockHeadless
        ) + $ExtraArguments
        $rejected = Invoke-AdapterEntrypoint -Entrypoint $invoke -Arguments $rejectArgs
        Assert-AdapterTest ($rejected.exit_code -ne 0) "$RouteId $Label was accepted."
        if ($null -ne $rejected.value -and $rejected.value -is [Collections.IDictionary] -and $rejected.value.Contains('error_code')) {
            Assert-AdapterTest ([string]$rejected.value.error_code -ceq 'ADAPTER_REQUEST_INVALID') "$RouteId $Label used the wrong error code."
        }
        if ($null -ne $rejected.value -and $rejected.value -is [Collections.IDictionary] -and $rejected.value.Contains('error_message')) {
            $publicMessage = [string]$rejected.value.error_message
            Assert-AdapterTest (-not [string]::IsNullOrWhiteSpace($publicMessage)) "$RouteId $Label omitted a public error message."
            foreach ($sentinel in $Sentinels) {
                if ([string]::IsNullOrWhiteSpace($sentinel)) { continue }
                Assert-AdapterTest ($publicMessage.Contains($sentinel) -eq $false) "$RouteId $Label leaked a caller value into the adapter result."
            }
        }
        $leakCount = Get-AdapterArtifactSentinelCount -Root $rejectState -Sentinels $Sentinels
        Assert-AdapterTest ($leakCount -eq 0) "$RouteId $Label leaked a caller value into durable state."
    }

    Invoke-RejectedDeepSeaStart -Label 'empty model' -ChildRoot (Join-Path $testRoot 'reject-empty-model') -ExtraArguments @('-Model', '') -Sentinels @()
    Invoke-RejectedDeepSeaStart -Label 'whitespace model' -ChildRoot (Join-Path $testRoot 'reject-whitespace-model') -ExtraArguments @('-Model', ' ') -Sentinels @()
    Invoke-RejectedDeepSeaStart -Label 'malformed model' -ChildRoot (Join-Path $testRoot 'reject-malformed-model') -ExtraArguments @('-Model', [string]$caps.malformed_model) -Sentinels @([string]$caps.malformed_model)
    Invoke-RejectedDeepSeaStart -Label 'out-of-set effort' -ChildRoot (Join-Path $testRoot 'reject-effort') -ExtraArguments @('-ReasoningEffort', [string]$caps.rejected_effort) -Sentinels @([string]$caps.rejected_effort)
    Invoke-RejectedDeepSeaStart -Label 'forbidden model variant' -ChildRoot (Join-Path $testRoot 'reject-fast-model') -ExtraArguments @('-Model', [string]$caps.forbidden_model) -Sentinels @([string]$caps.forbidden_model)
    $deepseaModelEffortRejected = 1

    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_STATE', $mockStatePath, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_COUNTER', $counterPath, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_LINE_MOCK_HEADLESS_CAPTURE', $capturePath, 'Process')

    [ordered]@{
        success = $true
        route_id = $RouteId
        headless_only = 1
        sidecar_rejected = 1
        exact_session = [int][bool]$caps.exact_native_session
        recover_no_rerun = 1
        deepsea_prompt_transport = $deepseaPromptTransport
        deepsea_result_referenced = $deepseaResultReferenced
        deepsea_native_binding = $deepseaNativeBinding
        production_shaped_dsh_invocation = $productionShapedDsh
        durable_generic_error_privacy = $durableGenericErrorPrivacy
        follow_up_rejected = $followUpRejected
        recover_no_provider = $recoverNoProvider
        cursor_unavailable = $cursorUnavailable
        cursor_process_launch = $cursorProcessLaunch
        v4_exact_native_session = $v4ExactSession
        provider_model_bound = $providerModelBound
        reasoning_effort_bound = $reasoningEffortBound
        deepsea_model_effort_override = $deepseaModelEffortOverride
        deepsea_model_effort_rejected = $deepseaModelEffortRejected
        profile_contained = $profileContained
        child_harness_launch = $childHarnessLaunch
        assertions = $assertions
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{ success = $false; route_id = $RouteId; error = [string]$_.Exception.Message; assertions = $assertions } | ConvertTo-Json -Compress
    exit 1
} finally {
    foreach ($name in @(
        'TELEPHONE_LINE_MOCK_HEADLESS_COUNTER',
        'TELEPHONE_LINE_MOCK_HEADLESS_CAPTURE',
        'TELEPHONE_LINE_MOCK_HEADLESS_STATE',
        'TELEPHONE_LINE_MOCK_PROMPT_SENTINEL',
        'TELEPHONE_LINE_MOCK_FAIL_TEXT',
        'TELEPHONE_LINE_MOCK_DSH_EXECUTABLE'
    )) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
exit 0
