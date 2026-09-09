# SPDX-License-Identifier: MPL-2.0
# Generic Lead CLI/runtime helpers for stable executable diagnosis, concurrent
# stream drain, and audited wake reconcile. Does not glob App version directories,
# switch accounts/models, or rewrite frozen dispatch bytes.

Set-StrictMode -Version Latest

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

function Get-TelephoneLeadProcessSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $proc = $null
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
        $started = $proc.StartTime.ToUniversalTime().ToString('o')
        $exe = ''
        try { $exe = [string]$proc.MainModule.FileName } catch { $exe = '' }
        $parent = 0
        $cim = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = " + $ProcessId) -ErrorAction SilentlyContinue
        if ($null -ne $cim) {
            $parent = [int]$cim.ParentProcessId
            if ([string]::IsNullOrWhiteSpace($exe) -and -not [string]::IsNullOrWhiteSpace([string]$cim.ExecutablePath)) {
                $exe = [string]$cim.ExecutablePath
            }
        }
        return [ordered]@{
            pid = [int]$ProcessId
            start_time_utc_ticks = $ticks
            started_at_utc = $started
            executable_path = $exe
            parent_process_id = $parent
        }
    } catch {
        return $null
    } finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }
}

function Test-TelephoneLeadProcessIdentityMatch {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Actual
    )
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    if ($Expected -isnot [Collections.IDictionary] -or $Actual -isnot [Collections.IDictionary]) { return $false }
    if (-not $Expected.Contains('pid') -or -not $Expected.Contains('start_time_utc_ticks')) { return $false }
    if (-not $Actual.Contains('pid') -or -not $Actual.Contains('start_time_utc_ticks')) { return $false }
    if ([int]$Expected.pid -ne [int]$Actual.pid) { return $false }
    if ([int64]$Expected.start_time_utc_ticks -ne [int64]$Actual.start_time_utc_ticks) { return $false }
    $expectedExe = ''
    $actualExe = ''
    if ($Expected.Contains('executable_path')) { $expectedExe = [string]$Expected.executable_path }
    if ($Actual.Contains('executable_path')) { $actualExe = [string]$Actual.executable_path }
    if (-not [string]::IsNullOrWhiteSpace($expectedExe) -and -not [string]::IsNullOrWhiteSpace($actualExe)) {
        if (-not [string]::Equals($expectedExe, $actualExe, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Test-TelephoneLeadOwnerIdentityAlive {
    [CmdletBinding()]
    param([AllowNull()][object]$Owner)
    if (-not (Test-TelephoneOwnerAlive -Owner $Owner)) { return $false }
    $live = Get-TelephoneLeadProcessSnapshot -ProcessId ([int]$Owner.pid)
    if ($null -eq $live) { return $false }
    $expected = [ordered]@{
        pid = [int]$Owner.pid
        start_time_utc_ticks = [int64]$Owner.start_time_utc_ticks
        executable_path = $(if ($Owner -is [Collections.IDictionary] -and $Owner.Contains('executable_path')) { [string]$Owner.executable_path } else { '' })
    }
    return (Test-TelephoneLeadProcessIdentityMatch -Expected $expected -Actual $live)
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

function Invoke-TelephoneLeadDrainedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [string]$WorkingDirectory = '',
        [string]$StdoutPath = '',
        [string]$StderrPath = '',
        [int]$TimeoutMilliseconds = 0,
        [switch]$KillOnTimeout
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
    try {
        $identity = [ordered]@{
            pid = [int]$process.Id
            start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
            started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
            executable_path = $FileName
        }
        if (-not [string]::IsNullOrWhiteSpace($StdoutPath)) {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StdoutPath))) | Out-Null
            $stdoutFile = [IO.File]::Create($StdoutPath)
            $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
        } else {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        }
        if (-not [string]::IsNullOrWhiteSpace($StderrPath)) {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StderrPath))) | Out-Null
            $stderrFile = [IO.File]::Create($StderrPath)
            $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrFile)
        } else {
            $stderrTask = $process.StandardError.ReadToEndAsync()
        }
        $exited = $false
        if ($TimeoutMilliseconds -gt 0) {
            $exited = $process.WaitForExit($TimeoutMilliseconds)
            if (-not $exited -and $KillOnTimeout) {
                try { $process.Kill($true) } catch { }
                $null = $process.WaitForExit(5000)
            }
        } else {
            $process.WaitForExit()
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
        return [ordered]@{
            protocol_version = 'telephone-line-drained-process-v1'
            pid = [int]$identity.pid
            start_time_utc_ticks = [int64]$identity.start_time_utc_ticks
            started_at_utc = [string]$identity.started_at_utc
            executable_path = [string]$identity.executable_path
            process_exited = $processExited
            exit_code = [int]$exitCode
            stdout_eof = $stdoutEof
            stderr_eof = $stderrEof
            stdout = $stdoutText
            stderr = $stderrText
            timed_out = (-not $exited)
        }
    } finally {
        if ($null -ne $stdoutFile) { $stdoutFile.Dispose() }
        if ($null -ne $stderrFile) { $stderrFile.Dispose() }
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Get-TelephoneLeadEventNativeTurn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EventsPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId,
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
    $childPath = Join-Path $root 'cli-child.json'
    $hostPath = Join-Path $root 'host-terminal.json'
    $finalPath = Join-Path $root 'lead-final.txt'
    $drainPath = Join-Path $root 'drain-lifecycle.json'
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
    }
    if ([IO.File]::Exists($childPath)) {
        try {
            $life.cli_child = (Read-TelephoneJson -Path $childPath).value
            $life.cli_child_alive = Test-TelephoneLeadOwnerIdentityAlive -Owner $life.cli_child
        } catch { }
    }
    if ([IO.File]::Exists($hostPath)) {
        try {
            $host = (Read-TelephoneJson -Path $hostPath).value
            $life.host_terminal_present = $true
            if ($host -is [Collections.IDictionary] -and $host.Contains('exit_code')) {
                $life.host_terminal_exit_code = [int]$host.exit_code
            }
        } catch { }
    }
    $life.lead_final_present = [IO.File]::Exists($finalPath)
    $native = Get-TelephoneLeadEventNativeTurn -EventsPath $eventsPath -ExpectedSessionId $ExpectedSessionId -NotBeforeUtc ([string]$life.created_at_utc)
    if (-not [string]::IsNullOrWhiteSpace([string]$native.rejected)) { $life.rejected = [string]$native.rejected }
    $life.native_turn_complete = [bool]$native.native_turn_complete
    $life.current_turn_id = [string]$native.current_turn_id
    $life.complete_kind = [string]$native.complete_kind
    if ([IO.File]::Exists($drainPath)) {
        try {
            $drain = (Read-TelephoneJson -Path $drainPath).value
            if ($drain -is [Collections.IDictionary]) {
                if ($drain.Contains('process_exited')) { $life.process_exited = [bool]$drain.process_exited }
                if ($drain.Contains('stdout_eof')) { $life.stdout_eof = [bool]$drain.stdout_eof }
                if ($drain.Contains('stderr_eof')) { $life.stderr_eof = [bool]$drain.stderr_eof }
            }
        } catch { }
    } else {
        $life.process_exited = (-not [bool]$life.owner_alive) -and (-not [bool]$life.cli_child_alive)
    }
    if ([bool]$life.lead_final_present -and -not [bool]$life.native_turn_complete) {
        $life.final_only = $true
    }
    return $life
}

function Stop-TelephoneLeadCompletedOwnProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId,
        [Parameter(Mandatory = $true)][string]$ExpectedRunId
    )
    $record = [ordered]@{
        protocol_version = 'telephone-line-completed-own-process-recovery-v1'
        attempted = $false
        recovered = $false
        refused = ''
        target = $null
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
    if (-not [string]::IsNullOrWhiteSpace([string]$Lifecycle.rejected) -and [string]$Lifecycle.rejected -cin @('wrong_session', 'wrong_turn', 'complete_without_current_turn')) {
        $record.refused = [string]$Lifecycle.rejected
        return $record
    }
    if ([bool]$Lifecycle.cli_child_alive) {
        $record.refused = 'cli_child_still_alive'
        return $record
    }
    $owner = $Lifecycle.owner
    if ($null -eq $owner -or -not [bool]$Lifecycle.owner_alive) {
        $record.refused = 'owner_not_alive'
        return $record
    }
    $live = Get-TelephoneLeadProcessSnapshot -ProcessId ([int]$owner.pid)
    if ($null -eq $live) {
        $record.refused = 'owner_vanished'
        return $record
    }
    $expected = [ordered]@{
        pid = [int]$owner.pid
        start_time_utc_ticks = [int64]$owner.start_time_utc_ticks
        executable_path = $(if ($owner -is [Collections.IDictionary] -and $owner.Contains('executable_path')) { [string]$owner.executable_path } else { '' })
    }
    if (-not (Test-TelephoneLeadProcessIdentityMatch -Expected $expected -Actual $live)) {
        $record.refused = 'pid_reuse_or_exe_mismatch'
        return $record
    }
    $record.attempted = $true
    $record.target = $live
    try {
        $again = Get-TelephoneLeadProcessSnapshot -ProcessId ([int]$owner.pid)
        if ($null -eq $again -or -not (Test-TelephoneLeadProcessIdentityMatch -Expected $expected -Actual $again)) {
            $record.refused = 'identity_changed_before_stop'
            return $record
        }
        Stop-Process -Id ([int]$again.pid) -Force -ErrorAction Stop
        $record.recovered = $true
    } catch {
        $record.refused = 'stop_failed'
    }
    return $record
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
        if ([bool]$life.native_turn_complete -and -not [bool]$life.cli_child_alive) {
            $recovery = Stop-TelephoneLeadCompletedOwnProcess -Lifecycle $life -ExpectedSessionId $SessionId -ExpectedRunId $RunId
            $result.recovery = $recovery
            $life = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $SessionId -ExpectedRunId $RunId
            $result.lifecycle = $life
            if ([bool]$recovery.recovered -or -not [bool]$life.owner_alive) {
                $state = $(if ([bool]$life.host_terminal_present) { 'recovered' } else { 'recovered_native_complete_host_incomplete' })
                $result.decision = 'recovered_attach'
                $result.error_code = ''
                $result.launch = New-TelephoneLeadLaunchFromRunRoot -RunRoot $runRoot -RunId $RunId -State $state
                $result.reason = $state
                return $result
            }
        }
        while (Test-TelephoneLeadOwnerIdentityAlive -Owner $life.owner) {
            Start-Sleep -Milliseconds 200
            $life = Get-TelephoneLeadRunLifecycle -RunRoot $runRoot -ExpectedSessionId $SessionId -ExpectedRunId $RunId
            $result.lifecycle = $life
            if ([bool]$life.native_turn_complete -and -not [bool]$life.cli_child_alive -and [bool]$life.owner_alive) {
                $recovery = Stop-TelephoneLeadCompletedOwnProcess -Lifecycle $life -ExpectedSessionId $SessionId -ExpectedRunId $RunId
                $result.recovery = $recovery
                if ([bool]$recovery.recovered) { break }
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
    return [ordered]@{
        protocol_version = 'telephone-line-lead-launch-diagnostic-v1'
        error_code = [string]$Code
        language_mode = Get-TelephoneLeadLanguageMode
        executable = [string]$Executable
        working_directory = [string]$WorkingDirectory
        create_process_error = [string]$CreateProcessError
        win32_error = [int]$Win32Error
        process_exited = [bool]$processExited
        native_turn_complete = $false
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
        stdout_preview = $(if ([string]$stdout.Length -gt 2048) { [string]$stdout.Substring(0, 2048) } else { [string]$stdout })
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Test-TelephoneLeadActiveWriterStderr {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)
    $raw = [string]$Text
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    return ($raw -match '(?i)thread-store conflict' -or $raw -match '(?i)already has an active writer')
}

function Get-TelephoneLeadWriterOwnerFromStderr {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)
    $raw = [string]$Text
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $match = [regex]::Match($raw, '(?i)pid[=:\s]+(?<pid>\d+)')
    if (-not $match.Success) { return $null }
    $pidValue = [int]$match.Groups['pid'].Value
    try {
        $proc = Get-Process -Id $pidValue -ErrorAction Stop
        try {
            return [ordered]@{
                pid = $pidValue
                start_time_utc_ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
                started_at_utc = $proc.StartTime.ToUniversalTime().ToString('o')
                executable_path = $(try { [string]$proc.MainModule.FileName } catch { '' })
            }
        } finally {
            $proc.Dispose()
        }
    } catch {
        return [ordered]@{ pid = $pidValue; start_time_utc_ticks = 0; started_at_utc = ''; executable_path = ''; vanished = $true }
    }
}

function Test-TelephoneLeadPreTurnActiveWriterConflict {
    [CmdletBinding()]
    param(
        [string]$RunRoot = '',
        [AllowNull()][string]$StderrText = '',
        [AllowNull()][object]$ExitCode = $null
    )
    $root = ''
    if (-not [string]::IsNullOrWhiteSpace($RunRoot)) {
        $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    }
    $stderr = [string]$StderrText
    $hostExit = $ExitCode
    $eventsEmpty = $true
    $hostTerminalPresent = $false
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
                $host = (Read-TelephoneJson -Path $hostPath).value
                if ($null -eq $hostExit -and $host -is [Collections.IDictionary] -and $host.Contains('exit_code')) {
                    $hostExit = [int]$host['exit_code']
                }
            } catch { }
        }
    }
    $writerPattern = Test-TelephoneLeadActiveWriterStderr -Text $stderr
    $nonzero = $false
    if ($null -ne $hostExit) { $nonzero = ([int]$hostExit -ne 0) }
    $matched = ($writerPattern -and $eventsEmpty -and ($nonzero -or $hostTerminalPresent))
    $writer = $null
    $writerAlive = $false
    if ($matched) {
        $writer = Get-TelephoneLeadWriterOwnerFromStderr -Text $stderr
        $vanished = $false
        if ($null -ne $writer) {
            if ($writer -is [Collections.IDictionary] -and $writer.Contains('vanished')) {
                $vanished = [bool]$writer['vanished']
            } elseif ($null -ne $writer.PSObject.Properties['vanished']) {
                $vanished = [bool]$writer.vanished
            }
        }
        if ($null -ne $writer -and -not $vanished) {
            $writerAlive = Test-TelephoneOwnerAlive -Owner $writer
        }
    }
    return [ordered]@{
        matched = [bool]$matched
        retry_eligible = [bool]$matched
        writer_alive = [bool]$writerAlive
        writer = $writer
        events_empty = [bool]$eventsEmpty
        host_terminal_present = [bool]$hostTerminalPresent
        exit_code = $hostExit
        stderr = [string]$stderr
        run_root = [string]$root
        native_turn_started = (-not $eventsEmpty)
    }
}
