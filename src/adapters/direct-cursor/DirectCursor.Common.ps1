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
    }
}

function Get-DirectPublicError {
    [CmdletBinding()]
    param([AllowNull()][string]$Message, [string]$ErrorCode)

    $catalog = Get-DirectPublicErrorCatalog
    $code = [string]$ErrorCode
    $text = [string]$Message
    if ([string]::IsNullOrWhiteSpace($code)) {
        if ($text -cmatch '(?i)selected model.*capacity|model is at capacity|at capacity') { $code = 'DIRECT_CURSOR_MODEL_CAPACITY' }
        elseif ($text -cmatch '(?i)rate.?limit|too many requests|\b429\b') { $code = 'DIRECT_CURSOR_RATE_LIMITED' }
        elseif ($text -cmatch '(?i)workspace.*owned by another dispatch|workspace.*busy') { $code = 'DIRECT_CURSOR_WORKSPACE_BUSY' }
        elseif ($text -cmatch '(?i)native session') { $code = 'ADAPTER_NATIVE_SESSION_MISMATCH' }
        elseif ($text -cmatch '(?i)already exists|duplicate') { $code = 'ADAPTER_DUPLICATE_NO_RERUN' }
        elseif ($text -cmatch '(?i)Fast') { $code = 'DIRECT_CURSOR_FAST_DISABLED' }
        elseif ($text -cmatch '(?i)write path|write scope|ReadOnly|Verify') { $code = 'DIRECT_CURSOR_WRITE_SCOPE' }
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
        [string]$Stage = 'unknown'
    )

    $text = [string]$Message
    $code = 'adapter_transport_failure'
    $publicCode = 'ADAPTER_TRANSPORT_FAILED'
    if ($text -cmatch '(?i)selected model.*capacity|model is at capacity|at capacity') {
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
    } elseif ($text -cmatch '(?i)Cursor CLI exited|Cursor CLI wrote to stderr|Cursor process-tree|Cursor CLI process did not start') {
        $code = 'cursor_cli_failure'
        $publicCode = 'DIRECT_CURSOR_CLI_FAILURE'
    }

    return [ordered]@{
        failure_kind = 'transport'
        failure_code = $code
        failure_stage = $(if ([string]::IsNullOrWhiteSpace($Stage)) { 'unknown' } else { $Stage })
        public_error_code = $publicCode
    }
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

    $initEvents = @($events | Where-Object { $_.type -eq 'system' -and $_.subtype -eq 'init' })
    $resultEvents = @($events | Where-Object { $_.type -eq 'result' })
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

    $cursorFailure = {
        param([string]$Message)
        return [ordered]@{
            outcome = 'cursor_failure'
            register_session = $false
            result = $null
            error_message = $Message
            changed_files = @($normalizedChanges)
            evidence = $evidence
        }
    }

    if ($true -ne $validation.valid) {
        return (& $cursorFailure ([string]$validation.error_message))
    }

    $violations = @(Get-DirectCursorPolicyViolations -Mode $Mode -Workspace $Workspace -AllowedWriteRelative $allowedRelative -Changes $normalizedChanges)
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
    if ([int]$Run.ExitCode -ne 0) {
        return (& $cursorFailure ('Cursor CLI exited {0}: {1}' -f [int]$Run.ExitCode, (Limit-DirectText -Text ([string]$Run.Stderr) -Limit $MaxErrorChars)))
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Run.Stderr)) {
        return (& $cursorFailure ('Cursor CLI wrote to stderr: {0}' -f (Limit-DirectText -Text ([string]$Run.Stderr) -Limit $MaxErrorChars)))
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
