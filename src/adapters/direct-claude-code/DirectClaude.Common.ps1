# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }

function Get-DirectClaudeFileIdentity {
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

function Assert-DirectClaudeIdentity {
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

function Read-DirectClaudeJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $identity = Get-DirectClaudeFileIdentity -Path $Path
    $bytes = [IO.File]::ReadAllBytes([string]$identity.path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'JSON must be UTF-8 without BOM.'
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    return [ordered]@{
        identity = $identity
        value = $text | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    }
}

function ConvertFrom-DirectClaudeCliJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][ValidateRange(1, [long]::MaxValue)][long]$MaxBytes
    )

    if ($Bytes.Length -eq 0) { throw "$Label is empty." }
    if ($Bytes.Length -gt $MaxBytes) { throw "$Label exceeded the bounded size." }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        throw "$Label must not contain a UTF-8 BOM."
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes).TrimStart([char]0xFEFF).Trim()
    $value = $text | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    if ($value -isnot [Collections.IDictionary]) { throw "$Label is not a JSON object." }
    return $value
}

function Get-DirectClaudeNativeSessionIdFromResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Value,
        [string]$ExpectedSessionId
    )

    if (-not $Value.Contains('session_id') -or [string]::IsNullOrWhiteSpace([string]$Value.session_id)) {
        throw 'Claude Code JSON result has no session_id.'
    }
    $sessionId = [string]$Value.session_id
    Assert-DirectClaudeNativeSessionIdFormat -SessionId $sessionId -Label 'Claude Code JSON'
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSessionId) -and $ExpectedSessionId -cne $sessionId) {
        throw 'Adapter native session id does not match the frozen session.'
    }
    return $sessionId
}

function Assert-DirectClaudeNativeSessionIdFormat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($SessionId -cnotmatch '^[A-Za-z0-9._:-]+$') { throw "$Label native session id is malformed." }
    if ($SessionId -ceq '.' -or $SessionId -ceq '..' -or $SessionId.IndexOfAny([char[]]@('\', '/')) -ge 0) {
        throw "$Label native session id is malformed."
    }
}

function Assert-DirectClaudeKeys {
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

function Write-DirectClaudeBytesCreateNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $stream = [IO.FileStream]::new($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    return Get-DirectClaudeFileIdentity -Path $full
}

function Write-DirectClaudeJsonCreateNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = ($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n"
    return Write-DirectClaudeBytesCreateNew -Path $Path -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Test-DirectClaudeOwnerAlive {
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

function Get-DirectClaudeCanonicalDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
}

function Test-DirectClaudePathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowEqual
    )

    $canonicalRoot = Get-DirectClaudeCanonicalDirectory -Path $Root
    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    if ($AllowEqual -and $canonicalPath.Equals($canonicalRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $canonicalPath.StartsWith($canonicalRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DirectClaudeExistingComponentChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$RequireExisting
    )

    $rootFull = Get-DirectClaudeCanonicalDirectory -Path $Root
    $probe = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    if (-not (Test-DirectClaudePathWithin -Root $rootFull -Path $probe -AllowEqual)) {
        throw "$Label path escapes its required root."
    }

    $rootItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw "$Label trusted root must be a directory." }
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label path is a reparse point." }

    $relative = [IO.Path]::GetRelativePath($rootFull, $probe)
    if ($relative.StartsWith('..', [StringComparison]::OrdinalIgnoreCase)) { throw "$Label path escapes its required root." }
    $segments = [Collections.Generic.List[string]]::new()
    foreach ($part in @($relative.Replace('/', '\').Split([char]'\'))) {
        if ([string]::IsNullOrEmpty($part) -or $part -ceq '.') { continue }
        if ($part -ceq '..') { throw "$Label path escape is not allowed." }
        [void]$segments.Add([string]$part)
    }
    if ($segments.Count -eq 0) { return $rootFull }

    $current = $rootFull
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $segment = [string]$segments[$i]
        $isLast = ($i -eq ($segments.Count - 1))
        $currentInfo = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (-not $currentInfo.PSIsContainer) { throw "$Label path component is not a directory." }
        if (($currentInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label path is a reparse point." }

        $matched = [Collections.Generic.List[string]]::new()
        $ordinalNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
            $name = [IO.Path]::GetFileName($entry)
            if ($name.Equals($segment, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$matched.Add([string]$entry)
                [void]$ordinalNames.Add([string]$name)
            }
        }
        if ($matched.Count -eq 0) {
            if ($RequireExisting -or -not $isLast) { throw "$Label path component is missing." }
            return [IO.Path]::GetFullPath((Join-Path $current $segment))
        }
        if ($ordinalNames.Count -ne 1) { throw "$Label path component is ambiguous." }
        $item = Get-Item -LiteralPath $matched[0] -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label path is a reparse point." }
        if ($isLast) { return $item.FullName }
        if (-not $item.PSIsContainer) { throw "$Label path component is not a directory." }
        $current = $item.FullName
    }
    return $current
}

function Initialize-DirectClaudeStateRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Get-DirectClaudeCanonicalDirectory -Path $Path
    $cursor = $full
    $existing = [Collections.Generic.List[string]]::new()
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if ([IO.Directory]::Exists($cursor) -or [IO.File]::Exists($cursor)) { [void]$existing.Add($cursor) }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { break }
        $cursor = $parent
    }
    foreach ($itemPath in $existing) {
        $item = Get-Item -LiteralPath $itemPath -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'State root path is a reparse point.' }
        if (-not $item.PSIsContainer) { throw 'State root path component is not a directory.' }
    }
    [IO.Directory]::CreateDirectory($full) | Out-Null
    $created = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (-not $created.PSIsContainer -or ($created.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'State root must be a regular directory.'
    }
    return $created.FullName.TrimEnd('\')
}

function Get-DirectClaudePublicErrorCatalog {
    return [ordered]@{
        ADAPTER_TRANSPORT_FAILED = 'Telephone-line adapter transport failed.'
        ADAPTER_NATIVE_SESSION_MISMATCH = 'Adapter native session id does not match the frozen session.'
        ADAPTER_NATIVE_SESSION_MISSING = 'Adapter native session id is missing or unknown.'
        ADAPTER_DURABLE_STATE_MISSING = 'Adapter durable state was not found.'
    }
}

function Get-DirectClaudePublicError {
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [string]$ErrorCode)
    $catalog = Get-DirectClaudePublicErrorCatalog
    $code = [string]$ErrorCode
    if ([string]::IsNullOrWhiteSpace($code) -or -not $catalog.Contains($code)) { $code = 'ADAPTER_TRANSPORT_FAILED' }
    return [string]$catalog[$code]
}

function Protect-DirectClaudeDiagnostic {
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [int]$MaxLength = 4096)
    return Get-DirectClaudePublicError -Text $Text
}

function Resolve-DirectClaudeCommand {
    [CmdletBinding()]
    param([string]$ClaudeCommand)

    if (-not [string]::IsNullOrWhiteSpace($ClaudeCommand)) {
        $full = [IO.Path]::GetFullPath($ClaudeCommand)
        if (-not [IO.File]::Exists($full)) { throw 'Claude Code CLI path does not exist.' }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Claude Code CLI path must be a regular file.'
        }
        return $item.FullName
    }
    foreach ($name in @('claude', 'claude.exe', 'claude.cmd')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source) -and [IO.File]::Exists([string]$cmd.Source)) {
            return [IO.Path]::GetFullPath([string]$cmd.Source)
        }
    }
    throw 'Claude Code CLI was not found. Install the user CLI or pass -ClaudeCommand.'
}

function Assert-DirectClaudeArgumentSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][bool]$Resume,
        [string]$ExpectedSessionId
    )

    $forbidden = @(
        '--no-session-persistence',
        '--fork-session',
        '--dangerously-skip-permissions',
        '--allow-dangerously-skip-permissions',
        'login',
        'logout',
        'auth',
        'install',
        'update'
    )
    foreach ($argument in @($Arguments)) {
        $value = [string]$argument
        if ($forbidden -contains $value) { throw 'Claude Code invocation used a forbidden argument.' }
        if ($value.StartsWith('--dangerously-', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Claude Code invocation used a forbidden argument.'
        }
    }
    if ($Arguments.Count -lt 1 -or [string]$Arguments[0] -cne '-p') {
        throw 'Claude Code invocation must start with -p.'
    }
    $hasResume = ($Arguments -contains '--resume') -or ($Arguments -contains '-r')
    if ($Resume -and -not $hasResume) { throw 'Claude Code follow-up is missing --resume.' }
    if (-not $Resume -and $hasResume) { throw 'Claude Code start must not resume a session.' }
    if ($Resume) {
        $flagIndex = [Array]::IndexOf($Arguments, '--resume')
        if ($flagIndex -lt 0) { $flagIndex = [Array]::IndexOf($Arguments, '-r') }
        if ($flagIndex -lt 0 -or ($flagIndex + 1) -ge $Arguments.Count) { throw 'Claude Code follow-up is missing a session id.' }
        if ([string]$Arguments[$flagIndex + 1] -cne $ExpectedSessionId) {
            throw 'Claude Code follow-up native session id does not match the frozen session.'
        }
    }
}

function New-DirectClaudeProcessStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CliPath,
        [Parameter(Mandatory = $true)][string[]]$CliArguments,
        [Parameter(Mandatory = $true)][string]$Workspace
    )

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.WorkingDirectory = $Workspace
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $extension = [IO.Path]::GetExtension($CliPath)
    if ($extension -ieq '.ps1') {
        $info.FileName = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $CliPath) + @($CliArguments)) {
            [void]$info.ArgumentList.Add([string]$argument)
        }
    } else {
        $info.FileName = $CliPath
        foreach ($argument in @($CliArguments)) { [void]$info.ArgumentList.Add([string]$argument) }
    }
    return $info
}
