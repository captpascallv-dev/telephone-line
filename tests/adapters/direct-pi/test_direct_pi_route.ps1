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
$payload = '{"type":"session","version":3,"id":"' + $sessionId + '","cwd":"' + $cwdJson + '"}' + $nl +
    '{"type":"agent_start"}' + $nl +
    '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"pi-mock-ok"}],"stopReason":"stop"}}' + $nl +
    '{"type":"agent_end"}' + $nl
$payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes($payload)
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

    [ordered]@{
        success = $true
        session_file = 1
        exact_session = 1
        recover_no_rerun = 1
        pi_path_discovery = $piPathDiscovery
        durable_generic_error_privacy = 1
        assertions = $assertions
    } | ConvertTo-Json -Compress
} finally {
    [Environment]::SetEnvironmentVariable('DIRECT_PI_MOCK_COUNTER', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_PI_FAIL_TEXT', $null, 'Process')
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
