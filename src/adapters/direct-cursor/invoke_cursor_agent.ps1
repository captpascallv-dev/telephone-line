# SPDX-License-Identifier: MPL-2.0
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true)][string]$WorkspacePath,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)][string]$PromptFile,
    [Parameter(ParameterSetName = 'QualifiedProbe')][switch]$QualifiedProbe,
    [ValidateSet('ReadOnly', 'Verify', 'Write')][string]$Mode = 'ReadOnly',
    [string]$Model = 'cursor-grok-4.6-xhigh',
    [string]$ExpectedAccount = '',
    [string]$ExpectedSubscription = '',
    [string]$ResumeSessionId,
    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [Parameter(ParameterSetName = 'QualifiedProbe')]
    [string]$SessionRoot,
    [string[]]$AllowedWritePath,
    [switch]$AllowWrite,
    [switch]$AllowFast,
    [string]$CursorAgentRoot,
    [ValidateRange(0, 2147483647)][int]$TimeoutSeconds = 0,
    [ValidateRange(65536, 67108864)][int]$MaxOutputBytes = 16777216
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }
. (Join-Path $PSScriptRoot 'DirectCursor.Common.ps1')

$jobHost = Join-Path $PSScriptRoot 'cursor_job_host.ps1'
$stateRoot = [IO.Path]::GetFullPath($SessionRoot).TrimEnd('\')
$registryPath = Join-Path $stateRoot 'sessions.json'
$blockedPath = Join-Path $stateRoot 'DISPATCH_BLOCKED.json'

if (-not ('CursorAgentDispatch.NativeJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace CursorAgentDispatch {
    public static class NativeJob {
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const int JobObjectExtendedLimitInformation = 9;
        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
            public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS {
            public ulong ReadOperationCount; public ulong WriteOperationCount; public ulong OtherOperationCount;
            public ulong ReadTransferCount; public ulong WriteTransferCount; public ulong OtherTransferCount;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInfo, uint cbJobObjectInfoLength);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);
        public static IntPtr CreateKillOnCloseJob() {
            IntPtr handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed"); }
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            uint length = (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            if (!SetInformationJobObject(handle, JobObjectExtendedLimitInformation, ref info, length)) {
                int error = Marshal.GetLastWin32Error(); CloseHandle(handle);
                throw new Win32Exception(error, "SetInformationJobObject failed");
            }
            return handle;
        }
        public static void Assign(IntPtr jobHandle, IntPtr processHandle) {
            if (!AssignProcessToJobObject(jobHandle, processHandle)) { throw new Win32Exception(Marshal.GetLastWin32Error(), "AssignProcessToJobObject failed"); }
        }
        public static bool Close(IntPtr jobHandle) { return CloseHandle(jobHandle); }
    }
}
'@
}

function ConvertTo-StableCursorModelDisplay {
    param([AllowNull()][string]$Display)
    if ($null -eq $Display) { throw 'Cursor model display is empty after canonicalization.' }
    $stableDisplay = $Display.Trim()
    $stableDisplay = [regex]::Replace($stableDisplay, '\s+\(current\)$', '', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ([string]::IsNullOrEmpty($stableDisplay)) { throw 'Cursor model display is empty after canonicalization.' }
    return $stableDisplay
}

function Limit-Text {
    param([string]$Text, [int]$Limit = 2000)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Limit) { return $Text }
    return $Text.Substring(0, $Limit) + '...[truncated]'
}

function Resolve-CursorAgentInstall {
    param([string]$RequestedRoot)
    $root = $RequestedRoot
    if ([string]::IsNullOrWhiteSpace($root) -and -not [string]::IsNullOrWhiteSpace($env:TELEPHONE_LINE_CURSOR_AGENT_ROOT)) {
        $root = [string]$env:TELEPHONE_LINE_CURSOR_AGENT_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($root) -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidate = Join-Path $env:LOCALAPPDATA 'cursor-agent'
        if ([IO.Directory]::Exists($candidate)) { $root = $candidate }
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw 'Cursor Agent CLI was not found. Pass -CursorAgentRoot or install the user-local CLI.'
    }
    $cursorRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
    $versionsRoot = Join-Path $cursorRoot 'versions'
    if (-not [IO.Directory]::Exists($versionsRoot)) { throw 'Cursor Agent CLI versions directory was not found.' }
    $versionDirs = @(Get-ChildItem -LiteralPath $versionsRoot -Directory -ErrorAction Stop | Sort-Object Name -Descending)
    $selected = $null
    foreach ($dir in $versionDirs) {
        $node = Join-Path $dir.FullName 'node.exe'
        $index = Join-Path $dir.FullName 'index.js'
        if ([IO.File]::Exists($node) -and [IO.File]::Exists($index)) { $selected = $dir; break }
    }
    if ($null -eq $selected) { throw 'Cursor Agent CLI payload was not found in the discovered install.' }
    return [ordered]@{
        root = $cursorRoot
        wrapper = Join-Path $cursorRoot 'cursor-agent.ps1'
        node = Join-Path $selected.FullName 'node.exe'
        index = Join-Path $selected.FullName 'index.js'
        version = [string]$selected.Name
    }
}

function Invoke-CursorProcess {
    param(
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$NodePath,
        [string]$IndexPath,
        [int]$ProcessTimeoutSeconds,
        [int]$OutputByteLimit = 16777216,
        [string]$DiagnosticRoot,
        [string]$DispatchId,
        [string]$RequestedSessionId,
        [string]$Stage = 'cursor_execution'
    )

    $argumentsJson = $Arguments | ConvertTo-Json -Compress
    $argumentsBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($argumentsJson))
    if ($argumentsBase64.Length -gt 24000) { throw 'Cursor argument payload is too large for the guarded Windows host. Use a file-backed task specification.' }
    $diagRoot = if (-not [string]::IsNullOrWhiteSpace($DiagnosticRoot)) { $DiagnosticRoot } else { $stateRoot }
    $diagDir = New-DirectCursorProcessDiagnosticDirectory -SessionRoot $diagRoot -DispatchId $DispatchId
    $stdoutPath = Join-Path $diagDir 'stdout.bin'
    $stderrPath = Join-Path $diagDir 'stderr.bin'
    $gateName = 'Local\CursorAgentDispatchGate_' + [Guid]::NewGuid().ToString('N')
    $createdNew = $false
    $gate = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $gateName, [ref]$createdNew)
    if (-not $createdNew) { $gate.Dispose(); throw 'Cursor dispatch gate name collision.' }

    $pwshPath = [string][Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwshPath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $jobHost)) { [void]$startInfo.ArgumentList.Add($argument) }
    [void]$startInfo.Environment.Remove('CURSOR_API_KEY')
    [void]$startInfo.Environment.Remove('CURSOR_API_ENDPOINT')
    $startInfo.Environment['CURSOR_INVOKED_AS'] = 'cursor-agent.ps1'
    $startInfo.Environment['CURSOR_DISPATCH_GATE'] = $gateName
    $startInfo.Environment['CURSOR_DISPATCH_ARGUMENTS_B64'] = $argumentsBase64
    $startInfo.Environment['CURSOR_DISPATCH_NODE'] = $NodePath
    $startInfo.Environment['CURSOR_DISPATCH_INDEX'] = $IndexPath

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $startedAt = [DateTimeOffset]::UtcNow
    $jobHandle = [CursorAgentDispatch.NativeJob]::CreateKillOnCloseJob()
    $processStarted = $false
    $jobAssigned = $false
    $jobClosed = $false
    $rootExited = $false
    $runFailure = $null
    $overLimit = $false
    $timedOut = $false
    $stdoutTruncated = $false
    $stderrTruncated = $false
    $durableWritten = [int64]0
    $processFailureClass = ''
    $nativePid = 0
    $nativeTicks = [int64]0
    $nativeExe = [string]$pwshPath
    $nativeExit = $null
    $stdoutFile = $null
    $stderrFile = $null
    $stdoutMemory = [IO.MemoryStream]::new()
    $stderrMemory = [IO.MemoryStream]::new()
    try {
        $stdoutFile = [IO.FileStream]::new($stdoutPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $stderrFile = [IO.FileStream]::new($stderrPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $processStarted = $process.Start()
        if (-not $processStarted) { throw 'Cursor CLI process did not start.' }
        $nativePid = [int]$process.Id
        try { $nativeTicks = [int64]$process.StartTime.ToUniversalTime().Ticks } catch { }
        [CursorAgentDispatch.NativeJob]::Assign($jobHandle, $process.Handle)
        $jobAssigned = $true
        [void]$gate.Set()
        $stdoutStream = $process.StandardOutput.BaseStream
        $stderrStream = $process.StandardError.BaseStream
        $stdoutBuffer = [byte[]]::new(8192)
        $stderrBuffer = [byte[]]::new(8192)
        $stdoutClosed = $false
        $stderrClosed = $false
        $stdoutRead = $stdoutStream.ReadAsync($stdoutBuffer, 0, $stdoutBuffer.Length)
        $stderrRead = $stderrStream.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length)
        $deadline = if ($ProcessTimeoutSeconds -gt 0) { $startedAt.AddSeconds($ProcessTimeoutSeconds) } else { $null }
        while (-not ($process.HasExited -and $stdoutClosed -and $stderrClosed)) {
            if (-not $stdoutClosed -and $stdoutRead.IsCompleted) {
                $count = $stdoutRead.GetAwaiter().GetResult()
                if ($count -eq 0) { $stdoutClosed = $true }
                else {
                    $room = [int64]$OutputByteLimit - $durableWritten
                    if ($room -le 0) {
                        $overLimit = $true
                        $stdoutTruncated = $true
                    } else {
                        $writeCount = if ($count -gt $room) { [int]$room } else { $count }
                        $stdoutFile.Write($stdoutBuffer, 0, $writeCount)
                        if (($stdoutMemory.Length + $stderrMemory.Length + $writeCount) -le $OutputByteLimit) {
                            $stdoutMemory.Write($stdoutBuffer, 0, $writeCount)
                        }
                        $durableWritten += $writeCount
                        if ($writeCount -lt $count) {
                            $overLimit = $true
                            $stdoutTruncated = $true
                        }
                    }
                    $stdoutRead = $stdoutStream.ReadAsync($stdoutBuffer, 0, $stdoutBuffer.Length)
                }
            }
            if (-not $stderrClosed -and $stderrRead.IsCompleted) {
                $count = $stderrRead.GetAwaiter().GetResult()
                if ($count -eq 0) { $stderrClosed = $true }
                else {
                    $room = [int64]$OutputByteLimit - $durableWritten
                    if ($room -le 0) {
                        $overLimit = $true
                        $stderrTruncated = $true
                    } else {
                        $writeCount = if ($count -gt $room) { [int]$room } else { $count }
                        $stderrFile.Write($stderrBuffer, 0, $writeCount)
                        if (($stdoutMemory.Length + $stderrMemory.Length + $writeCount) -le $OutputByteLimit) {
                            $stderrMemory.Write($stderrBuffer, 0, $writeCount)
                        }
                        $durableWritten += $writeCount
                        if ($writeCount -lt $count) {
                            $overLimit = $true
                            $stderrTruncated = $true
                        }
                    }
                    $stderrRead = $stderrStream.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length)
                }
            }
            if ($null -ne $deadline -and [DateTimeOffset]::UtcNow -gt $deadline) {
                $timedOut = $true
                break
            }
            if (-not ($process.HasExited -and $stdoutClosed -and $stderrClosed)) { Start-Sleep -Milliseconds 20 }
        }
        if (-not $timedOut) { $process.WaitForExit() }
        $rootExited = $process.HasExited
        if ($rootExited) { $nativeExit = [int]$process.ExitCode }
    } catch {
        $runFailure = $_
        $failTypeName = $_.Exception.GetType().FullName
        if ($failTypeName -cmatch '(?i)IOException|IO\.IOException') { $processFailureClass = 'stream_io' }
        try { if ($processStarted -and $process.HasExited) { $nativeExit = [int]$process.ExitCode } } catch { }
    } finally {
        if ($null -ne $stdoutFile) { try { $stdoutFile.Flush(); $stdoutFile.Dispose() } catch { } }
        if ($null -ne $stderrFile) { try { $stderrFile.Flush(); $stderrFile.Dispose() } catch { } }
        $gate.Dispose()
        if ($processStarted -and -not $jobAssigned -and -not $process.HasExited) { try { $process.Kill() } catch { } }
        if ($jobHandle -ne [IntPtr]::Zero) {
            $jobClosed = [CursorAgentDispatch.NativeJob]::Close($jobHandle)
            $jobHandle = [IntPtr]::Zero
        }
        if ($processStarted -and -not $rootExited) {
            try { $rootExited = $process.WaitForExit(10000) -and $process.HasExited } catch { }
            if ($rootExited -and $null -eq $nativeExit) { try { $nativeExit = [int]$process.ExitCode } catch { } }
        }
    }

    $failMessage = $null
    $failType = ''
    if ($null -ne $runFailure) {
        $failMessage = [string]$runFailure.Exception.Message
        $failType = $runFailure.Exception.GetType().FullName
        if ([string]::IsNullOrWhiteSpace($processFailureClass) -and $failType -cmatch '(?i)IOException') {
            $processFailureClass = 'stream_io'
            $failMessage = 'Cursor CLI stream I/O failed.'
        }
    } elseif ($overLimit) {
        $failMessage = 'Cursor CLI output exceeded the bounded result size.'
        $failType = 'System.InvalidOperationException'
        $processFailureClass = 'output_limit'
    } elseif ($timedOut) {
        $failMessage = 'Cursor CLI startup or command probe exceeded its bounded window.'
        $failType = 'System.InvalidOperationException'
    } elseif (-not $jobClosed -or ($processStarted -and -not $rootExited)) {
        $failMessage = 'Cursor process-tree termination could not be confirmed. Further dispatch is blocked.'
        $failType = 'System.InvalidOperationException'
        $processFailureClass = 'termination_uncertain'
    }
    $stdoutPreview = ''
    try { $stdoutPreview = [Text.Encoding]::UTF8.GetString($stdoutMemory.ToArray()) } catch { }
    $observed = Get-DirectCursorObservedIdentity -Stdout $stdoutPreview -Workspace $WorkingDirectory
    $classification = if (-not [string]::IsNullOrWhiteSpace($failMessage)) {
        Get-DirectCursorFailureClassification -Message $failMessage -Stage $Stage -ExceptionType $failType -ProcessFailureClass $processFailureClass
    } else { $null }
    $diag = $null
    try {
        $diag = Write-DirectCursorProcessDiagnostic `
            -Directory $diagDir `
            -Stage $(if ($null -ne $classification) { [string]$classification.failure_stage } else { $Stage }) `
            -ExceptionType $failType `
            -ExceptionMessage $failMessage `
            -Classification $classification `
            -RequestedSessionId $RequestedSessionId `
            -ReturnedSessionId '' `
            -ObservedSessionId ([string]$observed.session_id) `
            -NativePid $nativePid `
            -NativeStartTicks $nativeTicks `
            -NativeExecutable $nativeExe `
            -NativeExitCode $nativeExit `
            -StdoutPath $stdoutPath `
            -StderrPath $stderrPath `
            -OutputByteLimit $OutputByteLimit `
            -MemoryStdoutBytes ([int]$stdoutMemory.Length) `
            -MemoryStderrBytes ([int]$stderrMemory.Length) `
            -ProcessTimeoutSeconds $ProcessTimeoutSeconds `
            -OverLimit $overLimit `
            -StdoutTruncated $stdoutTruncated `
            -StderrTruncated $stderrTruncated `
            -ProcessFailureClass $processFailureClass
    } catch {
        if ([string]::IsNullOrWhiteSpace($failMessage)) { throw }
    }

    if (-not [string]::IsNullOrWhiteSpace($failMessage)) {
        $ex = [InvalidOperationException]::new($failMessage)
        if ($null -ne $diag) {
            $ex.Data['telephone_direct_cursor_diagnostic_path'] = [string]$diag.path
            $ex.Data['telephone_direct_cursor_stdout_bytes'] = [int64]$diag.stdout_bytes
            $ex.Data['telephone_direct_cursor_stderr_bytes'] = [int64]$diag.stderr_bytes
        } else {
            $ex.Data['telephone_direct_cursor_stdout_bytes'] = [int64]$stdoutMemory.Length
            $ex.Data['telephone_direct_cursor_stderr_bytes'] = [int64]$stderrMemory.Length
        }
        $ex.Data['telephone_direct_cursor_exception_type'] = $failType
        $ex.Data['telephone_direct_cursor_process_failure_class'] = $processFailureClass
        $ex.Data['telephone_direct_cursor_observed_session_id'] = [string]$observed.session_id
        $ex.Data['telephone_direct_cursor_stdout_truncated'] = [bool]$stdoutTruncated
        $ex.Data['telephone_direct_cursor_stderr_truncated'] = [bool]$stderrTruncated
        if ($null -ne $nativeExit) { $ex.Data['telephone_direct_cursor_native_exit_code'] = [int]$nativeExit }
        throw $ex
    }
    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        Stdout = [Text.Encoding]::UTF8.GetString($stdoutMemory.ToArray())
        Stderr = [Text.Encoding]::UTF8.GetString($stderrMemory.ToArray())
        DurationMs = [int]([DateTimeOffset]::UtcNow - $startedAt).TotalMilliseconds
        Diagnostic = $diag
        StdoutBytes = [int64]$diag.stdout_bytes
        StderrBytes = [int64]$diag.stderr_bytes
        NativePid = $nativePid
        ObservedSessionId = [string]$observed.session_id
        StdoutTruncated = [bool]$stdoutTruncated
        StderrTruncated = [bool]$stderrTruncated
        ProcessFailureClass = $processFailureClass
    }
}

function Get-WorkspaceSnapshot {
    param([string]$Root, [string[]]$AllowedWriteRelative, [ref]$VolatileExclusions)
    return Get-DirectWorkspaceSnapshot -Root $Root -AllowedWriteRelative $AllowedWriteRelative -VolatileExclusions $VolatileExclusions
}

function Assert-NoReparsePoints {
    param([string]$Root)
    $reparse = Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($null -ne $reparse) { throw 'Workspace contains a reparse point and is not eligible for automated dispatch.' }
}

function Compare-WorkspaceSnapshot {
    param([hashtable]$Before, [hashtable]$After)
    return @(Compare-DirectWorkspaceSnapshot -Before $Before -After $After)
}

function Test-PathInside {
    param([string]$Candidate, [string]$Root)
    return $Candidate.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or
        $Candidate.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Read-Registry {
    if (-not (Test-Path -LiteralPath $registryPath)) {
        return [pscustomobject]@{ schema_version = 1; sessions = @() }
    }
    $parsed = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
    if ($parsed.schema_version -ne 1) { throw 'Cursor session registry schema is unsupported.' }
    return $parsed
}

function Write-Registry {
    param($Registry)
    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    $temporaryPath = $registryPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $json = $Registry | ConvertTo-Json -Depth 8
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.FileStream]::new($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    Move-Item -LiteralPath $temporaryPath -Destination $registryPath -Force
}

$promptIdentity = $null
$promptBytes = [byte[]]@()
$Prompt = ''
$promptSha256 = ('0' * 64)
if (-not $QualifiedProbe) {
    $promptIdentity = Get-Item -LiteralPath $PromptFile -Force -ErrorAction Stop
    if ($promptIdentity.PSIsContainer) { throw 'PromptFile must be a regular file.' }
    $promptBytes = [IO.File]::ReadAllBytes($promptIdentity.FullName)
    $Prompt = [Text.UTF8Encoding]::new($false, $true).GetString($promptBytes)
    $promptSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes)).ToLowerInvariant()
}
$requestedAllowedWritePaths = @(if ($null -ne $AllowedWritePath) { $AllowedWritePath })
$dispatchId = [Guid]::NewGuid().ToString('D')
$workspace = $null
$beforeSnapshot = $null
$changes = @()
$allowedWriteRelative = @()
$normalizedRequestSha256 = $null
$mutex = $null
$failureStage = 'input_validation'
$failureEvidence = $null
$run = $null
$volatileSnapshotExclusions = @()
$snapshotCompleted = $false
try {
    if (-not $QualifiedProbe -and [string]::IsNullOrWhiteSpace($Prompt)) { throw 'Prompt must not be empty.' }
    if ($AllowFast) { throw 'Direct Cursor Fast mode is disabled.' }
    if ($Model.EndsWith('-fast', [StringComparison]::OrdinalIgnoreCase)) { throw 'Direct Cursor Fast mode is disabled.' }
    if (-not $QualifiedProbe -and (Test-Path -LiteralPath $blockedPath -PathType Leaf)) { throw 'Cursor dispatch is blocked pending process inspection.' }

    $failureStage = 'route_qualification'
    $wrapperPresent = $false
    $wrapperMatch = $false
    $indexPresent = $false
    $indexMatch = $false
    $nodePresent = $false
    $nodeMatch = $false
    $jobHostPresent = $false
    $jobHostMatch = $false
    $install = $null
    try {
        $install = Resolve-CursorAgentInstall -RequestedRoot $CursorAgentRoot
        try {
            $null = Get-DirectFileIdentity -Path ([string]$install.wrapper)
            $wrapperPresent = $true
            $wrapperMatch = $true
        } catch {
            $wrapperPresent = [IO.File]::Exists([string]$install.wrapper)
        }
        try {
            $null = Get-DirectFileIdentity -Path ([string]$install.index)
            $indexPresent = $true
            $indexMatch = $true
        } catch {
            $indexPresent = [IO.File]::Exists([string]$install.index)
        }
        try {
            $null = Get-DirectFileIdentity -Path ([string]$install.node)
            $nodePresent = $true
            $nodeMatch = $true
        } catch {
            $nodePresent = [IO.File]::Exists([string]$install.node)
        }
    } catch { }
    try {
        $null = Get-DirectFileIdentity -Path $jobHost
        $jobHostPresent = $true
        $jobHostMatch = $true
    } catch {
        $jobHostPresent = $false
        $jobHostMatch = $false
    }

    $failureStage = 'workspace_validation'
    $workspaceReady = $false
    try {
        if ([IO.Directory]::Exists($WorkspacePath)) {
            $workspace = (Resolve-Path -LiteralPath $WorkspacePath -ErrorAction Stop).ProviderPath.TrimEnd('\')
            $workspaceItem = Get-Item -LiteralPath $workspace -Force
            if ($workspaceItem.PSIsContainer -and ($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                $workspaceReady = $true
            }
        }
    } catch { }

    if ($QualifiedProbe) {
        $cliVersionMatch = $false
        $accountBound = [string]::IsNullOrWhiteSpace($ExpectedAccount)
        $subscriptionBound = [string]::IsNullOrWhiteSpace($ExpectedSubscription)
        $modelAvailable = $false
        if ($workspaceReady -and $null -ne $install -and $indexPresent -and $nodePresent) {
            $probeTimeoutSeconds = 90
            try {
                $versionProbe = Invoke-CursorProcess -Arguments @('--version') -WorkingDirectory $workspace -NodePath ([string]$install.node) -IndexPath ([string]$install.index) -ProcessTimeoutSeconds $probeTimeoutSeconds
                $cliVersionMatch = ($versionProbe.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$versionProbe.Stdout))
            } catch { }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedAccount) -or -not [string]::IsNullOrWhiteSpace($ExpectedSubscription)) {
                try {
                    $aboutProbe = Invoke-CursorProcess -Arguments @('about') -WorkingDirectory $workspace -NodePath ([string]$install.node) -IndexPath ([string]$install.index) -ProcessTimeoutSeconds $probeTimeoutSeconds
                    if ($aboutProbe.ExitCode -eq 0) {
                        if (-not [string]::IsNullOrWhiteSpace($ExpectedAccount)) {
                            $emailMatch = [regex]::Match($aboutProbe.Stdout, '(?m)^User Email\s+([^\r\n]+)\r?$')
                            $accountBound = ($emailMatch.Success -and $emailMatch.Groups[1].Value.Trim() -cne '' -and $emailMatch.Groups[1].Value.Trim() -ceq $ExpectedAccount)
                        }
                        if (-not [string]::IsNullOrWhiteSpace($ExpectedSubscription)) {
                            $subscriptionMatch = [regex]::Match($aboutProbe.Stdout, '(?m)^Subscription Tier\s+([^\r\n]+)\r?$')
                            $subscriptionBound = ($subscriptionMatch.Success -and $subscriptionMatch.Groups[1].Value.Trim() -ceq $ExpectedSubscription)
                        }
                    } else {
                        if (-not [string]::IsNullOrWhiteSpace($ExpectedAccount)) { $accountBound = $false }
                        if (-not [string]::IsNullOrWhiteSpace($ExpectedSubscription)) { $subscriptionBound = $false }
                    }
                } catch {
                    if (-not [string]::IsNullOrWhiteSpace($ExpectedAccount)) { $accountBound = $false }
                    if (-not [string]::IsNullOrWhiteSpace($ExpectedSubscription)) { $subscriptionBound = $false }
                }
            }
            try {
                $modelsProbe = Invoke-CursorProcess -Arguments @('models') -WorkingDirectory $workspace -NodePath ([string]$install.node) -IndexPath ([string]$install.index) -ProcessTimeoutSeconds $probeTimeoutSeconds
                if ($modelsProbe.ExitCode -eq 0) {
                    $modelMatch = [regex]::Match($modelsProbe.Stdout, "(?m)^$([regex]::Escape($Model))\s+-\s+(.+?)\r?$")
                    $modelAvailable = $modelMatch.Success
                }
            } catch { }
        }
        [ordered]@{
            protocol_version = 'telephone-line-direct-cursor-qualified-probe-v1'
            wrapper_present = [bool]$wrapperPresent
            wrapper_identity_match = [bool]$wrapperMatch
            index_present = [bool]$indexPresent
            index_identity_match = [bool]$indexMatch
            node_present = [bool]$nodePresent
            node_identity_match = [bool]$nodeMatch
            job_host_present = [bool]$jobHostPresent
            job_host_identity_match = [bool]$jobHostMatch
            cli_version_match = [bool]$cliVersionMatch
            account_bound = [bool]$accountBound
            subscription_bound = [bool]$subscriptionBound
            model_available = [bool]$modelAvailable
        } | ConvertTo-Json -Depth 6
        exit 0
    }

    if (-not $jobHostPresent -or -not $jobHostMatch) { throw 'Cursor Job Object host is missing.' }
    if ($null -eq $install -or -not [IO.File]::Exists([string]$install.node) -or -not [IO.File]::Exists([string]$install.index)) {
        throw 'Cursor Agent CLI payload was not found.'
    }
    if (-not $workspaceReady) { throw 'WorkspacePath must be a directory.' }
    $workspace = Assert-DirectCursorWorkspaceDispatchable -WorkspacePath $workspace
    $authority = Resolve-DirectCursorModeAuthority -Mode $Mode -AllowWrite ([bool]$AllowWrite.IsPresent) -AllowedWritePath $AllowedWritePath -WorkspacePath $workspace
    $Mode = [string]$authority.mode
    $allowedWriteRelative = [string[]]@($authority.allowed_write_paths)
    if ($authority.requires_linked_worktree -and -not (Test-Path -LiteralPath (Join-Path $workspace '.git') -PathType Leaf)) {
        throw 'Automated Write mode requires a pre-created linked Git worktree (.git file).'
    }
    foreach ($rel in $allowedWriteRelative) {
        $declaredFull = [IO.Path]::GetFullPath((Join-Path $workspace $rel)).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $declaredFull)) { throw 'Declared write path does not exist.' }
        $declaredItem = Get-Item -LiteralPath $declaredFull -Force
        if (($declaredItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Declared write path is a reparse point.'
        }
    }
    if (Test-DirectWorkspaceReparse -Root $workspace) { throw 'Workspace contains a reparse point and is not eligible for automated dispatch.' }

    $failureStage = 'workspace_lock'
    $mutex = [Threading.Mutex]::new($false, (Get-DirectCursorWorkspaceMutexName -Workspace $workspace))
    if (-not $mutex.WaitOne(0)) { throw 'Another Cursor dispatch already owns this workspace.' }
    try {
        $failureStage = 'cli_qualification'
        $probeTimeoutSeconds = 90
        $versionProbe = Invoke-CursorProcess -Arguments @('--version') -WorkingDirectory $workspace -NodePath ([string]$install.node) -IndexPath ([string]$install.index) -ProcessTimeoutSeconds $probeTimeoutSeconds -DiagnosticRoot $stateRoot -DispatchId $dispatchId -RequestedSessionId $ResumeSessionId -Stage 'cli_qualification'
        if ($versionProbe.ExitCode -ne 0) {
            $probeEx = [InvalidOperationException]::new('Cursor CLI version probe failed.')
            if ($null -ne $versionProbe.Diagnostic) {
                $probeEx.Data['telephone_direct_cursor_diagnostic_path'] = [string]$versionProbe.Diagnostic.path
                $probeEx.Data['telephone_direct_cursor_stdout_bytes'] = [int64]$versionProbe.StdoutBytes
                $probeEx.Data['telephone_direct_cursor_stderr_bytes'] = [int64]$versionProbe.StderrBytes
                $probeEx.Data['telephone_direct_cursor_native_exit_code'] = [int]$versionProbe.ExitCode
            }
            throw $probeEx
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedAccount) -or -not [string]::IsNullOrWhiteSpace($ExpectedSubscription)) {
            $aboutProbe = Invoke-CursorProcess -Arguments @('about') -WorkingDirectory $workspace -NodePath ([string]$install.node) -IndexPath ([string]$install.index) -ProcessTimeoutSeconds $probeTimeoutSeconds
            if ($aboutProbe.ExitCode -ne 0) { throw 'Cursor account identity could not be read.' }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedAccount)) {
                $emailMatch = [regex]::Match($aboutProbe.Stdout, '(?m)^User Email\s+([^\r\n]+)\r?$')
                if (-not $emailMatch.Success -or $emailMatch.Groups[1].Value.Trim() -cne $ExpectedAccount) {
                    throw 'Cursor login does not match the caller-supplied expected identity.'
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedSubscription)) {
                $subscriptionMatch = [regex]::Match($aboutProbe.Stdout, '(?m)^Subscription Tier\s+([^\r\n]+)\r?$')
                if (-not $subscriptionMatch.Success -or $subscriptionMatch.Groups[1].Value.Trim() -cne $ExpectedSubscription) {
                    throw 'Cursor subscription does not match the caller-supplied expected identity.'
                }
            }
        }
        $modelsProbe = Invoke-CursorProcess -Arguments @('models') -WorkingDirectory $workspace -NodePath ([string]$install.node) -IndexPath ([string]$install.index) -ProcessTimeoutSeconds $probeTimeoutSeconds -DiagnosticRoot $stateRoot -DispatchId $dispatchId -RequestedSessionId $ResumeSessionId -Stage 'cli_qualification'
        if ($modelsProbe.ExitCode -ne 0) {
            $probeEx = [InvalidOperationException]::new('Cursor model catalog probe failed.')
            if ($null -ne $modelsProbe.Diagnostic) {
                $probeEx.Data['telephone_direct_cursor_diagnostic_path'] = [string]$modelsProbe.Diagnostic.path
                $probeEx.Data['telephone_direct_cursor_stdout_bytes'] = [int64]$modelsProbe.StdoutBytes
                $probeEx.Data['telephone_direct_cursor_stderr_bytes'] = [int64]$modelsProbe.StderrBytes
                $probeEx.Data['telephone_direct_cursor_native_exit_code'] = [int]$modelsProbe.ExitCode
            }
            throw $probeEx
        }
        $modelMatch = [regex]::Match($modelsProbe.Stdout, "(?m)^$([regex]::Escape($Model))\s+-\s+(.+?)\r?$")
        if (-not $modelMatch.Success) { throw 'Requested Cursor model is not available.' }
        $expectedModelDisplay = ConvertTo-StableCursorModelDisplay -Display $modelMatch.Groups[1].Value

        $failureStage = 'session_binding'
        $registryReadMutex = [Threading.Mutex]::new($false, 'Global\TelephoneLineCursorSessionRegistry')
        if (-not $registryReadMutex.WaitOne(30000)) { throw 'Cursor session registry is busy.' }
        try { $registry = Read-Registry } finally {
            try { $registryReadMutex.ReleaseMutex() } catch { }
            $registryReadMutex.Dispose()
        }
        if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) {
            $records = @($registry.sessions | Where-Object { $_.session_id -eq $ResumeSessionId })
            if ($records.Count -ne 1) { throw 'Resume session is not registered by this wrapper.' }
            Assert-DirectCursorResumeBinding -Record $records[0] -Model $Model -Workspace $workspace -Mode $Mode -AllowedWriteRelative $allowedWriteRelative -ExpectedAccount $ExpectedAccount -ExpectedSubscription $ExpectedSubscription
        }

        $resumeBinding = if ([string]::IsNullOrWhiteSpace($ResumeSessionId)) { '<new>' } else { $ResumeSessionId }
        $requestMaterial = @($dispatchId, $Model, $workspace, $Mode, ($allowedWriteRelative -join '|'), $resumeBinding, $promptSha256) -join "`n"
        $normalizedRequestSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($requestMaterial))).ToLowerInvariant()
        $beforeExclusions = @()
        $beforeSnapshot = Get-WorkspaceSnapshot -Root $workspace -AllowedWriteRelative $allowedWriteRelative -VolatileExclusions ([ref]$beforeExclusions)
        $arguments = @('-p', '--output-format', 'stream-json', '--sandbox', 'disabled', '--trust', '--workspace', $workspace, '--model', $Model)
        $arguments += @(Get-DirectCursorCliInvocationArgs -Authority $authority)
        if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) { $arguments += @('--resume', $ResumeSessionId) }
        $arguments += @('--', $Prompt)

        $failureStage = 'cursor_execution'
        $run = Invoke-CursorProcess -Arguments $arguments -WorkingDirectory $workspace -NodePath ([string]$install.node) -IndexPath ([string]$install.index) -ProcessTimeoutSeconds $TimeoutSeconds -OutputByteLimit $MaxOutputBytes -DiagnosticRoot $stateRoot -DispatchId $dispatchId -RequestedSessionId $ResumeSessionId -Stage $failureStage
        $failureStage = 'post_execution_reparse'
        if (Test-DirectWorkspaceReparse -Root $workspace) { throw 'Workspace contains a reparse point and is not eligible for automated dispatch.' }
        $failureStage = 'post_execution_snapshot'
        $afterExclusions = @()
        $afterSnapshot = Get-WorkspaceSnapshot -Root $workspace -AllowedWriteRelative $allowedWriteRelative -VolatileExclusions ([ref]$afterExclusions)
        $failureStage = 'post_execution_exclusion'
        $beforeExclusionKey = @($beforeExclusions | ForEach-Object { [string]$_.path } | Sort-Object) -join "`n"
        $afterExclusionKey = @($afterExclusions | ForEach-Object { [string]$_.path } | Sort-Object) -join "`n"
        if ($beforeExclusionKey -cne $afterExclusionKey) { throw 'Runtime volatile exclusion set changed during dispatch.' }
        $volatileSnapshotExclusions = @($beforeExclusions)
        $changes = @(Compare-WorkspaceSnapshot -Before $beforeSnapshot -After $afterSnapshot)
        $snapshotCompleted = $true
        $failureStage = 'terminal_validation'
        $completed = Complete-DirectCursorAgentRun `
            -Mode $Mode `
            -Workspace $workspace `
            -AllowedWriteRelative $allowedWriteRelative `
            -Run $run `
            -Changes $changes `
            -Model $Model `
            -DispatchId $dispatchId `
            -PromptSha256 $promptSha256 `
            -ExpectedModelDisplay $expectedModelDisplay `
            -ResumeSessionId $ResumeSessionId
        if ([string](Get-DirectNoteValue -Object $completed -Name 'outcome') -ceq 'cursor_failure') {
            $failureEvidence = Get-DirectNoteValue -Object $completed -Name 'evidence'
            $errorMessage = [string](Get-DirectNoteValue -Object $completed -Name 'error_message')
            if ($errorMessage -cmatch '(?i)Cursor CLI exited|Cursor CLI wrote to stderr') { $failureStage = 'cursor_execution' }
            $failEx = [InvalidOperationException]::new($errorMessage)
            $runDiag = Get-DirectNoteValue -Object $run -Name 'Diagnostic'
            $runDiagPath = [string](Get-DirectNoteValue -Object $runDiag -Name 'path')
            if (-not [string]::IsNullOrWhiteSpace($runDiagPath)) {
                $failEx.Data['telephone_direct_cursor_diagnostic_path'] = $runDiagPath
            }
            $runStdoutBytes = Get-DirectNoteValue -Object $run -Name 'StdoutBytes'
            $runStderrBytes = Get-DirectNoteValue -Object $run -Name 'StderrBytes'
            $runExit = Get-DirectNoteValue -Object $run -Name 'ExitCode'
            if ($null -ne $runStdoutBytes) { $failEx.Data['telephone_direct_cursor_stdout_bytes'] = [int64]$runStdoutBytes }
            if ($null -ne $runStderrBytes) { $failEx.Data['telephone_direct_cursor_stderr_bytes'] = [int64]$runStderrBytes }
            if ($null -ne $runExit -and [string]$runExit -ne '') { $failEx.Data['telephone_direct_cursor_native_exit_code'] = [int]$runExit }
            $completedViolating = @(Get-DirectNoteValue -Object $completed -Name 'violating_paths')
            if ($completedViolating.Count -gt 0) {
                $failEx.Data['telephone_direct_cursor_violating_paths'] = @($completedViolating)
            }
            throw $failEx
        }

        if ($true -eq (Get-DirectNoteValue -Object $completed -Name 'register_session')) {
            $failureStage = 'session_registry'
            $sessionId = [string](Get-DirectNoteValue -Object (Get-DirectNoteValue -Object $completed -Name 'result') -Name 'session_id')
            $now = [DateTimeOffset]::UtcNow.ToString('o')
            $registryMutex = [Threading.Mutex]::new($false, 'Global\TelephoneLineCursorSessionRegistry')
            if (-not $registryMutex.WaitOne(30000)) { throw 'Cursor session registry is busy.' }
            try {
                $latestRegistry = Read-Registry
                if ([string]::IsNullOrWhiteSpace($ResumeSessionId)) {
                    if (@($latestRegistry.sessions | Where-Object { $_.session_id -eq $sessionId }).Count -ne 0) {
                        throw 'Cursor returned a session ID already owned by the registry.'
                    }
                    $newRecord = [pscustomobject]@{
                        session_id = $sessionId
                        model_id = $Model
                        workspace = $workspace
                        mode = $Mode
                        allowed_write_paths = $allowedWriteRelative
                        last_dispatch_id = $dispatchId
                        last_normalized_request_sha256 = $normalizedRequestSha256
                        created_at = $now
                        last_used_at = $now
                    }
                    $latestRegistry.sessions = @($latestRegistry.sessions) + $newRecord
                } else {
                    $latestRecords = @($latestRegistry.sessions | Where-Object { $_.session_id -eq $ResumeSessionId })
                    if ($latestRecords.Count -ne 1) { throw 'Resume session disappeared from the registry.' }
                    $latestRecords[0].last_dispatch_id = $dispatchId
                    $latestRecords[0].last_normalized_request_sha256 = $normalizedRequestSha256
                    $latestRecords[0].last_used_at = $now
                }
                Write-Registry -Registry $latestRegistry
            } finally {
                try { $registryMutex.ReleaseMutex() } catch { }
                $registryMutex.Dispose()
            }
        }

        $failureStage = 'result_projection'
        $summary = Get-DirectNoteValue -Object $completed -Name 'result'
        if ($null -eq $summary) { throw 'Cursor result is missing.' }
        $summary.volatile_snapshot_exclusions = @($volatileSnapshotExclusions)
        $summary.changed_files_availability = 'available'
        $summary.prompt = [ordered]@{ path = [string]$promptIdentity.FullName; bytes = [int64]$promptBytes.Length; sha256 = $promptSha256 }
        $summary | ConvertTo-Json -Depth 10
    } finally {
        if ($null -ne $mutex) {
            try { $mutex.ReleaseMutex() } catch { }
            $mutex.Dispose()
            $mutex = $null
        }
    }
} catch {
    $payload = New-DirectCursorCaughtFailureResult `
        -ErrorRecord $_ `
        -FailureStage $failureStage `
        -DispatchId $dispatchId `
        -PromptSha256 $promptSha256 `
        -PromptIdentity $promptIdentity `
        -PromptBytes $promptBytes `
        -FailureEvidence $failureEvidence `
        -Run $run `
        -ResumeSessionId $ResumeSessionId `
        -StateRoot $stateRoot `
        -Workspace $workspace `
        -Mode $Mode `
        -Model $Model `
        -AllowedWriteRelative $allowedWriteRelative `
        -BeforeSnapshot $beforeSnapshot `
        -SnapshotCompleted $snapshotCompleted `
        -ExistingChanges $changes `
        -VolatileSnapshotExclusions $volatileSnapshotExclusions
    $payload | ConvertTo-Json -Depth 8
    exit 1
}
