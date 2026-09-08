# SPDX-License-Identifier: MPL-2.0
# Current Understanding (execution, 2026-08-27 terminal lineage closure):
# 1. Phase: close residual Direct Grok terminal-lineage FAIL on candidate 34ace90; preserve wireless, nested unbounded wait, and passing event-chain; amend the same one commit over 6c9d25e.
# 2. Denominator: successful terminals require a round-trip-valid exact created_at_utc and a durable cli_stdout identity proven against captured output. Unparsable matching timestamps fail closed. No CE/smoke/GitHub/release.
# 3. Only next step: implement that matcher/resolve closure, extend focused Direct Grok negatives, amend the same candidate.
# 4. Frozen non-goals: no App Server/dashboard/core mutation, no runtime activation, black-box smoke, docs/catalog/package.
# 5. Exit: focused proof union + dashboard no-delta, clean one commit over 6c9d25e, self_accepted=false; not project PASS.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TestRoot,
    [switch]$ProofsOnly
)

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
    Assert-AdapterTest ($routeSource.Contains('write-occupancy.json')) 'Same-session write occupancy is missing.'
    Assert-AdapterTest ($routeSource.Contains('Test-DirectGrokExactOwnerFileAlive')) 'Exact child/host occupancy identity is missing.'
    Assert-AdapterTest ($routeSource.Contains('if (Test-DirectGrokJobWriteLive -Paths $Paths) { return }')) 'Receipt still releases a live same-session writer.'
    Assert-AdapterTest ($routeSource.Contains('if (-not [IO.File]::Exists([string]$SessionPaths.occupancy)) { return $null }')) 'Binding latest_job_id publish is not occupancy-gated.'
    Assert-AdapterTest (-not $routeSource.Contains('[IO.File]::WriteAllBytes($sessionPaths.binding')) 'Binding still uses non-atomic WriteAllBytes.'

    if ($ProofsOnly) {
        $pwshPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $proofInvoke = Join-Path $adapterCopy 'Invoke-DirectGrokRoute.ps1'
        $mockGrokPs1 = Join-Path $testRoot 'proof-mock-grok.ps1'
        $mockGrokCmd = Join-Path $testRoot 'proof-mock-grok.cmd'
        $stampDir = Join-Path $testRoot 'stamps'
        [IO.Directory]::CreateDirectory($stampDir) | Out-Null
        [IO.File]::WriteAllText($mockGrokPs1, @'
$session = ''
for ($i = 0; $i -lt $args.Count; $i++) {
    if ([string]$args[$i] -ceq '--session-id' -or [string]$args[$i] -ceq '--resume') { $session = [string]$args[$i + 1] }
}
$invDir = [string]$env:DIRECT_GROK_MOCK_INVOCATION_DIR
if (-not [string]::IsNullOrWhiteSpace($invDir)) {
    if (-not [IO.Directory]::Exists($invDir)) { [IO.Directory]::CreateDirectory($invDir) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $invDir ([Guid]::NewGuid().ToString('N') + '.txt')), [string]$session, [Text.UTF8Encoding]::new($false))
}
$sec = 0
if (-not [string]::IsNullOrWhiteSpace($env:TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS)) { $sec = [int]$env:TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS }
if ($sec -gt 0) { Start-Sleep -Seconds $sec }
[ordered]@{ sessionId = $session; ok = $true } | ConvertTo-Json -Compress
'@, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($mockGrokCmd, "@echo off`r`n`"$pwshPath`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$mockGrokPs1`" %*`r`nexit /b %ERRORLEVEL%`r`n", [Text.UTF8Encoding]::new($false))
        function Get-ProofStampCount {
            if (-not [IO.Directory]::Exists($stampDir)) { return 0 }
            return @(Get-ChildItem -LiteralPath $stampDir -File -ErrorAction SilentlyContinue).Count
        }
        function Stop-ProofJob {
            param([string]$JobRoot)
            foreach ($name in @('grok-child-owner.json', 'owner.json')) {
                $ownerFile = Join-Path $JobRoot $name
                if (-not [IO.File]::Exists($ownerFile)) { continue }
                try {
                    $doc = Get-Content -LiteralPath $ownerFile -Raw | ConvertFrom-Json -AsHashtable
                    if ($doc.Contains('pid') -and [int]$doc.pid -gt 0) {
                        $proc = Get-Process -Id ([int]$doc.pid) -ErrorAction SilentlyContinue
                        if ($null -ne $proc) {
                            try { $proc.Kill($true) } catch { }
                            $null = $proc.WaitForExit(3000)
                            $proc.Dispose()
                        }
                    }
                } catch { }
            }
        }
        function Start-ProofRoute {
            param([Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments)
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $pwshPath
            $info.UseShellExecute = $false
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $info.CreateNoWindow = $true
            foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $proofInvoke) + $Arguments) {
                [void]$info.ArgumentList.Add([string]$argument)
            }
            return [Diagnostics.Process]::Start($info)
        }
        function Wait-ProofRoute {
            param($Process, [int]$TimeoutMs)
            $stdoutTask = $Process.StandardOutput.ReadToEndAsync()
            $stderrTask = $Process.StandardError.ReadToEndAsync()
            $exited = $Process.WaitForExit($TimeoutMs)
            if (-not $exited) { try { $Process.Kill($true) } catch { }; throw 'Proof route exceeded the watchdog.' }
            $text = [string]$stdoutTask.GetAwaiter().GetResult()
            $err = [string]$stderrTask.GetAwaiter().GetResult()
            $value = $null
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                try { $value = $text | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String } catch { }
            }
            return [ordered]@{ exit_code = [int]$Process.ExitCode; stdout = $text; stderr = $err; value = $value }
        }

        [Environment]::SetEnvironmentVariable('DIRECT_GROK_MOCK_INVOCATION_DIR', $stampDir, 'Process')
        $r1State = Join-Path $testRoot 'r1-state'
        $r1Start = Invoke-AdapterEntrypoint -Entrypoint $proofInvoke -Arguments @(
            '-Operation', 'start', '-StateRoot', $r1State, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
            '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '20'
        )
        Assert-AdapterTest ($r1Start.exit_code -eq 0) "R1 start failed: $($r1Start.stderr)"
        $r1Session = [string]$r1Start.value.native_session_id
        $stampsAfterStart = Get-ProofStampCount
        [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS', '24', 'Process')
        [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SIMULATE_STOP_FAILURE', '1', 'Process')
        $failedJob = [Guid]::NewGuid().ToString('D')
        $failedSw = [Diagnostics.Stopwatch]::StartNew()
        $failed = Invoke-AdapterEntrypoint -Entrypoint $proofInvoke -Arguments @(
            '-Operation', 'follow_up', '-NativeSessionId', $r1Session, '-StateRoot', $r1State, '-WorkspacePath', $workspace,
            '-PromptFile', $promptPath, '-JobId', $failedJob, '-GrokCommand', $mockGrokCmd, '-GrokTimeoutSeconds', '1', '-WaitTimeoutSeconds', '18'
        )
        $failedSw.Stop()
        Assert-AdapterTest ($failed.exit_code -eq 4) "R1 stop-fail did not return honest exit 4: $($failed.exit_code) $($failed.stderr)"
        Assert-AdapterTest ($failed.value.transport_complete -ne $true) 'R1 stop-fail advertised transport complete.'
        Assert-AdapterTest ($failedSw.ElapsedMilliseconds -lt 20000) 'R1 stop-fail was not bounded.'
        $failedRoot = Join-Path $r1State ("jobs\$failedJob")
        $childPath = Join-Path $failedRoot 'grok-child-owner.json'
        Assert-AdapterTest ([IO.File]::Exists($childPath)) 'R1 omitted child-owner evidence.'
        $child = Get-Content -LiteralPath $childPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-AdapterTest ($child.stop_confirmed -ne $true) 'R1 claimed a confirmed stop.'
        $oldChild = Get-Process -Id ([int]$child.pid) -ErrorAction SilentlyContinue
        $beforeAlive = $null -ne $oldChild -and $oldChild.StartTime.ToUniversalTime().Ticks -eq [int64]$child.start_time_utc_ticks
        Assert-AdapterTest ($beforeAlive) 'R1 expected the exact old child to remain alive.'
        $occupancyPath = Join-Path $r1State ("sessions\$r1Session\write-occupancy.json")
        Assert-AdapterTest ([IO.File]::Exists($occupancyPath)) 'R1 released occupancy while the exact old child was still live.'
        $occDoc = Get-Content -LiteralPath $occupancyPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-AdapterTest ([string]$occDoc.job_id -ceq $failedJob) 'R1 occupancy did not retain the failed writer job.'
        [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS', $null, 'Process')
        [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SIMULATE_STOP_FAILURE', $null, 'Process')
        $stampsBeforeNext = Get-ProofStampCount
        $nextJob = [Guid]::NewGuid().ToString('D')
        $nextSw = [Diagnostics.Stopwatch]::StartNew()
        $next = Invoke-AdapterEntrypoint -Entrypoint $proofInvoke -Arguments @(
            '-Operation', 'follow_up', '-NativeSessionId', $r1Session, '-StateRoot', $r1State, '-WorkspacePath', $workspace,
            '-PromptFile', $promptPath, '-JobId', $nextJob, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '8'
        )
        $nextSw.Stop()
        $oldChild = Get-Process -Id ([int]$child.pid) -ErrorAction SilentlyContinue
        $afterAlive = $null -ne $oldChild -and $oldChild.StartTime.ToUniversalTime().Ticks -eq [int64]$child.start_time_utc_ticks
        Assert-AdapterTest ($afterAlive) 'R1 next follow_up ran after the exact old child disappeared.'
        Assert-AdapterTest ($next.exit_code -eq 3) "R1 successor was not blocked: $($next.exit_code) $($next.stderr) $($next.stdout)"
        Assert-AdapterTest ((Get-ProofStampCount) -eq $stampsBeforeNext) 'R1 successor launched a overlapping Grok write.'
        Assert-AdapterTest ([IO.File]::Exists($occupancyPath)) 'R1 occupancy vanished before exact owner exit.'
        Assert-AdapterTest ($next.value.automatic_rerun -eq $false -and $next.value.replacement_started -eq $false) 'R1 successor advertised a replacement.'
        $overlapping = ($beforeAlive -and $afterAlive -and $next.exit_code -eq 0)
        Assert-AdapterTest (-not $overlapping) 'R1 overlapping same-session write still reproduced.'
        Stop-ProofJob -JobRoot $failedRoot
        if ($null -ne $oldChild) { try { $oldChild.Dispose() } catch { } }

        $r2State = Join-Path $testRoot 'r2-state'
        $r2Start = Invoke-AdapterEntrypoint -Entrypoint $proofInvoke -Arguments @(
            '-Operation', 'start', '-StateRoot', $r2State, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
            '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '20'
        )
        Assert-AdapterTest ($r2Start.exit_code -eq 0) "R2 start failed: $($r2Start.stderr)"
        $r2Session = [string]$r2Start.value.native_session_id
        $r2Binding = Join-Path $r2State ("sessions\$r2Session\binding.json")
        [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS', '1', 'Process')
        [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_DELAY_BINDING_MS', '2500', 'Process')
        $followA = [Guid]::NewGuid().ToString('D')
        $followB = [Guid]::NewGuid().ToString('D')
        $pA = Start-ProofRoute -Arguments @(
            '-Operation', 'follow_up', '-NativeSessionId', $r2Session, '-StateRoot', $r2State, '-WorkspacePath', $workspace,
            '-PromptFile', $promptPath, '-JobId', $followA, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '20'
        )
        $ownerA = Join-Path $r2State ("jobs\$followA\owner.json")
        $ownerWait = [DateTimeOffset]::UtcNow.AddSeconds(8)
        while ([DateTimeOffset]::UtcNow -lt $ownerWait -and -not [IO.File]::Exists($ownerA)) { Start-Sleep -Milliseconds 50 }
        $pB = Start-ProofRoute -Arguments @(
            '-Operation', 'follow_up', '-NativeSessionId', $r2Session, '-StateRoot', $r2State, '-WorkspacePath', $workspace,
            '-PromptFile', $promptPath, '-JobId', $followB, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '20'
        )
        $aDone = Wait-ProofRoute -Process $pA -TimeoutMs 30000
        $bDone = Wait-ProofRoute -Process $pB -TimeoutMs 30000
        $pA.Dispose(); $pB.Dispose()
        Assert-AdapterTest ($aDone.exit_code -eq 0 -and $bDone.exit_code -eq 0) "R2 serialized follow_ups failed: $($aDone.exit_code) $($bDone.exit_code)"
        $binding = Get-Content -LiteralPath $r2Binding -Raw | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
        Assert-AdapterTest ([string]$binding.latest_job_id -ceq $followB) "R2 stale tail regressed latest_job_id to $($binding.latest_job_id)"
        $reqA = Get-Content -LiteralPath (Join-Path $r2State ("jobs\$followA\request.json")) -Raw | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
        $reqB = Get-Content -LiteralPath (Join-Path $r2State ("jobs\$followB\request.json")) -Raw | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
        Assert-AdapterTest ([string]$reqB.created_at_utc -cgt [string]$reqA.created_at_utc) 'R2 successor was not the later writer.'
        $recover = Invoke-AdapterEntrypoint -Entrypoint $proofInvoke -Arguments @(
            '-Operation', 'recover', '-NativeSessionId', $r2Session, '-StateRoot', $r2State, '-WaitTimeoutSeconds', '15'
        )
        Assert-AdapterTest ([string]$recover.value.job_id -ceq $followB) "R2 recover did not follow the current writer: $($recover.value.job_id)"
        [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_DELAY_BINDING_MS', $null, 'Process')
        [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS', $null, 'Process')

        [ordered]@{
            success = $true
            proofs_only = $true
            r1_occupancy_after_failure = $true
            r1_exact_old_child_alive_before_next = [bool]$beforeAlive
            r1_successor_blocked = $true
            overlapping_write_reproduced = $false
            r2_latest_is_successor = $true
            assertions = $assertions
        } | ConvertTo-Json -Compress
        return
    }
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
    Assert-AdapterTest ($wrapperSource.Contains('Get-DirectGrokStopCleanupMilliseconds')) 'Bounded timeout cleanup is missing.'
    Assert-AdapterTest ($wrapperSource.Contains('ADAPTER_GROK_STOP_FAILED')) 'Stop-failure catalog is missing.'
    Assert-AdapterTest ($wrapperSource.Contains("'bypassPermissions'")) 'Direct Grok permission mode was changed.'
    $grokDoc = [IO.File]::ReadAllText((Join-Path $repoRoot 'docs\adapters\direct-grok-cli.md'))
    $readmeEn = [IO.File]::ReadAllText((Join-Path $repoRoot 'README.md'))
    $readmeZh = [IO.File]::ReadAllText((Join-Path $repoRoot 'docs\README.zh-CN.md'))
    Assert-AdapterTest ($grokDoc.Contains('bypassPermissions') -and $grokDoc.Contains('not a sandbox')) 'Direct Grok adapter docs omit bypassPermissions posture.'
    Assert-AdapterTest ($readmeEn.Contains('bypassPermissions') -and $readmeEn.Contains('not a sandbox')) 'English README omits bypassPermissions posture.'
    Assert-AdapterTest ($readmeZh.Contains('bypassPermissions') -and $readmeZh.Contains('不是沙箱')) 'Chinese README omits bypassPermissions posture.'
    Assert-AdapterTest (-not $wrapperSource.Contains('WARNING: cwd is not a sandbox')) 'Wrapper stdout grew a permission warning banner.'

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
$invDir = [string]$env:DIRECT_GROK_MOCK_INVOCATION_DIR
if (-not [string]::IsNullOrWhiteSpace($invDir)) {
    if (-not [IO.Directory]::Exists($invDir)) { [IO.Directory]::CreateDirectory($invDir) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $invDir ([Guid]::NewGuid().ToString('N') + '.txt')), '1', [Text.UTF8Encoding]::new($false))
}
if ($mode -ceq 'sleep') {
    $sec = 25
    if (-not [string]::IsNullOrWhiteSpace($env:TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS)) { $sec = [int]$env:TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS }
    Start-Sleep -Seconds $sec
}
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

    $stampDir = Join-Path $testRoot 'stamps'
    [IO.Directory]::CreateDirectory($stampDir) | Out-Null
    [Environment]::SetEnvironmentVariable('DIRECT_GROK_MOCK_INVOCATION_DIR', $stampDir, 'Process')
    function Get-StampCount {
        if (-not [IO.Directory]::Exists($stampDir)) { return 0 }
        return @(Get-ChildItem -LiteralPath $stampDir -File -ErrorAction SilentlyContinue).Count
    }
    function Stop-DirectGrokTestJob {
        param([string]$JobRoot)
        foreach ($name in @('grok-child-owner.json', 'owner.json')) {
            $ownerFile = Join-Path $JobRoot $name
            if (-not [IO.File]::Exists($ownerFile)) { continue }
            try {
                $doc = Get-Content -LiteralPath $ownerFile -Raw | ConvertFrom-Json -AsHashtable
                if ($doc.Contains('pid') -and [int]$doc.pid -gt 0) {
                    $proc = Get-Process -Id ([int]$doc.pid) -ErrorAction SilentlyContinue
                    if ($null -ne $proc) {
                        try { $proc.Kill($true) } catch { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
                        $proc.Dispose()
                    }
                }
            } catch { }
        }
    }
    function Invoke-RouteWatchdog {
        param([Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments, [int]$TimeoutMs)
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $pwshPath
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.CreateNoWindow = $true
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $durableInvoke) + $Arguments) {
            [void]$info.ArgumentList.Add([string]$argument)
        }
        $proc = [Diagnostics.Process]::Start($info)
        try {
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            $exited = $proc.WaitForExit($TimeoutMs)
            if (-not $exited) {
                try { $proc.Kill($true) } catch { }
                $null = $proc.WaitForExit(3000)
                throw 'Direct Grok route exceeded the test watchdog.'
            }
            $text = [string]$stdoutTask.GetAwaiter().GetResult()
            $err = [string]$stderrTask.GetAwaiter().GetResult()
            $value = $null
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                try { $value = $text | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String } catch { }
            }
            return [ordered]@{ exit_code = [int]$proc.ExitCode; stdout = $text; stderr = $err; value = $value }
        } finally { $proc.Dispose() }
    }
    function Start-RouteProcess {
        param([Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments)
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $pwshPath
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.CreateNoWindow = $true
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $durableInvoke) + $Arguments) {
            [void]$info.ArgumentList.Add([string]$argument)
        }
        return [Diagnostics.Process]::Start($info)
    }

    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_MOCK_MODE', 'sleep', 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS', '3', 'Process')
    $unlimitedState = Join-Path $testRoot 'unlimited-state'
    $unlimitedJob = [Guid]::NewGuid().ToString('D')
    $unlimited = Invoke-AdapterEntrypoint -Entrypoint $durableEntry -Arguments @(
        '-WorkspacePath', $workspace, '-PromptFile', $promptPath, '-JobId', $unlimitedJob,
        '-StateRoot', $unlimitedState, '-GrokCommand', $mockGrokCmd, '-GrokTimeoutSeconds', '0', '-WaitTimeoutSeconds', '20'
    )
    Assert-AdapterTest ($unlimited.exit_code -eq 0) "Unlimited GrokTimeoutSeconds=0 failed: $($unlimited.stderr) $($unlimited.stdout)"
    Assert-AdapterTest ($unlimited.value.transport_complete -eq $true) 'Unlimited work was not transport complete.'
    Assert-AdapterTest ($unlimited.value.automatic_rerun -eq $false -and $unlimited.value.replacement_started -eq $false) 'Unlimited work advertised a replacement.'

    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS', '20', 'Process')
    $timeoutState = Join-Path $testRoot 'timeout-state'
    $timeoutJob = [Guid]::NewGuid().ToString('D')
    $timeoutSw = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = Invoke-RouteWatchdog -TimeoutMs 25000 -Arguments @(
        '-Operation', 'start', '-StateRoot', $timeoutState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $timeoutJob, '-GrokCommand', $mockGrokCmd, '-GrokTimeoutSeconds', '1', '-WaitTimeoutSeconds', '30'
    )
    $timeoutSw.Stop()
    Assert-AdapterTest ($timedOut.exit_code -ne 0) 'Caller-selected Grok timeout was treated as success.'
    Assert-AdapterTest ($timedOut.value.transport_complete -ne $true) 'Timed-out Grok advertised transport complete.'
    Assert-AdapterTest ($timedOut.value.automatic_rerun -eq $false -and $timedOut.value.replacement_started -eq $false) 'Timed-out Grok advertised a replacement.'
    Assert-AdapterTest ($timeoutSw.ElapsedMilliseconds -lt 20000) 'Caller-selected Grok timeout cleanup was not bounded.'
    $timeoutJobRoot = Join-Path $timeoutState ("jobs\$timeoutJob")
    $timeoutChildPath = Join-Path $timeoutJobRoot 'grok-child-owner.json'
    Assert-AdapterTest ([IO.File]::Exists($timeoutChildPath)) 'Confirmed timeout omitted child-owner evidence.'
    $timeoutChild = Get-Content -LiteralPath $timeoutChildPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ($timeoutChild.stop_attempted -eq $true) 'Confirmed timeout did not record a stop attempt.'
    Assert-AdapterTest ($timeoutChild.stop_confirmed -eq $true) 'Successful timeout stop was not confirmed.'
    Assert-AdapterTest ($timeoutChild.process_exited -eq $true) 'Successful timeout stop left the child running without saying so.'
    Assert-AdapterTest ($timeoutChild.automatic_rerun -eq $false -and $timeoutChild.replacement_started -eq $false) 'Timeout child owner advertised a replacement.'
    $timeoutResultPath = Join-Path $timeoutJobRoot 'grok-result.json'
    Assert-AdapterTest ([IO.File]::Exists($timeoutResultPath)) 'Timed-out route omitted grok-result.json.'
    $timeoutResult = Get-Content -LiteralPath $timeoutResultPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ($timeoutResult.success -ne $true) 'Timed-out wrapper claimed success.'
    Assert-AdapterTest ([string]$timeoutResult.error -ceq 'Official Grok CLI exceeded the caller-selected timeout.') 'Timed-out wrapper used the wrong public error.'
    Stop-DirectGrokTestJob -JobRoot $timeoutJobRoot

    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SIMULATE_STOP_FAILURE', '1', 'Process')
    $stopFailState = Join-Path $testRoot 'stop-fail-state'
    $stopFailJob = [Guid]::NewGuid().ToString('D')
    $stopFailSw = [Diagnostics.Stopwatch]::StartNew()
    $stopFailed = Invoke-RouteWatchdog -TimeoutMs 25000 -Arguments @(
        '-Operation', 'start', '-StateRoot', $stopFailState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $stopFailJob, '-GrokCommand', $mockGrokCmd, '-GrokTimeoutSeconds', '1', '-WaitTimeoutSeconds', '30'
    )
    $stopFailSw.Stop()
    Assert-AdapterTest ($stopFailed.exit_code -ne 0) 'Stop-failure path was treated as success.'
    Assert-AdapterTest ($stopFailed.value.transport_complete -ne $true) 'Stop-failure advertised transport complete.'
    Assert-AdapterTest ($stopFailed.value.automatic_rerun -eq $false -and $stopFailed.value.replacement_started -eq $false) 'Stop-failure advertised a replacement.'
    Assert-AdapterTest ($stopFailSw.ElapsedMilliseconds -lt 20000) 'Stop-failure cleanup wait was unbounded.'
    $stopFailRoot = Join-Path $stopFailState ("jobs\$stopFailJob")
    $stopFailChildPath = Join-Path $stopFailRoot 'grok-child-owner.json'
    Assert-AdapterTest ([IO.File]::Exists($stopFailChildPath)) 'Stop-failure omitted exact-owner recovery evidence.'
    $stopFailChild = Get-Content -LiteralPath $stopFailChildPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ($stopFailChild.stop_confirmed -ne $true) 'Stop-failure claimed a confirmed stop.'
    Assert-AdapterTest ($stopFailChild.process_exited -ne $true) 'Stop-failure claimed the child exited.'
    Assert-AdapterTest (-not $stopFailChild.Contains('orphans_zero')) 'Stop-failure claimed zero orphans.'
    $stopFailCkptPath = Join-Path $stopFailRoot 'completion-checkpoint.json'
    Assert-AdapterTest ([IO.File]::Exists($stopFailCkptPath)) 'Stop-failure omitted the bounded completion checkpoint.'
    $stopFailResult = Get-Content -LiteralPath $stopFailCkptPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ($stopFailResult.success -ne $true) 'Stop-failure wrapper claimed success.'
    Assert-AdapterTest ([string]$stopFailResult.error -ceq 'Official Grok CLI did not finish stop or redirected I/O within the bounded cleanup wait.') 'Stop-failure wrapper used the wrong public error.'
    Stop-DirectGrokTestJob -JobRoot $stopFailRoot
    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SIMULATE_STOP_FAILURE', $null, 'Process')

    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SIMULATE_IO_HANG', '1', 'Process')
    $ioHangState = Join-Path $testRoot 'io-hang-state'
    $ioHangJob = [Guid]::NewGuid().ToString('D')
    $ioHangSw = [Diagnostics.Stopwatch]::StartNew()
    $ioHang = Invoke-RouteWatchdog -TimeoutMs 25000 -Arguments @(
        '-Operation', 'start', '-StateRoot', $ioHangState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $ioHangJob, '-GrokCommand', $mockGrokCmd, '-GrokTimeoutSeconds', '1', '-WaitTimeoutSeconds', '30'
    )
    $ioHangSw.Stop()
    Assert-AdapterTest ($ioHang.exit_code -ne 0) 'I/O cleanup hang was treated as success.'
    Assert-AdapterTest ($ioHangSw.ElapsedMilliseconds -lt 20000) 'I/O cleanup hang wait was unbounded.'
    Assert-AdapterTest ($ioHang.value.automatic_rerun -eq $false -and $ioHang.value.replacement_started -eq $false) 'I/O cleanup hang advertised a replacement.'
    $ioHangRoot = Join-Path $ioHangState ("jobs\$ioHangJob")
    $ioHangChild = Get-Content -LiteralPath (Join-Path $ioHangRoot 'grok-child-owner.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ($ioHangChild.io_completed -ne $true) 'I/O cleanup hang claimed completed redirected I/O.'
    Assert-AdapterTest ($ioHangChild.stop_confirmed -ne $true) 'I/O cleanup hang claimed a confirmed stop.'
    Stop-DirectGrokTestJob -JobRoot $ioHangRoot
    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SIMULATE_IO_HANG', $null, 'Process')

    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_MOCK_MODE', 'success', 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS', $null, 'Process')
    $occState = Join-Path $testRoot 'occ-state'
    $occStartJob = [Guid]::NewGuid().ToString('D')
    $occStart = Invoke-AdapterEntrypoint -Entrypoint $durableInvoke -Arguments @(
        '-Operation', 'start', '-StateRoot', $occState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $occStartJob, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '30'
    )
    Assert-AdapterTest ($occStart.exit_code -eq 0) "Occupancy start failed: $($occStart.stderr) $($occStart.stdout)"
    $occSession = [string]$occStart.value.native_session_id
    $occBindingPath = Join-Path $occState ("sessions\$occSession\binding.json")
    $stampsAfterStart = Get-StampCount

    $readerStop = Join-Path $testRoot 'reader-stop.txt'
    $readerFail = Join-Path $testRoot 'reader-fail.txt'
    $readerOk = Join-Path $testRoot 'reader-ok.txt'
    $readerScript = Join-Path $testRoot 'read-binding.ps1'
    [IO.File]::WriteAllText($readerScript, @'
param([string]$BindingPath, [string]$StopPath, [string]$FailPath, [string]$OkPath)
Set-StrictMode -Version Latest
$keys = @('protocol_version', 'native_session_id', 'latest_job_id', 'created_at_utc')
while (-not [IO.File]::Exists($StopPath)) {
    if ([IO.File]::Exists($BindingPath)) {
        try {
            $bytes = [IO.File]::ReadAllBytes($BindingPath)
            if ($bytes.Length -lt 2) { Start-Sleep -Milliseconds 20; continue }
            $doc = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
            foreach ($k in $keys) {
                if (-not $doc.Contains($k) -or [string]::IsNullOrWhiteSpace([string]$doc[$k])) { throw "missing $k" }
            }
            [IO.File]::AppendAllText($OkPath, '1')
        } catch {
            [IO.File]::AppendAllText($FailPath, ($_.Exception.Message + "`n"))
        }
    }
    Start-Sleep -Milliseconds 20
}
'@, [Text.UTF8Encoding]::new($false))
    $readerInfo = [Diagnostics.ProcessStartInfo]::new()
    $readerInfo.FileName = $pwshPath
    $readerInfo.UseShellExecute = $false
    $readerInfo.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $readerScript, '-BindingPath', $occBindingPath, '-StopPath', $readerStop, '-FailPath', $readerFail, '-OkPath', $readerOk)) {
        [void]$readerInfo.ArgumentList.Add($argument)
    }
    $readerProc = [Diagnostics.Process]::Start($readerInfo)

    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_MOCK_MODE', 'sleep', 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS', '6', 'Process')
    $followA = [Guid]::NewGuid().ToString('D')
    $followB = [Guid]::NewGuid().ToString('D')
    $followArgsA = @(
        '-Operation', 'follow_up', '-NativeSessionId', $occSession, '-StateRoot', $occState, '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-JobId', $followA, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '20'
    )
    $followArgsB = @(
        '-Operation', 'follow_up', '-NativeSessionId', $occSession, '-StateRoot', $occState, '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-JobId', $followB, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '20'
    )
    $pFollowA = Start-RouteProcess -Arguments $followArgsA
    $pFollowB = Start-RouteProcess -Arguments $followArgsB
    $overlapWait = [Diagnostics.Stopwatch]::StartNew()
    while ($overlapWait.Elapsed.TotalSeconds -lt 5 -and (Get-StampCount) -lt ($stampsAfterStart + 1)) { Start-Sleep -Milliseconds 100 }
    Assert-AdapterTest ((Get-StampCount) -eq ($stampsAfterStart + 1)) "Competing follow_ups did not take a single write turn: $(Get-StampCount)"
    Start-Sleep -Seconds 1
    $stampsDuringOverlap = Get-StampCount
    Assert-AdapterTest ($stampsDuringOverlap -eq ($stampsAfterStart + 1)) "Competing follow_ups launched duplicate Grok writes: $stampsDuringOverlap"
    $null = $pFollowA.WaitForExit(30000)
    $null = $pFollowB.WaitForExit(30000)
    Assert-AdapterTest ($pFollowA.HasExited -and $pFollowB.HasExited) 'Competing follow_ups did not finish.'
    Assert-AdapterTest ($pFollowA.ExitCode -eq 0 -and $pFollowB.ExitCode -eq 0) "Serialized follow_ups failed: $($pFollowA.ExitCode) $($pFollowB.ExitCode)"
    Assert-AdapterTest ((Get-StampCount) -eq ($stampsAfterStart + 2)) 'Serialized follow_ups did not each run once.'
    $bindingAfter = Get-Content -LiteralPath $occBindingPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-AdapterTest ($bindingAfter.Contains('protocol_version') -and $bindingAfter.Contains('latest_job_id')) 'Binding after competing follow_ups was incomplete.'
    $reqA = Get-Content -LiteralPath (Join-Path $occState ("jobs\$followA\request.json")) -Raw | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $reqB = Get-Content -LiteralPath (Join-Path $occState ("jobs\$followB\request.json")) -Raw | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
    $successor = if ([string]$reqB.created_at_utc -cge [string]$reqA.created_at_utc) { $followB } else { $followA }
    Assert-AdapterTest ([string]$bindingAfter.latest_job_id -ceq $successor) "Binding latest_job_id was not the successor writer: $($bindingAfter.latest_job_id)"
    Assert-AdapterTest ([string]$bindingAfter.native_session_id -ceq $occSession) 'Competing follow_ups changed the native session id.'
    $occAfter = Join-Path $occState ("sessions\$occSession\write-occupancy.json")
    Assert-AdapterTest (-not [IO.File]::Exists($occAfter)) 'Write occupancy remained after both follow_ups completed.'
    $pFollowA.Dispose()
    $pFollowB.Dispose()
    [IO.File]::WriteAllText($readerStop, '1', [Text.UTF8Encoding]::new($false))
    $null = $readerProc.WaitForExit(5000)
    $readerProc.Dispose()
    Assert-AdapterTest (-not [IO.File]::Exists($readerFail)) 'Concurrent binding readers saw a torn or incomplete binding.'
    Assert-AdapterTest ([IO.File]::Exists($readerOk) -and ((Get-Item -LiteralPath $readerOk).Length -gt 0)) 'Concurrent binding readers never observed a complete binding.'

    $stampsBeforeBusy = Get-StampCount
    $busyA = [Guid]::NewGuid().ToString('D')
    $busyB = [Guid]::NewGuid().ToString('D')
    $pBusyA = Start-RouteProcess -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', $occSession, '-StateRoot', $occState, '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-JobId', $busyA, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '2'
    )
    $busyOwnerPath = Join-Path $occState ("jobs\$busyA\owner.json")
    $busyDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while ([DateTimeOffset]::UtcNow -lt $busyDeadline -and -not [IO.File]::Exists($busyOwnerPath)) { Start-Sleep -Milliseconds 100 }
    $pBusyB = Start-RouteProcess -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', $occSession, '-StateRoot', $occState, '-WorkspacePath', $workspace,
        '-PromptFile', $promptPath, '-JobId', $busyB, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '2'
    )
    $null = $pBusyA.WaitForExit(15000)
    $null = $pBusyB.WaitForExit(15000)
    Assert-AdapterTest ($pBusyA.HasExited -and $pBusyB.HasExited) 'Busy follow_ups did not return.'
    Assert-AdapterTest ($pBusyA.ExitCode -eq 3 -and $pBusyB.ExitCode -eq 3) "Caller wait timeout did not keep the live write turn: $($pBusyA.ExitCode) $($pBusyB.ExitCode)"
    Assert-AdapterTest ((Get-StampCount) -eq ($stampsBeforeBusy + 1)) 'Busy follow_up launched a duplicate Grok write.'
    Assert-AdapterTest ([IO.File]::Exists((Join-Path $occState ("sessions\$occSession\write-occupancy.json")))) 'Caller wait timeout released still-live write occupancy.'
    Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $occState ("jobs\$busyA\receipt.json")))) 'Caller wait timeout promoted a receipt for a live write.'
    $busyRecover = Invoke-AdapterEntrypoint -Entrypoint $durableInvoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $occSession, '-StateRoot', $occState, '-WaitTimeoutSeconds', '2'
    )
    Assert-AdapterTest ($busyRecover.exit_code -eq 3) 'Recover after caller wait timeout did not keep the live owner.'
    Assert-AdapterTest ($busyRecover.value.automatic_rerun -eq $false -and $busyRecover.value.replacement_started -eq $false) 'Live recover advertised a replacement.'
    Assert-AdapterTest ((Get-StampCount) -eq ($stampsBeforeBusy + 1)) 'Recover after caller wait timeout reran Grok.'
    $busyFinish = Invoke-AdapterEntrypoint -Entrypoint $durableInvoke -Arguments @(
        '-Operation', 'recover', '-NativeSessionId', $occSession, '-StateRoot', $occState, '-WaitTimeoutSeconds', '20'
    )
    Assert-AdapterTest ($busyFinish.exit_code -eq 0) "Exact recovery of the live follow_up failed: $($busyFinish.stderr) $($busyFinish.stdout)"
    Assert-AdapterTest ((Get-StampCount) -eq ($stampsBeforeBusy + 1)) 'Exact recovery reran Grok.'
    $pBusyA.Dispose()
    $pBusyB.Dispose()

    $distinctState = Join-Path $testRoot 'distinct-state'
    $distinctA = [Guid]::NewGuid().ToString('D')
    $distinctB = [Guid]::NewGuid().ToString('D')
    $stampsBeforeDistinct = Get-StampCount
    $pDistA = Start-RouteProcess -Arguments @(
        '-Operation', 'start', '-StateRoot', $distinctState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $distinctA, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '20'
    )
    $pDistB = Start-RouteProcess -Arguments @(
        '-Operation', 'start', '-StateRoot', $distinctState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-JobId', $distinctB, '-GrokCommand', $mockGrokCmd, '-WaitTimeoutSeconds', '20'
    )
    $distinctWait = [Diagnostics.Stopwatch]::StartNew()
    while ($distinctWait.Elapsed.TotalSeconds -lt 5 -and (Get-StampCount) -lt ($stampsBeforeDistinct + 2)) { Start-Sleep -Milliseconds 100 }
    Assert-AdapterTest ((Get-StampCount) -eq ($stampsBeforeDistinct + 2)) 'Distinct sessions were serialized onto one Grok write.'
    Assert-AdapterTest ($distinctWait.Elapsed.TotalSeconds -lt 5) 'Distinct sessions did not overlap.'
    $null = $pDistA.WaitForExit(30000)
    $null = $pDistB.WaitForExit(30000)
    Assert-AdapterTest ($pDistA.ExitCode -eq 0 -and $pDistB.ExitCode -eq 0) "Distinct sessions failed: $($pDistA.ExitCode) $($pDistB.ExitCode)"
    $pDistA.Dispose()
    $pDistB.Dispose()
    Stop-DirectGrokTestJob -JobRoot (Join-Path $occState ("jobs\$busyA"))
    Stop-DirectGrokTestJob -JobRoot $timeoutJobRoot
    Stop-DirectGrokTestJob -JobRoot $stopFailRoot
    Stop-DirectGrokTestJob -JobRoot $ioHangRoot

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
        unlimited_timeout_retained = 1
        explicit_timeout_bounded = 1
        stop_failure_bounded = 1
        io_cleanup_bounded = 1
        competing_follow_up_serialized = 1
        concurrent_binding_readers = 1
        caller_wait_keeps_live_owner = 1
        exact_recover_no_duplicate = 1
        distinct_sessions_concurrent = 1
        grok_invocations = (Get-DurableCount)
        assertions = $assertions
    } | ConvertTo-Json -Compress
} finally {
    [Environment]::SetEnvironmentVariable('DIRECT_GROK_MOCK_COUNTER', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_GROK_FAIL_TEXT', $null, 'Process')
    [Environment]::SetEnvironmentVariable('TELEPHONE_TEST_DIRECT_GROK_MOCK_MODE', $null, 'Process')
    foreach ($name in @(
            'TELEPHONE_TEST_DIRECT_GROK_CRASH_BEFORE_CLI',
            'TELEPHONE_TEST_DIRECT_GROK_CRASH_AFTER_CLI_STDOUT',
            'TELEPHONE_TEST_DIRECT_GROK_CRASH_AFTER_CHECKPOINT',
            'TELEPHONE_TEST_DIRECT_GROK_SIMULATE_STOP_FAILURE',
            'TELEPHONE_TEST_DIRECT_GROK_SIMULATE_IO_HANG',
            'TELEPHONE_TEST_DIRECT_GROK_SLEEP_SECONDS',
            'TELEPHONE_TEST_DIRECT_GROK_DELAY_BINDING_MS',
            'DIRECT_GROK_MOCK_INVOCATION_DIR'
        )) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
