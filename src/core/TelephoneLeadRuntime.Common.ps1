# SPDX-License-Identifier: MPL-2.0
# Generic Lead CLI/runtime helpers for stable executable diagnosis, concurrent
# stream drain, and audited wake reconcile. Does not glob App version directories,
# switch accounts/models, or rewrite frozen dispatch bytes.

Set-StrictMode -Version Latest

$script:TelephoneLeadOpenDrains = [ordered]@{}
$script:TelephoneLeadOpenDrainGate = [object]::new()

if (-not ('TelephoneLeadOwnedReaderCompletion' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

public static class TelephoneLeadOwnedReaderCompletion {
    public static Task Attach(
        System.Diagnostics.Process process,
        Task stdoutTask,
        Task stderrTask,
        string handoffPath,
        string lifecyclePath,
        int pid,
        long ticks,
        string startedAt,
        string exe,
        string sessionId,
        string runId,
        string role,
        int ownerPid,
        long ownerTicks,
        string ownerExe,
        Stream stdoutTarget,
        Stream stderrTarget) {
        if (process == null || stdoutTask == null || stderrTask == null) return Task.CompletedTask;
        if (string.IsNullOrWhiteSpace(handoffPath)) return Task.CompletedTask;
        Task<int?> exited = ProcessExited(process);
        return Task.WhenAll(stdoutTask, stderrTask, exited).ContinueWith(delegate(Task antecedent) {
            try {
                if (antecedent.IsFaulted || antecedent.IsCanceled) return;
                FlushTarget(stdoutTarget);
                FlushTarget(stderrTarget);
                Publish(exited.Result, stdoutTask, stderrTask, handoffPath, lifecyclePath, pid, ticks, startedAt, exe, sessionId, runId, role, ownerPid, ownerTicks, ownerExe);
            } catch {
            }
        });
    }

    static void FlushTarget(Stream target) {
        if (target is FileStream file) file.Flush(true);
        else if (target != null) target.Flush();
    }

    static int? ReadExitCode(System.Diagnostics.Process process) {
        try { return process.ExitCode; } catch { return null; }
    }

    static Task<int?> ProcessExited(System.Diagnostics.Process process) {
        var done = new TaskCompletionSource<int?>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (process.HasExited) {
            done.TrySetResult(ReadExitCode(process));
            return done.Task;
        }
        process.EnableRaisingEvents = true;
        process.Exited += delegate {
            done.TrySetResult(ReadExitCode(process));
        };
        if (process.HasExited) {
            done.TrySetResult(ReadExitCode(process));
        }
        return done.Task;
    }

    static void Publish(
        int? exitCode,
        Task stdoutTask,
        Task stderrTask,
        string handoffPath,
        string lifecyclePath,
        int pid,
        long ticks,
        string startedAt,
        string exe,
        string sessionId,
        string runId,
        string role,
        int ownerPid,
        long ownerTicks,
        string ownerExe) {
        if (stdoutTask == null || stderrTask == null) return;
        if (stdoutTask.Status != TaskStatus.RanToCompletion) return;
        if (stderrTask.Status != TaskStatus.RanToCompletion) return;
        string exitJson = exitCode.HasValue ? exitCode.Value.ToString(System.Globalization.CultureInfo.InvariantCulture) : "null";
        string exitObserved = exitCode.HasValue ? "true" : "false";
        string recorded = DateTimeOffset.UtcNow.ToString("o");
        string handoff = "{"
            + "\"protocol_version\":\"telephone-line-drain-handoff-v1\","
            + "\"owner_pid\":" + ownerPid.ToString(System.Globalization.CultureInfo.InvariantCulture) + ","
            + "\"owner_start_time_utc_ticks\":" + ownerTicks.ToString(System.Globalization.CultureInfo.InvariantCulture) + ","
            + "\"owner_executable_path\":\"" + Escape(ownerExe) + "\","
            + "\"target_pid\":" + pid.ToString(System.Globalization.CultureInfo.InvariantCulture) + ","
            + "\"pid\":" + pid.ToString(System.Globalization.CultureInfo.InvariantCulture) + ","
            + "\"start_time_utc_ticks\":" + ticks.ToString(System.Globalization.CultureInfo.InvariantCulture) + ","
            + "\"executable_path\":\"" + Escape(exe) + "\","
            + "\"session_id\":\"" + Escape(sessionId) + "\","
            + "\"run_id\":\"" + Escape(runId) + "\","
            + "\"role\":\"" + Escape(role) + "\","
            + "\"pending\":" + (exitCode.HasValue ? "false" : "true") + ","
            + "\"process_exited\":true,"
            + "\"exit_code\":" + exitJson + ","
            + "\"exit_code_observed\":" + exitObserved + ","
            + "\"stdout_eof\":true,"
            + "\"stderr_eof\":true,"
            + "\"recorded_by\":\"owner_reader_completion\","
            + "\"recorded_at_utc\":\"" + Escape(recorded) + "\""
            + "}\n";
        File.WriteAllText(handoffPath, handoff, new UTF8Encoding(false));
        if (!string.IsNullOrWhiteSpace(lifecyclePath)) {
            string life = "{"
                + "\"protocol_version\":\"telephone-line-drained-process-v1\","
                + "\"pid\":" + pid.ToString(System.Globalization.CultureInfo.InvariantCulture) + ","
                + "\"start_time_utc_ticks\":" + ticks.ToString(System.Globalization.CultureInfo.InvariantCulture) + ","
                + "\"started_at_utc\":\"" + Escape(startedAt) + "\","
                + "\"executable_path\":\"" + Escape(exe) + "\","
                + "\"process_exited\":true,"
                + "\"stdout_eof\":true,"
                + "\"stderr_eof\":true,"
                + "\"timed_out\":false,"
                + "\"native_turn_complete\":true,"
                + "\"recorded_at_utc\":\"" + Escape(recorded) + "\","
                + "\"exit_code\":" + exitJson + ","
                + "\"exit_code_observed\":" + exitObserved + ","
                + "\"role\":\"" + Escape(role) + "\","
                + "\"session_id\":\"" + Escape(sessionId) + "\","
                + "\"run_id\":\"" + Escape(runId) + "\""
                + "}\n";
            File.WriteAllText(lifecyclePath, life, new UTF8Encoding(false));
        }
    }

    static string Escape(string value) {
        if (string.IsNullOrEmpty(value)) return "";
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }
}
'@
}

function Get-TelephoneLeadNamedArgumentValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $named = ConvertTo-TelephoneFrozenLauncherNamedArguments -Arguments $Arguments
    if (-not $named.ContainsKey($Name)) { return '' }
    return [string]$named[$Name]
}

function Get-TelephoneLeadStableCliPolicy {
    [CmdletBinding()]
    param([string]$PolicyPath = '')

    $path = [string]$PolicyPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = [string]$env:TELEPHONE_LINE_STABLE_CLI_POLICY
    }
    if ([string]::IsNullOrWhiteSpace($path) -and -not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_INSTALL_ROOT)) {
        $path = Join-Path ([IO.Path]::GetFullPath([string]$env:TELEPHONE_LINE_INSTALL_ROOT).TrimEnd('\')) 'stable-cli-policy.json'
    }
    $record = [ordered]@{
        protocol_version = 'telephone-line-stable-cli-policy-v1'
        present = $false
        path = $path
        executable = [string]$env:TELEPHONE_LINE_STABLE_CLI
        sha256 = ''
        version = ''
    }
    if ([string]::IsNullOrWhiteSpace($record.executable) -eq $false) {
        $record.executable = [IO.Path]::GetFullPath($record.executable)
    }
    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.File]::Exists($path)) {
        return $record
    }
    $doc = (Read-TelephoneJson -Path $path).value
    if ($doc -isnot [Collections.IDictionary]) { return $record }
    $record.present = $true
    if ([string]::IsNullOrWhiteSpace($record.executable) -and $doc.Contains('executable')) {
        $record.executable = [IO.Path]::GetFullPath([string]$doc.executable)
    }
    if ($doc.Contains('sha256')) { $record.sha256 = [string]$doc.sha256 }
    if ($doc.Contains('version')) { $record.version = [string]$doc.version }
    return $record
}

function Get-TelephoneLeadProcessObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $proc = $null
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
        $started = $proc.StartTime.ToUniversalTime().ToString('o')
        $exe = ''
        try { $exe = [string]$proc.MainModule.FileName } catch { $exe = '' }
        if ([string]::IsNullOrWhiteSpace($exe)) {
            try { $exe = [string]$proc.Path } catch { $exe = '' }
        }
        $parent = 0
        try {
            $cim = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = " + $ProcessId) -ErrorAction Stop
            if ($null -ne $cim) {
                $parent = [int]$cim.ParentProcessId
                if ([string]::IsNullOrWhiteSpace($exe) -and -not [string]::IsNullOrWhiteSpace([string]$cim.ExecutablePath)) {
                    $exe = [string]$cim.ExecutablePath
                }
            }
        } catch { }
        return [ordered]@{
            status = 'alive'
            error = ''
            snapshot = [ordered]@{
                pid = [int]$ProcessId
                start_time_utc_ticks = $ticks
                started_at_utc = $started
                executable_path = $exe
                parent_process_id = $parent
            }
        }
    } catch {
        $notFound = $false
        try {
            if ($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound) { $notFound = $true }
        } catch { }
        if (-not $notFound) {
            $msg = [string]$_.Exception.Message
            if ($msg -match '(?i)cannot find a process|no process found|cannot find process') { $notFound = $true }
        }
        if ($notFound) {
            return [ordered]@{ status = 'not_found'; snapshot = $null; error = [string]$_.Exception.Message }
        }
        return [ordered]@{ status = 'query_error'; snapshot = $null; error = [string]$_.Exception.Message }
    } finally {
        if ($null -ne $proc) { try { $proc.Dispose() } catch { } }
    }
}

function Get-TelephoneLeadProcessSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $obs = Get-TelephoneLeadProcessObservation -ProcessId $ProcessId
    if ([string]$obs.status -ceq 'alive' -and $null -ne $obs.snapshot) { return $obs.snapshot }
    return $null
}

function ConvertTo-TelephoneLeadProducerIdentity {
    [CmdletBinding()]
    param([AllowNull()][object]$Doc)
    if ($null -eq $Doc -or $Doc -isnot [Collections.IDictionary]) { return $null }
    $ownedPid = 0
    $ticks = [int64]0
    $exe = ''
    try {
        if ($Doc.Contains('pid')) { $ownedPid = [int]$Doc['pid'] }
        elseif ($Doc.Contains('target_pid')) { $ownedPid = [int]$Doc['target_pid'] }
        if ($Doc.Contains('start_time_utc_ticks')) { $ticks = [int64]$Doc['start_time_utc_ticks'] }
        if ($Doc.Contains('executable_path')) { $exe = [string]$Doc['executable_path'] }
    } catch {
        return $null
    }
    if ($ownedPid -le 0 -or $ticks -le 0) { return $null }
    return [ordered]@{
        pid = [int]$ownedPid
        start_time_utc_ticks = [int64]$ticks
        executable_path = [string]$exe
    }
}

function Test-TelephoneLeadProcessIdentityMatch {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Actual
    )
    $left = ConvertTo-TelephoneLeadProducerIdentity -Doc $Expected
    $right = ConvertTo-TelephoneLeadProducerIdentity -Doc $Actual
    if ($null -eq $left -or $null -eq $right) { return $false }
    if ([int]$left.pid -ne [int]$right.pid) { return $false }
    if ([int64]$left.start_time_utc_ticks -ne [int64]$right.start_time_utc_ticks) { return $false }
    $expectedExe = [string]$left.executable_path
    $actualExe = [string]$right.executable_path
    if (-not [string]::IsNullOrWhiteSpace($expectedExe) -and -not [string]::IsNullOrWhiteSpace($actualExe)) {
        try {
            $expectedFull = [IO.Path]::GetFullPath($expectedExe)
            $actualFull = [IO.Path]::GetFullPath($actualExe)
            if (-not $expectedFull.Equals($actualFull, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        } catch {
            if (-not [string]::Equals($expectedExe, $actualExe, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
    }
    return $true
}

function Test-TelephoneLeadDrainMatchesExpectedProducer {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Doc,
        [AllowNull()][object]$ExpectedIdentity,
        [string]$SessionId = '',
        [string]$RunId = ''
    )
    if (-not (Test-TelephoneLeadDrainIdentityComplete -Doc $Doc -SessionId $SessionId -RunId $RunId)) { return $false }
    if ($null -eq $ExpectedIdentity) { return $false }
    return (Test-TelephoneLeadProcessIdentityMatch -Expected $ExpectedIdentity -Actual $Doc)
}

function Test-TelephoneLeadDrainMatchesIndependentProducer {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Doc,
        [AllowNull()][object]$ExpectedIdentity,
        [string]$SessionId = '',
        [string]$RunId = '',
        [string]$ExpectedRole = ''
    )
    if ($null -eq $ExpectedIdentity) { return $false }
    if (-not (Test-TelephoneLeadDrainMatchesExpectedProducer -Doc $Doc -ExpectedIdentity $ExpectedIdentity -SessionId $SessionId -RunId $RunId)) { return $false }
    $role = ''
    try {
        if ($Doc.Contains('role')) { $role = [string]$Doc['role'] }
    } catch {
        $role = ''
    }
    if (-not [string]::IsNullOrWhiteSpace($role) -and -not [string]::IsNullOrWhiteSpace($ExpectedRole) -and $role -cne $ExpectedRole) {
        return $false
    }
    return $true
}

function Get-TelephoneLeadOwnerIdentityObservation {
    [CmdletBinding()]
    param([AllowNull()][object]$Owner)
    if ($null -eq $Owner -or $Owner -isnot [Collections.IDictionary]) {
        return [ordered]@{ status = 'missing'; snapshot = $null; error = 'missing_owner' }
    }
    $ownedPid = 0
    try { if ($Owner.Contains('pid')) { $ownedPid = [int]$Owner['pid'] } elseif ($Owner.Contains('target_pid')) { $ownedPid = [int]$Owner['target_pid'] } } catch { $ownedPid = 0 }
    if ($ownedPid -le 0) { return [ordered]@{ status = 'missing'; snapshot = $null; error = 'missing_pid' } }
    $obs = Get-TelephoneLeadProcessObservation -ProcessId $ownedPid
    if ([string]$obs.status -ceq 'query_error') { return $obs }
    if ([string]$obs.status -ceq 'not_found') { return $obs }
    $expected = [ordered]@{
        pid = $ownedPid
        start_time_utc_ticks = $(if ($Owner.Contains('start_time_utc_ticks')) { [int64]$Owner['start_time_utc_ticks'] } else { [int64]0 })
        executable_path = $(if ($Owner.Contains('executable_path')) { [string]$Owner['executable_path'] } else { '' })
    }
    if ($null -eq $obs.snapshot -or -not (Test-TelephoneLeadProcessIdentityMatch -Expected $expected -Actual $obs.snapshot)) {
        return [ordered]@{ status = 'mismatch'; snapshot = $obs.snapshot; error = 'pid_reuse_or_exe_mismatch' }
    }
    return $obs
}

function Test-TelephoneLeadOwnerIdentityAlive {
    [CmdletBinding()]
    param([AllowNull()][object]$Owner)
    $obs = Get-TelephoneLeadOwnerIdentityObservation -Owner $Owner
    return ([string]$obs.status -ceq 'alive')
}

function Test-TelephoneLeadSharedCodexAppExecutable {
    [CmdletBinding()]
    param([string]$Path = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = [string]$Path
    try { $full = [IO.Path]::GetFullPath($Path) } catch { $full = [string]$Path }
    if ($full.IndexOf('\Packages\OpenAI.Codex', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    if ($full.IndexOf('\WindowsApps\OpenAI.Codex', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    return $false
}

function Test-TelephoneLeadWindowsConsoleHostExecutable {
    [CmdletBinding()]
    param([string]$Path = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $name = ''
    try { $name = [IO.Path]::GetFileName($Path) } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    if ($name -ine 'conhost.exe' -and $name -ine 'openconsole.exe') { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $windows = [IO.Path]::GetFullPath($env:WINDIR).TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($windows)) { $windows = 'C:\Windows' }
        # Only the OS console infrastructure is exempt, never an arbitrary
        # executable with that name elsewhere under the Windows directory.
        foreach ($directory in @('System32', 'SysWOW64')) {
            $trusted = [IO.Path]::Combine($windows, $directory, $name)
            if ($full.Equals($trusted, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    } catch {
        return $false
    }
}

function Get-TelephoneLeadOwnedDescendantObservation {
    [CmdletBinding()]
    param([AllowNull()][object]$Identity)
    $result = [ordered]@{
        protocol_version = 'telephone-line-owned-descendant-observation-v1'
        status = 'none'
        refused = ''
        parent_pid = 0
        children = [Collections.Generic.List[object]]::new()
        error = ''
    }
    if ($null -eq $Identity -or $Identity -isnot [Collections.IDictionary]) {
        $result.status = 'missing_identity'
        $result.refused = 'missing_identity'
        return $result
    }
    $ownedPid = 0
    try {
        if ($Identity.Contains('pid')) { $ownedPid = [int]$Identity['pid'] }
        elseif ($Identity.Contains('target_pid')) { $ownedPid = [int]$Identity['target_pid'] }
    } catch { $ownedPid = 0 }
    if ($ownedPid -le 0) {
        $result.status = 'missing_identity'
        $result.refused = 'missing_identity'
        return $result
    }
    $result.parent_pid = $ownedPid
    $rows = $null
    try {
        $rows = @(Get-CimInstance -ClassName Win32_Process -Filter ('ParentProcessId = {0}' -f $ownedPid) -ErrorAction Stop)
    } catch {
        $result.status = 'query_error'
        $result.refused = 'descendant_query_error'
        $result.error = [string]$_.Exception.Message
        return $result
    }
    foreach ($row in @($rows)) {
        if ($null -eq $row) { continue }
        $childPid = 0
        try { $childPid = [int]$row.ProcessId } catch { continue }
        if ($childPid -le 0 -or $childPid -eq $ownedPid) { continue }
        $obs = Get-TelephoneLeadProcessObservation -ProcessId $childPid
        if ([string]$obs.status -ceq 'query_error') {
            $result.status = 'query_error'
            $result.refused = 'descendant_query_error'
            $result.error = [string]$obs.error
            return $result
        }
        if ([string]$obs.status -cne 'alive' -or $null -eq $obs.snapshot) { continue }
        $exePath = ''
        try {
            if ($obs.snapshot -is [Collections.IDictionary] -and $obs.snapshot.Contains('executable_path')) {
                $exePath = [string]$obs.snapshot['executable_path']
            }
        } catch { $exePath = '' }
        if (Test-TelephoneLeadWindowsConsoleHostExecutable -Path $exePath) { continue }
        $parentNow = 0
        try {
            if ($obs.snapshot -is [Collections.IDictionary] -and $obs.snapshot.Contains('parent_process_id')) {
                $parentNow = [int]$obs.snapshot['parent_process_id']
            }
        } catch { $parentNow = 0 }
        if ($parentNow -le 0) {
            $result.status = 'query_error'
            $result.refused = 'descendant_query_error'
            $result.error = 'A live enumerated descendant has no independently readable parent identity.'
            return $result
        }
        if ($parentNow -ne $ownedPid) { continue }
        [void]$result.children.Add($obs.snapshot)
    }
    if ($result.children.Count -gt 0) {
        $result.status = 'active_descendant'
        $result.refused = 'active_descendant'
    }
    return $result
}

function ConvertTo-TelephonePersistableRecord {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            $copy[[string]$key] = ConvertTo-TelephonePersistableRecord -Value $Value[$key]
        }
        return $copy
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in @($Value)) { [void]$items.Add((ConvertTo-TelephonePersistableRecord -Value $item)) }
        return ,([object[]]$items.ToArray())
    }
    return $Value
}

function Write-TelephoneLeadOwnedRecoveryRecord {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$RunRoot,
        [Parameter(Mandatory = $true)][object]$Record
    )
    if ([string]::IsNullOrWhiteSpace($RunRoot) -or -not [IO.Directory]::Exists($RunRoot)) { return }
    $path = Join-Path ([IO.Path]::GetFullPath($RunRoot).TrimEnd('\')) 'owned-residue-recovery.json'
    $payload = ConvertTo-TelephonePersistableRecord -Value $Record
    try {
        if ([IO.File]::Exists($path)) { $null = Write-TelephoneJsonReplace -Path $path -Value $payload }
        else { $null = Write-TelephoneJsonCreateNew -Path $path -Value $payload }
    } catch {
        try { $null = Write-TelephoneJsonReplace -Path $path -Value $payload } catch { }
    }
}

function New-TelephoneLeadCliDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$Executable = '',
        [string]$ErrorCode = '',
        [string]$Win32Error = '',
        [bool]$PathExists = $false,
        [bool]$CreateProcessOk = $false,
        [int]$ExitCode = -1,
        [string]$VersionText = '',
        [string]$Reconcile = '',
        [string]$FrozenExecutable = '',
        [string]$ConfiguredExecutable = ''
    )
    return [ordered]@{
        protocol_version = 'telephone-line-cli-diagnostic-v1'
        stage = $Stage
        executable = $Executable
        frozen_executable = $FrozenExecutable
        configured_executable = $ConfiguredExecutable
        path_exists = [bool]$PathExists
        create_process_ok = [bool]$CreateProcessOk
        win32_error = $Win32Error
        exit_code = [int]$ExitCode
        version_text = $VersionText
        error_code = $ErrorCode
        reconcile = $Reconcile
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Invoke-TelephoneLeadCreateProcessProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$Arguments = @('--version'),
        [int]$TimeoutMilliseconds = 20000
    )
    $full = $Executable
    try { $full = [IO.Path]::GetFullPath($Executable) } catch { $full = $Executable }
    $exists = [IO.File]::Exists($full)
    $diag = New-TelephoneLeadCliDiagnostic -Stage 'path' -Executable $full -PathExists $exists
    if (-not $exists) {
        $diag.stage = 'path'
        $diag.error_code = 'LEAD_CLI_UNLAUNCHABLE'
        $diag.win32_error = 'path_missing'
        return $diag
    }
    try {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $diag.stage = 'regular_file'
            $diag.error_code = 'LEAD_CLI_UNLAUNCHABLE'
            $diag.win32_error = 'not_regular_file'
            return $diag
        }
        $full = [string]$item.FullName
        $diag.executable = $full
        $diag.path_exists = $true
    } catch {
        $diag.stage = 'regular_file'
        $diag.error_code = 'LEAD_CLI_UNLAUNCHABLE'
        $diag.win32_error = 'stat_failed'
        return $diag
    }
    $captured = $null
    try {
        $captured = Invoke-TelephoneLeadDrainedProcess -FileName $full -Arguments $Arguments -TimeoutMilliseconds $TimeoutMilliseconds -KillOnTimeout
    } catch {
        $ex = $_.Exception
        $win32 = ''
        if ($ex -is [ComponentModel.Win32Exception]) { $win32 = [string]$ex.NativeErrorCode }
        elseif ($null -ne $ex.InnerException -and $ex.InnerException -is [ComponentModel.Win32Exception]) { $win32 = [string]$ex.InnerException.NativeErrorCode }
        elseif ($ex.HResult -ne 0) { $win32 = ('hresult:' + $ex.HResult.ToString()) }
        $diag.stage = 'create_process'
        $diag.error_code = 'LEAD_CLI_UNLAUNCHABLE'
        $diag.win32_error = $(if ([string]::IsNullOrWhiteSpace($win32)) { [string]$ex.Message } else { $win32 })
        return $diag
    }
    $diag.stage = 'version_probe'
    $diag.create_process_ok = [bool]$captured.process_exited
    $diag.exit_code = [int]$captured.exit_code
    $diag.version_text = ([string]$captured.stdout).Trim()
    if (-not [bool]$captured.process_exited) {
        $diag.error_code = 'LEAD_CLI_UNLAUNCHABLE'
        $diag.win32_error = 'probe_timeout'
        return $diag
    }
    if ([int]$captured.exit_code -ne 0 -or [string]::IsNullOrWhiteSpace($diag.version_text)) {
        $diag.error_code = 'LEAD_CLI_UNLAUNCHABLE'
        $diag.win32_error = 'version_probe_failed'
        return $diag
    }
    $diag.error_code = ''
    return $diag
}

function Resolve-TelephoneLeadCliExecutable {
    [CmdletBinding()]
    param(
        [string]$FrozenExecutable = '',
        [string]$ConfiguredExecutable = '',
        [string]$PolicyPath = '',
        [switch]$Probe
    )
    $policy = Get-TelephoneLeadStableCliPolicy -PolicyPath $PolicyPath
    $configured = [string]$ConfiguredExecutable
    if ([string]::IsNullOrWhiteSpace($configured)) { $configured = [string]$policy.executable }
    $frozen = [string]$FrozenExecutable
    $result = [ordered]@{
        protocol_version = 'telephone-line-cli-resolve-v1'
        launchable = $false
        reconciled = $false
        executable = ''
        frozen_executable = $frozen
        configured_executable = $configured
        diagnostic = $null
        policy_present = [bool]$policy.present
    }
    $candidates = [Collections.Generic.List[object]]::new()
    if (-not [string]::IsNullOrWhiteSpace($frozen)) {
        $frozenPath = $frozen
        if ($frozen -match '[\\/]' -or $frozen.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
            try { $frozenPath = [IO.Path]::GetFullPath($frozen) } catch { $frozenPath = $frozen }
        }
        [void]$candidates.Add([ordered]@{ kind = 'frozen'; path = $frozenPath })
    }
    if (-not [string]::IsNullOrWhiteSpace($configured) -and -not [string]::Equals($configured, $frozen, [StringComparison]::OrdinalIgnoreCase)) {
        [void]$candidates.Add([ordered]@{ kind = 'configured_stable'; path = $configured })
    }
    if ($candidates.Count -eq 0) {
        $result.diagnostic = New-TelephoneLeadCliDiagnostic -Stage 'resolve' -ErrorCode 'LEAD_CLI_UNLAUNCHABLE' -Win32Error 'no_executable_configured'
        return $result
    }
    foreach ($item in $candidates) {
        $diag = $null
        if ($Probe) {
            $diag = Invoke-TelephoneLeadCreateProcessProbe -Executable ([string]$item.path)
        } else {
            $exists = [IO.File]::Exists([string]$item.path)
            $diag = New-TelephoneLeadCliDiagnostic -Stage 'path' -Executable ([string]$item.path) -PathExists $exists
            if ($exists) {
                $itemObj = Get-Item -LiteralPath ([string]$item.path) -Force -ErrorAction SilentlyContinue
                if ($null -ne $itemObj -and -not $itemObj.PSIsContainer -and ($itemObj.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $diag.create_process_ok = $false
                    $diag.stage = 'path_only_not_probed'
                    $diag.error_code = ''
                } else {
                    $diag.error_code = 'LEAD_CLI_UNLAUNCHABLE'
                    $diag.win32_error = 'not_regular_file'
                }
            } else {
                $diag.error_code = 'LEAD_CLI_UNLAUNCHABLE'
                $diag.win32_error = 'path_missing'
            }
        }
        $result.diagnostic = $diag
        $ok = [string]::IsNullOrWhiteSpace([string]$diag.error_code)
        if ($Probe) { $ok = $ok -and [bool]$diag.create_process_ok }
        else { $ok = $ok -and [bool]$diag.path_exists }
        if ($ok) {
            $result.launchable = $true
            $result.executable = [string]$diag.executable
            if ([string]$item.kind -ceq 'configured_stable' -and -not [string]::IsNullOrWhiteSpace($frozen)) {
                $result.reconciled = $true
                $diag.reconcile = 'frozen_unlaunchable_use_configured_stable'
                $diag.frozen_executable = $frozen
                $diag.configured_executable = $configured
            }
            return $result
        }
        if ([string]$item.kind -ceq 'frozen') { continue }
    }
    $result.launchable = $false
    if ($null -ne $result.diagnostic) {
        $result.diagnostic.frozen_executable = $frozen
        $result.diagnostic.configured_executable = $configured
        $result.diagnostic.error_code = 'LEAD_CLI_UNLAUNCHABLE'
    }
    return $result
}

function Test-TelephoneLeadRunRootAdmission {
    [CmdletBinding()]
    param(
        [string]$RunRoot = '',
        [string]$ExpectedSessionId = '',
        [string]$ExpectedRunId = ''
    )
    $result = [ordered]@{ ok = $true; reason = '' }
    if ([string]::IsNullOrWhiteSpace($RunRoot)) { return $result }
    try {
        $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    } catch {
        $result.ok = $false
        $result.reason = 'run_root_invalid'
        return $result
    }
    if (-not [IO.Directory]::Exists($root)) { return $result }
    foreach ($name in @('lead-run.json')) {
        if ([IO.File]::Exists((Join-Path $root $name))) {
            $result.ok = $false
            $result.reason = 'run_already_exists'
            return $result
        }
    }
    $eventsPath = Join-Path $root 'codex-events.jsonl'
    if ([IO.File]::Exists($eventsPath)) {
        try {
            if ([IO.File]::ReadAllBytes($eventsPath).Length -gt 0) {
                $result.ok = $false
                $result.reason = 'events_already_present'
                return $result
            }
        } catch {
            $result.ok = $false
            $result.reason = 'events_unreadable'
            return $result
        }
    }
    $ownerPath = Join-Path $root 'owner.json'
    if (-not [IO.File]::Exists($ownerPath)) { return $result }
    try {
        $owner = (Read-TelephoneJson -Path $ownerPath).value
        if ($owner -isnot [Collections.IDictionary]) {
            $result.ok = $false
            $result.reason = 'owner_invalid'
            return $result
        }
        $ownSession = ''
        $ownRun = ''
        if ($owner.Contains('session_id')) { $ownSession = [string]$owner['session_id'] }
        if ($owner.Contains('run_id')) { $ownRun = [string]$owner['run_id'] }
        if (-not [string]::IsNullOrWhiteSpace($ownSession) -and -not [string]::IsNullOrWhiteSpace($ExpectedSessionId) -and $ownSession -cne $ExpectedSessionId) {
            $result.ok = $false
            $result.reason = 'foreign_session'
            return $result
        }
        if (-not [string]::IsNullOrWhiteSpace($ownRun) -and -not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and $ownRun -cne $ExpectedRunId) {
            $result.ok = $false
            $result.reason = 'run_mismatch'
            return $result
        }
        if (Test-TelephoneLeadOwnerIdentityAlive -Owner $owner) {
            $result.ok = $false
            $result.reason = 'live_owner'
            return $result
        }
    } catch {
        $result.ok = $false
        $result.reason = 'owner_unreadable'
        return $result
    }
    return $result
}

function Write-TelephoneLeadBoundOwnerFile {
    [CmdletBinding()]
    param(
        [string]$Path,
        [AllowNull()][object]$Identity = $null,
        [string]$SessionId = '',
        [string]$RunId = '',
        [string]$Role = 'host'
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or $null -eq $Identity) { return }
    $record = [ordered]@{
        protocol_version = 'telephone-line-bound-owner-v1'
        pid = [int]$Identity.pid
        start_time_utc_ticks = [int64]$Identity.start_time_utc_ticks
        started_at_utc = [string]$Identity.started_at_utc
        executable_path = [string]$Identity.executable_path
        session_id = [string]$SessionId
        run_id = [string]$RunId
        role = [string]$Role
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
        if ([IO.File]::Exists($full)) {
            try {
                $existing = (Read-TelephoneJson -Path $full).value
                if ($existing -is [Collections.IDictionary]) {
                    $existSession = ''
                    $existRun = ''
                    if ($existing.Contains('session_id')) { $existSession = [string]$existing['session_id'] }
                    if ($existing.Contains('run_id')) { $existRun = [string]$existing['run_id'] }
                    if (-not [string]::IsNullOrWhiteSpace($existSession) -and -not [string]::IsNullOrWhiteSpace($SessionId) -and $existSession -cne $SessionId) { return }
                    if (-not [string]::IsNullOrWhiteSpace($existRun) -and -not [string]::IsNullOrWhiteSpace($RunId) -and $existRun -cne $RunId) { return }
                    if (Test-TelephoneLeadOwnerIdentityAlive -Owner $existing) {
                        $existPid = 0
                        if ($existing.Contains('pid')) { $existPid = [int]$existing['pid'] }
                        if ($existPid -gt 0 -and $existPid -ne [int]$Identity.pid) { return }
                    }
                }
            } catch { return }
            $null = Write-TelephoneJsonReplace -Path $full -Value $record
        } else {
            $null = Write-TelephoneJsonCreateNew -Path $full -Value $record
        }
        Register-TelephoneLeadSessionWriter -Identity $Identity -SessionId $SessionId -RunId $RunId -Role $Role -OwnerPath $full
    } catch { }
}

function Write-TelephoneLeadDrainLifecycleFile {
    [CmdletBinding()]
    param(
        [string]$Path,
        [AllowNull()][object]$Identity = $null,
        [bool]$ProcessExited = $false,
        [AllowNull()][object]$ExitCode = $null,
        [bool]$StdoutEof = $false,
        [bool]$StderrEof = $false,
        [bool]$TimedOut = $false,
        [bool]$NativeTurnComplete = $false,
        [string]$Role = '',
        [string]$SessionId = '',
        [string]$RunId = ''
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or $null -eq $Identity) { return }
    $record = [ordered]@{
        protocol_version = 'telephone-line-drained-process-v1'
        pid = [int]$Identity.pid
        start_time_utc_ticks = [int64]$Identity.start_time_utc_ticks
        started_at_utc = [string]$Identity.started_at_utc
        executable_path = [string]$Identity.executable_path
        process_exited = [bool]$ProcessExited
        stdout_eof = [bool]$StdoutEof
        stderr_eof = [bool]$StderrEof
        timed_out = [bool]$TimedOut
        native_turn_complete = [bool]$NativeTurnComplete
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if ($null -ne $ExitCode) { $record['exit_code'] = [int]$ExitCode }
    if (-not [string]::IsNullOrWhiteSpace($Role)) { $record['role'] = [string]$Role }
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) { $record['session_id'] = [string]$SessionId }
    if (-not [string]::IsNullOrWhiteSpace($RunId)) { $record['run_id'] = [string]$RunId }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
        if ([IO.File]::Exists($full)) {
            try {
                $existing = [IO.File]::ReadAllText($full) | ConvertFrom-Json -AsHashtable -Depth 8
                if ($existing -is [Collections.IDictionary]) {
                    $hadExit = $false
                    $hadStdout = $false
                    $hadStderr = $false
                    if ($existing.Contains('process_exited')) { $hadExit = [bool]$existing['process_exited'] }
                    if ($existing.Contains('stdout_eof')) { $hadStdout = [bool]$existing['stdout_eof'] }
                    if ($existing.Contains('stderr_eof')) { $hadStderr = [bool]$existing['stderr_eof'] }
                    if (($hadExit -or $hadStdout -or $hadStderr) -and -not $ProcessExited -and -not $StdoutEof -and -not $StderrEof) {
                        return
                    }
                    if ($hadStdout -and -not $StdoutEof) { return }
                    if ($hadStderr -and -not $StderrEof) { return }
                    if ($hadExit -and -not $ProcessExited) { return }
                }
            } catch { }
        }
        $json = ($record | ConvertTo-Json -Depth 8 -Compress)
        [IO.File]::WriteAllText($full, ($json + "`n"), [Text.UTF8Encoding]::new($false))
    } catch { }
}

function Register-TelephoneLeadSessionWriter {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Identity = $null,
        [string]$SessionId = '',
        [string]$RunId = '',
        [string]$Role = '',
        [string]$OwnerPath = ''
    )
    $roleName = [string]$Role
    if ($roleName -cne 'cli' -and $roleName -cne 'writer') { return }
    if ([string]::IsNullOrWhiteSpace($SessionId) -or $null -eq $Identity -or [string]::IsNullOrWhiteSpace($OwnerPath)) { return }
    try {
        $runRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OwnerPath))
        $parent = [IO.Path]::GetDirectoryName($runRoot)
        if ([string]::IsNullOrWhiteSpace($parent)) { return }
        $dir = Join-Path $parent 'session-writers'
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $path = Join-Path $dir ($SessionId + '.json')
        $record = [ordered]@{
            protocol_version = 'telephone-line-session-writer-v1'
            pid = [int]$Identity.pid
            start_time_utc_ticks = [int64]$Identity.start_time_utc_ticks
            started_at_utc = [string]$Identity.started_at_utc
            executable_path = [string]$Identity.executable_path
            session_id = [string]$SessionId
            run_id = [string]$RunId
            role = $roleName
            source_run_root = $runRoot
            source_owner_path = [IO.Path]::GetFullPath($OwnerPath)
            recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        if ([IO.File]::Exists($path)) {
            $null = Write-TelephoneJsonReplace -Path $path -Value $record
        } else {
            $null = Write-TelephoneJsonCreateNew -Path $path -Value $record
        }
    } catch { }
}

function Start-TelephoneLeadOpenDrain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [AllowNull()][object]$StdoutTask = $null,
        [AllowNull()][object]$StderrTask = $null,
        [AllowNull()][object]$StdoutFile = $null,
        [AllowNull()][object]$StderrFile = $null,
        [string]$LifecyclePath = '',
        [Parameter(Mandatory = $true)][object]$Identity,
        [string]$Role = '',
        [string]$SessionId = '',
        [string]$RunId = '',
        [string]$HandoffPath = ''
    )
    $selfProc = Get-Process -Id $PID
    $ownerTicks = [int64]0
    $ownerExe = ''
    try {
        $ownerTicks = [int64]$selfProc.StartTime.ToUniversalTime().Ticks
        try { $ownerExe = [string]$selfProc.MainModule.FileName } catch { $ownerExe = [string]$selfProc.Path }
    } finally {
        $selfProc.Dispose()
    }
    $key = ([string]$Identity.pid) + '|' + ([string]$Identity.start_time_utc_ticks)
    $script:TelephoneLeadOpenDrains[$key] = [ordered]@{
        process = $Process
        stdout_task = $StdoutTask
        stderr_task = $StderrTask
        stdout_file = $StdoutFile
        stderr_file = $StderrFile
        lifecycle_path = [string]$LifecyclePath
        identity = $Identity
        role = [string]$Role
        session_id = [string]$SessionId
        run_id = [string]$RunId
        owner_pid = [int]$PID
        owner_start_time_utc_ticks = [int64]$ownerTicks
        owner_executable_path = [string]$ownerExe
        handoff_path = [string]$HandoffPath
        completion_task = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($HandoffPath)) {
        $handoff = [ordered]@{
            protocol_version = 'telephone-line-drain-handoff-v1'
            owner_pid = [int]$PID
            owner_start_time_utc_ticks = [int64]$ownerTicks
            owner_executable_path = [string]$ownerExe
            target_pid = [int]$Identity.pid
            pid = [int]$Identity.pid
            start_time_utc_ticks = [int64]$Identity.start_time_utc_ticks
            executable_path = [string]$Identity.executable_path
            session_id = [string]$SessionId
            run_id = [string]$RunId
            role = [string]$Role
            pending = $true
            process_exited = $false
            stdout_eof = $false
            stderr_eof = $false
            recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        try {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($HandoffPath))) | Out-Null
            [IO.File]::WriteAllText($HandoffPath, (($handoff | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        } catch { }
    }
    if ($null -ne $StdoutTask -and $null -ne $StderrTask -and -not [string]::IsNullOrWhiteSpace($HandoffPath)) {
        $startedAt = ''
        try {
            if ($null -ne $Identity -and $Identity -is [Collections.IDictionary] -and $Identity.Contains('started_at_utc')) {
                $startedAt = [string]$Identity.started_at_utc
            }
        } catch { $startedAt = '' }
        try {
            $script:TelephoneLeadOpenDrains[$key].completion_task = [TelephoneLeadOwnedReaderCompletion]::Attach(
                $Process,
                $StdoutTask,
                $StderrTask,
                [string]$HandoffPath,
                [string]$LifecyclePath,
                [int]$Identity.pid,
                [int64]$Identity.start_time_utc_ticks,
                $startedAt,
                [string]$Identity.executable_path,
                [string]$SessionId,
                [string]$RunId,
                [string]$Role,
                [int]$PID,
                [int64]$ownerTicks,
                [string]$ownerExe,
                $StdoutFile,
                $StderrFile)
        } catch { }
    }
}

function Find-TelephoneLeadOpenDrainKey {
    [CmdletBinding()]
    param(
        [int]$ProcessId = 0,
        [AllowNull()][object]$Identity = $null,
        [string]$SessionId = '',
        [string]$RunId = ''
    )
    $matches = [Collections.Generic.List[string]]::new()
    foreach ($key in @($script:TelephoneLeadOpenDrains.Keys)) {
        $drain = $script:TelephoneLeadOpenDrains[$key]
        $drainIdentity = $drain.identity
        $drainPid = 0
        try {
            if ($null -ne $drainIdentity -and $drainIdentity -is [Collections.IDictionary] -and $drainIdentity.Contains('pid')) {
                $drainPid = [int]$drainIdentity['pid']
            }
        } catch { $drainPid = 0 }
        if ($ProcessId -gt 0 -and $drainPid -ne $ProcessId) { continue }
        if ($null -ne $Identity) {
            if (-not (Test-TelephoneLeadProcessIdentityMatch -Expected $Identity -Actual $drainIdentity)) { continue }
        }
        if (-not [string]::IsNullOrWhiteSpace($SessionId) -and [string]$drain.session_id -cne $SessionId) { continue }
        if (-not [string]::IsNullOrWhiteSpace($RunId) -and [string]$drain.run_id -cne $RunId) { continue }
        [void]$matches.Add([string]$key)
    }
    if ($matches.Count -ne 1) { return '' }
    return [string]$matches[0]
}

function Complete-TelephoneLeadOpenDrain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [AllowNull()][object]$Identity = $null,
        [string]$SessionId = '',
        [string]$RunId = '',
        [switch]$Wait,
        [int]$WaitMilliseconds = 0
    )
    $key = Find-TelephoneLeadOpenDrainKey -ProcessId $ProcessId -Identity $Identity -SessionId $SessionId -RunId $RunId
    if ([string]::IsNullOrWhiteSpace($key) -or -not $script:TelephoneLeadOpenDrains.Contains($key)) {
        return [ordered]@{ found = $false; process_exited = $false; stdout_eof = $false; stderr_eof = $false; pending = $true }
    }
    $drain = $script:TelephoneLeadOpenDrains[$key]
    $process = $drain.process
    $exited = $false
    $exitCode = $null
    $boundMs = [Math]::Max(0, [int]$WaitMilliseconds)
    try {
        if ($Wait -and $boundMs -gt 0 -and $null -ne $process -and -not $process.HasExited) {
            $null = $process.WaitForExit($boundMs)
        }
        if ($null -ne $process) {
            $exited = [bool]$process.HasExited
            if ($exited) {
                try { $exitCode = [int]$process.ExitCode } catch { $exitCode = $null }
            }
        }
    } catch {
        $exited = $false
    }
    if (-not $exited) {
        return [ordered]@{ found = $true; process_exited = $false; stdout_eof = $false; stderr_eof = $false; pending = $true; pid = [int]$ProcessId }
    }
    $stdoutEof = $false
    $stderrEof = $false
    $streamMs = if ($boundMs -gt 0) { $boundMs } else { 5000 }
    try {
        if ($null -ne $drain.stdout_task) {
            if ($drain.stdout_task.Wait($streamMs)) {
                $null = $drain.stdout_task.GetAwaiter().GetResult()
                $stdoutEof = $true
            }
        } else {
            $stdoutEof = $true
        }
    } catch { }
    try {
        if ($null -ne $drain.stderr_task) {
            if ($drain.stderr_task.Wait($streamMs)) {
                $null = $drain.stderr_task.GetAwaiter().GetResult()
                $stderrEof = $true
            }
        } else {
            $stderrEof = $true
        }
    } catch { }
    $terminal = $stdoutEof -and $stderrEof -and $null -ne $exitCode
    if ($terminal -and $null -ne $drain.completion_task) {
        try { $terminal = [bool]$drain.completion_task.Wait($streamMs) } catch { $terminal = $false }
    }
    if (-not $terminal) {
        # Keep the actual reader and file handles alive. A later call can finish
        # the same drain; root exit or a bounded observation is not stream EOF.
        return [ordered]@{
            found = $true
            process_exited = $true
            exit_code = $exitCode
            exit_code_observed = ($null -ne $exitCode)
            stdout_eof = $stdoutEof
            stderr_eof = $stderrEof
            pending = $true
            pid = [int]$ProcessId
        }
    }
    try { if ($null -ne $drain.stdout_file) { $drain.stdout_file.Flush($true) } } catch { }
    try { if ($null -ne $drain.stderr_file) { $drain.stderr_file.Flush($true) } } catch { }
    if (-not [string]::IsNullOrWhiteSpace([string]$drain.lifecycle_path)) {
        Write-TelephoneLeadDrainLifecycleFile -Path ([string]$drain.lifecycle_path) -Identity $drain.identity -ProcessExited $true -ExitCode $exitCode -StdoutEof $stdoutEof -StderrEof $stderrEof -NativeTurnComplete $true -Role ([string]$drain.role) -SessionId ([string]$drain.session_id) -RunId ([string]$drain.run_id)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$drain.handoff_path)) {
        try {
            $done = [ordered]@{
                protocol_version = 'telephone-line-drain-handoff-v1'
                owner_pid = [int]$drain.owner_pid
                owner_start_time_utc_ticks = $(if ($drain.Contains('owner_start_time_utc_ticks')) { [int64]$drain.owner_start_time_utc_ticks } else { [int64]0 })
                owner_executable_path = $(if ($drain.Contains('owner_executable_path')) { [string]$drain.owner_executable_path } else { '' })
                target_pid = [int]$ProcessId
                pid = [int]$ProcessId
                start_time_utc_ticks = $(if ($null -ne $drain.identity -and $drain.identity -is [Collections.IDictionary] -and $drain.identity.Contains('start_time_utc_ticks')) { [int64]$drain.identity.start_time_utc_ticks } else { [int64]0 })
                executable_path = $(if ($null -ne $drain.identity -and $drain.identity -is [Collections.IDictionary] -and $drain.identity.Contains('executable_path')) { [string]$drain.identity.executable_path } else { '' })
                session_id = [string]$drain.session_id
                run_id = [string]$drain.run_id
                role = [string]$drain.role
                pending = $false
                process_exited = $true
                exit_code = [int]$exitCode
                stdout_eof = [bool]$stdoutEof
                stderr_eof = [bool]$stderrEof
                recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            }
            [IO.File]::WriteAllText([string]$drain.handoff_path, (($done | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
        } catch { }
    }
    try { if ($null -ne $drain.stdout_file) { $drain.stdout_file.Dispose() } } catch { }
    try { if ($null -ne $drain.stderr_file) { $drain.stderr_file.Dispose() } } catch { }
    try { if ($null -ne $process) { $process.Dispose() } } catch { }
    $script:TelephoneLeadOpenDrains.Remove($key)
    return [ordered]@{
        found = $true
        process_exited = $true
        exit_code = [int]$exitCode
        stdout_eof = [bool]$stdoutEof
        stderr_eof = [bool]$stderrEof
        pending = $false
        pid = [int]$ProcessId
    }
}

function Wait-TelephoneLeadOpenDrainUntilMeasured {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [AllowNull()][object]$Identity = $null,
        [string]$SessionId = '',
        [string]$RunId = '',
        [string]$LifecyclePath = ''
    )
    $unavailable = [ordered]@{
        found = $false
        unavailable = $true
        process_exited = $false
        stdout_eof = $false
        stderr_eof = $false
        pending = $true
        pid = [int]$ProcessId
        refused = 'drain_owner_unavailable'
        recorded_by = 'unavailable'
    }
    while ($true) {
        $done = Complete-TelephoneLeadOpenDrain -ProcessId $ProcessId -Identity $Identity -SessionId $SessionId -RunId $RunId -Wait -WaitMilliseconds 1000
        if ($null -ne $done -and [bool]$done.found -and [bool]$done.process_exited -and [bool]$done.stdout_eof -and [bool]$done.stderr_eof -and -not [bool]$done.pending -and $done.Contains('exit_code') -and $null -ne $done['exit_code']) {
            return $done
        }
        $life = $null
        if (-not [string]::IsNullOrWhiteSpace($LifecyclePath) -and [IO.File]::Exists($LifecyclePath)) {
            try { $life = Get-Content -LiteralPath $LifecyclePath -Raw | ConvertFrom-Json -AsHashtable } catch { $life = $null }
        }
        if ($null -ne $life -and $life -is [Collections.IDictionary]) {
            $lifePid = 0
            $lifeTarget = 0
            try { if ($life.Contains('pid')) { $lifePid = [int]$life['pid'] } } catch { $lifePid = 0 }
            try { if ($life.Contains('target_pid')) { $lifeTarget = [int]$life['target_pid'] } } catch { $lifeTarget = 0 }
            $pidMatch = ($lifePid -eq $ProcessId) -or ($lifeTarget -eq $ProcessId)
            if ($pidMatch -and (Test-TelephoneLeadDurableDrainTerminal -Doc $life -SessionId $SessionId -RunId $RunId -ExpectedIdentity $Identity)) {
                $exit = $null
                try { $exit = [int]$life['exit_code'] } catch { $exit = $null }
                if ($null -eq $exit) { return $unavailable }
                return [ordered]@{
                    found = $true
                    unavailable = $false
                    process_exited = $true
                    stdout_eof = $true
                    stderr_eof = $true
                    pending = $false
                    exit_code = $exit
                    pid = [int]$lifePid
                    recorded_by = 'lifecycle_file'
                }
            }
        }
        $key = Find-TelephoneLeadOpenDrainKey -ProcessId $ProcessId -Identity $Identity -SessionId $SessionId -RunId $RunId
        $inMemory = (-not [string]::IsNullOrWhiteSpace($key) -and $script:TelephoneLeadOpenDrains.Contains($key))
        if ($inMemory) {
            if ($null -ne $Identity -and $Identity -is [Collections.IDictionary]) {
                $obs = Get-TelephoneLeadOwnerIdentityObservation -Owner $Identity
                if ([string]$obs.status -ceq 'query_error') { Start-Sleep -Milliseconds 200; continue }
                if ([string]$obs.status -cne 'alive') { return $unavailable }
            }
            continue
        }
        $ownerAlive = $false
        if ($null -ne $life -and $life -is [Collections.IDictionary] -and (Test-TelephoneLeadDrainIdentityComplete -Doc $life -SessionId $SessionId -RunId $RunId)) {
            $lifePid = 0
            $lifeTarget = 0
            try { if ($life.Contains('pid')) { $lifePid = [int]$life['pid'] } } catch { $lifePid = 0 }
            try { if ($life.Contains('target_pid')) { $lifeTarget = [int]$life['target_pid'] } } catch { $lifeTarget = 0 }
            if ($lifePid -eq $ProcessId -or $lifeTarget -eq $ProcessId) {
                $obs = Get-TelephoneLeadOwnerIdentityObservation -Owner $life
                if ([string]$obs.status -ceq 'query_error') { Start-Sleep -Milliseconds 200; continue }
                if ([string]$obs.status -ceq 'alive') { $ownerAlive = $true }
            }
        }
        if ($ownerAlive) {
            Start-Sleep -Milliseconds 200
            continue
        }
        return $unavailable
    }
}

function Read-TelephoneLeadDrainRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    try {
        $doc = (Read-TelephoneJson -Path $Path).value
        if ($doc -is [Collections.IDictionary]) { return $doc }
        return $null
    } catch {
        return [ordered]@{ unreadable = $true; path = [string]$Path }
    }
}

function Test-TelephoneLeadDrainIdentityComplete {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Doc,
        [string]$SessionId = '',
        [string]$RunId = ''
    )
    if ($null -eq $Doc -or $Doc -isnot [Collections.IDictionary]) { return $false }
    if ($Doc.Contains('unreadable') -and [bool]$Doc['unreadable']) { return $false }
    $ownedPid = 0
    $ticks = [int64]0
    $exe = ''
    $session = ''
    $run = ''
    try {
        if ($Doc.Contains('pid')) { $ownedPid = [int]$Doc['pid'] }
        elseif ($Doc.Contains('target_pid')) { $ownedPid = [int]$Doc['target_pid'] }
        if ($Doc.Contains('start_time_utc_ticks')) { $ticks = [int64]$Doc['start_time_utc_ticks'] }
        if ($Doc.Contains('executable_path')) { $exe = [string]$Doc['executable_path'] }
        if ($Doc.Contains('session_id')) { $session = [string]$Doc['session_id'] }
        if ($Doc.Contains('run_id')) { $run = [string]$Doc['run_id'] }
    } catch {
        return $false
    }
    if ($ownedPid -le 0 -or $ticks -le 0 -or [string]::IsNullOrWhiteSpace($exe)) { return $false }
    if ([string]::IsNullOrWhiteSpace($session) -or [string]::IsNullOrWhiteSpace($run)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($SessionId) -and $session -cne $SessionId) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($RunId) -and $run -cne $RunId) { return $false }
    return $true
}

function Test-TelephoneLeadExactProcessObservation {
    [CmdletBinding()]
    param([AllowNull()][object]$Doc)
    if (-not (Test-TelephoneLeadDrainIdentityComplete -Doc $Doc)) {
        return [ordered]@{ status = 'unbound'; snapshot = $null; error = 'identity_incomplete' }
    }
    return (Get-TelephoneLeadOwnerIdentityObservation -Owner $Doc)
}

function Test-TelephoneLeadExactProcessAlive {
    [CmdletBinding()]
    param([AllowNull()][object]$Doc)
    $obs = Test-TelephoneLeadExactProcessObservation -Doc $Doc
    return ([string]$obs.status -ceq 'alive')
}

function Test-TelephoneLeadBoundHostTerminalRecord {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Doc,
        [string]$SessionId = '',
        [string]$RunId = '',
        [AllowNull()][object]$ExpectedIdentity = $null
    )
    if ($null -eq $Doc -or $Doc -isnot [Collections.IDictionary]) { return $false }
    $proto = ''
    if ($Doc.Contains('protocol_version')) { $proto = [string]$Doc['protocol_version'] }
    if ($proto -cne 'telephone-line-host-terminal-v1') { return $false }
    return (Test-TelephoneLeadDurableDrainTerminal -Doc $Doc -SessionId $SessionId -RunId $RunId -ExpectedIdentity $ExpectedIdentity)
}

function Test-TelephoneLeadDurableDrainTerminal {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Doc,
        [string]$SessionId = '',
        [string]$RunId = '',
        [AllowNull()][object]$ExpectedIdentity = $null
    )
    if (-not (Test-TelephoneLeadDrainIdentityComplete -Doc $Doc -SessionId $SessionId -RunId $RunId)) { return $false }
    if ($null -ne $ExpectedIdentity) {
        if (-not (Test-TelephoneLeadDrainMatchesExpectedProducer -Doc $Doc -ExpectedIdentity $ExpectedIdentity -SessionId $SessionId -RunId $RunId)) { return $false }
    }
    $exited = $false
    $stdoutEof = $false
    $stderrEof = $false
    try {
        if ($Doc.Contains('process_exited')) { $exited = [bool]$Doc['process_exited'] }
        if ($Doc.Contains('stdout_eof')) { $stdoutEof = [bool]$Doc['stdout_eof'] }
        if ($Doc.Contains('stderr_eof')) { $stderrEof = [bool]$Doc['stderr_eof'] }
    } catch {
        return $false
    }
    if (-not $exited -or -not $stdoutEof -or -not $stderrEof) { return $false }
    if (-not $Doc.Contains('exit_code') -or $null -eq $Doc['exit_code']) { return $false }
    if ($Doc.Contains('exit_code_observed') -and -not [bool]$Doc['exit_code_observed']) { return $false }
    $obs = Test-TelephoneLeadExactProcessObservation -Doc $Doc
    if ([string]$obs.status -ceq 'query_error' -or [string]$obs.status -ceq 'alive') { return $false }
    return $true
}

function Test-TelephoneLeadCliChildAbsenceProven {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [string]$SessionId = '',
        [string]$RunId = ''
    )
    $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    foreach ($name in @('cli-child.json', 'cli-drain-lifecycle.json', 'cli-drain-handoff.json')) {
        if ([IO.File]::Exists((Join-Path $root $name))) { return $false }
    }
    $meta = $null
    foreach ($name in @('lead-run.json', 'run.json')) {
        $path = Join-Path $root $name
        if (-not [IO.File]::Exists($path)) { continue }
        $doc = Read-TelephoneLeadDrainRecord -Path $path
        if ($null -eq $doc -or ($doc -is [Collections.IDictionary] -and $doc.Contains('unreadable'))) { continue }
        $meta = $doc
        break
    }
    if ($null -eq $meta -or $meta -isnot [Collections.IDictionary]) { return $false }
    $session = ''
    $run = ''
    try {
        if ($meta.Contains('resume_session_id')) { $session = [string]$meta['resume_session_id'] }
        if ([string]::IsNullOrWhiteSpace($session) -and $meta.Contains('session_id')) { $session = [string]$meta['session_id'] }
        if ($meta.Contains('run_id')) { $run = [string]$meta['run_id'] }
    } catch { return $false }
    if (-not [string]::IsNullOrWhiteSpace($SessionId) -and $session -cne $SessionId) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($RunId) -and $run -cne $RunId) { return $false }
    $proven = $false
    try {
        if ($meta.Contains('cli_child_expected')) { $proven = (-not [bool]$meta['cli_child_expected']) }
        elseif ($meta.Contains('cli_child_started')) { $proven = (-not [bool]$meta['cli_child_started']) }
        elseif ($meta.Contains('no_cli_child')) { $proven = [bool]$meta['no_cli_child'] }
    } catch { return $false }
    return [bool]$proven
}

function Get-TelephoneLeadDurableLastOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RunRoot)
    $path = Join-Path ([IO.Path]::GetFullPath($RunRoot).TrimEnd('\')) 'native-output.txt'
    if (-not [IO.File]::Exists($path)) { return $null }
    try {
        $bytes = [IO.File]::ReadAllBytes($path)
        return [ordered]@{
            path = [IO.Path]::GetFullPath($path)
            bytes = [int64]$bytes.Length
            sha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
        }
    } catch {
        return $null
    }
}

function Get-TelephoneLeadOwnedStreamObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][object]$Identity,
        [string]$Role = 'host',
        [string]$SessionId = '',
        [string]$RunId = ''
    )
    $result = [ordered]@{
        stdout_eof = $false
        stderr_eof = $false
        observation = 'reader_unrecoverable'
        exit_code = $null
        last_output = $null
    }
    $ownedPid = 0
    try {
        if ($Identity -is [Collections.IDictionary] -and $Identity.Contains('pid')) { $ownedPid = [int]$Identity['pid'] }
        elseif ($Identity -is [Collections.IDictionary] -and $Identity.Contains('target_pid')) { $ownedPid = [int]$Identity['target_pid'] }
    } catch { $ownedPid = 0 }
    if ($ownedPid -gt 0) {
        $complete = Complete-TelephoneLeadOpenDrain -ProcessId $ownedPid -Identity $Identity -SessionId $SessionId -RunId $RunId -Wait -WaitMilliseconds 1500
        if ([bool]$complete.found) {
            $result.stdout_eof = [bool]$complete.stdout_eof
            $result.stderr_eof = [bool]$complete.stderr_eof
            $result.observation = $(if ([bool]$complete.pending) { 'open_drain_pending' } else { 'open_drain_readers' })
            if ($complete.Contains('exit_code')) { $result.exit_code = $complete.exit_code }
            $result.last_output = Get-TelephoneLeadDurableLastOutput -RunRoot $RunRoot
            return $result
        }
    }
    $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    $handoffName = if ([string]$Role -ceq 'cli' -or [string]$Role -ceq 'child') { 'cli-drain-handoff.json' } else { 'host-drain-handoff.json' }
    $handoffPath = Join-Path $root $handoffName
    if ([IO.File]::Exists($handoffPath)) {
        $doc = Read-TelephoneLeadDrainRecord -Path $handoffPath
        if ($null -ne $doc -and $doc -is [Collections.IDictionary] -and -not ($doc.Contains('unreadable') -and [bool]$doc['unreadable'])) {
            if (Test-TelephoneLeadDrainMatchesExpectedProducer -Doc $doc -ExpectedIdentity $Identity -SessionId $SessionId -RunId $RunId) {
                $pending = $true
                if ($doc.Contains('pending')) { $pending = [bool]$doc['pending'] }
                if (-not $pending) {
                    if ($doc.Contains('stdout_eof')) { $result.stdout_eof = [bool]$doc['stdout_eof'] }
                    if ($doc.Contains('stderr_eof')) { $result.stderr_eof = [bool]$doc['stderr_eof'] }
                    $result.observation = 'handoff_complete'
                    if ($doc.Contains('exit_code')) { $result.exit_code = $doc['exit_code'] }
                } else {
                    $result.observation = 'handoff_pending'
                    $result.stdout_eof = $false
                    $result.stderr_eof = $false
                }
            } elseif (Test-TelephoneLeadDrainIdentityComplete -Doc $doc -SessionId $SessionId -RunId $RunId) {
                $result.observation = 'handoff_foreign_producer'
                $result.stdout_eof = $false
                $result.stderr_eof = $false
            }
        }
    }
    $result.last_output = Get-TelephoneLeadDurableLastOutput -RunRoot $RunRoot
    if ([string]$result.observation -cin @('reader_unrecoverable', 'handoff_pending', 'handoff_foreign_producer')) {
        $result.stdout_eof = $false
        $result.stderr_eof = $false
    }
    return $result
}

function Test-TelephoneLeadDrainCoordinatorAlive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [string]$Role = 'host'
    )
    $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    $handoffName = if ([string]$Role -ceq 'cli' -or [string]$Role -ceq 'child') { 'cli-drain-handoff.json' } else { 'host-drain-handoff.json' }
    $path = Join-Path $root $handoffName
    $doc = Read-TelephoneLeadDrainRecord -Path $path
    if ($null -eq $doc -or $doc -isnot [Collections.IDictionary] -or ($doc.Contains('unreadable') -and [bool]$doc['unreadable'])) { return $false }
    $ownerPid = 0
    $ownerTicks = [int64]0
    $ownerExe = ''
    try {
        if ($doc.Contains('owner_pid')) { $ownerPid = [int]$doc['owner_pid'] }
        if ($doc.Contains('owner_start_time_utc_ticks')) { $ownerTicks = [int64]$doc['owner_start_time_utc_ticks'] }
        if ($doc.Contains('owner_executable_path')) { $ownerExe = [string]$doc['owner_executable_path'] }
    } catch { return $false }
    if ($ownerPid -le 0 -or $ownerTicks -le 0) { return $false }
    return (Test-TelephoneLeadOwnerIdentityAlive -Owner ([ordered]@{
        pid = [int]$ownerPid
        start_time_utc_ticks = [int64]$ownerTicks
        executable_path = [string]$ownerExe
    }))
}

function Write-TelephoneLeadOwnedRecoveredDrainLifecycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [string]$Role = 'host',
        [bool]$NativeTurnComplete = $true,
        [AllowNull()][object]$ExitCode = $null
    )
    if (-not (Test-TelephoneLeadDrainIdentityComplete -Doc $Identity -SessionId $SessionId -RunId $RunId)) { return $false }
    $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    $name = if ([string]$Role -ceq 'cli' -or [string]$Role -ceq 'child') { 'cli-drain-lifecycle.json' } else { 'host-drain-lifecycle.json' }
    $path = Join-Path $root $name
    $stream = Get-TelephoneLeadOwnedStreamObservation -RunRoot $root -Identity $Identity -Role $Role -SessionId $SessionId -RunId $RunId
    $resolvedExit = $ExitCode
    if ($null -eq $resolvedExit -and $null -ne $stream.exit_code) { $resolvedExit = $stream.exit_code }
    Write-TelephoneLeadDrainLifecycleFile -Path $path -Identity $Identity -ProcessExited $true -ExitCode $resolvedExit -StdoutEof ([bool]$stream.stdout_eof) -StderrEof ([bool]$stream.stderr_eof) -NativeTurnComplete $NativeTurnComplete -Role $Role -SessionId $SessionId -RunId $RunId
    try {
        $doc = (Read-TelephoneJson -Path $path).value
        if ($doc -is [Collections.IDictionary]) {
            $doc['process_exit_observation'] = 'exact_identity_not_found_after_owned_stop'
            $doc['stream_eof_observation'] = [string]$stream.observation
            $doc['recovery_source'] = 'owned_native_complete_reconcile'
            if ($null -ne $stream.last_output -and $stream.last_output -is [Collections.IDictionary]) {
                $doc['last_output_path'] = [string]$stream.last_output.path
                $doc['last_output_bytes'] = [int64]$stream.last_output.bytes
                $doc['last_output_sha256'] = [string]$stream.last_output.sha256
            }
            $null = Write-TelephoneJsonReplace -Path $path -Value $doc
        }
    } catch { }
    return $true
}

function Get-TelephoneLeadOwnedDrainSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [string]$SessionId = '',
        [string]$RunId = ''
    )
    $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    $hostDocs = [Collections.Generic.List[object]]::new()
    $childDocs = [Collections.Generic.List[object]]::new()
    $hostUnreadable = $false
    $childUnreadable = $false
    $hostPresent = $false
    $childPresent = $false
    foreach ($name in @('owner.json', 'host-owner.json', 'host-drain-lifecycle.json', 'host-drain-handoff.json')) {
        $path = Join-Path $root $name
        if (-not [IO.File]::Exists($path)) { continue }
        $hostPresent = $true
        $doc = Read-TelephoneLeadDrainRecord -Path $path
        if ($null -eq $doc -or ($doc -is [Collections.IDictionary] -and $doc.Contains('unreadable'))) {
            $hostUnreadable = $true
            continue
        }
        $hostDocs.Add($doc)
    }
    foreach ($name in @('cli-child.json', 'cli-drain-lifecycle.json', 'cli-drain-handoff.json')) {
        $path = Join-Path $root $name
        if (-not [IO.File]::Exists($path)) { continue }
        $childPresent = $true
        $doc = Read-TelephoneLeadDrainRecord -Path $path
        if ($null -eq $doc -or ($doc -is [Collections.IDictionary] -and $doc.Contains('unreadable'))) {
            $childUnreadable = $true
            continue
        }
        $childDocs.Add($doc)
    }
    $hostIdentity = $null
    foreach ($doc in $hostDocs) {
        if (Test-TelephoneLeadDrainIdentityComplete -Doc $doc -SessionId $SessionId -RunId $RunId) {
            $hostIdentity = $doc
            break
        }
    }
    $childIdentity = $null
    foreach ($doc in $childDocs) {
        if (Test-TelephoneLeadDrainIdentityComplete -Doc $doc -SessionId $SessionId -RunId $RunId) {
            $childIdentity = $doc
            break
        }
    }
    return [ordered]@{
        host_present = [bool]$hostPresent
        child_present = [bool]$childPresent
        host_unreadable = [bool]$hostUnreadable
        child_unreadable = [bool]$childUnreadable
        host_identity = $hostIdentity
        child_identity = $childIdentity
        host_docs = @($hostDocs)
        child_docs = @($childDocs)
    }
}

function Test-TelephoneLeadOwnedDrainRecordsPresent {
    [CmdletBinding()]
    param([string]$RunRoot)
    if ([string]::IsNullOrWhiteSpace($RunRoot)) { return $false }
    try { $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\') } catch { return $false }
    foreach ($name in @('host-drain-lifecycle.json', 'cli-drain-lifecycle.json', 'drain-lifecycle.json')) {
        if ([IO.File]::Exists((Join-Path $root $name))) { return $true }
    }
    return $false
}

function Test-TelephoneLeadCallbackQueueStillOpen {
    [CmdletBinding()]
    param([string]$RunRoot)
    if ([string]::IsNullOrWhiteSpace($RunRoot)) { return $false }
    try { $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\') } catch { return $false }
    $runPath = Join-Path $root 'run.json'
    if (-not [IO.File]::Exists($runPath)) { return $false }
    $run = $null
    try { $run = (Read-TelephoneJson -Path $runPath).value } catch { return $false }
    if ($run -isnot [Collections.IDictionary]) { return $false }
    $queueState = ''
    $phase = ''
    if ($run.Contains('queue_state')) { $queueState = [string]$run['queue_state'] }
    if ($run.Contains('callback_write_phase')) { $phase = [string]$run['callback_write_phase'] }
    if ($queueState -ceq 'queued') { return $true }
    if ($phase -cin @('turn_start_sending', 'turn_bound', 'turn_start_ambiguous')) { return $true }
    if ($queueState -ceq 'in_progress' -and $phase -cne 'terminal') { return $true }
    $intentPath = Join-Path $root 'intent.json'
    $ackPath = Join-Path $root 'lead-wake-ack.json'
    if ([IO.File]::Exists($intentPath) -and -not [IO.File]::Exists($ackPath) -and $queueState -cne 'retired') { return $true }
    return $false
}

function Wait-TelephoneLeadOwnedDrainTerminal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [int]$WaitMilliseconds = 120000
    )
    $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    $result = [ordered]@{
        protocol_version = 'telephone-line-owned-drain-terminal-v1'
        run_root = $root
        host_terminal = $false
        child_terminal = $false
        pending = $true
        stdout_eof = $false
        stderr_eof = $false
        process_exited = $false
        identity_status = 'UNKNOWN'
        host_alive = $false
        child_alive = $false
        native_turn_complete = $false
        host_observation_status = 'UNKNOWN'
        child_observation_status = 'UNKNOWN'
        child_absence_proven = $false
        measured_os_exit_code = $null
        recorded_by = ''
        reader_ready = $false
        child_measured = $false
    }
    $sessionId = ''
    $runId = ''
    $runPath = Join-Path $root 'run.json'
    $leadRunPath = Join-Path $root 'lead-run.json'
    $metaUnreadable = $false
    foreach ($metaPath in @($runPath, $leadRunPath)) {
        if (-not [IO.File]::Exists($metaPath)) { continue }
        $meta = Read-TelephoneLeadDrainRecord -Path $metaPath
        if ($null -eq $meta -or ($meta -is [Collections.IDictionary] -and $meta.Contains('unreadable'))) {
            $metaUnreadable = $true
            continue
        }
        if ($meta.Contains('session_id') -and [string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = [string]$meta['session_id'] }
        if ($meta.Contains('resume_session_id') -and [string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = [string]$meta['resume_session_id'] }
        if ($meta.Contains('run_id') -and [string]::IsNullOrWhiteSpace($runId)) { $runId = [string]$meta['run_id'] }
        if ($meta.Contains('thread_id') -and [string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = [string]$meta['thread_id'] }
    }
    $bound = [Math]::Max(0, [int]$WaitMilliseconds)
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds([Math]::Max(1, $bound))
    $first = $true
    do {
        $snap = Get-TelephoneLeadOwnedDrainSnapshot -RunRoot $root -SessionId $sessionId -RunId $runId
        if (-not [bool]$snap.host_present -and -not [bool]$snap.child_present) {
            $result.identity_status = 'UNKNOWN'
            $result.pending = $true
            $result.host_terminal = $false
            $result.child_terminal = $false
            $result.process_exited = $false
            return $result
        }
        $hostUnreadableBlocking = [bool]$snap.host_unreadable -and $null -eq $snap.host_identity
        $childUnreadableBlocking = [bool]$snap.child_unreadable -and $null -eq $snap.child_identity -and [bool]$snap.child_present
        if ($hostUnreadableBlocking -or $childUnreadableBlocking -or ($metaUnreadable -and [string]::IsNullOrWhiteSpace($sessionId))) {
            $result.identity_status = 'UNKNOWN'
            $result.pending = $true
        }
        $remain = [int][Math]::Max(0, ($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)
        $slice = [Math]::Min(250, $remain)
        $hostIdentity = $snap.host_identity
        $childIdentity = $snap.child_identity
        $hostDone = $false
        $childDone = $false
        $hostDrain = $null
        $childDrain = $null
        $result.child_absence_proven = (Test-TelephoneLeadCliChildAbsenceProven -RunRoot $root -SessionId $sessionId -RunId $runId)
        if ($null -ne $hostIdentity) {
            $hostPid = 0
            if ($hostIdentity.Contains('pid')) { $hostPid = [int]$hostIdentity['pid'] }
            elseif ($hostIdentity.Contains('target_pid')) { $hostPid = [int]$hostIdentity['target_pid'] }
            $hostObs = Test-TelephoneLeadExactProcessObservation -Doc $hostIdentity
            $result.host_observation_status = [string]$hostObs.status
            $result.host_alive = ([string]$hostObs.status -ceq 'alive')
            if ($hostPid -gt 0) {
                $hostDrainWait = ($slice -gt 0) -and -not [bool]$result.host_alive
                $hostDrain = Complete-TelephoneLeadOpenDrain -ProcessId $hostPid -Identity $hostIdentity -SessionId $sessionId -RunId $runId -Wait:$hostDrainWait -WaitMilliseconds $(if ($hostDrainWait) { $slice } else { 0 })
            }
            if ($null -ne $hostDrain -and [bool]$hostDrain.found -and [bool]$hostDrain.process_exited -and [bool]$hostDrain.stdout_eof -and [bool]$hostDrain.stderr_eof) {
                $recheck = Test-TelephoneLeadExactProcessObservation -Doc $hostIdentity
                $result.host_observation_status = [string]$recheck.status
                $result.host_alive = ([string]$recheck.status -ceq 'alive')
                if ([string]$recheck.status -cne 'query_error' -and [string]$recheck.status -cne 'alive') {
                    $hostDone = $true
                    $result.stdout_eof = [bool]$hostDrain.stdout_eof
                    $result.stderr_eof = [bool]$hostDrain.stderr_eof
                    if ($hostDrain.Contains('exit_code') -and $null -ne $hostDrain['exit_code']) {
                        $result.measured_os_exit_code = [int]$hostDrain['exit_code']
                        $result.recorded_by = 'open_drain_completion'
                    }
                }
            }
            if (-not $hostDone) {
                foreach ($doc in @($snap.host_docs)) {
                    if (Test-TelephoneLeadDurableDrainTerminal -Doc $doc -SessionId $sessionId -RunId $runId -ExpectedIdentity $hostIdentity) {
                        $hostDone = $true
                        $result.stdout_eof = $true
                        $result.stderr_eof = $true
                        if ($doc.Contains('exit_code') -and $null -ne $doc['exit_code']) {
                            $result.measured_os_exit_code = [int]$doc['exit_code']
                        }
                        if ($doc.Contains('recorded_by') -and -not [string]::IsNullOrWhiteSpace([string]$doc['recorded_by'])) {
                            $result.recorded_by = [string]$doc['recorded_by']
                        } elseif ([string]::IsNullOrWhiteSpace([string]$result.recorded_by)) {
                            $result.recorded_by = 'durable_drain_terminal'
                        }
                        break
                    }
                }
            }
            $nativeBound = $false
            foreach ($doc in @($snap.host_docs)) {
                if (-not (Test-TelephoneLeadDrainIdentityComplete -Doc $doc -SessionId $sessionId -RunId $runId)) { continue }
                if ($doc.Contains('native_turn_complete') -and [bool]$doc['native_turn_complete']) { $nativeBound = $true }
            }
            $result.native_turn_complete = [bool]$nativeBound
        }
        if ($null -ne $childIdentity) {
            $childPid = 0
            if ($childIdentity.Contains('pid')) { $childPid = [int]$childIdentity['pid'] }
            elseif ($childIdentity.Contains('target_pid')) { $childPid = [int]$childIdentity['target_pid'] }
            $childObs = Test-TelephoneLeadExactProcessObservation -Doc $childIdentity
            $result.child_observation_status = [string]$childObs.status
            $result.child_alive = ([string]$childObs.status -ceq 'alive')
            $remain = [int][Math]::Max(0, ($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)
            $slice = [Math]::Min(250, $remain)
            if ($childPid -gt 0) {
                $childDrain = Complete-TelephoneLeadOpenDrain -ProcessId $childPid -Identity $childIdentity -SessionId $sessionId -RunId $runId -Wait:($slice -gt 0) -WaitMilliseconds $slice
            }
            if ($null -ne $childDrain -and [bool]$childDrain.found -and [bool]$childDrain.process_exited -and [bool]$childDrain.stdout_eof -and [bool]$childDrain.stderr_eof) {
                $recheckChild = Test-TelephoneLeadExactProcessObservation -Doc $childIdentity
                $result.child_observation_status = [string]$recheckChild.status
                $result.child_alive = ([string]$recheckChild.status -ceq 'alive')
                if ([string]$recheckChild.status -cne 'query_error') {
                    $childDone = $true
                    $result.stdout_eof = [bool]$childDrain.stdout_eof
                    $result.stderr_eof = [bool]$childDrain.stderr_eof
                    if ($childDrain.Contains('exit_code') -and $null -ne $childDrain['exit_code']) {
                        $result.measured_os_exit_code = [int]$childDrain['exit_code']
                        $result.recorded_by = 'open_drain_completion'
                    }
                }
            }
            if (-not $childDone) {
                foreach ($doc in @($snap.child_docs)) {
                    if (Test-TelephoneLeadDurableDrainTerminal -Doc $doc -SessionId $sessionId -RunId $runId -ExpectedIdentity $childIdentity) {
                        $childDone = $true
                        $result.stdout_eof = $true
                        $result.stderr_eof = $true
                        if ($doc.Contains('exit_code') -and $null -ne $doc['exit_code']) {
                            $result.measured_os_exit_code = [int]$doc['exit_code']
                        }
                        if ($doc.Contains('recorded_by') -and -not [string]::IsNullOrWhiteSpace([string]$doc['recorded_by'])) {
                            $result.recorded_by = [string]$doc['recorded_by']
                        } elseif ([string]::IsNullOrWhiteSpace([string]$result.recorded_by)) {
                            $result.recorded_by = 'durable_child_drain_terminal'
                        }
                        break
                    }
                }
            }
            if (-not $childDone -and -not [bool]$result.child_alive -and [string]$childObs.status -cin @('not_found', 'mismatch')) {
                $childHandoffPath = Join-Path $root 'cli-drain-handoff.json'
                $childDrainOwned = [IO.File]::Exists($childHandoffPath) -or -not [string]::IsNullOrWhiteSpace((Find-TelephoneLeadOpenDrainKey -ProcessId $childPid -Identity $childIdentity -SessionId $sessionId -RunId $runId))
                if (-not $childDrainOwned) {
                    $childDone = $true
                    $result.child_observation_status = 'streams_never_owned_process_exited'
                }
            }
        } elseif ([bool]$result.child_absence_proven) {
            $result.child_observation_status = 'absent_proven'
            $childDone = $true
        } else {
            $result.child_observation_status = 'missing_unproven'
        }
        $childMeasured = [bool]$result.stdout_eof -and [bool]$result.stderr_eof -and $null -ne $result.measured_os_exit_code
        $result.child_measured = [bool]$childMeasured
        if ([bool]$result.host_alive) { $hostDone = $false }
        if ($childMeasured -and [string]::IsNullOrWhiteSpace([string]$result.recorded_by)) {
            $result.recorded_by = 'measured_child_drain'
        }
        $result.reader_ready = [bool](($childDone -or $childMeasured) -and -not $hostDone)
        $result.host_terminal = [bool]$hostDone
        $result.child_terminal = [bool]$childDone
        $result.process_exited = [bool]($hostDone -and $childDone)
        if ($null -ne $hostIdentity) {
            $result.identity_status = 'BOUND'
        } elseif ($childMeasured) {
            $result.identity_status = 'BOUND'
        } else {
            $result.identity_status = 'UNKNOWN'
        }
        if ([bool]$result.host_alive -and ($childDone -or $childMeasured -or [bool]$result.child_absence_proven)) {
            $result.pending = $true
            $result.host_terminal = $false
            $result.process_exited = $false
            $result.reader_ready = $true
            return $result
        }
        if (-not $hostDone -and -not [bool]$result.host_alive -and [string]$result.host_observation_status -cin @('not_found', 'mismatch')) {
            $hostTermPath = Join-Path $root 'host-terminal.json'
            if ([IO.File]::Exists($hostTermPath)) {
                try {
                    $hostTerm = (Read-TelephoneJson -Path $hostTermPath).value
                    if (Test-TelephoneLeadBoundHostTerminalRecord -Doc $hostTerm -SessionId $sessionId -RunId $runId -ExpectedIdentity $hostIdentity) {
                        $hostDone = $true
                        $result.host_terminal = $true
                        if ($null -eq $result.measured_os_exit_code -and $hostTerm.Contains('exit_code') -and $null -ne $hostTerm['exit_code']) {
                            $result.measured_os_exit_code = [int]$hostTerm['exit_code']
                        }
                        if ($hostTerm.Contains('recorded_by') -and -not [string]::IsNullOrWhiteSpace([string]$hostTerm['recorded_by'])) {
                            $result.recorded_by = [string]$hostTerm['recorded_by']
                        } elseif ([string]::IsNullOrWhiteSpace([string]$result.recorded_by)) {
                            $result.recorded_by = 'host_terminal_record'
                        }
                    }
                } catch { }
            }
        }
        $result.reader_ready = [bool](($childDone -or $childMeasured) -and -not $hostDone)
        $result.host_terminal = [bool]$hostDone
        $result.child_terminal = [bool]$childDone
        $result.process_exited = [bool]($hostDone -and $childDone)
        if (-not [bool]$result.host_alive -and [string]$result.host_observation_status -cin @('not_found', 'mismatch') -and -not $hostDone -and ($childDone -or $childMeasured)) {
            $result.pending = $true
            $result.host_terminal = $false
            $result.process_exited = $false
            $result.reader_ready = $true
            if ($first -or [int]$WaitMilliseconds -le 0) { return $result }
        }
        $measured = [bool]$result.stdout_eof -and [bool]$result.stderr_eof -and $null -ne $result.measured_os_exit_code
        if ($hostDone -and $childDone -and [string]$result.identity_status -ceq 'BOUND' -and $measured -and [string]$result.host_observation_status -cne 'query_error') {
            $result.pending = $false
            return $result
        }
        $result.pending = $true
        if ($first -and [int]$WaitMilliseconds -le 0) { return $result }
        $first = $false
        if ([DateTimeOffset]::UtcNow -ge $deadline) { return $result }
        $sleepMs = [Math]::Min(200, [int][Math]::Max(1, ($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds))
        Start-Sleep -Milliseconds $sleepMs
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    $result.pending = $true
    return $result
}

function Invoke-TelephoneLeadDrainedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [string]$WorkingDirectory = '',
        [string]$StdoutPath = '',
        [string]$StderrPath = '',
        [string]$LifecyclePath = '',
        [string]$OwnerPath = '',
        [string]$EventsPath = '',
        [string]$SessionId = '',
        [string]$RunId = '',
        [string]$Role = 'host',
        [int]$TimeoutMilliseconds = 0,
        [switch]$KillOnTimeout,
        [switch]$ReturnOnNativeComplete
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FileName
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $info.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    }
    foreach ($item in @($Arguments)) {
        [void]$info.ArgumentList.Add([string]$item)
    }
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($info)
    } catch {
        throw
    }
    if ($null -eq $process) { throw 'Process did not start.' }
    $stdoutTask = $null
    $stderrTask = $null
    $stdoutFile = $null
    $stderrFile = $null
    $abandon = $false
    try {
        $identity = [ordered]@{
            pid = [int]$process.Id
            start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
            started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
            executable_path = $FileName
            session_id = [string]$SessionId
            run_id = [string]$RunId
        }
        if (-not [string]::IsNullOrWhiteSpace($StdoutPath)) {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StdoutPath))) | Out-Null
            $stdoutFile = [IO.FileStream]::new($StdoutPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
        } else {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        }
        if (-not [string]::IsNullOrWhiteSpace($StderrPath)) {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StderrPath))) | Out-Null
            $stderrFile = [IO.FileStream]::new($StderrPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrFile)
        } else {
            $stderrTask = $process.StandardError.ReadToEndAsync()
        }
        Write-TelephoneLeadBoundOwnerFile -Path $OwnerPath -Identity $identity -SessionId $SessionId -RunId $RunId -Role $Role
        if (-not [string]::IsNullOrWhiteSpace($LifecyclePath)) {
            Write-TelephoneLeadDrainLifecycleFile -Path $LifecyclePath -Identity $identity -ProcessExited $false -Role $Role -SessionId $SessionId -RunId $RunId
        }
        $exited = $false
        $nativeComplete = $false
        $stopReason = ''
        $deadline = [DateTimeOffset]::MaxValue
        if ($TimeoutMilliseconds -gt 0) {
            $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        }
        while (-not $process.HasExited) {
            $slice = 1000
            if ($deadline -ne [DateTimeOffset]::MaxValue) {
                $remain = [int]($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds
                if ($remain -le 0) { break }
                if ($remain -lt $slice) { $slice = $remain }
            }
            $exited = $process.WaitForExit($slice)
            if ($exited) { break }
            if ($null -ne $stdoutFile) { try { $stdoutFile.Flush($true) } catch { } }
            if ($null -ne $stderrFile) { try { $stderrFile.Flush($true) } catch { } }
            if (-not [string]::IsNullOrWhiteSpace($EventsPath) -and -not [string]::IsNullOrWhiteSpace($SessionId)) {
                try {
                    $native = Get-TelephoneLeadEventNativeTurn -EventsPath $EventsPath -ExpectedSessionId $SessionId -ExpectedRunId $RunId
                    $nativeComplete = [bool]$native.native_turn_complete
                } catch { $nativeComplete = $false }
            }
            if (-not [string]::IsNullOrWhiteSpace($LifecyclePath)) {
                Write-TelephoneLeadDrainLifecycleFile -Path $LifecyclePath -Identity $identity -ProcessExited $false -NativeTurnComplete $nativeComplete -Role $Role -SessionId $SessionId -RunId $RunId
            }
            if ($ReturnOnNativeComplete -and $nativeComplete) {
                $abandon = $true
                if (-not [string]::IsNullOrWhiteSpace($LifecyclePath)) {
                    Write-TelephoneLeadDrainLifecycleFile -Path $LifecyclePath -Identity $identity -ProcessExited $false -NativeTurnComplete $true -Role $Role -SessionId $SessionId -RunId $RunId
                }
                $handoffPath = ''
                if (-not [string]::IsNullOrWhiteSpace($LifecyclePath)) {
                    $handoffPath = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($LifecyclePath))) (($Role + '-drain-handoff.json').TrimStart('-'))
                    if ([string]::IsNullOrWhiteSpace($Role)) { $handoffPath = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($LifecyclePath))) 'drain-handoff.json' }
                }
                Start-TelephoneLeadOpenDrain -Process $process -StdoutTask $stdoutTask -StderrTask $stderrTask -StdoutFile $stdoutFile -StderrFile $stderrFile -LifecyclePath $LifecyclePath -Identity $identity -Role $Role -SessionId $SessionId -RunId $RunId -HandoffPath $handoffPath
                return [ordered]@{
                    protocol_version = 'telephone-line-drained-process-v1'
                    pid = [int]$identity.pid
                    start_time_utc_ticks = [int64]$identity.start_time_utc_ticks
                    started_at_utc = [string]$identity.started_at_utc
                    executable_path = [string]$identity.executable_path
                    session_id = [string]$SessionId
                    run_id = [string]$RunId
                    role = [string]$Role
                    process_exited = $false
                    exit_code = 1
                    stdout_eof = $false
                    stderr_eof = $false
                    stdout = ''
                    stderr = ''
                    timed_out = $false
                    native_turn_complete = $true
                    returned_on_native_complete = $true
                    drain_handoff_pending = $true
                    drain_owner_pid = [int]$PID
                    stop_reason = $(if (-not [string]::IsNullOrWhiteSpace($stopReason)) { [string]$stopReason } else { 'native_complete_open_drain' })
                    recycle_attempted = $false
                }
            }
        }
        if (-not $process.HasExited) {
            if ($KillOnTimeout) {
                try { $process.Kill($true) } catch { }
                $null = $process.WaitForExit(5000)
            }
        } else {
            $exited = $true
        }
        $stdoutText = ''
        $stderrText = ''
        $stdoutEof = $false
        $stderrEof = $false
        try {
            $stdoutResult = $stdoutTask.GetAwaiter().GetResult()
            $stdoutEof = $true
            if ([string]::IsNullOrWhiteSpace($StdoutPath)) { $stdoutText = [string]$stdoutResult }
        } catch { }
        try {
            $stderrResult = $stderrTask.GetAwaiter().GetResult()
            $stderrEof = $true
            if ([string]::IsNullOrWhiteSpace($StderrPath)) { $stderrText = [string]$stderrResult }
        } catch { }
        $processExited = [bool]$process.HasExited
        $exitCode = 1
        if ($processExited) { $exitCode = [int]$process.ExitCode }
        if (-not [string]::IsNullOrWhiteSpace($EventsPath) -and -not [string]::IsNullOrWhiteSpace($SessionId)) {
            try {
                $native = Get-TelephoneLeadEventNativeTurn -EventsPath $EventsPath -ExpectedSessionId $SessionId -ExpectedRunId $RunId
                $nativeComplete = [bool]$native.native_turn_complete
            } catch { }
        }
        if (-not [string]::IsNullOrWhiteSpace($LifecyclePath)) {
            Write-TelephoneLeadDrainLifecycleFile -Path $LifecyclePath -Identity $identity -ProcessExited $processExited -ExitCode $exitCode -StdoutEof $stdoutEof -StderrEof $stderrEof -TimedOut (-not $exited) -NativeTurnComplete $nativeComplete -Role $Role -SessionId $SessionId -RunId $RunId
        }
        return [ordered]@{
            protocol_version = 'telephone-line-drained-process-v1'
            pid = [int]$identity.pid
            start_time_utc_ticks = [int64]$identity.start_time_utc_ticks
            started_at_utc = [string]$identity.started_at_utc
            executable_path = [string]$identity.executable_path
            session_id = [string]$SessionId
            run_id = [string]$RunId
            role = [string]$Role
            process_exited = $processExited
            exit_code = [int]$exitCode
            stdout_eof = $stdoutEof
            stderr_eof = $stderrEof
            stdout = $stdoutText
            stderr = $stderrText
            timed_out = (-not $exited)
            native_turn_complete = [bool]$nativeComplete
            returned_on_native_complete = $false
            stop_reason = $(if (-not [string]::IsNullOrWhiteSpace($stopReason)) { [string]$stopReason } elseif (-not $exited) { 'timeout' } else { 'natural_exit' })
            recycle_attempted = $false
        }
    } finally {
        if (-not $abandon) {
            if ($null -ne $stdoutFile) { $stdoutFile.Dispose() }
            if ($null -ne $stderrFile) { $stderrFile.Dispose() }
            if ($null -ne $process) { $process.Dispose() }
        }
    }
}

function Get-TelephoneLeadEventNativeTurn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EventsPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId,
        [string]$ExpectedRunId = '',
        [AllowNull()][string]$NotBeforeUtc = ''
    )
    $result = [ordered]@{
        thread_started = $false
        turn_started = $false
        native_turn_complete = $false
        current_turn_id = ''
        complete_kind = ''
        rejected = ''
    }
    if (-not [IO.File]::Exists($EventsPath)) { return $result }
    $notBefore = [DateTimeOffset]::MinValue
    if (-not [string]::IsNullOrWhiteSpace($NotBeforeUtc)) {
        try { $notBefore = [DateTimeOffset]::Parse($NotBeforeUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { $notBefore = [DateTimeOffset]::MinValue }
    }
    $records = @()
    try {
        $records = @(Read-TelephoneJsonlCompleteRecords -Path $EventsPath)
    } catch {
        $result.rejected = 'malformed_events'
        return $result
    }
    foreach ($record in $records) {
        if ($record -isnot [Collections.IDictionary]) { continue }
        $when = $null
        foreach ($key in @('timestamp', 'created_at', 'created_at_utc')) {
            if ($record.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$record[$key])) {
                try { $when = [DateTimeOffset]::Parse([string]$record[$key], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { $when = $null }
                if ($null -ne $when) { break }
            }
        }
        if ($null -ne $when -and $notBefore -ne [DateTimeOffset]::MinValue -and $when -lt $notBefore) {
            continue
        }
        $type = Get-TelephoneDictString -Dict $record -Key 'type'
        $payload = $null
        if ($record.Contains('payload') -and $record.payload -is [Collections.IDictionary]) { $payload = $record.payload }
        $payloadType = ''
        if ($null -ne $payload) { $payloadType = Get-TelephoneDictString -Dict $payload -Key 'type' }
        if ($type -ceq 'thread.started') {
            $id = Get-TelephoneDictString -Dict $record -Key 'thread_id'
            if ([string]::IsNullOrWhiteSpace($id)) { $id = Get-TelephoneDictString -Dict $record -Key 'session_id' }
            if ($id -cne $ExpectedSessionId) {
                $result.rejected = 'wrong_session'
                return $result
            }
            $result.thread_started = $true
        } elseif ($type -ceq 'turn.started') {
            if (-not [bool]$result.thread_started) { continue }
            $sess = Get-TelephoneDictString -Dict $record -Key 'session_id'
            if ([string]::IsNullOrWhiteSpace($sess) -and $null -ne $payload) { $sess = Get-TelephoneDictString -Dict $payload -Key 'session_id' }
            if (-not [string]::IsNullOrWhiteSpace($sess) -and $sess -cne $ExpectedSessionId) {
                $result.rejected = 'wrong_session'
                continue
            }
            $evtRun = Get-TelephoneDictString -Dict $record -Key 'run_id'
            if ([string]::IsNullOrWhiteSpace($evtRun) -and $null -ne $payload) { $evtRun = Get-TelephoneDictString -Dict $payload -Key 'run_id' }
            if (-not [string]::IsNullOrWhiteSpace($evtRun) -and -not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and $evtRun -cne $ExpectedRunId) {
                $result.rejected = 'wrong_run'
                continue
            }
            $turnId = Get-TelephoneDictString -Dict $record -Key 'turn_id'
            if ([string]::IsNullOrWhiteSpace($turnId) -and $null -ne $payload) { $turnId = Get-TelephoneDictString -Dict $payload -Key 'turn_id' }
            $result.turn_started = $true
            $result.current_turn_id = $turnId
        } elseif ($type -ceq 'turn.completed' -or $payloadType -ceq 'turn.completed' -or $payloadType -ceq 'task_complete') {
            if (-not [bool]$result.turn_started) {
                $result.rejected = 'complete_without_current_turn'
                continue
            }
            $turnId = Get-TelephoneDictString -Dict $record -Key 'turn_id'
            if ([string]::IsNullOrWhiteSpace($turnId) -and $null -ne $payload) { $turnId = Get-TelephoneDictString -Dict $payload -Key 'turn_id' }
            if (-not [string]::IsNullOrWhiteSpace([string]$result.current_turn_id) -and -not [string]::IsNullOrWhiteSpace($turnId) -and $turnId -cne [string]$result.current_turn_id) {
                $result.rejected = 'wrong_turn'
                continue
            }
            $sess = Get-TelephoneDictString -Dict $record -Key 'session_id'
            if ([string]::IsNullOrWhiteSpace($sess) -and $null -ne $payload) { $sess = Get-TelephoneDictString -Dict $payload -Key 'session_id' }
            if (-not [string]::IsNullOrWhiteSpace($sess) -and $sess -cne $ExpectedSessionId) {
                $result.rejected = 'wrong_session'
                continue
            }
            $evtRun = Get-TelephoneDictString -Dict $record -Key 'run_id'
            if ([string]::IsNullOrWhiteSpace($evtRun) -and $null -ne $payload) { $evtRun = Get-TelephoneDictString -Dict $payload -Key 'run_id' }
            if (-not [string]::IsNullOrWhiteSpace($evtRun) -and -not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and $evtRun -cne $ExpectedRunId) {
                $result.rejected = 'wrong_run'
                continue
            }
            $result.native_turn_complete = $true
            $result.complete_kind = $(if ($type -ceq 'turn.completed') { 'turn.completed' } else { $payloadType })
        }
    }
    return $result
}

function Get-TelephoneLeadRunLifecycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId,
        [Parameter(Mandatory = $true)][string]$ExpectedRunId
    )
    $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    $life = [ordered]@{
        protocol_version = 'telephone-line-run-lifecycle-v1'
        run_root = $root
        run_id = $ExpectedRunId
        session_id = $ExpectedSessionId
        binding_ok = $false
        owner_alive = $false
        owner = $null
        cli_child_alive = $false
        cli_child = $null
        host_terminal_present = $false
        host_terminal_exit_code = $null
        lead_final_present = $false
        native_turn_complete = $false
        process_exited = $false
        stdout_eof = $false
        stderr_eof = $false
        final_only = $false
        rejected = ''
        current_turn_id = ''
        complete_kind = ''
        created_at_utc = ''
    }
    $runMetaPath = Join-Path $root 'lead-run.json'
    $eventsPath = Join-Path $root 'codex-events.jsonl'
    $ownerPath = Join-Path $root 'owner.json'
    $hostOwnerPath = Join-Path $root 'host-owner.json'
    $childPath = Join-Path $root 'cli-child.json'
    $hostPath = Join-Path $root 'host-terminal.json'
    $finalPath = Join-Path $root 'lead-final.txt'
    $drainPath = Join-Path $root 'drain-lifecycle.json'
    $hostDrainPath = Join-Path $root 'host-drain-lifecycle.json'
    $cliDrainPath = Join-Path $root 'cli-drain-lifecycle.json'
    if (-not [IO.File]::Exists($runMetaPath)) {
        $life.rejected = 'missing_run_metadata'
        return $life
    }
    try {
        $runMeta = (Read-TelephoneJson -Path $runMetaPath).value
        $null = Test-TelephoneNativeLeadRunBinding -Run $runMeta -ExpectedSessionId $ExpectedSessionId -ExpectedRunId $ExpectedRunId -EventsPath $eventsPath
        $life.binding_ok = $true
        if ($runMeta -is [Collections.IDictionary] -and $runMeta.Contains('created_at_utc')) {
            $life.created_at_utc = [string]$runMeta.created_at_utc
        }
    } catch {
        $life.rejected = 'run_binding_mismatch'
        return $life
    }
    if ([IO.File]::Exists($ownerPath)) {
        try {
            $life.owner = (Read-TelephoneJson -Path $ownerPath).value
            $life.owner_alive = Test-TelephoneLeadOwnerIdentityAlive -Owner $life.owner
        } catch { }
    } elseif ([IO.File]::Exists($hostOwnerPath)) {
        try {
            $life.owner = (Read-TelephoneJson -Path $hostOwnerPath).value
            $life.owner_alive = Test-TelephoneLeadOwnerIdentityAlive -Owner $life.owner
        } catch { }
    }
    $independentHostOwner = $life.owner
    $independentCliChild = $null
    if ([IO.File]::Exists($childPath)) {
        try {
            $life.cli_child = (Read-TelephoneJson -Path $childPath).value
            $life.cli_child_alive = Test-TelephoneLeadOwnerIdentityAlive -Owner $life.cli_child
            $independentCliChild = $life.cli_child
        } catch { }
    } elseif ([IO.File]::Exists($cliDrainPath)) {
        try {
            $cliDrain = (Read-TelephoneJson -Path $cliDrainPath).value
            if ($cliDrain -is [Collections.IDictionary] -and (Test-TelephoneLeadWriterIdentityBound -Owner $cliDrain)) {
                $life.cli_child = $cliDrain
                $life.cli_child_alive = Test-TelephoneLeadOwnerIdentityAlive -Owner $cliDrain
            }
        } catch { }
    }
    if ([IO.File]::Exists($hostPath)) {
        try {
            $hostTerminalDoc = (Read-TelephoneJson -Path $hostPath).value
            if (Test-TelephoneLeadBoundHostTerminalRecord -Doc $hostTerminalDoc -SessionId $ExpectedSessionId -RunId $ExpectedRunId -ExpectedIdentity $life.owner) {
                $life.host_terminal_present = $true
                if ($hostTerminalDoc -is [Collections.IDictionary] -and $hostTerminalDoc.Contains('exit_code')) {
                    $life.host_terminal_exit_code = [int]$hostTerminalDoc.exit_code
                }
            }
        } catch { }
    }
    $life.lead_final_present = [IO.File]::Exists($finalPath)
    $native = Get-TelephoneLeadEventNativeTurn -EventsPath $eventsPath -ExpectedSessionId $ExpectedSessionId -ExpectedRunId $ExpectedRunId -NotBeforeUtc ([string]$life.created_at_utc)
    if (-not [string]::IsNullOrWhiteSpace([string]$native.rejected)) { $life.rejected = [string]$native.rejected }
    $life.native_turn_complete = [bool]$native.native_turn_complete
    $life.current_turn_id = [string]$native.current_turn_id
    $life.complete_kind = [string]$native.complete_kind
    $hostDrain = $null
    $hostDrainSidecarPresent = $false
    foreach ($path in @($hostDrainPath, $drainPath)) {
        if (-not [IO.File]::Exists($path)) { continue }
        $hostDrainSidecarPresent = $true
        try {
            $candidate = (Read-TelephoneJson -Path $path).value
            if ($candidate -isnot [Collections.IDictionary]) { continue }
            if (-not (Test-TelephoneLeadDrainMatchesIndependentProducer -Doc $candidate -ExpectedIdentity $independentHostOwner -SessionId $ExpectedSessionId -RunId $ExpectedRunId -ExpectedRole 'host')) {
                continue
            }
            $hostDrain = $candidate
            break
        } catch { }
    }
    if ($null -ne $hostDrain -and $hostDrain -is [Collections.IDictionary]) {
        if ($hostDrain.Contains('process_exited')) { $life.process_exited = [bool]$hostDrain.process_exited }
        if ($hostDrain.Contains('stdout_eof')) { $life.stdout_eof = [bool]$hostDrain.stdout_eof }
        if ($hostDrain.Contains('stderr_eof')) { $life.stderr_eof = [bool]$hostDrain.stderr_eof }
        if ($hostDrain.Contains('native_turn_complete') -and [bool]$hostDrain['native_turn_complete']) {
            $life.native_turn_complete = $true
        }
        if ($null -eq $life.owner -and (Test-TelephoneLeadWriterIdentityBound -Owner $hostDrain)) {
            $life.owner = $hostDrain
            $life.owner_alive = Test-TelephoneLeadOwnerIdentityAlive -Owner $hostDrain
        }
    } elseif (-not $hostDrainSidecarPresent -and [IO.File]::Exists($cliDrainPath)) {
        try {
            $cliOnly = (Read-TelephoneJson -Path $cliDrainPath).value
            if ($cliOnly -is [Collections.IDictionary] -and (Test-TelephoneLeadDrainMatchesIndependentProducer -Doc $cliOnly -ExpectedIdentity $independentCliChild -SessionId $ExpectedSessionId -RunId $ExpectedRunId -ExpectedRole 'cli')) {
                if ($cliOnly.Contains('process_exited')) { $life.process_exited = [bool]$cliOnly.process_exited }
                if ($cliOnly.Contains('stdout_eof')) { $life.stdout_eof = [bool]$cliOnly.stdout_eof }
                if ($cliOnly.Contains('stderr_eof')) { $life.stderr_eof = [bool]$cliOnly.stderr_eof }
                if ($cliOnly.Contains('native_turn_complete') -and [bool]$cliOnly['native_turn_complete']) {
                    $life.native_turn_complete = $true
                }
            }
        } catch { }
    }
    if ([bool]$life.lead_final_present -and -not [bool]$life.native_turn_complete) {
        $life.final_only = $true
    }
    return $life
}

function Stop-TelephoneLeadExactOwnedIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Identity,
        [int]$WaitGoneMilliseconds = 2000
    )
    $record = [ordered]@{
        attempted = $false
        stopped = $false
        refused = ''
        observation = $null
        target = $null
    }
    $obs = Get-TelephoneLeadOwnerIdentityObservation -Owner $Identity
    $record.observation = $obs
    if ([string]$obs.status -ceq 'query_error') {
        $record.refused = 'owner_query_error'
        return $record
    }
    if ([string]$obs.status -cne 'alive' -or $null -eq $obs.snapshot) {
        $record.refused = $(if ([string]$obs.status -ceq 'mismatch') { 'pid_reuse_or_exe_mismatch' } else { 'owner_not_alive' })
        return $record
    }
    $expected = [ordered]@{
        pid = $(if ($Identity -is [Collections.IDictionary] -and $Identity.Contains('pid')) { [int]$Identity.pid } elseif ($Identity -is [Collections.IDictionary] -and $Identity.Contains('target_pid')) { [int]$Identity.target_pid } else { 0 })
        start_time_utc_ticks = $(if ($Identity -is [Collections.IDictionary] -and $Identity.Contains('start_time_utc_ticks')) { [int64]$Identity.start_time_utc_ticks } else { [int64]0 })
        executable_path = $(if ($Identity -is [Collections.IDictionary] -and $Identity.Contains('executable_path')) { [string]$Identity.executable_path } else { '' })
    }
    $record.attempted = $true
    $record.target = $obs.snapshot
    $exeNow = ''
    try {
        if ($obs.snapshot -is [Collections.IDictionary] -and $obs.snapshot.Contains('executable_path')) {
            $exeNow = [string]$obs.snapshot['executable_path']
        }
    } catch { $exeNow = '' }
    if (Test-TelephoneLeadSharedCodexAppExecutable -Path $exeNow) {
        $record.refused = 'shared_codex_app'
        return $record
    }
    try {
        $againObs = Get-TelephoneLeadOwnerIdentityObservation -Owner $Identity
        if ([string]$againObs.status -ceq 'query_error') {
            $record.refused = 'owner_query_error'
            return $record
        }
        if ([string]$againObs.status -cne 'alive' -or $null -eq $againObs.snapshot -or -not (Test-TelephoneLeadProcessIdentityMatch -Expected $expected -Actual $againObs.snapshot)) {
            $record.refused = 'identity_changed_before_stop'
            return $record
        }
        $descendants = Get-TelephoneLeadOwnedDescendantObservation -Identity $againObs.snapshot
        $record.descendant_observation = $descendants
        if ([string]$descendants.status -ceq 'query_error' -or [string]$descendants.refused -ceq 'descendant_query_error') {
            $record.refused = 'descendant_query_error'
            return $record
        }
        if ([string]$descendants.status -ceq 'active_descendant' -or $descendants.children.Count -gt 0) {
            $record.refused = 'active_descendant'
            return $record
        }
        # Keep a handle to the exact target across the final identity check and
        # termination, so a PID reused after the descendant census is not killed.
        $targetProcess = Get-Process -Id ([int]$againObs.snapshot.pid) -ErrorAction Stop
        try {
            $null = $targetProcess.Handle
            if ($targetProcess.StartTime.ToUniversalTime().Ticks -ne [int64]$expected.start_time_utc_ticks) {
                $record.refused = 'identity_changed_before_stop'
                return $record
            }
            $targetProcess.Kill()
        } finally {
            $targetProcess.Dispose()
        }
        $goneDeadline = [DateTimeOffset]::UtcNow.AddMilliseconds([Math]::Max(1, [int]$WaitGoneMilliseconds))
        $gone = $false
        do {
            $after = Get-TelephoneLeadOwnerIdentityObservation -Owner $Identity
            if ([string]$after.status -ceq 'query_error') {
                $record.refused = 'owner_query_error_after_stop'
                return $record
            }
            if ([string]$after.status -ceq 'not_found' -or [string]$after.status -ceq 'mismatch') {
                $gone = $true
                break
            }
            Start-Sleep -Milliseconds 50
        } while ([DateTimeOffset]::UtcNow -lt $goneDeadline)
        if (-not $gone) {
            $record.refused = 'owner_still_alive_after_stop'
            return $record
        }
        $record.stopped = $true
    } catch {
        $record.refused = 'stop_failed'
    }
    return $record
}

function Stop-TelephoneLeadCompletedOwnProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId,
        [Parameter(Mandatory = $true)][string]$ExpectedRunId,
        [int]$DrainWaitMilliseconds = 20000
    )
    $record = [ordered]@{
        protocol_version = 'telephone-line-completed-own-process-recovery-v1'
        attempted = $false
        recovered = $false
        refused = ''
        target = $null
        child_stop = $null
        host_stop = $null
        drain = $null
        measured_os_exit_code = $null
        stdout_eof = $false
        stderr_eof = $false
        drain_pending = $true
        provider_replayed = $false
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if ($Lifecycle -isnot [Collections.IDictionary]) {
        $record.refused = 'missing_lifecycle'
        return $record
    }
    if ([string]$Lifecycle.session_id -cne $ExpectedSessionId -or [string]$Lifecycle.run_id -cne $ExpectedRunId) {
        $record.refused = 'wrong_session_or_run'
        return $record
    }
    if (-not [bool]$Lifecycle.binding_ok) {
        $record.refused = 'binding_not_ok'
        return $record
    }
    if (-not [bool]$Lifecycle.native_turn_complete) {
        $record.refused = 'native_turn_not_complete'
        return $record
    }
    if ([bool]$Lifecycle.final_only -and -not [bool]$Lifecycle.native_turn_complete) {
        $record.refused = 'final_only'
        return $record
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Lifecycle.rejected) -and [string]$Lifecycle.rejected -cin @('wrong_session', 'wrong_turn', 'wrong_run', 'complete_without_current_turn')) {
        $record.refused = [string]$Lifecycle.rejected
        return $record
    }
    $runRoot = ''
    if ($Lifecycle.Contains('run_root')) { $runRoot = [string]$Lifecycle['run_root'] }
    if (-not [string]::IsNullOrWhiteSpace($runRoot) -and (Test-TelephoneLeadCallbackQueueStillOpen -RunRoot $runRoot)) {
        $record.refused = 'queued_callback'
        Write-TelephoneLeadOwnedRecoveryRecord -RunRoot $runRoot -Record $record
        return $record
    }
    $child = $null
    if ($Lifecycle.Contains('cli_child')) { $child = $Lifecycle.cli_child }
    if ($null -ne $child) {
        $childObs = Get-TelephoneLeadOwnerIdentityObservation -Owner $child
        if ([string]$childObs.status -ceq 'query_error') {
            $record.refused = 'owner_query_error'
            Write-TelephoneLeadOwnedRecoveryRecord -RunRoot $runRoot -Record $record
            return $record
        }
        if ([string]$childObs.status -ceq 'mismatch') {
            $record.refused = 'pid_reuse_or_exe_mismatch'
            Write-TelephoneLeadOwnedRecoveryRecord -RunRoot $runRoot -Record $record
            return $record
        }
    }
    $owner = $Lifecycle.owner
    $ownerObs = Get-TelephoneLeadOwnerIdentityObservation -Owner $owner
    if ([string]$ownerObs.status -ceq 'query_error') {
        $record.refused = 'owner_query_error'
        Write-TelephoneLeadOwnedRecoveryRecord -RunRoot $runRoot -Record $record
        return $record
    }
    if ([string]$ownerObs.status -ceq 'mismatch') {
        $record.refused = 'pid_reuse_or_exe_mismatch'
        Write-TelephoneLeadOwnedRecoveryRecord -RunRoot $runRoot -Record $record
        return $record
    }
    if (-not [string]::IsNullOrWhiteSpace($runRoot) -and -not (Test-TelephoneLeadOwnedDrainRecordsPresent -RunRoot $runRoot)) {
        $record.recovered = $false
        $record.drain_pending = $true
        $record.refused = 'drain_records_absent'
        Write-TelephoneLeadOwnedRecoveryRecord -RunRoot $runRoot -Record $record
        return $record
    }
    if ([string]::IsNullOrWhiteSpace($runRoot)) {
        $record.recovered = $false
        $record.drain_pending = $true
        $record.refused = 'drain_records_absent'
        return $record
    }
    $waitMs = [int]$DrainWaitMilliseconds
    if ([string]$ownerObs.status -ceq 'alive') { $waitMs = 0 }
    $drain = Wait-TelephoneLeadOwnedDrainTerminal -RunRoot $runRoot -WaitMilliseconds 0
    if ($null -ne $drain -and $drain -is [Collections.IDictionary] -and [bool]$drain.pending -and $waitMs -gt 0 -and -not [bool]$drain.host_alive -and -not [bool]$drain.reader_ready) {
        $drain = Wait-TelephoneLeadOwnedDrainTerminal -RunRoot $runRoot -WaitMilliseconds $waitMs
    }
    $record.drain = $drain
    if ($null -ne $drain -and $drain -is [Collections.IDictionary]) {
        if ($drain.Contains('pending')) { $record.drain_pending = [bool]$drain['pending'] }
        if ($drain.Contains('stdout_eof')) { $record.stdout_eof = [bool]$drain['stdout_eof'] }
        if ($drain.Contains('stderr_eof')) { $record.stderr_eof = [bool]$drain['stderr_eof'] }
        if ($drain.Contains('measured_os_exit_code') -and $null -ne $drain['measured_os_exit_code']) {
            $record.measured_os_exit_code = [int]$drain['measured_os_exit_code']
        }
        $hostAlive = $false
        $hostTerminal = $false
        $childTerminal = $false
        $pending = $true
        if ($drain.Contains('host_alive')) { $hostAlive = [bool]$drain['host_alive'] }
        if ($drain.Contains('host_terminal')) { $hostTerminal = [bool]$drain['host_terminal'] }
        if ($drain.Contains('child_terminal')) { $childTerminal = [bool]$drain['child_terminal'] }
        if ($drain.Contains('pending')) { $pending = [bool]$drain['pending'] }
        if ($hostAlive -or $pending -or -not $hostTerminal) {
            $record.recovered = $false
            $record.drain_pending = $true
            if ([bool]$drain.reader_ready) { $record.refused = 'reader_ready' }
        } elseif ($hostTerminal -and $childTerminal -and -not $pending -and [bool]$record.stdout_eof -and [bool]$record.stderr_eof -and $null -ne $record.measured_os_exit_code) {
            $record.recovered = $true
            $record.drain_pending = $false
        }
    }
    if (-not [bool]$record.recovered -and [string]::IsNullOrWhiteSpace([string]$record.refused)) {
        $record.refused = 'drain_pending'
        $record.drain_pending = $true
    }
    Write-TelephoneLeadOwnedRecoveryRecord -RunRoot $runRoot -Record $record
    return $record
}

function Reconcile-TelephoneLeadCompletedOwnedResidue {
    [CmdletBinding()]
    param(
        [string]$LeadStateRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId,
        [string]$ExpectedRunId = ''
    )
    $result = [ordered]@{
        protocol_version = 'telephone-line-completed-owned-residue-reconcile-v1'
        lead_state_root = ''
        session_id = [string]$ExpectedSessionId
        scanned = 0
        recovered = 0
        skipped_foreign = 0
        skipped_active = 0
        refused = [Collections.Generic.List[object]]::new()
        pending = [Collections.Generic.List[object]]::new()
        recovered_runs = [Collections.Generic.List[object]]::new()
        provider_replayed = $false
        persist_path = ''
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if ([string]::IsNullOrWhiteSpace($LeadStateRoot) -or -not [IO.Directory]::Exists($LeadStateRoot)) {
        $result.refused.Add([ordered]@{ reason = 'lead_state_root_missing' })
        return $result
    }
    $rootBase = [IO.Path]::GetFullPath($LeadStateRoot).TrimEnd('\')
    $result.lead_state_root = $rootBase
    $candidates = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId)) {
        $one = Join-Path $rootBase $ExpectedRunId
        if ([IO.Directory]::Exists($one)) { [void]$candidates.Add($one) }
    } else {
        foreach ($dir in @([IO.Directory]::GetDirectories($rootBase))) {
            if ([IO.File]::Exists((Join-Path $dir 'lead-run.json'))) { [void]$candidates.Add($dir) }
        }
    }
    foreach ($runRoot in @($candidates)) {
        $runId = [IO.Path]::GetFileName($runRoot)
        if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and $runId -cne $ExpectedRunId) { continue }
        $result.scanned += 1
        $life = $null
        try {
            $life = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $ExpectedSessionId -ExpectedRunId $runId
        } catch {
            [void]$result.refused.Add([ordered]@{ run_id = $runId; reason = 'lifecycle_read_failed' })
            continue
        }
        if (-not [bool]$life.binding_ok) {
            $rej = [string]$life.rejected
            if ($rej -cin @('wrong_session', 'run_binding_mismatch', 'foreign_session')) {
                $result.skipped_foreign += 1
            } else {
                [void]$result.refused.Add([ordered]@{ run_id = $runId; reason = $(if ([string]::IsNullOrWhiteSpace($rej)) { 'binding_not_ok' } else { $rej }) })
            }
            continue
        }
        if (-not [bool]$life.native_turn_complete) {
            $result.skipped_active += 1
            continue
        }
        if (Test-TelephoneLeadCallbackQueueStillOpen -RunRoot $runRoot) {
            $result.skipped_active += 1
            continue
        }
        $ownerObsAuto = Get-TelephoneLeadOwnerIdentityObservation -Owner $life.owner
        if ([string]$ownerObsAuto.status -ceq 'mismatch') {
            [void]$result.refused.Add([ordered]@{
                run_id = $runId
                run_root = $runRoot
                session_id = [string]$ExpectedSessionId
                reason = 'pid_reuse_or_exe_mismatch'
                attempted = $false
                recovered = $false
            })
            continue
        }
        if ([string]$ownerObsAuto.status -ceq 'query_error') {
            [void]$result.refused.Add([ordered]@{
                run_id = $runId
                run_root = $runRoot
                session_id = [string]$ExpectedSessionId
                reason = 'owner_query_error'
                attempted = $false
                recovered = $false
            })
            [void]$result.pending.Add([ordered]@{
                run_id = $runId
                session_id = [string]$ExpectedSessionId
                identity_status = 'owner_query_error'
                reason = 'owner_query_error'
            })
            continue
        }
        if ($null -ne $life.cli_child) {
            $childObsAuto = Get-TelephoneLeadOwnerIdentityObservation -Owner $life.cli_child
            if ([string]$childObsAuto.status -ceq 'mismatch') {
                [void]$result.refused.Add([ordered]@{
                    run_id = $runId
                    run_root = $runRoot
                    session_id = [string]$ExpectedSessionId
                    reason = 'pid_reuse_or_exe_mismatch'
                    attempted = $false
                    recovered = $false
                })
                continue
            }
        }
        $recovery = $null
        if ([bool]$life.owner_alive -or [bool]$life.cli_child_alive) {
            $recovery = Stop-TelephoneLeadCompletedOwnProcess -Lifecycle $life -ExpectedSessionId $ExpectedSessionId -ExpectedRunId $runId -DrainWaitMilliseconds 0
            if ([bool]$recovery.recovered -and -not [bool]$recovery.drain_pending) {
                $result.recovered += 1
                [void]$result.recovered_runs.Add([ordered]@{
                    run_id = $runId
                    run_root = $runRoot
                    session_id = [string]$ExpectedSessionId
                    refused = [string]$recovery.refused
                    drain_pending = [bool]$recovery.drain_pending
                    stdout_eof = [bool]$recovery.stdout_eof
                    stderr_eof = [bool]$recovery.stderr_eof
                    measured_os_exit_code = $(if ($null -ne $recovery.measured_os_exit_code) { [int]$recovery.measured_os_exit_code } else { $null })
                    provider_replayed = $false
                })
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$recovery.refused)) {
                [void]$result.refused.Add([ordered]@{
                    run_id = $runId
                    run_root = $runRoot
                    session_id = [string]$ExpectedSessionId
                    reason = [string]$recovery.refused
                    attempted = [bool]$recovery.attempted
                    recovered = $false
                })
                if ([string]$recovery.refused -cin @('active_descendant', 'descendant_query_error', 'owner_query_error', 'pid_reuse_or_exe_mismatch', 'reader_ready', 'drain_pending')) {
                    [void]$result.pending.Add([ordered]@{
                        run_id = $runId
                        session_id = [string]$ExpectedSessionId
                        identity_status = [string]$recovery.refused
                        host_alive = [bool]$life.owner_alive
                        child_alive = [bool]$life.cli_child_alive
                        reason = [string]$recovery.refused
                    })
                }
            }
        }
        $drain = $null
        if ($null -ne $recovery -and $null -ne $recovery.drain) {
            $drain = $recovery.drain
        } else {
            $drain = Wait-TelephoneLeadOwnedDrainTerminal -RunRoot $runRoot -WaitMilliseconds 0
        }
        if ($null -ne $drain -and $drain -is [Collections.IDictionary] -and [bool]$drain.pending) {
            [void]$result.pending.Add([ordered]@{
                run_id = $runId
                session_id = [string]$ExpectedSessionId
                identity_status = [string]$drain.identity_status
                host_alive = [bool]$drain.host_alive
                child_alive = [bool]$drain.child_alive
                process_exited = [bool]$drain.process_exited
                stdout_eof = $(if ($drain.Contains('stdout_eof')) { [bool]$drain.stdout_eof } else { $false })
                stderr_eof = $(if ($drain.Contains('stderr_eof')) { [bool]$drain.stderr_eof } else { $false })
                measured_os_exit_code = $(if ($drain.Contains('measured_os_exit_code')) { $drain.measured_os_exit_code } else { $null })
                reason = 'drain_pending'
            })
        }
    }
    $persist = ConvertTo-TelephonePersistableRecord -Value $result
    $persistName = 'session-residue-reconcile-' + ([string]$ExpectedSessionId).ToLowerInvariant() + '.json'
    $persistPath = Join-Path $rootBase $persistName
    $result.persist_path = $persistPath
    $persist['persist_path'] = $persistPath
    try {
        if ([IO.File]::Exists($persistPath)) { $null = Write-TelephoneJsonReplace -Path $persistPath -Value $persist }
        else { $null = Write-TelephoneJsonCreateNew -Path $persistPath -Value $persist }
    } catch {
        try { $null = Write-TelephoneJsonReplace -Path $persistPath -Value $persist } catch { }
    }
    return $result
}

function New-TelephoneLeadLaunchFromRunRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$State
    )
    return [ordered]@{
        run_id = $RunId
        run_root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
        state = $State
    }
}

function Invoke-TelephoneLeadWakeReconcile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LaunchResultPath,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [object[]]$ExtraArguments,
        [string]$Worktree = '',
        [string]$DiagnosticPath = ''
    )
    $result = [ordered]@{
        protocol_version = 'telephone-line-wake-reconcile-v1'
        decision = 'ambiguous'
        error_code = 'LEAD_WAKE_AMBIGUOUS'
        launch = $null
        lifecycle = $null
        recovery = $null
        reason = ''
    }
    $stateRoot = Get-TelephoneLeadNamedArgumentValue -Arguments $ExtraArguments -Name 'StateRootOverride'
    if ([string]::IsNullOrWhiteSpace($stateRoot) -and -not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_LEAD_STATE_ROOT)) {
        $stateRoot = [string]$env:TELEPHONE_LINE_LEAD_STATE_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($stateRoot)) {
        $result.reason = 'no_state_root_hint'
        return $result
    }
    $runRoot = [IO.Path]::GetFullPath((Join-Path $stateRoot $RunId)).TrimEnd('\')
    if (-not [IO.Directory]::Exists($runRoot)) {
        $result.reason = 'run_root_missing'
        return $result
    }
    if (-not [string]::IsNullOrWhiteSpace($Worktree)) {
        $runMetaPath = Join-Path $runRoot 'lead-run.json'
        if ([IO.File]::Exists($runMetaPath)) {
            try {
                $runMeta = (Read-TelephoneJson -Path $runMetaPath).value
                $boundTree = ''
                if ($runMeta -is [Collections.IDictionary] -and $runMeta.Contains('worktree')) { $boundTree = [string]$runMeta.worktree }
                if (-not [string]::IsNullOrWhiteSpace($boundTree) -and -not [string]::Equals([IO.Path]::GetFullPath($boundTree).TrimEnd('\'), [IO.Path]::GetFullPath($Worktree).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
                    $result.reason = 'worktree_mismatch'
                    return $result
                }
            } catch { }
        }
    }
    $life = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $SessionId -ExpectedRunId $RunId
    $result.lifecycle = $life
    if (-not [bool]$life.binding_ok) {
        $result.reason = $(if ([string]::IsNullOrWhiteSpace([string]$life.rejected)) { 'binding_not_ok' } else { [string]$life.rejected })
        return $result
    }
    if ([bool]$life.owner_alive) {
        if ([bool]$life.native_turn_complete -and ([bool]$life.owner_alive -or [bool]$life.cli_child_alive)) {
            $recovery = Stop-TelephoneLeadCompletedOwnProcess -Lifecycle $life -ExpectedSessionId $SessionId -ExpectedRunId $RunId -DrainWaitMilliseconds 0
            $result.recovery = $recovery
            $life = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $SessionId -ExpectedRunId $RunId
            $result.lifecycle = $life
            if ([bool]$recovery.recovered -and [bool]$life.host_terminal_present -and -not [bool]$recovery.drain_pending) {
                $result.decision = 'recovered_attach'
                $result.error_code = ''
                $result.launch = New-TelephoneLeadLaunchFromRunRoot -RunRoot $runRoot -RunId $RunId -State 'recovered'
                $result.reason = 'recovered'
                return $result
            }
            if ([bool]$life.owner_alive -or [bool]$recovery.drain_pending -or [string]$recovery.refused -ceq 'reader_ready') {
                $result.decision = 'attached'
                $result.error_code = ''
                $result.launch = New-TelephoneLeadLaunchFromRunRoot -RunRoot $runRoot -RunId $RunId -State 'reader_ready_host_pending'
                $result.reason = 'reader_ready_host_pending'
                return $result
            }
        }
        $life = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $SessionId -ExpectedRunId $RunId
        $result.lifecycle = $life
    }
    if ([bool]$life.host_terminal_present) {
        $result.decision = 'attached'
        $result.error_code = ''
        $result.launch = New-TelephoneLeadLaunchFromRunRoot -RunRoot $runRoot -RunId $RunId -State 'attached_existing_terminal'
        $result.reason = 'host_terminal'
        return $result
    }
    if ([bool]$life.native_turn_complete) {
        $result.decision = 'recovered_attach'
        $result.error_code = ''
        $result.launch = New-TelephoneLeadLaunchFromRunRoot -RunRoot $runRoot -RunId $RunId -State 'recovered_native_complete_host_incomplete'
        $result.reason = 'native_complete_no_host_terminal'
        if (-not [string]::IsNullOrWhiteSpace($DiagnosticPath)) {
            $diag = [ordered]@{
                protocol_version = 'telephone-line-wake-reconcile-v1'
                decision = [string]$result.decision
                reason = [string]$result.reason
                run_id = $RunId
                session_id = $SessionId
                native_turn_complete = $true
                host_terminal_present = $false
                process_exited = [bool]$life.process_exited
                stdout_eof = [bool]$life.stdout_eof
                stderr_eof = [bool]$life.stderr_eof
                current_turn_id = [string]$life.current_turn_id
                recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            }
            try { $null = Write-TelephoneJsonCreateNew -Path $DiagnosticPath -Value $diag } catch [IO.IOException] { }
        }
        return $result
    }
    if ([bool]$life.final_only) {
        $result.reason = 'final_only'
        $result.error_code = 'LEAD_WAKE_AMBIGUOUS'
        return $result
    }
    $result.reason = $(if ([string]::IsNullOrWhiteSpace([string]$life.rejected)) { 'incomplete_wake' } else { [string]$life.rejected })
    return $result
}

function Copy-TelephoneLeadExtraArgumentsWithCli {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Executable
    )
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return @('-CodexCommand', $Executable) }
    $copy = [Collections.Generic.List[object]]::new()
    $replaced = $false
    for ($index = 0; $index -lt $Arguments.Count; $index += 2) {
        $name = [string]$Arguments[$index]
        $value = [string]$Arguments[$index + 1]
        if ($name -ceq '-CodexCommand') {
            $value = $Executable
            $replaced = $true
        }
        [void]$copy.Add($name)
        [void]$copy.Add($value)
    }
    if (-not $replaced) {
        [void]$copy.Add('-CodexCommand')
        [void]$copy.Add($Executable)
    }
    return @($copy)
}

function Get-TelephoneLeadLanguageMode {
    [CmdletBinding()]
    param()
    try { return [string]$ExecutionContext.SessionState.LanguageMode } catch { return '' }
}

function Set-TelephoneLastLeadLaunchDiagnostic {
    [CmdletBinding()]
    param([AllowNull()][object]$Diagnostic)
    $script:TelephoneLastLeadLaunchDiagnostic = $Diagnostic
}

function Get-TelephoneLastLeadLaunchDiagnostic {
    [CmdletBinding()]
    param()
    if ($null -eq $script:TelephoneLastLeadLaunchDiagnostic) { return $null }
    return $script:TelephoneLastLeadLaunchDiagnostic
}

function New-TelephoneLeadLaunchDiagnostic {
    [CmdletBinding()]
    param(
        [string]$Code = 'LEAD_WAKE_FAILED',
        [string]$Executable = '',
        [string]$WorkingDirectory = '',
        [AllowNull()][object]$Captured = $null,
        [string]$CreateProcessError = '',
        [string]$RunId = '',
        [string]$SessionId = '',
        [string]$RunRoot = '',
        [int]$Win32Error = 0
    )
    $stderr = ''
    $stdout = ''
    $exitCode = $null
    $processExited = $false
    $stdoutEof = $false
    $stderrEof = $false
    $pidValue = 0
    $ticks = 0
    $started = ''
    $nativeTurn = $false
    if ($null -ne $Captured) {
        if ($Captured -is [Collections.IDictionary]) {
            if ($Captured.Contains('stderr')) { $stderr = [string]$Captured['stderr'] }
            if ($Captured.Contains('stdout')) { $stdout = [string]$Captured['stdout'] }
            if ($Captured.Contains('exit_code')) { $exitCode = [int]$Captured['exit_code'] }
            if ($Captured.Contains('process_exited')) { $processExited = [bool]$Captured['process_exited'] }
            if ($Captured.Contains('stdout_eof')) { $stdoutEof = [bool]$Captured['stdout_eof'] }
            if ($Captured.Contains('stderr_eof')) { $stderrEof = [bool]$Captured['stderr_eof'] }
            if ($Captured.Contains('pid')) { $pidValue = [int]$Captured['pid'] }
            if ($Captured.Contains('start_time_utc_ticks')) { $ticks = [int64]$Captured['start_time_utc_ticks'] }
            if ($Captured.Contains('started_at_utc')) { $started = [string]$Captured['started_at_utc'] }
            if ($Captured.Contains('executable_path') -and [string]::IsNullOrWhiteSpace($Executable)) { $Executable = [string]$Captured['executable_path'] }
            if ($Captured.Contains('native_turn_complete')) { $nativeTurn = [bool]$Captured['native_turn_complete'] }
        } else {
            try { $stderr = [string]$Captured.stderr } catch { }
            try { $stdout = [string]$Captured.stdout } catch { }
            try { $exitCode = [int]$Captured.exit_code } catch { }
            try { $processExited = [bool]$Captured.process_exited } catch { }
            try { $stdoutEof = [bool]$Captured.stdout_eof } catch { }
            try { $stderrEof = [bool]$Captured.stderr_eof } catch { }
            try { $pidValue = [int]$Captured.pid } catch { }
            try { $ticks = [int64]$Captured.start_time_utc_ticks } catch { }
            try { $started = [string]$Captured.started_at_utc } catch { }
        }
    }
    $stdoutPreview = $(if ([string]$stdout.Length -gt 2048) { [string]$stdout.Substring(0, 2048) } else { [string]$stdout })
    $createError = [string]$CreateProcessError
    if (Get-Command -Name Get-TelephoneSanitizedMessage -ErrorAction SilentlyContinue) {
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { $stderr = Get-TelephoneSanitizedMessage -Message $stderr }
        if (-not [string]::IsNullOrWhiteSpace($stdoutPreview)) { $stdoutPreview = Get-TelephoneSanitizedMessage -Message $stdoutPreview }
        if (-not [string]::IsNullOrWhiteSpace($createError)) { $createError = Get-TelephoneSanitizedMessage -Message $createError }
    }
    return [ordered]@{
        protocol_version = 'telephone-line-lead-launch-diagnostic-v1'
        error_code = [string]$Code
        language_mode = Get-TelephoneLeadLanguageMode
        executable = [string]$Executable
        working_directory = [string]$WorkingDirectory
        create_process_error = [string]$createError
        win32_error = [int]$Win32Error
        process_exited = [bool]$processExited
        native_turn_complete = [bool]$nativeTurn
        stdout_eof = [bool]$stdoutEof
        stderr_eof = [bool]$stderrEof
        exit_code = $exitCode
        pid = [int]$pidValue
        start_time_utc_ticks = [int64]$ticks
        started_at_utc = [string]$started
        run_id = [string]$RunId
        session_id = [string]$SessionId
        run_root = [string]$RunRoot
        stderr = [string]$stderr
        stdout_preview = [string]$stdoutPreview
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Test-TelephoneLeadActiveWriterStderr {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)
    $raw = [string]$Text
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    return (($raw -match '(?i)thread-store conflict') -and ($raw -match '(?i)already has an active writer'))
}

function Test-TelephoneLeadWriterIdentityBound {
    [CmdletBinding()]
    param([AllowNull()][object]$Owner)
    if ($null -eq $Owner) { return $false }
    $pidValue = 0
    $ticks = [int64]0
    $exe = ''
    if ($Owner -is [Collections.IDictionary]) {
        if ($Owner.Contains('pid')) { try { $pidValue = [int]$Owner['pid'] } catch { $pidValue = 0 } }
        if ($Owner.Contains('start_time_utc_ticks')) { try { $ticks = [int64]$Owner['start_time_utc_ticks'] } catch { $ticks = 0 } }
        if ($Owner.Contains('executable_path')) { $exe = [string]$Owner['executable_path'] }
    } else {
        try { $pidValue = [int]$Owner.pid } catch { $pidValue = 0 }
        try { $ticks = [int64]$Owner.start_time_utc_ticks } catch { $ticks = 0 }
        try { $exe = [string]$Owner.executable_path } catch { $exe = '' }
    }
    return ($pidValue -gt 0 -and $ticks -gt 0 -and -not [string]::IsNullOrWhiteSpace($exe))
}

function Read-TelephoneLeadDurableWriterRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$ExpectedPid = 0,
        [string]$ExpectedSessionId = '',
        [string]$ExpectedRunId = '',
        [switch]$RequireSessionRun,
        [switch]$AllowDifferentRunId
    )
    if (-not [IO.File]::Exists($Path)) { return $null }
    try {
        $doc = (Read-TelephoneJson -Path $Path).value
        if ($doc -isnot [Collections.IDictionary]) { return $null }
        if (-not (Test-TelephoneLeadWriterIdentityBound -Owner $doc)) { return $null }
        if ($ExpectedPid -gt 0 -and [int]$doc['pid'] -ne $ExpectedPid) { return $null }
        $session = $(if ($doc.Contains('session_id')) { [string]$doc['session_id'] } else { '' })
        $run = $(if ($doc.Contains('run_id')) { [string]$doc['run_id'] } else { '' })
        if ($RequireSessionRun -or -not [string]::IsNullOrWhiteSpace($ExpectedSessionId) -or -not [string]::IsNullOrWhiteSpace($ExpectedRunId)) {
            if ([string]::IsNullOrWhiteSpace($session) -or [string]::IsNullOrWhiteSpace($run)) { return $null }
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSessionId) -and $session -cne $ExpectedSessionId) { return $null }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and -not $AllowDifferentRunId -and $run -cne $ExpectedRunId) { return $null }
        if ($AllowDifferentRunId -and -not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and $run -ceq $ExpectedRunId) { return $null }
        $live = Get-TelephoneLeadProcessSnapshot -ProcessId ([int]$doc['pid'])
        if ($null -ne $live) {
            $expected = [ordered]@{
                pid = [int]$doc['pid']
                start_time_utc_ticks = [int64]$doc['start_time_utc_ticks']
                executable_path = [string]$doc['executable_path']
            }
            if (-not (Test-TelephoneLeadProcessIdentityMatch -Expected $expected -Actual $live)) {
                return $null
            }
        }
        return [ordered]@{
            pid = [int]$doc['pid']
            start_time_utc_ticks = [int64]$doc['start_time_utc_ticks']
            started_at_utc = $(if ($doc.Contains('started_at_utc')) { [string]$doc['started_at_utc'] } else { '' })
            executable_path = [string]$doc['executable_path']
            session_id = $session
            run_id = $run
            source = [IO.Path]::GetFileName($Path)
            source_path = [IO.Path]::GetFullPath($Path)
        }
    } catch {
        return $null
    }
}

function Get-TelephoneLeadRejectedAttemptPids {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RunRoot)
    $pids = [Collections.Generic.HashSet[int]]::new()
    foreach ($name in @('host-drain-lifecycle.json', 'drain-lifecycle.json', 'host-owner.json', 'owner.json')) {
        $path = Join-Path $RunRoot $name
        if (-not [IO.File]::Exists($path)) { continue }
        try {
            $doc = (Read-TelephoneJson -Path $path).value
            if ($doc -is [Collections.IDictionary] -and $doc.Contains('pid')) {
                $pidValue = 0
                try { $pidValue = [int]$doc['pid'] } catch { $pidValue = 0 }
                if ($pidValue -gt 0) { [void]$pids.Add($pidValue) }
            }
        } catch { }
    }
    return @($pids)
}

function Find-TelephoneLeadPriorSessionWriter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FailedRunRoot,
        [string]$ExpectedSessionId = '',
        [string]$FailedRunId = '',
        [int[]]$RejectedPids = @()
    )
    if ([string]::IsNullOrWhiteSpace($ExpectedSessionId)) { return $null }
    $failed = [IO.Path]::GetFullPath($FailedRunRoot).TrimEnd('\')
    $parent = [IO.Path]::GetDirectoryName($failed)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)) { return $null }
    $rejected = [Collections.Generic.HashSet[int]]::new()
    foreach ($pidValue in @($RejectedPids)) { if ($pidValue -gt 0) { [void]$rejected.Add([int]$pidValue) } }
    $regPath = Join-Path (Join-Path $parent 'session-writers') ($ExpectedSessionId + '.json')
    $registered = Read-TelephoneLeadDurableWriterRecord -Path $regPath -ExpectedSessionId $ExpectedSessionId -ExpectedRunId $FailedRunId -RequireSessionRun -AllowDifferentRunId
    if ($null -ne $registered -and $rejected.Contains([int]$registered.pid)) { $registered = $null }
    $registeredAlive = $false
    if ($null -ne $registered) {
        $registered['source_run_root'] = $(if ($registered.Contains('source_path')) { [IO.Path]::GetDirectoryName([string]$registered.source_path) } else { '' })
        $registered['source_run_id'] = [string]$registered.run_id
        $registered['binding_kind'] = 'current_session_writer'
        $registeredAlive = Test-TelephoneLeadOwnerIdentityAlive -Owner $registered
        if (-not $registeredAlive) { $registeredAlive = Test-TelephoneOwnerAlive -Owner $registered }
    }
    $preferred = [Collections.Generic.List[object]]::new()
    $fallback = [Collections.Generic.List[object]]::new()
    $names = @('cli-child.json', 'writer-owner.json', 'owner.json', 'host-owner.json')
    if ([IO.Directory]::Exists($parent)) {
        foreach ($dir in @([IO.Directory]::GetDirectories($parent))) {
            $root = [IO.Path]::GetFullPath($dir).TrimEnd('\')
            if ($root.Equals($failed, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ([IO.Path]::GetFileName($root) -ceq 'session-writers') { continue }
            foreach ($name in $names) {
                $bound = Read-TelephoneLeadDurableWriterRecord -Path (Join-Path $root $name) -ExpectedSessionId $ExpectedSessionId -ExpectedRunId $FailedRunId -RequireSessionRun -AllowDifferentRunId
                if ($null -eq $bound) { continue }
                if ($rejected.Contains([int]$bound.pid)) { continue }
                $alive = Test-TelephoneLeadOwnerIdentityAlive -Owner $bound
                if (-not $alive) { $alive = Test-TelephoneOwnerAlive -Owner $bound }
                if (-not $alive) { continue }
                $bound['source_run_root'] = $root
                $bound['source_run_id'] = [string]$bound.run_id
                $bound['binding_kind'] = 'live_registered_owner'
                if ($name -ceq 'cli-child.json' -or $name -ceq 'writer-owner.json') {
                    [void]$preferred.Add($bound)
                } else {
                    [void]$fallback.Add($bound)
                }
            }
        }
    }
    $uniquePreferred = [Collections.Generic.List[object]]::new()
    foreach ($row in $preferred) {
        $dup = $false
        foreach ($kept in $uniquePreferred) {
            if ([int]$kept.pid -eq [int]$row.pid -and [int64]$kept.start_time_utc_ticks -eq [int64]$row.start_time_utc_ticks) {
                $dup = $true
                break
            }
        }
        if (-not $dup) { [void]$uniquePreferred.Add($row) }
    }
    if ($uniquePreferred.Count -eq 1) { return $uniquePreferred[0] }
    if ($uniquePreferred.Count -gt 1) { return $null }
    if ($registeredAlive) { return $registered }
    $uniqueFallback = [Collections.Generic.List[object]]::new()
    foreach ($row in $fallback) {
        $dup = $false
        foreach ($kept in $uniqueFallback) {
            if ([int]$kept.pid -eq [int]$row.pid -and [int64]$kept.start_time_utc_ticks -eq [int64]$row.start_time_utc_ticks) {
                $dup = $true
                break
            }
        }
        if (-not $dup) { [void]$uniqueFallback.Add($row) }
    }
    if ($uniqueFallback.Count -eq 1) { return $uniqueFallback[0] }
    if ($null -ne $registered) { return $registered }
    return $null
}

function Get-TelephoneLeadBoundWriterFromRun {
    [CmdletBinding()]
    param(
        [string]$RunRoot = '',
        [AllowNull()][string]$StderrText = '',
        [string]$ExpectedSessionId = '',
        [string]$ExpectedRunId = ''
    )
    $root = ''
    if (-not [string]::IsNullOrWhiteSpace($RunRoot)) {
        $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    }
    $stderrPid = 0
    $raw = [string]$StderrText
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $match = [regex]::Match($raw, '(?i)pid[=:\s]+(?<pid>\d+)')
        if ($match.Success) { $stderrPid = [int]$match.Groups['pid'].Value }
    }
    if ([string]::IsNullOrWhiteSpace($root) -or -not [IO.Directory]::Exists($root)) {
        return [ordered]@{ writer = $null; identity_status = 'UNKNOWN'; stderr_pid = [int]$stderrPid }
    }
    $rejected = @(Get-TelephoneLeadRejectedAttemptPids -RunRoot $root)
    $rejectedSet = [Collections.Generic.HashSet[int]]::new()
    foreach ($pidValue in @($rejected)) { if ([int]$pidValue -gt 0) { [void]$rejectedSet.Add([int]$pidValue) } }
    $stderrUsable = ($stderrPid -gt 0 -and -not $rejectedSet.Contains($stderrPid))
    $prior = Find-TelephoneLeadPriorSessionWriter -FailedRunRoot $root -ExpectedSessionId $ExpectedSessionId -FailedRunId $ExpectedRunId -RejectedPids @($rejectedSet)
    if ($null -ne $prior) {
        if ($stderrUsable -and [int]$prior.pid -ne $stderrPid) {
            return [ordered]@{ writer = $null; identity_status = 'UNKNOWN'; stderr_pid = [int]$stderrPid; source = 'stderr_pid_disagrees' }
        }
        $priorPath = Join-Path $root 'prior-writer.json'
        if (-not [IO.File]::Exists($priorPath)) {
            try { $null = Write-TelephoneJsonCreateNew -Path $priorPath -Value $prior } catch [IO.IOException] { }
        }
        return [ordered]@{ writer = $prior; identity_status = 'bound'; stderr_pid = [int]$stderrPid; source = $(if ($prior.Contains('binding_kind')) { [string]$prior.binding_kind } else { 'current_registered' }) }
    }
    foreach ($name in @('prior-writer.json', 'writer-owner.json')) {
        $bound = Read-TelephoneLeadDurableWriterRecord -Path (Join-Path $root $name) -ExpectedSessionId $ExpectedSessionId -ExpectedRunId $ExpectedRunId -RequireSessionRun -AllowDifferentRunId
        if ($null -eq $bound) { continue }
        if ($rejectedSet.Contains([int]$bound.pid)) { continue }
        if ($stderrUsable -and [int]$bound.pid -ne $stderrPid) { continue }
        return [ordered]@{ writer = $bound; identity_status = 'bound'; stderr_pid = [int]$stderrPid; source = [string]$bound.source }
    }
    return [ordered]@{ writer = $null; identity_status = 'UNKNOWN'; stderr_pid = [int]$stderrPid }
}

function Get-TelephoneLeadWriterOwnerFromStderr {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text,
        [string]$RunRoot = '',
        [string]$ExpectedSessionId = '',
        [string]$ExpectedRunId = ''
    )
    $bound = Get-TelephoneLeadBoundWriterFromRun -RunRoot $RunRoot -StderrText $Text -ExpectedSessionId $ExpectedSessionId -ExpectedRunId $ExpectedRunId
    return $bound.writer
}

function Test-TelephoneLeadPreTurnActiveWriterConflict {
    [CmdletBinding()]
    param(
        [string]$RunRoot = '',
        [AllowNull()][string]$StderrText = '',
        [AllowNull()][object]$ExitCode = $null,
        [string]$ExpectedSessionId = '',
        [string]$ExpectedRunId = ''
    )
    $root = ''
    if (-not [string]::IsNullOrWhiteSpace($RunRoot)) {
        $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    }
    $stderr = [string]$StderrText
    $hostExit = $ExitCode
    $eventsEmpty = $true
    $hostTerminalPresent = $false
    $runMetaSession = $ExpectedSessionId
    $runMetaRunId = $ExpectedRunId
    if (-not [string]::IsNullOrWhiteSpace($root) -and [IO.Directory]::Exists($root)) {
        $stderrPath = Join-Path $root 'codex-stderr.txt'
        if ([string]::IsNullOrWhiteSpace($stderr) -and [IO.File]::Exists($stderrPath)) {
            try { $stderr = [IO.File]::ReadAllText($stderrPath) } catch { $stderr = '' }
        }
        $eventsPath = Join-Path $root 'codex-events.jsonl'
        if ([IO.File]::Exists($eventsPath)) {
            try {
                $eventsBytes = [IO.File]::ReadAllBytes($eventsPath)
                $eventsEmpty = ($eventsBytes.Length -eq 0)
            } catch { $eventsEmpty = $false }
        }
        $hostPath = Join-Path $root 'host-terminal.json'
        if ([IO.File]::Exists($hostPath)) {
            $hostTerminalPresent = $true
            try {
                $hostTerminalDoc = (Read-TelephoneJson -Path $hostPath).value
                if ($null -eq $hostExit -and $hostTerminalDoc -is [Collections.IDictionary] -and $hostTerminalDoc.Contains('exit_code')) {
                    $hostExit = [int]$hostTerminalDoc['exit_code']
                }
            } catch { }
        }
        $runMetaPath = Join-Path $root 'lead-run.json'
        if ([IO.File]::Exists($runMetaPath)) {
            try {
                $runMeta = (Read-TelephoneJson -Path $runMetaPath).value
                if ($runMeta -is [Collections.IDictionary]) {
                    if ([string]::IsNullOrWhiteSpace($runMetaSession) -and $runMeta.Contains('resume_session_id')) { $runMetaSession = [string]$runMeta['resume_session_id'] }
                    if ([string]::IsNullOrWhiteSpace($runMetaRunId) -and $runMeta.Contains('run_id')) { $runMetaRunId = [string]$runMeta['run_id'] }
                }
            } catch { }
        }
    }
    $writerPattern = Test-TelephoneLeadActiveWriterStderr -Text $stderr
    $nonzero = $false
    if ($null -ne $hostExit) { $nonzero = ([int]$hostExit -ne 0) }
    $matched = ($writerPattern -and $eventsEmpty -and $hostTerminalPresent -and $nonzero)
    $writer = $null
    $writerAlive = $false
    $identityStatus = 'UNKNOWN'
    if ($matched) {
        try {
            $bound = Get-TelephoneLeadBoundWriterFromRun -RunRoot $root -StderrText $stderr -ExpectedSessionId $runMetaSession -ExpectedRunId $runMetaRunId
            $identityStatus = [string]$bound.identity_status
            $writer = $bound.writer
            if ($identityStatus -ceq 'bound' -and $null -ne $writer) {
                $writerAlive = Test-TelephoneLeadOwnerIdentityAlive -Owner $writer
                if (-not $writerAlive) { $writerAlive = Test-TelephoneOwnerAlive -Owner $writer }
            } else {
                $identityStatus = 'UNKNOWN'
                $writer = $null
                $writerAlive = $false
            }
        } catch {
            $identityStatus = 'UNKNOWN'
            $writer = $null
            $writerAlive = $false
        }
    }
    $retryEligible = ([bool]$matched -and $identityStatus -ceq 'bound' -and -not $writerAlive)
    return [ordered]@{
        matched = [bool]$matched
        retry_eligible = [bool]$retryEligible
        writer_alive = [bool]$writerAlive
        writer_identity_status = [string]$identityStatus
        writer = $writer
        events_empty = [bool]$eventsEmpty
        host_terminal_present = [bool]$hostTerminalPresent
        exit_code = $hostExit
        stderr = [string]$stderr
        run_root = [string]$root
        native_turn_started = (-not $eventsEmpty)
    }
}
