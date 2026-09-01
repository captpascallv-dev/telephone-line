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
$utf8NoBom = [Text.UTF8Encoding]::new($false, $true)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'DirectCodex.Common.ps1')

$request = $null
$process = $null
$stdoutBuffer = $null
$stderrBuffer = $null
$startedAt = [Diagnostics.Stopwatch]::StartNew()
$nativeSessionId = ''
$cliExitCode = $null
$lastMessage = $null
try {
    $wrapperIdentity = Get-DirectCodexFileIdentity -Path $PSCommandPath
    if ([int64]$wrapperIdentity.bytes -ne $ExpectedWrapperBytes -or [string]$wrapperIdentity.sha256 -cne $ExpectedWrapperSha256) {
        throw 'Direct Codex wrapper identity changed before launch.'
    }

    $requestRead = Read-DirectCodexJson -Path $RequestPath
    if ([int64]$requestRead.identity.bytes -ne $ExpectedRequestBytes -or [string]$requestRead.identity.sha256 -cne $ExpectedRequestSha256) {
        throw 'Direct Codex request identity changed before launch.'
    }
    $request = $requestRead.value
    Assert-DirectCodexKeys -Value $request -Keys @(
        'protocol_version', 'job_id', 'workspace', 'prompt', 'model', 'reasoning_effort',
        'sandbox', 'approval_policy', 'skip_git_repo_check', 'session_id', 'resume', 'timeout_seconds',
        'max_output_bytes', 'last_message_path', 'cli', 'wrapper', 'created_at_utc'
    ) -Label 'Direct Codex request'

    if ([string]$request.protocol_version -cne 'telephone-line-direct-codex-request-v1') { throw 'Unsupported Direct Codex request protocol.' }
    if ([string]$request.job_id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'Direct Codex job ID is invalid.' }
    if ($request.resume -isnot [bool]) { throw 'Direct Codex resume control is malformed.' }
    if ($request.skip_git_repo_check -isnot [bool]) { throw 'Direct Codex Git-repository control is malformed.' }
    if ([bool]$request.resume) {
        Assert-DirectCodexNativeSessionIdFormat -SessionId ([string]$request.session_id) -Label 'Direct Codex request'
    } elseif (-not [string]::IsNullOrEmpty([string]$request.session_id)) {
        throw 'Direct Codex start must not synthesize a native session id.'
    }

    $workspace = Get-DirectCodexCanonicalDirectory -Path ([string]$request.workspace)
    if (-not [IO.Directory]::Exists($workspace)) { throw 'Direct Codex workspace does not exist.' }
    $workspaceItem = Get-Item -LiteralPath $workspace -Force -ErrorAction Stop
    if (-not $workspaceItem.PSIsContainer -or ($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Direct Codex workspace must be a regular directory.'
    }

    if ($request.prompt -isnot [Collections.IDictionary]) { throw 'Direct Codex prompt binding is malformed.' }
    Assert-DirectCodexKeys -Value $request.prompt -Keys @('path', 'bytes', 'sha256') -Label 'Direct Codex prompt binding'
    $promptIdentity = Get-DirectCodexFileIdentity -Path ([string]$request.prompt.path)
    Assert-DirectCodexIdentity -Expected $request.prompt -Actual $promptIdentity -Label 'Direct Codex prompt'
    $promptBytes = [IO.File]::ReadAllBytes([string]$promptIdentity.path)
    if ($promptBytes.Length -ge 3 -and $promptBytes[0] -eq 0xEF -and $promptBytes[1] -eq 0xBB -and $promptBytes[2] -eq 0xBF) {
        throw 'Direct Codex prompt must be UTF-8 without BOM.'
    }
    if ($promptBytes.Length -eq 0) { throw 'Direct Codex prompt is empty.' }

    $adapterRoot = Get-DirectCodexCanonicalDirectory -Path $PSScriptRoot
    $expectedWrapperPath = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'invoke_codex_exec.ps1'))
    Assert-DirectCodexKeys -Value $request.wrapper -Keys @('path', 'bytes', 'sha256') -Label 'Direct Codex wrapper binding'
    if (-not $expectedWrapperPath.Equals([IO.Path]::GetFullPath([string]$request.wrapper.path), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Direct Codex wrapper escaped the adapter root.'
    }
    Assert-DirectCodexIdentity -Expected $request.wrapper -Actual (Get-DirectCodexFileIdentity -Path $expectedWrapperPath) -Label 'Direct Codex wrapper'

    Assert-DirectCodexKeys -Value $request.cli -Keys @('path', 'bytes', 'sha256') -Label 'Direct Codex executable binding'
    $cliPath = [IO.Path]::GetFullPath([string]$request.cli.path)
    Assert-DirectCodexIdentity -Expected $request.cli -Actual (Get-DirectCodexFileIdentity -Path $cliPath) -Label 'Direct Codex executable'

    $lastMessagePath = [IO.Path]::GetFullPath([string]$request.last_message_path)
    $jobRoot = [IO.Path]::GetDirectoryName($lastMessagePath)
    if (-not (Test-DirectCodexPathWithin -Root $jobRoot -Path $lastMessagePath)) {
        throw 'Direct Codex last-message path escaped the job root.'
    }

    $cliArguments = [Collections.Generic.List[string]]::new()
    [void]$cliArguments.Add('exec')
    [void]$cliArguments.Add('--json')
    [void]$cliArguments.Add('--output-last-message')
    [void]$cliArguments.Add($lastMessagePath)
    [void]$cliArguments.Add('--cd')
    [void]$cliArguments.Add($workspace)
    [void]$cliArguments.Add('--color')
    [void]$cliArguments.Add('never')
    if (-not [string]::IsNullOrWhiteSpace([string]$request.model)) {
        if ([string]$request.model -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Direct Codex model is malformed.' }
        [void]$cliArguments.Add('--model')
        [void]$cliArguments.Add([string]$request.model)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$request.reasoning_effort)) {
        if ([string]$request.reasoning_effort -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Direct Codex reasoning effort is malformed.' }
        [void]$cliArguments.Add('-c')
        [void]$cliArguments.Add('model_reasoning_effort=' + [string]$request.reasoning_effort)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$request.sandbox)) {
        if ([string]$request.sandbox -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Direct Codex sandbox is malformed.' }
        [void]$cliArguments.Add('--sandbox')
        [void]$cliArguments.Add([string]$request.sandbox)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$request.approval_policy)) {
        if ([string]$request.approval_policy -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Direct Codex approval policy is malformed.' }
        [void]$cliArguments.Add('-c')
        [void]$cliArguments.Add('approval_policy=' + [string]$request.approval_policy)
    }
    if ([bool]$request.skip_git_repo_check) {
        [void]$cliArguments.Add('--skip-git-repo-check')
    }
    if ([bool]$request.resume) {
        [void]$cliArguments.Add('resume')
        [void]$cliArguments.Add([string]$request.session_id)
    }
    Assert-DirectCodexArgumentSafety -Arguments @($cliArguments) -Resume ([bool]$request.resume)

    $startInfo = New-DirectCodexProcessStartInfo -CliPath $cliPath -CliArguments @($cliArguments) -Workspace $workspace
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Codex CLI did not start.' }
    $stdoutBuffer = [IO.MemoryStream]::new()
    $stderrBuffer = [IO.MemoryStream]::new()
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutBuffer)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrBuffer)
    try {
        $process.StandardInput.BaseStream.Write($promptBytes, 0, $promptBytes.Length)
        $process.StandardInput.BaseStream.Flush()
    } finally {
        $process.StandardInput.Close()
    }

    if ([int]$request.timeout_seconds -gt 0) {
        $finished = $process.WaitForExit(([int]$request.timeout_seconds * 1000))
        if (-not $finished) {
            try { $process.Kill($true) } catch { }
            $process.WaitForExit()
        }
    } else {
        $process.WaitForExit()
        $finished = $true
    }
    [void]$stdoutTask.GetAwaiter().GetResult()
    [void]$stderrTask.GetAwaiter().GetResult()
    $stdoutBytes = $stdoutBuffer.ToArray()
    $cliExitCode = if ($finished) { [int]$process.ExitCode } else { 124 }

    $records = @(ConvertFrom-DirectCodexJsonLines -Bytes $stdoutBytes -Label 'Codex JSONL stream' -MaxBytes ([int64]$request.max_output_bytes))
    $nativeSessionId = Get-DirectCodexNativeSessionIdFromEvents -Records $records
    if ([bool]$request.resume -and $nativeSessionId -cne [string]$request.session_id) {
        throw 'Adapter native session id does not match the frozen session.'
    }
    if (-not $finished) { throw 'Codex CLI exceeded a bounded startup window.' }
    if ($cliExitCode -ne 0) { throw 'Codex CLI exited nonzero.' }
    if (-not [IO.File]::Exists($lastMessagePath)) { throw 'Codex CLI last-message output is missing.' }
    $lastMessage = Get-DirectCodexFileIdentity -Path $lastMessagePath

    [ordered]@{
        protocol_version = 'telephone-line-direct-codex-result-v1'
        job_id = [string]$request.job_id
        success = $true
        error = $null
        workspace = $workspace
        prompt = $promptIdentity
        session_id = $nativeSessionId
        resumed = [bool]$request.resume
        cli_exit_code = $cliExitCode
        last_message = $lastMessage
        event_count = @($records).Count
        diagnostic = ''
        duration_ms = [int64]$startedAt.ElapsedMilliseconds
        official_cli = $true
    } | ConvertTo-Json -Depth 64
    exit 0
} catch {
    if (-not [string]::IsNullOrWhiteSpace([string]$request.last_message_path) -and [IO.File]::Exists([string]$request.last_message_path)) {
        try { [IO.File]::Delete([string]$request.last_message_path) } catch { }
    }
    [ordered]@{
        protocol_version = 'telephone-line-direct-codex-result-v1'
        job_id = if ($null -ne $request) { [string]$request.job_id } else { '' }
        success = $false
        error = Get-DirectCodexPublicError -Text $_.Exception.Message
        workspace = if ($null -ne $request) { [string]$request.workspace } else { '' }
        prompt = if ($null -ne $request -and $request.prompt -is [Collections.IDictionary]) { $request.prompt } else { $null }
        session_id = $nativeSessionId
        resumed = if ($null -ne $request) { [bool]$request.resume } else { $false }
        cli_exit_code = $cliExitCode
        last_message = $null
        event_count = 0
        diagnostic = Protect-DirectCodexDiagnostic -Text $_.Exception.Message
        duration_ms = [int64]$startedAt.ElapsedMilliseconds
        official_cli = $true
    } | ConvertTo-Json -Depth 64
    exit 4
} finally {
    if ($null -ne $stdoutBuffer) { $stdoutBuffer.Dispose() }
    if ($null -ne $stderrBuffer) { $stderrBuffer.Dispose() }
    if ($null -ne $process) { $process.Dispose() }
}
