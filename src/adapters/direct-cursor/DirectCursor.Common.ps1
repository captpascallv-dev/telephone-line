# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }

function Get-DirectFileIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Expected a regular file.'
    }
    $bytes = [IO.File]::ReadAllBytes($full)
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$bytes.Length
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
}

function Assert-DirectIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (
        [IO.Path]::GetFullPath([string]$Expected.path) -cne [IO.Path]::GetFullPath([string]$Actual.path) -or
        [int64]$Expected.bytes -ne [int64]$Actual.bytes -or
        [string]$Expected.sha256 -cne [string]$Actual.sha256
    ) {
        throw "$Label identity changed."
    }
}

function Assert-DirectContentIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($null -eq $Expected -or $null -eq $Actual) { throw "$Label identity is missing." }
    $expectedBytes = Get-DirectNoteValue -Object $Expected -Name 'bytes'
    $expectedSha = [string](Get-DirectNoteValue -Object $Expected -Name 'sha256')
    $actualBytes = Get-DirectNoteValue -Object $Actual -Name 'bytes'
    $actualSha = [string](Get-DirectNoteValue -Object $Actual -Name 'sha256')
    if ([int64]$expectedBytes -ne [int64]$actualBytes -or $expectedSha -cne $actualSha -or [string]::IsNullOrWhiteSpace($expectedSha)) {
        throw "$Label identity does not match the bound evidence."
    }
}

function Get-DirectCursorSortedWriteScope {
    [CmdletBinding()]
    param($Paths)

    return [string](([string[]]@($Paths | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)) -join "`n")
}

function Get-DirectSpoolIdentitySafe {
    [CmdletBinding()]
    param([string]$Path)

    $result = [ordered]@{
        unavailable = $true
        identity = $null
        error_type = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return $result }
    try {
        $result.identity = Get-DirectFileIdentity -Path $Path
        $result.unavailable = $false
        return $result
    } catch {
        $result.error_type = $_.Exception.GetType().FullName
        return $result
    }
}

function Get-DirectCursorSessionRegistryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    return Join-Path (Get-DirectCanonicalDirectory -Path $StateRoot) 'cursor-sessions\sessions.json'
}

function Get-DirectCursorPartialRegistryRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$NativeSessionId
    )

    $registryPath = Get-DirectCursorSessionRegistryPath -StateRoot $StateRoot
    if (-not [IO.File]::Exists($registryPath)) { return $null }
    $registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
    $rows = @($registry.sessions | Where-Object { $_.session_id -eq $NativeSessionId })
    if ($rows.Count -ne 1) { return $null }
    return $rows[0]
}

function Test-DirectCursorPartialAdmissionUsable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$NativeSessionId
    )

    $admission = Read-DirectCursorPartialAdmission -StateRoot $StateRoot -NativeSessionId $NativeSessionId
    if ($null -eq $admission) { return $null }
    $record = Get-DirectCursorPartialRegistryRecord -StateRoot $StateRoot -NativeSessionId $NativeSessionId
    if ($null -eq $record) { throw 'Partial admission is inconsistent and is not usable.' }
    if ([string]$record.acceptance -cne [string]$admission.acceptance -or [string]$record.admission_kind -cne 'partial_observed') {
        throw 'Partial admission is inconsistent and is not usable.'
    }
    if ([int]$record.continuation_remaining -ne [int]$admission.continuation_remaining) {
        throw 'Partial admission is inconsistent and is not usable.'
    }
    return $admission
}

function Confirm-DirectCursorOwnerDead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Owner,
        [string]$Source = 'owner'
    )

    if (Test-DirectOwnerAlive -Owner $Owner) { throw 'Competing owner is still alive.' }
    return [ordered]@{
        pid = [int]$Owner.pid
        start_time_utc_ticks = [int64]$Owner.start_time_utc_ticks
        exact_owner_alive = $false
        source = $Source
    }
}

function Get-DirectTextSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Read-DirectJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $identity = Get-DirectFileIdentity -Path $Path
    $bytes = [IO.File]::ReadAllBytes([string]$identity.path)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    return [ordered]@{
        identity = $identity
        value = $text | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    }
}

function Assert-DirectKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Value,
        [Parameter(Mandatory = $true)][string[]]$Keys,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Value.Count -ne $Keys.Count) { throw "$Label key count mismatch." }
    foreach ($key in $Keys) {
        if (-not $Value.Contains($key)) { throw "$Label is missing or has a wrong-case key: $key" }
    }
}

function Write-DirectJsonCreateNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $json = ($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.FileStream]::new($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    return Get-DirectFileIdentity -Path $full
}

function ConvertTo-DirectRelativeWritePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [string[]]$Paths
    )

    $workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\')
    $result = [Collections.Generic.List[string]]::new()
    if ($null -eq $Paths -or $Paths.Count -eq 0) { return [string[]]@() }
    foreach ($raw in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace([string]$raw)) { throw 'A declared write path is empty.' }
        if ([IO.Path]::IsPathRooted([string]$raw)) { throw 'Declared write paths must be workspace-relative.' }
        $full = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$raw))).TrimEnd('\')
        if (-not ($full.Equals($workspace, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase))) {
            throw 'Declared write path escapes the workspace.'
        }
        $relative = [IO.Path]::GetRelativePath($workspace, $full).Replace('\', '/').TrimEnd('/')
        if ($relative -eq '.') { throw 'The whole workspace cannot be declared as one write path.' }
        $result.Add($relative)
    }
    return [string[]]@($result | Sort-Object -Unique)
}

function Test-DirectOwnerAlive {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Owner)

    try {
        $process = Get-Process -Id ([int]$Owner.pid) -ErrorAction Stop
        try {
            return $process.StartTime.ToUniversalTime().Ticks -eq [int64]$Owner.start_time_utc_ticks
        } finally {
            $process.Dispose()
        }
    } catch {
        return $false
    }
}

function Get-DirectCanonicalDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
}

function Test-DirectPathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowEqual
    )

    $canonicalRoot = Get-DirectCanonicalDirectory -Path $Root
    $canonicalPath = Get-DirectCanonicalDirectory -Path $Path
    if ($AllowEqual -and $canonicalPath.Equals($canonicalRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $canonicalPath.StartsWith($canonicalRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-DirectPublicErrorCatalog {
    return [ordered]@{
        ADAPTER_TRANSPORT_FAILED = 'Telephone-line adapter transport failed.'
        ADAPTER_NATIVE_SESSION_MISMATCH = 'Adapter native session id does not match the frozen session.'
        ADAPTER_NATIVE_SESSION_MISSING = 'Adapter native session id is missing or unknown.'
        ADAPTER_DURABLE_STATE_MISSING = 'Adapter durable state was not found.'
        ADAPTER_DUPLICATE_NO_RERUN = 'Adapter duplicate start was directed to existing durable state.'
        DIRECT_CURSOR_FAST_DISABLED = 'Direct Cursor Fast mode is disabled.'
        DIRECT_CURSOR_WRITE_SCOPE = 'Direct Cursor write scope is invalid.'
        DIRECT_CURSOR_MODEL_CAPACITY = 'Direct Cursor selected model is temporarily at capacity.'
        DIRECT_CURSOR_RATE_LIMITED = 'Direct Cursor is temporarily rate limited.'
        DIRECT_CURSOR_WORKSPACE_BUSY = 'Direct Cursor workspace is currently owned by another dispatch.'
        DIRECT_CURSOR_CLI_FAILURE = 'Direct Cursor CLI did not complete successfully.'
        DIRECT_CURSOR_TERMINAL_INVALID = 'Direct Cursor terminal result is invalid.'
        DIRECT_CURSOR_AUTH_FAILED = 'Direct Cursor subscription authentication is unavailable.'
        DIRECT_CURSOR_OUTPUT_LIMIT = 'Direct Cursor CLI output exceeded the bounded result size.'
        DIRECT_CURSOR_STREAM_IO = 'Direct Cursor CLI stream I/O failed.'
        DIRECT_CURSOR_TERMINATION_UNCERTAIN = 'Direct Cursor process-tree termination could not be confirmed.'
        DIRECT_CURSOR_POST_EXECUTION = 'Direct Cursor post-execution snapshot or workspace check failed.'
        DIRECT_CURSOR_RESULT_PROJECTION = 'Direct Cursor result or receipt projection failed.'
    }
}

function Get-DirectPublicError {
    [CmdletBinding()]
    param([AllowNull()][string]$Message, [string]$ErrorCode)

    $catalog = Get-DirectPublicErrorCatalog
    $code = [string]$ErrorCode
    $text = [string]$Message
    if (-not [string]::IsNullOrWhiteSpace($code) -and $catalog.Contains($code)) {
        return [string]$catalog[$code]
    }
    if ([string]::IsNullOrWhiteSpace($code) -and -not [string]::IsNullOrWhiteSpace($text)) {
        foreach ($key in @($catalog.Keys)) {
            if ($text -ceq [string]$catalog[$key]) { $code = [string]$key; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($code)) {
        if ($text -cmatch '(?i)selected model.*capacity|model is at capacity|at capacity') { $code = 'DIRECT_CURSOR_MODEL_CAPACITY' }
        elseif ($text -cmatch '(?i)rate.?limit|too many requests|\b429\b') { $code = 'DIRECT_CURSOR_RATE_LIMITED' }
        elseif ($text -cmatch '(?i)workspace.*owned by another dispatch|workspace.*busy') { $code = 'DIRECT_CURSOR_WORKSPACE_BUSY' }
        elseif ($text -cmatch '(?i)native session') { $code = 'ADAPTER_NATIVE_SESSION_MISMATCH' }
        elseif ($text -cmatch '(?i)already exists|duplicate') { $code = 'ADAPTER_DUPLICATE_NO_RERUN' }
        elseif ($text -cmatch '(?i)Fast') { $code = 'DIRECT_CURSOR_FAST_DISABLED' }
        elseif ($text -cmatch '(?i)write path|write scope|ReadOnly|Verify') { $code = 'DIRECT_CURSOR_WRITE_SCOPE' }
        elseif ($text -cmatch '(?i)output exceeded the bounded result size') { $code = 'DIRECT_CURSOR_OUTPUT_LIMIT' }
        elseif ($text -cmatch '(?i)stream I/O|I/O error|IOException') { $code = 'DIRECT_CURSOR_STREAM_IO' }
        elseif ($text -cmatch '(?i)process-tree termination could not be confirmed') { $code = 'DIRECT_CURSOR_TERMINATION_UNCERTAIN' }
        elseif ($text -cmatch '(?i)post-execution|volatile exclusion|reparse point and is not eligible') { $code = 'DIRECT_CURSOR_POST_EXECUTION' }
        elseif ($text -cmatch '(?i)receipt|result projection|not a terminal result object|Cursor result is missing') { $code = 'DIRECT_CURSOR_RESULT_PROJECTION' }
        elseif ($text -cmatch '(?i)malformed NDJSON|stream must contain|terminal result|session identity is missing or inconsistent') { $code = 'DIRECT_CURSOR_TERMINAL_INVALID' }
        elseif ($text -cmatch '(?i)missing|unknown') { $code = 'ADAPTER_DURABLE_STATE_MISSING' }
        else { $code = 'ADAPTER_TRANSPORT_FAILED' }
    }
    if (-not $catalog.Contains($code)) { $code = 'ADAPTER_TRANSPORT_FAILED' }
    return [string]$catalog[$code]
}

function Get-DirectCursorFailureClassification {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Message,
        [string]$Stage = 'unknown',
        [string]$ExceptionType = '',
        [string]$ProcessFailureClass = ''
    )

    $text = [string]$Message
    $stage = if ([string]::IsNullOrWhiteSpace($Stage)) { 'unknown' } else { $Stage }
    $code = 'adapter_transport_failure'
    $publicCode = 'ADAPTER_TRANSPORT_FAILED'
    $processClass = [string]$ProcessFailureClass
    $exceptionType = [string]$ExceptionType

            if ($processClass -ceq 'output_limit' -or $text -cmatch '(?i)output exceeded the bounded result size') {
        $code = 'cursor_output_limit'
        $publicCode = 'DIRECT_CURSOR_OUTPUT_LIMIT'
        if ($stage -ceq 'cursor_execution' -or $stage -ceq 'unknown') { $stage = 'process_output_limit' }
    } elseif (
        $processClass -ceq 'stream_io' -or
        $text -cmatch '(?i)stream I/O|I/O error while reading Cursor' -or
        (
            $exceptionType -cmatch '(?i)IOException|IO\.IOException' -and
            ($stage -ceq 'cursor_execution' -or $stage -ceq 'unknown' -or $stage -ceq 'stream_io')
        )
    ) {
        $code = 'cursor_stream_io'
        $publicCode = 'DIRECT_CURSOR_STREAM_IO'
        if ($stage -ceq 'cursor_execution' -or $stage -ceq 'unknown') { $stage = 'stream_io' }
    } elseif ($processClass -ceq 'termination_uncertain' -or $text -cmatch '(?i)process-tree termination could not be confirmed') {
        $code = 'cursor_termination_uncertain'
        $publicCode = 'DIRECT_CURSOR_TERMINATION_UNCERTAIN'
        if ($stage -ceq 'cursor_execution' -or $stage -ceq 'unknown') { $stage = 'termination_uncertain' }
    } elseif ($stage -cmatch '(?i)^post_execution_' -or $text -cmatch '(?i)Runtime volatile exclusion set changed|reparse point and is not eligible|Workspace contains a reparse point') {
        $code = 'cursor_post_execution'
        $publicCode = 'DIRECT_CURSOR_POST_EXECUTION'
        if ($stage -ceq 'cursor_execution') { $stage = 'post_execution_snapshot' }
    } elseif ($stage -ceq 'result_projection' -or $text -cmatch '(?i)not a terminal result object|Cursor result is missing|receipt belongs to another job|result prompt binding differs') {
        $code = 'cursor_result_projection'
        $publicCode = 'DIRECT_CURSOR_RESULT_PROJECTION'
        if ($stage -ceq 'unknown') { $stage = 'result_projection' }
    } elseif ($text -cmatch '(?i)selected model.*capacity|model is at capacity|at capacity') {
        $code = 'cursor_model_capacity'
        $publicCode = 'DIRECT_CURSOR_MODEL_CAPACITY'
    } elseif ($text -cmatch '(?i)rate.?limit|too many requests|\b429\b') {
        $code = 'cursor_rate_limited'
        $publicCode = 'DIRECT_CURSOR_RATE_LIMITED'
    } elseif ($text -cmatch '(?i)another Cursor dispatch already owns this workspace|workspace.*busy') {
        $code = 'cursor_workspace_busy'
        $publicCode = 'DIRECT_CURSOR_WORKSPACE_BUSY'
    } elseif ($text -cmatch '(?i)subscription login|authentication|not logged in|account identity') {
        $code = 'cursor_authentication_failed'
        $publicCode = 'DIRECT_CURSOR_AUTH_FAILED'
    } elseif ($text -cmatch '(?i)malformed NDJSON|stream must contain|terminal result|session identity is missing or inconsistent') {
        $code = 'cursor_terminal_invalid'
        $publicCode = 'DIRECT_CURSOR_TERMINAL_INVALID'
        if ($stage -ceq 'cursor_execution' -or $stage -ceq 'unknown') { $stage = 'terminal_validation' }
    } elseif ($text -cmatch '(?i)Cursor CLI exited|Cursor CLI wrote to stderr|Cursor CLI process did not start|startup or command probe exceeded') {
        $code = 'cursor_cli_failure'
        $publicCode = 'DIRECT_CURSOR_CLI_FAILURE'
    }

    return [ordered]@{
        failure_kind = 'transport'
        failure_code = $code
        failure_stage = $stage
        public_error_code = $publicCode
        process_failure_class = $processClass
    }
}

function Restrict-DirectCursorDiagnosticDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Directory)

    $full = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    if (-not [IO.Directory]::Exists($full)) { throw 'Diagnostic directory is missing.' }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Diagnostic path is not a regular directory.'
    }
    try {
        $acl = Get-Acl -LiteralPath $full
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) {
            try { $null = $acl.RemoveAccessRule($rule) } catch { }
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -eq $identity -or $null -eq $identity.User) { throw 'Diagnostic owner identity is unavailable.' }
        $access = [Security.AccessControl.FileSystemRights]::FullControl
        $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $propagate = [Security.AccessControl.PropagationFlags]::None
        $allow = [Security.AccessControl.AccessControlType]::Allow
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity.User, $access, $inherit, $propagate, $allow)
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $full -AclObject $acl
        return $true
    } catch {
        return $false
    }
}

function New-DirectCursorProcessDiagnosticDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionRoot,
        [string]$DispatchId
    )

    $root = [IO.Path]::GetFullPath($SessionRoot).TrimEnd('\')
    $dispatch = if ([string]::IsNullOrWhiteSpace($DispatchId)) { [Guid]::NewGuid().ToString('D') } else { $DispatchId }
    $dir = Join-Path $root ('diagnostics\' + $dispatch + '\' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    if (-not (Restrict-DirectCursorDiagnosticDirectory -Directory $dir)) {
        try { [IO.Directory]::Delete($dir, $true) } catch { }
        throw 'Diagnostic directory permissions could not be restricted.'
    }
    return $dir
}

function Write-DirectCursorProcessDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [string]$Stage = 'unknown',
        [AllowNull()][string]$ExceptionType,
        [AllowNull()][string]$ExceptionMessage,
        [AllowNull()][object]$Classification,
        [string]$RequestedSessionId = '',
        [string]$ReturnedSessionId = '',
        [int]$NativePid = 0,
        [int64]$NativeStartTicks = 0,
        [string]$NativeExecutable = '',
        [AllowNull()][object]$NativeExitCode,
        [string]$StdoutPath = '',
        [string]$StderrPath = '',
        [int]$OutputByteLimit = 0,
        [int]$MemoryStdoutBytes = 0,
        [int]$MemoryStderrBytes = 0,
        [int]$ProcessTimeoutSeconds = 0,
        [bool]$OverLimit = $false,
        [bool]$StdoutTruncated = $false,
        [bool]$StderrTruncated = $false,
        [string]$ProcessFailureClass = '',
        [string]$ObservedSessionId = ''
    )

    $dir = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $stdoutIdentity = $null
    $stderrIdentity = $null
    $stdoutBytes = [int64]0
    $stderrBytes = [int64]0
    if (-not [string]::IsNullOrWhiteSpace($StdoutPath) -and [IO.File]::Exists($StdoutPath)) {
        $stdoutIdentity = Get-DirectFileIdentity -Path $StdoutPath
        $stdoutBytes = [int64]$stdoutIdentity.bytes
    }
    if (-not [string]::IsNullOrWhiteSpace($StderrPath) -and [IO.File]::Exists($StderrPath)) {
        $stderrIdentity = Get-DirectFileIdentity -Path $StderrPath
        $stderrBytes = [int64]$stderrIdentity.bytes
    }
    $exitValue = $null
    $exitAvailable = $false
    if ($null -ne $NativeExitCode -and [string]$NativeExitCode -ne '') {
        $exitValue = [int]$NativeExitCode
        $exitAvailable = $true
    }
    $doc = [ordered]@{
        protocol_version = 'telephone-line-direct-cursor-process-diagnostic-v1'
        stage = $(if ([string]::IsNullOrWhiteSpace($Stage)) { 'unknown' } else { $Stage })
        exception_type = $(if ([string]::IsNullOrWhiteSpace($ExceptionType)) { '' } else { $ExceptionType })
        exception_message = Limit-DirectText -Text ([string]$ExceptionMessage) -Limit 2000
        failure_kind = if ($null -ne $Classification) { [string](Get-DirectNoteValue -Object $Classification -Name 'failure_kind') } else { '' }
        failure_code = if ($null -ne $Classification) { [string](Get-DirectNoteValue -Object $Classification -Name 'failure_code') } else { '' }
        failure_stage = if ($null -ne $Classification) { [string](Get-DirectNoteValue -Object $Classification -Name 'failure_stage') } else { $Stage }
        public_error_code = if ($null -ne $Classification) { [string](Get-DirectNoteValue -Object $Classification -Name 'public_error_code') } else { '' }
        process_failure_class = [string]$ProcessFailureClass
        requested_native_session_id = [string]$RequestedSessionId
        returned_native_session_id = [string]$ReturnedSessionId
        observed_native_session_id = [string]$ObservedSessionId
        returned_session_verified = $false
        native_pid = [int]$NativePid
        native_start_time_utc_ticks = [int64]$NativeStartTicks
        native_executable = [string]$NativeExecutable
        native_exit_code = $exitValue
        native_exit_available = [bool]$exitAvailable
        stdout_bytes = $stdoutBytes
        stderr_bytes = $stderrBytes
        stdout_truncated = [bool]$StdoutTruncated
        stderr_truncated = [bool]$StderrTruncated
        captured_truncated = [bool]($StdoutTruncated -or $StderrTruncated -or $OverLimit)
        memory_stdout_bytes = [int]$MemoryStdoutBytes
        memory_stderr_bytes = [int]$MemoryStderrBytes
        output_byte_limit = [int]$OutputByteLimit
        process_timeout_seconds = [int]$ProcessTimeoutSeconds
        over_limit = [bool]$OverLimit
        stdout = $stdoutIdentity
        stderr = $stderrIdentity
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $path = Join-Path $dir 'process-diagnostic.json'
    $identity = Write-DirectJsonCreateNew -Path $path -Value $doc
    return [ordered]@{
        path = [string]$identity.path
        bytes = [int64]$identity.bytes
        sha256 = [string]$identity.sha256
        stdout_bytes = $stdoutBytes
        stderr_bytes = $stderrBytes
        native_exit_code = $exitValue
        native_pid = [int]$NativePid
        directory = $dir
        stdout = $stdoutIdentity
        stderr = $stderrIdentity
        requested_native_session_id = [string]$RequestedSessionId
        returned_native_session_id = [string]$ReturnedSessionId
        observed_native_session_id = [string]$ObservedSessionId
        stdout_truncated = [bool]$StdoutTruncated
        stderr_truncated = [bool]$StderrTruncated
        captured_truncated = [bool]($StdoutTruncated -or $StderrTruncated -or $OverLimit)
        process_failure_class = [string]$ProcessFailureClass
        native_exit_available = [bool]$exitAvailable
    }
}

function Test-DirectCursorFollowUpSessionGate {
    [CmdletBinding()]
    param(
        [string]$RequestedSessionId,
        [string]$ReturnedSessionId
    )

    if ([string]::IsNullOrWhiteSpace($ReturnedSessionId)) {
        return [ordered]@{
            reject = $false
            reason = 'empty_returned_is_not_identity_mismatch'
            returned_verified = $false
        }
    }
    if ($ReturnedSessionId -cne $RequestedSessionId) {
        return [ordered]@{
            reject = $true
            reason = 'genuine_returned_session_mismatch'
            returned_verified = $false
        }
    }
    return [ordered]@{
        reject = $false
        reason = 'returned_matches_frozen'
        returned_verified = $true
    }
}

function Resolve-DirectCursorReturnedSessionId {
    [CmdletBinding()]
    param($Terminal)

    $value = $null
    if ($null -ne $Terminal -and $Terminal -is [Collections.IDictionary] -and $Terminal.Contains('value')) {
        $value = $Terminal['value']
    } else {
        $value = $Terminal
    }
    $fromTerminal = [string](Get-DirectNoteValue -Object $value -Name 'native_session_id')
    if (-not [string]::IsNullOrWhiteSpace($fromTerminal)) { return $fromTerminal }
    $cursorResult = Get-DirectNoteValue -Object $value -Name 'cursor_result'
    $fromResult = [string](Get-DirectNoteValue -Object $cursorResult -Name 'session_id')
    if (-not [string]::IsNullOrWhiteSpace($fromResult)) { return $fromResult }
    $fromReturned = [string](Get-DirectNoteValue -Object $cursorResult -Name 'returned_native_session_id')
    if (-not [string]::IsNullOrWhiteSpace($fromReturned)) { return $fromReturned }
    return ''
}

function Get-DirectCursorAdapterExitCode {
    [CmdletBinding()]
    param($Terminal)

    $value = $null
    if ($null -ne $Terminal -and $Terminal -is [Collections.IDictionary] -and $Terminal.Contains('value')) {
        $value = $Terminal['value']
    } else {
        $value = $Terminal
    }
    if ([string](Get-DirectNoteValue -Object $value -Name 'protocol_version') -ceq 'telephone-line-direct-cursor-status-v1') {
        return 3
    }
    $transportComplete = Get-DirectNoteValue -Object $value -Name 'transport_complete'
    $cursorSuccess = Get-DirectNoteValue -Object $value -Name 'cursor_success'
    if ($transportComplete -eq $true -and $cursorSuccess -eq $true) { return 0 }
    return 2
}

function Get-DirectCursorPreflightCheckCodes {
    [CmdletBinding()]
    param()

    return @(
        'state_root_containment',
        'job_id_collision',
        'prompt_exists',
        'prompt_regular_file',
        'prompt_utf8',
        'prompt_length',
        'workspace_exists',
        'workspace_directory',
        'workspace_alias',
        'workspace_broad_root',
        'workspace_sensitive_root',
        'workspace_reparse',
        'mode_authority',
        'write_scope_normalization',
        'write_scope_containment',
        'write_scope_existence',
        'write_scope_non_reparse',
        'linked_worktree_leaf',
        'route_common_identity',
        'route_entry_identity',
        'route_runtime_identity',
        'route_bridge_identity',
        'route_host_identity',
        'route_job_host_identity',
        'qualified_wrapper_present',
        'qualified_index_present',
        'qualified_node_present',
        'qualified_job_host_identity',
        'dispatch_block_absent',
        'workspace_mutex_available',
        'workspace_snapshot_qualification',
        'cli_version',
        'account_binding',
        'subscription_binding',
        'model_availability',
        'resume_session_exists',
        'resume_session_binding'
    )
}

function Get-DirectCursorQualifiedProbeRequiredKeys {
    [CmdletBinding()]
    param()

    return @(
        'protocol_version',
        'wrapper_present',
        'wrapper_identity_match',
        'index_present',
        'index_identity_match',
        'node_present',
        'node_identity_match',
        'job_host_present',
        'job_host_identity_match',
        'cli_version_match',
        'account_bound',
        'subscription_bound',
        'model_available'
    )
}

function Limit-DirectText {
    [CmdletBinding()]
    param([string]$Text, [int]$Limit = 2000)

    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Limit) { return $Text }
    return $Text.Substring(0, $Limit) + '...[truncated]'
}

function ConvertTo-DirectStableCursorModelDisplay {
    [CmdletBinding()]
    param([AllowNull()][string]$Display)

    if ($null -eq $Display) { throw 'Cursor model display is empty after canonicalization.' }
    $stableDisplay = $Display.Trim()
    $stableDisplay = [regex]::Replace(
        $stableDisplay,
        '\s+\(current\)$',
        '',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if ([string]::IsNullOrEmpty($stableDisplay)) { throw 'Cursor model display is empty after canonicalization.' }
    return $stableDisplay
}

function Test-DirectPathInside {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Root
    )

    return Test-DirectPathWithin -Root $Root -Path $Candidate -AllowEqual
}

function Get-DirectCursorWorkspaceAliasReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)]$WorkspaceItem
    )

    if ($Workspace.StartsWith('\\') -or $Workspace -match '(?i)\\[^\\]*~\d') {
        return 'UNC or short-name workspace aliases are not allowed.'
    }
    if ($null -ne $WorkspaceItem.PSDrive -and $null -ne $WorkspaceItem.PSDrive.DisplayRoot) {
        return 'Mapped-drive workspaces are not allowed.'
    }
    return $null
}

function Test-DirectCursorBroadWorkspaceRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Workspace)

    $driveRoot = [IO.Path]::GetPathRoot($Workspace).TrimEnd('\')
    $profileRoot = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $null } else { $env:USERPROFILE.TrimEnd('\') }
    foreach ($broadRoot in @($driveRoot, $profileRoot)) {
        if ([string]::IsNullOrWhiteSpace([string]$broadRoot)) { continue }
        if ($Workspace.Equals($broadRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-DirectCursorSensitiveWorkspaceRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Workspace)

    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $false }
    $profileRoot = $env:USERPROFILE.TrimEnd('\')
    foreach ($sensitiveRoot in @(
        (Join-Path $profileRoot '.codex'),
        (Join-Path $profileRoot '.ssh'),
        (Join-Path $profileRoot 'AppData')
    )) {
        if (Test-DirectPathInside -Candidate $Workspace -Root $sensitiveRoot) { return $true }
    }
    return $false
}

function Assert-DirectCursorWorkspaceDispatchable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WorkspacePath)

    $workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\')
    if (-not [IO.Directory]::Exists($workspace)) { throw 'Direct Cursor workspace does not exist.' }
    $workspaceItem = Get-Item -LiteralPath $workspace -Force -ErrorAction Stop
    if (-not $workspaceItem.PSIsContainer) { throw 'WorkspacePath must be a directory.' }
    if (($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'A reparse-point workspace root is not allowed.'
    }
    $aliasReason = Get-DirectCursorWorkspaceAliasReason -Workspace $workspace -WorkspaceItem $workspaceItem
    if (-not [string]::IsNullOrWhiteSpace([string]$aliasReason)) { throw $aliasReason }
    if (Test-DirectCursorBroadWorkspaceRoot -Workspace $workspace) {
        throw 'Workspace is a forbidden broad root.'
    }
    if (Test-DirectCursorSensitiveWorkspaceRoot -Workspace $workspace) {
        throw 'Workspace is a forbidden sensitive root.'
    }
    if (Test-DirectWorkspaceReparse -Root $workspace) {
        throw 'Workspace contains a reparse point and is not eligible for automated dispatch.'
    }
    return $workspace
}

function Resolve-DirectCursorModeAuthority {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [bool]$AllowWrite,
        [string[]]$AllowedWritePath,
        [string]$WorkspacePath
    )

    $canonical = $null
    switch -Regex ($Mode) {
        '^(?i)readonly$' { $canonical = 'ReadOnly' }
        '^(?i)verify$' { $canonical = 'Verify' }
        '^(?i)write$' { $canonical = 'Write' }
        default { throw 'Direct Cursor mode is unsupported.' }
    }

    $rawPaths = @()
    if ($null -ne $AllowedWritePath) { $rawPaths = @($AllowedWritePath) }
    $hasPath = $false
    foreach ($raw in $rawPaths) {
        if (-not [string]::IsNullOrWhiteSpace([string]$raw)) { $hasPath = $true; break }
    }

    $normalized = [string[]]@()
    if ($hasPath) {
        if ([string]::IsNullOrWhiteSpace($WorkspacePath)) { throw 'Direct Cursor write scope requires a workspace.' }
        $normalized = [string[]]@(ConvertTo-DirectRelativeWritePaths -WorkspacePath $WorkspacePath -Paths $rawPaths)
    }

    switch ($canonical) {
        'ReadOnly' {
            if ($AllowWrite -or $normalized.Count -ne 0 -or $hasPath) {
                throw 'Direct Cursor ReadOnly mode cannot carry a write scope.'
            }
            return [ordered]@{
                mode = 'ReadOnly'
                allow_write = $false
                allowed_write_paths = [string[]]@()
                command_capable = $false
                requires_linked_worktree = $false
            }
        }
        'Verify' {
            if ($AllowWrite -or $normalized.Count -ne 0 -or $hasPath) {
                throw 'Direct Cursor Verify mode cannot carry a write scope.'
            }
            return [ordered]@{
                mode = 'Verify'
                allow_write = $false
                allowed_write_paths = [string[]]@()
                command_capable = $true
                requires_linked_worktree = $false
            }
        }
        default {
            if (-not $AllowWrite) { throw 'Direct Cursor Write mode requires explicit write authority.' }
            if ($normalized.Count -eq 0) { throw 'Direct Cursor Write mode requires an explicit write scope.' }
            return [ordered]@{
                mode = 'Write'
                allow_write = $true
                allowed_write_paths = $normalized
                command_capable = $true
                requires_linked_worktree = $true
            }
        }
    }
}

function Get-DirectCursorCliInvocationArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Authority)

    if ($true -eq $Authority.command_capable) {
        return [string[]]@('--force')
    }
    return [string[]]@('--mode', 'ask')
}

function Get-DirectWorkspaceSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$AllowedWriteRelative,
        [ref]$VolatileExclusions
    )

    $root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $snapshot = @{}
    $excluded = [Collections.Generic.List[object]]::new()
    $allowed = @($AllowedWriteRelative | ForEach-Object { ([string]$_).Replace('\', '/').Trim('/') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $stack = [Collections.Generic.Stack[string]]::new()
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)
        foreach ($item in $items) {
            $relative = [IO.Path]::GetRelativePath($root, $item.FullName).Replace('\', '/')
            $isReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            if ($item.PSIsContainer) {
                $snapshot[$relative] = 'dir:reparse=' + $(if ($isReparse) { '1' } else { '0' })
                if (-not $isReparse) { $stack.Push($item.FullName) }
            } elseif ($isReparse) {
                $snapshot[$relative] = 'file:reparse=1'
            } else {
                try {
                    $bytes = [IO.File]::ReadAllBytes($item.FullName)
                    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                    $snapshot[$relative] = 'file:bytes=' + $bytes.Length.ToString() + ':sha256=' + $hash + ':reparse=0'
                } catch [IO.IOException] {
                    $nativeError = [int]([int64]$_.Exception.HResult -band 0xFFFF)
                    $insideLease = $false
                    foreach ($lease in $allowed) {
                        if ($relative.Equals($lease, [StringComparison]::OrdinalIgnoreCase) -or
                            $relative.StartsWith($lease.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)) {
                            $insideLease = $true
                            break
                        }
                    }
                    $gitIgnored = $false
                    if (-not $insideLease -and $nativeError -in @(32, 33)) {
                        try {
                            $git = Get-Command git -ErrorAction Stop
                            # Deliberately omit --no-index: a tracked file must never be
                            # classified as an excludable runtime artifact merely because
                            # its path also matches an ignore rule.
                            & ([string]$git.Source) -C $root check-ignore --quiet -- $relative 2>$null
                            $gitIgnored = $LASTEXITCODE -eq 0
                        } catch { $gitIgnored = $false }
                    }
                    if (-not $gitIgnored) { throw }
                    $snapshot[$relative] = 'file:volatile=locked_gitignored_nonlease:reparse=0'
                    $excluded.Add([ordered]@{
                        path = $relative
                        reason = 'locked_gitignored_nonlease_runtime_file'
                        git_ignored = $true
                        sharing_error = $nativeError
                    })
                }
            }
        }
    }
    if ($PSBoundParameters.ContainsKey('VolatileExclusions')) {
        $VolatileExclusions.Value = @($excluded.ToArray() | Sort-Object { [string]$_.path })
    }
    return $snapshot
}

function Compare-DirectWorkspaceSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )

    $keys = @(@($Before.Keys) + @($After.Keys) | Select-Object -Unique | Sort-Object)
    $changes = [Collections.Generic.List[object]]::new()
    foreach ($path in $keys) {
        $norm = ([string]$path).Replace('\', '/')
        $beforeHas = $Before.ContainsKey($path) -or $Before.ContainsKey($norm)
        $afterHas = $After.ContainsKey($path) -or $After.ContainsKey($norm)
        $beforeVal = if ($Before.ContainsKey($path)) { $Before[$path] } elseif ($Before.ContainsKey($norm)) { $Before[$norm] } else { $null }
        $afterVal = if ($After.ContainsKey($path)) { $After[$path] } elseif ($After.ContainsKey($norm)) { $After[$norm] } else { $null }
        if (-not $beforeHas) {
            $changes.Add([ordered]@{ path = $norm; change = 'added' })
        } elseif (-not $afterHas) {
            $changes.Add([ordered]@{ path = $norm; change = 'deleted' })
        } elseif ([string]$beforeVal -cne [string]$afterVal) {
            $changes.Add([ordered]@{ path = $norm; change = 'modified' })
        }
    }
    return @($changes.ToArray())
}

function Test-DirectWorkspaceReparse {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $stack = [Collections.Generic.Stack[string]]::new()
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $dirItem = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
        if (($dirItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and $dir -cne $root) {
            return $true
        }
        $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)
        foreach ($item in $items) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
            if ($item.PSIsContainer) { $stack.Push($item.FullName) }
        }
    }
    return $false
}

function ConvertFrom-DirectCursorNdjson {
    [CmdletBinding()]
    param([string]$Stdout)

    if ([string]::IsNullOrWhiteSpace($Stdout)) {
        return [ordered]@{
            available = $false
            malformed = $false
            shape_ok = $false
            init = $null
            result_event = $null
            error = 'stdout_absent'
        }
    }

    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in @($Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        try {
            $events.Add(($line | ConvertFrom-Json))
        } catch {
            return [ordered]@{
                available = $false
                malformed = $true
                shape_ok = $false
                init = $null
                result_event = $null
                error = 'malformed_ndjson'
            }
        }
    }

    $initEvents = @($events | Where-Object {
        [string](Get-DirectNoteValue -Object $_ -Name 'type') -eq 'system' -and
        [string](Get-DirectNoteValue -Object $_ -Name 'subtype') -eq 'init'
    })
    $resultEvents = @($events | Where-Object { [string](Get-DirectNoteValue -Object $_ -Name 'type') -eq 'result' })
    $shapeOk = ($initEvents.Count -eq 1 -and $resultEvents.Count -eq 1)
    return [ordered]@{
        available = $true
        malformed = $false
        shape_ok = $shapeOk
        init = $(if ($initEvents.Count -eq 1) { $initEvents[0] } else { $null })
        result_event = $(if ($resultEvents.Count -eq 1) { $resultEvents[0] } else { $null })
        error = $(if ($shapeOk) { $null } else { 'shape_invalid' })
    }
}

function Get-DirectCursorPolicyViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [string]$Workspace,
        [string[]]$AllowedWriteRelative,
        [Parameter(Mandatory = $true)]$Changes
    )

    $list = [Collections.Generic.List[object]]::new()
    $changeList = @($Changes)
    if ($Mode -ceq 'Verify') {
        foreach ($change in $changeList) {
            $list.Add([ordered]@{
                kind = 'verify_mutation'
                code = 'verify_workspace_mutated'
                path = ([string]$change.path).Replace('\', '/')
                change = [string]$change.change
            })
        }
        return @($list)
    }
    if ($Mode -cne 'Write') { return @() }

    $workspace = [IO.Path]::GetFullPath($Workspace).TrimEnd('\')
    $roots = [Collections.Generic.List[string]]::new()
    foreach ($rel in @($AllowedWriteRelative)) {
        if ([string]::IsNullOrWhiteSpace([string]$rel)) { continue }
        $roots.Add([IO.Path]::GetFullPath((Join-Path $workspace ([string]$rel).Replace('/', '\'))).TrimEnd('\'))
    }
    foreach ($change in $changeList) {
        $rel = ([string]$change.path).Replace('\', '/')
        $abs = [IO.Path]::GetFullPath((Join-Path $workspace ($rel.Replace('/', '\')))).TrimEnd('\')
        $isAllowed = $false
        foreach ($root in $roots) {
            if (Test-DirectPathInside -Candidate $abs -Root $root) { $isAllowed = $true; break }
        }
        if (-not $isAllowed) {
            $list.Add([ordered]@{
                kind = 'write_scope'
                code = 'undeclared_write_path'
                path = $rel
                change = [string]$change.change
            })
        }
    }
    return @($list)
}

function Assert-DirectCursorResumeBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Mode,
        [string[]]$AllowedWriteRelative,
        [string]$ExpectedAccount = '',
        [string]$ExpectedSubscription = ''
    )

    $expectedScope = (@($AllowedWriteRelative | ForEach-Object { [string]$_ }) -join '|')
    $actualScope = (@($Record.allowed_write_paths | ForEach-Object { [string]$_ }) -join '|')
    if ($Record.model_id -ne $Model -or
        -not ([string]$Record.workspace).Equals($Workspace, [StringComparison]::OrdinalIgnoreCase) -or
        $Record.mode -ne $Mode -or
        $actualScope -ne $expectedScope) {
        throw 'Resume session binding does not match model, workspace, mode, and write scope.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedAccount)) {
        $recordAccount = $null
        if ($Record -is [Collections.IDictionary] -and $Record.Contains('account')) { $recordAccount = [string]$Record.account }
        elseif ($null -ne $Record.PSObject.Properties['account']) { $recordAccount = [string]$Record.account }
        if ($recordAccount -cne $ExpectedAccount) {
            throw 'Resume session binding does not match the caller-supplied expected identity.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSubscription)) {
        $recordSub = $null
        if ($Record -is [Collections.IDictionary] -and $Record.Contains('subscription')) { $recordSub = [string]$Record.subscription }
        elseif ($null -ne $Record.PSObject.Properties['subscription']) { $recordSub = [string]$Record.subscription }
        if ($recordSub -cne $ExpectedSubscription) {
            throw 'Resume session binding does not match the caller-supplied expected identity.'
        }
    }
}

function ConvertFrom-DirectCursorQualifiedProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Qualified probe output is empty.' }
    $obj = $null
    try {
        $obj = $Text | ConvertFrom-Json
    } catch {
        throw 'Qualified probe output is not valid JSON.'
    }
    if ($null -eq $obj -or $obj -is [string] -or $obj -is [ValueType] -or $obj -is [System.Array]) {
        throw 'Qualified probe output is not an object.'
    }
    $required = @(Get-DirectCursorQualifiedProbeRequiredKeys)
    $names = @($obj.PSObject.Properties.Name)
    if ($names.Count -ne $required.Count) { throw 'Qualified probe key count mismatch.' }
    foreach ($key in $required) {
        if ($names -cnotcontains $key) { throw 'Qualified probe keys are missing, extra, or wrong-case.' }
    }
    foreach ($name in $names) {
        if ($required -cnotcontains $name) { throw 'Qualified probe keys are missing, extra, or wrong-case.' }
    }
    if ([string]$obj.protocol_version -cne 'telephone-line-direct-cursor-qualified-probe-v1') {
        throw 'Qualified probe protocol is unsupported.'
    }
    $probe = [ordered]@{
        protocol_version = [string]$obj.protocol_version
    }
    foreach ($key in $required) {
        if ($key -ceq 'protocol_version') { continue }
        $val = $obj.$key
        if ($val -isnot [bool]) { throw 'Qualified probe facts must be boolean.' }
        $probe[$key] = [bool]$val
    }
    return $probe
}

function Assert-DirectCursorQualifiedProbeObject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Probe)

    $required = @(Get-DirectCursorQualifiedProbeRequiredKeys)
    $names = @($Probe.Keys | ForEach-Object { [string]$_ })
    if ($names.Count -ne $required.Count) { throw 'Qualified probe key count mismatch.' }
    foreach ($key in $required) {
        if ($names -cnotcontains $key) { throw 'Qualified probe keys are missing, extra, or wrong-case.' }
    }
    foreach ($name in $names) {
        if ($required -cnotcontains $name) { throw 'Qualified probe keys are missing, extra, or wrong-case.' }
    }
    if ([string]$Probe['protocol_version'] -cne 'telephone-line-direct-cursor-qualified-probe-v1') {
        throw 'Qualified probe protocol is unsupported.'
    }
    foreach ($key in $required) {
        if ($key -ceq 'protocol_version') { continue }
        if ($Probe[$key] -isnot [bool]) { throw 'Qualified probe facts must be boolean.' }
    }
}

function Get-DirectNoteValue {
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        foreach ($key in @($Object.Keys)) {
            if ([string]$key -ceq $Name) { return $Object[$key] }
        }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-DirectCursorTerminalValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Ndjson,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [string]$ExpectedModelDisplay,
        [string]$ResumeSessionId
    )

    $evidence = [ordered]@{
        agent_result = 'unavailable'
        usage = 'unavailable'
        session = 'unavailable'
        model = 'unavailable'
        changed_files = 'available'
        exit_status = 'available'
        stderr = 'empty'
    }
    $init = $Ndjson.init
    $resultEvent = $Ndjson.result_event
    $sessionId = $null
    $agentResult = $null
    $usage = $null
    $modelDisplay = $null
    $subscriptionAuth = $null

    if ($null -ne $init -and $Ndjson.available -and -not $Ndjson.malformed) {
        $observedModel = Get-DirectNoteValue -Object $init -Name 'model'
        if (-not [string]::IsNullOrWhiteSpace([string]$observedModel)) {
            try {
                $modelDisplay = ConvertTo-DirectStableCursorModelDisplay -Display ([string]$observedModel)
                $evidence.model = 'available'
            } catch { }
        }
        $observedSession = Get-DirectNoteValue -Object $init -Name 'session_id'
        if (-not [string]::IsNullOrWhiteSpace([string]$observedSession)) {
            $sessionId = [string]$observedSession
            $evidence.session = 'available'
        }
        if ([string](Get-DirectNoteValue -Object $init -Name 'apiKeySource') -ceq 'login') { $subscriptionAuth = 'login' }
    }
    if ($null -ne $resultEvent -and $Ndjson.available -and -not $Ndjson.malformed) {
        $observedResult = Get-DirectNoteValue -Object $resultEvent -Name 'result'
        if ($null -ne $observedResult) {
            $agentResult = [string]$observedResult
            $evidence.agent_result = 'available'
        }
        $usageValue = Get-DirectNoteValue -Object $resultEvent -Name 'usage'
        if ($null -ne $usageValue) {
            $usage = $usageValue
            $evidence.usage = 'available'
        }
        $resultSession = Get-DirectNoteValue -Object $resultEvent -Name 'session_id'
        if ($evidence.session -ceq 'available' -and [string]$resultSession -cne $sessionId) {
            $evidence.session = 'unavailable'
            $sessionId = $null
        }
    }

    $base = {
        param([bool]$Valid, [string]$Message)
        return [ordered]@{
            valid = $Valid
            error_message = $Message
            init = $init
            result_event = $resultEvent
            model_display = $modelDisplay
            session_id = $sessionId
            agent_result = $agentResult
            usage = $usage
            subscription_auth = $subscriptionAuth
            evidence = $evidence
        }
    }

    if ($Ndjson.malformed) {
        return (& $base $false 'Cursor emitted malformed NDJSON.')
    }
    if (-not $Ndjson.available -or $true -ne $Ndjson.shape_ok) {
        return (& $base $false 'Cursor stream must contain exactly one init event and one terminal result event.')
    }
    if ([string](Get-DirectNoteValue -Object $init -Name 'apiKeySource') -ne 'login') {
        return (& $base $false 'Cursor did not use subscription login authentication.')
    }
    if (-not [string]::Equals([string](Get-DirectNoteValue -Object $init -Name 'cwd'), $Workspace, [StringComparison]::OrdinalIgnoreCase)) {
        return (& $base $false 'Cursor cwd does not match the locked workspace.')
    }
    $actualModelDisplay = $null
    try {
        $actualModelDisplay = ConvertTo-DirectStableCursorModelDisplay -Display ([string](Get-DirectNoteValue -Object $init -Name 'model'))
    } catch {
        return (& $base $false $_.Exception.Message)
    }
    if (-not [string]::Equals($actualModelDisplay, $ExpectedModelDisplay, [StringComparison]::Ordinal)) {
        return (& $base $false 'Cursor model mismatch.')
    }
    $modelDisplay = $actualModelDisplay
    $evidence.model = 'available'
    if ([string](Get-DirectNoteValue -Object $resultEvent -Name 'subtype') -ne 'success' -or (Get-DirectNoteValue -Object $resultEvent -Name 'is_error') -eq $true) {
        return (& $base $false 'Cursor terminal result is not success.')
    }
    $initSession = Get-DirectNoteValue -Object $init -Name 'session_id'
    $resultSessionId = Get-DirectNoteValue -Object $resultEvent -Name 'session_id'
    if ([string]::IsNullOrWhiteSpace([string]$initSession) -or [string]$resultSessionId -ne [string]$initSession) {
        return (& $base $false 'Cursor session identity is missing or inconsistent.')
    }
    $sessionId = [string]$initSession
    $evidence.session = 'available'
    if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId) -and [string]$initSession -ne $ResumeSessionId) {
        return (& $base $false 'Cursor resumed a different session.')
    }

    return (& $base $true $null)
}

function Complete-DirectCursorAgentRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [string[]]$AllowedWriteRelative,
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$Changes,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$DispatchId,
        [Parameter(Mandatory = $true)][string]$PromptSha256,
        [string]$ExpectedModelDisplay,
        [string]$ResumeSessionId,
        [int]$MaxErrorChars = 2000
    )

    $changeList = @($Changes)
    $normalizedChanges = @($changeList | ForEach-Object {
        [ordered]@{
            path = ([string]$_.path).Replace('\', '/')
            change = [string]$_.change
        }
    })
    $allowedRelative = @($AllowedWriteRelative | ForEach-Object { [string]$_ })
    $ndjson = ConvertFrom-DirectCursorNdjson -Stdout ([string]$Run.Stdout)
    $validation = Get-DirectCursorTerminalValidation -Ndjson $ndjson -Workspace $Workspace -ExpectedModelDisplay $ExpectedModelDisplay -ResumeSessionId $ResumeSessionId
    $evidence = $validation.evidence
    $evidence.stderr = $(if ([string]::IsNullOrEmpty([string]$Run.Stderr)) { 'empty' } else { 'available' })
    $evidence.exit_status = 'available'

    $violations = @(Get-DirectCursorPolicyViolations -Mode $Mode -Workspace $Workspace -AllowedWriteRelative $allowedRelative -Changes $normalizedChanges)
    $violatingPaths = @($violations | ForEach-Object { [string]$_.path } | Sort-Object -Unique)

    $cursorFailure = {
        param([string]$Message)
        $payload = [ordered]@{
            outcome = 'cursor_failure'
            register_session = $false
            result = $null
            error_message = $Message
            changed_files = @($normalizedChanges)
            evidence = $evidence
            violating_paths = @($violatingPaths)
            policy_violation = ($violations.Count -gt 0)
        }
        if ($violations.Count -gt 0) {
            $payload['policy_violations'] = @($violations)
            $payload.evidence = $evidence
            if ($payload.evidence -is [Collections.IDictionary]) {
                $payload.evidence['policy_violations'] = @($violations)
                $payload.evidence['violating_paths'] = @($violatingPaths)
                $payload.evidence['policy_violation'] = $true
            }
        }
        return $payload
    }

    if ([int]$Run.ExitCode -ne 0) {
        return (& $cursorFailure ('Cursor CLI exited {0}: {1}' -f [int]$Run.ExitCode, (Limit-DirectText -Text ([string]$Run.Stderr) -Limit $MaxErrorChars)))
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Run.Stderr)) {
        return (& $cursorFailure ('Cursor CLI wrote to stderr: {0}' -f (Limit-DirectText -Text ([string]$Run.Stderr) -Limit $MaxErrorChars)))
    }

    if ($true -ne $validation.valid) {
        return (& $cursorFailure ([string]$validation.error_message))
    }

    if ($violations.Count -gt 0) {
        $code = if ($Mode -ceq 'Verify') { 'verify_workspace_mutated' } else { 'write_scope_violation' }
        $violatingPaths = @($violations | ForEach-Object { [string]$_.path } | Sort-Object -Unique)
        $result = [ordered]@{
            success = $false
            dispatch_id = $DispatchId
            prompt_sha256 = $PromptSha256
            fast_disabled = $true
            model_id = $Model
            model_display = $validation.model_display
            workspace = $Workspace
            mode = $Mode
            allowed_write_paths = @($allowedRelative)
            session_id = $validation.session_id
            resumed = -not [string]::IsNullOrWhiteSpace($ResumeSessionId)
            result = $validation.agent_result
            usage = $validation.usage
            duration_ms = [int]$Run.DurationMs
            changed_files = @($normalizedChanges)
            failure_kind = 'policy'
            failure_code = $code
            violating_paths = @($violatingPaths)
            evidence = $evidence
            cursor_exit_code = [int]$Run.ExitCode
            stderr_present = -not [string]::IsNullOrEmpty([string]$Run.Stderr)
        }
        return [ordered]@{
            outcome = 'policy_failure'
            register_session = $false
            result = $result
            error_message = $null
            changed_files = @($normalizedChanges)
            evidence = $evidence
        }
    }

    if ($Mode -ceq 'ReadOnly' -and $normalizedChanges.Count -gt 0) {
        return (& $cursorFailure 'Read-only Cursor dispatch changed workspace files.')
    }

    $init = $validation.init
    $resultEvent = $validation.result_event
    return [ordered]@{
        outcome = 'success'
        register_session = $true
        result = [ordered]@{
            success = $true
            dispatch_id = $DispatchId
            prompt_sha256 = $PromptSha256
            fast_disabled = $true
            model_id = $Model
            model_display = $ExpectedModelDisplay
            workspace = $Workspace
            mode = $Mode
            allowed_write_paths = @($allowedRelative)
            session_id = [string]$init.session_id
            resumed = -not [string]::IsNullOrWhiteSpace($ResumeSessionId)
            result = [string](Get-DirectNoteValue -Object $resultEvent -Name 'result')
            usage = (Get-DirectNoteValue -Object $resultEvent -Name 'usage')
            duration_ms = [int]$Run.DurationMs
            changed_files = @($normalizedChanges)
        }
        error_message = $null
        changed_files = @($normalizedChanges)
        evidence = $evidence
    }
}

function Get-DirectCursorWorkspaceMutexName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Workspace)

    $material = [Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($Workspace).TrimEnd('\')).ToLowerInvariant())
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($material)).ToLowerInvariant()
    return "Global\TelephoneLineDirectCursorWorkspace_$hash"
}

function Get-DirectCursorRecoveryProtocol {
    [CmdletBinding()]
    param()
    return 'telephone-line-direct-cursor-recovery-v1'
}

function Get-DirectCursorRecoveryRequiredKeys {
    [CmdletBinding()]
    param()
    return @(
        'protocol_version',
        'native_session_id',
        'latest_job_id',
        'receipt',
        'updated_at_utc'
    )
}

function Get-DirectCursorRecoveryBindingPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$NativeSessionId
    )

    if ($NativeSessionId -cnotmatch '^[A-Za-z0-9._:-]+$') {
        throw 'Adapter native session id is malformed.'
    }
    $root = Get-DirectCanonicalDirectory -Path $StateRoot
    $recoveryRoot = Join-Path $root 'recovery'
    $leaf = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($NativeSessionId))).ToLowerInvariant()
    $sessionRoot = [IO.Path]::GetFullPath((Join-Path $recoveryRoot $leaf)).TrimEnd('\')
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path $recoveryRoot $leaf)).TrimEnd('\')
    if (-not $sessionRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Adapter native session id is malformed.'
    }
    if (-not (Test-DirectPathWithin -Root $recoveryRoot -Path $sessionRoot -AllowEqual)) {
        throw 'Adapter native session id is malformed.'
    }
    return Join-Path $sessionRoot 'binding.json'
}

function Publish-DirectCursorRecoveryBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$NativeSessionId,
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$ReceiptIdentity
    )

    if ([string]::IsNullOrWhiteSpace($NativeSessionId) -or [string]::IsNullOrWhiteSpace($JobId)) {
        throw 'Direct Cursor recovery binding is missing job or session identity.'
    }
    $path = Get-DirectCursorRecoveryBindingPath -StateRoot $StateRoot -NativeSessionId $NativeSessionId
    $record = [ordered]@{
        protocol_version = Get-DirectCursorRecoveryProtocol
        native_session_id = $NativeSessionId
        latest_job_id = $JobId
        receipt = [ordered]@{
            path = [string]$ReceiptIdentity.path
            bytes = [int64]$ReceiptIdentity.bytes
            sha256 = [string]$ReceiptIdentity.sha256
        }
        updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $mutex = [Threading.Mutex]::new($false, 'Global\TelephoneLineDirectCursorRecoveryIndex')
    if (-not $mutex.WaitOne(30000)) { throw 'Direct Cursor recovery index is busy.' }
    try {
        $parent = [IO.Path]::GetDirectoryName($path)
        if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        $parentItem = Get-Item -LiteralPath $parent -Force
        if (-not $parentItem.PSIsContainer -or ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Direct Cursor recovery binding path is not a regular directory.'
        }
        $json = ($record | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n"
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $temporaryPath = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        $stream = [IO.FileStream]::new($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        $tmpItem = Get-Item -LiteralPath $temporaryPath -Force
        if ($tmpItem.PSIsContainer -or ($tmpItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            [IO.File]::Delete($temporaryPath)
            throw 'Direct Cursor recovery binding is not a regular file.'
        }
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force
        $null = Get-DirectFileIdentity -Path $path
    } finally {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}

function Read-DirectCursorRecoveryBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$NativeSessionId
    )

    $path = Get-DirectCursorRecoveryBindingPath -StateRoot $StateRoot -NativeSessionId $NativeSessionId
    if (-not [IO.File]::Exists($path)) { return $null }
    $null = Get-DirectFileIdentity -Path $path
    $text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($path)).TrimStart([char]0xFEFF)
    $obj = $null
    try {
        $obj = $text | ConvertFrom-Json
    } catch {
        throw 'Direct Cursor recovery binding is malformed.'
    }
    if ($null -eq $obj -or $obj -is [string] -or $obj -is [ValueType] -or $obj -is [System.Array]) {
        throw 'Direct Cursor recovery binding is malformed.'
    }
    $required = @(Get-DirectCursorRecoveryRequiredKeys)
    $names = @($obj.PSObject.Properties.Name)
    if ($names.Count -ne $required.Count) { throw 'Direct Cursor recovery binding is malformed.' }
    foreach ($key in $required) {
        if ($names -cnotcontains $key) { throw 'Direct Cursor recovery binding is malformed.' }
    }
    foreach ($name in $names) {
        if ($required -cnotcontains $name) { throw 'Direct Cursor recovery binding is malformed.' }
    }
    if ([string]$obj.protocol_version -cne (Get-DirectCursorRecoveryProtocol)) {
        throw 'Direct Cursor recovery binding protocol is unsupported.'
    }
    if ([string]$obj.native_session_id -cne $NativeSessionId) {
        throw 'Adapter native session id does not match the frozen session.'
    }
    if ([string]$obj.latest_job_id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'Direct Cursor recovery binding is malformed.'
    }
    $receipt = $obj.receipt
    if ($null -eq $receipt -or $receipt -is [string] -or $receipt -is [ValueType] -or $receipt -is [System.Array]) {
        throw 'Direct Cursor recovery binding is malformed.'
    }
    $receiptNames = @($receipt.PSObject.Properties.Name)
    foreach ($key in @('path', 'bytes', 'sha256')) {
        if ($receiptNames -cnotcontains $key) { throw 'Direct Cursor recovery binding is malformed.' }
    }
    foreach ($name in $receiptNames) {
        if (@('path', 'bytes', 'sha256') -cnotcontains $name) { throw 'Direct Cursor recovery binding is malformed.' }
    }
    return [ordered]@{
        protocol_version = [string]$obj.protocol_version
        native_session_id = [string]$obj.native_session_id
        latest_job_id = [string]$obj.latest_job_id
        receipt = [ordered]@{
            path = [string]$receipt.path
            bytes = [int64]$receipt.bytes
            sha256 = [string]$receipt.sha256
        }
        updated_at_utc = [string]$obj.updated_at_utc
    }
}

function Resolve-DirectCursorRecoverJobId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$NativeSessionId
    )

    $recovery = Read-DirectCursorRecoveryBinding -StateRoot $StateRoot -NativeSessionId $NativeSessionId
    if ($null -eq $recovery) { return $null }
    $jobId = [string]$recovery.latest_job_id
    $expectedReceipt = [IO.Path]::GetFullPath((Join-Path $StateRoot ('jobs\' + $jobId + '\receipt.json')))
    $boundPath = [IO.Path]::GetFullPath([string]$recovery.receipt.path)
    if (-not $boundPath.Equals($expectedReceipt, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Adapter durable state was not found.'
    }
    $actual = Get-DirectFileIdentity -Path $expectedReceipt
    if ([int64]$actual.bytes -ne [int64]$recovery.receipt.bytes -or [string]$actual.sha256 -cne [string]$recovery.receipt.sha256) {
        throw 'Adapter durable state was not found.'
    }
    $receiptRead = Read-DirectJson -Path $expectedReceipt
    if ([string]$receiptRead.value.job_id -cne $jobId) {
        throw 'Adapter durable state was not found.'
    }
    if ([string]$receiptRead.value.native_session_id -cne $NativeSessionId -and
        ($null -eq $receiptRead.value.cursor_result -or [string]$receiptRead.value.cursor_result.session_id -cne $NativeSessionId)) {
        throw 'Adapter native session id does not match the frozen session.'
    }
    return $jobId
}

function Invoke-DirectCursorLaunchPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AdapterRoot,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$Mode,
        [string[]]$AllowedWritePath,
        [string]$ResumeSessionId,
        [string]$ExpectedAccount = '',
        [string]$ExpectedSubscription = '',
        [string]$Model = 'cursor-grok-4.6-xhigh',
        [Collections.IDictionary]$ProbeEvidence
    )

    if ($null -eq $ProbeEvidence) { throw 'Qualified probe evidence is missing.' }
    Assert-DirectCursorQualifiedProbeObject -Probe $ProbeEvidence

    $codes = @(Get-DirectCursorPreflightCheckCodes)
    $results = [ordered]@{}
    foreach ($code in $codes) {
        $results[$code] = [ordered]@{ code = $code; status = 'not_evaluated'; message = '' }
    }
    function Set-PreflightCheck {
        param([string]$Code, [string]$Status, [string]$Message)
        $results[$Code] = [ordered]@{ code = $Code; status = $Status; message = $Message }
    }

    $adapterRoot = [IO.Path]::GetFullPath($AdapterRoot).TrimEnd('\')
    $resolvedStateRoot = $null
    $promptBytes = $null
    $promptSha = $null
    $promptText = $null
    $workspace = $null
    $authority = $null
    $allowedRelative = [string[]]@()
    $workspaceSnapshotExclusions = @()
    $routeFiles = [ordered]@{
        common = $null
        entry = $null
        runtime = $null
        bridge = $null
        host = $null
        job_host = $null
    }

    try {
        $resolvedStateRoot = Get-DirectCanonicalDirectory -Path $StateRoot
        $stateParent = [IO.Path]::GetDirectoryName($resolvedStateRoot)
        if ([string]::IsNullOrWhiteSpace($stateParent) -or -not [IO.Directory]::Exists($stateParent)) {
            Set-PreflightCheck 'state_root_containment' 'fail' 'State-root parent does not exist.'
        } else {
            $parentItem = Get-Item -LiteralPath $stateParent -Force
            if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Set-PreflightCheck 'state_root_containment' 'fail' 'State-root parent is a reparse point.'
            } elseif ([IO.Directory]::Exists($resolvedStateRoot)) {
                $stateItem = Get-Item -LiteralPath $resolvedStateRoot -Force
                if (-not $stateItem.PSIsContainer) {
                    Set-PreflightCheck 'state_root_containment' 'fail' 'State root is not a directory.'
                } elseif (($stateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Set-PreflightCheck 'state_root_containment' 'fail' 'State root is a reparse point.'
                } else {
                    Set-PreflightCheck 'state_root_containment' 'pass' ''
                }
            } else {
                Set-PreflightCheck 'state_root_containment' 'pass' ''
            }
        }
    } catch {
        Set-PreflightCheck 'state_root_containment' 'fail' 'State root could not be normalized.'
    }

    $jobRoot = if ($null -ne $resolvedStateRoot) { Join-Path $resolvedStateRoot ('jobs\' + $JobId) } else { $null }
    if ($results['state_root_containment'].status -cne 'pass') {
        Set-PreflightCheck 'job_id_collision' 'not_evaluated' 'State root is not usable.'
    } elseif ([IO.Directory]::Exists($jobRoot)) {
        Set-PreflightCheck 'job_id_collision' 'fail' 'Job id already exists.'
    } else {
        Set-PreflightCheck 'job_id_collision' 'pass' ''
    }

    $promptPath = $PromptFile
    try { $promptPath = [IO.Path]::GetFullPath($PromptFile) } catch { $promptPath = $PromptFile }
    if (-not [IO.File]::Exists($promptPath)) {
        Set-PreflightCheck 'prompt_exists' 'fail' 'Prompt file does not exist.'
    } else {
        Set-PreflightCheck 'prompt_exists' 'pass' ''
        try {
            $promptIdentity = Get-DirectFileIdentity -Path $promptPath
            Set-PreflightCheck 'prompt_regular_file' 'pass' ''
            try {
                $promptBytes = [IO.File]::ReadAllBytes([string]$promptIdentity.path)
                $promptText = [Text.UTF8Encoding]::new($false, $true).GetString($promptBytes)
                $promptSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes)).ToLowerInvariant()
                Set-PreflightCheck 'prompt_utf8' 'pass' ''
                if ([string]::IsNullOrWhiteSpace($promptText) -or $promptText.Length -lt 1 -or $promptText.Length -gt 12000) {
                    Set-PreflightCheck 'prompt_length' 'fail' 'Prompt must contain 1 to 12000 characters.'
                } else {
                    Set-PreflightCheck 'prompt_length' 'pass' ''
                }
            } catch {
                Set-PreflightCheck 'prompt_utf8' 'fail' 'Prompt is not strict UTF-8.'
            }
        } catch {
            Set-PreflightCheck 'prompt_regular_file' 'fail' 'Prompt is not a regular non-reparse file.'
        }
    }

    $workspaceCandidate = $null
    try { $workspaceCandidate = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\') } catch { $workspaceCandidate = $null }
    if ($null -eq $workspaceCandidate -or -not [IO.Directory]::Exists($workspaceCandidate)) {
        Set-PreflightCheck 'workspace_exists' 'fail' 'Workspace does not exist.'
    } else {
        Set-PreflightCheck 'workspace_exists' 'pass' ''
        try {
            $workspaceItem = Get-Item -LiteralPath $workspaceCandidate -Force -ErrorAction Stop
            if (-not $workspaceItem.PSIsContainer) {
                Set-PreflightCheck 'workspace_directory' 'fail' 'Workspace is not a directory.'
            } elseif (($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Set-PreflightCheck 'workspace_directory' 'fail' 'Workspace root is a reparse point.'
            } else {
                Set-PreflightCheck 'workspace_directory' 'pass' ''
                $workspace = $workspaceCandidate
                $aliasMessage = Get-DirectCursorWorkspaceAliasReason -Workspace $workspace -WorkspaceItem $workspaceItem
                if (-not [string]::IsNullOrWhiteSpace([string]$aliasMessage)) {
                    Set-PreflightCheck 'workspace_alias' 'fail' $aliasMessage
                } else {
                    Set-PreflightCheck 'workspace_alias' 'pass' ''
                }

                if (Test-DirectCursorBroadWorkspaceRoot -Workspace $workspace) {
                    Set-PreflightCheck 'workspace_broad_root' 'fail' 'Workspace is a forbidden broad root.'
                } else {
                    Set-PreflightCheck 'workspace_broad_root' 'pass' ''
                }

                if (Test-DirectCursorSensitiveWorkspaceRoot -Workspace $workspace) {
                    Set-PreflightCheck 'workspace_sensitive_root' 'fail' 'Workspace is a forbidden sensitive root.'
                } else {
                    Set-PreflightCheck 'workspace_sensitive_root' 'pass' ''
                }

                if (Test-DirectWorkspaceReparse -Root $workspace) {
                    Set-PreflightCheck 'workspace_reparse' 'fail' 'Workspace contains a reparse point.'
                } else {
                    Set-PreflightCheck 'workspace_reparse' 'pass' ''
                }

                if ($results['state_root_containment'].status -ceq 'pass' -and $null -ne $resolvedStateRoot -and
                    ($resolvedStateRoot.Equals($workspace, [StringComparison]::OrdinalIgnoreCase) -or
                     $resolvedStateRoot.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase))) {
                    Set-PreflightCheck 'state_root_containment' 'fail' 'State root cannot be stored inside the execution workspace.'
                }
            }
        } catch {
            Set-PreflightCheck 'workspace_directory' 'fail' 'Workspace could not be inspected.'
        }
    }

    $allowWriteFlag = $Mode -ceq 'Write'
    try {
        if ($null -eq $workspace) { throw 'Workspace is not available for mode evaluation.' }
        $authority = Resolve-DirectCursorModeAuthority -Mode $Mode -AllowWrite $allowWriteFlag -AllowedWritePath $AllowedWritePath -WorkspacePath $workspace
        Set-PreflightCheck 'mode_authority' 'pass' ''
        $allowedRelative = [string[]]@($authority.allowed_write_paths)
    } catch {
        $modeMessage = $_.Exception.Message
        if ($null -eq $workspace -and $Mode -cne 'Write' -and $Mode -cne 'write') {
            try {
                $rawPaths = @()
                if ($null -ne $AllowedWritePath) { $rawPaths = @($AllowedWritePath) }
                $hasPath = $false
                foreach ($raw in $rawPaths) { if (-not [string]::IsNullOrWhiteSpace([string]$raw)) { $hasPath = $true; break } }
                $canonicalProbe = $null
                switch -Regex ($Mode) {
                    '^(?i)readonly$' { $canonicalProbe = 'ReadOnly' }
                    '^(?i)verify$' { $canonicalProbe = 'Verify' }
                    '^(?i)write$' { $canonicalProbe = 'Write' }
                    default { $canonicalProbe = $null }
                }
                if ($null -ne $canonicalProbe -and $canonicalProbe -cne 'Write' -and -not $allowWriteFlag -and -not $hasPath) {
                    Set-PreflightCheck 'mode_authority' 'pass' ''
                    $authority = [ordered]@{
                        mode = $canonicalProbe
                        allow_write = $false
                        allowed_write_paths = [string[]]@()
                        command_capable = ($canonicalProbe -ceq 'Verify')
                        requires_linked_worktree = $false
                    }
                } else {
                    Set-PreflightCheck 'mode_authority' 'fail' (Limit-DirectText -Text $modeMessage -Limit 200)
                }
            } catch {
                Set-PreflightCheck 'mode_authority' 'fail' (Limit-DirectText -Text $modeMessage -Limit 200)
            }
        } else {
            Set-PreflightCheck 'mode_authority' 'fail' (Limit-DirectText -Text $modeMessage -Limit 200)
        }
    }

    if ($null -ne $authority -and $authority.mode -ceq 'Write') {
        $rawPaths = @()
        if ($null -ne $AllowedWritePath) { $rawPaths = @($AllowedWritePath) }
        try {
            if ($null -eq $workspace) { throw 'Workspace is not available.' }
            $normalized = [string[]]@(ConvertTo-DirectRelativeWritePaths -WorkspacePath $workspace -Paths $rawPaths)
            Set-PreflightCheck 'write_scope_normalization' 'pass' ''
            Set-PreflightCheck 'write_scope_containment' 'pass' ''
            $allowedRelative = $normalized
            $missing = [Collections.Generic.List[string]]::new()
            $reparseHits = [Collections.Generic.List[string]]::new()
            foreach ($rel in $normalized) {
                $full = [IO.Path]::GetFullPath((Join-Path $workspace $rel)).TrimEnd('\')
                if (-not (Test-Path -LiteralPath $full)) {
                    $missing.Add($rel)
                    continue
                }
                $item = Get-Item -LiteralPath $full -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $reparseHits.Add($rel) }
            }
            if ($missing.Count -gt 0) {
                Set-PreflightCheck 'write_scope_existence' 'fail' 'Declared write path does not exist.'
            } else {
                Set-PreflightCheck 'write_scope_existence' 'pass' ''
                if ($reparseHits.Count -gt 0) {
                    Set-PreflightCheck 'write_scope_non_reparse' 'fail' 'Declared write path is a reparse point.'
                } else {
                    Set-PreflightCheck 'write_scope_non_reparse' 'pass' ''
                }
            }
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match 'escapes the workspace') {
                Set-PreflightCheck 'write_scope_normalization' 'fail' 'Declared write path is not workspace-relative or cannot be normalized.'
                Set-PreflightCheck 'write_scope_containment' 'fail' 'Declared write path escapes the workspace.'
            } else {
                Set-PreflightCheck 'write_scope_normalization' 'fail' (Limit-DirectText -Text $msg -Limit 200)
            }
        }
    }

    if ($null -ne $authority -and $true -eq $authority.requires_linked_worktree) {
        if ($null -eq $workspace) {
            Set-PreflightCheck 'linked_worktree_leaf' 'not_evaluated' 'Workspace is not available.'
        } elseif (Test-Path -LiteralPath (Join-Path $workspace '.git') -PathType Leaf) {
            Set-PreflightCheck 'linked_worktree_leaf' 'pass' ''
        } else {
            Set-PreflightCheck 'linked_worktree_leaf' 'fail' 'Linked-worktree .git leaf is missing.'
        }
    }

    foreach ($pair in @(
        @('route_common_identity', (Join-Path $adapterRoot 'DirectCursor.Common.ps1'), 'common', 'Route common is not a regular file.'),
        @('route_entry_identity', (Join-Path $adapterRoot 'Invoke-DirectCursorRoute.ps1'), 'entry', 'Route entry is not a regular file.'),
        @('route_runtime_identity', (Join-Path $adapterRoot 'invoke_cursor_agent.ps1'), 'runtime', 'Route runtime is not a regular file.'),
        @('route_bridge_identity', (Join-Path $adapterRoot 'invoke_cursor_request.ps1'), 'bridge', 'Route bridge is not a regular file.'),
        @('route_host_identity', (Join-Path $adapterRoot 'process_file_host.ps1'), 'host', 'Route host is not a regular file.'),
        @('route_job_host_identity', (Join-Path $adapterRoot 'cursor_job_host.ps1'), 'job_host', 'Route job host is not a regular file.')
    )) {
        try {
            $routeFiles[$pair[2]] = Get-DirectFileIdentity -Path $pair[1]
            Set-PreflightCheck $pair[0] 'pass' ''
        } catch {
            Set-PreflightCheck $pair[0] 'fail' $pair[3]
        }
    }

    $vendorOk = $true
    foreach ($pair in @(
        @('qualified_wrapper_present', 'wrapper_present', 'wrapper_identity_match', 'Qualified wrapper is missing or drifted.'),
        @('qualified_index_present', 'index_present', 'index_identity_match', 'Qualified index is missing or drifted.'),
        @('qualified_node_present', 'node_present', 'node_identity_match', 'Qualified node is missing or drifted.')
    )) {
        $present = [bool]$ProbeEvidence[$pair[1]]
        $match = [bool]$ProbeEvidence[$pair[2]]
        if ($present -and $match) {
            Set-PreflightCheck $pair[0] 'pass' ''
        } else {
            Set-PreflightCheck $pair[0] 'fail' $pair[3]
            $vendorOk = $false
        }
    }

    $jobHostPresent = [bool]$ProbeEvidence['job_host_present']
    $jobHostMatch = [bool]$ProbeEvidence['job_host_identity_match']
    if ($results['route_job_host_identity'].status -ceq 'pass' -and $jobHostPresent -and $jobHostMatch) {
        Set-PreflightCheck 'qualified_job_host_identity' 'pass' ''
    } else {
        Set-PreflightCheck 'qualified_job_host_identity' 'fail' 'Qualified job host is missing or drifted.'
    }

    $sessionRoot = if ($null -ne $resolvedStateRoot) { Join-Path $resolvedStateRoot 'cursor-sessions' } else { $null }
    $blockedPath = if ($null -ne $sessionRoot) { Join-Path $sessionRoot 'DISPATCH_BLOCKED.json' } else { $null }
    if ($null -eq $blockedPath) {
        Set-PreflightCheck 'dispatch_block_absent' 'not_evaluated' 'State root is not usable.'
    } elseif (Test-Path -LiteralPath $blockedPath -PathType Leaf) {
        Set-PreflightCheck 'dispatch_block_absent' 'fail' 'Persistent dispatch-block marker is present.'
    } else {
        Set-PreflightCheck 'dispatch_block_absent' 'pass' ''
    }

    if ($null -eq $workspace) {
        Set-PreflightCheck 'workspace_mutex_available' 'not_evaluated' 'Workspace is not available.'
    } else {
        $mutex = $null
        $acquired = $false
        try {
            $mutex = [Threading.Mutex]::new($false, (Get-DirectCursorWorkspaceMutexName -Workspace $workspace))
            if (-not $mutex.WaitOne(0)) {
                Set-PreflightCheck 'workspace_mutex_available' 'fail' 'Workspace mutex is held.'
            } else {
                $acquired = $true
                Set-PreflightCheck 'workspace_mutex_available' 'pass' ''
            }
        } catch {
            Set-PreflightCheck 'workspace_mutex_available' 'fail' 'Workspace mutex could not be evaluated.'
        } finally {
            if ($acquired -and $null -ne $mutex) { try { $mutex.ReleaseMutex() } catch { } }
            if ($null -ne $mutex) { $mutex.Dispose() }
        }
    }

    if ($null -eq $workspace -or $null -eq $authority) {
        Set-PreflightCheck 'workspace_snapshot_qualification' 'not_evaluated' 'Workspace or mode authority is not available.'
    } else {
        try {
            $snapshotExclusions = @()
            $null = Get-DirectWorkspaceSnapshot -Root $workspace -AllowedWriteRelative $allowedRelative -VolatileExclusions ([ref]$snapshotExclusions)
            $workspaceSnapshotExclusions = @($snapshotExclusions)
            Set-PreflightCheck 'workspace_snapshot_qualification' 'pass' ''
        } catch {
            Set-PreflightCheck 'workspace_snapshot_qualification' 'fail' 'Workspace snapshot cannot classify every file safely.'
        }
    }

    $cliReady = $vendorOk -and $results['qualified_job_host_identity'].status -ceq 'pass'
    foreach ($pair in @(
        @('cli_version', 'cli_version_match', 'Qualified CLI version does not match.'),
        @('account_binding', 'account_bound', 'Account binding does not match.'),
        @('subscription_binding', 'subscription_bound', 'Subscription binding does not match.'),
        @('model_availability', 'model_available', 'Model is not available.')
    )) {
        if (-not $cliReady) {
            Set-PreflightCheck $pair[0] 'not_evaluated' 'Qualified CLI binaries are not ready.'
        } elseif ([bool]$ProbeEvidence[$pair[1]]) {
            Set-PreflightCheck $pair[0] 'pass' ''
        } else {
            Set-PreflightCheck $pair[0] 'fail' $pair[2]
        }
    }

    $resumeId = [string]$ResumeSessionId
    if ([string]::IsNullOrWhiteSpace($resumeId)) {
        Set-PreflightCheck 'resume_session_exists' 'not_evaluated' ''
        Set-PreflightCheck 'resume_session_binding' 'not_evaluated' ''
    } else {
        $registryPath = if ($null -ne $sessionRoot) { Join-Path $sessionRoot 'sessions.json' } else { $null }
        if ($null -eq $registryPath -or -not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
            Set-PreflightCheck 'resume_session_exists' 'fail' 'Resume session is not registered.'
        } else {
            try {
                $parsed = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
                $records = @($parsed.sessions | Where-Object { $_.session_id -eq $resumeId })
                if ($records.Count -ne 1) {
                    Set-PreflightCheck 'resume_session_exists' 'fail' 'Resume session is not registered.'
                } else {
                    Set-PreflightCheck 'resume_session_exists' 'pass' ''
                    if ($null -eq $authority -or $null -eq $workspace) {
                        Set-PreflightCheck 'resume_session_binding' 'not_evaluated' 'Mode or workspace is not available.'
                    } else {
                        try {
                            Assert-DirectCursorResumeBinding -Record $records[0] -Model $Model -Workspace $workspace -Mode $authority.mode -AllowedWriteRelative $allowedRelative -ExpectedAccount $ExpectedAccount -ExpectedSubscription $ExpectedSubscription
                            Set-PreflightCheck 'resume_session_binding' 'pass' ''
                        } catch {
                            Set-PreflightCheck 'resume_session_binding' 'fail' 'Resume session binding does not match.'
                        }
                    }
                }
            } catch {
                Set-PreflightCheck 'resume_session_exists' 'fail' 'Resume session registry is unreadable.'
            }
        }
    }

    $inapplicable = @{}
    if ($null -eq $authority -or $authority.mode -cne 'Write') {
        foreach ($code in @('write_scope_normalization', 'write_scope_containment', 'write_scope_existence', 'write_scope_non_reparse', 'linked_worktree_leaf')) {
            $inapplicable[$code] = $true
        }
    }
    if ([string]::IsNullOrWhiteSpace($resumeId)) {
        $inapplicable['resume_session_exists'] = $true
        $inapplicable['resume_session_binding'] = $true
    }

    $checks = [Collections.Generic.List[object]]::new()
    $blockers = [Collections.Generic.List[object]]::new()
    $launchable = $true
    foreach ($code in $codes) {
        $item = $results[$code]
        $checks.Add($item)
        if ($item.status -ceq 'fail') {
            $launchable = $false
            $blockers.Add([ordered]@{ code = $item.code; message = $item.message })
        } elseif ($item.status -ceq 'not_evaluated' -and -not $inapplicable.Contains($code)) {
            $launchable = $false
            $blockerMessage = [string]$item.message
            if ([string]::IsNullOrWhiteSpace($blockerMessage)) { $blockerMessage = 'Required check was not evaluated.' }
            $blockers.Add([ordered]@{ code = $item.code; message = $blockerMessage })
        }
    }

    $reportMode = $Mode
    if ($null -ne $authority) { $reportMode = [string]$authority.mode }

    return [ordered]@{
        protocol_version = 'telephone-line-direct-cursor-preflight-v1'
        launchable = [bool]$launchable
        job_id = $JobId
        workspace = $workspace
        mode = $reportMode
        prompt_bytes = $(if ($null -ne $promptBytes) { [int64]$promptBytes.Length } else { $null })
        prompt_sha256 = $promptSha
        allowed_write_paths = @($allowedRelative)
        volatile_snapshot_exclusions = @($workspaceSnapshotExclusions)
        route_files = $routeFiles
        checks = @($checks)
        blockers = @($blockers)
        state_changes = $false
        model_session_created = $false
    }
}

function Convert-DirectCursorFailureCodeToPublicErrorCode {
    [CmdletBinding()]
    param([AllowNull()][string]$FailureCode)

    switch -Regex ([string]$FailureCode) {
        '^(?i)cursor_output_limit$' { return 'DIRECT_CURSOR_OUTPUT_LIMIT' }
        '^(?i)cursor_stream_io$' { return 'DIRECT_CURSOR_STREAM_IO' }
        '^(?i)cursor_termination_uncertain$' { return 'DIRECT_CURSOR_TERMINATION_UNCERTAIN' }
        '^(?i)cursor_post_execution$' { return 'DIRECT_CURSOR_POST_EXECUTION' }
        '^(?i)cursor_result_projection$' { return 'DIRECT_CURSOR_RESULT_PROJECTION' }
        '^(?i)cursor_cli_failure$' { return 'DIRECT_CURSOR_CLI_FAILURE' }
        '^(?i)cursor_terminal_invalid$' { return 'DIRECT_CURSOR_TERMINAL_INVALID' }
        '^(?i)cursor_authentication_failed$' { return 'DIRECT_CURSOR_AUTH_FAILED' }
        '^(?i)cursor_model_capacity$' { return 'DIRECT_CURSOR_MODEL_CAPACITY' }
        '^(?i)cursor_rate_limited$' { return 'DIRECT_CURSOR_RATE_LIMITED' }
        '^(?i)cursor_workspace_busy$' { return 'DIRECT_CURSOR_WORKSPACE_BUSY' }
        default { return '' }
    }
}

function Resolve-DirectCursorReceiptPublicError {
    [CmdletBinding()]
    param([AllowNull()]$CursorResult)

    if ($null -eq $CursorResult) {
        return [ordered]@{
            public_error_code = 'ADAPTER_TRANSPORT_FAILED'
            public_error = Get-DirectPublicError -ErrorCode 'ADAPTER_TRANSPORT_FAILED'
            transport_error = Get-DirectPublicError -ErrorCode 'ADAPTER_TRANSPORT_FAILED'
            preserve_typed_failure = $false
        }
    }
    $isPolicy = [string](Get-DirectNoteValue -Object $CursorResult -Name 'failure_kind') -ceq 'policy'
    $success = Get-DirectNoteValue -Object $CursorResult -Name 'success'
    $existingCode = [string](Get-DirectNoteValue -Object $CursorResult -Name 'public_error_code')
    $failureCode = [string](Get-DirectNoteValue -Object $CursorResult -Name 'failure_code')
    $mapped = Convert-DirectCursorFailureCodeToPublicErrorCode -FailureCode $failureCode
    $code = $existingCode
    if ([string]::IsNullOrWhiteSpace($code)) { $code = $mapped }
    $existingError = [string](Get-DirectNoteValue -Object $CursorResult -Name 'error')
    $existingPublic = [string](Get-DirectNoteValue -Object $CursorResult -Name 'public_error')
    $message = if (-not [string]::IsNullOrWhiteSpace($existingPublic)) { $existingPublic } else { $existingError }
    $text = Get-DirectPublicError -ErrorCode $code -Message $message
    $catalog = Get-DirectPublicErrorCatalog
    $resolvedCode = $code
    if ([string]::IsNullOrWhiteSpace($resolvedCode)) {
        foreach ($key in @($catalog.Keys)) {
            if ($text -ceq [string]$catalog[$key]) { $resolvedCode = [string]$key; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($resolvedCode) -or -not $catalog.Contains($resolvedCode)) {
        $resolvedCode = 'ADAPTER_TRANSPORT_FAILED'
        $text = [string]$catalog[$resolvedCode]
    } else {
        $text = [string]$catalog[$resolvedCode]
    }
    $transport = $null
    if ($success -ne $true -and -not $isPolicy) { $transport = $text }
    return [ordered]@{
        public_error_code = $resolvedCode
        public_error = $text
        transport_error = $transport
        preserve_typed_failure = (-not [string]::IsNullOrWhiteSpace($failureCode) -or -not [string]::IsNullOrWhiteSpace($existingCode))
    }
}

function Get-DirectCursorObservedIdentity {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Stdout,
        [string]$Workspace = ''
    )

    $observed = [ordered]@{
        session_id = ''
        status = 'absent'
        source = 'none'
        accepted = $false
        cwd = ''
        cwd_matches_workspace = $false
        model_display = ''
        api_key_source = ''
        init_available = $false
        terminal_available = $false
        truncated_or_malformed = $false
    }
    if ([string]::IsNullOrWhiteSpace($Stdout)) { return $observed }

    foreach ($line in @($Stdout -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = $null
        try { $event = $line | ConvertFrom-Json } catch {
            $observed.truncated_or_malformed = $true
            continue
        }
        $type = [string](Get-DirectNoteValue -Object $event -Name 'type')
        $subtype = [string](Get-DirectNoteValue -Object $event -Name 'subtype')
        if ($type -ceq 'system' -and $subtype -ceq 'init' -and $true -ne $observed.init_available) {
            $observed.init_available = $true
            $observed.source = 'init_event'
            $session = [string](Get-DirectNoteValue -Object $event -Name 'session_id')
            if (-not [string]::IsNullOrWhiteSpace($session)) {
                $observed.session_id = $session
                $observed.status = 'partial'
            }
            $cwd = [string](Get-DirectNoteValue -Object $event -Name 'cwd')
            $observed.cwd = $cwd
            if (-not [string]::IsNullOrWhiteSpace($Workspace) -and -not [string]::IsNullOrWhiteSpace($cwd)) {
                $observed.cwd_matches_workspace = [IO.Path]::GetFullPath($cwd).TrimEnd('\').Equals(
                    [IO.Path]::GetFullPath($Workspace).TrimEnd('\'),
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
            $model = [string](Get-DirectNoteValue -Object $event -Name 'model')
            if (-not [string]::IsNullOrWhiteSpace($model)) {
                try { $observed.model_display = ConvertTo-DirectStableCursorModelDisplay -Display $model } catch { $observed.model_display = $model.Trim() }
            }
            $observed.api_key_source = [string](Get-DirectNoteValue -Object $event -Name 'apiKeySource')
        }
        if ($type -ceq 'result') { $observed.terminal_available = $true }
    }
    if ($observed.init_available -and $observed.terminal_available) {
        $observed.status = $(if ([string]::IsNullOrWhiteSpace([string]$observed.session_id)) { 'absent' } else { 'observed_unaccepted' })
    }
    $observed.accepted = $false
    return $observed
}

function Get-DirectCursorStdoutTextForObservation {
    [CmdletBinding()]
    param(
        $Run,
        [string]$DiagnosticPath = '',
        [int]$Limit = 16777216
    )

    $fromRun = [string](Get-DirectNoteValue -Object $Run -Name 'Stdout')
    if (-not [string]::IsNullOrWhiteSpace($fromRun)) { return $fromRun }
    $dir = ''
    if (-not [string]::IsNullOrWhiteSpace($DiagnosticPath) -and [IO.File]::Exists($DiagnosticPath)) {
        $dir = [IO.Path]::GetDirectoryName($DiagnosticPath)
    }
    $stdoutPath = if (-not [string]::IsNullOrWhiteSpace($dir)) { Join-Path $dir 'stdout.bin' } else { '' }
    if ([string]::IsNullOrWhiteSpace($stdoutPath) -or -not [IO.File]::Exists($stdoutPath)) { return '' }
    $fs = $null
    try {
        $fs = [IO.File]::Open($stdoutPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $cap = [Math]::Min([int64]$Limit, [int64]$fs.Length)
        $buf = [byte[]]::new([int]$cap)
        $read = $fs.Read($buf, 0, $buf.Length)
        $enc = [Text.UTF8Encoding]::new($false, $false)
        return $enc.GetString($buf, 0, $read)
    } finally {
        if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
    }
}

function Get-DirectCursorFailureObservation {
    [CmdletBinding()]
    param(
        $Run,
        [string]$DiagnosticPath = '',
        [string]$Workspace = '',
        $BeforeSnapshot = $null,
        [string[]]$AllowedWriteRelative,
        [bool]$SnapshotCompleted = $false,
        $ExistingChanges = $null
    )

    $stdoutText = ''
    $stdoutEvidence = 'unavailable'
    $secondary = [Collections.Generic.List[string]]::new()
    try {
        $stdoutText = Get-DirectCursorStdoutTextForObservation -Run $Run -DiagnosticPath $DiagnosticPath
        $stdoutEvidence = if ([string]::IsNullOrWhiteSpace($stdoutText) -and [string]::IsNullOrWhiteSpace([string](Get-DirectNoteValue -Object $Run -Name 'Stdout'))) {
            $diagDir = if (-not [string]::IsNullOrWhiteSpace($DiagnosticPath) -and [IO.File]::Exists($DiagnosticPath)) { [IO.Path]::GetDirectoryName($DiagnosticPath) } else { '' }
            $stdoutPath = if (-not [string]::IsNullOrWhiteSpace($diagDir)) { Join-Path $diagDir 'stdout.bin' } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($stdoutPath) -and [IO.File]::Exists($stdoutPath)) { 'available' } else { 'unavailable' }
        } else { 'available' }
    } catch {
        $null = $secondary.Add($_.Exception.GetType().FullName)
        $stdoutEvidence = 'unavailable'
        $stdoutText = [string](Get-DirectNoteValue -Object $Run -Name 'Stdout')
        if ($null -eq $stdoutText) { $stdoutText = '' }
    }
    $observed = Get-DirectCursorObservedIdentity -Stdout $stdoutText -Workspace $Workspace
    $availability = 'unknown'
    $changes = @()
    if ($true -eq $SnapshotCompleted) {
        $availability = 'available'
        $changes = @($ExistingChanges)
    } elseif ($null -ne $BeforeSnapshot -and -not [string]::IsNullOrWhiteSpace($Workspace) -and [IO.Directory]::Exists($Workspace)) {
        try {
            $afterExclusions = @()
            $afterSnapshot = Get-DirectWorkspaceSnapshot -Root $Workspace -AllowedWriteRelative $AllowedWriteRelative -VolatileExclusions ([ref]$afterExclusions)
            $changes = @(Compare-DirectWorkspaceSnapshot -Before $BeforeSnapshot -After $afterSnapshot)
            $availability = 'available'
        } catch {
            $null = $secondary.Add($_.Exception.GetType().FullName)
            $availability = 'unknown'
            $changes = @()
        }
    }
    return [ordered]@{
        observed_session = $observed
        changed_files_availability = $availability
        changed_files = @($changes)
        secondary_snapshot_errors = @($secondary)
        secondary_error_types = @($secondary)
        stdout_text = $stdoutText
        stdout_evidence = $stdoutEvidence
    }
}

function New-DirectCursorCaughtFailureResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$FailureStage = 'unknown',
        [string]$DispatchId = '',
        [string]$PromptSha256 = '',
        $PromptIdentity = $null,
        [AllowNull()][byte[]]$PromptBytes = $null,
        $FailureEvidence = $null,
        $Run = $null,
        [string]$ResumeSessionId = '',
        [string]$StateRoot = '',
        [string]$Workspace = '',
        [string]$Mode = '',
        [string]$Model = '',
        [string[]]$AllowedWriteRelative,
        $BeforeSnapshot = $null,
        [bool]$SnapshotCompleted = $false,
        $ExistingChanges = $null,
        $VolatileSnapshotExclusions = $null
    )

    $ex = $ErrorRecord.Exception
    $processFailureClass = ''
    if ($null -ne $ex.Data -and $null -ne $ex.Data['telephone_direct_cursor_process_failure_class']) {
        $processFailureClass = [string]$ex.Data['telephone_direct_cursor_process_failure_class']
    }
    $classification = Get-DirectCursorFailureClassification -Message $ex.Message -Stage $FailureStage -ExceptionType $ex.GetType().FullName -ProcessFailureClass $processFailureClass
    $promptPublicIdentity = if ($null -ne $PromptIdentity) {
        [ordered]@{ path = [string]$PromptIdentity.FullName; bytes = [int64]$PromptBytes.Length; sha256 = $PromptSha256 }
    } else { $null }
    if ($null -eq $FailureEvidence -or $FailureEvidence -isnot [Collections.IDictionary]) {
        $FailureEvidence = [ordered]@{}
    }
    $FailureEvidence.exception_type = $ex.GetType().FullName
    if ($null -ne $ex.InnerException) {
        $FailureEvidence.inner_exception_type = $ex.InnerException.GetType().FullName
    }
    $FailureEvidence.requested_native_session_id = [string]$ResumeSessionId
    $FailureEvidence.returned_native_session_id = ''
    $FailureEvidence.primary_failure_retained = $true
    $diagPath = ''
    if ($null -ne $ex.Data -and $null -ne $ex.Data['telephone_direct_cursor_diagnostic_path']) {
        $diagPath = [string]$ex.Data['telephone_direct_cursor_diagnostic_path']
    } elseif ($null -ne $Run -and $null -ne $Run.Diagnostic) {
        $diagPath = [string]$Run.Diagnostic.path
    }
    $stdoutBytes = [int64]0
    $stderrBytes = [int64]0
    $nativeExit = $null
    if ($null -ne $ex.Data -and $null -ne $ex.Data['telephone_direct_cursor_stdout_bytes']) {
        $stdoutBytes = [int64]$ex.Data['telephone_direct_cursor_stdout_bytes']
    }
    if ($null -ne $ex.Data -and $null -ne $ex.Data['telephone_direct_cursor_stderr_bytes']) {
        $stderrBytes = [int64]$ex.Data['telephone_direct_cursor_stderr_bytes']
    }
    if ($null -ne $ex.Data -and $null -ne $ex.Data['telephone_direct_cursor_native_exit_code']) {
        $nativeExit = [int]$ex.Data['telephone_direct_cursor_native_exit_code']
    }
    if ($null -eq $nativeExit -and -not [string]::IsNullOrWhiteSpace($diagPath) -and [IO.File]::Exists($diagPath)) {
        try {
            $diagDoc = (Read-DirectJson -Path $diagPath).value
            $fromDiagExit = Get-DirectNoteValue -Object $diagDoc -Name 'native_exit_code'
            if ($null -ne $fromDiagExit -and [string]$fromDiagExit -ne '') { $nativeExit = [int]$fromDiagExit }
        } catch {
            $FailureEvidence.secondary_diagnostic_error_types = @($_.Exception.GetType().FullName)
        }
    }
    if ([string]::IsNullOrWhiteSpace($diagPath) -and -not [string]::IsNullOrWhiteSpace($StateRoot) -and -not [string]::IsNullOrWhiteSpace($DispatchId)) {
        $ownDir = Join-Path $StateRoot ('diagnostics\' + [string]$DispatchId)
        $ownDiag = Join-Path $ownDir 'process-diagnostic.json'
        if ([IO.File]::Exists($ownDiag)) {
            $diagPath = $ownDiag
        } elseif ([IO.Directory]::Exists($ownDir)) {
            $ownLatest = @(Get-ChildItem -LiteralPath $ownDir -Recurse -Filter 'process-diagnostic.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
            if ($ownLatest.Count -gt 0) { $diagPath = [string]$ownLatest[0].FullName }
        }
        if ([string]::IsNullOrWhiteSpace($diagPath)) {
            try {
                [IO.Directory]::CreateDirectory($ownDir) | Out-Null
                if (Restrict-DirectCursorDiagnosticDirectory -Directory $ownDir) {
                    $stageDiag = Write-DirectCursorProcessDiagnostic -Directory $ownDir -Stage $FailureStage -ExceptionType $ex.GetType().FullName -ExceptionMessage $ex.Message -Classification $classification -RequestedSessionId ([string]$ResumeSessionId) -ProcessFailureClass $processFailureClass
                    $diagPath = [string]$stageDiag.path
                } else {
                    try { [IO.Directory]::Delete($ownDir, $true) } catch { }
                    $FailureEvidence.diagnostic_spool = 'unavailable'
                    $FailureEvidence.secondary_diagnostic_error_types = @('diagnostic_acl_failed')
                }
            } catch {
                $FailureEvidence.diagnostic_spool = 'unavailable'
                $FailureEvidence.secondary_diagnostic_error_types = @($_.Exception.GetType().FullName)
            }
        }
    }
    $secondaryTypes = [Collections.Generic.List[string]]::new()
    if ($FailureEvidence.Contains('secondary_diagnostic_error_types')) {
        foreach ($item in @($FailureEvidence['secondary_diagnostic_error_types'])) { $null = $secondaryTypes.Add([string]$item) }
    }
    if (-not [string]::IsNullOrWhiteSpace($diagPath) -and [IO.File]::Exists($diagPath)) {
        $diagIdentity = Get-DirectSpoolIdentitySafe -Path $diagPath
        if ($true -eq $diagIdentity.unavailable) {
            $FailureEvidence.diagnostic = $null
            $FailureEvidence.diagnostic_spool = 'unavailable'
            if (-not [string]::IsNullOrWhiteSpace([string]$diagIdentity.error_type)) { $null = $secondaryTypes.Add([string]$diagIdentity.error_type) }
        } else {
            $FailureEvidence.diagnostic = $diagIdentity.identity
        }
        $diagDir = [IO.Path]::GetDirectoryName($diagPath)
        $stdoutSpool = Get-DirectSpoolIdentitySafe -Path (Join-Path $diagDir 'stdout.bin')
        $stderrSpool = Get-DirectSpoolIdentitySafe -Path (Join-Path $diagDir 'stderr.bin')
        if ($true -eq $stdoutSpool.unavailable) {
            $FailureEvidence.stdout = $null
            $FailureEvidence.stdout_evidence = 'unavailable'
            if (-not [string]::IsNullOrWhiteSpace([string]$stdoutSpool.error_type)) { $null = $secondaryTypes.Add([string]$stdoutSpool.error_type) }
        } else {
            $FailureEvidence.stdout = $stdoutSpool.identity
            $stdoutBytes = [int64]$stdoutSpool.identity.bytes
            $FailureEvidence.stdout_evidence = 'available'
        }
        if ($true -eq $stderrSpool.unavailable) {
            $FailureEvidence.stderr_spool = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$stderrSpool.error_type)) { $null = $secondaryTypes.Add([string]$stderrSpool.error_type) }
        } else {
            $FailureEvidence.stderr_spool = $stderrSpool.identity
            $stderrBytes = [int64]$stderrSpool.identity.bytes
        }
    }
    $observation = $null
    try {
        $observation = Get-DirectCursorFailureObservation `
            -Run $Run `
            -DiagnosticPath $diagPath `
            -Workspace $Workspace `
            -BeforeSnapshot $BeforeSnapshot `
            -AllowedWriteRelative $AllowedWriteRelative `
            -SnapshotCompleted $SnapshotCompleted `
            -ExistingChanges $ExistingChanges
    } catch {
        $null = $secondaryTypes.Add($_.Exception.GetType().FullName)
        $observation = [ordered]@{
            observed_session = Get-DirectCursorObservedIdentity -Stdout '' -Workspace $Workspace
            changed_files_availability = 'unknown'
            changed_files = @()
            secondary_snapshot_errors = @($_.Exception.GetType().FullName)
            secondary_error_types = @($_.Exception.GetType().FullName)
            stdout_evidence = 'unavailable'
        }
    }
    foreach ($item in @($observation.secondary_error_types)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item)) { $null = $secondaryTypes.Add([string]$item) }
    }
    $observedSession = $observation.observed_session
    $changedFilesAvailability = [string]$observation.changed_files_availability
    $changes = $ExistingChanges
    if ($changedFilesAvailability -ceq 'available') {
        $changes = @($observation.changed_files)
    }
    if ($secondaryTypes.Count -gt 0) {
        $FailureEvidence.secondary_error_types = @($secondaryTypes | Select-Object -Unique)
        $FailureEvidence.primary_failure_retained = $true
    }
    $FailureEvidence.observed_session = $observedSession
    $FailureEvidence.changed_files_availability = $changedFilesAvailability
    $FailureEvidence.process_failure_class = $processFailureClass
    if ([string]$observation.stdout_evidence -ceq 'unavailable') {
        $FailureEvidence.stdout_evidence = 'unavailable'
    }
    $observedFromException = ''
    if ($null -ne $ex.Data -and $null -ne $ex.Data['telephone_direct_cursor_observed_session_id']) {
        $observedFromException = [string]$ex.Data['telephone_direct_cursor_observed_session_id']
    }
    if ([string]::IsNullOrWhiteSpace([string]$observedSession.session_id) -and -not [string]::IsNullOrWhiteSpace($observedFromException)) {
        $observedSession.session_id = $observedFromException
        $observedSession.status = 'partial'
        $observedSession.source = 'process_exception_data'
        $observedSession.accepted = $false
    }
    $violatingPaths = @()
    if ($null -ne $ex.Data -and $null -ne $ex.Data['telephone_direct_cursor_violating_paths']) {
        $violatingPaths = @($ex.Data['telephone_direct_cursor_violating_paths'])
    } elseif ($FailureEvidence.Contains('violating_paths')) {
        $violatingPaths = @($FailureEvidence['violating_paths'])
    }
    return [ordered]@{
        success = $false
        dispatch_id = $DispatchId
        prompt_sha256 = $PromptSha256
        prompt = $promptPublicIdentity
        failure_kind = [string]$classification.failure_kind
        failure_code = [string]$classification.failure_code
        failure_stage = [string]$classification.failure_stage
        public_error_code = [string]$classification.public_error_code
        process_failure_class = $processFailureClass
        exception_type = $ex.GetType().FullName
        error = Get-DirectPublicError -ErrorCode ([string]$classification.public_error_code)
        workspace = $Workspace
        mode = $Mode
        model_id = $Model
        allowed_write_paths = $AllowedWriteRelative
        resume_session_id = $ResumeSessionId
        requested_native_session_id = [string]$ResumeSessionId
        returned_native_session_id = ''
        session_id = ''
        observed_session = $observedSession
        native_exit_code = $nativeExit
        stdout_bytes = $stdoutBytes
        stderr_bytes = $stderrBytes
        violating_paths = @($violatingPaths)
        policy_violation = ($violatingPaths.Count -gt 0)
        fast_disabled = $true
        changed_files_availability = $changedFilesAvailability
        changed_files = $(if ($changedFilesAvailability -ceq 'available') { @($changes) } else { $null })
        volatile_snapshot_exclusions = @($VolatileSnapshotExclusions)
        evidence = $FailureEvidence
    }
}

function Get-DirectCursorPartialAdmissionProtocol {
    [CmdletBinding()]
    param()
    return 'telephone-line-direct-cursor-partial-admission-v1'
}

function Get-DirectCursorPartialAdmissionPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$NativeSessionId
    )

    if ($NativeSessionId -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Adapter native session id is malformed.' }
    $root = Get-DirectCanonicalDirectory -Path $StateRoot
    $leaf = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($NativeSessionId))).ToLowerInvariant()
    $dir = Join-Path $root ('partial-admissions\' + $leaf)
    $full = [IO.Path]::GetFullPath($dir).TrimEnd('\')
    if (-not (Test-DirectPathWithin -Root (Join-Path $root 'partial-admissions') -Path $full -AllowEqual)) {
        throw 'Adapter native session id is malformed.'
    }
    return Join-Path $full 'admission.json'
}

function Read-DirectCursorPartialAdmission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$NativeSessionId
    )

    $path = Get-DirectCursorPartialAdmissionPath -StateRoot $StateRoot -NativeSessionId $NativeSessionId
    if (-not [IO.File]::Exists($path)) { return $null }
    $read = Read-DirectJson -Path $path
    $value = $read.value
    if ([string]$value.protocol_version -cne (Get-DirectCursorPartialAdmissionProtocol)) {
        throw 'Direct Cursor partial admission protocol is unsupported.'
    }
    if ([string]$value.native_session_id -cne $NativeSessionId) {
        throw 'Adapter native session id does not match the frozen session.'
    }
    return $value
}

function Test-DirectCursorJsonlTranscript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId
    )

    $identity = Get-DirectFileIdentity -Path $Path
    $bytes = [IO.File]::ReadAllBytes([string]$identity.path)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $records = 0
    $lastRole = ''
    $lastHasToolUse = $false
    foreach ($line in @($text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { throw 'Native transcript is corrupt JSONL.' }
        $records += 1
        $lastRole = [string](Get-DirectNoteValue -Object $obj -Name 'role')
        $message = Get-DirectNoteValue -Object $obj -Name 'message'
        $content = Get-DirectNoteValue -Object $message -Name 'content'
        $lastHasToolUse = $false
        foreach ($block in @($content)) {
            $blockType = [string](Get-DirectNoteValue -Object $block -Name 'type')
            if ($blockType -ceq 'tool_use') { $lastHasToolUse = $true }
        }
    }
    if ($records -lt 1) { throw 'Native transcript has no records.' }
    $name = [IO.Path]::GetFileNameWithoutExtension([string]$identity.path)
    if ($name -cne $ExpectedSessionId) { throw 'Native transcript session identity does not match.' }
    $hasFinal = ($lastRole -ceq 'assistant' -and -not $lastHasToolUse)
    return [ordered]@{
        identity = $identity
        record_count = [int]$records
        last_role = $lastRole
        last_has_tool_use = [bool]$lastHasToolUse
        final_response_present = [bool]$hasFinal
        normal_terminal_record_present = $false
    }
}

function Register-DirectCursorPartialSessionAdmission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$FailedRequestPath,
        [Parameter(Mandatory = $true)][string]$FailedReceiptPath,
        [Parameter(Mandatory = $true)][string]$NativeTranscriptPath,
        [Parameter(Mandatory = $true)][string]$NativeMetaPath,
        [Parameter(Mandatory = $true)][string]$ObservedSessionId,
        [Parameter(Mandatory = $true)][string]$OldBindingPath,
        [Parameter(Mandatory = $true)][string]$FailedOwnerPath,
        [Parameter(Mandatory = $true)][string]$ActualExecutionPath,
        [Parameter(Mandatory = $true)][string]$ExpectedEvidencePath,
        [int]$CursorNodePid = 0,
        [int64]$CursorNodeStartTicks = 0,
        [string]$FixtureLabel = ''
    )

    $resolvedState = Get-DirectCanonicalDirectory -Path $StateRoot
    if (-not [string]::IsNullOrWhiteSpace($FixtureLabel)) {
        if ($FixtureLabel -cnotmatch '^FAKE-SOURCE') { throw 'Test fixture label is invalid.' }
        if ($resolvedState -match '(?i)small-world-sandbox-telephone-resume\\state\\direct-cursor') {
            throw 'Fake source fixtures must never be admitted into real SWS state.'
        }
    }
    if ($ObservedSessionId -cnotmatch '^[A-Za-z0-9._:-]+$') { throw 'Adapter native session id is malformed.' }
    if ([string]::IsNullOrWhiteSpace($ExpectedEvidencePath) -or -not [IO.File]::Exists($ExpectedEvidencePath)) {
        throw 'Expected immutable evidence identities are required.'
    }
    if ([string]::IsNullOrWhiteSpace($ActualExecutionPath) -or -not [IO.File]::Exists($ActualExecutionPath)) {
        throw 'Actual execution observation is required.'
    }
    if ([string]::IsNullOrWhiteSpace($FailedOwnerPath) -or -not [IO.File]::Exists($FailedOwnerPath)) {
        throw 'Failed job owner identity is required.'
    }
    if ([string]::IsNullOrWhiteSpace($OldBindingPath) -or -not [IO.File]::Exists($OldBindingPath)) {
        throw 'Old binding identity is required.'
    }

    $expectedDoc = (Read-DirectJson -Path $ExpectedEvidencePath).value
    $expected = $expectedDoc
    $nested = Get-DirectNoteValue -Object $expectedDoc -Name 'native_original_inputs'
    if ($null -ne $nested) { $expected = $nested }
    foreach ($key in @('request', 'receipt', 'transcript', 'meta', 'prompt', 'actual_execution', 'old_binding')) {
        if ($null -eq (Get-DirectNoteValue -Object $expected -Name $key)) {
            throw "Expected $key identity is missing."
        }
    }

    $requestRead = Read-DirectJson -Path $FailedRequestPath
    $receiptRead = Read-DirectJson -Path $FailedReceiptPath
    $request = $requestRead.value
    $receipt = $receiptRead.value
    Assert-DirectContentIdentity -Expected (Get-DirectNoteValue -Object $expected -Name 'request') -Actual $requestRead.identity -Label 'Original failed request'
    Assert-DirectContentIdentity -Expected (Get-DirectNoteValue -Object $expected -Name 'receipt') -Actual $receiptRead.identity -Label 'Original failed receipt'
    if ([string]$request.protocol_version -cne 'telephone-line-direct-cursor-request-v1') {
        throw 'Original failed request protocol is unsupported.'
    }
    if ([string]$receipt.protocol_version -cne 'telephone-line-direct-cursor-receipt-v1') {
        throw 'Original failed receipt protocol is unsupported.'
    }
    if ([string]$request.job_id -cne [string]$receipt.job_id) { throw 'Original failed request and receipt job ids differ.' }
    Assert-DirectIdentity -Expected $requestRead.identity -Actual $receipt.request -Label 'Original failed request'
    if ([bool]$receipt.transport_complete -eq $true -or [bool]$receipt.cursor_success -eq $true) {
        throw 'Original failure is not an immutable failed start.'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$receipt.native_session_id)) {
        throw 'Original receipt already has an accepted native session id.'
    }

    $workspace = [IO.Path]::GetFullPath([string]$request.workspace).TrimEnd('\')
    $null = Assert-DirectCursorWorkspaceDispatchable -WorkspacePath $workspace
    $mode = [string]$request.mode
    $model = [string]$request.model
    $allowed = [string[]]@($request.allowed_write_paths | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $prompt = $request.prompt
    Assert-DirectContentIdentity -Expected (Get-DirectNoteValue -Object $expected -Name 'prompt') -Actual $prompt -Label 'Original prompt'
    $promptPath = [string](Get-DirectNoteValue -Object $prompt -Name 'path')
    if (-not [string]::IsNullOrWhiteSpace($promptPath) -and [IO.File]::Exists($promptPath)) {
        Assert-DirectContentIdentity -Expected $prompt -Actual (Get-DirectFileIdentity -Path $promptPath) -Label 'Original prompt file'
    }

    $executionRead = Read-DirectJson -Path $ActualExecutionPath
    $execution = $executionRead.value
    Assert-DirectContentIdentity -Expected (Get-DirectNoteValue -Object $expected -Name 'actual_execution') -Actual $executionRead.identity -Label 'Actual execution observation'
    $executionJob = [string](Get-DirectNoteValue -Object $execution -Name 'job')
    if ([string]::IsNullOrWhiteSpace($executionJob)) { $executionJob = [string](Get-DirectNoteValue -Object $execution -Name 'job_id') }
    if ([string]::IsNullOrWhiteSpace($executionJob) -or $executionJob -cne [string]$request.job_id) {
        throw 'Actual execution job does not match the original failed start.'
    }
    $modelFromProcess = [string](Get-DirectNoteValue -Object $execution -Name 'model')
    if ([string]::IsNullOrWhiteSpace($modelFromProcess) -or $modelFromProcess -cne $model) {
        throw 'Actual execution model does not match the original request.'
    }
    $execNodePid = Get-DirectNoteValue -Object $execution -Name 'cursor_node_pid'
    if ($null -ne $execNodePid -and [string]$execNodePid -ne '') {
        if ([int]$CursorNodePid -ne [int]$execNodePid -or [int64]$CursorNodeStartTicks -le 0) {
            throw 'Cursor node process identity is required and must match the actual execution observation.'
        }
    }

    $metaRead = Read-DirectJson -Path $NativeMetaPath
    $meta = $metaRead.value
    Assert-DirectContentIdentity -Expected (Get-DirectNoteValue -Object $expected -Name 'meta') -Actual $metaRead.identity -Label 'Native metadata'
    $metaCwd = [string](Get-DirectNoteValue -Object $meta -Name 'cwd')
    if ([string]::IsNullOrWhiteSpace($metaCwd)) { throw 'Native metadata cwd is missing.' }
    if (-not [IO.Path]::GetFullPath($metaCwd).TrimEnd('\').Equals($workspace, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Native metadata cwd does not match the original workspace.'
    }
    $hasConversation = Get-DirectNoteValue -Object $meta -Name 'hasConversation'
    if ($hasConversation -ne $true) { throw 'Native metadata does not record a conversation.' }
    if ($null -ne (Get-DirectNoteValue -Object $meta -Name 'model') -and -not [string]::IsNullOrWhiteSpace([string](Get-DirectNoteValue -Object $meta -Name 'model'))) {
        throw 'Native metadata unexpectedly contains a model field; do not invent native model metadata.'
    }

    $transcript = Test-DirectCursorJsonlTranscript -Path $NativeTranscriptPath -ExpectedSessionId $ObservedSessionId
    Assert-DirectContentIdentity -Expected (Get-DirectNoteValue -Object $expected -Name 'transcript') -Actual $transcript.identity -Label 'Native transcript'
    $metaName = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([string]$metaRead.identity.path))
    if ($metaName -cne $ObservedSessionId) { throw 'Native metadata session identity does not match.' }

    $oldRead = Read-DirectJson -Path $OldBindingPath
    $oldBinding = $oldRead.value
    Assert-DirectContentIdentity -Expected (Get-DirectNoteValue -Object $expected -Name 'old_binding') -Actual $oldRead.identity -Label 'Old binding'
    if ([string]$oldBinding.native_session_id -ceq $ObservedSessionId) {
        throw 'Old binding already uses the observed native session.'
    }
    if (-not [IO.Path]::GetFullPath([string]$oldBinding.workspace).TrimEnd('\').Equals($workspace, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Old binding workspace does not match the original request.'
    }
    if ([string]$oldBinding.mode -cne $mode) { throw 'Old binding mode does not match the original request.' }
    $oldScope = Get-DirectCursorSortedWriteScope -Paths $oldBinding.allowed_write_paths
    $requestScope = Get-DirectCursorSortedWriteScope -Paths $allowed
    if ($oldScope -cne $requestScope) { throw 'Old binding write scope does not match the original request.' }

    $ownerRead = Read-DirectJson -Path $FailedOwnerPath
    $failedOwner = $ownerRead.value
    $null = Confirm-DirectCursorOwnerDead -Owner $failedOwner -Source 'failed_job_owner'
    if ([int]$CursorNodePid -gt 0 -and [int64]$CursorNodeStartTicks -gt 0) {
        $null = Confirm-DirectCursorOwnerDead -Owner ([ordered]@{ pid = [int]$CursorNodePid; start_time_utc_ticks = [int64]$CursorNodeStartTicks }) -Source 'cursor_node_observation'
    }
    $createdMs = Get-DirectNoteValue -Object $meta -Name 'createdAtMs'
    $updatedMs = Get-DirectNoteValue -Object $meta -Name 'updatedAtMs'
    if ($null -eq $createdMs -or $null -eq $updatedMs) { throw 'Native metadata times are missing.' }
    $createdAt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$createdMs)
    $updatedAt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$updatedMs)
    if ($updatedAt -lt $createdAt) { throw 'Native metadata times are inconsistent.' }
    $ownerStart = $null
    $ownerTicks = Get-DirectNoteValue -Object $failedOwner -Name 'start_time_utc_ticks'
    if ($null -ne $ownerTicks -and [string]$ownerTicks -ne '') {
        $ownerStart = [DateTimeOffset]::new([int64]$ownerTicks, [TimeSpan]::Zero)
    }
    $ownerStartedText = [string](Get-DirectNoteValue -Object $failedOwner -Name 'started_at_utc')
    if ([string]::IsNullOrWhiteSpace($ownerStartedText) -eq $false) {
        $ownerStart = [DateTimeOffset]$ownerStartedText
    }
    $receiptEndText = [string](Get-DirectNoteValue -Object $receipt -Name 'completed_at_utc')
    if ([string]::IsNullOrWhiteSpace($receiptEndText)) { throw 'Original receipt completion time is missing.' }
    $receiptEnd = [DateTimeOffset]$receiptEndText
    if ($null -eq $ownerStart) { throw 'Failed job owner start time is missing.' }
    if ($createdAt -lt $ownerStart.AddMinutes(-1) -or $createdAt -gt $receiptEnd.AddMinutes(1) -or $updatedAt -gt $receiptEnd.AddMinutes(1)) {
        throw 'Native metadata time is outside the failed start window.'
    }

    $sessionPaths = @{
        root = Join-Path $resolvedState ('sessions\' + $ObservedSessionId)
        binding = Join-Path $resolvedState ('sessions\' + $ObservedSessionId + '\binding.json')
    }

    $workspaceMutex = [Threading.Mutex]::new($false, (Get-DirectCursorWorkspaceMutexName -Workspace $workspace))
    $registryMutex = [Threading.Mutex]::new($false, 'Global\TelephoneLineCursorSessionRegistry')
    $haveWorkspace = $false
    $haveRegistry = $false
    $admissionPath = Get-DirectCursorPartialAdmissionPath -StateRoot $resolvedState -NativeSessionId $ObservedSessionId
    $identity = $null
    try {
        try { $haveWorkspace = $workspaceMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $haveWorkspace = $true }
        if (-not $haveWorkspace) { throw 'Another Cursor dispatch already owns this workspace.' }
        try { $haveRegistry = $registryMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $haveRegistry = $true }
        if (-not $haveRegistry) { throw 'Cursor session registry is busy.' }

        Assert-DirectContentIdentity -Expected (Get-DirectNoteValue -Object $expected -Name 'request') -Actual (Get-DirectFileIdentity -Path $FailedRequestPath) -Label 'Original failed request'
        Assert-DirectContentIdentity -Expected (Get-DirectNoteValue -Object $expected -Name 'receipt') -Actual (Get-DirectFileIdentity -Path $FailedReceiptPath) -Label 'Original failed receipt'
        if ([IO.File]::Exists($sessionPaths.binding)) {
            throw 'An accepted binding already exists for this native session.'
        }

        $deadOwners = [Collections.Generic.List[object]]::new()
        $null = $deadOwners.Add((Confirm-DirectCursorOwnerDead -Owner $failedOwner -Source 'failed_job_owner'))
        if ([int]$CursorNodePid -gt 0 -and [int64]$CursorNodeStartTicks -gt 0) {
            $null = $deadOwners.Add((Confirm-DirectCursorOwnerDead -Owner ([ordered]@{ pid = [int]$CursorNodePid; start_time_utc_ticks = [int64]$CursorNodeStartTicks }) -Source 'cursor_node_observation'))
        }
        $extraOwners = Get-DirectNoteValue -Object $expectedDoc -Name 'dead_owners'
        if ($null -eq $extraOwners) { $extraOwners = Get-DirectNoteValue -Object $expectedDoc -Name 'activation_recheck_owners' }
        foreach ($extra in @($extraOwners)) {
            if ($null -eq $extra) { continue }
            $extraOwnerPid = [int](Get-DirectNoteValue -Object $extra -Name 'pid')
            $ticks = [int64](Get-DirectNoteValue -Object $extra -Name 'start_time_utc_ticks')
            if ($extraOwnerPid -le 0 -or $ticks -le 0) { throw 'Expected dead owner identity is incomplete.' }
            $null = $deadOwners.Add((Confirm-DirectCursorOwnerDead -Owner ([ordered]@{ pid = $extraOwnerPid; start_time_utc_ticks = $ticks }) -Source ([string](Get-DirectNoteValue -Object $extra -Name 'role'))))
        }

        $existingAdmission = $null
        $admissionExists = [IO.File]::Exists($admissionPath)
        if ($admissionExists) {
            try { $existingAdmission = Read-DirectCursorPartialAdmission -StateRoot $resolvedState -NativeSessionId $ObservedSessionId } catch {
                throw 'Partial admission is inconsistent and is not usable.'
            }
        }
        $registryRecord = Get-DirectCursorPartialRegistryRecord -StateRoot $resolvedState -NativeSessionId $ObservedSessionId
        if ($admissionExists -and $null -eq $registryRecord) {
            throw 'Partial admission is inconsistent and is not usable.'
        }
        if (-not $admissionExists -and $null -ne $registryRecord -and [string]$registryRecord.admission_kind -ceq 'partial_observed') {
            throw 'Partial admission is inconsistent and is not usable.'
        }
        if ($admissionExists -and $null -ne $registryRecord) {
            $usable = Test-DirectCursorPartialAdmissionUsable -StateRoot $resolvedState -NativeSessionId $ObservedSessionId
            $existingRequestSha = [string](Get-DirectNoteValue -Object (Get-DirectNoteValue -Object $usable -Name 'original_failure') -Name 'request_sha256')
            if ([string]$existingRequestSha -cne [string]$requestRead.identity.sha256) {
                throw 'A conflicting partial admission already exists for this session.'
            }
            if ([int]$usable.continuation_remaining -ne 1 -or [string]$usable.status -cne 'provisional') {
                throw 'Partial admission continuation has already been consumed.'
            }
            return [ordered]@{
                protocol_version = Get-DirectCursorPartialAdmissionProtocol
                status = 'already_registered'
                admission = $usable
                identity = Get-DirectFileIdentity -Path $admissionPath
                accepted_binding_written = $false
                receipt_fabricated = $false
                continuation_remaining = [int]$usable.continuation_remaining
                workspace_mutex_held_through_mutation = $true
                registry_mutex_held_through_mutation = $true
            }
        }

        $admission = [ordered]@{
            protocol_version = Get-DirectCursorPartialAdmissionProtocol
            status = 'provisional'
            acceptance = 'pending'
            continuation_remaining = 1
            continuation_job_id = ''
            native_session_id = $ObservedSessionId
            workspace = $workspace
            mode = $mode
            model_id = $model
            allowed_write_paths = @($allowed)
            original_failure = [ordered]@{
                job_id = [string]$request.job_id
                request = $requestRead.identity
                receipt = $receiptRead.identity
                request_sha256 = [string]$requestRead.identity.sha256
                receipt_sha256 = [string]$receiptRead.identity.sha256
                prompt = $prompt
                failure_code = [string](Get-DirectNoteValue -Object (Get-DirectNoteValue -Object $receipt -Name 'cursor_result') -Name 'failure_code')
                failure_stage = [string](Get-DirectNoteValue -Object (Get-DirectNoteValue -Object $receipt -Name 'cursor_result') -Name 'failure_stage')
            }
            native_evidence = [ordered]@{
                transcript = $transcript.identity
                transcript_records = [int]$transcript.record_count
                transcript_last_role = [string]$transcript.last_role
                transcript_last_has_tool_use = [bool]$transcript.last_has_tool_use
                transcript_final_response_present = [bool]$transcript.final_response_present
                meta = $metaRead.identity
                meta_cwd = $metaCwd
                meta_created_at_ms = $createdMs
                meta_updated_at_ms = $updatedMs
                has_conversation = [bool]$hasConversation
            }
            fact_sources = [ordered]@{
                session_id = @('native_transcript_path', 'native_meta_path')
                model_requested = 'original_request'
                model_process_command = 'actual_execution_observation'
                model_native_metadata = 'unavailable'
                workspace = @('original_request', 'native_meta.cwd')
                prompt = 'original_request'
                scope = @('original_request', 'old_binding')
                confirmed_on_resume_only = @('native_stream_model_display', 'terminal_success', 'write_scope_of_resume')
            }
            old_binding_native_session_id = [string]$oldBinding.native_session_id
            owners_confirmed_dead = @($deadOwners)
            expected_evidence = (Get-DirectFileIdentity -Path $ExpectedEvidencePath)
            fixture_label = [string]$FixtureLabel
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }

        try {
            $identity = Write-DirectJsonCreateNew -Path $admissionPath -Value $admission
            $registryPath = Get-DirectCursorSessionRegistryPath -StateRoot $resolvedState
            $registry = if ([IO.File]::Exists($registryPath)) {
                Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
            } else {
                [pscustomobject]@{ schema_version = 1; sessions = @() }
            }
            if ($registry.schema_version -ne 1) { throw 'Cursor session registry schema is unsupported.' }
            if (@($registry.sessions | Where-Object { $_.session_id -eq $ObservedSessionId }).Count -ne 0) {
                throw 'Cursor returned a session ID already owned by the registry.'
            }
            $now = [DateTimeOffset]::UtcNow.ToString('o')
            $newRecord = [pscustomobject]@{
                session_id = $ObservedSessionId
                model_id = $model
                workspace = $workspace
                mode = $mode
                allowed_write_paths = @($allowed)
                last_dispatch_id = ''
                last_normalized_request_sha256 = ''
                created_at = $now
                last_used_at = $now
                acceptance = 'pending'
                admission_kind = 'partial_observed'
                continuation_remaining = 1
            }
            $registry.sessions = @($registry.sessions) + $newRecord
            $parent = [IO.Path]::GetDirectoryName($registryPath)
            if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
            $temporaryPath = $registryPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
            $json = ($registry | ConvertTo-Json -Depth 8)
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
            $stream = [IO.FileStream]::new($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            Move-Item -LiteralPath $temporaryPath -Destination $registryPath -Force
        } catch {
            if ([IO.File]::Exists($admissionPath)) {
                try { [IO.File]::Delete($admissionPath) } catch { }
            }
            throw
        }

        return [ordered]@{
            protocol_version = Get-DirectCursorPartialAdmissionProtocol
            status = 'provisional'
            acceptance = 'pending'
            native_session_id = $ObservedSessionId
            continuation_remaining = 1
            original_failure_job_id = [string]$request.job_id
            admission = $identity
            accepted_binding_written = $false
            receipt_fabricated = $false
            fixture_label = [string]$FixtureLabel
            workspace_mutex_held_through_mutation = $true
            registry_mutex_held_through_mutation = $true
        }
    } finally {
        if ($haveRegistry) { try { $registryMutex.ReleaseMutex() } catch { } }
        $registryMutex.Dispose()
        if ($haveWorkspace) { try { $workspaceMutex.ReleaseMutex() } catch { } }
        $workspaceMutex.Dispose()
    }
}

. (Join-Path $PSScriptRoot 'DirectCursor.Migration.ps1')

function Use-DirectCursorPartialContinuation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$NativeSessionId,
        [Parameter(Mandatory = $true)][string]$JobId
    )

    $path = Get-DirectCursorPartialAdmissionPath -StateRoot $StateRoot -NativeSessionId $NativeSessionId
    $workspaceMutex = $null
    $registryMutex = [Threading.Mutex]::new($false, 'Global\TelephoneLineCursorSessionRegistry')
    $admissionMutex = [Threading.Mutex]::new($false, 'Global\TelephoneLineDirectCursorPartialAdmission')
    $haveRegistry = $false
    $haveAdmission = $false
    $haveWorkspace = $false
    if (-not $admissionMutex.WaitOne(30000)) { throw 'Direct Cursor partial admission is busy.' }
    $haveAdmission = $true
    try {
        $usable = Test-DirectCursorPartialAdmissionUsable -StateRoot $StateRoot -NativeSessionId $NativeSessionId
        if ($null -eq $usable) { throw 'Partial admission is inconsistent and is not usable.' }
        $workspaceMutex = [Threading.Mutex]::new($false, (Get-DirectCursorWorkspaceMutexName -Workspace ([string]$usable.workspace)))
        try { $haveWorkspace = $workspaceMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $haveWorkspace = $true }
        if (-not $haveWorkspace) { throw 'Another Cursor dispatch already owns this workspace.' }
        try { $haveRegistry = $registryMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $haveRegistry = $true }
        if (-not $haveRegistry) { throw 'Cursor session registry is busy.' }
        $usable = Test-DirectCursorPartialAdmissionUsable -StateRoot $StateRoot -NativeSessionId $NativeSessionId
        if ([string]$usable.status -cne 'provisional' -or [string]$usable.acceptance -cne 'pending') {
            throw 'Partial admission is not provisional.'
        }
        if ([int]$usable.continuation_remaining -ne 1) {
            throw 'Partial admission continuation has already been consumed.'
        }
        $usable.continuation_remaining = 0
        $usable.continuation_job_id = $JobId
        $usable.consumed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        $json = (($usable | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n")
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        [IO.File]::WriteAllBytes($path, $bytes)

        $registryPath = Get-DirectCursorSessionRegistryPath -StateRoot $StateRoot
        $registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
        $records = @($registry.sessions | Where-Object { $_.session_id -eq $NativeSessionId })
        if ($records.Count -ne 1) { throw 'Partial admission is inconsistent and is not usable.' }
        $records[0].continuation_remaining = 0
        $records[0].last_dispatch_id = $JobId
        $json2 = $registry | ConvertTo-Json -Depth 8
        $bytes2 = [Text.UTF8Encoding]::new($false).GetBytes($json2)
        [IO.File]::WriteAllBytes($registryPath, $bytes2)
        return $usable
    } finally {
        if ($haveRegistry) { try { $registryMutex.ReleaseMutex() } catch { } }
        $registryMutex.Dispose()
        if ($haveWorkspace -and $null -ne $workspaceMutex) { try { $workspaceMutex.ReleaseMutex() } catch { } }
        if ($null -ne $workspaceMutex) { $workspaceMutex.Dispose() }
        if ($haveAdmission) { try { $admissionMutex.ReleaseMutex() } catch { } }
        $admissionMutex.Dispose()
    }
}
