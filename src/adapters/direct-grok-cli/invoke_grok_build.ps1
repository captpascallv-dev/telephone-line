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
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
. (Join-Path $PSScriptRoot 'DirectGrok.Common.ps1')

$request = $null
$process = $null
$startedAt = [Diagnostics.Stopwatch]::StartNew()
try {
    $wrapperIdentity = Get-DirectGrokFileIdentity -Path $PSCommandPath
    if ([int64]$wrapperIdentity.bytes -ne $ExpectedWrapperBytes -or [string]$wrapperIdentity.sha256 -cne $ExpectedWrapperSha256) {
        throw 'Direct Grok wrapper identity changed before launch.'
    }

    $requestRead = Read-DirectGrokJson -Path $RequestPath
    if ([int64]$requestRead.identity.bytes -ne $ExpectedRequestBytes -or [string]$requestRead.identity.sha256 -cne $ExpectedRequestSha256) {
        throw 'Direct Grok request identity changed before launch.'
    }
    $request = $requestRead.value
    Assert-DirectGrokKeys -Value $request -Keys @(
        'protocol_version', 'job_id', 'workspace', 'prompt', 'model', 'reasoning_effort',
        'session_id', 'resume', 'timeout_seconds', 'max_output_bytes', 'grok', 'wrapper', 'created_at_utc'
    ) -Label 'Direct Grok request'

    if ([string]$request.protocol_version -cne 'telephone-line-direct-grok-request-v1') { throw 'Unsupported Direct Grok request protocol.' }
    if ([string]$request.job_id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'Direct Grok job ID is invalid.' }
    if ([string]$request.session_id -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Direct Grok session ID is invalid.' }
    if ($request.resume -isnot [bool]) { throw 'Direct Grok resume control is malformed.' }
    if ([string]$request.model -cne 'grok-4.6' -or [string]$request.reasoning_effort -cne 'xhigh') {
        throw 'Direct Grok must use grok-4.6 xhigh.'
    }

    $workspace = [IO.Path]::GetFullPath([string]$request.workspace).TrimEnd('\')
    if (-not [IO.Directory]::Exists($workspace)) { throw 'Direct Grok workspace does not exist.' }
    if ($request.prompt -isnot [Collections.IDictionary]) { throw 'Direct Grok prompt binding is malformed.' }
    Assert-DirectGrokKeys -Value $request.prompt -Keys @('path', 'bytes', 'sha256') -Label 'Direct Grok prompt binding'
    $promptIdentity = Get-DirectGrokFileIdentity -Path ([string]$request.prompt.path)
    Assert-DirectGrokIdentity -Expected $request.prompt -Actual $promptIdentity -Label 'Direct Grok prompt'

    $adapterRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    $expectedWrapperPath = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'invoke_grok_build.ps1'))
    if ($request.wrapper -isnot [Collections.IDictionary]) { throw 'Direct Grok wrapper binding is malformed.' }
    Assert-DirectGrokKeys -Value $request.wrapper -Keys @('path', 'bytes', 'sha256') -Label 'Direct Grok wrapper binding'
    if (-not $expectedWrapperPath.Equals([IO.Path]::GetFullPath([string]$request.wrapper.path), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Direct Grok wrapper escaped the adapter root.'
    }
    Assert-DirectGrokIdentity -Expected $request.wrapper -Actual (Get-DirectGrokFileIdentity -Path $expectedWrapperPath) -Label 'Direct Grok wrapper'

    if ($request.grok -isnot [Collections.IDictionary]) { throw 'Direct Grok executable binding is malformed.' }
    Assert-DirectGrokKeys -Value $request.grok -Keys @('path', 'bytes', 'sha256') -Label 'Direct Grok executable binding'
    $grokPath = [IO.Path]::GetFullPath([string]$request.grok.path)
    Assert-DirectGrokIdentity -Expected $request.grok -Actual (Get-DirectGrokFileIdentity -Path $grokPath) -Label 'Direct Grok executable'

    $arguments = @(
        '--cwd', $workspace,
        '--model', 'grok-4.6',
        '--reasoning-effort', 'xhigh',
        '--permission-mode', 'bypassPermissions',
        '--output-format', 'json',
        '--verbatim',
        '--prompt-file', [string]$promptIdentity.path
    )
    if ([bool]$request.resume) { $arguments += @('--resume', [string]$request.session_id) }
    else { $arguments += @('--session-id', [string]$request.session_id) }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $grokPath
    $startInfo.WorkingDirectory = $workspace
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Official Grok CLI did not start.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
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
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = if ($finished) { [int]$process.ExitCode } else { 124 }
    $jobRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($RequestPath))
    $artifacts = Get-DirectGrokJobArtifactPaths -JobRoot $jobRoot
    if ([string]$env:TELEPHONE_TEST_DIRECT_GROK_CRASH_BEFORE_CLI -ceq '1') { exit 99 }
    if ($finished -and [int]$exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($stdout) -and -not [IO.File]::Exists($artifacts.cli_stdout)) {
        try { $null = Write-DirectGrokBytesCreateNew -Path $artifacts.cli_stdout -Bytes $utf8NoBom.GetBytes($stdout) } catch [IO.IOException] { }
    }
    if ([IO.File]::Exists($artifacts.cli_stdout)) {
        $null = Write-DirectGrokSessionProof -Artifacts $artifacts -Request $request
    }
    if ([string]$env:TELEPHONE_TEST_DIRECT_GROK_CRASH_AFTER_CLI_STDOUT -ceq '1') { exit 99 }
    if ($utf8NoBom.GetByteCount($stdout) -gt [int]$request.max_output_bytes) {
        throw 'Official Grok CLI output exceeded the bounded result size.'
    }

    $response = $null
    $parseError = $null
    try {
        if ([string]::IsNullOrWhiteSpace($stdout)) { throw 'Official Grok CLI returned no JSON result.' }
        $response = $stdout.TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
        if ($response -isnot [Collections.IDictionary]) { throw 'Official Grok CLI result is not an object.' }
        $returnedSession = if ($response.Contains('sessionId')) { [string]$response.sessionId } elseif ($response.Contains('session_id')) { [string]$response.session_id } else { '' }
        if ([string]::IsNullOrWhiteSpace($returnedSession)) { throw 'Official Grok CLI result has no session ID.' }
        if ($returnedSession -cne [string]$request.session_id) { throw 'Official Grok CLI returned another session.' }
    } catch {
        $parseError = $_.Exception.Message
    }

    $success = $finished -and $exitCode -eq 0 -and $null -eq $parseError
    $errorText = if ($success) { $null } else { Get-DirectGrokPublicError -Text $parseError }
    $resultObject = [ordered]@{
        protocol_version = 'telephone-line-direct-grok-result-v1'
        job_id = [string]$request.job_id
        success = [bool]$success
        error = $errorText
        workspace = $workspace
        prompt = $promptIdentity
        model_id = 'grok-4.6'
        reasoning_effort = 'xhigh'
        session_id = [string]$request.session_id
        resumed = [bool]$request.resume
        grok_exit_code = $exitCode
        response = $response
        diagnostic = if ($success) { '' } else { Get-DirectGrokPublicError -Text $stderr }
        duration_ms = [int64]$startedAt.ElapsedMilliseconds
        official_cli = $true
        created_at_utc = [string]$request.created_at_utc
        automatic_rerun = $false
        replacement_started = $false
    }
    if ([IO.File]::Exists($artifacts.cli_stdout)) {
        $resultObject['cli_stdout'] = Get-DirectGrokFileIdentity -Path $artifacts.cli_stdout
    }
    if ([bool]$success -and -not [IO.File]::Exists($artifacts.checkpoint)) {
        try { $null = Write-DirectGrokJsonCreateNew -Path $artifacts.checkpoint -Value $resultObject } catch [IO.IOException] { }
    }
    if ([string]$env:TELEPHONE_TEST_DIRECT_GROK_CRASH_AFTER_CHECKPOINT -ceq '1') { exit 99 }
    $resultObject | ConvertTo-Json -Depth 64
    if ($success) { exit 0 }
    exit 4
} catch {
    [ordered]@{
        protocol_version = 'telephone-line-direct-grok-result-v1'
        job_id = if ($null -ne $request) { [string]$request.job_id } else { '' }
        success = $false
        error = Get-DirectGrokPublicError -Text $_.Exception.Message
        workspace = if ($null -ne $request) { [string]$request.workspace } else { '' }
        prompt = if ($null -ne $request -and $request.prompt -is [Collections.IDictionary]) { $request.prompt } else { $null }
        model_id = 'grok-4.6'
        reasoning_effort = 'xhigh'
        session_id = if ($null -ne $request) { [string]$request.session_id } else { '' }
        resumed = if ($null -ne $request) { [bool]$request.resume } else { $false }
        grok_exit_code = $null
        response = $null
        diagnostic = Get-DirectGrokPublicError -Text $_.Exception.Message
        duration_ms = [int64]$startedAt.ElapsedMilliseconds
        official_cli = $true
        created_at_utc = if ($null -ne $request -and $request.Contains('created_at_utc')) { [string]$request.created_at_utc } else { '' }
        automatic_rerun = $false
        replacement_started = $false
    } | ConvertTo-Json -Depth 64
    exit 4
} finally {
    if ($null -ne $process) { $process.Dispose() }
}
