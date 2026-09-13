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

function Assert-DirectPiModelValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Thinking,
        [string]$Label = 'Direct PI model binding'
    )

    foreach ($binding in @(
        [ordered]@{ name = 'provider'; value = $Provider },
        [ordered]@{ name = 'model'; value = $Model },
        [ordered]@{ name = 'thinking'; value = $Thinking }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$binding.value) -or [string]$binding.value -cnotmatch '^[A-Za-z0-9._:/-]+$') {
            throw "$Label $($binding.name) is malformed."
        }
    }
}

function Assert-DirectPiModelBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Value,
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Thinking,
        [string]$Label = 'Direct PI model binding'
    )

    Assert-DirectPiModelValues -Provider $Provider -Model $Model -Thinking $Thinking -Label $Label
    if (
        [string]$Value.provider -cne $Provider -or
        [string]$Value.model -cne $Model -or
        [string]$Value.thinking -cne $Thinking
    ) {
        throw "$Label differs."
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

function Get-DirectPiRecordRole {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Record)
    if ($Record.Contains('message') -and $Record.message -is [Collections.IDictionary] -and $Record.message.Contains('role')) {
        return [string]$Record.message.role
    }
    if ($Record.Contains('role')) { return [string]$Record.role }
    return ''
}

function Get-DirectPiRecordType {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Record)
    if ($Record.Contains('type') -and -not [string]::IsNullOrWhiteSpace([string]$Record.type)) {
        return [string]$Record.type
    }
    return ''
}

function Get-DirectPiRecordAssistantMessage {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Record)
    $role = Get-DirectPiRecordRole -Record $Record
    if ($role -cne 'assistant') { return $null }
    if ($Record.Contains('message') -and $Record.message -is [Collections.IDictionary]) { return $Record.message }
    return $Record
}

function Test-DirectPiRecordIsUserOrTool {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Record)
    $type = Get-DirectPiRecordType -Record $Record
    $role = Get-DirectPiRecordRole -Record $Record
    if ($role -in @('user', 'tool', 'toolResult', 'bashExecution')) { return $true }
    if ($type -match '^(tool|tool_use|tool_result|toolCall|agent_start)$') { return $true }
    return $false
}

function Test-DirectPiRecordIsUnprovenTail {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Record)
    $type = Get-DirectPiRecordType -Record $Record
    if ($type -in @('compaction', 'branch_summary', 'custom_message')) { return $true }
    return $false
}

function Test-DirectPiAssistantStopIsTerminal {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Assistant)
    if (-not $Assistant.Contains('stopReason')) { return $false }
    $stopReason = [string]$Assistant.stopReason
    if ([string]::IsNullOrWhiteSpace($stopReason)) { return $false }
    return $stopReason -cin @('stop', 'length')
}

function Test-DirectPiAssistantHasOpenToolCall {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Assistant)
    if (-not $Assistant.Contains('content')) { return $false }
    $content = $Assistant.content
    if ($content -isnot [Collections.IEnumerable] -or $content -is [string]) { return $false }
    foreach ($block in @($content)) {
        if ($block -isnot [Collections.IDictionary]) { continue }
        $blockType = if ($block.Contains('type')) { [string]$block.type } else { '' }
        if ($blockType -cin @('toolCall', 'tool_use', 'toolUse')) { return $true }
    }
    return $false
}

function Get-DirectPiCurrentNativePath {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records)
    $nodes = [Collections.Generic.List[Collections.IDictionary]]::new()
    foreach ($record in $Records) {
        if ($record -isnot [Collections.IDictionary]) { continue }
        $type = Get-DirectPiRecordType -Record $record
        if ($type -ceq 'session') { continue }
        if (-not $record.Contains('id') -or [string]::IsNullOrWhiteSpace([string]$record.id)) { continue }
        $nodes.Add($record)
    }
    if ($nodes.Count -eq 0) {
        return @($Records)
    }

    $byId = [ordered]@{}
    foreach ($node in $nodes) {
        $id = [string]$node.id
        if ($byId.Contains($id)) { throw 'Latest native turn cannot be proven from the current session branch.' }
        $byId[$id] = $node
    }

    $leaf = $nodes[$nodes.Count - 1]
    $path = [Collections.Generic.List[Collections.IDictionary]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $cursor = $leaf
    while ($null -ne $cursor) {
        $id = [string]$cursor.id
        if (-not $seen.Add($id)) { throw 'Latest native turn cannot be proven from the current session branch.' }
        $path.Insert(0, $cursor)
        $parentId = $null
        if ($cursor.Contains('parentId') -and $null -ne $cursor.parentId -and -not [string]::IsNullOrWhiteSpace([string]$cursor.parentId)) {
            $parentId = [string]$cursor.parentId
        }
        if ([string]::IsNullOrWhiteSpace($parentId)) { break }
        if (-not $byId.Contains($parentId)) { throw 'Latest native turn cannot be proven from the current session branch.' }
        $cursor = $byId[$parentId]
    }
    return @($path)
}

function Assert-DirectPiLatestNativeTurnClosed {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records)
    $path = @(Get-DirectPiCurrentNativePath -Records $Records)
    if ($path.Count -lt 1) { throw 'PI JSON event stream has no final assistant message_end.' }

    $lastAssistantIndex = -1
    $lastAssistant = $null
    $lastThinking = ''
    $lastThinkingAtAssistant = ''
    for ($index = 0; $index -lt $path.Count; $index++) {
        $record = $path[$index]
        if ($record -isnot [Collections.IDictionary]) { continue }
        $type = Get-DirectPiRecordType -Record $record
        if ($type -ceq 'thinking_level_change') {
            if ($record.Contains('thinkingLevel') -and -not [string]::IsNullOrWhiteSpace([string]$record.thinkingLevel)) {
                $lastThinking = [string]$record.thinkingLevel
            }
        }
        $assistant = Get-DirectPiRecordAssistantMessage -Record $record
        if ($null -ne $assistant) {
            $lastAssistantIndex = $index
            $lastAssistant = $assistant
            $lastThinkingAtAssistant = $lastThinking
        }
    }
    if ($null -eq $lastAssistant) { throw 'PI JSON event stream has no final assistant message_end.' }
    if (-not (Test-DirectPiAssistantStopIsTerminal -Assistant $lastAssistant)) {
        throw 'PI final assistant has a non-terminal stopReason.'
    }
    if (Test-DirectPiAssistantHasOpenToolCall -Assistant $lastAssistant) {
        throw 'Latest native turn is not closed.'
    }
    $leaf = $path[$path.Count - 1]
    if ($leaf -is [Collections.IDictionary]) {
        $leafType = Get-DirectPiRecordType -Record $leaf
        if ($leafType -in @('compaction', 'branch_summary')) {
            throw 'Latest native turn cannot be proven from the current session branch.'
        }
    }
    for ($index = $lastAssistantIndex + 1; $index -lt $path.Count; $index++) {
        $record = $path[$index]
        if ($record -isnot [Collections.IDictionary]) { continue }
        if (Test-DirectPiRecordIsUserOrTool -Record $record) {
            throw 'Latest native turn is not closed.'
        }
        if (Test-DirectPiRecordIsUnprovenTail -Record $record) {
            throw 'Latest native turn cannot be proven from the current session branch.'
        }
        $laterAssistant = Get-DirectPiRecordAssistantMessage -Record $record
        if ($null -ne $laterAssistant) { throw 'Latest native turn is not closed.' }
    }
    $observedThinking = if ($null -ne $lastThinkingAtAssistant) { [string]$lastThinkingAtAssistant } else { '' }
    return [ordered]@{ assistant = $lastAssistant; thinking = $observedThinking; index = $lastAssistantIndex }
}

function ConvertFrom-DirectPiTerminalStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][ValidateRange(1, [long]::MaxValue)][long]$MaxRecordBytes
    )

    if ($Bytes.Length -eq 0) { throw 'PI JSON event stream is empty.' }
    if ($Bytes[$Bytes.Length - 1] -ne 10) { throw 'PI JSON event stream has no terminal LF.' }
    if ([Array]::IndexOf($Bytes, [byte]13) -ge 0) { throw 'PI JSON event stream is not strict LF JSONL.' }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        throw 'PI JSON event stream must not contain a UTF-8 BOM.'
    }

    $memory = [IO.MemoryStream]::new($Bytes, $false)
    $reader = [IO.StreamReader]::new($memory, [Text.UTF8Encoding]::new($false, $true), $false)
    $headers = [Collections.Generic.List[object]]::new()
    $lastAssistant = $null
    $lastEnd = $null
    $count = 0
    $endCount = 0
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { throw 'PI JSON event stream contains a blank record.' }
            if ([Text.Encoding]::UTF8.GetByteCount($line) -gt $MaxRecordBytes) { throw 'PI JSON event record exceeded the bounded size.' }
            $value = $line | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
            if ($value -isnot [Collections.IDictionary]) { throw 'PI JSON event stream contains a non-object record.' }
            if ($value.Contains('type') -and [string]$value.type -ceq 'session') {
                if ($count -ne 0 -or $headers.Count -ne 0) { throw 'PI session header is not the first and unique event.' }
                $headers.Add([ordered]@{ index = $count; value = $value })
            }
            if ($value.Contains('type') -and [string]$value.type -ceq 'agent_end') {
                $endCount++
                $lastEnd = [ordered]@{ index = $count; value = $value }
            }
            if (
                $value.Contains('type') -and [string]$value.type -ceq 'message_end' -and
                $value.Contains('message') -and $value.message -is [Collections.IDictionary] -and
                $value.message.Contains('role') -and [string]$value.message.role -ceq 'assistant'
            ) {
                $lastAssistant = [ordered]@{ index = $count; value = $value }
            }
            $count++
        }
    } finally {
        $reader.Dispose()
        $memory.Dispose()
    }

    $retained = [Collections.Generic.List[object]]::new()
    foreach ($header in $headers) { $retained.Add($header) }
    if ($null -ne $lastAssistant) { $retained.Add($lastAssistant) }
    if ($null -ne $lastEnd) { $retained.Add($lastEnd) }
    $events = @(
        $retained | Sort-Object { $_.index } | ForEach-Object { $_.value }
    )
    return [ordered]@{
        events = $events
        event_count = $count
        agent_end_count = $endCount
        stdout_bytes = [int64]$Bytes.Length
        stdout_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
        retained_events = $events.Count
        last_assistant_index = if ($null -ne $lastAssistant) { [int]$lastAssistant.index } else { -1 }
        last_agent_end_index = if ($null -ne $lastEnd) { [int]$lastEnd.index } else { -1 }
    }
}
