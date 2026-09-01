# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'Telephone Line v0.1 supports Windows only.'
}

$supervisorCore = Join-Path $PSScriptRoot '..\core\TelephoneLine.Common.ps1'
if (-not (Test-Path -LiteralPath $supervisorCore)) { throw 'Telephone-line core is missing.' }
. $supervisorCore

$script:TelephoneSupervisorTaskName = 'TelephoneLineWiredSupervisor'
$script:TelephoneSupervisorEmergencyShortcut = '有线电话｜紧急停止.lnk'
$script:TelephoneSupervisorConsoleShortcut = '有线电话｜控制台.lnk'
$script:TelephoneSupervisorRequestProtocol = 'telephone-line-wired-supervisor-request-v1'
$script:TelephoneSupervisorOwnerProtocol = 'telephone-line-wired-supervisor-owner-v1'
$script:TelephoneSupervisorStatusProtocol = 'telephone-line-wired-supervisor-status-v1'
$script:TelephoneSupervisorControlProtocol = 'telephone-line-wired-supervisor-control-v1'
$script:TelephoneSupervisorNativeReady = $false
$script:TelephoneSupervisorCommonImported = $true
$script:TelephoneRecycleMaxAttempts = 8
$script:TelephoneRecycleRetryDelayMilliseconds = 75
$script:TelephoneRecycleQuiescenceMilliseconds = 2000
$script:TelephoneRecycleInjectNextNativeFailures = 0
$script:TelephoneRecycleAttemptLog = [Collections.Generic.List[object]]::new()

function Initialize-TelephoneSupervisorNative {
    [CmdletBinding()]
    param()
    if ($script:TelephoneSupervisorNativeReady) { return }
    if ($null -eq ('TelephoneWiredSupervisorNative.Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace TelephoneWiredSupervisorNative {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEOPSTRUCT {
        public IntPtr hwnd;
        public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string pTo;
        public ushort fFlags;
        public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszProgressTitle;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct STARTUPINFO {
        public int cb; public IntPtr lpReserved; public IntPtr lpDesktop; public IntPtr lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize;
        public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS {
        public ulong ReadOperationCount; public ulong WriteOperationCount; public ulong OtherOperationCount;
        public ulong ReadTransferCount; public ulong WriteTransferCount; public ulong OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
    }
    public static class Native {
        public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        public const int JobObjectExtendedLimitInformation = 9;
        public const int JobObjectBasicProcessIdList = 3;
        public const uint CREATE_SUSPENDED = 0x00000004;
        public const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
        public const uint CREATE_NO_WINDOW = 0x08000000;
        public const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        public const uint FO_DELETE = 3;
        public const ushort FOF_SILENT = 4;
        public const ushort FOF_NOCONFIRMATION = 16;
        public const ushort FOF_ALLOWUNDO = 64;
        public const ushort FOF_NOERRORUI = 1024;
        public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr OpenJobObject(uint dwDesiredAccess, bool bInheritHandle, string lpName);
        public static IntPtr TryOpenJob(string name, out int error) {
            uint[] accesses = new uint[] { 0x0010001Fu, 0x1F003Fu, 0x0000001Fu, 0x0000000Du, 0x00000004u };
            error = 0;
            foreach (uint access in accesses) {
                IntPtr handle = OpenJobObject(access, false, name);
                if (handle != IntPtr.Zero) {
                    error = 0;
                    return handle;
                }
                error = Marshal.GetLastWin32Error();
            }
            return IntPtr.Zero;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInfo, uint cbJobObjectInfoLength);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool IsProcessInJob(IntPtr ProcessHandle, IntPtr JobHandle, out bool Result);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool QueryInformationJobObject(IntPtr hJob, int JobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength, out uint lpReturnLength);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CreateProcess(string lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint ResumeThread(IntPtr hThread);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern int SHFileOperation(ref SHFILEOPSTRUCT lpFileOp);
        public static IntPtr CreateNamedKillOnCloseJob(string name) {
            IntPtr handle = CreateJobObject(IntPtr.Zero, name);
            if (handle == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed"); }
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            uint length = (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            if (!SetInformationJobObject(handle, JobObjectExtendedLimitInformation, ref info, length)) {
                int error = Marshal.GetLastWin32Error();
                CloseHandle(handle);
                throw new Win32Exception(error, "SetInformationJobObject failed");
            }
            return handle;
        }
        public static bool ProcessInJob(IntPtr process, IntPtr job) {
            bool result;
            if (!IsProcessInJob(process, job, out result)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "IsProcessInJob failed");
            }
            return result;
        }
        public static int[] JobProcessIds(IntPtr job) {
            uint needed;
            QueryInformationJobObject(job, JobObjectBasicProcessIdList, IntPtr.Zero, 0, out needed);
            int cap = 64;
            while (true) {
                int size = 8 + (IntPtr.Size * cap);
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try {
                    uint returned;
                    if (QueryInformationJobObject(job, JobObjectBasicProcessIdList, buffer, (uint)size, out returned)) {
                        int assigned = Marshal.ReadInt32(buffer, 0);
                        int listed = Marshal.ReadInt32(buffer, 4);
                        int count = listed > 0 ? listed : assigned;
                        if (count < 0) { count = 0; }
                        if (count > cap) { cap = count + 8; continue; }
                        int[] ids = new int[count];
                        for (int i = 0; i < count; i++) {
                            IntPtr value = Marshal.ReadIntPtr(buffer, 8 + (i * IntPtr.Size));
                            ids[i] = value.ToInt32();
                        }
                        return ids;
                    }
                    int error = Marshal.GetLastWin32Error();
                    if (error == 234) { cap = cap * 2; continue; }
                    throw new Win32Exception(error, "QueryInformationJobObject failed");
                } finally {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }
        public static int StartSuspendedInJob(IntPtr job, string fileName, string commandLine, string workingDirectory) {
            var si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            si.dwFlags = 1;
            si.wShowWindow = 0;
            PROCESS_INFORMATION pi;
            var cmd = new StringBuilder(commandLine);
            uint flags = CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT;
            if (!CreateProcess(fileName, cmd, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, workingDirectory, ref si, out pi)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess failed");
            }
            try {
                if (!AssignProcessToJobObject(job, pi.hProcess)) {
                    int error = Marshal.GetLastWin32Error();
                    TerminateProcess(pi.hProcess, 1);
                    throw new Win32Exception(error, "AssignProcessToJobObject failed");
                }
                ResumeThread(pi.hThread);
                return pi.dwProcessId;
            } finally {
                if (pi.hThread != IntPtr.Zero) { CloseHandle(pi.hThread); }
                if (pi.hProcess != IntPtr.Zero) { CloseHandle(pi.hProcess); }
            }
        }
        public static int StartDetached(string fileName, string commandLine, string workingDirectory) {
            var si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            si.dwFlags = 1;
            si.wShowWindow = 0;
            PROCESS_INFORMATION pi;
            var cmd = new StringBuilder(commandLine);
            uint flags = CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP;
            if (!CreateProcess(fileName, cmd, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, workingDirectory, ref si, out pi)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess detached failed");
            }
            if (pi.hThread != IntPtr.Zero) { CloseHandle(pi.hThread); }
            if (pi.hProcess != IntPtr.Zero) { CloseHandle(pi.hProcess); }
            return pi.dwProcessId;
        }
        public static int RecyclePath(string path) {
            var op = new SHFILEOPSTRUCT();
            op.wFunc = FO_DELETE;
            op.pFrom = path + "\0\0";
            op.fFlags = (ushort)(FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO | FOF_NOERRORUI);
            return SHFileOperation(ref op);
        }
    }
}
'@
    }
    $script:TelephoneSupervisorNativeReady = $true
}

function Get-TelephoneSupervisorSha256Hex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function ConvertTo-TelephoneSupervisorJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Value)
    return (($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n")
}

function Resolve-TelephoneSupervisorStateRoot {
    [CmdletBinding()]
    param([string]$StateRoot)
    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        return [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT)) {
        return [IO.Path]::GetFullPath([string]$env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT).TrimEnd('\')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_STATE_ROOT)) {
        return [IO.Path]::GetFullPath((Join-Path ([string]$env:TELEPHONE_LINE_STATE_ROOT) 'supervisor')).TrimEnd('\')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) {
        return [IO.Path]::GetFullPath((Join-Path ([string]$env:LOCALAPPDATA) 'TelephoneLine\supervisor-state')).TrimEnd('\')
    }
    throw 'Supervisor state root is required.'
}

function Get-TelephoneSupervisorPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $root = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    $control = Join-Path $root 'control'
    return [ordered]@{
        root = $root
        inbox = Join-Path $root 'inbox'
        claimed = Join-Path $root 'claimed'
        outbox = Join-Path $root 'outbox'
        runs = Join-Path $root 'runs'
        control = $control
        pause = Join-Path $control 'pause.json'
        supervisor_owner = Join-Path $control 'supervisor-owner.json'
    }
}

function Initialize-TelephoneSupervisorLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $paths = Get-TelephoneSupervisorPaths -StateRoot $StateRoot
    foreach ($dir in @($paths.root, $paths.inbox, $paths.claimed, $paths.outbox, $paths.runs, $paths.control)) {
        if (-not [IO.Directory]::Exists($dir)) {
            [IO.Directory]::CreateDirectory($dir) | Out-Null
        }
        $null = Assert-TelephoneDirectoryPath -Path $dir -Label 'Supervisor directory'
    }
    return $paths
}

function Get-TelephoneSupervisorMutexName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $full = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($full.ToLowerInvariant())
    $hash = Get-TelephoneSupervisorSha256Hex -Bytes $bytes
    return ('Local\TelephoneLine.WiredSupervisor.' + $hash.Substring(0, 16))
}

function Get-TelephoneSupervisorJobName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RunId)
    if ([string]$RunId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'Supervisor run-id is invalid.'
    }
    return ('Local\TelephoneLine.WiredRun.' + [string]$RunId)
}

function Test-TelephoneSupervisorPathInsideRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return ($pathFull + '\').StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-TelephoneSupervisorContainedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Contains('..')) { throw "$Label path escape is not allowed." }
    Assert-TelephoneRelativePathSafe -Path $full -Label $Label
    if (-not (Test-TelephoneSupervisorPathInsideRoot -Path $full -Root $Root)) {
        throw "$Label path escape is not allowed."
    }
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $cursor = $parent
        $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        while (-not [string]::IsNullOrWhiteSpace($cursor)) {
            $cursorFull = [IO.Path]::GetFullPath($cursor).TrimEnd('\')
            if ([IO.Directory]::Exists($cursorFull) -or [IO.File]::Exists($cursorFull)) {
                $item = Get-Item -LiteralPath $cursorFull -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "$Label path is a reparse point."
                }
            }
            if ($cursorFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
            $next = [IO.Path]::GetDirectoryName($cursorFull)
            if ([string]::IsNullOrWhiteSpace($next) -or $next.Equals($cursorFull, [StringComparison]::OrdinalIgnoreCase)) { break }
            $cursor = $next
        }
    }
    return $full
}

function Assert-TelephoneSupervisorNoPartialTemp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    $name = [IO.Path]::GetFileName($full)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)) { return }
    $prefix = '.' + $name + '.tmp-'
    foreach ($entry in [IO.Directory]::EnumerateFiles($parent)) {
        $itemName = [IO.Path]::GetFileName($entry)
        if ($itemName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Partial temporary write is present; supervisor refused to continue.'
        }
    }
}

function Get-TelephoneSupervisorRequestHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Request)
    $copy = [ordered]@{}
    foreach ($key in @($Request.Keys)) {
        if ([string]$key -ceq 'request_sha256') { continue }
        $copy[[string]$key] = $Request[$key]
    }
    $json = ConvertTo-TelephoneSupervisorJson -Value $copy
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    return Get-TelephoneSupervisorSha256Hex -Bytes $bytes
}

function Assert-TelephoneSupervisorRequestValue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Request)
    $json = ConvertTo-TelephoneSupervisorJson -Value $Request
    Assert-TelephoneJsonSchema -JsonText $json -SchemaName 'wired-supervisor-request' -Label 'wired supervisor request'
    $expected = Get-TelephoneSupervisorRequestHash -Request $Request
    if ([string]$Request.request_sha256 -cne $expected) {
        throw 'Supervisor request hash does not match the canonical request bytes.'
    }
    if ([string]$Request.protocol_version -cne $script:TelephoneSupervisorRequestProtocol) {
        throw 'Unsupported wired supervisor request protocol.'
    }
    return $expected
}

function New-TelephoneSupervisorOwnerSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [int]$ProcessId = 0
    )
    $id = if ($ProcessId -gt 0) { [int]$ProcessId } else { [int]$PID }
    $proc = Get-Process -Id $id -ErrorAction Stop
    try {
        return [ordered]@{
            protocol_version = $script:TelephoneSupervisorOwnerProtocol
            kind = [string]$Kind
            pid = [int]$proc.Id
            start_time_utc_ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
            started_at_utc = $proc.StartTime.ToUniversalTime().ToString('o')
        }
    } finally {
        $proc.Dispose()
    }
}

function Test-TelephoneSupervisorExactOwner {
    [CmdletBinding()]
    param([AllowNull()][object]$Owner)
    if ($null -eq $Owner) { return $false }
    return [bool](Test-TelephoneOwnerAlive -Owner $Owner)
}

function Get-TelephoneSupervisorPause {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $paths = Get-TelephoneSupervisorPaths -StateRoot $StateRoot
    if (-not [IO.File]::Exists($paths.pause)) {
        return [ordered]@{ paused_by_pascal = $false }
    }
    $read = Read-TelephoneJson -Path $paths.pause
    $paused = $false
    if ($read.value -is [Collections.IDictionary] -and $read.value.Contains('paused_by_pascal')) {
        $paused = [bool]$read.value.paused_by_pascal
    }
    return [ordered]@{ paused_by_pascal = $paused; record = $read.value }
}

function Write-TelephoneSupervisorPause {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][bool]$Paused
    )
    $paths = Initialize-TelephoneSupervisorLayout -StateRoot $StateRoot
    $value = [ordered]@{
        paused_by_pascal = [bool]$Paused
        updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $null = Write-TelephoneJsonReplace -Path $paths.pause -Value $value
    return $value
}

function Get-TelephoneSupervisorRecordPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $paths = Get-TelephoneSupervisorPaths -StateRoot $StateRoot
    $file = ([string]$RunId + '.json')
    switch ([string]$Kind) {
        'inbox' { return (Join-Path $paths.inbox $file) }
        'claimed' { return (Join-Path $paths.claimed $file) }
        'outbox' { return (Join-Path $paths.outbox $file) }
        default { throw 'Unknown supervisor record kind.' }
    }
}

function Read-TelephoneSupervisorOptionalRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
        return (Read-TelephoneJson -Path $Path)
    } catch {
        return $null
    }
}

function Publish-TelephoneSupervisorInbox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Request
    )
    $paths = Initialize-TelephoneSupervisorLayout -StateRoot $StateRoot
    $hash = Assert-TelephoneSupervisorRequestValue -Request $Request
    $runId = [string]$Request.run_id
    $inboxPath = Get-TelephoneSupervisorRecordPath -StateRoot $paths.root -Kind inbox -RunId $runId
    $claimedPath = Get-TelephoneSupervisorRecordPath -StateRoot $paths.root -Kind claimed -RunId $runId
    $outboxPath = Get-TelephoneSupervisorRecordPath -StateRoot $paths.root -Kind outbox -RunId $runId
    $null = Assert-TelephoneSupervisorContainedPath -Path $inboxPath -Root $paths.root -Label 'Supervisor inbox'
    Assert-TelephoneSupervisorNoPartialTemp -Path $inboxPath
    foreach ($existingPath in @($inboxPath, $claimedPath, $outboxPath)) {
        $existing = Read-TelephoneSupervisorOptionalRecord -Path $existingPath
        if ($null -eq $existing) { continue }
        $existingHash = [string]$existing.value.request_sha256
        if ($existingHash -ceq $hash) {
            return [ordered]@{ published = $false; replayed = $true; launched = $false; path = $existingPath; request_sha256 = $hash }
        }
        throw 'Supervisor run-id replay with different request bytes is refused.'
    }
    $null = Write-TelephoneJsonCreateNew -Path $inboxPath -Value $Request
    return [ordered]@{ published = $true; replayed = $false; launched = $false; path = $inboxPath; request_sha256 = $hash }
}

function Claim-TelephoneSupervisorInbox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $paths = Initialize-TelephoneSupervisorLayout -StateRoot $StateRoot
    $inboxPath = Get-TelephoneSupervisorRecordPath -StateRoot $paths.root -Kind inbox -RunId $RunId
    $claimedPath = Get-TelephoneSupervisorRecordPath -StateRoot $paths.root -Kind claimed -RunId $RunId
    $outboxPath = Get-TelephoneSupervisorRecordPath -StateRoot $paths.root -Kind outbox -RunId $RunId
    $null = Assert-TelephoneSupervisorContainedPath -Path $claimedPath -Root $paths.root -Label 'Supervisor claimed'
    Assert-TelephoneSupervisorNoPartialTemp -Path $claimedPath
    if ([IO.File]::Exists($outboxPath)) {
        $outbox = Read-TelephoneJson -Path $outboxPath
        return [ordered]@{ claimed = $false; replayed = $true; terminal = $true; record = $outbox }
    }
    if ([IO.File]::Exists($claimedPath)) {
        $claimed = Read-TelephoneJson -Path $claimedPath -SchemaName 'wired-supervisor-request'
        if ([IO.File]::Exists($inboxPath)) {
            $inbox = Read-TelephoneJson -Path $inboxPath
            if ([string]$inbox.value.request_sha256 -cne [string]$claimed.value.request_sha256) {
                throw 'Supervisor run-id replay with different request bytes is refused.'
            }
        }
        return [ordered]@{ claimed = $false; replayed = $true; terminal = $false; record = $claimed }
    }
    if (-not [IO.File]::Exists($inboxPath)) {
        throw 'Supervisor inbox request is missing.'
    }
    $inbox = Read-TelephoneJson -Path $inboxPath -SchemaName 'wired-supervisor-request'
    $null = Assert-TelephoneSupervisorRequestValue -Request $inbox.value
    $null = Write-TelephoneBytesCreateNew -Path $claimedPath -Bytes ([IO.File]::ReadAllBytes($inboxPath))
    [IO.File]::Delete($inboxPath)
    return [ordered]@{ claimed = $true; replayed = $false; terminal = $false; record = (Read-TelephoneJson -Path $claimedPath -SchemaName 'wired-supervisor-request') }
}

function Write-TelephoneSupervisorOutbox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Terminal,
        [AllowNull()][object]$Request,
        [string]$ErrorCode = ''
    )
    $paths = Initialize-TelephoneSupervisorLayout -StateRoot $StateRoot
    $outboxPath = Get-TelephoneSupervisorRecordPath -StateRoot $paths.root -Kind outbox -RunId $RunId
    $null = Assert-TelephoneSupervisorContainedPath -Path $outboxPath -Root $paths.root -Label 'Supervisor outbox'
    if ([IO.File]::Exists($outboxPath)) {
        return (Read-TelephoneJson -Path $outboxPath)
    }
    $value = [ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-outbox-v1'
        run_id = [string]$RunId
        terminal = [string]$Terminal
        request_sha256 = $(if ($null -ne $Request -and $Request -is [Collections.IDictionary] -and $Request.Contains('request_sha256')) { [string]$Request.request_sha256 } else { '' })
        project = $(if ($null -ne $Request) { [string]$Request.project } else { '' })
        stage = $(if ($null -ne $Request) { [string]$Request.stage } else { '' })
        error_code = [string]$ErrorCode
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try {
        $null = Write-TelephoneJsonCreateNew -Path $outboxPath -Value $value
    } catch [IO.IOException] {
        return (Read-TelephoneJson -Path $outboxPath)
    }
    $claimedPath = Get-TelephoneSupervisorRecordPath -StateRoot $paths.root -Kind claimed -RunId $RunId
    if ([IO.File]::Exists($claimedPath)) { [IO.File]::Delete($claimedPath) }
    return (Read-TelephoneJson -Path $outboxPath)
}

function Get-TelephoneSupervisorRunOwnerPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $paths = Get-TelephoneSupervisorPaths -StateRoot $StateRoot
    return (Join-Path (Join-Path $paths.runs $RunId) 'owner.json')
}

function Write-TelephoneSupervisorRunOwner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Owner
    )
    $paths = Initialize-TelephoneSupervisorLayout -StateRoot $StateRoot
    $runId = [string]$Owner.run_id
    $runDir = Join-Path $paths.runs $runId
    if (-not [IO.Directory]::Exists($runDir)) { [IO.Directory]::CreateDirectory($runDir) | Out-Null }
    $ownerPath = Join-Path $runDir 'owner.json'
    $null = Assert-TelephoneSupervisorContainedPath -Path $ownerPath -Root $paths.root -Label 'Supervisor owner'
    $json = ConvertTo-TelephoneSupervisorJson -Value $Owner
    Assert-TelephoneJsonSchema -JsonText $json -SchemaName 'wired-supervisor-owner' -Label 'wired supervisor owner'
    try {
        $null = Write-TelephoneJsonCreateNew -Path $ownerPath -Value $Owner
    } catch [IO.IOException] {
        $existing = Read-TelephoneSupervisorRunOwner -StateRoot $StateRoot -RunId $runId
        if ($null -ne $existing -and (Test-TelephoneSupervisorExactOwner -Owner $existing.value)) {
            throw 'Supervisor run owner already exists.'
        }
        $null = Write-TelephoneJsonReplace -Path $ownerPath -Value $Owner
    }
    return $ownerPath
}

function Read-TelephoneSupervisorRunOwner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $ownerPath = Get-TelephoneSupervisorRunOwnerPath -StateRoot $StateRoot -RunId $RunId
    if (-not [IO.File]::Exists($ownerPath)) { return $null }
    return (Read-TelephoneJson -Path $ownerPath -SchemaName 'wired-supervisor-owner')
}

function Open-TelephoneSupervisorMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [switch]$RequireCreated
    )
    $name = Get-TelephoneSupervisorMutexName -StateRoot $StateRoot
    $created = $false
    $mutex = [Threading.Mutex]::new($true, $name, [ref]$created)
    if ($RequireCreated -and -not $created) {
        $mutex.Dispose()
        throw 'A supervisor owner is already present.'
    }
    return [ordered]@{ mutex = $mutex; created = [bool]$created; name = $name }
}

function Get-TelephoneSupervisorTaskActionScript {
    [CmdletBinding()]
    param([AllowNull()][string]$Arguments)
    $text = [string]$Arguments
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $encoded = [regex]::Match($text, '(?i)-EncodedCommand\s+([A-Za-z0-9+/=]+)')
    if ($encoded.Success) {
        try {
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String([string]$encoded.Groups[1].Value))
            $nested = Get-TelephoneSupervisorTaskActionScript -Arguments $command
            if (-not [string]::IsNullOrWhiteSpace($nested)) { return $nested }
            $invocation = [regex]::Match($command, "&\s+'((?:''|[^'])+)'")
            if ($invocation.Success) { return [string]$invocation.Groups[1].Value.Replace("''", "'") }
        } catch { }
    }
    $quoted = [regex]::Match($text, '(?i)-File\s+"([^"]+)"')
    if ($quoted.Success) { return [string]$quoted.Groups[1].Value }
    $bare = [regex]::Match($text, '(?i)-File\s+(\S+)')
    if ($bare.Success) { return [string]$bare.Groups[1].Value.Trim('"') }
    return ''
}

function ConvertTo-TelephoneSupervisorTaskArgumentTokens {
    [CmdletBinding()]
    param([AllowNull()][string]$Arguments)
    $tokens = [Collections.Generic.List[string]]::new()
    $text = [string]$Arguments
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        foreach ($match in @([regex]::Matches($text, '"([^"]*)"|(\S+)'))) {
            if ($match.Groups[1].Success) { [void]$tokens.Add([string]$match.Groups[1].Value) }
            else { [void]$tokens.Add([string]$match.Groups[2].Value) }
        }
    }
    return [string[]]$tokens.ToArray()
}

function New-TelephoneSupervisorEncodedTaskArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ActionScript,
        [AllowNull()][string]$ActionArguments
    )
    $scriptPath = Assert-TelephoneRegularFilePath -Path $ActionScript -Label 'Supervisor task action script'
    $parts = [Collections.Generic.List[string]]::new()
    [void]$parts.Add(("'" + $scriptPath.Replace("'", "''") + "'"))
    foreach ($token in @(ConvertTo-TelephoneSupervisorTaskArgumentTokens -Arguments $ActionArguments)) {
        $value = [string]$token
        if ($value -cmatch '^-[A-Za-z][A-Za-z0-9-]*$') { [void]$parts.Add($value) }
        else { [void]$parts.Add(("'" + $value.Replace("'", "''") + "'")) }
    }
    # A successful PowerShell script may legitimately leave LASTEXITCODE set by an
    # internal native probe. Propagate it only when the script invocation itself
    # failed; otherwise normalize successful completion to zero.
    $command = "`$ErrorActionPreference='Stop'; & " + ([string]::Join(' ', $parts)) + "; `$scriptSucceeded=`$?; `$scriptExitCode=`$LASTEXITCODE; if (-not `$scriptSucceeded) { if (`$null -ne `$scriptExitCode) { exit [int]`$scriptExitCode }; exit 1 }; exit 0"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    # Task Scheduler's Hidden setting hides the task entry, not the console host.
    # The explicit pwsh window style prevents the one-minute supervisor trigger
    # from flashing a transient terminal in the interactive user session.
    return '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $encoded
}

function New-TelephoneSupervisorTaskActionDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ActionScript,
        [AllowNull()][string]$ActionArguments
    )
    $pwsh = Assert-TelephoneRegularFilePath -Path ([string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)) -Label 'PowerShell host'
    $windowsPowerShell = Assert-TelephoneRegularFilePath -Path (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Label 'Hidden scheduled-task host'
    $innerArguments = New-TelephoneSupervisorEncodedTaskArguments -ActionScript $ActionScript -ActionArguments $ActionArguments
    $outerCommand = "& '" + $pwsh.Replace("'", "''") + "' " + $innerArguments + "; if (`$null -ne `$LASTEXITCODE) { exit [int]`$LASTEXITCODE }; exit 0"
    $outerEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($outerCommand))
    return [ordered]@{
        execute = $windowsPowerShell
        arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $outerEncoded
        inner_arguments = $innerArguments
    }
}

function Invoke-TelephoneSupervisorTaskOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [string]$InstallRoot,
        [string]$ActionScript,
        [string]$ActionArguments
    )
    $backend = [string]$env:TELEPHONE_LINE_TASK_BACKEND
    $store = [string]$env:TELEPHONE_LINE_TASK_STORE
    if (-not [string]::IsNullOrWhiteSpace($backend)) {
        $scriptPath = Assert-TelephoneRegularFilePath -Path $backend -Label 'Supervisor task backend'
        $payload = [ordered]@{
            operation = [string]$Operation
            task_name = $script:TelephoneSupervisorTaskName
            install_root = [string]$InstallRoot
            action_script = [string]$ActionScript
            action_arguments = [string]$ActionArguments
            store = [string]$store
        }
        $json = ConvertTo-TelephoneSupervisorJson -Value $payload
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('tl-task-' + [Guid]::NewGuid().ToString('N') + '.json')
        try {
            [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
            $info.UseShellExecute = $false
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $info.CreateNoWindow = $true
            foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-RequestFile', $temp)) {
                [void]$info.ArgumentList.Add([string]$argument)
            }
            $process = [Diagnostics.Process]::Start($info)
            try {
                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                if ($process.ExitCode -ne 0) { throw "Task backend failed: $stderr $stdout" }
                if ([string]::IsNullOrWhiteSpace($stdout)) { return [ordered]@{ ok = $true } }
                return ($stdout | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String)
            } finally {
                $process.Dispose()
            }
        } finally {
            if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($store)) {
        $storeRoot = [IO.Path]::GetFullPath($store).TrimEnd('\')
        if (-not [IO.Directory]::Exists($storeRoot)) { [IO.Directory]::CreateDirectory($storeRoot) | Out-Null }
        $recordPath = Join-Path $storeRoot 'task.json'
        switch ([string]$Operation) {
            'register' {
                $record = [ordered]@{
                    task_name = $script:TelephoneSupervisorTaskName
                    principal = 'LimitedUser'
                    hidden = $true
                    logon_type = 'InteractiveToken'
                    action_script = [string]$ActionScript
                    action_arguments = [string]$ActionArguments
                    install_root = [string]$InstallRoot
                    restart_trigger = 'at-logon+one-minute-periodic'
                    registered = $true
                }
                [IO.File]::WriteAllText($recordPath, (ConvertTo-TelephoneSupervisorJson -Value $record), [Text.UTF8Encoding]::new($false))
                return $record
            }
            'unregister' {
                if ([IO.File]::Exists($recordPath)) { [IO.File]::Delete($recordPath) }
                return [ordered]@{ unregistered = $true }
            }
            'get' {
                if (-not [IO.File]::Exists($recordPath)) { return [ordered]@{ registered = $false } }
                $existing = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
                $existing['registered'] = $true
                if (-not $existing.Contains('action_script') -or [string]::IsNullOrWhiteSpace([string]$existing.action_script)) {
                    $existing['action_script'] = Get-TelephoneSupervisorTaskActionScript -Arguments $(if ($existing.Contains('action_arguments')) { [string]$existing.action_arguments } else { '' })
                }
                return $existing
            }
            'start' {
                if (-not [IO.File]::Exists($recordPath)) { throw 'Scheduled task identity is missing.' }
                $record = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
                $expected = [string]$ActionScript
                if (-not [string]::IsNullOrWhiteSpace($expected) -and [string]$record.action_script -cne $expected) {
                    throw 'Scheduled task action identity is wrong.'
                }
                $argTokens = [Collections.Generic.List[string]]::new()
                $argText = [string]$record.action_arguments
                if (-not [string]::IsNullOrWhiteSpace($argText)) {
                    foreach ($token in @([regex]::Matches($argText, '"([^"]*)"|(\S+)') | ForEach-Object {
                        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
                    })) {
                        [void]$argTokens.Add([string]$token)
                    }
                }
                $started = Start-TelephoneSupervisorDetachedPowerShell -ScriptPath ([string]$record.action_script) -Arguments @($argTokens)
                return [ordered]@{ started = $true; pid = [int]$started.pid }
            }
            default { throw 'Unknown task operation.' }
        }
    }
    return (Invoke-TelephoneSupervisorRealTaskOperation -Operation $Operation -InstallRoot $InstallRoot -ActionScript $ActionScript -ActionArguments $ActionArguments)
}

function Invoke-TelephoneSupervisorRealTaskOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [string]$InstallRoot,
        [string]$ActionScript,
        [string]$ActionArguments
    )
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        $installFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
        if (($installFull + '\').StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Supervisor task backend is required in this package test surface; real Task Scheduler mutation is reserved for Lead.'
        }
    }
    switch ([string]$Operation) {
        'register' {
            $definition = New-TelephoneSupervisorTaskActionDefinition -ActionScript $ActionScript -ActionArguments $ActionArguments
            $action = New-ScheduledTaskAction -Execute ([string]$definition.execute) -Argument ([string]$definition.arguments) -WorkingDirectory ([string]$InstallRoot)
            $principal = New-ScheduledTaskPrincipal -UserId ([string]$env:USERNAME) -LogonType Interactive -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -MultipleInstances IgnoreNew
            $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User ([string]$env:USERNAME)
            $timerTrigger = New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
            Register-ScheduledTask -TaskName $script:TelephoneSupervisorTaskName -Action $action -Trigger @($logonTrigger,$timerTrigger) -Principal $principal -Settings $settings -Force | Out-Null
            return [ordered]@{
                task_name = $script:TelephoneSupervisorTaskName
                principal = 'LimitedUser'
                hidden = $true
                logon_type = 'InteractiveToken'
                action_script = [string]$ActionScript
                action_arguments = [string]$definition.arguments
                install_root = [string]$InstallRoot
                restart_trigger = 'at-logon+one-minute-periodic'
                registered = $true
            }
        }
        'unregister' {
            Unregister-ScheduledTask -TaskName $script:TelephoneSupervisorTaskName -Confirm:$false -ErrorAction SilentlyContinue
            return [ordered]@{ unregistered = $true }
        }
        'get' {
            $task = Get-ScheduledTask -TaskName $script:TelephoneSupervisorTaskName -ErrorAction SilentlyContinue
            if ($null -eq $task) { return [ordered]@{ registered = $false } }
            $action = @($task.Actions)[0]
            $principal = $task.Principal
            $limited = ($null -ne $principal -and [string]$principal.RunLevel -ceq 'Limited')
            $argumentText = if ($null -ne $action) { [string]$action.Arguments } else { '' }
            $execute = if ($null -ne $action) { [string]$action.Execute } else { '' }
            $hasLogonTrigger = @($task.Triggers | Where-Object { [string]$_.CimClass.CimClassName -match 'LogonTrigger' }).Count -gt 0
            $hasPeriodicTrigger = @($task.Triggers | Where-Object { $null -ne $_.Repetition -and -not [string]::IsNullOrWhiteSpace([string]$_.Repetition.Interval) }).Count -gt 0
            return [ordered]@{
                registered = $true
                task_name = [string]$task.TaskName
                principal = $(if ($limited) { 'LimitedUser' } else { $(if ($null -ne $principal) { [string]$principal.RunLevel } else { '' }) })
                hidden = [bool]$task.Settings.Hidden
                logon_type = $(if ($null -ne $principal) { [string]$principal.LogonType } else { '' })
                execute = $execute
                action_arguments = $argumentText
                action_script = Get-TelephoneSupervisorTaskActionScript -Arguments $argumentText
                restart_trigger = $(if ($hasLogonTrigger -and $hasPeriodicTrigger) { 'at-logon+one-minute-periodic' } elseif ($hasLogonTrigger) { 'at-logon-only' } else { 'missing' })
            }
        }
        'start' {
            Start-ScheduledTask -TaskName $script:TelephoneSupervisorTaskName
            return [ordered]@{ started = $true }
        }
        default { throw 'Unknown task operation.' }
    }
}

function Get-TelephoneSupervisorDesktopRoot {
    [CmdletBinding()]
    param()
    if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_DESKTOP_ROOT)) {
        return [IO.Path]::GetFullPath([string]$env:TELEPHONE_LINE_DESKTOP_ROOT).TrimEnd('\')
    }
    return [IO.Path]::GetFullPath([Environment]::GetFolderPath('Desktop')).TrimEnd('\')
}

function Register-TelephoneSupervisorDesktopShortcuts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$ControlScript
    )
    $desktop = Get-TelephoneSupervisorDesktopRoot
    if (-not [IO.Directory]::Exists($desktop)) { [IO.Directory]::CreateDirectory($desktop) | Out-Null }
    $pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $shell = New-Object -ComObject WScript.Shell
    $rows = @(
        @{ name = $script:TelephoneSupervisorEmergencyShortcut; extra = '-Mode Emergency' },
        @{ name = $script:TelephoneSupervisorConsoleShortcut; extra = '-Mode Console' }
    )
    foreach ($row in $rows) {
        $path = Join-Path $desktop ([string]$row.name)
        $shortcut = $shell.CreateShortcut($path)
        $shortcut.TargetPath = $pwsh
        $shortcut.Arguments = ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $ControlScript + '" ' + [string]$row.extra)
        $shortcut.WorkingDirectory = $InstallRoot
        $shortcut.WindowStyle = 1
        $shortcut.Save()
    }
    return [ordered]@{ desktop = $desktop; emergency = $script:TelephoneSupervisorEmergencyShortcut; console = $script:TelephoneSupervisorConsoleShortcut }
}

function Unregister-TelephoneSupervisorDesktopShortcuts {
    [CmdletBinding()]
    param()
    $desktop = Get-TelephoneSupervisorDesktopRoot
    foreach ($name in @($script:TelephoneSupervisorEmergencyShortcut, $script:TelephoneSupervisorConsoleShortcut)) {
        $path = Join-Path $desktop $name
        if ([IO.File]::Exists($path)) {
            $null = Move-TelephonePathToRecycleBin -Path $path
        }
    }
}

function Test-TelephoneSupervisorDesktopShortcuts {
    [CmdletBinding()]
    param()
    $desktop = Get-TelephoneSupervisorDesktopRoot
    return [ordered]@{
        emergency = [IO.File]::Exists((Join-Path $desktop $script:TelephoneSupervisorEmergencyShortcut))
        console = [IO.File]::Exists((Join-Path $desktop $script:TelephoneSupervisorConsoleShortcut))
        desktop = $desktop
    }
}

function Test-TelephoneRecyclePathPresent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path))
}

function Reset-TelephoneRecycleAttemptLog {
    [CmdletBinding()]
    param()
    $script:TelephoneRecycleAttemptLog = [Collections.Generic.List[object]]::new()
}

function Get-TelephoneRecycleAttemptLog {
    [CmdletBinding()]
    param()
    if ($null -eq $script:TelephoneRecycleAttemptLog) {
        $script:TelephoneRecycleAttemptLog = [Collections.Generic.List[object]]::new()
    }
    return $script:TelephoneRecycleAttemptLog
}

function Add-TelephoneRecycleAttemptRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Record)
    try {
        if ($null -eq $script:TelephoneRecycleAttemptLog) {
            $script:TelephoneRecycleAttemptLog = [Collections.Generic.List[object]]::new()
        }
        if ($null -ne $script:TelephoneRecycleAttemptLog) {
            [void]$script:TelephoneRecycleAttemptLog.Add($Record)
        }
    } catch { }
}

function Test-TelephoneRecycleInjectTransient {
    [CmdletBinding()]
    param()
    if ([int]$script:TelephoneRecycleInjectNextNativeFailures -gt 0) { return $true }
    return ([string]$env:TELEPHONE_LINE_RECYCLE_INJECT_TRANSIENT -match '^(?i:1|true|yes|on)$')
}

function Consume-TelephoneRecycleInjectTransient {
    [CmdletBinding()]
    param()
    if ([int]$script:TelephoneRecycleInjectNextNativeFailures -gt 0) {
        $script:TelephoneRecycleInjectNextNativeFailures = [int]$script:TelephoneRecycleInjectNextNativeFailures - 1
    }
}

function Test-TelephoneRecycleReparse {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-TelephoneRecyclePathPresent -Path $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        return $false
    }
}

function Test-TelephoneRecycleOwnerRowLiveForeign {
    [CmdletBinding()]
    param([AllowNull()][object]$Owner)
    if ($null -eq $Owner -or $Owner -isnot [Collections.IDictionary]) { return $false }
    if (-not $Owner.Contains('pid') -or [int]$Owner.pid -le 0) { return $false }
    if ([int]$Owner.pid -eq [int]$PID) { return $false }
    if (-not $Owner.Contains('start_time_utc_ticks')) { return $false }
    return [bool](Test-TelephoneOwnerAlive -Owner $Owner)
}

function Test-TelephoneRecycleForeignLiveOwner {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not [IO.Directory]::Exists($full)) { return $false }
    $paths = Get-TelephoneSupervisorPaths -StateRoot $full
    if ([IO.File]::Exists($paths.supervisor_owner)) {
        try {
            $owner = (Read-TelephoneJson -Path $paths.supervisor_owner -SchemaName 'wired-supervisor-owner').value
            if (Test-TelephoneRecycleOwnerRowLiveForeign -Owner $owner) { return $true }
        } catch { }
    }
    foreach ($run in @(Get-TelephoneSupervisorActiveRunList -StateRoot $full)) {
        if ($null -eq $run -or $run -isnot [Collections.IDictionary]) { continue }
        if ($run.Contains('owner') -and (Test-TelephoneRecycleOwnerRowLiveForeign -Owner $run.owner)) { return $true }
    }
    return $false
}

function Confirm-TelephoneRecycleTargetReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedFull
    )
    $expected = [IO.Path]::GetFullPath($ExpectedFull).TrimEnd('\')
    if (-not (Test-TelephoneRecyclePathPresent -Path $expected)) {
        return [ordered]@{ exists = $false; full = $expected; revalidated = $true }
    }
    $resolved = [IO.Path]::GetFullPath($expected).TrimEnd('\')
    if (-not $resolved.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'RECYCLE_BLOCKED'
    }
    Assert-TelephoneRelativePathSafe -Path $resolved -Label 'Recycle target'
    if (Test-TelephoneRecycleReparse -Path $resolved) {
        throw 'Recycle target path is a reparse point.'
    }
    if (Test-TelephoneRecycleForeignLiveOwner -Path $resolved) {
        throw 'RECYCLE_BLOCKED'
    }
    return [ordered]@{ exists = $true; full = $resolved; revalidated = $true }
}

function Wait-TelephoneRecycleOwnershipQuiescence {
    [CmdletBinding()]
    param(
        [string]$StateRoot,
        [int]$WaitMilliseconds = 0
    )
    try {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    } catch { }
    if ([string]::IsNullOrWhiteSpace($StateRoot) -or -not [IO.Directory]::Exists($StateRoot)) {
        return [ordered]@{ quiet = $true; reason = 'absent'; waited_ms = 0 }
    }
    $root = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    $waitMs = [int]$WaitMilliseconds
    if ($waitMs -le 0) { $waitMs = [int]$script:TelephoneRecycleQuiescenceMilliseconds }
    $started = [DateTimeOffset]::UtcNow
    $deadline = $started.AddMilliseconds([Math]::Max(0, $waitMs))
    $reason = 'quiet'
    [Threading.Mutex]$held = $null
    do {
        $busy = $false
        $reason = 'quiet'
        $paths = Get-TelephoneSupervisorPaths -StateRoot $root
        if ([IO.File]::Exists($paths.supervisor_owner)) {
            try {
                $owner = (Read-TelephoneJson -Path $paths.supervisor_owner -SchemaName 'wired-supervisor-owner').value
                if ((Test-TelephoneOwnerAlive -Owner $owner) -and [int]$owner.pid -ne [int]$PID) {
                    $busy = $true
                    $reason = 'live-supervisor-owner'
                }
            } catch { }
        }
        if (-not $busy) {
            foreach ($run in @(Get-TelephoneSupervisorActiveRunList -StateRoot $root)) {
                if ([bool]$run.alive -or [bool]$run.job_backed) {
                    $busy = $true
                    $reason = 'live-run-job'
                    break
                }
            }
        }
        if (-not $busy) {
            $held = $null
            try {
                $mutexName = Get-TelephoneSupervisorMutexName -StateRoot $root
                if ([Threading.Mutex]::TryOpenExisting($mutexName, [ref]$held)) {
                    $busy = $true
                    $reason = 'mutex-held'
                }
            } catch { }
            finally {
                if ($null -ne $held) {
                    $held.Dispose()
                    $held = $null
                }
            }
        }
        if (-not $busy) {
            $lockFiles = [Collections.Generic.List[string]]::new()
            foreach ($candidate in @($paths.pause, $paths.supervisor_owner)) {
                if ([IO.File]::Exists($candidate)) { [void]$lockFiles.Add($candidate) }
            }
            $probed = 0
            foreach ($dir in @($paths.control, $paths.inbox, $paths.claimed, $paths.runs)) {
                if (-not [IO.Directory]::Exists($dir)) { continue }
                foreach ($file in [IO.Directory]::EnumerateFiles($dir)) {
                    if ($probed -ge 32) { break }
                    [void]$lockFiles.Add($file)
                    $probed += 1
                }
                if ($probed -ge 32) { break }
            }
            foreach ($file in $lockFiles) {
                $stream = $null
                try {
                    $stream = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
                } catch {
                    $busy = $true
                    $reason = 'file-lock'
                    break
                } finally {
                    if ($null -ne $stream) { $stream.Dispose() }
                }
            }
        }
        if (-not $busy) {
            return [ordered]@{
                quiet = $true
                reason = 'quiet'
                waited_ms = [int]([DateTimeOffset]::UtcNow - $started).TotalMilliseconds
            }
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            return [ordered]@{
                quiet = $false
                reason = $reason
                waited_ms = [int]([DateTimeOffset]::UtcNow - $started).TotalMilliseconds
            }
        }
        Start-Sleep -Milliseconds 50
    } while ($true)
}

function Move-TelephonePathToRecycleBin {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $records = [Collections.Generic.List[object]]::new()
    try { $script:TelephoneRecycleAttemptLog = $records } catch { }
    if (-not (Test-TelephoneRecyclePathPresent -Path $full)) {
        return [ordered]@{ recycled = $false; missing = $true; attempts = 0; revalidated = $false; attempt_records = @() }
    }
    $ready = Confirm-TelephoneRecycleTargetReady -ExpectedFull $full
    if (-not [bool]$ready.exists) {
        return [ordered]@{ recycled = $false; missing = $true; attempts = 0; revalidated = $true }
    }
    $full = [string]$ready.full
    $recycleRoot = [string]$env:TELEPHONE_LINE_RECYCLE_ROOT
    if (-not [string]::IsNullOrWhiteSpace($recycleRoot)) {
        $destRoot = [IO.Path]::GetFullPath($recycleRoot).TrimEnd('\')
        if (-not [IO.Directory]::Exists($destRoot)) { [IO.Directory]::CreateDirectory($destRoot) | Out-Null }
        $name = [IO.Path]::GetFileName($full)
        $dest = Join-Path $destRoot ($name + '-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($dest) | Out-Null
        $leaf = Join-Path $dest $name
        try {
            if ([IO.Directory]::Exists($full)) {
                [IO.Directory]::Move($full, $leaf)
            } else {
                [IO.File]::Move($full, $leaf)
            }
        } catch {
            [void]$records.Add(([ordered]@{
                path = $full
                attempt = 1
                code = -1
                injected = $false
                existed_before = $true
                existed_after = (Test-TelephoneRecyclePathPresent -Path $full)
                revalidated = $true
                backend = 'fake'
            }))
            if (Test-TelephoneRecyclePathPresent -Path $full) { throw 'RECYCLE_BLOCKED' }
            return [ordered]@{ recycled = $true; recoverable = $true; attempts = 1; revalidated = $true; backend = 'fake'; destination = $leaf; attempt_records = @($records) }
        }
        [void]$records.Add(([ordered]@{
            path = $full
            attempt = 1
            code = 0
            injected = $false
            existed_before = $true
            existed_after = (Test-TelephoneRecyclePathPresent -Path $full)
            revalidated = $true
            backend = 'fake'
        }))
        if (Test-TelephoneRecyclePathPresent -Path $full) { throw 'RECYCLE_BLOCKED' }
        return [ordered]@{ recycled = $true; destination = $leaf; recoverable = $true; attempts = 1; revalidated = $true; backend = 'fake'; attempt_records = @($records) }
    }
    Initialize-TelephoneSupervisorNative
    $max = 8
    try { if ([int]$script:TelephoneRecycleMaxAttempts -ge 2) { $max = [int]$script:TelephoneRecycleMaxAttempts } } catch { }
    $delay = 75
    try { if ([int]$script:TelephoneRecycleRetryDelayMilliseconds -ge 1) { $delay = [int]$script:TelephoneRecycleRetryDelayMilliseconds } } catch { }
    $attempts = 0
    $revalidated = $false
    $lastCode = 0
    while ($attempts -lt $max) {
        $attempts += 1
        if ($attempts -gt 1) {
            $revalidated = $true
            $again = Confirm-TelephoneRecycleTargetReady -ExpectedFull $full
            if (-not [bool]$again.exists) {
                [void]$records.Add(([ordered]@{
                    path = $full
                    attempt = $attempts
                    code = [int]$lastCode
                    injected = $false
                    existed_before = $false
                    existed_after = $false
                    revalidated = $true
                    backend = 'native'
                    disappeared = $true
                }))
                return [ordered]@{ recycled = $true; recoverable = $true; code = [int]$lastCode; attempts = [int]$attempts; revalidated = $true; backend = 'native'; attempt_records = @($records) }
            }
            Start-Sleep -Milliseconds $delay
        }
        $existedBefore = Test-TelephoneRecyclePathPresent -Path $full
        $injected = $false
        if ($attempts -eq 1 -and (Test-TelephoneRecycleInjectTransient)) {
            Consume-TelephoneRecycleInjectTransient
            $lastCode = 32
            $injected = $true
        } else {
            $lastCode = [int][TelephoneWiredSupervisorNative.Native]::RecyclePath($full)
        }
        $existedAfter = Test-TelephoneRecyclePathPresent -Path $full
        [void]$records.Add(([ordered]@{
            path = $full
            attempt = [int]$attempts
            code = [int]$lastCode
            injected = [bool]$injected
            existed_before = [bool]$existedBefore
            existed_after = [bool]$existedAfter
            revalidated = [bool]$revalidated
            backend = 'native'
        }))
        if (-not $existedAfter) {
            return [ordered]@{
                recycled = $true
                recoverable = $true
                code = [int]$lastCode
                attempts = [int]$attempts
                revalidated = [bool]$revalidated
                backend = 'native'
                attempt_records = @($records)
            }
        }
    }
    throw 'RECYCLE_BLOCKED'
}

function New-TelephoneSupervisorRunJob {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RunId)
    Initialize-TelephoneSupervisorNative
    $name = Get-TelephoneSupervisorJobName -RunId $RunId
    $handle = [TelephoneWiredSupervisorNative.Native]::CreateNamedKillOnCloseJob($name)
    return [ordered]@{ name = $name; handle = $handle }
}

function Open-TelephoneSupervisorRunJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [int]$WaitMilliseconds = 2000
    )
    Initialize-TelephoneSupervisorNative
    $name = Get-TelephoneSupervisorJobName -RunId $RunId
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds([Math]::Max(0, [int]$WaitMilliseconds))
    $errorCode = 0
    do {
        $handle = [TelephoneWiredSupervisorNative.Native]::TryOpenJob($name, [ref]$errorCode)
        if ($handle -ne [IntPtr]::Zero) {
            return [ordered]@{ name = $name; handle = $handle; error = 0 }
        }
        if ([int]$WaitMilliseconds -le 0) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    return [ordered]@{ name = $name; handle = [IntPtr]::Zero; error = [int]$errorCode }
}

function Close-TelephoneSupervisorRunJob {
    [CmdletBinding()]
    param([AllowNull()][object]$Job)
    if ($null -eq $Job -or $null -eq $Job.handle -or [IntPtr]$Job.handle -eq [IntPtr]::Zero) { return }
    Initialize-TelephoneSupervisorNative
    [void][TelephoneWiredSupervisorNative.Native]::CloseHandle([IntPtr]$Job.handle)
}

function Stop-TelephoneSupervisorRunJob {
    [CmdletBinding()]
    param([AllowNull()][object]$Job)
    if ($null -eq $Job -or $null -eq $Job.handle -or [IntPtr]$Job.handle -eq [IntPtr]::Zero) { return $false }
    Initialize-TelephoneSupervisorNative
    return [bool][TelephoneWiredSupervisorNative.Native]::TerminateJobObject([IntPtr]$Job.handle, 1)
}

function Add-TelephoneSupervisorPidToRunJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )
    if ($ProcessId -le 0) { return $false }
    if ($null -eq $Job -or $null -eq $Job.handle -or [IntPtr]$Job.handle -eq [IntPtr]::Zero) { return $false }
    if (Test-TelephoneSupervisorPidInJob -Job $Job -ProcessId $ProcessId) { return $true }
    Initialize-TelephoneSupervisorNative
    $process = [TelephoneWiredSupervisorNative.Native]::OpenProcess(0x00000101, $false, [int]$ProcessId)
    if ($process -eq [IntPtr]::Zero) {
        $process = [TelephoneWiredSupervisorNative.Native]::OpenProcess(0x001F0FFF, $false, [int]$ProcessId)
    }
    if ($process -eq [IntPtr]::Zero) { return $false }
    try {
        return [bool][TelephoneWiredSupervisorNative.Native]::AssignProcessToJobObject([IntPtr]$Job.handle, $process)
    } finally {
        [void][TelephoneWiredSupervisorNative.Native]::CloseHandle($process)
    }
}

function Sync-TelephoneSupervisorMailboxBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][object]$Job,
        [string]$RelayScript = ''
    )
    $binding = [ordered]@{
        protocol_version = 'telephone-line-wired-supervisor-mailbox-v1'
        run_id = [string]$RunId
        lead_identity_sha256 = ''
        lead_session_id = ''
        mailbox_batch_id = ''
        mailbox_counted = 0
        mailbox_n = 0
        mailbox_state = ''
        collector_pid = 0
        collector_in_job = $false
    }
    $telState = [string]$env:TELEPHONE_LINE_STATE_ROOT
    $paths = Get-TelephoneSupervisorPaths -StateRoot $StateRoot
    $runDir = Join-Path $paths.runs $RunId
    $mailboxPath = Join-Path $runDir 'mailbox.json'
    if ([string]::IsNullOrWhiteSpace($telState) -or -not [IO.Directory]::Exists($telState)) {
        $null = Write-TelephoneJsonReplace -Path $mailboxPath -Value $binding
        return $binding
    }
    $leadKeys = [Collections.Generic.List[string]]::new()
    $jobsRoot = Join-Path $telState 'jobs'
    $needsCollector = $false
    if ([IO.Directory]::Exists($jobsRoot)) {
        foreach ($dir in @([IO.Directory]::GetDirectories($jobsRoot))) {
            $lineagePath = Join-Path $dir 'supervisor-lineage.json'
            if (-not [IO.File]::Exists($lineagePath)) { continue }
            try {
                $lineage = (Read-TelephoneJson -Path $lineagePath).value
            } catch {
                continue
            }
            if ($lineage -isnot [Collections.IDictionary]) { continue }
            if ([string]$lineage.supervisor_run_id -cne [string]$RunId) { continue }
            $leadKey = ''
            if ($lineage.Contains('lead_identity_sha256')) { $leadKey = [string]$lineage.lead_identity_sha256 }
            if (-not [string]::IsNullOrWhiteSpace($leadKey) -and -not $leadKeys.Contains($leadKey)) { [void]$leadKeys.Add($leadKey) }
            if ([string]::IsNullOrWhiteSpace([string]$binding.lead_session_id) -and $lineage.Contains('lead_session_id')) {
                $binding.lead_session_id = [string]$lineage.lead_session_id
            }
            if ([string]::IsNullOrWhiteSpace([string]$binding.mailbox_batch_id) -and $lineage.Contains('batch_id')) {
                $binding.mailbox_batch_id = [string]$lineage.batch_id
            }
            $jobPaths = Get-TelephoneJobPaths -JobRoot $dir
            if (-not [IO.File]::Exists($jobPaths.delivery) -and -not [IO.File]::Exists($jobPaths.relay_error)) {
                $needsCollector = $true
            }
        }
    }
    foreach ($leadKey in @($leadKeys)) {
        $binding.lead_identity_sha256 = [string]$leadKey
        $mailbox = Get-TelephoneLeadMailboxPaths -StateRoot $telState -LeadKey $leadKey
        if ([IO.File]::Exists([string]$mailbox.truth)) {
            try {
                $truth = (Read-TelephoneJson -Path ([string]$mailbox.truth)).value
                foreach ($batch in @($truth.batches)) {
                    if ($batch -isnot [Collections.IDictionary]) { continue }
                    if (-not [string]::IsNullOrWhiteSpace([string]$binding.mailbox_batch_id) -and $batch.Contains('batch_id') -and [string]$batch.batch_id -cne [string]$binding.mailbox_batch_id) { continue }
                    if ($batch.Contains('counted')) { $binding.mailbox_counted = [int]$batch.counted }
                    if ($batch.Contains('n')) { $binding.mailbox_n = [int]$batch.n }
                    if ($batch.Contains('state') -and -not [string]::IsNullOrWhiteSpace([string]$batch.state)) { $binding.mailbox_state = [string]$batch.state }
                    if ([string]::IsNullOrWhiteSpace([string]$binding.mailbox_batch_id) -and $batch.Contains('batch_id')) { $binding.mailbox_batch_id = [string]$batch.batch_id }
                    break
                }
            } catch { }
        }
        $collectorPid = 0
        if ([IO.File]::Exists([string]$mailbox.owner)) {
            try {
                $owner = (Read-TelephoneJson -Path ([string]$mailbox.owner)).value
                if (Test-TelephoneOwnerAlive -Owner $owner) { $collectorPid = [int]$owner.pid }
            } catch { }
        }
        if ($collectorPid -le 0 -and $needsCollector -and -not [string]::IsNullOrWhiteSpace($RelayScript) -and [IO.File]::Exists($RelayScript)) {
            try {
                $ensured = Ensure-TelephoneLeadCollector -StateRoot $telState -LeadKey $leadKey -RelayScript $RelayScript
                if ($null -ne $ensured -and $ensured -is [Collections.IDictionary] -and $ensured.Contains('pid')) {
                    $collectorPid = [int]$ensured.pid
                }
            } catch { }
        }
        if ($collectorPid -gt 0) {
            $binding.collector_pid = [int]$collectorPid
            $inJob = $false
            try { $inJob = Test-TelephoneSupervisorPidInJob -Job $Job -ProcessId $collectorPid } catch { $inJob = $false }
            if (-not $inJob) {
                try { $null = Add-TelephoneSupervisorPidToRunJob -Job $Job -ProcessId $collectorPid } catch { }
                try { $inJob = Test-TelephoneSupervisorPidInJob -Job $Job -ProcessId $collectorPid } catch { $inJob = $false }
            }
            $binding.collector_in_job = [bool]$inJob
        }
    }
    $null = Write-TelephoneJsonReplace -Path $mailboxPath -Value $binding
    return $binding
}

function Test-TelephoneSupervisorPidInJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )
    Initialize-TelephoneSupervisorNative
    $process = [TelephoneWiredSupervisorNative.Native]::OpenProcess(0x1000, $false, [int]$ProcessId)
    if ($process -eq [IntPtr]::Zero) { return $false }
    try {
        return [bool][TelephoneWiredSupervisorNative.Native]::ProcessInJob($process, [IntPtr]$Job.handle)
    } finally {
        [void][TelephoneWiredSupervisorNative.Native]::CloseHandle($process)
    }
}

function Get-TelephoneSupervisorJobProcessIds {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Job)
    Initialize-TelephoneSupervisorNative
    return @([TelephoneWiredSupervisorNative.Native]::JobProcessIds([IntPtr]$Job.handle))
}

function ConvertTo-TelephoneSupervisorCommandLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [AllowEmptyCollection()][string[]]$Arguments
    )
    $parts = [Collections.Generic.List[string]]::new()
    [void]$parts.Add('"' + $FileName.Replace('"', '""') + '"')
    foreach ($argument in @($Arguments)) {
        $text = [string]$argument
        if ($text -match '[\s"]') {
            [void]$parts.Add('"' + $text.Replace('"', '""') + '"')
        } else {
            [void]$parts.Add($text)
        }
    }
    return ([string]::Join(' ', $parts))
}

function Start-TelephoneSupervisorDetachedPowerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [AllowEmptyCollection()][string[]]$Arguments
    )
    Initialize-TelephoneSupervisorNative
    $powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $scriptFull = Assert-TelephoneRegularFilePath -Path $ScriptPath -Label 'Supervisor detached script'
    $commandLine = ConvertTo-TelephoneSupervisorCommandLine -FileName $powerShellPath -Arguments ((
        @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptFull) + @($Arguments)
    ))
    $cwd = [IO.Path]::GetDirectoryName($scriptFull)
    $pidValue = [TelephoneWiredSupervisorNative.Native]::StartDetached($powerShellPath, $commandLine, $cwd)
    $proc = Get-Process -Id $pidValue -ErrorAction Stop
    try {
        return [ordered]@{
            pid = [int]$proc.Id
            start_time_utc_ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
            started_at_utc = $proc.StartTime.ToUniversalTime().ToString('o')
        }
    } finally {
        $proc.Dispose()
    }
}

function Start-TelephoneSupervisorLeadInJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [AllowEmptyCollection()][string[]]$Arguments
    )
    Initialize-TelephoneSupervisorNative
    $exe = Assert-TelephoneRegularFilePath -Path $Executable -Label 'Supervisor lead executable'
    $cwd = Assert-TelephoneDirectoryPath -Path $WorkingDirectory -Label 'Supervisor lead working directory'
    $commandLine = ConvertTo-TelephoneSupervisorCommandLine -FileName $exe -Arguments @($Arguments)
    $pidValue = [TelephoneWiredSupervisorNative.Native]::StartSuspendedInJob([IntPtr]$Job.handle, $exe, $commandLine, $cwd)
    $proc = Get-Process -Id $pidValue -ErrorAction Stop
    try {
        return [ordered]@{
            pid = [int]$proc.Id
            start_time_utc_ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
            started_at_utc = $proc.StartTime.ToUniversalTime().ToString('o')
        }
    } finally {
        $proc.Dispose()
    }
}

function Get-TelephoneSupervisorProcessIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        try {
            return [ordered]@{
                pid = [int]$proc.Id
                start_time_utc_ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
                started_at_utc = $proc.StartTime.ToUniversalTime().ToString('o')
            }
        } finally {
            $proc.Dispose()
        }
    } catch {
        return $null
    }
}

function Write-TelephoneSupervisorJobMembers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][object]$Job,
        [AllowNull()][object]$LeadIdentity
    )
    $pids = @(Get-TelephoneSupervisorJobProcessIds -Job $Job)
    $members = [Collections.Generic.List[object]]::new()
    foreach ($pidValue in $pids) {
        $identity = Get-TelephoneSupervisorProcessIdentity -ProcessId ([int]$pidValue)
        if ($null -ne $identity) { [void]$members.Add($identity) }
    }
    $value = [ordered]@{
        run_id = [string]$RunId
        job_name = [string]$Job.name
        lead_pid = $(if ($null -ne $LeadIdentity -and $LeadIdentity.Contains('pid')) { [int]$LeadIdentity.pid } else { 0 })
        lead_start_time_utc_ticks = $(if ($null -ne $LeadIdentity -and $LeadIdentity.Contains('start_time_utc_ticks')) { [int64]$LeadIdentity.start_time_utc_ticks } else { [int64]0 })
        job_pids = @($pids | ForEach-Object { [int]$_ })
        members = @($members)
    }
    $null = Write-TelephoneJsonReplace -Path $Path -Value $value
    return $value
}

function Read-TelephoneSupervisorJobMembers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $memberPath = Join-Path (Join-Path (Get-TelephoneSupervisorPaths -StateRoot $StateRoot).runs $RunId) 'job-members.json'
    return (Read-TelephoneSupervisorOptionalRecord -Path $memberPath)
}

function Test-TelephoneSupervisorLiveExactMembers {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$MemberRecord,
        [AllowNull()][object]$Job
    )
    if ($null -eq $MemberRecord) { return $false }
    $value = if ($MemberRecord -is [Collections.IDictionary] -and $MemberRecord.Contains('value')) { $MemberRecord.value } else { $MemberRecord }
    if ($value -isnot [Collections.IDictionary]) { return $false }
    $rows = [Collections.Generic.List[object]]::new()
    if ($value.Contains('members')) {
        foreach ($row in @($value.members)) {
            if ($row -is [Collections.IDictionary]) { [void]$rows.Add($row) }
        }
    }
    if ($rows.Count -eq 0 -and $value.Contains('job_pids')) {
        foreach ($pidValue in @($value.job_pids)) {
            [void]$rows.Add([ordered]@{ pid = [int]$pidValue })
        }
    }
    if ($value.Contains('lead_pid') -and [int]$value.lead_pid -gt 0) {
        $lead = [ordered]@{ pid = [int]$value.lead_pid }
        if ($value.Contains('lead_start_time_utc_ticks') -and [int64]$value.lead_start_time_utc_ticks -gt 0) {
            $lead.start_time_utc_ticks = [int64]$value.lead_start_time_utc_ticks
        }
        [void]$rows.Add($lead)
    }
    foreach ($row in $rows) {
        $alive = $false
        if ($row.Contains('start_time_utc_ticks')) {
            $alive = Test-TelephoneOwnerAlive -Owner $row
        } else {
            try {
                $proc = Get-Process -Id ([int]$row.pid) -ErrorAction Stop
                $proc.Dispose()
                $alive = $true
            } catch { $alive = $false }
        }
        if (-not $alive) { continue }
        if ($null -ne $Job -and $null -ne $Job.handle -and [IntPtr]$Job.handle -ne [IntPtr]::Zero) {
            if (Test-TelephoneSupervisorPidInJob -Job $Job -ProcessId ([int]$row.pid)) { return $true }
        } else {
            return $true
        }
    }
    return $false
}

function Stop-TelephoneSupervisorExactRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $ownerRead = Read-TelephoneSupervisorRunOwner -StateRoot $StateRoot -RunId $RunId
    if ($null -eq $ownerRead) {
        return [ordered]@{ stopped = $false; reason = 'owner-missing' }
    }
    $owner = $ownerRead.value
    $runDir = Join-Path (Get-TelephoneSupervisorPaths -StateRoot $StateRoot).runs $RunId
    $stopPath = Join-Path $runDir 'stop.requested'
    $hostAlive = Test-TelephoneSupervisorExactOwner -Owner $owner
    $pidExists = $false
    try {
        $probe = Get-Process -Id ([int]$owner.pid) -ErrorAction Stop
        $probe.Dispose()
        $pidExists = $true
    } catch { $pidExists = $false }
    if ($pidExists -and -not $hostAlive) {
        return [ordered]@{ stopped = $false; reason = 'pid-reuse-or-stale' }
    }
    $memberRead = Read-TelephoneSupervisorJobMembers -StateRoot $StateRoot -RunId $RunId
    $job = Open-TelephoneSupervisorRunJob -RunId $RunId
    try {
        $jobOpen = ($null -ne $job -and [IntPtr]$job.handle -ne [IntPtr]::Zero)
        if (-not $jobOpen) {
            if (-not $hostAlive) {
                return [ordered]@{ stopped = $false; reason = 'job-missing-and-owner-dead' }
            }
            if (Test-TelephoneSupervisorLiveExactMembers -MemberRecord $memberRead -Job $null) {
                $null = [IO.Directory]::CreateDirectory($runDir)
                [IO.File]::WriteAllText($stopPath, "stop`n")
                return [ordered]@{ stopped = $true; reason = 'stop-signaled'; owner = $owner }
            }
            return [ordered]@{ stopped = $false; reason = 'job-missing' }
        }
        $expectedName = Get-TelephoneSupervisorJobName -RunId $RunId
        if ($owner.Contains('job_name') -and -not [string]::IsNullOrWhiteSpace([string]$owner.job_name) -and [string]$owner.job_name -cne $expectedName) {
            return [ordered]@{ stopped = $false; reason = 'foreign-process' }
        }
        $memberInJob = Test-TelephoneSupervisorLiveExactMembers -MemberRecord $memberRead -Job $job
        $leadInJob = $false
        if ($owner.Contains('lead_pid') -and [int]$owner.lead_pid -gt 0) {
            $leadInJob = Test-TelephoneSupervisorPidInJob -Job $job -ProcessId ([int]$owner.lead_pid)
            if ($leadInJob -and $owner.Contains('lead_start_time_utc_ticks')) {
                $leadAlive = Test-TelephoneOwnerAlive -Owner ([ordered]@{ pid = [int]$owner.lead_pid; start_time_utc_ticks = [int64]$owner.lead_start_time_utc_ticks })
                if (-not $leadAlive) {
                    $leadProc = Get-TelephoneSupervisorProcessIdentity -ProcessId ([int]$owner.lead_pid)
                    if ($null -ne $leadProc) {
                        return [ordered]@{ stopped = $false; reason = 'pid-reuse-or-stale' }
                    }
                    $leadInJob = $false
                }
            }
        }
        $jobIds = @(Get-TelephoneSupervisorJobProcessIds -Job $job)
        if (-not $hostAlive -and -not $memberInJob -and -not $leadInJob -and $jobIds.Count -eq 0) {
            return [ordered]@{ stopped = $false; reason = 'job-missing-and-owner-dead' }
        }
        if (-not $hostAlive -and -not $memberInJob -and -not $leadInJob) {
            return [ordered]@{ stopped = $false; reason = 'foreign-process' }
        }
        $null = [IO.Directory]::CreateDirectory($runDir)
        [IO.File]::WriteAllText($stopPath, "stop`n")
        $stopped = Stop-TelephoneSupervisorRunJob -Job $job
        if ([bool]$stopped) {
            return [ordered]@{ stopped = $true; reason = 'job-terminated'; owner = $owner }
        }
        return [ordered]@{ stopped = $true; reason = 'stop-signaled'; owner = $owner }
    } finally {
        Close-TelephoneSupervisorRunJob -Job $job
    }
}

function Get-TelephoneSupervisorActiveRuns {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $paths = Get-TelephoneSupervisorPaths -StateRoot $StateRoot
    $runs = [Collections.Generic.List[object]]::new()
    if (-not [IO.Directory]::Exists($paths.runs)) { return @() }
    foreach ($dir in [IO.Directory]::EnumerateDirectories($paths.runs)) {
        $item = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $runId = [string]$item.Name
        $ownerRead = Read-TelephoneSupervisorRunOwner -StateRoot $StateRoot -RunId $runId
        if ($null -eq $ownerRead) { continue }
        $outboxPath = Get-TelephoneSupervisorRecordPath -StateRoot $StateRoot -Kind outbox -RunId $runId
        if ([IO.File]::Exists($outboxPath)) { continue }
        $alive = Test-TelephoneSupervisorExactOwner -Owner $ownerRead.value
        $claimedPath = Get-TelephoneSupervisorRecordPath -StateRoot $StateRoot -Kind claimed -RunId $runId
        $memberRead = Read-TelephoneSupervisorJobMembers -StateRoot $StateRoot -RunId $runId
        $job = Open-TelephoneSupervisorRunJob -RunId $runId -WaitMilliseconds 0
        try {
            $memberLive = Test-TelephoneSupervisorLiveExactMembers -MemberRecord $memberRead -Job $job
            $jobOpen = ($null -ne $job -and [IntPtr]$job.handle -ne [IntPtr]::Zero)
            $jobBacked = [bool]$alive -or [bool]$memberLive -or ([bool]$jobOpen -and [IO.File]::Exists($claimedPath))
        } finally {
            Close-TelephoneSupervisorRunJob -Job $job
        }
        [void]$runs.Add([ordered]@{
            run_id = $runId
            owner = $ownerRead.value
            alive = [bool]$alive
            job_backed = [bool]$jobBacked
            project = $(if ($ownerRead.value.Contains('project')) { [string]$ownerRead.value.project } else { '' })
            stage = $(if ($ownerRead.value.Contains('stage')) { [string]$ownerRead.value.stage } else { '' })
            lead_session_id = $(if ($ownerRead.value.Contains('lead_session_id')) { [string]$ownerRead.value.lead_session_id } else { '' })
            name = $(if ($ownerRead.value.Contains('project')) { [string]$ownerRead.value.project } else { $runId })
            version_id = $(if ($ownerRead.value.Contains('installed_version')) { [string]$ownerRead.value.installed_version.version_id } else { '' })
        })
    }
    return $runs
}

function ConvertTo-TelephoneSupervisorRunList {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    $list = [Collections.Generic.List[object]]::new()
    if ($null -eq $Value) { return $list }
    if ($Value -is [Collections.IDictionary]) {
        [void]$list.Add($Value)
        return $list
    }
    foreach ($item in @($Value)) {
        if ($item -is [Collections.IDictionary] -and $item.Contains('run_id')) {
            [void]$list.Add($item)
        }
    }
    return $list
}

function Get-TelephoneSupervisorActiveRunList {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    return (ConvertTo-TelephoneSupervisorRunList -Value (Get-TelephoneSupervisorActiveRuns -StateRoot $StateRoot))
}

function Get-TelephoneSupervisorStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$InstallRoot
    )
    $paths = Initialize-TelephoneSupervisorLayout -StateRoot $StateRoot
    $pause = Get-TelephoneSupervisorPause -StateRoot $StateRoot
    $active = [Collections.Generic.List[object]]::new()
    foreach ($run in @(Get-TelephoneSupervisorActiveRunList -StateRoot $StateRoot)) {
        if ([bool]$run.job_backed) { [void]$active.Add($run) }
    }
    $inboxCount = @([IO.Directory]::EnumerateFiles($paths.inbox, '*.json')).Count
    $claimedCount = @([IO.Directory]::EnumerateFiles($paths.claimed, '*.json')).Count
    $outboxCount = @([IO.Directory]::EnumerateFiles($paths.outbox, '*.json')).Count
    $supervisorAlive = $false
    $supervisorPid = 0
    $supervisorTicks = [int64]0
    if ([IO.File]::Exists($paths.supervisor_owner)) {
        $owner = (Read-TelephoneJson -Path $paths.supervisor_owner -SchemaName 'wired-supervisor-owner').value
        $supervisorAlive = Test-TelephoneSupervisorExactOwner -Owner $owner
        $supervisorPid = [int]$owner.pid
        $supervisorTicks = [int64]$owner.start_time_utc_ticks
    }
    $pinned = [Collections.Generic.List[string]]::new()
    foreach ($run in @($active)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$run.version_id) -and -not $pinned.Contains([string]$run.version_id)) {
            [void]$pinned.Add([string]$run.version_id)
        }
    }
    $currentVersion = ''
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        $pointerPath = Join-Path $InstallRoot 'current.json'
        if ([IO.File]::Exists($pointerPath)) {
            $pointer = (Read-TelephoneJson -Path $pointerPath).value
            if ($pointer.Contains('version_id')) { $currentVersion = [string]$pointer.version_id }
        }
    }
    $status = [ordered]@{
        protocol_version = $script:TelephoneSupervisorStatusProtocol
        paused_by_pascal = [bool]$pause.paused_by_pascal
        supervisor_alive = [bool]$supervisorAlive
        supervisor_pid = [int]$supervisorPid
        supervisor_start_time_utc_ticks = [int64]$supervisorTicks
        inbox_count = [int]$inboxCount
        claimed_count = [int]$claimedCount
        outbox_count = [int]$outboxCount
        active_runs = @(
            foreach ($run in $active) {
                $row = [ordered]@{
                    run_id = [string]$run.run_id
                    project = $(if ([string]::IsNullOrWhiteSpace([string]$run.project)) { 'wired-run' } else { [string]$run.project })
                    stage = $(if ([string]::IsNullOrWhiteSpace([string]$run.stage)) { 'active' } else { [string]$run.stage })
                    name = $(if ([string]::IsNullOrWhiteSpace([string]$run.name)) { [string]$run.run_id } else { [string]$run.name })
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$run.lead_session_id)) {
                    $row.lead_session_id = [string]$run.lead_session_id
                }
                $mailboxPath = Join-Path (Join-Path $paths.runs ([string]$run.run_id)) 'mailbox.json'
                if ([IO.File]::Exists($mailboxPath)) {
                    try {
                        $mailbox = (Read-TelephoneJson -Path $mailboxPath).value
                        if ($mailbox -is [Collections.IDictionary]) {
                            if ($mailbox.Contains('lead_identity_sha256') -and [string]$mailbox.lead_identity_sha256 -cmatch '^[0-9a-f]{64}$') {
                                $row.lead_identity_sha256 = [string]$mailbox.lead_identity_sha256
                            }
                            if ($mailbox.Contains('mailbox_batch_id') -and [string]$mailbox.mailbox_batch_id -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
                                $row.mailbox_batch_id = [string]$mailbox.mailbox_batch_id
                            }
                            if ($mailbox.Contains('mailbox_counted')) { $row.mailbox_counted = [int]$mailbox.mailbox_counted }
                            if ($mailbox.Contains('mailbox_n')) { $row.mailbox_n = [int]$mailbox.mailbox_n }
                            if ($mailbox.Contains('mailbox_state') -and -not [string]::IsNullOrWhiteSpace([string]$mailbox.mailbox_state)) {
                                $row.mailbox_state = [string]$mailbox.mailbox_state
                            }
                            if ($mailbox.Contains('collector_pid')) { $row.collector_pid = [int]$mailbox.collector_pid }
                            if ($mailbox.Contains('collector_in_job')) { $row.collector_in_job = [bool]$mailbox.collector_in_job }
                            if ([string]::IsNullOrWhiteSpace([string]$row.lead_session_id) -and $mailbox.Contains('lead_session_id') -and -not [string]::IsNullOrWhiteSpace([string]$mailbox.lead_session_id)) {
                                $row.lead_session_id = [string]$mailbox.lead_session_id
                            }
                        }
                    } catch { }
                }
                $row
            }
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($currentVersion)) { $status.current_version_id = $currentVersion }
    if ($pinned.Count -gt 0) { $status.pinned_version_ids = @($pinned) }
    $json = ConvertTo-TelephoneSupervisorJson -Value $status
    Assert-TelephoneJsonSchema -JsonText $json -SchemaName 'wired-supervisor-status' -Label 'wired supervisor status'
    return $status
}

function Reconcile-TelephoneSupervisorClaimed {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $paths = Initialize-TelephoneSupervisorLayout -StateRoot $StateRoot
    $reconciled = [Collections.Generic.List[object]]::new()
    foreach ($file in [IO.Directory]::EnumerateFiles($paths.claimed, '*.json')) {
        $claimed = Read-TelephoneJson -Path $file -SchemaName 'wired-supervisor-request'
        $runId = [string]$claimed.value.run_id
        $outboxPath = Get-TelephoneSupervisorRecordPath -StateRoot $StateRoot -Kind outbox -RunId $runId
        if ([IO.File]::Exists($outboxPath)) { continue }
        $ownerRead = Read-TelephoneSupervisorRunOwner -StateRoot $StateRoot -RunId $runId
        if ($null -eq $ownerRead) { continue }
        if (Test-TelephoneSupervisorExactOwner -Owner $ownerRead.value) { continue }
        $memberRead = Read-TelephoneSupervisorJobMembers -StateRoot $StateRoot -RunId $runId
        $job = Open-TelephoneSupervisorRunJob -RunId $runId -WaitMilliseconds 0
        try {
            if (Test-TelephoneSupervisorLiveExactMembers -MemberRecord $memberRead -Job $job) { continue }
            if ($null -ne $job -and [IntPtr]$job.handle -ne [IntPtr]::Zero) {
                $left = @(Get-TelephoneSupervisorJobProcessIds -Job $job)
                if ($left.Count -gt 0) { continue }
            }
        } finally {
            Close-TelephoneSupervisorRunJob -Job $job
        }
        $null = Write-TelephoneSupervisorOutbox -StateRoot $StateRoot -RunId $runId -Terminal 'failed' -Request $claimed.value -ErrorCode 'SUPERVISOR_OWNER_DEAD_NO_RERUN'
        [void]$reconciled.Add([ordered]@{ run_id = $runId; terminal = 'failed' })
    }
    return @($reconciled)
}

function Get-TelephoneSupervisorPinnedVersionIds {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $ids = [Collections.Generic.List[string]]::new()
    foreach ($run in @(Get-TelephoneSupervisorActiveRunList -StateRoot $StateRoot)) {
        if ($run.Contains('job_backed') -and -not [bool]$run.job_backed) { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$run.version_id) -and -not $ids.Contains([string]$run.version_id)) {
            [void]$ids.Add([string]$run.version_id)
        }
    }
    return @($ids)
}

function Get-TelephoneSupervisorSingleOwnerProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $name = Get-TelephoneSupervisorMutexName -StateRoot $StateRoot
    $createdNew = $false
    $mutex = $null
    $held = $false
    try {
        $mutex = [Threading.Mutex]::new($false, $name, [ref]$createdNew)
        $acquired = $false
        try { $acquired = $mutex.WaitOne(0) } catch { $acquired = $false }
        if ($acquired) {
            try { [void]$mutex.ReleaseMutex() } catch { }
            $held = $false
        } else {
            $held = $true
        }
    } catch {
        $held = $false
    } finally {
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
    $live = 0
    $paths = Get-TelephoneSupervisorPaths -StateRoot $StateRoot
    if ([IO.File]::Exists($paths.supervisor_owner)) {
        try {
            $owner = (Read-TelephoneJson -Path $paths.supervisor_owner -SchemaName 'wired-supervisor-owner').value
            if (Test-TelephoneSupervisorExactOwner -Owner $owner) { $live = 1 }
        } catch { }
    }
    return [ordered]@{
        one_supervisor = (($live -le 1) -and (-not ($held -and $live -gt 1)))
        mutex_held = [bool]$held
        live_owners = [int]$live
        mutex_created_new = [bool]$createdNew
    }
}

function Get-TelephoneSupervisorDoctorReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$StateRoot
    )
    $resolvedState = if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT)) {
        Resolve-TelephoneSupervisorStateRoot
    } elseif (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        [IO.Path]::GetFullPath((Join-Path $StateRoot 'supervisor')).TrimEnd('\')
    } else {
        Resolve-TelephoneSupervisorStateRoot
    }
    $paths = Get-TelephoneSupervisorPaths -StateRoot $resolvedState
    $pause = if ([IO.Directory]::Exists($resolvedState)) { Get-TelephoneSupervisorPause -StateRoot $resolvedState } else { [ordered]@{ paused_by_pascal = $false } }
    $task = [ordered]@{ registered = $false; action_ok = $false; principal_ok = $false; hidden_ok = $false; logon_ok = $false; execute = ''; action_script = ''; action_arguments = '' }
    try {
        $got = Invoke-TelephoneSupervisorTaskOperation -Operation get -InstallRoot $InstallRoot
        if ($got -is [Collections.IDictionary]) {
            $task.registered = [bool]($got.Contains('registered') -and [bool]$got.registered)
            if ($got.Contains('task_name') -and [string]$got.task_name -ceq $script:TelephoneSupervisorTaskName) { $task.registered = $true }
            $expectedScript = Join-Path $InstallRoot 'src\supervisor\Invoke-TelephoneSupervisor.ps1'
            $actualScript = if ($got.Contains('action_script')) { [string]$got.action_script } else { '' }
            if ([string]::IsNullOrWhiteSpace($actualScript) -and $got.Contains('action_arguments')) {
                $actualScript = Get-TelephoneSupervisorTaskActionScript -Arguments ([string]$got.action_arguments)
            }
            $task.action_script = $actualScript
            if ($got.Contains('execute')) { $task.execute = [string]$got.execute }
            if ($got.Contains('action_arguments')) { $task.action_arguments = [string]$got.action_arguments }
            if (-not [string]::IsNullOrWhiteSpace($actualScript) -and $actualScript.Equals($expectedScript, [StringComparison]::OrdinalIgnoreCase)) { $task.action_ok = $true }
            if ($got.Contains('principal') -and [string]$got.principal -ceq 'LimitedUser') { $task.principal_ok = $true }
            if ($got.Contains('hidden')) { $task.hidden_ok = [bool]$got.hidden }
            if ($got.Contains('logon_type')) {
                $logon = [string]$got.logon_type
                $task.logon_ok = ($logon -ceq 'InteractiveToken' -or $logon -ceq 'Interactive')
            }
        }
    } catch {
        $task.registered = $false
    }
    $desktop = Test-TelephoneSupervisorDesktopShortcuts
    $stale = 0
    $pidReused = 0
    $orphan = 0
    $ownerOk = $true
    $layoutPresent = [IO.Directory]::Exists($paths.root)
    if ($layoutPresent) {
        foreach ($run in @(Get-TelephoneSupervisorActiveRunList -StateRoot $resolvedState)) {
            if ([bool]$run.alive) { continue }
            $pidExists = $false
            try {
                if ($null -ne $run.owner) {
                    $probe = Get-Process -Id ([int]$run.owner.pid) -ErrorAction Stop
                    $probe.Dispose()
                    $pidExists = $true
                }
            } catch { $pidExists = $false }
            if ($pidExists) {
                $pidReused += 1
                $stale += 1
                $ownerOk = $false
            } elseif (-not [bool]$run.job_backed) {
                $orphan += 1
                $stale += 1
                $ownerOk = $false
            }
        }
        if ([IO.File]::Exists($paths.supervisor_owner)) {
            $sup = (Read-TelephoneJson -Path $paths.supervisor_owner -SchemaName 'wired-supervisor-owner').value
            if (-not (Test-TelephoneSupervisorExactOwner -Owner $sup)) {
                $stale += 1
                $pidExists = $false
                try {
                    $probe = Get-Process -Id ([int]$sup.pid) -ErrorAction Stop
                    $probe.Dispose()
                    $pidExists = $true
                } catch { $pidExists = $false }
                if ($pidExists) { $pidReused += 1 }
            }
        }
    }
    $pointerPath = Join-Path $InstallRoot 'current.json'
    $currentVersion = ''
    $currentSource = ''
    if ([IO.File]::Exists($pointerPath)) {
        $pointer = (Read-TelephoneJson -Path $pointerPath).value
        if ($pointer.Contains('version_id')) { $currentVersion = [string]$pointer.version_id }
        if ($pointer.Contains('source_sha256')) { $currentSource = [string]$pointer.source_sha256 }
    }
    $pendingPath = Join-Path $InstallRoot 'pending.json'
    $pendingVersion = ''
    $pendingSource = ''
    if ([IO.File]::Exists($pendingPath)) {
        try {
            $pending = (Read-TelephoneJson -Path $pendingPath).value
            if ($pending.Contains('version_id')) { $pendingVersion = [string]$pending.version_id }
            if ($pending.Contains('source_sha256')) { $pendingSource = [string]$pending.source_sha256 }
        } catch { }
    }
    $pinned = @()
    if ($layoutPresent) { $pinned = @(Get-TelephoneSupervisorPinnedVersionIds -StateRoot $resolvedState) }
    $one = Get-TelephoneSupervisorSingleOwnerProbe -StateRoot $resolvedState
    if ([int]$one.live_owners -gt 1) { $ownerOk = $false }
    return [ordered]@{
        state_root = $resolvedState
        inbox = [IO.Directory]::Exists($paths.inbox)
        claimed = [IO.Directory]::Exists($paths.claimed)
        outbox = [IO.Directory]::Exists($paths.outbox)
        control = [IO.Directory]::Exists($paths.control)
        paused_by_pascal = [bool]$pause.paused_by_pascal
        task = $task
        desktop = $desktop
        owner_ok = [bool]$ownerOk
        stale_owners = [int]$stale
        pid_reused = [int]$pidReused
        orphan_owners = [int]$orphan
        current_version_id = $currentVersion
        current_source_sha256 = $currentSource
        pending_version_id = $pendingVersion
        pending_source_sha256 = $pendingSource
        pinned_version_ids = @($pinned)
        one_supervisor = [bool]$one.one_supervisor
        mutex_held = [bool]$one.mutex_held
        live_supervisor_owners = [int]$one.live_owners
    }
}

function Test-TelephoneSupervisorVersionStorePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $leaf = [IO.Path]::GetFileName($full)
    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($parent)) { return $false }
    $parentLeaf = [IO.Path]::GetFileName($parent.TrimEnd('\'))
    return ($parentLeaf -ceq 'versions' -and [string]$leaf -cmatch '^[0-9a-f]{64}$')
}

function Assert-TelephoneSupervisorCanonicalRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ([IO.Directory]::Exists($full) -or [IO.File]::Exists($full)) {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label path is a reparse point."
        }
    }
    if (Test-TelephoneSupervisorVersionStorePath -Path $full) {
        $versions = [IO.Path]::GetDirectoryName($full)
        if (-not [string]::IsNullOrWhiteSpace($versions) -and [IO.Directory]::Exists($versions)) {
            $item = Get-Item -LiteralPath $versions -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label path is a reparse point."
            }
        }
    }
    return $full
}

function Get-TelephoneSupervisorBaseInstallRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (Test-TelephoneSupervisorVersionStorePath -Path $full) {
        return [IO.Path]::GetFullPath((Join-Path $full '..\..')).TrimEnd('\')
    }
    return $full
}

function Get-TelephoneSupervisorVersionDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$VersionId
    )
    if ([string]$VersionId -cnotmatch '^[0-9a-f]{64}$') { throw 'Installed version identity is invalid.' }
    $base = Get-TelephoneSupervisorBaseInstallRoot -Path $InstallRoot
    return [IO.Path]::GetFullPath((Join-Path (Join-Path $base 'versions') $VersionId)).TrimEnd('\')
}

function Resolve-TelephoneSupervisorInstallIdentities {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$RuntimeRoot,
        [string]$VersionId
    )
    $base = Assert-TelephoneSupervisorCanonicalRoot -Path (Get-TelephoneSupervisorBaseInstallRoot -Path $InstallRoot) -Label 'Base install root'
    $runtime = ''
    if (-not [string]::IsNullOrWhiteSpace($VersionId) -and [string]$VersionId -cmatch '^[0-9a-f]{64}$') {
        $versionDir = Get-TelephoneSupervisorVersionDirectory -InstallRoot $base -VersionId $VersionId
        if ([IO.Directory]::Exists($versionDir)) {
            $runtime = Assert-TelephoneSupervisorCanonicalRoot -Path $versionDir -Label 'Pinned runtime root'
        }
    }
    if ([string]::IsNullOrWhiteSpace($runtime) -and -not [string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $candidate = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\')
        if ((Test-TelephoneSupervisorVersionStorePath -Path $candidate) -or [IO.Directory]::Exists($candidate)) {
            $runtime = Assert-TelephoneSupervisorCanonicalRoot -Path $candidate -Label 'Pinned runtime root'
        }
    }
    if ([string]::IsNullOrWhiteSpace($runtime)) { $runtime = $base }
    if (-not $runtime.Equals($base, [StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-TelephoneSupervisorPathInsideRoot -Path $runtime -Root $base)) {
            throw 'Pinned runtime root is not inside the base install root.'
        }
        if (-not (Test-TelephoneSupervisorVersionStorePath -Path $runtime)) {
            throw 'Pinned runtime root is not a version directory.'
        }
    }
    return [ordered]@{
        base_install_root = $base
        pinned_runtime_root = $runtime
        distinct = (-not $base.Equals($runtime, [StringComparison]::OrdinalIgnoreCase))
    }
}

function Get-TelephoneInstallActivationMutexName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $base = Get-TelephoneSupervisorBaseInstallRoot -Path $InstallRoot
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($base.ToLowerInvariant())
    $hash = Get-TelephoneSupervisorSha256Hex -Bytes $bytes
    return ('Local\TelephoneLine.InstallActivation.' + $hash.Substring(0, 16))
}

function Open-TelephoneInstallActivationMutex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $name = Get-TelephoneInstallActivationMutexName -InstallRoot $InstallRoot
    $created = $false
    $mutex = [Threading.Mutex]::new($false, $name, [ref]$created)
    $owned = $false
    try {
        try {
            $owned = [bool]$mutex.WaitOne()
        } catch [Threading.AbandonedMutexException] {
            $owned = $true
        }
        if (-not $owned) { throw 'Install activation mutex was not acquired.' }
        return [ordered]@{ mutex = $mutex; name = $name; created = [bool]$created }
    } catch {
        if ($owned) {
            try { [void]$mutex.ReleaseMutex() } catch { }
        }
        $mutex.Dispose()
        throw
    }
}

function Read-TelephoneInstallCurrentPointer {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $path = Join-Path $InstallRoot 'current.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    return (Read-TelephoneJson -Path $path).value
}

function Write-TelephoneInstallCurrentPointer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$VersionId,
        [Parameter(Mandatory = $true)][string]$SourceSha256
    )
    $value = [ordered]@{
        protocol_version = 'telephone-line-install-current-v1'
        version_id = [string]$VersionId
        source_sha256 = [string]$SourceSha256
        switched_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $null = Write-TelephoneJsonReplace -Path (Join-Path $InstallRoot 'current.json') -Value $value
    return $value
}

function Register-TelephoneSupervisorInstallSurface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$StateRoot
    )
    $supervisorScript = Join-Path $InstallRoot 'src\supervisor\Invoke-TelephoneSupervisor.ps1'
    $controlScript = Join-Path $InstallRoot 'src\supervisor\Show-TelephoneSupervisorControl.ps1'
    $arguments = ('-InstallRoot "' + $InstallRoot + '"')
    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        $arguments = $arguments + (' -StateRoot "' + $StateRoot + '"')
    }
    $task = Invoke-TelephoneSupervisorTaskOperation -Operation register -InstallRoot $InstallRoot -ActionScript $supervisorScript -ActionArguments $arguments
    $desktop = Register-TelephoneSupervisorDesktopShortcuts -InstallRoot $InstallRoot -ControlScript $controlScript
    return [ordered]@{ task = $task; desktop = $desktop }
}

function Unregister-TelephoneSupervisorInstallSurface {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    Unregister-TelephoneSupervisorDesktopShortcuts
    try { $null = Invoke-TelephoneSupervisorTaskOperation -Operation unregister -InstallRoot $InstallRoot } catch { }
}

function Stop-TelephoneSupervisorExactProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $paths = Get-TelephoneSupervisorPaths -StateRoot $StateRoot
    if (-not [IO.File]::Exists($paths.supervisor_owner)) { return [ordered]@{ stopped = $false; reason = 'missing' } }
    $owner = (Read-TelephoneJson -Path $paths.supervisor_owner -SchemaName 'wired-supervisor-owner').value
    if (-not (Test-TelephoneSupervisorExactOwner -Owner $owner)) {
        return [ordered]@{ stopped = $false; reason = 'stale-or-pid-reuse' }
    }
    Stop-Process -Id ([int]$owner.pid) -Force -ErrorAction SilentlyContinue
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(3)
    while ([DateTimeOffset]::UtcNow -lt $deadline -and (Test-TelephoneSupervisorExactOwner -Owner $owner)) {
        Start-Sleep -Milliseconds 50
    }
    return [ordered]@{ stopped = -not (Test-TelephoneSupervisorExactOwner -Owner $owner); reason = 'exact-owner' }
}

function Invoke-TelephoneSupervisorIdleVersionActivation {
    [CmdletBinding()]
    param(
        [string]$InstallRoot,
        [string]$StateRoot
    )
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { return [ordered]@{ switched = $false; reason = 'no-install-root' } }
    $identities = Resolve-TelephoneSupervisorInstallIdentities -InstallRoot $InstallRoot -RuntimeRoot $InstallRoot
    if (-not (Get-Command Complete-TelephoneInstallPendingActivationIfIdle -ErrorAction SilentlyContinue)) {
        $installCommon = Join-Path $PSScriptRoot '..\install\TelephoneLineInstall.Common.ps1'
        if (-not [IO.File]::Exists($installCommon)) { return [ordered]@{ switched = $false; reason = 'install-common-missing' } }
        . $installCommon
    }
    if (-not (Get-Command Complete-TelephoneInstallPendingActivationIfIdle -ErrorAction SilentlyContinue)) {
        return [ordered]@{ switched = $false; reason = 'activation-unavailable' }
    }
    return (Complete-TelephoneInstallPendingActivationIfIdle -InstallRoot ([string]$identities.base_install_root) -StateRoot $StateRoot)
}
