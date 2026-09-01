# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }

function Get-DirectPiFileIdentity {
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

function Assert-DirectPiIdentity {
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

function Read-DirectPiJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $identity = Get-DirectPiFileIdentity -Path $Path
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

function ConvertFrom-DirectPiJsonLinesStrict {
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
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    if ($text.Contains("`r")) { throw "$Label is not strict LF JSONL." }
    if (-not $text.EndsWith("`n", [StringComparison]::Ordinal)) { throw "$Label has no terminal LF." }

    $lines = $text.Substring(0, $text.Length - 1).Split([char]0x0A)
    if ($lines.Count -eq 0) { throw "$Label has no JSON records." }
    $records = [Collections.Generic.List[Collections.IDictionary]]::new()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { throw "$Label contains a blank record." }
        $value = $line | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
        if ($value -isnot [Collections.IDictionary]) { throw "$Label contains a non-object record." }
        $records.Add($value)
    }
    return $records.ToArray()
}

function Assert-DirectPiKeys {
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

function Write-DirectPiBytesCreateNew {
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
    return Get-DirectPiFileIdentity -Path $full
}

function Write-DirectPiJsonCreateNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = ($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n"
    return Write-DirectPiBytesCreateNew -Path $Path -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Test-DirectPiOwnerAlive {
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

function Get-DirectPiCanonicalDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
}

function Test-DirectPiPathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowEqual
    )

    $canonicalRoot = Get-DirectPiCanonicalDirectory -Path $Root
    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    if ($AllowEqual -and $canonicalPath.Equals($canonicalRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $canonicalPath.StartsWith($canonicalRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-DirectPiPublicErrorCatalog {
    return [ordered]@{
        ADAPTER_TRANSPORT_FAILED = 'Telephone-line adapter transport failed.'
        ADAPTER_NATIVE_SESSION_MISMATCH = 'Adapter native session id does not match the frozen session.'
        ADAPTER_NATIVE_SESSION_MISSING = 'Adapter native session id is missing or unknown.'
        ADAPTER_DURABLE_STATE_MISSING = 'Adapter durable state was not found.'
    }
}

function Get-DirectPiPublicError {
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [string]$ErrorCode)
    $catalog = Get-DirectPiPublicErrorCatalog
    $code = [string]$ErrorCode
    if ([string]::IsNullOrWhiteSpace($code) -or -not $catalog.Contains($code)) { $code = 'ADAPTER_TRANSPORT_FAILED' }
    return [string]$catalog[$code]
}

function Protect-DirectPiDiagnostic {
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [int]$MaxLength = 2048)
    return Get-DirectPiPublicError -Text $Text
}

function Resolve-DirectPiNodeCommand {
    [CmdletBinding()]
    param([string]$NodePath)

    if (-not [string]::IsNullOrWhiteSpace($NodePath)) {
        $full = [IO.Path]::GetFullPath($NodePath)
        if (-not [IO.File]::Exists($full)) { throw 'Node executable path does not exist.' }
        return $full
    }
    $cmd = Get-Command 'node' -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { $cmd = Get-Command 'node.exe' -ErrorAction SilentlyContinue }
    if ($null -eq $cmd -or [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        throw 'Node was not found. Install Node or pass -NodePath.'
    }
    return [IO.Path]::GetFullPath([string]$cmd.Source)
}

function Resolve-DirectPiCliCommand {
    [CmdletBinding()]
    param([string]$PiCliPath)

    if (-not [string]::IsNullOrWhiteSpace($PiCliPath)) {
        $full = [IO.Path]::GetFullPath($PiCliPath)
        if (-not [IO.File]::Exists($full)) { throw 'PI CLI path does not exist.' }
        return $full
    }
    $cmd = Get-Command 'pi' -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { $cmd = Get-Command 'pi.cmd' -ErrorAction SilentlyContinue }
    if ($null -eq $cmd -or [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        throw 'PI coding agent CLI was not found. Install it or pass -PiCliPath.'
    }
    return [IO.Path]::GetFullPath([string]$cmd.Source)
}

function Get-DirectPiLaunchKind {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CliPath, [bool]$MockMode)
    $extension = [IO.Path]::GetExtension($CliPath)
    if ($extension -ieq '.ps1') { return 'powershell' }
    if ($extension -ieq '.cmd' -or $extension -ieq '.bat') { return 'command-shim' }
    if ($extension -ieq '.exe') { return 'executable' }
    if ($extension -ieq '.js' -or $extension -ieq '.mjs' -or $extension -ieq '.cjs') { return 'node-js' }
    if ($MockMode) { return 'powershell' }
    return 'node-js'
}

function Resolve-DirectPiLaunchHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CliPath,
        [Parameter(Mandatory = $true)][string]$Kind,
        [string]$NodePath
    )
    switch ([string]$Kind) {
        'powershell' { return [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
        'command-shim' { return [IO.Path]::GetFullPath($CliPath) }
        'executable' { return [IO.Path]::GetFullPath($CliPath) }
        default { return Resolve-DirectPiNodeCommand -NodePath $NodePath }
    }
}
