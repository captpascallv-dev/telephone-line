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
. (Join-Path $PSScriptRoot 'DirectClaude.Common.ps1')

$request = $null
$process = $null
$stdoutBuffer = $null
$stderrBuffer = $null
$startedAt = [Diagnostics.Stopwatch]::StartNew()
$nativeSessionId = ''
$cliExitCode = $null
$assistantText = ''
try {
    $wrapperIdentity = Get-DirectClaudeFileIdentity -Path $PSCommandPath
    if ([int64]$wrapperIdentity.bytes -ne $ExpectedWrapperBytes -or [string]$wrapperIdentity.sha256 -cne $ExpectedWrapperSha256) {
        throw 'Direct Claude wrapper identity changed before launch.'
    }

    $requestRead = Read-DirectClaudeJson -Path $RequestPath
    if ([int64]$requestRead.identity.bytes -ne $ExpectedRequestBytes -or [string]$requestRead.identity.sha256 -cne $ExpectedRequestSha256) {
        throw 'Direct Claude request identity changed before launch.'
    }
    $request = $requestRead.value
    Assert-DirectClaudeKeys -Value $request -Keys @(
        'protocol_version', 'job_id', 'workspace', 'prompt', 'model', 'permission_mode',
        'supplied_session_id', 'session_id', 'resume', 'timeout_seconds',
        'max_output_bytes', 'cli', 'wrapper', 'created_at_utc'
    ) -Label 'Direct Claude request'

    if ([string]$request.protocol_version -cne 'telephone-line-direct-claude-request-v1') { throw 'Unsupported Direct Claude request protocol.' }
    if ([string]$request.job_id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'Direct Claude job ID is invalid.' }
    if ($request.resume -isnot [bool]) { throw 'Direct Claude resume control is malformed.' }
    if ([bool]$request.resume) {
        Assert-DirectClaudeNativeSessionIdFormat -SessionId ([string]$request.session_id) -Label 'Direct Claude request'
    } elseif (-not [string]::IsNullOrEmpty([string]$request.session_id)) {
        throw 'Direct Claude start must not synthesize a native session id unless it is supplied for verification.'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$request.supplied_session_id)) {
        Assert-DirectClaudeNativeSessionIdFormat -SessionId ([string]$request.supplied_session_id) -Label 'Direct Claude supplied session'
    }

    $workspace = Get-DirectClaudeCanonicalDirectory -Path ([string]$request.workspace)
    if (-not [IO.Directory]::Exists($workspace)) { throw 'Direct Claude workspace does not exist.' }
    $workspaceItem = Get-Item -LiteralPath $workspace -Force -ErrorAction Stop
    if (-not $workspaceItem.PSIsContainer -or ($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Direct Claude workspace must be a regular directory.'
    }

    if ($request.prompt -isnot [Collections.IDictionary]) { throw 'Direct Claude prompt binding is malformed.' }
    Assert-DirectClaudeKeys -Value $request.prompt -Keys @('path', 'bytes', 'sha256') -Label 'Direct Claude prompt binding'
    $promptIdentity = Get-DirectClaudeFileIdentity -Path ([string]$request.prompt.path)
    Assert-DirectClaudeIdentity -Expected $request.prompt -Actual $promptIdentity -Label 'Direct Claude prompt'
    $promptBytes = [IO.File]::ReadAllBytes([string]$promptIdentity.path)
    if ($promptBytes.Length -ge 3 -and $promptBytes[0] -eq 0xEF -and $promptBytes[1] -eq 0xBB -and $promptBytes[2] -eq 0xBF) {
        throw 'Direct Claude prompt must be UTF-8 without BOM.'
    }
    if ($promptBytes.Length -eq 0) { throw 'Direct Claude prompt is empty.' }

    $adapterRoot = Get-DirectClaudeCanonicalDirectory -Path $PSScriptRoot
    $expectedWrapperPath = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'invoke_claude.ps1'))
    Assert-DirectClaudeKeys -Value $request.wrapper -Keys @('path', 'bytes', 'sha256') -Label 'Direct Claude wrapper binding'
    if (-not $expectedWrapperPath.Equals([IO.Path]::GetFullPath([string]$request.wrapper.path), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Direct Claude wrapper escaped the adapter root.'
    }
    Assert-DirectClaudeIdentity -Expected $request.wrapper -Actual (Get-DirectClaudeFileIdentity -Path $expectedWrapperPath) -Label 'Direct Claude wrapper'

    Assert-DirectClaudeKeys -Value $request.cli -Keys @('path', 'bytes', 'sha256') -Label 'Direct Claude executable binding'
    $cliPath = [IO.Path]::GetFullPath([string]$request.cli.path)
    Assert-DirectClaudeIdentity -Expected $request.cli -Actual (Get-DirectClaudeFileIdentity -Path $cliPath) -Label 'Direct Claude executable'

    $cliArguments = [Collections.Generic.List[string]]::new()
    [void]$cliArguments.Add('-p')
    [void]$cliArguments.Add('--output-format')
    [void]$cliArguments.Add('json')
    if ([bool]$request.resume) {
        [void]$cliArguments.Add('--resume')
        [void]$cliArguments.Add([string]$request.session_id)
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$request.supplied_session_id)) {
        [void]$cliArguments.Add('--session-id')
        [void]$cliArguments.Add([string]$request.supplied_session_id)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$request.model)) {
        if ([string]$request.model -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Direct Claude model is malformed.' }
        [void]$cliArguments.Add('--model')
        [void]$cliArguments.Add([string]$request.model)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$request.permission_mode)) {
        if ([string]$request.permission_mode -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Direct Claude permission mode is malformed.' }
        [void]$cliArguments.Add('--permission-mode')
        [void]$cliArguments.Add([string]$request.permission_mode)
    }
    $expected = if ([bool]$request.resume) { [string]$request.session_id } else { [string]$request.supplied_session_id }
    Assert-DirectClaudeArgumentSafety -Arguments @($cliArguments) -Resume ([bool]$request.resume) -ExpectedSessionId $expected

    $startInfo = New-DirectClaudeProcessStartInfo -CliPath $cliPath -CliArguments @($cliArguments) -Workspace $workspace
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Claude Code CLI did not start.' }
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

    $cliJson = ConvertFrom-DirectClaudeCliJson -Bytes $stdoutBytes -Label 'Claude Code JSON result' -MaxBytes ([int64]$request.max_output_bytes)
    $verifyAgainst = if ([bool]$request.resume) { [string]$request.session_id } elseif (-not [string]::IsNullOrWhiteSpace([string]$request.supplied_session_id)) { [string]$request.supplied_session_id } else { '' }
    $nativeSessionId = Get-DirectClaudeNativeSessionIdFromResult -Value $cliJson -ExpectedSessionId $verifyAgainst
    if (-not $cliJson.Contains('result') -or $cliJson.result -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$cliJson.result)) {
        throw 'Claude Code JSON result has no assistant text.'
    }
    $assistantText = [string]$cliJson.result
    if (-not $finished) { throw 'Claude Code CLI exceeded a bounded startup window.' }
    if ($cliExitCode -ne 0) { throw 'Claude Code CLI exited nonzero.' }

    [ordered]@{
        protocol_version = 'telephone-line-direct-claude-result-v1'
        job_id = [string]$request.job_id
        success = $true
        error = $null
        workspace = $workspace
        prompt = $promptIdentity
        session_id = $nativeSessionId
        resumed = [bool]$request.resume
        cli_exit_code = $cliExitCode
        assistant_text = $assistantText
        diagnostic = ''
        duration_ms = [int64]$startedAt.ElapsedMilliseconds
        official_cli = $true
    } | ConvertTo-Json -Depth 64
    exit 0
} catch {
    [ordered]@{
        protocol_version = 'telephone-line-direct-claude-result-v1'
        job_id = if ($null -ne $request) { [string]$request.job_id } else { '' }
        success = $false
        error = Get-DirectClaudePublicError -Text $_.Exception.Message
        workspace = if ($null -ne $request) { [string]$request.workspace } else { '' }
        prompt = if ($null -ne $request -and $request.prompt -is [Collections.IDictionary]) { $request.prompt } else { $null }
        session_id = $nativeSessionId
        resumed = if ($null -ne $request) { [bool]$request.resume } else { $false }
        cli_exit_code = $cliExitCode
        assistant_text = ''
        diagnostic = Protect-DirectClaudeDiagnostic -Text $_.Exception.Message
        duration_ms = [int64]$startedAt.ElapsedMilliseconds
        official_cli = $true
    } | ConvertTo-Json -Depth 64
    exit 4
} finally {
    if ($null -ne $stdoutBuffer) { $stdoutBuffer.Dispose() }
    if ($null -ne $stderrBuffer) { $stderrBuffer.Dispose() }
    if ($null -ne $process) { $process.Dispose() }
}
