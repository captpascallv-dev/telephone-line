# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }

function Get-DirectCodexFileIdentity {
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

function Assert-DirectCodexIdentity {
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

function Read-DirectCodexJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $identity = Get-DirectCodexFileIdentity -Path $Path
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

function ConvertFrom-DirectCodexJsonLines {
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
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes).Replace("`r`n", "`n").Replace("`r", "`n")
    $records = [Collections.Generic.List[Collections.IDictionary]]::new()
    foreach ($line in $text.Split([char]0x0A)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $value = $line | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
        if ($value -isnot [Collections.IDictionary]) { throw "$Label contains a non-object record." }
        $records.Add($value)
    }
    if ($records.Count -eq 0) { throw "$Label has no JSON records." }
    return $records.ToArray()
}

function Get-DirectCodexNativeSessionIdFromEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Records)

    $ids = [Collections.Generic.List[string]]::new()
    foreach ($record in @($Records)) {
        $type = if ($record.Contains('type')) { [string]$record.type } else { '' }
        if ($type -cne 'thread.started') { continue }
        $id = ''
        if ($record.Contains('thread_id') -and -not [string]::IsNullOrWhiteSpace([string]$record.thread_id)) {
            $id = [string]$record.thread_id
        } elseif ($record.Contains('session_id') -and -not [string]::IsNullOrWhiteSpace([string]$record.session_id)) {
            $id = [string]$record.session_id
        }
        if ([string]::IsNullOrWhiteSpace($id)) { throw 'Codex JSONL thread.started event has no native session id.' }
        $ids.Add($id)
    }
    if ($ids.Count -eq 0) { throw 'Codex JSONL stream did not include a native session id.' }
    $unique = @($ids | Select-Object -Unique)
    if ($unique.Count -ne 1) { throw 'Codex JSONL stream reported more than one native session id.' }
    Assert-DirectCodexNativeSessionIdFormat -SessionId ([string]$unique[0]) -Label 'Codex JSONL'
    return [string]$unique[0]
}

function Assert-DirectCodexNativeSessionIdFormat {
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

function Assert-DirectCodexKeys {
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

function Write-DirectCodexBytesCreateNew {
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
    return Get-DirectCodexFileIdentity -Path $full
}

function Write-DirectCodexJsonCreateNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = ($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n"
    return Write-DirectCodexBytesCreateNew -Path $Path -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Test-DirectCodexOwnerAlive {
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

function Get-DirectCodexCanonicalDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
}

function Test-DirectCodexPathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowEqual
    )

    $canonicalRoot = Get-DirectCodexCanonicalDirectory -Path $Root
    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    if ($AllowEqual -and $canonicalPath.Equals($canonicalRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $canonicalPath.StartsWith($canonicalRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DirectCodexExistingComponentChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$RequireExisting
    )

    $rootFull = Get-DirectCodexCanonicalDirectory -Path $Root
    $probe = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    if (-not (Test-DirectCodexPathWithin -Root $rootFull -Path $probe -AllowEqual)) {
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

function Initialize-DirectCodexStateRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Get-DirectCodexCanonicalDirectory -Path $Path
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

function Get-DirectCodexPublicErrorCatalog {
    return [ordered]@{
        ADAPTER_TRANSPORT_FAILED = 'Telephone-line adapter transport failed.'
        ADAPTER_NATIVE_SESSION_MISMATCH = 'Adapter native session id does not match the frozen session.'
        ADAPTER_NATIVE_SESSION_MISSING = 'Adapter native session id is missing or unknown.'
        ADAPTER_DURABLE_STATE_MISSING = 'Adapter durable state was not found.'
    }
}

function Get-DirectCodexPublicError {
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [string]$ErrorCode)
    $catalog = Get-DirectCodexPublicErrorCatalog
    $code = [string]$ErrorCode
    if ([string]::IsNullOrWhiteSpace($code) -or -not $catalog.Contains($code)) { $code = 'ADAPTER_TRANSPORT_FAILED' }
    return [string]$catalog[$code]
}

function Protect-DirectCodexDiagnostic {
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [int]$MaxLength = 4096)
    return Get-DirectCodexPublicError -Text $Text
}

function Resolve-DirectCodexCommand {
    [CmdletBinding()]
    param([string]$CodexCommand)

    if (-not [string]::IsNullOrWhiteSpace($CodexCommand)) {
        $full = [IO.Path]::GetFullPath($CodexCommand)
        if (-not [IO.File]::Exists($full)) { throw 'Codex CLI path does not exist.' }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Codex CLI path must be a regular file.'
        }
        return $item.FullName
    }
    foreach ($name in @('codex', 'codex.exe', 'codex.cmd')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source) -and [IO.File]::Exists([string]$cmd.Source)) {
            return [IO.Path]::GetFullPath([string]$cmd.Source)
        }
    }
    throw 'Codex CLI was not found. Install the user CLI or pass -CodexCommand.'
}

function Assert-DirectCodexArgumentSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][bool]$Resume
    )

    $forbidden = @(
        '--ephemeral',
        '--dangerously-bypass-approvals-and-sandbox',
        '--dangerously-bypass-hook-trust',
        'login',
        'logout',
        'auth',
        'install',
        'update'
    )
    foreach ($argument in @($Arguments)) {
        $value = [string]$argument
        if ($forbidden -contains $value) { throw 'Codex CLI invocation used a forbidden argument.' }
        if ($value.StartsWith('--dangerously-', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Codex CLI invocation used a forbidden argument.'
        }
    }
    if ($Arguments.Count -lt 1 -or [string]$Arguments[0] -cne 'exec') {
        throw 'Codex CLI invocation must start with exec.'
    }
    $hasResume = $Arguments -contains 'resume'
    if ($Resume -and -not $hasResume) { throw 'Codex CLI follow-up is missing resume.' }
    if (-not $Resume -and $hasResume) { throw 'Codex CLI start must not resume a session.' }
}

function New-DirectCodexProcessStartInfo {
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
