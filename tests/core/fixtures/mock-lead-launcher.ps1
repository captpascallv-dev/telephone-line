# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorktreePath,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$ResumeSessionId,
    [Parameter(Mandatory = $true)][string]$RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logPath = [string]$env:TELEPHONE_TEST_LEAD_LOG
$runsRoot = [string]$env:TELEPHONE_TEST_LEAD_RUNS
$turnLog = [string]$env:TELEPHONE_TEST_LEAD_TURNS
if ([string]::IsNullOrWhiteSpace($logPath) -or [string]::IsNullOrWhiteSpace($runsRoot)) {
    throw 'Telephone test launcher environment is missing.'
}
$runRoot = Join-Path $runsRoot $RunId
[IO.Directory]::CreateDirectory($runRoot) | Out-Null
$ackPath = Join-Path $runRoot 'lead-wake-ack.json'
$ownerPath = Join-Path $runRoot 'owner.json'
$eventsPath = Join-Path $runRoot 'codex-events.jsonl'
$nativeEvents = [string]$env:TELEPHONE_TEST_LEAD_NATIVE_EVENTS -ceq '1'
$createdNewTurn = -not [IO.File]::Exists($ackPath)
if ($nativeEvents) { $createdNewTurn = $createdNewTurn -and -not [IO.File]::Exists($eventsPath) }
$promptText = ''
$promptIdentity = $null
if ([IO.File]::Exists($PromptFile)) {
    $fullPrompt = [IO.Path]::GetFullPath($PromptFile)
    $promptBytes = [IO.File]::ReadAllBytes($fullPrompt)
    $promptText = [Text.UTF8Encoding]::new($false, $false).GetString($promptBytes)
    $promptIdentity = [ordered]@{
        path = $fullPrompt
        bytes = [int64]$promptBytes.Length
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes)).ToLowerInvariant()
    }
}
$wakeKey = ''
$receiptSha = ''
foreach ($line in ($promptText -split '\r?\n')) {
    if ($line -match '^- wake_key:\s*([0-9a-fA-F]{64})\s*$') { $wakeKey = $Matches[1].ToLowerInvariant() }
    if ($line -match '^- receipt_sha256:\s*([0-9a-fA-F]{64})\s*$') { $receiptSha = $Matches[1].ToLowerInvariant() }
}
$entry = [ordered]@{
    session_id = $ResumeSessionId
    run_id = $RunId
    worktree = [IO.Path]::GetFullPath($WorktreePath).TrimEnd('\')
    prompt = [IO.Path]::GetFullPath($PromptFile)
    existing = (-not $createdNewTurn)
}
[IO.File]::AppendAllText($logPath, (($entry | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
$self = Get-Process -Id $PID
try {
    $owner = [ordered]@{
        pid = [int]$PID
        start_time_utc_ticks = [int64]$self.StartTime.ToUniversalTime().Ticks
        started_at_utc = $self.StartTime.ToUniversalTime().ToString('o')
    }
} finally {
    $self.Dispose()
}
$nativeOwner = $null
if ($createdNewTurn -and $nativeEvents) {
    $sleeperScript = Join-Path $runRoot 'native-owner-hold.ps1'
    [IO.File]::WriteAllText($sleeperScript, "Start-Sleep -Seconds 60`n", [Text.UTF8Encoding]::new($false))
    $sleeperInfo = [Diagnostics.ProcessStartInfo]::new()
    $sleeperInfo.FileName = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $sleeperInfo.UseShellExecute = $true
    $sleeperInfo.CreateNoWindow = $false
    $sleeperInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $sleeperScript)) {
        [void]$sleeperInfo.ArgumentList.Add([string]$argument)
    }
    $nativeOwner = [Diagnostics.Process]::Start($sleeperInfo)
    if ($null -eq $nativeOwner) { throw 'Native test Lead owner did not start.' }
    $owner = [ordered]@{
        pid = [int]$nativeOwner.Id
        start_time_utc_ticks = [int64]$nativeOwner.StartTime.ToUniversalTime().Ticks
        started_at_utc = $nativeOwner.StartTime.ToUniversalTime().ToString('o')
    }
}
if (-not [IO.File]::Exists($ownerPath)) {
    [IO.File]::WriteAllText($ownerPath, (($owner | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
}
$eventsStream = $null
$skipOfficialFinal = $false
if ($createdNewTurn -and $nativeEvents) {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $leadRun = [ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = $RunId
        requested_run_id = $RunId
        worktree = [IO.Path]::GetFullPath($WorktreePath).TrimEnd('\')
        resume_session_id = $ResumeSessionId
        events_path = $eventsPath
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if ($null -ne $promptIdentity) { $leadRun['prompt'] = $promptIdentity }
    [IO.File]::WriteAllText((Join-Path $runRoot 'lead-run.json'), (($leadRun | ConvertTo-Json -Depth 8) + "`n"), $utf8)
    $eventsStream = [IO.FileStream]::new($eventsPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    $eventBytes = $utf8.GetBytes(('{"type":"thread.started","thread_id":"' + $ResumeSessionId + '"}' + "`n" + '{"type":"turn.started"}' + "`n"))
    $eventsStream.Write($eventBytes, 0, $eventBytes.Length)
    $eventsStream.Flush($true)
    $skipOfficialFinal = $true
    if (-not [string]::IsNullOrWhiteSpace($turnLog)) {
        $turnEntry = [ordered]@{
            run_id = $RunId
            session_id = $ResumeSessionId
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        [IO.File]::AppendAllText($turnLog, (($turnEntry | ConvertTo-Json -Compress) + "`n"), $utf8)
    }
} elseif ($createdNewTurn) {
    $ack = [ordered]@{
        protocol_version = 'telephone-line-lead-wake-ack-v1'
        session_id = $ResumeSessionId
        run_id = $RunId
        event = 'turn.started'
        acknowledged_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if (-not [string]::IsNullOrWhiteSpace($wakeKey)) { $ack['wake_key'] = $wakeKey }
    if (-not [string]::IsNullOrWhiteSpace($receiptSha)) { $ack['receipt_sha256'] = $receiptSha }
    [IO.File]::WriteAllText($ackPath, (($ack | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    $leadRun = [ordered]@{
        protocol_version = 'huhu-concerto-cli-lead-run-v1'
        run_id = $RunId
        requested_run_id = $RunId
        worktree = [IO.Path]::GetFullPath($WorktreePath).TrimEnd('\')
        resume_session_id = $ResumeSessionId
        events_path = $eventsPath
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if ($null -ne $promptIdentity) { $leadRun['prompt'] = $promptIdentity }
    [IO.File]::WriteAllText((Join-Path $runRoot 'lead-run.json'), (($leadRun | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    if (-not [string]::IsNullOrWhiteSpace($turnLog)) {
        $turnEntry = [ordered]@{
            run_id = $RunId
            session_id = $ResumeSessionId
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        [IO.File]::AppendAllText($turnLog, (($turnEntry | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    }
} elseif (-not $createdNewTurn -and [IO.File]::Exists($ackPath) -and (-not [string]::IsNullOrWhiteSpace($wakeKey) -or -not [string]::IsNullOrWhiteSpace($receiptSha))) {
    try {
        $existingAck = (Get-Content -LiteralPath $ackPath -Raw -Encoding utf8) | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        $changed = $false
        if ($existingAck -is [Collections.IDictionary]) {
            if (-not [string]::IsNullOrWhiteSpace($wakeKey) -and (-not $existingAck.Contains('wake_key') -or [string]::IsNullOrWhiteSpace([string]$existingAck['wake_key']))) {
                $existingAck['wake_key'] = $wakeKey
                $changed = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($receiptSha) -and (-not $existingAck.Contains('receipt_sha256') -or [string]::IsNullOrWhiteSpace([string]$existingAck['receipt_sha256']))) {
                $existingAck['receipt_sha256'] = $receiptSha
                $changed = $true
            }
            if ($changed) {
                [IO.File]::WriteAllText($ackPath, (($existingAck | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
            }
        }
    } catch {
    }
}
if ($createdNewTurn -and -not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_TEST_LEAD_THROW_AFTER_WAKE)) {
    $throwAfter = [string]$env:TELEPHONE_TEST_LEAD_THROW_AFTER_WAKE
    if ($throwAfter -ceq '*' -or $throwAfter -ceq $RunId) {
        throw 'mock lead wake returned ambiguously'
    }
}
$holdTerminal = [string]$env:TELEPHONE_TEST_LEAD_HOLD_TERMINAL
$shouldHold = (-not [string]::IsNullOrWhiteSpace($holdTerminal) -and ($holdTerminal -ceq '*' -or $holdTerminal -ceq $ResumeSessionId -or $holdTerminal -ceq $RunId))
$delaySession = [string]$env:TELEPHONE_TEST_LEAD_DELAY_TERMINAL_SESSION
$delayMs = 0
if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_TEST_LEAD_DELAY_TERMINAL_MS)) {
    $delayApplies = [string]::IsNullOrWhiteSpace($delaySession) -or $delaySession -ceq $ResumeSessionId
    if ($delayApplies) { $delayMs = [int]$env:TELEPHONE_TEST_LEAD_DELAY_TERMINAL_MS }
}
$finalPath = Join-Path $runRoot 'launcher-final.txt'
$terminalState = [string]$env:TELEPHONE_TEST_LEAD_TERMINAL_STATE
if ([string]::IsNullOrWhiteSpace($terminalState)) { $terminalState = 'completed' }
if ($terminalState -cnotin @('completed', 'failed', 'interrupted')) { $terminalState = 'completed' }
if ($skipOfficialFinal) { $terminalState = 'running' }
if ($delayMs -gt 0 -and -not $shouldHold -and -not [IO.File]::Exists($finalPath) -and -not $skipOfficialFinal) {
    Start-Sleep -Milliseconds $delayMs
}
if (-not $shouldHold -and -not [IO.File]::Exists($finalPath) -and -not $skipOfficialFinal) {
    [IO.File]::WriteAllText($finalPath, ($terminalState + "`n"), [Text.UTF8Encoding]::new($false))
}
if ($null -ne $eventsStream) { $eventsStream.Dispose() }
if ($null -ne $nativeOwner) { $nativeOwner.Dispose() }
[ordered]@{
    started = $true
    existing = (-not $createdNewTurn)
    state = $terminalState
    run_id = $RunId
    run_root = $runRoot
} | ConvertTo-Json -Compress
