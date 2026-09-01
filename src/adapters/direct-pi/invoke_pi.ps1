# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [Parameter(Mandatory = $true)][ValidateRange(1, [long]::MaxValue)][long]$ExpectedRequestBytes,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedRequestSha256,
    [Parameter(Mandatory = $true)][ValidateRange(1, [long]::MaxValue)][long]$ExpectedWrapperBytes,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedWrapperSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }
$utf8Strict = [Text.UTF8Encoding]::new($false, $true)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'DirectPi.Common.ps1')

function Get-DirectPiSessionHeader {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][long]$MaxBytes)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $records = @(ConvertFrom-DirectPiJsonLinesStrict -Bytes $bytes -Label 'PI session file' -MaxBytes $MaxBytes)
    if ($records.Count -lt 1) { throw 'PI session file has no header.' }
    $header = $records[0]
    if (-not $header.Contains('type') -or [string]$header.type -cne 'session') { throw 'PI session file has no session header.' }
    foreach ($key in @('id', 'cwd')) {
        if (-not $header.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$header[$key])) { throw 'PI session header is incomplete.' }
    }
    return $header
}

function Find-DirectPiExactSessionFile {
    param(
        [Parameter(Mandatory = $true)][string]$SessionDir,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][long]$MaxBytes
    )
    $matches = [Collections.Generic.List[string]]::new()
    $canonicalWorkspace = Get-DirectPiCanonicalDirectory -Path $Workspace
    foreach ($file in @(Get-ChildItem -LiteralPath $SessionDir -Filter '*.jsonl' -File -Force -ErrorAction Stop)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PI session is a reparse point.' }
        $header = Get-DirectPiSessionHeader -Path $file.FullName -MaxBytes $MaxBytes
        $headerCwd = Get-DirectPiCanonicalDirectory -Path ([string]$header.cwd)
        if ([string]$header.id -ceq $SessionId -and $headerCwd.Equals($canonicalWorkspace, [StringComparison]::OrdinalIgnoreCase)) {
            $matches.Add($file.FullName)
        }
    }
    if ($matches.Count -ne 1) { throw 'Expected one exact PI session file.' }
    return [IO.Path]::GetFullPath($matches[0])
}

function Get-DirectPiAssistantText {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Message)
    $pieces = [Collections.Generic.List[string]]::new()
    if ($Message.Contains('content') -and $null -ne $Message.content) {
        foreach ($item in @($Message.content)) {
            if ($item -is [Collections.IDictionary] -and $item.Contains('type') -and [string]$item.type -ceq 'text' -and $item.Contains('text')) {
                $pieces.Add([string]$item.text)
            }
        }
    }
    return [string]::Concat($pieces)
}

$request = $null
$process = $null
$stdoutBuffer = $null
$stderrBuffer = $null
$startedAt = [Diagnostics.Stopwatch]::StartNew()
$boundSessionPath = ''
$piExitCode = $null
$eventCount = 0
$agentEndCount = 0
$assistantMessage = $null
$assistantText = ''
$stopReason = ''
$stderrBytesCount = 0
try {
    $wrapperIdentity = Get-DirectPiFileIdentity -Path $PSCommandPath
    if ([int64]$wrapperIdentity.bytes -ne $ExpectedWrapperBytes -or [string]$wrapperIdentity.sha256 -cne $ExpectedWrapperSha256) {
        throw 'Direct PI wrapper identity changed before launch.'
    }
    $requestRead = Read-DirectPiJson -Path $RequestPath
    if ([int64]$requestRead.identity.bytes -ne $ExpectedRequestBytes -or [string]$requestRead.identity.sha256 -cne $ExpectedRequestSha256) {
        throw 'Direct PI request identity changed before launch.'
    }
    $request = $requestRead.value
    Assert-DirectPiKeys -Value $request -Keys @(
        'protocol_version', 'job_id', 'workspace', 'prompt', 'provider', 'model', 'thinking',
        'session_id', 'session_path', 'resume', 'session_dir', 'timeout_seconds', 'max_output_bytes',
        'node', 'cli', 'wrapper', 'mock_mode', 'execution_count', 'created_at_utc'
    ) -Label 'Direct PI request'
    if ([string]$request.protocol_version -cne 'telephone-line-direct-pi-request-v1') { throw 'Unsupported Direct PI request protocol.' }
    if ([string]$request.job_id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'Direct PI job ID is invalid.' }
    if ([string]$request.session_id -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Direct PI session ID is invalid.' }
    if ($request.resume -isnot [bool] -or $request.mock_mode -isnot [bool]) { throw 'Direct PI boolean control is malformed.' }
    if ([int]$request.execution_count -ne 1) { throw 'Direct PI execution count must be one.' }

    $workspace = Get-DirectPiCanonicalDirectory -Path ([string]$request.workspace)
    if (-not [IO.Directory]::Exists($workspace)) { throw 'Direct PI workspace does not exist.' }
    $sessionDir = Get-DirectPiCanonicalDirectory -Path ([string]$request.session_dir)
    if (-not [IO.Directory]::Exists($sessionDir)) { throw 'Direct PI private session directory does not exist.' }

    if ($request.prompt -isnot [Collections.IDictionary]) { throw 'Direct PI prompt binding is malformed.' }
    Assert-DirectPiKeys -Value $request.prompt -Keys @('path', 'bytes', 'sha256') -Label 'Direct PI prompt binding'
    $promptIdentity = Get-DirectPiFileIdentity -Path ([string]$request.prompt.path)
    Assert-DirectPiIdentity -Expected $request.prompt -Actual $promptIdentity -Label 'Direct PI prompt'
    $promptBytes = [IO.File]::ReadAllBytes([string]$promptIdentity.path)
    if ($promptBytes.Length -ge 3 -and $promptBytes[0] -eq 0xEF -and $promptBytes[1] -eq 0xBB -and $promptBytes[2] -eq 0xBF) { throw 'Direct PI prompt must be UTF-8 without BOM.' }
    $promptText = $utf8Strict.GetString($promptBytes)
    if ([string]::IsNullOrWhiteSpace($promptText)) { throw 'Direct PI prompt is empty.' }

    $adapterRoot = Get-DirectPiCanonicalDirectory -Path $PSScriptRoot
    $expectedWrapperPath = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'invoke_pi.ps1'))
    Assert-DirectPiKeys -Value $request.wrapper -Keys @('path', 'bytes', 'sha256') -Label 'Direct PI wrapper binding'
    if (-not $expectedWrapperPath.Equals([IO.Path]::GetFullPath([string]$request.wrapper.path), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Direct PI wrapper escaped the adapter root.'
    }
    Assert-DirectPiIdentity -Expected $request.wrapper -Actual (Get-DirectPiFileIdentity -Path $expectedWrapperPath) -Label 'Direct PI wrapper'

    Assert-DirectPiKeys -Value $request.node -Keys @('path', 'bytes', 'sha256') -Label 'Direct PI Node binding'
    $nodePath = [IO.Path]::GetFullPath([string]$request.node.path)
    Assert-DirectPiIdentity -Expected $request.node -Actual (Get-DirectPiFileIdentity -Path $nodePath) -Label 'Direct PI Node executable'
    Assert-DirectPiKeys -Value $request.cli -Keys @('path', 'bytes', 'sha256') -Label 'Direct PI CLI binding'
    $cliPath = [IO.Path]::GetFullPath([string]$request.cli.path)
    Assert-DirectPiIdentity -Expected $request.cli -Actual (Get-DirectPiFileIdentity -Path $cliPath) -Label 'Direct PI CLI'

    $sessionFileMaxBytes = [Math]::Max([int64]$request.max_output_bytes, 67108864)
    if ([bool]$request.resume) {
        if ([string]::IsNullOrWhiteSpace([string]$request.session_path)) { throw 'Direct PI follow-up has no exact session path.' }
        $boundSessionPath = [IO.Path]::GetFullPath([string]$request.session_path)
        if (-not (Test-DirectPiPathWithin -Root $sessionDir -Path $boundSessionPath)) { throw 'Direct PI follow-up session escaped the private session directory.' }
        if (-not [IO.File]::Exists($boundSessionPath)) { throw 'Direct PI follow-up exact session file is missing.' }
        $beforePath = Find-DirectPiExactSessionFile -SessionDir $sessionDir -SessionId ([string]$request.session_id) -Workspace $workspace -MaxBytes $sessionFileMaxBytes
        if (-not $beforePath.Equals($boundSessionPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Direct PI follow-up exact session path differs.' }
    } elseif (-not [string]::IsNullOrEmpty([string]$request.session_path)) {
        throw 'Direct PI new session unexpectedly supplied a session path.'
    }

    $piArgs = @(
        '--offline', '--mode', 'json', '--provider', [string]$request.provider, '--model', [string]$request.model,
        '--thinking', [string]$request.thinking, '--session-dir', $sessionDir
    )
    if ([bool]$request.resume) { $piArgs += @('--session', $boundSessionPath) }
    else { $piArgs += @('--session-id', [string]$request.session_id) }
    $piArgs += '--approve'

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.WorkingDirectory = $workspace
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $launchKind = Get-DirectPiLaunchKind -CliPath $cliPath -MockMode ([bool]$request.mock_mode)
    if ($launchKind -ceq 'powershell') {
        $startInfo.FileName = $nodePath
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $cliPath) + $piArgs) {
            [void]$startInfo.ArgumentList.Add([string]$argument)
        }
    } elseif ($launchKind -ceq 'command-shim' -or $launchKind -ceq 'executable') {
        $startInfo.FileName = $cliPath
        foreach ($argument in $piArgs) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    } else {
        $startInfo.FileName = $nodePath
        foreach ($argument in @($cliPath) + $piArgs) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'PI process did not start.' }
    $stdoutBuffer = [IO.MemoryStream]::new()
    $stderrBuffer = [IO.MemoryStream]::new()
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutBuffer)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrBuffer)
    try {
        $process.StandardInput.BaseStream.Write($promptBytes, 0, $promptBytes.Length)
        $process.StandardInput.BaseStream.Flush()
    } finally { $process.StandardInput.Close() }

    if ([int]$request.timeout_seconds -gt 0) {
        $finished = $process.WaitForExit(([int]$request.timeout_seconds * 1000))
        if (-not $finished) { try { $process.Kill($true) } catch { }; $process.WaitForExit() }
    } else {
        $process.WaitForExit()
        $finished = $true
    }
    [void]$stdoutTask.GetAwaiter().GetResult()
    [void]$stderrTask.GetAwaiter().GetResult()
    $stdoutBytes = $stdoutBuffer.ToArray()
    $stderrBytesCount = [int64]$stderrBuffer.Length
    $piExitCode = if ($finished) { [int]$process.ExitCode } else { 124 }

    $boundAfter = Find-DirectPiExactSessionFile -SessionDir $sessionDir -SessionId ([string]$request.session_id) -Workspace $workspace -MaxBytes $sessionFileMaxBytes
    if ([bool]$request.resume -and -not $boundAfter.Equals($boundSessionPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Direct PI follow-up changed the exact session path.'
    }
    $boundSessionPath = $boundAfter

    $events = @(ConvertFrom-DirectPiJsonLinesStrict -Bytes $stdoutBytes -Label 'PI JSON event stream' -MaxBytes ([int64]$request.max_output_bytes))
    $eventCount = $events.Count
    if ($events.Count -lt 1) { throw 'PI JSON event stream has no header.' }
    $headerCount = 0
    $lastAssistantIndex = -1
    $agentEndIndices = [Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt $events.Count; $index++) {
        $event = $events[$index]
        if ($event.Contains('type') -and [string]$event.type -ceq 'session') {
            $headerCount++
            if ($index -ne 0) { throw 'PI session header is not the first event.' }
        }
        if ($event.Contains('type') -and [string]$event.type -ceq 'agent_end') { $agentEndIndices.Add($index) }
        if (
            $event.Contains('type') -and [string]$event.type -ceq 'message_end' -and
            $event.Contains('message') -and $event.message -is [Collections.IDictionary] -and
            $event.message.Contains('role') -and [string]$event.message.role -ceq 'assistant'
        ) {
            $lastAssistantIndex = $index
            $assistantMessage = $event.message
        }
    }
    if ($headerCount -ne 1) { throw 'PI JSON event stream must contain one session header.' }
    $header = $events[0]
    if (-not $header.Contains('id') -or [string]$header.id -cne [string]$request.session_id) { throw 'PI JSON header returned another session ID.' }
    if (-not $header.Contains('cwd')) { throw 'PI JSON header has no cwd.' }
    $headerCwd = Get-DirectPiCanonicalDirectory -Path ([string]$header.cwd)
    if (-not $headerCwd.Equals($workspace, [StringComparison]::OrdinalIgnoreCase)) { throw 'PI JSON header returned another cwd.' }
    if ($null -eq $assistantMessage) { throw 'PI JSON event stream has no final assistant message_end.' }
    if (-not $assistantMessage.Contains('stopReason')) { throw 'PI final assistant has no stopReason.' }
    $stopReason = [string]$assistantMessage.stopReason
    if ([string]::IsNullOrWhiteSpace($stopReason) -or $stopReason -in @('error', 'aborted', 'pending')) { throw 'PI final assistant has a non-terminal stopReason.' }
    $agentEndCount = $agentEndIndices.Count
    if ($agentEndCount -lt 1 -or -not (@($agentEndIndices | Where-Object { $_ -gt $lastAssistantIndex }).Count -gt 0)) {
        throw 'PI JSON event stream has no agent_end after the final assistant.'
    }
    if (-not $finished) { throw 'PI process exceeded a bounded startup window.' }
    if ($piExitCode -ne 0) { throw 'PI process exited nonzero.' }
    $assistantText = Get-DirectPiAssistantText -Message $assistantMessage
    [ordered]@{
        protocol_version = 'telephone-line-direct-pi-result-v1'
        job_id = [string]$request.job_id
        success = $true
        error = $null
        workspace = $workspace
        prompt = $promptIdentity
        provider = [string]$request.provider
        model = [string]$request.model
        thinking = [string]$request.thinking
        session_id = [string]$request.session_id
        session_path = $boundSessionPath
        resumed = [bool]$request.resume
        pi_exit_code = $piExitCode
        stop_reason = $stopReason
        assistant_text = $assistantText
        assistant_message = $assistantMessage
        execution_count = 1
        event_count = $eventCount
        agent_end_count = $agentEndCount
        stderr_bytes = $stderrBytesCount
        duration_ms = [int64]$startedAt.ElapsedMilliseconds
    } | ConvertTo-Json -Depth 64
    exit 0
} catch {
    [ordered]@{
        protocol_version = 'telephone-line-direct-pi-result-v1'
        job_id = if ($null -ne $request) { [string]$request.job_id } else { '' }
        success = $false
        error = Get-DirectPiPublicError -Text $_.Exception.Message
        workspace = if ($null -ne $request) { [string]$request.workspace } else { '' }
        prompt = if ($null -ne $request -and $request.prompt -is [Collections.IDictionary]) { $request.prompt } else { $null }
        provider = if ($null -ne $request) { [string]$request.provider } else { '' }
        model = if ($null -ne $request) { [string]$request.model } else { '' }
        thinking = if ($null -ne $request) { [string]$request.thinking } else { '' }
        session_id = if ($null -ne $request) { [string]$request.session_id } else { '' }
        session_path = $boundSessionPath
        resumed = if ($null -ne $request) { [bool]$request.resume } else { $false }
        pi_exit_code = $piExitCode
        stop_reason = $stopReason
        assistant_text = $assistantText
        assistant_message = $assistantMessage
        execution_count = if ($null -ne $request) { 1 } else { 0 }
        event_count = $eventCount
        agent_end_count = $agentEndCount
        stderr_bytes = $stderrBytesCount
        duration_ms = [int64]$startedAt.ElapsedMilliseconds
    } | ConvertTo-Json -Depth 64
    exit 4
} finally {
    if ($null -ne $stdoutBuffer) { $stdoutBuffer.Dispose() }
    if ($null -ne $stderrBuffer) { $stderrBuffer.Dispose() }
    if ($null -ne $process) { $process.Dispose() }
}
