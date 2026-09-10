# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'tests\adapters\AdapterTest.Common.ps1')
. (Join-Path $repoRoot 'src\adapters\direct-cursor\DirectCursor.Common.ps1')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
$outsideRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('TelephoneLineDirectCursorRecovery-' + [Guid]::NewGuid().ToString('N'))
$workspace = Join-Path $outsideRoot 'workspace'
$stateRoot = Join-Path $testRoot 'state'
$promptPath = Join-Path $testRoot 'prompt.txt'
$promptText = 'DIRECT-CURSOR-RECOVERY-PROMPT'
$powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$observations = [ordered]@{
    protocol_version = 'telephone-line-direct-cursor-recovery-test-observations-v1'
    fixture_label = 'FAKE-SOURCE-NOT-FOR-SWS'
    cases = [Collections.Generic.List[object]]::new()
}

function Add-Observation {
    param([string]$Name, [object]$Value)
    $observations.cases.Add([ordered]@{ name = $Name; detail = $Value })
}

try {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    [IO.File]::WriteAllText($promptPath, $promptText, [Text.UTF8Encoding]::new($false))

    $limitClass = Get-DirectCursorFailureClassification -Message 'Cursor CLI output exceeded the bounded result size.' -Stage 'cursor_execution' -ProcessFailureClass 'output_limit'
    Assert-AdapterTest ([string]$limitClass.failure_code -ceq 'cursor_output_limit') 'Output-limit classification lost its typed code.'
    Assert-AdapterTest ([string]$limitClass.failure_stage -ceq 'process_output_limit') 'Output-limit stage was not distinguished.'
    $streamClass = Get-DirectCursorFailureClassification -Message 'pipe broken' -Stage 'cursor_execution' -ExceptionType 'System.IO.IOException' -ProcessFailureClass 'stream_io'
    Assert-AdapterTest ([string]$streamClass.failure_code -ceq 'cursor_stream_io') 'Stream I/O classification lost its typed code.'
    Assert-AdapterTest ([string]$streamClass.failure_stage -ceq 'stream_io') 'Stream I/O stage was not distinguished.'
    $termClass = Get-DirectCursorFailureClassification -Message 'Cursor process-tree termination could not be confirmed. Further dispatch is blocked.' -Stage 'cursor_execution'
    Assert-AdapterTest ([string]$termClass.failure_code -ceq 'cursor_termination_uncertain') 'Termination classification lost its typed code.'
    $postClass = Get-DirectCursorFailureClassification -Message 'Workspace contains a reparse point and is not eligible for automated dispatch.' -Stage 'post_execution_snapshot'
    Assert-AdapterTest ([string]$postClass.failure_code -ceq 'cursor_post_execution') 'Post-execution classification lost its typed code.'
    $termInvalid = Get-DirectCursorFailureClassification -Message 'Cursor stream must contain exactly one init event and one terminal result event.' -Stage 'terminal_validation'
    Assert-AdapterTest ([string]$termInvalid.failure_code -ceq 'cursor_terminal_invalid') 'Terminal-invalid classification drifted.'

    $cliPublic = Get-DirectPublicError -ErrorCode 'DIRECT_CURSOR_CLI_FAILURE'
    $rewritten = Get-DirectPublicError -Message $cliPublic
    Assert-AdapterTest ($rewritten -ceq $cliPublic) 'Get-DirectPublicError still generic-falls-back a typed catalog string.'
    $terminalResult = [ordered]@{
        success = $false
        failure_kind = 'transport'
        failure_code = 'cursor_terminal_invalid'
        failure_stage = 'terminal_validation'
        public_error_code = 'DIRECT_CURSOR_TERMINAL_INVALID'
        error = Get-DirectPublicError -ErrorCode 'DIRECT_CURSOR_TERMINAL_INVALID'
        fast_disabled = $true
    }
    $resolvedReceipt = Resolve-DirectCursorReceiptPublicError -CursorResult $terminalResult
    Assert-AdapterTest ([string]$resolvedReceipt.public_error_code -ceq 'DIRECT_CURSOR_TERMINAL_INVALID') 'Receipt helper dropped terminal-invalid code.'
    Assert-AdapterTest ([string]$resolvedReceipt.transport_error -cne (Get-DirectPublicError -ErrorCode 'ADAPTER_TRANSPORT_FAILED')) 'Receipt helper overwrote terminal-invalid with generic transport.'

    $partialStdout = '{"type":"system","subtype":"init","cwd":"C:\\obs","session_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee0","model":"Cursor Grok 4.6 Extra High","apiKeySource":"login"}' + "`n" + '{"type":"assistant","partial":true'
    $observed = Get-DirectCursorObservedIdentity -Stdout $partialStdout -Workspace 'C:\obs'
    Assert-AdapterTest ([string]$observed.session_id -ceq 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee0') 'Observed init session was not parsed from truncated stdout.'
    Assert-AdapterTest ([bool]$observed.accepted -eq $false) 'Observed session was marked accepted.'
    Assert-AdapterTest ([bool]$observed.terminal_available -eq $false) 'Missing terminal was treated as present.'
    Assert-AdapterTest ([bool]$observed.truncated_or_malformed -eq $true) 'Truncated tail was not recorded.'

    $childCs = @'
using System;
using System.IO;
using System.Text;
namespace DirectCursorRecoveryTest {
    public static class Program {
        public static int Main(string[] args) {
            string mode = Environment.GetEnvironmentVariable("DIRECT_CURSOR_TEST_CHILD_MODE") ?? "normal";
            string session = Environment.GetEnvironmentVariable("DIRECT_CURSOR_TEST_SESSION") ?? "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
            string workspace = Directory.GetCurrentDirectory();
            for (int i = 0; i < args.Length; i++) {
                if (args[i] == "--version") { Console.Write("1.0.0-test\n"); return 0; }
                if (args[i] == "models") { Console.Write("cursor-grok-4.6-xhigh - Cursor Grok 4.6 Extra High\n"); return 0; }
                if (args[i] == "--workspace" && i + 1 < args.Length) { workspace = args[i + 1]; }
            }
            string escaped = workspace.Replace("\\", "\\\\").Replace("\"", "\\\"");
            string init = "{\"type\":\"system\",\"subtype\":\"init\",\"cwd\":\"" + escaped + "\",\"session_id\":\"" + session + "\",\"model\":\"Cursor Grok 4.6 Extra High\",\"apiKeySource\":\"login\"}\n";
            if (mode == "overlimit") {
                Console.Write(init);
                Console.Out.Flush();
                byte[] block = Encoding.UTF8.GetBytes(new string('X', 4096));
                Stream stdout = Console.OpenStandardOutput();
                for (int i = 0; i < 40; i++) { stdout.Write(block, 0, block.Length); }
                stdout.Flush();
                return 0;
            }
            if (mode == "post_reparse") {
                Console.Write(init);
                Console.Write("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"" + session + "\",\"result\":\"ok\",\"usage\":{}}\n");
                Console.Out.Flush();
                string target = Path.Combine(workspace, "jtarget");
                string link = Path.Combine(workspace, "jlink");
                Directory.CreateDirectory(target);
                var psi = new System.Diagnostics.ProcessStartInfo("cmd.exe", "/c mklink /J \"" + link + "\" \"" + target + "\"");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                System.Diagnostics.Process p = System.Diagnostics.Process.Start(psi);
                p.WaitForExit();
                return 0;
            }
            Console.Write(init);
            Console.Write("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"" + session + "\",\"result\":\"ok\",\"usage\":{}}\n");
            return 0;
        }
    }
}
'@
    $fakeRoot = Join-Path $testRoot 'fake-cursor-agent'
    $versionDir = Join-Path $fakeRoot 'versions\test'
    [IO.Directory]::CreateDirectory($versionDir) | Out-Null
    $nodeExe = Join-Path $versionDir 'node.exe'
    $csPath = Join-Path $testRoot 'CursorTestChild.cs'
    [IO.File]::WriteAllText($csPath, $childCs, [Text.UTF8Encoding]::new($false))
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    Assert-AdapterTest ([IO.File]::Exists($csc)) 'Framework csc.exe is missing for the owned-child test.'
    $cscInfo = [Diagnostics.ProcessStartInfo]::new()
    $cscInfo.FileName = $csc
    $cscInfo.UseShellExecute = $false
    $cscInfo.RedirectStandardOutput = $true
    $cscInfo.RedirectStandardError = $true
    $cscInfo.CreateNoWindow = $true
    foreach ($argument in @('/nologo', '/target:exe', ('/out:' + $nodeExe), $csPath)) { [void]$cscInfo.ArgumentList.Add($argument) }
    $cscProc = [Diagnostics.Process]::Start($cscInfo)
    try {
        $cscOut = $cscProc.StandardOutput.ReadToEnd()
        $cscErr = $cscProc.StandardError.ReadToEnd()
        $cscProc.WaitForExit()
        Assert-AdapterTest ($cscProc.ExitCode -eq 0 -and [IO.File]::Exists($nodeExe)) ("Owned test child failed to compile: $cscOut $cscErr")
    } finally { $cscProc.Dispose() }
    [IO.File]::WriteAllText((Join-Path $versionDir 'index.js'), '// FAKE-SOURCE-NOT-FOR-SWS' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fakeRoot 'cursor-agent.ps1'), '# FAKE-SOURCE-NOT-FOR-SWS' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $wrapper = Join-Path $repoRoot 'src\adapters\direct-cursor\invoke_cursor_agent.ps1'
    $sessionId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_TEST_SESSION', $sessionId, 'Process')

    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_TEST_CHILD_MODE', 'normal', 'Process')
    $normalSessionRoot = Join-Path $testRoot 'session-normal'
    $normal = Invoke-AdapterEntrypoint -Entrypoint $wrapper -Arguments @(
        '-WorkspacePath', $workspace, '-PromptFile', $promptPath, '-Mode', 'ReadOnly',
        '-Model', 'cursor-grok-4.6-xhigh', '-SessionRoot', $normalSessionRoot,
        '-CursorAgentRoot', $fakeRoot, '-TimeoutSeconds', '30', '-MaxOutputBytes', '65536'
    )
    Assert-AdapterTest ($normal.exit_code -eq 0) ("Normal strict result failed: " + $normal.stderr + ' ' + $normal.stdout)
    Assert-AdapterTest ($normal.value.success -eq $true) 'Normal result was not success.'
    Assert-AdapterTest ([string]$normal.value.session_id -ceq $sessionId) 'Normal result lost accepted session id.'
    Assert-AdapterTest ([string]$normal.value.changed_files_availability -ceq 'available') 'Normal result lost changed-files availability.'
    Add-Observation -Name 'normal_strict' -Value ([ordered]@{ exit_code = $normal.exit_code; session_id = [string]$normal.value.session_id; success = [bool]$normal.value.success })

    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_TEST_CHILD_MODE', 'overlimit', 'Process')
    $overSessionRoot = Join-Path $testRoot 'session-overlimit'
    $over = Invoke-AdapterEntrypoint -Entrypoint $wrapper -Arguments @(
        '-WorkspacePath', $workspace, '-PromptFile', $promptPath, '-Mode', 'ReadOnly',
        '-Model', 'cursor-grok-4.6-xhigh', '-SessionRoot', $overSessionRoot,
        '-CursorAgentRoot', $fakeRoot, '-TimeoutSeconds', '30', '-MaxOutputBytes', '65536'
    )
    Assert-AdapterTest ($over.exit_code -eq 1) 'Over-limit child was treated as success.'
    Assert-AdapterTest ($over.value.success -eq $false) 'Over-limit child set success true.'
    Assert-AdapterTest ([string]$over.value.failure_code -ceq 'cursor_output_limit') ('Over-limit typed code missing: ' + [string]$over.value.failure_code)
    Assert-AdapterTest ([string]$over.value.failure_stage -ceq 'process_output_limit') ('Over-limit stage missing: ' + [string]$over.value.failure_stage)
    Assert-AdapterTest ([string]$over.value.session_id -eq '') 'Over-limit observed session was accepted as session_id.'
    Assert-AdapterTest ([string]$over.value.observed_session.session_id -ceq $sessionId) 'Over-limit did not preserve observed init session.'
    Assert-AdapterTest ([bool]$over.value.observed_session.accepted -eq $false) 'Over-limit marked observed session accepted.'
    Assert-AdapterTest ([int64]$over.value.stdout_bytes -gt 0) 'Over-limit discarded captured stdout.'
    Assert-AdapterTest ([int64]$over.value.stdout_bytes -le 65536) 'Over-limit durable capture exceeded the configured bound.'
    $diagPath = [string]$over.value.evidence.diagnostic.path
    Assert-AdapterTest ([IO.File]::Exists($diagPath)) 'Over-limit diagnostic file is missing.'
    $diagDoc = (Get-Content -Raw -LiteralPath $diagPath | ConvertFrom-Json -AsHashtable)
    Assert-AdapterTest ([bool]$diagDoc.captured_truncated -eq $true -or [bool]$diagDoc.over_limit -eq $true) 'Over-limit diagnostic omitted truncation.'
    Assert-AdapterTest ([string]$over.value.error -cne (Get-DirectPublicError -ErrorCode 'ADAPTER_TRANSPORT_FAILED') -or [string]$over.value.public_error_code -ceq 'DIRECT_CURSOR_OUTPUT_LIMIT') 'Over-limit public error was generic transport.'
    Add-Observation -Name 'output_limit_child' -Value ([ordered]@{
        exit_code = $over.exit_code
        failure_code = [string]$over.value.failure_code
        failure_stage = [string]$over.value.failure_stage
        observed_session_id = [string]$over.value.observed_session.session_id
        stdout_bytes = [int64]$over.value.stdout_bytes
        diagnostic = $diagPath
    })

    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_TEST_CHILD_MODE', 'post_reparse', 'Process')
    $postSessionRoot = Join-Path $testRoot 'session-post-snapshot'
    $post = Invoke-AdapterEntrypoint -Entrypoint $wrapper -Arguments @(
        '-WorkspacePath', $workspace, '-PromptFile', $promptPath, '-Mode', 'ReadOnly',
        '-Model', 'cursor-grok-4.6-xhigh', '-SessionRoot', $postSessionRoot,
        '-CursorAgentRoot', $fakeRoot, '-TimeoutSeconds', '30', '-MaxOutputBytes', '65536'
    )
    Assert-AdapterTest ($post.exit_code -eq 1) 'Post-snapshot fault was treated as success.'
    Assert-AdapterTest ([string]$post.value.failure_code -ceq 'cursor_post_execution') ('Post-snapshot code missing: ' + [string]$post.value.failure_code)
    Assert-AdapterTest ([string]$post.value.failure_stage -ceq 'post_execution_reparse') ('Post-snapshot stage missing: ' + [string]$post.value.failure_stage)
    Assert-AdapterTest ([string]$post.value.session_id -eq '') 'Post-snapshot accepted a session id.'
    Assert-AdapterTest ([string]$post.value.observed_session.session_id -ceq $sessionId) 'Post-snapshot dropped observed init session from the retained run.'
    Assert-AdapterTest ([string]$post.value.error -ceq (Get-DirectPublicError -ErrorCode 'DIRECT_CURSOR_POST_EXECUTION')) 'Post-execution public error was overwritten.'
    Add-Observation -Name 'post_execution_reparse_fault' -Value ([ordered]@{
        failure_code = [string]$post.value.failure_code
        failure_stage = [string]$post.value.failure_stage
        observed_session_id = [string]$post.value.observed_session.session_id
        changed_files_availability = [string]$post.value.changed_files_availability
    })
    foreach ($leftover in @((Join-Path $workspace 'jlink'), (Join-Path $workspace 'jtarget'))) {
        try { if ([IO.Directory]::Exists($leftover)) { [IO.Directory]::Delete($leftover, $true) } } catch { }
    }

    $adapterCopy = Join-Path $testRoot 'adapter-receipt'
    Copy-AdapterForTest -Source (Join-Path $repoRoot 'src\adapters\direct-cursor') -Destination $adapterCopy
    $failWrapper = @'
# SPDX-License-Identifier: MPL-2.0
param(
    [Parameter(Mandatory = $true)][string]$WorkspacePath,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [string]$Mode, [string]$Model, [string]$ExpectedAccount, [string]$ExpectedSubscription,
    [string]$ResumeSessionId, [string]$SessionRoot, [string[]]$AllowedWritePath,
    [switch]$AllowWrite, [switch]$AllowFast, [string]$CursorAgentRoot,
    [int]$TimeoutSeconds, [int]$MaxOutputBytes
)
. (Join-Path $PSScriptRoot 'DirectCursor.Common.ps1')
$promptBytes = [IO.File]::ReadAllBytes($PromptFile)
$promptSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes)).ToLowerInvariant()
[ordered]@{
    success = $false
    prompt_sha256 = $promptSha
    prompt = [ordered]@{ path = [IO.Path]::GetFullPath($PromptFile); bytes = [int64]$promptBytes.Length; sha256 = $promptSha }
    failure_kind = 'transport'
    failure_code = 'cursor_terminal_invalid'
    failure_stage = 'terminal_validation'
    public_error_code = 'DIRECT_CURSOR_TERMINAL_INVALID'
    error = Get-DirectPublicError -ErrorCode 'DIRECT_CURSOR_TERMINAL_INVALID'
    workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\')
    mode = $Mode
    model_id = $Model
    allowed_write_paths = @($AllowedWritePath | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    fast_disabled = $true
    session_id = ''
    observed_session = [ordered]@{ session_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; status = 'partial'; accepted = $false; source = 'init_event' }
    changed_files_availability = 'unknown'
    changed_files = $null
} | ConvertTo-Json -Depth 8
exit 1
'@
    [IO.File]::WriteAllText((Join-Path $adapterCopy 'invoke_cursor_agent.ps1'), $failWrapper.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    $receiptState = Join-Path $testRoot 'receipt-state'
    $receiptJob = [Guid]::NewGuid().ToString('D')
    $receiptRun = Invoke-AdapterEntrypoint -Entrypoint (Join-Path $adapterCopy 'Invoke-DirectCursorRoute.ps1') -Arguments @(
        '-Operation', 'start', '-StateRoot', $receiptState, '-WorkspacePath', $workspace, '-PromptFile', $promptPath,
        '-Mode', 'ReadOnly', '-JobId', $receiptJob, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($receiptRun.exit_code -eq 2) 'Terminal-invalid outer receipt did not return adapter-failure exit.'
    Assert-AdapterTest ([string]$receiptRun.value.failure_code -ceq 'cursor_terminal_invalid') 'Outer adapter result lost cursor_terminal_invalid.'
    Assert-AdapterTest ([string]$receiptRun.value.transport_error -ceq (Get-DirectPublicError -ErrorCode 'DIRECT_CURSOR_TERMINAL_INVALID')) 'Outer receipt overwrote terminal-invalid with generic transport.'
    $receiptPath = Join-Path $receiptState ("jobs\$receiptJob\receipt.json")
    $receiptDoc = (Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json -AsHashtable)
    Assert-AdapterTest ([string]$receiptDoc.transport_error -ceq (Get-DirectPublicError -ErrorCode 'DIRECT_CURSOR_TERMINAL_INVALID')) 'Persisted receipt overwrote typed public error.'
    Assert-AdapterTest ([string]$receiptDoc.native_session_id -eq '') 'Outer receipt accepted an observed session as native_session_id.'
    Add-Observation -Name 'terminal_invalid_outer_receipt' -Value ([ordered]@{
        exit_code = $receiptRun.exit_code
        failure_code = [string]$receiptRun.value.failure_code
        transport_error = [string]$receiptRun.value.transport_error
    })

    $admitRoot = Join-Path $testRoot 'admit-state'
    $admitWorkspace = Join-Path $outsideRoot 'admit-workspace'
    [IO.Directory]::CreateDirectory($admitWorkspace) | Out-Null
    $fakeSession = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    $oldSession = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
    $jobId = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
    $transcriptDir = Join-Path $testRoot ('transcripts\' + $fakeSession)
    [IO.Directory]::CreateDirectory($transcriptDir) | Out-Null
    $transcriptPath = Join-Path $transcriptDir ($fakeSession + '.jsonl')
    $metaDir = Join-Path $testRoot ('meta\' + $fakeSession)
    [IO.Directory]::CreateDirectory($metaDir) | Out-Null
    $metaPath = Join-Path $metaDir 'meta.json'
    $utf8 = [Text.UTF8Encoding]::new($false)
    $transcript = (@(
        '{"role":"user","message":{"content":[{"type":"text","text":"FAKE-SOURCE-NOT-FOR-SWS prompt"}]}}',
        '{"role":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}'
    ) -join "`n") + "`n"
    [IO.File]::WriteAllText($transcriptPath, $transcript, $utf8)
    $meta = [ordered]@{
        schemaVersion = 1
        createdAtMs = 1
        updatedAtMs = 2
        hasConversation = $true
        cwd = $admitWorkspace
    }
    [IO.File]::WriteAllText($metaPath, (($meta | ConvertTo-Json -Compress) + "`n"), $utf8)
    $promptIdentity = Get-DirectFileIdentity -Path $promptPath
    $requestPath = Join-Path $testRoot 'fake-request.json'
    $request = [ordered]@{
        protocol_version = 'telephone-line-direct-cursor-request-v1'
        job_id = $jobId
        workspace = $admitWorkspace
        prompt = $promptIdentity
        mode = 'ReadOnly'
        model = 'cursor-grok-4.6-xhigh'
        expected_account = ''
        expected_subscription = ''
        resume_session_id = ''
        allowed_write_paths = @()
        allow_write = $false
        allow_fast = $false
        timeout_seconds = 0
        max_output_bytes = 65536
        session_root = (Join-Path $admitRoot 'cursor-sessions')
        wrapper = @{ path = $wrapper; bytes = 1; sha256 = ('0' * 64) }
        cursor_agent_root = ''
    }
    $null = Write-DirectJsonCreateNew -Path $requestPath -Value $request
    $requestIdentity = Get-DirectFileIdentity -Path $requestPath
    $receiptPathFake = Join-Path $testRoot 'fake-receipt.json'
    $receiptFake = [ordered]@{
        protocol_version = 'telephone-line-direct-cursor-receipt-v1'
        job_id = $jobId
        request = $requestIdentity
        transport_complete = $false
        transport_error = Get-DirectPublicError -ErrorCode 'ADAPTER_TRANSPORT_FAILED'
        cursor_success = $false
        native_session_id = ''
        cursor_result = [ordered]@{
            success = $false
            failure_code = 'adapter_transport_failure'
            failure_stage = 'cursor_execution'
            session_id = ''
        }
        stdout = $null
        stderr = $null
        owner = $null
        automatic_rerun = $false
        replacement_started = $false
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $null = Write-DirectJsonCreateNew -Path $receiptPathFake -Value $receiptFake
    $oldBindingPath = Join-Path $testRoot 'fake-old-binding.json'
    $null = Write-DirectJsonCreateNew -Path $oldBindingPath -Value ([ordered]@{
        protocol_version = 'telephone-line-direct-cursor-binding-v1'
        native_session_id = $oldSession
        latest_job_id = [Guid]::NewGuid().ToString('D')
        workspace = $admitWorkspace
        mode = 'ReadOnly'
        allowed_write_paths = @()
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    $ownerPath = Join-Path $testRoot 'fake-dead-owner.json'
    $null = Write-DirectJsonCreateNew -Path $ownerPath -Value ([ordered]@{
        protocol_version = 'telephone-line-direct-cursor-owner-v1'
        pid = 1
        start_time_utc_ticks = 1
        started_at_utc = '2020-01-01T00:00:00Z'
    })
    $originalReceiptBytes = [IO.File]::ReadAllBytes($receiptPathFake)

    $admit = Invoke-AdapterEntrypoint -Entrypoint (Join-Path $repoRoot 'src\adapters\direct-cursor\Register-DirectCursorPartialSession.ps1') -Arguments @(
        '-StateRoot', $admitRoot,
        '-FailedRequestPath', $requestPath,
        '-FailedReceiptPath', $receiptPathFake,
        '-NativeTranscriptPath', $transcriptPath,
        '-NativeMetaPath', $metaPath,
        '-ObservedSessionId', $fakeSession,
        '-OldBindingPath', $oldBindingPath,
        '-FailedOwnerPath', $ownerPath,
        '-FixtureLabel', 'FAKE-SOURCE-NOT-FOR-SWS'
    )
    Assert-AdapterTest ($admit.exit_code -eq 0) ("Partial admission failed: " + $admit.stderr + ' ' + $admit.stdout)
    Assert-AdapterTest ([string]$admit.value.status -ceq 'provisional') 'Partial admission was not provisional.'
    Assert-AdapterTest ([bool]$admit.value.accepted_binding_written -eq $false) 'Partial admission wrote an accepted binding.'
    Assert-AdapterTest ([bool]$admit.value.receipt_fabricated -eq $false) 'Partial admission fabricated a receipt.'
    Assert-AdapterTest ([int]$admit.value.continuation_remaining -eq 1) 'Partial admission did not authorize one continuation.'
    $bindingPath = Join-Path $admitRoot ('sessions\' + $fakeSession + '\binding.json')
    Assert-AdapterTest (-not [IO.File]::Exists($bindingPath)) 'Partial admission created an ordinary accepted binding.json.'
    $afterReceipt = [IO.File]::ReadAllBytes($receiptPathFake)
    Assert-AdapterTest (@(Compare-Object $originalReceiptBytes $afterReceipt).Count -eq 0) 'Partial admission mutated the original failed receipt.'
    Add-Observation -Name 'partial_admission_positive' -Value ([ordered]@{
        status = [string]$admit.value.status
        continuation_remaining = [int]$admit.value.continuation_remaining
        accepted_binding_written = [bool]$admit.value.accepted_binding_written
    })

    $mismatch = Invoke-AdapterEntrypoint -Entrypoint (Join-Path $repoRoot 'src\adapters\direct-cursor\Register-DirectCursorPartialSession.ps1') -Arguments @(
        '-StateRoot', (Join-Path $testRoot 'admit-mismatch'),
        '-FailedRequestPath', $requestPath,
        '-FailedReceiptPath', $receiptPathFake,
        '-NativeTranscriptPath', $transcriptPath,
        '-NativeMetaPath', $metaPath,
        '-ObservedSessionId', '00000000-0000-4000-8000-000000000000',
        '-OldBindingPath', $oldBindingPath,
        '-FailedOwnerPath', $ownerPath,
        '-FixtureLabel', 'FAKE-SOURCE-NOT-FOR-SWS'
    )
    Assert-AdapterTest ($mismatch.exit_code -ne 0) 'Mismatched session id was admitted.'
    Add-Observation -Name 'partial_admission_mismatch' -Value ([ordered]@{ exit_code = $mismatch.exit_code; stderr = [string]$mismatch.stderr })

    $live = Start-Process -FilePath $powerShellPath -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 90') -PassThru -WindowStyle Hidden
    try {
        $liveOwnerPath = Join-Path $testRoot 'fake-live-owner.json'
        $null = Write-DirectJsonCreateNew -Path $liveOwnerPath -Value ([ordered]@{
            protocol_version = 'telephone-line-direct-cursor-owner-v1'
            pid = [int]$live.Id
            start_time_utc_ticks = [int64]$live.StartTime.ToUniversalTime().Ticks
            started_at_utc = $live.StartTime.ToUniversalTime().ToString('o')
        })
        $liveAdmit = Invoke-AdapterEntrypoint -Entrypoint (Join-Path $repoRoot 'src\adapters\direct-cursor\Register-DirectCursorPartialSession.ps1') -Arguments @(
            '-StateRoot', (Join-Path $testRoot 'admit-live'),
            '-FailedRequestPath', $requestPath,
            '-FailedReceiptPath', $receiptPathFake,
            '-NativeTranscriptPath', $transcriptPath,
            '-NativeMetaPath', $metaPath,
            '-ObservedSessionId', $fakeSession,
            '-FailedOwnerPath', $liveOwnerPath,
            '-FixtureLabel', 'FAKE-SOURCE-NOT-FOR-SWS'
        )
        Assert-AdapterTest ($liveAdmit.exit_code -ne 0) 'Live owner was admitted.'
        Add-Observation -Name 'partial_admission_live_owner' -Value ([ordered]@{ exit_code = $liveAdmit.exit_code; stderr = [string]$liveAdmit.stderr })
    } finally {
        try { Stop-Process -Id $live.Id -Force -ErrorAction SilentlyContinue } catch { }
        try { $live.Dispose() } catch { }
    }

    $followJob = [Guid]::NewGuid().ToString('D')
    $followCopy = Join-Path $testRoot 'adapter-follow'
    Copy-AdapterForTest -Source (Join-Path $repoRoot 'src\adapters\direct-cursor') -Destination $followCopy
    $followWrapper = @'
# SPDX-License-Identifier: MPL-2.0
param(
    [Parameter(Mandatory = $true)][string]$WorkspacePath,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [string]$Mode, [string]$Model, [string]$ExpectedAccount, [string]$ExpectedSubscription,
    [string]$ResumeSessionId, [string]$SessionRoot, [string[]]$AllowedWritePath,
    [switch]$AllowWrite, [switch]$AllowFast, [string]$CursorAgentRoot,
    [int]$TimeoutSeconds, [int]$MaxOutputBytes
)
$promptBytes = [IO.File]::ReadAllBytes($PromptFile)
$promptSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes)).ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($ResumeSessionId)) { throw 'FAKE-SOURCE follow-up missing resume id.' }
[ordered]@{
    success = $true
    prompt_sha256 = $promptSha
    prompt = [ordered]@{ path = [IO.Path]::GetFullPath($PromptFile); bytes = [int64]$promptBytes.Length; sha256 = $promptSha }
    fast_disabled = $true
    model_id = $Model
    workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\')
    mode = $Mode
    allowed_write_paths = @($AllowedWritePath | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    session_id = $ResumeSessionId
    resumed = $true
    changed_files_availability = 'available'
    changed_files = @()
} | ConvertTo-Json -Depth 8
'@
    [IO.File]::WriteAllText((Join-Path $followCopy 'invoke_cursor_agent.ps1'), $followWrapper.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    $follow = Invoke-AdapterEntrypoint -Entrypoint (Join-Path $followCopy 'Invoke-DirectCursorRoute.ps1') -Arguments @(
        '-Operation', 'follow_up', '-NativeSessionId', $fakeSession, '-StateRoot', $admitRoot,
        '-WorkspacePath', $admitWorkspace, '-PromptFile', $promptPath, '-Mode', 'ReadOnly',
        '-JobId', $followJob, '-WaitTimeoutSeconds', '60'
    )
    Assert-AdapterTest ($follow.exit_code -eq 0) ("Authorized continuation failed: " + $follow.stderr + ' ' + $follow.stdout)
    Assert-AdapterTest ([string]$follow.value.native_session_id -ceq $fakeSession) 'Continuation used a different native session.'
    $admissionAfter = Read-DirectCursorPartialAdmission -StateRoot $admitRoot -NativeSessionId $fakeSession
    Assert-AdapterTest ([int]$admissionAfter.continuation_remaining -eq 0) 'Continuation did not consume the single authorized retry.'
    Add-Observation -Name 'partial_follow_up_consumed' -Value ([ordered]@{
        exit_code = $follow.exit_code
        continuation_remaining = [int]$admissionAfter.continuation_remaining
        native_session_id = [string]$follow.value.native_session_id
    })

    $observations.assertion_count = $assertions
    $obsPath = Join-Path $testRoot 'observations.json'
    [IO.File]::WriteAllText($obsPath, (($observations | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Write-Output ("DIRECT_CURSOR_RECOVERY_ASSERTIONS=" + $assertions)
    Write-Output ("DIRECT_CURSOR_RECOVERY_OBSERVATIONS=" + $obsPath)
} finally {
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_TEST_CHILD_MODE', $null, 'Process')
    [Environment]::SetEnvironmentVariable('DIRECT_CURSOR_TEST_SESSION', $null, 'Process')
    if ([IO.Directory]::Exists($outsideRoot)) {
        try { [IO.Directory]::Delete($outsideRoot, $true) } catch { }
    }
}
