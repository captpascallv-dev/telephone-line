# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

function Test-TelephoneDashboardMalformedRow {
    [CmdletBinding()]
    param([AllowNull()][object]$Row)
    if ($null -eq $Row) { return $false }
    if ($Row -is [Collections.IDictionary]) {
        return ($Row.Contains('malformed') -and [bool]$Row['malformed'])
    }
    $prop = $Row.PSObject.Properties['malformed']
    return ($null -ne $prop -and [bool]$prop.Value)
}

function Add-TelephoneDashboardFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Findings,
        [Parameter(Mandatory = $true)][string]$Code,
        [string]$Severity = 'fail_closed'
    )
    foreach ($existing in $Findings) {
        if ([string]$existing.code -ceq $Code) { return }
    }
    [void]$Findings.Add([ordered]@{ code = [string]$Code; severity = [string]$Severity })
}

function Test-TelephoneDashboardLooksRemote {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return ($text -match '(?i)https?://|webhook://|callback://')
}

function Get-TelephoneDashboardGroupKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [string]$SessionId = '',
        [string]$RunId = ''
    )
    return ([string]$Project + '|' + [string]$SessionId + '|' + [string]$RunId)
}

function Read-TelephoneDashboardOptionalJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$SchemaName,
        [string]$Root = ''
    )
    if (-not [IO.File]::Exists($Path)) {
        return [ordered]@{ present = $false; valid = $false; value = $null; identity = $null; error = 'missing' }
    }
    $chain = Test-TelephoneCompletePathChain -Path $Path -Root $Root -RequireRegularFile -Label 'Dashboard evidence file'
    if (-not [bool]$chain.ok) {
        return [ordered]@{ present = $true; valid = $false; value = $null; identity = $null; error = $(if ([string]::IsNullOrWhiteSpace([string]$chain.error)) { 'UNREADABLE_EVIDENCE' } else { [string]$chain.error }) }
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return [ordered]@{ present = $false; valid = $false; value = $null; identity = $null; error = 'missing' }
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [ordered]@{ present = $true; valid = $false; value = $null; identity = $null; error = 'REPARSE_POINT' }
    }
    try {
        if ([string]::IsNullOrWhiteSpace($SchemaName)) {
            $read = Read-TelephoneJson -Path $Path
        } else {
            $read = Read-TelephoneJson -Path $Path -SchemaName $SchemaName
        }
        return [ordered]@{ present = $true; valid = $true; value = $read.value; identity = $read.identity; error = '' }
    } catch {
        return [ordered]@{ present = $true; valid = $false; value = $null; identity = $null; error = 'MALFORMED_EVIDENCE' }
    }
}

function Get-TelephoneDashboardLockHeld {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $false }
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $stream.Dispose()
        return $false
    } catch [IO.IOException] {
        return $true
    } catch {
        return $true
    }
}

function Read-TelephoneDashboardLifecycleEvents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Root = ''
    )
    $rows = [Collections.Generic.List[object]]::new()
    if (-not [IO.File]::Exists($Path)) {
        if ([IO.Directory]::Exists($Path)) {
            [void]$rows.Add([ordered]@{ malformed = $true; error = 'REPARSE_POINT' })
        } else {
            try {
                $ghost = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                if ($null -ne $ghost -and ($ghost.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    [void]$rows.Add([ordered]@{ malformed = $true; error = 'REPARSE_POINT' })
                }
            } catch { }
        }
        return @($rows)
    }
    $chain = Test-TelephoneCompletePathChain -Path $Path -Root $Root -RequireRegularFile -Label 'Lifecycle event file'
    if (-not [bool]$chain.ok) {
        [void]$rows.Add([ordered]@{ malformed = $true; error = $(if ([string]::IsNullOrWhiteSpace([string]$chain.error)) { 'UNREADABLE_EVIDENCE' } else { [string]$chain.error }) })
        return @($rows)
    }
    $maxBytes = [int]$script:TelephoneDashboardSessionEventsMaxBytes
    $read = Read-TelephoneDashboardSharedUtf8Bounded -Path $Path -MaxBytes $maxBytes
    if (-not [bool]$read.ok) {
        $code = [string]$read.error
        if ([string]::IsNullOrWhiteSpace($code) -or $code -ceq 'SESSION_EVIDENCE_INVALID') { $code = 'UNREADABLE_EVIDENCE' }
        [void]$rows.Add([ordered]@{ malformed = $true; error = $code })
        return @($rows)
    }
    try {
        $lengthAfter = [int64]([IO.FileInfo]::new($Path).Length)
        $readBytes = 0
        if ($read.Contains('bytes')) { $readBytes = [int64]$read.bytes }
        if ($lengthAfter -gt [int64]$maxBytes -or ($readBytes -gt 0 -and $lengthAfter -gt $readBytes)) {
            [void]$rows.Add([ordered]@{ malformed = $true; error = 'UNREADABLE_EVIDENCE' })
            return @($rows)
        }
    } catch {
        [void]$rows.Add([ordered]@{ malformed = $true; error = 'UNREADABLE_EVIDENCE' })
        return @($rows)
    }
    foreach ($line in @([string]$read.text -split "`n")) {
        $trim = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trim)) { continue }
        try {
            Assert-TelephoneJsonSchema -JsonText $trim -SchemaName 'dashboard-lifecycle-event' -Label 'lifecycle event'
            $row = $trim | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
            [void]$rows.Add($row)
        } catch {
            [void]$rows.Add([ordered]@{ malformed = $true; error = 'MALFORMED_EVIDENCE' })
        }
    }
    return @($rows)
}

function Convert-TelephoneDashboardEventsFromLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Project,
        [string]$SessionId = '',
        [string]$RunId = ''
    )
    $events = [Collections.Generic.List[object]]::new()
    foreach ($row in @($Rows)) {
        if ($null -eq $row -or (Test-TelephoneDashboardMalformedRow -Row $row)) { continue }
        if ([string]$row.project -cne $Project) { continue }
        if (-not [string]::IsNullOrWhiteSpace($SessionId) -and [string]$row.lead_session_id -cne $SessionId) { continue }
        if ($PSBoundParameters.ContainsKey('RunId') -and [string]$row.lead_run_id -cne [string]$RunId) { continue }
        $kind = [string]$row.kind
        if ([bool]$row.duplicate) { $kind = 'duplicate' }
        $ambiguous = $false
        if ($row -is [Collections.IDictionary] -and $row.Contains('provenance_ambiguous')) {
            $ambiguous = [bool]$row.provenance_ambiguous
        }
        [void]$events.Add((New-TelephoneDashboardReducerEvent -Kind $kind -LeadId ([string]$row.lead_session_id) -SessionId ([string]$row.lead_session_id) -JobId $(if ([string]::IsNullOrWhiteSpace([string]$row.line_job_id)) { [string]$row.lead_run_id } else { [string]$row.line_job_id }) -Receipt ([string]$row.receipt_sha256) -Provenance $(if ($null -ne $row.provenance) { [string]$row.provenance.sha256 } else { '' }) -Ambiguous:$ambiguous))
    }
    return @($events)
}

$script:TelephoneDashboardDirectStartupGateSeconds = 90
$script:TelephoneDashboardDirectRequestProtocols = @('huhu-direct-grok-request-v1', 'huhu-direct-cursor-request-v1')
$script:TelephoneDashboardPromptAcceptedPhases = @('prompt_accepted', 'execution', 'executing', 'delivered', 'completed', 'accepted')
$script:TelephoneDashboardPrePromptPhases = @('session_create', 'startup', 'starting')
$script:TelephoneDashboardAcceptedTurnTypes = @('turn_started', 'first_token')
$script:TelephoneDashboardSessionEventsMaxBytes = 8388608
$script:TelephoneDashboardMaxConfiguredJobRoots = 32
$script:TelephoneDashboardReservedDeviceNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($reservedName in @('CON', 'PRN', 'AUX', 'NUL')) {
    [void]$script:TelephoneDashboardReservedDeviceNames.Add($reservedName)
}
for ($reservedIndex = 1; $reservedIndex -le 9; $reservedIndex++) {
    [void]$script:TelephoneDashboardReservedDeviceNames.Add(('COM{0}' -f $reservedIndex))
    [void]$script:TelephoneDashboardReservedDeviceNames.Add(('LPT{0}' -f $reservedIndex))
}

function Get-TelephoneDashboardMapText {
    [CmdletBinding()]
    param([AllowNull()][object]$Map, [string]$Name, [string]$Default = '')
    if ($null -eq $Map) { return $Default }
    if ($Map -is [Collections.IDictionary]) {
        if (-not $Map.Contains($Name)) { return $Default }
        return [string]$Map[$Name]
    }
    $prop = $Map.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return [string]$prop.Value
}

function Get-TelephoneDashboardMapFlag {
    [CmdletBinding()]
    param([AllowNull()][object]$Map, [string]$Name)
    if ($null -eq $Map) { return $false }
    if ($Map -is [Collections.IDictionary]) {
        if (-not $Map.Contains($Name)) { return $false }
        $value = $Map[$Name]
        if ($value -is [bool]) { return [bool]$value }
        return $false
    }
    $prop = $Map.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $false }
    if ($prop.Value -is [bool]) { return [bool]$prop.Value }
    return $false
}

function Get-TelephoneDashboardDirectRouteAuthority {
    [CmdletBinding()]
    param([AllowNull()][object]$Descriptor)
    $retired = [Collections.Generic.List[string]]::new()
    $fresh = $false
    if ($null -eq $Descriptor) {
        return [ordered]@{ retired_session_ids = @(); fresh_required = $false }
    }
    $rawRetired = $null
    if ($Descriptor -is [Collections.IDictionary]) {
        if ($Descriptor.Contains('retired_direct_session_ids')) { $rawRetired = $Descriptor['retired_direct_session_ids'] }
        if ($Descriptor.Contains('fresh_direct_session_required')) { $fresh = [bool]$Descriptor['fresh_direct_session_required'] }
    } else {
        $retiredProp = $Descriptor.PSObject.Properties['retired_direct_session_ids']
        if ($null -ne $retiredProp) { $rawRetired = $retiredProp.Value }
        $freshProp = $Descriptor.PSObject.Properties['fresh_direct_session_required']
        if ($null -ne $freshProp -and $freshProp.Value -is [bool]) { $fresh = [bool]$freshProp.Value }
    }
    foreach ($item in @($rawRetired)) {
        $text = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($text)) { [void]$retired.Add($text) }
    }
    return [ordered]@{ retired_session_ids = @($retired); fresh_required = [bool]$fresh }
}

function Test-TelephoneDashboardPathReparse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$StopAt = ''
    )
    $probe = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $stop = ''
    if (-not [string]::IsNullOrWhiteSpace($StopAt)) {
        try { $stop = [IO.Path]::GetFullPath($StopAt).TrimEnd('\') } catch { $stop = '' }
    }
    while (-not [string]::IsNullOrWhiteSpace($probe)) {
        if ([IO.File]::Exists($probe) -or [IO.Directory]::Exists($probe)) {
            try {
                $item = Get-Item -LiteralPath $probe -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
            } catch { return $true }
        }
        if (-not [string]::IsNullOrWhiteSpace($stop) -and $probe.Equals($stop, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = [IO.Path]::GetDirectoryName($probe)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($probe, [StringComparison]::OrdinalIgnoreCase)) { break }
        $probe = $parent.TrimEnd('\')
    }
    return $false
}

function Test-TelephoneDashboardConfiguredDirectory {
    [CmdletBinding()]
    param([AllowNull()][string]$Path, [string]$Label = 'Configured root')
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [ordered]@{ ok = $false; path = ''; error = 'UNREADABLE_EVIDENCE' }
    }
    if (Test-TelephoneDashboardLooksRemote -Value $Path) {
        return [ordered]@{ ok = $false; path = [string]$Path; error = 'PATH_ESCAPE' }
    }
    try {
        Assert-TelephoneRelativePathSafe -Path $Path -Label $Label
        $full = Assert-TelephoneDirectoryPath -Path $Path -Label $Label
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -match 'reparse') { return [ordered]@{ ok = $false; path = [string]$Path; error = 'REPARSE_POINT' } }
        if ($message -match 'escape') { return [ordered]@{ ok = $false; path = [string]$Path; error = 'PATH_ESCAPE' } }
        return [ordered]@{ ok = $false; path = [string]$Path; error = 'UNREADABLE_EVIDENCE' }
    }
    if (Test-TelephoneDashboardPathReparse -Path $full) {
        return [ordered]@{ ok = $false; path = $full; error = 'REPARSE_POINT' }
    }
    return [ordered]@{ ok = $true; path = $full; error = '' }
}

function Test-TelephoneDashboardSessionComponentSafe {
    [CmdletBinding()]
    param([AllowNull()][string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
    if ($SessionId.IndexOfAny([char[]]@('\', '/', ':')) -ge 0) { return $false }
    if ($SessionId -ceq '.' -or $SessionId -ceq '..') { return $false }
    if ($SessionId.EndsWith('.') -or $SessionId.EndsWith(' ')) { return $false }
    if ($SessionId -notmatch '^[A-Za-z0-9._-]+$') { return $false }
    $stem = $SessionId
    $dot = $SessionId.IndexOf('.')
    if ($dot -ge 0) { $stem = $SessionId.Substring(0, $dot) }
    if ($script:TelephoneDashboardReservedDeviceNames.Contains($stem)) { return $false }
    return $true
}

function Get-TelephoneDashboardSessionEventsPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionEventsRoot,
        [Parameter(Mandatory = $true)][string]$SessionId
    )
    if (-not (Test-TelephoneDashboardSessionComponentSafe -SessionId $SessionId)) {
        return [ordered]@{ ok = $false; path = ''; error = 'SESSION_MISMATCH' }
    }
    $rootProbe = Test-TelephoneDashboardConfiguredDirectory -Path $SessionEventsRoot -Label 'Session events root'
    if (-not [bool]$rootProbe.ok) { return $rootProbe }
    try {
        Assert-TelephoneRelativePathSafe -Path $SessionId -Label 'Direct session id'
        Assert-TelephoneRelativePathSafe -Path (Join-Path $SessionId 'events.jsonl') -Label 'Session events'
    } catch {
        return [ordered]@{ ok = $false; path = ''; error = 'PATH_ESCAPE' }
    }
    $rootFull = [string]$rootProbe.path
    $full = [IO.Path]::GetFullPath((Join-Path $rootFull (Join-Path $SessionId 'events.jsonl')))
    $prefix = $rootFull + '\'
    if (-not ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
        return [ordered]@{ ok = $false; path = $full; error = 'PATH_ESCAPE' }
    }
    $sessionDir = [IO.Path]::GetDirectoryName($full)
    if ([IO.Directory]::Exists($sessionDir) -and (Test-TelephoneDashboardPathReparse -Path $sessionDir -StopAt $rootFull)) {
        return [ordered]@{ ok = $false; path = $full; error = 'REPARSE_POINT' }
    }
    if ([IO.File]::Exists($full) -and (Test-TelephoneDashboardPathReparse -Path $full -StopAt $rootFull)) {
        return [ordered]@{ ok = $false; path = $full; error = 'REPARSE_POINT' }
    }
    return [ordered]@{ ok = $true; path = $full; error = '' }
}

function Read-TelephoneDashboardSharedUtf8Bounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxBytes = 0
    )
    if ($MaxBytes -le 0) { $MaxBytes = [int]$script:TelephoneDashboardSessionEventsMaxBytes }
    if (-not [IO.File]::Exists($Path)) {
        return [ordered]@{ ok = $false; text = ''; error = 'UNREADABLE_EVIDENCE' }
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [ordered]@{ ok = $false; text = ''; error = 'REPARSE_POINT' }
    }
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $limit = [int]($MaxBytes + 1)
        if ($limit -le 1) {
            return [ordered]@{ ok = $false; text = ''; error = 'SESSION_EVIDENCE_INVALID' }
        }
        $buffer = New-Object byte[] $limit
        $total = 0
        while ($total -lt $limit) {
            $n = $stream.Read($buffer, $total, ($limit - $total))
            if ($n -le 0) { break }
            $total += $n
        }
        if ($total -gt $MaxBytes) {
            return [ordered]@{ ok = $false; text = ''; error = 'SESSION_EVIDENCE_INVALID' }
        }
        try {
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($buffer, 0, $total)
        } catch {
            return [ordered]@{ ok = $false; text = ''; error = 'SESSION_EVIDENCE_INVALID' }
        }
        return [ordered]@{ ok = $true; text = [string]$text; error = ''; bytes = [int64]$total }
    } catch {
        return [ordered]@{ ok = $false; text = ''; error = 'UNREADABLE_EVIDENCE'; bytes = [int64]0 }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-TelephoneDashboardSessionTurnAccepted {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$SessionEventsRoot,
        [AllowNull()][string]$SessionId,
        [int]$MaxBytes = 0
    )
    if ([string]::IsNullOrWhiteSpace($SessionEventsRoot)) {
        return [ordered]@{ accepted = $false; error = ''; configured = $false }
    }
    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return [ordered]@{ accepted = $false; error = 'SESSION_MISMATCH'; configured = $true }
    }
    $located = Get-TelephoneDashboardSessionEventsPath -SessionEventsRoot $SessionEventsRoot -SessionId $SessionId
    if (-not [bool]$located.ok) {
        return [ordered]@{ accepted = $false; error = $(if ([string]::IsNullOrWhiteSpace([string]$located.error)) { 'SESSION_EVIDENCE_INVALID' } else { [string]$located.error }); configured = $true }
    }
    if (-not [IO.File]::Exists([string]$located.path)) {
        return [ordered]@{ accepted = $false; error = ''; configured = $true }
    }
    $read = Read-TelephoneDashboardSharedUtf8Bounded -Path ([string]$located.path) -MaxBytes $MaxBytes
    if (-not [bool]$read.ok) {
        return [ordered]@{ accepted = $false; error = $(if ([string]::IsNullOrWhiteSpace([string]$read.error)) { 'SESSION_EVIDENCE_INVALID' } else { [string]$read.error }); configured = $true }
    }
    $accepted = $false
    foreach ($line in @([string]$read.text -split "`n")) {
        $trim = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trim)) { continue }
        $row = $null
        try {
            $row = $trim | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
        } catch {
            return [ordered]@{ accepted = $false; error = 'SESSION_EVIDENCE_INVALID'; configured = $true }
        }
        if ($null -eq $row -or $row -isnot [Collections.IDictionary] -or -not $row.Contains('type')) {
            return [ordered]@{ accepted = $false; error = 'SESSION_EVIDENCE_INVALID'; configured = $true }
        }
        $type = [string]$row['type']
        if ([string]::IsNullOrWhiteSpace($type) -or $type -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            return [ordered]@{ accepted = $false; error = 'SESSION_EVIDENCE_INVALID'; configured = $true }
        }
        if ($type -cnotin $script:TelephoneDashboardAcceptedTurnTypes) { continue }
        $eventSession = ''
        if ($row.Contains('session_id')) { $eventSession = [string]$row['session_id'] }
        if (-not [string]::IsNullOrWhiteSpace($eventSession) -and $eventSession -cne $SessionId) {
            return [ordered]@{ accepted = $false; error = 'SESSION_MISMATCH'; configured = $true }
        }
        $accepted = $true
    }
    return [ordered]@{ accepted = [bool]$accepted; error = ''; configured = $true }
}

function ConvertFrom-TelephoneDashboardTime {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return [DateTimeOffset]::MinValue }
    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    try {
        return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        return [DateTimeOffset]::MinValue
    }
}

function Get-TelephoneDashboardDirectRouteStartTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobRoot,
        [AllowNull()][object]$Request,
        [AllowNull()][object]$Owner
    )
    $fromRequest = ConvertFrom-TelephoneDashboardTime -Value (Get-TelephoneDashboardMapText -Map $Request -Name 'created_at_utc')
    if ($fromRequest -gt [DateTimeOffset]::MinValue) { return $fromRequest }
    $intent = Read-TelephoneDashboardOptionalJson -Path (Join-Path $JobRoot 'launch-intent.json')
    if ([bool]$intent.valid) {
        $fromIntent = ConvertFrom-TelephoneDashboardTime -Value (Get-TelephoneDashboardMapText -Map $intent.value -Name 'created_at_utc')
        if ($fromIntent -gt [DateTimeOffset]::MinValue) { return $fromIntent }
    }
    $fromOwner = ConvertFrom-TelephoneDashboardTime -Value (Get-TelephoneDashboardMapText -Map $Owner -Name 'started_at_utc')
    if ($fromOwner -gt [DateTimeOffset]::MinValue) { return $fromOwner }
    try {
        return [DateTimeOffset](Get-Item -LiteralPath $JobRoot).CreationTimeUtc
    } catch {
        return [DateTimeOffset]::UtcNow
    }
}

function Test-TelephoneDashboardDirectPromptAccepted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobRoot,
        [AllowNull()][object]$Request
    )
    $status = Read-TelephoneDashboardOptionalJson -Path (Join-Path $JobRoot 'lifecycle-status.json') -SchemaName 'lifecycle-status'
    if ([bool]$status.valid) {
        $phase = [string]$status.value.phase
        if ($phase -cin $script:TelephoneDashboardPromptAcceptedPhases) { return $true }
        if ($phase -cin $script:TelephoneDashboardPrePromptPhases) { return $false }
    }
    $progress = Read-TelephoneDashboardOptionalJson -Path (Join-Path $JobRoot 'progress.json')
    if ([bool]$progress.valid) {
        if (Get-TelephoneDashboardMapFlag -Map $progress.value -Name 'prompt_accepted') { return $true }
        $progressPhase = Get-TelephoneDashboardMapText -Map $progress.value -Name 'phase'
        if ($progressPhase -cin $script:TelephoneDashboardPromptAcceptedPhases) { return $true }
        if ($progressPhase -cin $script:TelephoneDashboardPrePromptPhases) { return $false }
    }
    foreach ($name in @('grok-result.json', 'result.json')) {
        $path = Join-Path $JobRoot $name
        if (-not [IO.File]::Exists($path)) { continue }
        try {
            if ((Get-Item -LiteralPath $path).Length -le 0) { continue }
        } catch { continue }
        $read = Read-TelephoneDashboardOptionalJson -Path $path
        if (-not [bool]$read.valid) { continue }
        $response = $null
        if ($read.value -is [Collections.IDictionary] -and $read.value.Contains('response')) { $response = $read.value['response'] }
        elseif ($null -ne $read.value.PSObject.Properties['response']) { $response = $read.value.response }
        if ($null -ne $response) { return $true }
        $session = Get-TelephoneDashboardMapText -Map $read.value -Name 'sessionId'
        if ([string]::IsNullOrWhiteSpace($session)) { $session = Get-TelephoneDashboardMapText -Map $read.value -Name 'session_id' }
        if (-not [string]::IsNullOrWhiteSpace($session)) { return $true }
    }
    $stdout = Join-Path $JobRoot 'route-stdout.txt'
    if ([IO.File]::Exists($stdout)) {
        try {
            if ((Get-Item -LiteralPath $stdout).Length -gt 0) { return $true }
        } catch { }
    }
    return $false
}

function Get-TelephoneDashboardDirectRouteLiveness {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Request,
        [bool]$OwnerAlive,
        [bool]$PromptAccepted,
        [DateTimeOffset]$StartedAt,
        [DateTimeOffset]$UtcNow,
        [AllowEmptyCollection()][string[]]$RetiredSessionIds = @(),
        [bool]$FreshSessionRequired = $false,
        [int]$StartupGateSeconds = 0
    )
    if ($StartupGateSeconds -le 0) { $StartupGateSeconds = [int]$script:TelephoneDashboardDirectStartupGateSeconds }
    $codes = [Collections.Generic.List[string]]::new()
    $sessionId = Get-TelephoneDashboardMapText -Map $Request -Name 'session_id'
    $resume = Get-TelephoneDashboardMapFlag -Map $Request -Name 'resume'
    foreach ($retired in @($RetiredSessionIds)) {
        if (-not [string]::IsNullOrWhiteSpace($sessionId) -and $sessionId -ceq [string]$retired) {
            [void]$codes.Add('RETIRED_DIRECT_SESSION')
            break
        }
    }
    if ($FreshSessionRequired -and $resume) {
        [void]$codes.Add('FRESH_DIRECT_SESSION_REQUIRED')
    }
    if ($codes.Count -eq 0 -and $OwnerAlive -and -not $PromptAccepted) {
        $ageSeconds = 0
        if ($StartedAt -gt [DateTimeOffset]::MinValue) {
            $ageSeconds = ($UtcNow - $StartedAt).TotalSeconds
        }
        if ($ageSeconds -gt $StartupGateSeconds) {
            [void]$codes.Add('STARTUP_PROGRESS_STALLED')
        }
    }
    $healthy = ($codes.Count -eq 0)
    return [ordered]@{
        healthy = [bool]$healthy
        codes = @($codes)
        prompt_accepted = [bool]$PromptAccepted
        owner_alive = [bool]$OwnerAlive
    }
}

function Test-TelephoneDashboardDirectReceiptFailed {
    [CmdletBinding()]
    param([AllowNull()][object]$Receipt)
    if ($null -eq $Receipt) { return $false }
    $complete = Get-TelephoneDashboardMapFlag -Map $Receipt -Name 'transport_complete'
    $success = $null
    foreach ($name in @('grok_success', 'cursor_success', 'success', 'executor_success')) {
        if ($Receipt -is [Collections.IDictionary] -and $Receipt.Contains($name)) {
            if ($Receipt[$name] -is [bool]) { $success = [bool]$Receipt[$name]; break }
        } elseif ($null -ne $Receipt.PSObject.Properties[$name] -and $Receipt.PSObject.Properties[$name].Value -is [bool]) {
            $success = [bool]$Receipt.PSObject.Properties[$name].Value
            break
        }
    }
    if ($complete -and $success -is [bool] -and -not $success) { return $true }
    $errorCode = Get-TelephoneDashboardMapText -Map $Receipt -Name 'command_error_code'
    if (-not [string]::IsNullOrWhiteSpace($errorCode) -and $errorCode -cne 'null') { return $true }
    return $false
}

function Test-TelephoneDashboardDirectReceiptSuccess {
    [CmdletBinding()]
    param([AllowNull()][object]$Receipt)
    if ($null -eq $Receipt) { return $false }
    if (-not (Get-TelephoneDashboardMapFlag -Map $Receipt -Name 'transport_complete')) { return $false }
    foreach ($name in @('grok_success', 'cursor_success', 'success', 'executor_success')) {
        if ($Receipt -is [Collections.IDictionary] -and $Receipt.Contains($name) -and $Receipt[$name] -is [bool]) {
            return [bool]$Receipt[$name]
        }
        if ($null -ne $Receipt.PSObject.Properties[$name] -and $Receipt.PSObject.Properties[$name].Value -is [bool]) {
            return [bool]$Receipt.PSObject.Properties[$name].Value
        }
    }
    return $false
}

function Get-TelephoneDashboardSessionEventsRoot {
    [CmdletBinding()]
    param([AllowNull()][object]$Descriptor)
    if ($null -eq $Descriptor) { return '' }
    return Get-TelephoneDashboardMapText -Map $Descriptor -Name 'session_events_root'
}

function Add-TelephoneDashboardDirectRouteLiveness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Findings,
        [Parameter(Mandatory = $true)][string]$JobRoot,
        [AllowNull()][object]$Request,
        [bool]$OwnerAlive,
        [AllowNull()][object]$Authority,
        [AllowNull()][object]$Receipt,
        [AllowNull()][object]$Descriptor,
        [DateTimeOffset]$UtcNow = [DateTimeOffset]::MinValue
    )
    if ($UtcNow -eq [DateTimeOffset]::MinValue) { $UtcNow = [DateTimeOffset]::UtcNow }
    $promptAccepted = $false
    $sessionRoot = Get-TelephoneDashboardSessionEventsRoot -Descriptor $Descriptor
    $sessionId = Get-TelephoneDashboardMapText -Map $Request -Name 'session_id'
    $turn = Test-TelephoneDashboardSessionTurnAccepted -SessionEventsRoot $sessionRoot -SessionId $sessionId
    if (-not [string]::IsNullOrWhiteSpace([string]$turn.error)) {
        Add-TelephoneDashboardFinding -Findings $Findings -Code ([string]$turn.error)
    } elseif ([bool]$turn.accepted) {
        $promptAccepted = $true
    } else {
        $promptAccepted = Test-TelephoneDashboardDirectPromptAccepted -JobRoot $JobRoot -Request $Request
    }
    $startedAt = Get-TelephoneDashboardDirectRouteStartTime -JobRoot $JobRoot -Request $Request -Owner $null
    $owner = Read-TelephoneDashboardOptionalJson -Path (Join-Path $JobRoot 'owner.json')
    if (-not [bool]$owner.valid) { $owner = Read-TelephoneDashboardOptionalJson -Path (Join-Path $JobRoot 'command-owner.json') }
    if ([bool]$owner.valid) {
        $startedAt = Get-TelephoneDashboardDirectRouteStartTime -JobRoot $JobRoot -Request $Request -Owner $owner.value
    }
    $retired = @()
    $fresh = $false
    if ($null -ne $Authority) {
        if ($Authority -is [Collections.IDictionary] -and $Authority.Contains('retired_session_ids')) {
            $retired = @($Authority.retired_session_ids)
            $fresh = [bool]$Authority.fresh_required
        } else {
            $resolved = Get-TelephoneDashboardDirectRouteAuthority -Descriptor $Authority
            $retired = @($resolved.retired_session_ids)
            $fresh = [bool]$resolved.fresh_required
        }
    }
    $liveness = Get-TelephoneDashboardDirectRouteLiveness -Request $Request -OwnerAlive $OwnerAlive -PromptAccepted $promptAccepted -StartedAt $startedAt -UtcNow $UtcNow -RetiredSessionIds $retired -FreshSessionRequired $fresh
    foreach ($code in @($liveness.codes)) {
        Add-TelephoneDashboardFinding -Findings $Findings -Code ([string]$code)
    }
    if (Test-TelephoneDashboardDirectReceiptFailed -Receipt $Receipt) {
        Add-TelephoneDashboardFinding -Findings $Findings -Code 'RECEIPT_FAILED'
    }
    return $liveness
}

function Get-TelephoneDashboardDirectRouteScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobRoot,
        [AllowNull()][object]$Descriptor,
        [DateTimeOffset]$UtcNow = [DateTimeOffset]::MinValue
    )
    if ($UtcNow -eq [DateTimeOffset]::MinValue) { $UtcNow = [DateTimeOffset]::UtcNow }
    $findings = [Collections.Generic.List[object]]::new()
    $request = Read-TelephoneDashboardOptionalJson -Path (Join-Path $JobRoot 'request.json')
    $owner = Read-TelephoneDashboardOptionalJson -Path (Join-Path $JobRoot 'owner.json')
    $receipt = Read-TelephoneDashboardOptionalJson -Path (Join-Path $JobRoot 'receipt.json')
    $status = Read-TelephoneDashboardOptionalJson -Path (Join-Path $JobRoot 'lifecycle-status.json') -SchemaName 'lifecycle-status'
    foreach ($probe in @($request, $owner, $receipt, $status)) {
        if ([bool]$probe.present -and -not [bool]$probe.valid) {
            Add-TelephoneDashboardFinding -Findings $findings -Code $(if ([string]$probe.error -ceq 'REPARSE_POINT') { 'REPARSE_POINT' } else { 'MALFORMED_EVIDENCE' })
        }
    }
    $protocol = ''
    if ([bool]$request.valid) { $protocol = Get-TelephoneDashboardMapText -Map $request.value -Name 'protocol_version' }
    if ([bool]$request.present -and [bool]$request.valid -and $protocol -cnotin $script:TelephoneDashboardDirectRequestProtocols) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'MALFORMED_EVIDENCE'
        $request = [ordered]@{ present = $true; valid = $false; value = $null; identity = $null; error = 'MALFORMED_EVIDENCE' }
    }
    $ownerAlive = $false
    if ([bool]$owner.valid) { $ownerAlive = Test-TelephoneOwnerAlive -Owner $owner.value }
    if ([bool]$request.valid -and -not [bool]$owner.present -and -not [bool]$receipt.present) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'OWNER_MISSING'
    }
    if ([bool]$owner.valid -and -not $ownerAlive -and -not [bool]$receipt.present) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'STALE_ACTIVE'
    }
    $authority = Get-TelephoneDashboardDirectRouteAuthority -Descriptor $Descriptor
    $receiptValue = $null
    if ([bool]$receipt.valid) { $receiptValue = $receipt.value }
    $requestValue = $null
    if ([bool]$request.valid) { $requestValue = $request.value }
    $null = Add-TelephoneDashboardDirectRouteLiveness -Findings $findings -JobRoot $JobRoot -Request $requestValue -OwnerAlive $ownerAlive -Authority $authority -Receipt $receiptValue -Descriptor $Descriptor -UtcNow $UtcNow
    $session = Get-TelephoneDashboardMapText -Map $requestValue -Name 'session_id'
    $jobId = Get-TelephoneDashboardMapText -Map $requestValue -Name 'job_id'
    if ([string]::IsNullOrWhiteSpace($jobId)) { $jobId = [IO.Path]::GetFileName($JobRoot.TrimEnd('\')) }
    $events = Read-TelephoneDashboardLifecycleEvents -Path (Join-Path $JobRoot 'lifecycle-events.jsonl') -Root $JobRoot
    return [ordered]@{
        job_root = $JobRoot
        project = ''
        session_id = $session
        job_id = $jobId
        stage = ''
        role = 'execution'
        route = ''
        dispatch = [ordered]@{ present = $false; valid = $false; value = $null }
        binding = [ordered]@{ present = $false; valid = $false; value = $null }
        receipt = $receipt
        delivery = [IO.File]::Exists((Join-Path $JobRoot 'delivery.json'))
        relay_error = [IO.File]::Exists((Join-Path $JobRoot 'relay-error.json'))
        status = $status
        command_alive = $ownerAlive
        relay_alive = $false
        events = $events
        findings = @($findings)
        direct_route = $true
        direct_session_id = $session
        direct_resume = (Get-TelephoneDashboardMapFlag -Map $requestValue -Name 'resume')
    }
}

function Get-TelephoneDashboardJobScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobRoot,
        [AllowNull()][object]$Descriptor,
        [DateTimeOffset]$UtcNow = [DateTimeOffset]::MinValue
    )

    $paths = Get-TelephoneJobPaths -JobRoot $JobRoot
    $findings = [Collections.Generic.List[object]]::new()
    $dispatch = Read-TelephoneDashboardOptionalJson -Path $paths.dispatch -SchemaName 'dispatch'
    $binding = Read-TelephoneDashboardOptionalJson -Path $paths.lead_binding -SchemaName 'lead-binding'
    $receipt = Read-TelephoneDashboardOptionalJson -Path $paths.receipt -SchemaName 'receipt'
    $status = Read-TelephoneDashboardOptionalJson -Path $paths.lifecycle_status -SchemaName 'lifecycle-status'
    $commandOwner = Read-TelephoneDashboardOptionalJson -Path $paths.command_owner
    $relayOwner = Read-TelephoneDashboardOptionalJson -Path $paths.relay_owner
    $deliveryPresent = [IO.File]::Exists($paths.delivery)
    $relayErrorPresent = [IO.File]::Exists($paths.relay_error)
    $events = Read-TelephoneDashboardLifecycleEvents -Path (Join-Path $JobRoot 'lifecycle-events.jsonl') -Root $JobRoot
    foreach ($probe in @($dispatch, $binding, $receipt, $status, $commandOwner, $relayOwner)) {
        if ([bool]$probe.present -and -not [bool]$probe.valid) {
            Add-TelephoneDashboardFinding -Findings $findings -Code $(if ([string]$probe.error -ceq 'REPARSE_POINT') { 'REPARSE_POINT' } else { 'MALFORMED_EVIDENCE' })
        }
    }
    if (-not [bool]$dispatch.present) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'BINDING_MISSING'
    }
    $project = ''
    $session = ''
    $jobId = ''
    $role = ''
    $stage = ''
    $route = ''
    if ([bool]$dispatch.valid) {
        $project = [string]$dispatch.value.project
        $jobId = [string]$dispatch.value.line_job_id
        $role = [string]$dispatch.value.role
        $stage = Get-TelephoneDashboardMapText -Map $dispatch.value -Name 'stage'
        $route = Get-TelephoneDashboardMapText -Map $dispatch.value -Name 'route'
        if ($null -ne $dispatch.value.lead) { $session = [string]$dispatch.value.lead.session_id }
    } elseif ([bool]$dispatch.present) {
        try {
            $rawDispatch = Read-TelephoneJson -Path $paths.dispatch
            $rawValue = $rawDispatch.value
            $project = Get-TelephoneDashboardMapText -Map $rawValue -Name 'project'
            $jobId = Get-TelephoneDashboardMapText -Map $rawValue -Name 'line_job_id'
            $role = Get-TelephoneDashboardMapText -Map $rawValue -Name 'role'
            $stage = Get-TelephoneDashboardMapText -Map $rawValue -Name 'stage'
            $route = Get-TelephoneDashboardMapText -Map $rawValue -Name 'route'
            $leadMap = $null
            if ($rawValue -is [Collections.IDictionary] -and $rawValue.Contains('lead')) { $leadMap = $rawValue['lead'] }
            elseif ($null -ne $rawValue.PSObject.Properties['lead']) { $leadMap = $rawValue.lead }
            if ($null -ne $leadMap) { $session = Get-TelephoneDashboardMapText -Map $leadMap -Name 'session_id' }
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($jobId)) { $jobId = [IO.Path]::GetFileName($JobRoot.TrimEnd('\')) }
    if ([bool]$binding.valid) {
        $boundSession = [string]$binding.value.session_id
        if ([string]::IsNullOrWhiteSpace($session)) { $session = $boundSession }
        elseif ($boundSession -cne $session) { Add-TelephoneDashboardFinding -Findings $findings -Code 'BINDING_MISMATCH' }
    } elseif ([bool]$dispatch.valid) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'BINDING_MISSING'
    }
    if ([bool]$receipt.present -and [bool]$receipt.valid) {
        if ([string]$receipt.value.line_job_id -cne $jobId -and -not [string]::IsNullOrWhiteSpace($jobId)) {
            Add-TelephoneDashboardFinding -Findings $findings -Code 'RECEIPT_MISMATCH'
        }
    }
    $commandAlive = $false
    if ([bool]$commandOwner.valid) { $commandAlive = Test-TelephoneOwnerAlive -Owner $commandOwner.value }
    $relayAlive = $false
    if ([bool]$relayOwner.valid) { $relayAlive = Test-TelephoneOwnerAlive -Owner $relayOwner.value }
    if ([bool]$dispatch.valid -and -not [bool]$commandOwner.present -and -not [bool]$receipt.present) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'OWNER_MISSING'
    }
    if ([bool]$commandOwner.valid -and -not $commandAlive -and -not [bool]$receipt.present) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'STALE_ACTIVE'
    }
    if ([bool]$receipt.valid -and -not $deliveryPresent) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'CALLBACK_MISSING'
        if (Test-TelephoneJobMailboxPendingWait -JobRoot $JobRoot) {
            Add-TelephoneDashboardFinding -Findings $findings -Code 'BATCH_COLLECTING' -Severity 'info'
        }
    }
    if ($relayErrorPresent -and [bool]$receipt.valid -and -not $deliveryPresent) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'LOST_RELAY'
    }
    $mailboxPending = Test-TelephoneJobMailboxPendingWait -JobRoot $JobRoot
    if ([bool]$relayOwner.valid -and -not $relayAlive -and [bool]$receipt.valid -and -not $deliveryPresent -and -not $mailboxPending) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'LOST_RELAY'
    }
    $commandHeld = Get-TelephoneDashboardLockHeld -Path $paths.command_gate
    $deliveryHeld = Get-TelephoneDashboardLockHeld -Path $paths.delivery_lock
    if ($commandHeld -or $deliveryHeld) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'HELD_LOCK'
    }
    if ([bool]$status.valid) {
        $idleGap = Test-TelephoneLifecycleIdleGap -JobRoot $JobRoot
        if ([bool]$idleGap.idle_gap) {
            Add-TelephoneDashboardFinding -Findings $findings -Code 'NONTERMINAL_IDLE_GAP'
        }
    }
    $directRequest = Read-TelephoneDashboardOptionalJson -Path (Join-Path $JobRoot 'request.json')
    $directSessionId = ''
    $directResume = $false
    $directRoute = $false
    if ([bool]$directRequest.valid) {
        $directProtocol = Get-TelephoneDashboardMapText -Map $directRequest.value -Name 'protocol_version'
        if ($directProtocol -cin $script:TelephoneDashboardDirectRequestProtocols) {
            $directRoute = $true
            $directSessionId = Get-TelephoneDashboardMapText -Map $directRequest.value -Name 'session_id'
            $directResume = Get-TelephoneDashboardMapFlag -Map $directRequest.value -Name 'resume'
            if ($UtcNow -eq [DateTimeOffset]::MinValue) { $UtcNow = [DateTimeOffset]::UtcNow }
            $authority = Get-TelephoneDashboardDirectRouteAuthority -Descriptor $Descriptor
            $receiptValue = $null
            if ([bool]$receipt.valid) { $receiptValue = $receipt.value }
            $null = Add-TelephoneDashboardDirectRouteLiveness -Findings $findings -JobRoot $JobRoot -Request $directRequest.value -OwnerAlive $commandAlive -Authority $authority -Receipt $receiptValue -Descriptor $Descriptor -UtcNow $UtcNow
            if ([string]::IsNullOrWhiteSpace($session)) { $session = $directSessionId }
        }
    }
    return [ordered]@{
        job_root = $JobRoot
        project = $project
        session_id = $session
        job_id = $jobId
        stage = $stage
        role = $role
        route = $route
        dispatch = $dispatch
        binding = $binding
        receipt = $receipt
        delivery = $deliveryPresent
        relay_error = $relayErrorPresent
        status = $status
        command_alive = $commandAlive
        relay_alive = $relayAlive
        events = $events
        findings = @($findings)
        direct_route = [bool]$directRoute
        direct_session_id = $directSessionId
        direct_resume = [bool]$directResume
    }
}

function Get-TelephoneDashboardRunScan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RunRoot)

    $findings = [Collections.Generic.List[object]]::new()
    $run = Read-TelephoneDashboardOptionalJson -Path (Join-Path $RunRoot 'run.json') -SchemaName 'codex-app-server-lead-run'
    $owner = Read-TelephoneDashboardOptionalJson -Path (Join-Path $RunRoot 'owner.json') -SchemaName 'codex-app-server-lead-owner'
    $status = Read-TelephoneDashboardOptionalJson -Path (Join-Path $RunRoot 'status.json') -SchemaName 'codex-app-server-lead-status'
    $ack = Read-TelephoneDashboardOptionalJson -Path (Join-Path $RunRoot 'lead-wake-ack.json') -SchemaName 'codex-app-server-lead-ack'
    $result = Read-TelephoneDashboardOptionalJson -Path (Join-Path $RunRoot 'launcher-result.json') -SchemaName 'codex-app-server-lead-result'
    $gate = Join-Path $RunRoot 'gate.lock'
    foreach ($probe in @($run, $owner, $status, $ack, $result)) {
        if ([bool]$probe.present -and -not [bool]$probe.valid) {
            Add-TelephoneDashboardFinding -Findings $findings -Code $(if ([string]$probe.error -ceq 'REPARSE_POINT') { 'REPARSE_POINT' } else { 'MALFORMED_EVIDENCE' })
        }
    }
    $runId = [IO.Path]::GetFileName($RunRoot.TrimEnd('\'))
    $session = ''
    $leadStatus = ''
    if ([bool]$run.valid) {
        $runId = [string]$run.value.run_id
        if ($run.value.Contains('thread_id')) { $session = [string]$run.value.thread_id }
    }
    if ([bool]$status.valid) {
        $leadStatus = [string]$status.value.status
        if ([string]::IsNullOrWhiteSpace($session)) { $session = [string]$status.value.thread_id }
    }
    $ownerAlive = $false
    if ([bool]$owner.valid) { $ownerAlive = Test-TelephoneOwnerAlive -Owner $owner.value }
    if ([bool]$run.valid -and -not [bool]$owner.present -and $leadStatus -ceq 'active') {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'OWNER_MISSING'
    }
    if ([bool]$owner.valid -and -not $ownerAlive -and $leadStatus -ceq 'active') {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'LIVE_IDENTITY_DISAGREEMENT'
    }
    if (Get-TelephoneDashboardLockHeld -Path $gate) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'HELD_LOCK'
    }
    $events = Read-TelephoneDashboardLifecycleEvents -Path (Join-Path $RunRoot 'lifecycle-events.jsonl') -Root $RunRoot
    foreach ($row in @($events)) {
        if (Test-TelephoneDashboardMalformedRow -Row $row) {
            $eventCode = 'MALFORMED_EVIDENCE'
            if ($row.Contains('error') -and -not [string]::IsNullOrWhiteSpace([string]$row.error) -and [string]$row.error -cne 'missing') {
                $eventCode = [string]$row.error
            }
            Add-TelephoneDashboardFinding -Findings $findings -Code $eventCode
        }
    }
    return [ordered]@{
        run_root = $RunRoot
        run_id = $runId
        session_id = $session
        lead_status = $leadStatus
        owner_alive = $ownerAlive
        ack = [bool]$ack.present
        result = [bool]$result.present
        events = $events
        findings = @($findings)
    }
}

function Get-TelephoneDashboardDescriptorScan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DescriptorPath)

    $findings = [Collections.Generic.List[object]]::new()
    if (Test-TelephoneDashboardLooksRemote -Value $DescriptorPath) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'PATH_ESCAPE'
        return [ordered]@{ valid = $false; descriptor = $null; findings = @($findings) }
    }
    $descSafety = Test-TelephoneCompletePathChain -Path $DescriptorPath -RequireRegularFile -Label 'Dashboard descriptor'
    if (-not [bool]$descSafety.ok) {
        Add-TelephoneDashboardFinding -Findings $findings -Code $(if ([string]::IsNullOrWhiteSpace([string]$descSafety.error)) { 'UNREADABLE_EVIDENCE' } else { [string]$descSafety.error })
        return [ordered]@{ valid = $false; descriptor = $null; findings = @($findings) }
    }
    $read = Read-TelephoneDashboardOptionalJson -Path $DescriptorPath -SchemaName 'dashboard-project-descriptor'
    if (-not [bool]$read.valid) {
        Add-TelephoneDashboardFinding -Findings $findings -Code $(if ([string]$read.error -ceq 'REPARSE_POINT') { 'REPARSE_POINT' } else { 'MALFORMED_EVIDENCE' })
        return [ordered]@{ valid = $false; descriptor = $null; findings = @($findings) }
    }
    $stateRoot = [string]$read.value.state_root
    if (Test-TelephoneDashboardLooksRemote -Value $stateRoot) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'PATH_ESCAPE'
        return [ordered]@{ valid = $false; descriptor = $read.value; findings = @($findings) }
    }
    $stateProbe = Test-TelephoneDashboardConfiguredDirectory -Path $stateRoot -Label 'Dashboard state root'
    if (-not [bool]$stateProbe.ok) {
        Add-TelephoneDashboardFinding -Findings $findings -Code $(if ([string]::IsNullOrWhiteSpace([string]$stateProbe.error)) { 'UNREADABLE_EVIDENCE' } else { [string]$stateProbe.error })
        return [ordered]@{ valid = $false; descriptor = $read.value; findings = @($findings) }
    }
    return [ordered]@{ valid = $true; descriptor = $read.value; findings = @($findings); state_root = [string]$stateProbe.path }
}

function Test-TelephoneDashboardExactToken {
    [CmdletBinding()]
    param([AllowNull()][string]$Value, [Parameter(Mandatory = $true)][string[]]$Tokens)
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    foreach ($token in @($Tokens)) {
        if ($text.Equals($token, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-TelephoneDashboardExactAuditEvidence {
    [CmdletBinding()]
    param([AllowNull()][object]$Job)
    if ($null -eq $Job) { return $false }
    $tokens = @('review', 'final_audit', 'final-audit')
    return (
        (Test-TelephoneDashboardExactToken -Value ([string]$Job.role) -Tokens $tokens) -or
        (Test-TelephoneDashboardExactToken -Value $(if ($Job -is [Collections.IDictionary] -and $Job.Contains('stage')) { [string]$Job.stage } else { '' }) -Tokens $tokens) -or
        (Test-TelephoneDashboardExactToken -Value $(if ($Job -is [Collections.IDictionary] -and $Job.Contains('route')) { [string]$Job.route } else { '' }) -Tokens $tokens)
    )
}

function Test-TelephoneDashboardDelimitedStageToken {
    [CmdletBinding()]
    param([AllowNull()][string]$Stage, [Parameter(Mandatory = $true)][string[]]$Tokens)
    $text = [string]$Stage
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if (Test-TelephoneDashboardExactToken -Value $text -Tokens $Tokens) { return $true }
    foreach ($part in @([regex]::Split($text, '[^A-Za-z0-9]+'))) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        if (Test-TelephoneDashboardExactToken -Value $part -Tokens $Tokens) { return $true }
    }
    return $false
}

function Test-TelephoneDashboardExactCorrectionEvidence {
    [CmdletBinding()]
    param([AllowNull()][object]$Job)
    if ($null -eq $Job) { return $false }
    $role = Get-TelephoneDashboardMapText -Map $Job -Name 'role'
    if (-not $role.Equals('execution', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $stage = Get-TelephoneDashboardMapText -Map $Job -Name 'stage'
    return (Test-TelephoneDashboardDelimitedStageToken -Stage $stage -Tokens @('correction', 'correct', 'repair'))
}

function New-TelephoneDashboardObservedGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [string]$SessionId = '',
        [string]$RunId = '',
        [string]$Phase = 'idle',
        [bool]$Visible = $true,
        [bool]$Disappeared = $false,
        [string]$Color = 'yellow',
        [bool]$Lead = $false,
        [bool]$Execution = $false,
        [bool]$FinalAudit = $false,
        [bool]$Correction = $false,
        [bool]$Closure = $false,
        [bool]$Terminal = $false,
        [string]$ClosureReceipt = '',
        [AllowEmptyCollection()][object[]]$Findings = @(),
        [string]$LineJobId = '',
        [string]$Stage = '',
        [string]$Role = '',
        [string]$Route = '',
        [int]$DuplicateCount = 0,
        [string]$Provenance = '',
        [string]$SupervisorRunId = '',
        [string]$SupervisorStatus = '',
        [bool]$PausedByPascal = $false,
        [switch]$HasSupervisorEvidence
    )
    $group = [ordered]@{
        project = $Project
        lead_session_id = $SessionId
        lead_run_id = $RunId
        phase = $Phase
        visible = [bool]$Visible
        disappeared = [bool]$Disappeared
        color = $Color
        lead = [bool]$Lead
        execution = [bool]$Execution
        final_audit = [bool]$FinalAudit
        correction = [bool]$Correction
        closure = [bool]$Closure
        terminal = [bool]$Terminal
        closure_receipt = $ClosureReceipt
        line_job_id = $LineJobId
        stage = $Stage
        role = $Role
        route = $Route
        duplicate_count = [int]$DuplicateCount
        provenance = $Provenance
        findings = @($Findings)
    }
    if ($HasSupervisorEvidence -or -not [string]::IsNullOrWhiteSpace($SupervisorRunId) -or -not [string]::IsNullOrWhiteSpace($SupervisorStatus)) {
        $group.supervisor_run_id = $SupervisorRunId
        $group.supervisor_status = $SupervisorStatus
        $group.paused_by_pascal = [bool]$PausedByPascal
    }
    return $group
}

function Get-TelephoneDashboardCurrentStateGroup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Descriptor)

    $project = [string]$Descriptor.project
    $path = [string]$Descriptor.current_state_file
    $safety = Test-TelephoneCompletePathChain -Path $path -RequireRegularFile -Label 'Telephone current-state projection'
    if (-not [bool]$safety.ok) {
        return (New-TelephoneDashboardObservedGroup -Project $project -Findings @([ordered]@{ code = 'CURRENT_STATE_INVALID'; severity = 'fail_closed' }))
    }
    $read = Read-TelephoneDashboardOptionalJson -Path ([string]$safety.path) -SchemaName 'control-plane-current-state'
    if (-not [bool]$read.valid) {
        return (New-TelephoneDashboardObservedGroup -Project $project -Findings @([ordered]@{ code = 'CURRENT_STATE_INVALID'; severity = 'fail_closed' }))
    }
    $state = $read.value
    if ([string]$state.project -cne $project) {
        return (New-TelephoneDashboardObservedGroup -Project $project -Findings @([ordered]@{ code = 'CURRENT_STATE_PROJECT_MISMATCH'; severity = 'fail_closed' }))
    }
    $lineageFields = @('current_pointer_file','manifest_file','registration_file','activation_generation')
    $lineageConfigured = @($lineageFields | Where-Object { $Descriptor.Contains($_) }).Count -gt 0
    if ($lineageConfigured) {
        try {
            foreach ($field in $lineageFields) { if (-not $Descriptor.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$Descriptor[$field])) { throw 'descriptor lineage incomplete' } }
            $pointerRead = Read-TelephoneJson -Path ([string]$Descriptor.current_pointer_file) -SchemaName 'control-plane-current-pointer'
            $manifestRead = Read-TelephoneJson -Path ([string]$Descriptor.manifest_file) -SchemaName 'control-plane-wave-manifest'
            $registrationRead = Read-TelephoneJson -Path ([string]$Descriptor.registration_file)
            $generation = [string]$Descriptor.activation_generation
            if ([string]$pointerRead.value.activation_generation -cne $generation -or [string]$manifestRead.value.activation_generation -cne $generation -or [string]$registrationRead.value.activation_generation -cne $generation -or [string]$state.activation_generation -cne $generation) { throw 'activation generation mismatch' }
            Assert-TelephoneFileIdentity -Expected $pointerRead.value.manifest -Actual $manifestRead.identity -Label 'HUD pointer manifest'
            Assert-TelephoneFileIdentity -Expected $state.manifest -Actual $manifestRead.identity -Label 'HUD current manifest'
            Assert-TelephoneFileIdentity -Expected $state.current_pointer -Actual $pointerRead.identity -Label 'HUD current pointer'
            Assert-TelephoneFileIdentity -Expected $registrationRead.value.manifest -Actual $manifestRead.identity -Label 'HUD registration manifest'
            if (-not [IO.Path]::GetFullPath([string]$registrationRead.value.current_state).Equals([IO.Path]::GetFullPath([string]$safety.path), [StringComparison]::OrdinalIgnoreCase)) { throw 'registration current path mismatch' }
        } catch {
            return (New-TelephoneDashboardObservedGroup -Project $project -Findings @([ordered]@{ code = 'CURRENT_LINEAGE_CONFLICT'; severity = 'fail_closed' }))
        }
    }
    $stateAgeSeconds = 0
    try { $stateAgeSeconds = [math]::Max(0, [math]::Floor(([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$state.updated_at_utc).ToUniversalTime()).TotalSeconds)) } catch { $stateAgeSeconds = [int]::MaxValue }
    $staleAfterSeconds = [int]$state.stale_after_seconds
    $stateStale = ($stateAgeSeconds -gt $staleAfterSeconds)
    $findings = [Collections.Generic.List[object]]::new()
    foreach ($code in @($state.findings)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$code)) { [void]$findings.Add([ordered]@{ code = [string]$code; severity = 'fail_closed' }) }
    }
    if ([string]$state.projection_status -ceq 'unknown') { [void]$findings.Add([ordered]@{ code = 'CURRENT_STATE_UNKNOWN'; severity = 'fail_closed' }) }
    if ([string]$state.projection_status -ceq 'conflict') { [void]$findings.Add([ordered]@{ code = 'CURRENT_STATE_CONFLICT'; severity = 'fail_closed' }) }
    if ($stateStale) { [void]$findings.Add([ordered]@{ code = 'CURRENT_STATE_STALE'; severity = 'fail_closed' }) }
    $lanes = @($state.lanes | ForEach-Object {
        [ordered]@{
            package_id = [string]$_.package_id; line_job_id = [string]$_.line_job_id; role = [string]$_.role; route = [string]$_.route
            state = [string]$_.state; failure_class = [string]$_.failure_class
            diagnostic_code = [string]$_.diagnostic_code; attempt = [int]$_.attempt; retry_of_line_job_id = $_.retry_of_line_job_id
            owner_alive = ($null -ne $_.owner -and [bool]$_.owner.alive)
            receipt_present = ($null -ne $_.receipt); delivery_present = ($null -ne $_.delivery)
            callback_active = [bool]$_.callback_active; last_evidence_at_utc = [string]$_.last_evidence_at_utc
            evidence_age_seconds = [int64]$_.evidence_age_seconds; evidence_fingerprint = [string]$_.evidence_fingerprint
        }
    })
    $actions = @($state.actions | ForEach-Object { [ordered]@{ action_id=[string]$_.action_id; kind=[string]$_.kind; sequence=[int]$_.sequence; state=[string]$_.state; reason=[string]$_.reason; retry_count=[int]$_.retry_count } })
    $roles = @($lanes.role | Sort-Object -Unique)
    $routes = @($lanes.route | Sort-Object -Unique)
    $failures = @($lanes.failure_class | Where-Object { $_ -cne 'none' } | Sort-Object -Unique)
    $failureClass = $(if ($failures.Count -eq 0) { 'none' } elseif ($failures.Count -eq 1) { [string]$failures[0] } else { 'mixed' })
    $phase = [string]$state.dashboard_phase
    $terminal = [bool]$state.terminal
    $group = New-TelephoneDashboardObservedGroup `
        -Project $project -SessionId ([string]$state.lead.session_id) -RunId ([string]$state.lead.run_id) `
        -Phase $phase -Visible (-not $terminal) -Disappeared $terminal -Color $(if ($findings.Count -eq 0) { 'green' } else { 'yellow' }) `
        -Lead ($phase -ceq 'lead') -Execution (@($lanes | Where-Object { [string]$_.state -cin @('starting', 'executing', 'receipt_ready', 'callback_running') }).Count -gt 0) `
        -FinalAudit ($roles -contains 'review') -Correction ($failures.Count -gt 0) -Closure ($phase -ceq 'closure') -Terminal $terminal `
        -Findings @($findings) -LineJobId $(if ($lanes.Count -eq 1) { [string]$lanes[0].line_job_id } else { '' }) `
        -Stage ([string]$state.goal_summary) -Role $(if ($roles.Count -eq 1) { [string]$roles[0] } else { '' }) -Route $(if ($routes.Count -eq 1) { [string]$routes[0] } else { 'mixed' }) `
        -Provenance ([string]$state.projection_fingerprint)
    $group.current_state_version = [int]$state.projection_version
    $group.current_state_fingerprint = [string]$state.projection_fingerprint
    $group.current_state_age_seconds = [int64]$stateAgeSeconds
    $group.current_state_stale_after_seconds = $staleAfterSeconds
    $group.current_state_stale = [bool]$stateStale
    $group.last_event_at_utc = [string]$state.last_transition.at_utc
    $group.failure_class = $failureClass
    $group.automatic_action = $(if ([bool]$state.next_transition.authorized) { [string]$state.next_transition.kind } else { '' })
    $group.requires_pascal = [bool]$state.requires_pascal
    $group.lanes = $lanes
    $group.actions = $actions
    return $group
}

function Get-TelephoneDashboardGroupProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [string]$SessionId = '',
        [string]$RunId = '',
        [string]$TerminalState = 'active',
        [AllowEmptyCollection()][object[]]$Jobs = @(),
        [AllowEmptyCollection()][object[]]$Runs = @(),
        [AllowEmptyCollection()][object[]]$Events = @(),
        [AllowNull()][object]$Closure = $null,
        [AllowEmptyCollection()][object[]]$ExtraFindings = @(),
        [string]$SupervisorRunId = '',
        [string]$SupervisorStatus = '',
        [bool]$PausedByPascal = $false,
        [switch]$HasSupervisorEvidence
    )

    $findings = [Collections.Generic.List[object]]::new()
    foreach ($extra in @($ExtraFindings)) {
        if ($null -eq $extra) { continue }
        $code = ''
        $severity = 'fail_closed'
        if ($extra -is [Collections.IDictionary]) {
            if ($extra.Contains('code')) { $code = [string]$extra.code }
            if ($extra.Contains('severity') -and -not [string]::IsNullOrWhiteSpace([string]$extra.severity)) { $severity = [string]$extra.severity }
        } else {
            $code = [string]$extra.code
            if ($null -ne $extra.PSObject.Properties['severity'] -and -not [string]::IsNullOrWhiteSpace([string]$extra.severity)) { $severity = [string]$extra.severity }
        }
        if (-not [string]::IsNullOrWhiteSpace($code)) {
            Add-TelephoneDashboardFinding -Findings $findings -Code $code -Severity $severity
        }
    }
    foreach ($job in @($Jobs)) {
        foreach ($finding in @($job.findings)) { Add-TelephoneDashboardFinding -Findings $findings -Code ([string]$finding.code) -Severity ([string]$finding.severity) }
        foreach ($row in @($job.events)) {
            if (Test-TelephoneDashboardMalformedRow -Row $row) {
                $eventCode = 'MALFORMED_EVIDENCE'
                if ($row.Contains('error') -and -not [string]::IsNullOrWhiteSpace([string]$row.error) -and [string]$row.error -cne 'missing') {
                    $eventCode = [string]$row.error
                }
                Add-TelephoneDashboardFinding -Findings $findings -Code $eventCode
            }
        }
    }
    foreach ($run in @($Runs)) {
        foreach ($finding in @($run.findings)) { Add-TelephoneDashboardFinding -Findings $findings -Code ([string]$finding.code) -Severity ([string]$finding.severity) }
    }

    $reducerEvents = [Collections.Generic.List[object]]::new()
    if (@($Events).Count -gt 0) {
        foreach ($event in @($Events)) { [void]$reducerEvents.Add($event) }
    } else {
        $seedJob = ''
        $seedSession = $SessionId
        foreach ($job in @($Jobs)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$job.job_id)) { $seedJob = [string]$job.job_id }
            if ([string]::IsNullOrWhiteSpace($seedSession) -and -not [string]::IsNullOrWhiteSpace([string]$job.session_id)) { $seedSession = [string]$job.session_id }
        }
        foreach ($run in @($Runs)) {
            if ([string]::IsNullOrWhiteSpace($seedSession) -and -not [string]::IsNullOrWhiteSpace([string]$run.session_id)) { $seedSession = [string]$run.session_id }
            if ([string]::IsNullOrWhiteSpace($seedJob) -and -not [string]::IsNullOrWhiteSpace([string]$run.run_id)) { $seedJob = [string]$run.run_id }
        }
        if (-not [string]::IsNullOrWhiteSpace($seedSession) -and -not [string]::IsNullOrWhiteSpace($seedJob)) {
            [void]$reducerEvents.Add((New-TelephoneDashboardReducerEvent -Kind 'lead' -LeadId $seedSession -SessionId $seedSession -JobId $seedJob))
            $sawExecute = $false
            $sawReview = $false
            $sawSync = $false
            $sawOwnerAcceptance = $false
            foreach ($job in @($Jobs)) {
                if ([string]$job.role -ceq 'execution') { $sawExecute = $true }
                if ([string]$job.role -ceq 'review') { $sawReview = $true }
                if ([bool]$job.status.valid -and [string]$job.status.value.phase -ceq 'nested_target') { $sawSync = $true }
                if ([bool]$job.status.valid -and [string]$job.status.value.phase -ceq 'owner_acceptance') { $sawOwnerAcceptance = $true }
            }
            if ($sawExecute) { [void]$reducerEvents.Add((New-TelephoneDashboardReducerEvent -Kind 'execute' -LeadId $seedSession -SessionId $seedSession -JobId $seedJob)) }
            if ($sawSync) { [void]$reducerEvents.Add((New-TelephoneDashboardReducerEvent -Kind 'sync' -LeadId $seedSession -SessionId $seedSession -JobId $seedJob)) }
            if ($sawOwnerAcceptance -or $sawReview) {
                [void]$reducerEvents.Add((New-TelephoneDashboardReducerEvent -Kind 'review' -LeadId $seedSession -SessionId $seedSession -JobId $seedJob))
            }
            if ($null -ne $Closure -and [bool]$Closure.valid) {
                if (-not $sawExecute) {
                    [void]$reducerEvents.Add((New-TelephoneDashboardReducerEvent -Kind 'execute' -LeadId $seedSession -SessionId $seedSession -JobId $seedJob))
                    Add-TelephoneDashboardFinding -Findings $findings -Code 'SKIPPED_TRANSITION'
                }
                [void]$reducerEvents.Add((New-TelephoneDashboardReducerEvent -Kind 'closure' -LeadId $seedSession -SessionId $seedSession -JobId $seedJob))
                [void]$reducerEvents.Add((New-TelephoneDashboardReducerEvent -Kind 'commit_closure' -LeadId $seedSession -SessionId $seedSession -JobId $seedJob -Receipt ([string]$Closure.receipt_sha256)))
            }
        } elseif (@($Jobs).Count -gt 0 -or @($Runs).Count -gt 0) {
            Add-TelephoneDashboardFinding -Findings $findings -Code 'IDENTITY_INCOMPLETE'
        }
    }

    $reduced = Reduce-TelephoneDashboardEvents -Events @($reducerEvents)
    foreach ($code in @($reduced.rejected)) {
        Add-TelephoneDashboardFinding -Findings $findings -Code ([string]$code)
    }

    $liveOwner = $false
    $heldLock = $false
    foreach ($job in @($Jobs)) {
        if ([bool]$job.command_alive -or [bool]$job.relay_alive) { $liveOwner = $true }
        foreach ($finding in @($job.findings)) {
            if ([string]$finding.code -ceq 'HELD_LOCK') { $heldLock = $true }
        }
        if ([bool]$job.dispatch.valid -and -not [bool]$job.receipt.present) {
            Add-TelephoneDashboardFinding -Findings $findings -Code 'RECEIPT_MISSING'
        }
        if ([bool]$job.dispatch.valid -and [string]$job.session_id -cne $SessionId -and -not [string]::IsNullOrWhiteSpace($SessionId) -and -not [string]::IsNullOrWhiteSpace([string]$job.session_id)) {
            Add-TelephoneDashboardFinding -Findings $findings -Code 'BINDING_MISMATCH'
        }
    }
    foreach ($run in @($Runs)) {
        if ([bool]$run.owner_alive) { $liveOwner = $true }
        if ([string]$run.lead_status -ceq 'active') { $liveOwner = $true }
    }

    $leadIdle = $true
    if (@($Runs).Count -eq 0) {
        $leadIdle = ([string]$TerminalState -cin @('terminal', 'retired', 'idle')) -or (-not $liveOwner)
    } else {
        $leadIdle = $true
        foreach ($run in @($Runs)) {
            if ([string]$run.lead_status -cin @('active', 'systemError')) { $leadIdle = $false }
            if ([bool]$run.owner_alive) { $leadIdle = $false }
        }
        if ([string]$TerminalState -cin @('terminal', 'retired', 'idle')) { $leadIdle = $true }
    }

    $closureOk = $false
    $closureReceipt = [string]$reduced.closure_receipt
    if ($null -ne $Closure -and [bool]$Closure.valid) {
        $closureOk = $true
        $closureReceipt = [string]$Closure.receipt_sha256
        $matched = $false
        foreach ($job in @($Jobs)) {
            if ([bool]$job.receipt.valid -and [string]$job.receipt.identity.sha256 -ceq $closureReceipt) { $matched = $true }
        }
        if (-not $matched) {
            Add-TelephoneDashboardFinding -Findings $findings -Code 'RECEIPT_MISMATCH'
            $closureOk = $false
        }
    } elseif ([string]$reduced.phase -ceq 'closed' -and -not [string]::IsNullOrWhiteSpace($closureReceipt)) {
        $closureOk = $true
    }

    $projectTerminal = ([string]$TerminalState -cin @('terminal', 'retired'))
    if ([string]$reduced.phase -ceq 'closed' -and -not $projectTerminal) {
        Add-TelephoneDashboardFinding -Findings $findings -Code 'WRONG_TERMINAL'
    }

    if ([int]$reduced.duplicate_count -gt 0) {
        $ambiguousDup = $false
        foreach ($code in @($reduced.rejected)) {
            if ([string]$code -ceq 'DUPLICATE_AMBIGUOUS') { $ambiguousDup = $true }
        }
        if (-not $ambiguousDup) {
            Add-TelephoneDashboardFinding -Findings $findings -Code 'DUPLICATE_SAME_PROVENANCE' -Severity 'info'
        }
    }

    $failClosed = $false
    foreach ($finding in $findings) {
        if ([string]$finding.severity -ceq 'fail_closed') { $failClosed = $true }
    }

    $canDisappear = (
        [bool]$reduced.dashboard_disappeared -and
        $closureOk -and
        $projectTerminal -and
        $leadIdle -and
        (-not $liveOwner) -and
        (-not $heldLock) -and
        (-not $failClosed)
    )
    if ([bool]$reduced.dashboard_disappeared -and -not $canDisappear) {
        $reduced.dashboard_visible = $true
        $reduced.dashboard_disappeared = $false
        if (-not $closureOk) { Add-TelephoneDashboardFinding -Findings $findings -Code 'CLOSURE_RECEIPT_MISSING' }
        if (-not $projectTerminal) { Add-TelephoneDashboardFinding -Findings $findings -Code 'WRONG_TERMINAL' }
        if ($liveOwner) { Add-TelephoneDashboardFinding -Findings $findings -Code 'PROCESS_RESIDUE' }
        if ($heldLock) { Add-TelephoneDashboardFinding -Findings $findings -Code 'HELD_LOCK' }
        if (-not $leadIdle) { Add-TelephoneDashboardFinding -Findings $findings -Code 'STALE_ACTIVE' }
        foreach ($finding in $findings) {
            if ([string]$finding.severity -ceq 'fail_closed') { $failClosed = $true }
        }
    }

    $visible = [bool]$reduced.dashboard_visible
    if (-not $canDisappear -and (@($Jobs).Count -gt 0 -or @($Runs).Count -gt 0 -or [string]$reduced.phase -cne 'idle' -or $failClosed)) {
        $visible = $true
    }
    if ($canDisappear) { $visible = $false }

    $color = 'hidden'
    if ($canDisappear) {
        $color = 'hidden'
        $visible = $false
    } elseif ($failClosed) {
        $color = 'yellow'
        $visible = $true
    } elseif ($visible) {
        $color = 'green'
    } else {
        $color = 'yellow'
        $visible = $true
    }

    $phase = [string]$reduced.phase
    $lineJobId = ''
    $stage = ''
    $role = ''
    $route = ''
    $provenance = ''
    if ($reduced.Contains('last_provenance') -and -not [string]::IsNullOrWhiteSpace([string]$reduced.last_provenance)) {
        $provenance = [string]$reduced.last_provenance
    }
    $duplicateCount = [int]$reduced.duplicate_count
    $finalAudit = $false
    $correction = $false
    foreach ($job in @($Jobs)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$job.job_id)) { $lineJobId = [string]$job.job_id }
        if ($job -is [Collections.IDictionary] -and $job.Contains('stage') -and -not [string]::IsNullOrWhiteSpace([string]$job.stage)) { $stage = [string]$job.stage }
        if (-not [string]::IsNullOrWhiteSpace([string]$job.role)) { $role = [string]$job.role }
        if ($job -is [Collections.IDictionary] -and $job.Contains('route') -and -not [string]::IsNullOrWhiteSpace([string]$job.route)) { $route = [string]$job.route }
        if (Test-TelephoneDashboardExactAuditEvidence -Job $job) { $finalAudit = $true }
        if (Test-TelephoneDashboardExactCorrectionEvidence -Job $job) { $correction = $true }
        foreach ($row in @($job.events)) {
            if ($null -eq $row -or (Test-TelephoneDashboardMalformedRow -Row $row)) { continue }
            if ($row -is [Collections.IDictionary] -and $row.Contains('duplicate_count')) {
                try {
                    $rowDup = [int]$row.duplicate_count
                    if ($rowDup -gt $duplicateCount) { $duplicateCount = $rowDup }
                } catch { }
            }
            if ($null -ne $row.provenance -and -not [string]::IsNullOrWhiteSpace([string]$row.provenance.sha256)) {
                $provenance = [string]$row.provenance.sha256
            }
        }
    }
    foreach ($event in @($Events)) {
        if ($null -eq $event) { continue }
        if ($event -is [Collections.IDictionary] -and $event.Contains('provenance') -and -not [string]::IsNullOrWhiteSpace([string]$event.provenance)) {
            $provenance = [string]$event.provenance
        }
    }
    return (New-TelephoneDashboardObservedGroup `
        -Project $Project `
        -SessionId $(if ([string]::IsNullOrWhiteSpace($SessionId)) { [string]$reduced.session_id } else { $SessionId }) `
        -RunId $RunId `
        -Phase $phase `
        -Visible ([bool]$visible) `
        -Disappeared ([bool]$canDisappear) `
        -Color $color `
        -Lead ($phase -cin @('lead', 'execute', 'review', 'sync', 'modify', 'closure', 'closed') -or @($Runs).Count -gt 0) `
        -Execution ($phase -cin @('execute', 'review', 'sync', 'modify', 'closure', 'closed') -or $role -ceq 'execution') `
        -FinalAudit $finalAudit `
        -Correction $correction `
        -Closure ($phase -cin @('closure', 'closed')) `
        -Terminal ([bool]$canDisappear) `
        -ClosureReceipt $closureReceipt `
        -Findings @($findings) `
        -LineJobId $lineJobId `
        -Stage $stage `
        -Role $role `
        -Route $route `
        -DuplicateCount $duplicateCount `
        -Provenance $provenance `
        -SupervisorRunId $SupervisorRunId `
        -SupervisorStatus $SupervisorStatus `
        -PausedByPascal $PausedByPascal `
        -HasSupervisorEvidence:$HasSupervisorEvidence)
}

function Test-TelephoneDashboardExactSuccessorJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][object]$Descriptor
    )
    if ($null -eq $Candidate) { return $false }
    if (-not [bool]$Candidate.binding.valid) { return $false }
    if (-not [bool]$Candidate.delivery) { return $false }
    $project = [string]$Descriptor.project
    if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.project) -and [string]$Candidate.project -cne $project -and $project -cne 'state-root') {
        return $false
    }
    $succSession = if ($Descriptor.Contains('successor_lead_session_id')) { [string]$Descriptor.successor_lead_session_id } else { '' }
    $succJob = if ($Descriptor.Contains('successor_line_job_id')) { [string]$Descriptor.successor_line_job_id } else { '' }
    $succRun = if ($Descriptor.Contains('successor_lead_run_id')) { [string]$Descriptor.successor_lead_run_id } else { '' }
    if ([string]::IsNullOrWhiteSpace($succSession) -and [string]::IsNullOrWhiteSpace($succJob) -and [string]::IsNullOrWhiteSpace($succRun)) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($succSession) -and [string]$Candidate.session_id -cne $succSession) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($succJob) -and [string]$Candidate.job_id -cne $succJob) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($succRun) -and [string]$Candidate.job_id -cne $succRun -and [string]$Candidate.session_id -cne $succRun) { return $false }
    return $true
}

function Test-TelephoneDashboardSupersededFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$AllJobs,
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [string]$StateRoot,
        [AllowNull()][object]$Closure
    )
    $failureLineage = [bool]$Job.receipt.present -and -not [bool]$Job.delivery -and [bool]$Job.relay_error
    if (-not $failureLineage) { return $false }

    $terminalState = if ($Descriptor.Contains('terminal_state')) { [string]$Descriptor.terminal_state } else { 'active' }
    $terminalProof = $false
    if ($terminalState -cin @('terminal', 'retired')) {
        $closurePath = Join-Path $StateRoot 'closure.json'
        $statusRetired = $false
        if ([bool]$Job.status.valid) {
            $phase = [string]$Job.status.value.phase
            if ($phase -cin @('retired', 'delivered', 'failed')) { $statusRetired = $true }
        }
        if ($null -ne $Closure -and [bool]$Closure.valid) { $terminalProof = $true }
        elseif ([IO.File]::Exists($closurePath)) { $terminalProof = $true }
        elseif ($statusRetired -and $terminalState -cin @('terminal', 'retired')) { $terminalProof = $true }
    }
    $hasExactSuccessor = $false
    foreach ($other in @($AllJobs)) {
        if ([string]$other.job_root -ceq [string]$Job.job_root) { continue }
        if (Test-TelephoneDashboardExactSuccessorJob -Candidate $other -Descriptor $Descriptor) {
            $hasExactSuccessor = $true
            break
        }
    }
    $succBound = ($Descriptor.Contains('successor_lead_session_id') -and -not [string]::IsNullOrWhiteSpace([string]$Descriptor.successor_lead_session_id)) -or
        ($Descriptor.Contains('successor_line_job_id') -and -not [string]::IsNullOrWhiteSpace([string]$Descriptor.successor_line_job_id)) -or
        ($Descriptor.Contains('successor_lead_run_id') -and -not [string]::IsNullOrWhiteSpace([string]$Descriptor.successor_lead_run_id))
    if ($succBound -and -not $hasExactSuccessor) { return $false }
    if ($terminalState -cin @('terminal', 'retired') -and -not $terminalProof -and -not $hasExactSuccessor) { return $false }
    return ($hasExactSuccessor -or $terminalProof)
}

function Get-TelephoneDashboardPairedDirectJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [AllowNull()][hashtable]$DirectByJobId
    )
    if ([bool]$Job.direct_route) { return $Job }
    $jobId = [string]$Job.job_id
    if ([string]::IsNullOrWhiteSpace($jobId) -or $null -eq $DirectByJobId -or -not $DirectByJobId.Contains($jobId)) { return $null }
    return $DirectByJobId[$jobId]
}

function Get-TelephoneDashboardJobDirectSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [AllowNull()][hashtable]$DirectByJobId
    )
    $sid = Get-TelephoneDashboardMapText -Map $Job -Name 'direct_session_id'
    if (-not [string]::IsNullOrWhiteSpace($sid)) { return $sid }
    $paired = Get-TelephoneDashboardPairedDirectJob -Job $Job -DirectByJobId $DirectByJobId
    if ($null -ne $paired -and -not [object]::ReferenceEquals($paired, $Job)) {
        return Get-TelephoneDashboardMapText -Map $paired -Name 'direct_session_id'
    }
    if ([bool]$Job.direct_route) { return [string]$Job.session_id }
    return ''
}

function Get-TelephoneDashboardDescriptorExactJobIds {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Descriptor)
    $ids = [Collections.Generic.List[string]]::new()
    foreach ($name in @('successor_line_job_id', 'current_line_job_id', 'successor_direct_job_id', 'current_direct_job_id')) {
        $value = Get-TelephoneDashboardMapText -Map $Descriptor -Name $name
        if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$ids.Add($value) }
    }
    return @($ids)
}

function Test-TelephoneDashboardJobMatchesDescriptorLineage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [AllowNull()][hashtable]$TelephoneByJobId,
        [AllowNull()][hashtable]$DirectByJobId
    )
    $descProject = Get-TelephoneDashboardMapText -Map $Descriptor -Name 'project'
    $jobProject = [string]$Job.project
    $jobId = [string]$Job.job_id
    if ([string]::IsNullOrWhiteSpace($jobProject) -and -not [string]::IsNullOrWhiteSpace($jobId) -and $null -ne $TelephoneByJobId -and $TelephoneByJobId.Contains($jobId)) {
        $jobProject = [string]$TelephoneByJobId[$jobId].project
    }
    if (-not [string]::IsNullOrWhiteSpace($jobProject) -and -not [string]::IsNullOrWhiteSpace($descProject) -and $descProject -cne 'state-root' -and $jobProject -cne $descProject) {
        return $false
    }
    $filterSession = Get-TelephoneDashboardMapText -Map $Descriptor -Name 'lead_session_id'
    $succSession = Get-TelephoneDashboardMapText -Map $Descriptor -Name 'successor_lead_session_id'
    $correlated = Get-TelephoneDashboardCorrelatedLeadSession -Job $Job -TelephoneByJobId $TelephoneByJobId -Descriptor $Descriptor -FilterSession $filterSession
    $leadBound = (-not [string]::IsNullOrWhiteSpace($filterSession) -or -not [string]::IsNullOrWhiteSpace($succSession))
    if ($leadBound) {
        if (-not [string]::IsNullOrWhiteSpace($filterSession) -and $correlated -ceq $filterSession) { return $true }
        if (-not [string]::IsNullOrWhiteSpace($succSession) -and $correlated -ceq $succSession) { return $true }
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($jobId) -and $null -ne $TelephoneByJobId -and $TelephoneByJobId.Contains($jobId)) {
        return $true
    }
    return $false
}

function Test-TelephoneDashboardDirectPackageOwner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$AllJobs,
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [AllowNull()][hashtable]$DirectByJobId,
        [AllowNull()][hashtable]$TelephoneByJobId
    )
    $paired = Get-TelephoneDashboardPairedDirectJob -Job $Job -DirectByJobId $DirectByJobId
    if ($null -eq $paired) { return $false }
    $receiptValue = $null
    if ([bool]$paired.receipt.valid) { $receiptValue = $paired.receipt.value }
    if (-not (Test-TelephoneDashboardDirectReceiptSuccess -Receipt $receiptValue)) { return $false }
    $session = Get-TelephoneDashboardJobDirectSession -Job $paired -DirectByJobId $DirectByJobId
    if ([string]::IsNullOrWhiteSpace($session)) { return $false }
    $authority = Get-TelephoneDashboardDirectRouteAuthority -Descriptor $Descriptor
    foreach ($retired in @($authority.retired_session_ids)) {
        if ($session -ceq [string]$retired) { return $false }
    }
    if (-not (Test-TelephoneDashboardJobMatchesDescriptorLineage -Job $Job -Descriptor $Descriptor -TelephoneByJobId $TelephoneByJobId -DirectByJobId $DirectByJobId)) {
        return $false
    }
    $resume = Get-TelephoneDashboardMapFlag -Map $paired -Name 'direct_resume'
    $pairedJobId = [string]$paired.job_id
    if (-not $resume) { return $true }
    $exactJob = $false
    foreach ($exactId in @(Get-TelephoneDashboardDescriptorExactJobIds -Descriptor $Descriptor)) {
        if (-not [string]::IsNullOrWhiteSpace($pairedJobId) -and $pairedJobId -ceq [string]$exactId) { $exactJob = $true; break }
    }
    if (-not $exactJob) { return $false }
    foreach ($other in @($AllJobs)) {
        $otherPaired = Get-TelephoneDashboardPairedDirectJob -Job $other -DirectByJobId $DirectByJobId
        if ($null -eq $otherPaired) { continue }
        if ([string]$otherPaired.job_root -ceq [string]$paired.job_root) { continue }
        if (Get-TelephoneDashboardMapFlag -Map $otherPaired -Name 'direct_resume') { continue }
        $otherReceipt = $null
        if ([bool]$otherPaired.receipt.valid) { $otherReceipt = $otherPaired.receipt.value }
        if (-not (Test-TelephoneDashboardDirectReceiptSuccess -Receipt $otherReceipt)) { continue }
        if (-not (Test-TelephoneDashboardJobMatchesDescriptorLineage -Job $other -Descriptor $Descriptor -TelephoneByJobId $TelephoneByJobId -DirectByJobId $DirectByJobId)) {
            continue
        }
        $otherSession = Get-TelephoneDashboardJobDirectSession -Job $otherPaired -DirectByJobId $DirectByJobId
        if ($otherSession -ceq $session) { return $true }
    }
    return $false
}

function Test-TelephoneDashboardDirectHistoryRetired {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$AllJobs,
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [AllowNull()][hashtable]$DirectByJobId,
        [AllowEmptyCollection()][string[]]$ProofJobIds = @(),
        [AllowEmptyCollection()][string[]]$ProofDirectSessions = @()
    )
    $proofJobSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in @($ProofJobIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) { [void]$proofJobSet.Add([string]$id) }
    }
    $proofSessionSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($sid in @($ProofDirectSessions)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$sid)) { [void]$proofSessionSet.Add([string]$sid) }
    }
    if ($proofJobSet.Count -eq 0 -and $proofSessionSet.Count -eq 0) { return $false }
    $jobId = [string]$Job.job_id
    if (-not [string]::IsNullOrWhiteSpace($jobId) -and $proofJobSet.Contains($jobId)) { return $false }
    foreach ($exactId in @(Get-TelephoneDashboardDescriptorExactJobIds -Descriptor $Descriptor)) {
        if (-not [string]::IsNullOrWhiteSpace($jobId) -and $jobId -ceq [string]$exactId) { return $false }
    }
    $directSession = Get-TelephoneDashboardJobDirectSession -Job $Job -DirectByJobId $DirectByJobId
    $authority = Get-TelephoneDashboardDirectRouteAuthority -Descriptor $Descriptor
    $sessionRetired = $false
    foreach ($retired in @($authority.retired_session_ids)) {
        if (-not [string]::IsNullOrWhiteSpace($directSession) -and $directSession -ceq [string]$retired) { $sessionRetired = $true; break }
    }
    $onProofSession = (-not [string]::IsNullOrWhiteSpace($directSession) -and $proofSessionSet.Contains($directSession) -and -not $sessionRetired)
    $supersededByExactSuccessor = $false
    foreach ($exactId in @(Get-TelephoneDashboardDescriptorExactJobIds -Descriptor $Descriptor)) {
        if ([string]::IsNullOrWhiteSpace([string]$exactId) -or [string]$exactId -ceq $jobId) { continue }
        $exactOnProvenSession = $proofJobSet.Contains([string]$exactId)
        if (-not $exactOnProvenSession) {
            foreach ($other in @($AllJobs)) {
                if ([string]$other.job_id -cne [string]$exactId) { continue }
                $otherSession = Get-TelephoneDashboardJobDirectSession -Job $other -DirectByJobId $DirectByJobId
                if (-not [string]::IsNullOrWhiteSpace($otherSession) -and $proofSessionSet.Contains($otherSession)) {
                    $otherRetired = $false
                    foreach ($retiredSid in @($authority.retired_session_ids)) {
                        if ($otherSession -ceq [string]$retiredSid) { $otherRetired = $true; break }
                    }
                    if (-not $otherRetired) { $exactOnProvenSession = $true }
                }
                break
            }
        }
        if ($exactOnProvenSession) { $supersededByExactSuccessor = $true; break }
    }
    $paired = Get-TelephoneDashboardPairedDirectJob -Job $Job -DirectByJobId $DirectByJobId
    if ($null -eq $paired) { return $false }
    $failed = $false
    if ([bool]$paired.receipt.valid) { $failed = Test-TelephoneDashboardDirectReceiptFailed -Receipt $paired.receipt.value }
    $noReceipt = -not [bool]$paired.receipt.present
    $stale = (-not [bool]$paired.command_alive) -and $noReceipt
    if ($onProofSession -and $supersededByExactSuccessor) { return $true }
    if (-not ($sessionRetired -or $failed -or $noReceipt -or $stale)) { return $false }
    if ($sessionRetired) { return $true }
    if (-not $onProofSession) { return $true }
    return $false
}

function Get-TelephoneDashboardCorrelatedLeadSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [AllowNull()][hashtable]$TelephoneByJobId,
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [string]$FilterSession = ''
    )
    if (-not [bool]$Job.direct_route) { return [string]$Job.session_id }
    $jobId = [string]$Job.job_id
    if (-not [string]::IsNullOrWhiteSpace($jobId) -and $null -ne $TelephoneByJobId -and $TelephoneByJobId.Contains($jobId)) {
        return [string]$TelephoneByJobId[$jobId].session_id
    }
    $succJob = Get-TelephoneDashboardMapText -Map $Descriptor -Name 'successor_line_job_id'
    $succRun = Get-TelephoneDashboardMapText -Map $Descriptor -Name 'successor_lead_run_id'
    $filterRun = Get-TelephoneDashboardMapText -Map $Descriptor -Name 'lead_run_id'
    $bound = $false
    if (-not [string]::IsNullOrWhiteSpace($jobId)) {
        if ($jobId -ceq $succJob -or $jobId -ceq $succRun -or $jobId -ceq $filterRun) { $bound = $true }
    }
    if ($bound) {
        $succSession = Get-TelephoneDashboardMapText -Map $Descriptor -Name 'successor_lead_session_id'
        if (-not [string]::IsNullOrWhiteSpace($succSession)) { return $succSession }
        if (-not [string]::IsNullOrWhiteSpace($FilterSession)) { return $FilterSession }
    }
    return [string]$Job.session_id
}

function Get-TelephoneDashboardSupervisorScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )
    $paused = $false
    $shared = [Collections.Generic.List[object]]::new()
    $records = [Collections.Generic.List[object]]::new()
    $supRoot = ''
    if ($Descriptor -is [Collections.IDictionary] -and $Descriptor.Contains('supervisor_state_root') -and -not [string]::IsNullOrWhiteSpace([string]$Descriptor.supervisor_state_root)) {
        $supRoot = [string]$Descriptor.supervisor_state_root
    } else {
        $supRoot = Join-Path $StateRoot 'supervisor'
    }
    if (-not [IO.Directory]::Exists($supRoot) -and -not [IO.File]::Exists($supRoot)) {
        return [ordered]@{ paused = $false; shared_findings = @(); records = @() }
    }
    $probe = Test-TelephoneDashboardConfiguredDirectory -Path $supRoot -Label 'Supervisor state'
    if (-not [bool]$probe.ok) {
        Add-TelephoneDashboardFinding -Findings $shared -Code $(if ([string]::IsNullOrWhiteSpace([string]$probe.error)) { 'UNREADABLE_EVIDENCE' } else { [string]$probe.error })
        return [ordered]@{ paused = $false; shared_findings = @($shared); records = @() }
    }
    $root = [string]$probe.path
    $pausePath = Join-Path (Join-Path $root 'control') 'pause.json'
    if ([IO.File]::Exists($pausePath)) {
        $pauseRead = Read-TelephoneDashboardOptionalJson -Path $pausePath
        if ([bool]$pauseRead.valid -and $pauseRead.value -is [Collections.IDictionary] -and $pauseRead.value.Contains('paused_by_pascal') -and [bool]$pauseRead.value.paused_by_pascal) {
            $paused = $true
            Add-TelephoneDashboardFinding -Findings $shared -Code 'SUPERVISOR_PAUSED'
        } elseif ([bool]$pauseRead.present -and -not [bool]$pauseRead.valid) {
            $code = $(if ([string]$pauseRead.error -ceq 'REPARSE_POINT') { 'REPARSE_POINT' } elseif ([string]$pauseRead.error -ceq 'PATH_ESCAPE') { 'PATH_ESCAPE' } else { 'MALFORMED_EVIDENCE' })
            Add-TelephoneDashboardFinding -Findings $shared -Code $code
        }
    }
    $seen = @{}
    foreach ($kind in @('inbox', 'claimed', 'outbox')) {
        $dir = Join-Path $root $kind
        if (-not [IO.Directory]::Exists($dir)) { continue }
        if (Test-TelephoneDashboardPathReparse -Path $dir) {
            Add-TelephoneDashboardFinding -Findings $shared -Code 'REPARSE_POINT'
            continue
        }
        foreach ($file in @([IO.Directory]::EnumerateFiles($dir, '*.json'))) {
            $schemaName = if ([string]$kind -cin @('inbox', 'claimed')) { 'wired-supervisor-request' } else { '' }
            $read = if (-not [string]::IsNullOrWhiteSpace($schemaName)) {
                Read-TelephoneDashboardOptionalJson -Path $file -SchemaName $schemaName
            } else {
                Read-TelephoneDashboardOptionalJson -Path $file
            }
            if (-not [bool]$read.valid) {
                $code = $(if ([string]$read.error -ceq 'REPARSE_POINT') { 'REPARSE_POINT' } else { 'MALFORMED_EVIDENCE' })
                Add-TelephoneDashboardFinding -Findings $shared -Code $code
                continue
            }
            $value = $read.value
            if ($value -isnot [Collections.IDictionary]) {
                Add-TelephoneDashboardFinding -Findings $shared -Code 'MALFORMED_EVIDENCE'
                continue
            }
            if ([string]$kind -ceq 'outbox') {
                $proto = if ($value.Contains('protocol_version')) { [string]$value.protocol_version } else { '' }
                $term = if ($value.Contains('terminal')) { [string]$value.terminal } else { '' }
                if ($proto -cne 'telephone-line-wired-supervisor-outbox-v1' -or $term -cnotin @('completed', 'failed', 'cancelled') -or -not $value.Contains('run_id')) {
                    Add-TelephoneDashboardFinding -Findings $shared -Code 'MALFORMED_EVIDENCE'
                    continue
                }
            }
            $runId = if ($value -is [Collections.IDictionary] -and $value.Contains('run_id')) { [string]$value.run_id } else { [IO.Path]::GetFileNameWithoutExtension($file) }
            $hash = if ($value -is [Collections.IDictionary] -and $value.Contains('request_sha256')) { [string]$value.request_sha256 } else { '' }
            $status = [string]$kind
            if ($kind -ceq 'outbox' -and $value.Contains('terminal')) { $status = [string]$value.terminal }
            if ($seen.Contains($runId) -and [string]$seen[$runId].hash -cne $hash -and -not [string]::IsNullOrWhiteSpace($hash) -and -not [string]::IsNullOrWhiteSpace([string]$seen[$runId].hash)) {
                Add-TelephoneDashboardFinding -Findings $shared -Code 'SUPERVISOR_DUPLICATE'
            }
            $seen[$runId] = [ordered]@{ hash = $hash; kind = $kind }
            [void]$records.Add([ordered]@{
                run_id = $runId
                project = $(if ($value.Contains('project')) { [string]$value.project } else { '' })
                stage = $(if ($value.Contains('stage')) { [string]$value.stage } else { '' })
                lead_session_id = $(if ($value.Contains('lead_session_id')) { [string]$value.lead_session_id } else { '' })
                lead_run_id = $(if ($value.Contains('lead_run_id')) { [string]$value.lead_run_id } else { '' })
                status = $status
                terminal = $(if ($value.Contains('terminal')) { [string]$value.terminal } else { '' })
                error_code = $(if ($value.Contains('error_code')) { [string]$value.error_code } else { '' })
                findings = @()
                matched = $false
            })
        }
    }
    $runsDir = Join-Path $root 'runs'
    if ([IO.Directory]::Exists($runsDir) -and -not (Test-TelephoneDashboardPathReparse -Path $runsDir)) {
        foreach ($dir in @([IO.Directory]::EnumerateDirectories($runsDir))) {
            $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
            if ($null -eq $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $ownerPath = Join-Path $dir 'owner.json'
            if (-not [IO.File]::Exists($ownerPath)) { continue }
            $ownerRead = Read-TelephoneDashboardOptionalJson -Path $ownerPath -SchemaName 'wired-supervisor-owner'
            if (-not [bool]$ownerRead.valid) {
                Add-TelephoneDashboardFinding -Findings $shared -Code $(if ([string]$ownerRead.error -ceq 'REPARSE_POINT') { 'REPARSE_POINT' } else { 'MALFORMED_EVIDENCE' })
                continue
            }
            $owner = $ownerRead.value
            if ($owner -isnot [Collections.IDictionary]) {
                Add-TelephoneDashboardFinding -Findings $shared -Code 'MALFORMED_EVIDENCE'
                continue
            }
            $runId = if ($owner.Contains('run_id')) { [string]$owner.run_id } else { [string]$item.Name }
            $alive = $false
            $pidReuse = $false
            try {
                if ($owner.Contains('pid') -and $owner.Contains('start_time_utc_ticks')) {
                    $proc = Get-Process -Id ([int]$owner.pid) -ErrorAction SilentlyContinue
                    if ($null -ne $proc) {
                        try {
                            if ([int64]$proc.StartTime.ToUniversalTime().Ticks -eq [int64]$owner.start_time_utc_ticks) {
                                $alive = $true
                            } else {
                                $pidReuse = $true
                            }
                        } finally { $proc.Dispose() }
                    }
                }
            } catch { }
            $outboxPath = Join-Path (Join-Path $root 'outbox') ($runId + '.json')
            $status = 'active'
            $findings = [Collections.Generic.List[object]]::new()
            if ($pidReuse) {
                $status = 'orphan'
                Add-TelephoneDashboardFinding -Findings $findings -Code 'SUPERVISOR_PID_REUSE'
            } elseif (-not $alive -and -not [IO.File]::Exists($outboxPath)) {
                $status = 'orphan'
                Add-TelephoneDashboardFinding -Findings $findings -Code 'SUPERVISOR_ORPHAN'
            }
            if ($owner.Contains('installed_version') -and $owner.installed_version -is [Collections.IDictionary] -and $owner.installed_version.Contains('version_id')) {
                $pointerPath = Join-Path ([IO.Path]::GetDirectoryName($root)) 'current.json'
                # version pointer lives on install root, not supervisor state; skip unless sibling current exists
            }
            [void]$records.Add([ordered]@{
                run_id = $runId
                project = $(if ($owner.Contains('project')) { [string]$owner.project } else { '' })
                stage = $(if ($owner.Contains('stage')) { [string]$owner.stage } else { '' })
                lead_session_id = $(if ($owner.Contains('lead_session_id')) { [string]$owner.lead_session_id } else { '' })
                lead_run_id = $(if ($owner.Contains('lead_run_id')) { [string]$owner.lead_run_id } else { '' })
                status = $status
                findings = @($findings)
                version_id = $(if ($owner.Contains('installed_version') -and $owner.installed_version.Contains('version_id')) { [string]$owner.installed_version.version_id } else { '' })
                matched = $false
            })
        }
    }
    $byId = @{}
    foreach ($row in @($records)) {
        $id = [string]$row.run_id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ($byId.Contains($id)) {
            $existing = $byId[$id]
            if (-not [string]::IsNullOrWhiteSpace([string]$row.status) -and [string]$row.status -cne [string]$existing.status) {
                if ([string]$row.status -cin @('cancelled', 'failed', 'completed', 'orphan')) { $existing.status = [string]$row.status }
            }
            if ($row.Contains('findings')) {
                $merged = [Collections.Generic.List[object]]::new()
                foreach ($f in @($existing.findings) + @($row.findings)) { if ($null -ne $f) { [void]$merged.Add($f) } }
                $existing.findings = @($merged)
            }
        } else {
            if (-not $row.Contains('findings')) { $row.findings = @() }
            $byId[$id] = $row
        }
    }
    return [ordered]@{ paused = [bool]$paused; shared_findings = @($shared); records = @($byId.Values) }
}

function Get-TelephoneDashboardMailboxScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][string]$StateRoot
    )
    $records = [Collections.Generic.List[object]]::new()
    $leadsRoot = Join-Path $StateRoot 'leads'
    if (-not [IO.Directory]::Exists($leadsRoot)) { return @() }
    if (Test-TelephoneDashboardPathReparse -Path $leadsRoot) { return @() }
    $filterSession = Get-TelephoneDashboardMapText -Map $Descriptor -Name 'lead_session_id'
    foreach ($dir in @([IO.Directory]::EnumerateDirectories($leadsRoot))) {
        $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $session = ''
        $mailboxDir = Join-Path $dir 'mailbox'
        if ([IO.Directory]::Exists($mailboxDir) -and -not (Test-TelephoneDashboardPathReparse -Path $mailboxDir)) {
            foreach ($file in @([IO.Directory]::EnumerateFiles($mailboxDir, '*.json'))) {
                $read = Read-TelephoneDashboardOptionalJson -Path $file
                if (-not [bool]$read.valid -or $read.value -isnot [Collections.IDictionary]) { continue }
                $session = Get-TelephoneDashboardMapText -Map $read.value -Name 'lead_session_id'
                if (-not [string]::IsNullOrWhiteSpace($session)) { break }
            }
        }
        if ([string]::IsNullOrWhiteSpace($session)) { continue }
        if (-not [string]::IsNullOrWhiteSpace($filterSession) -and $session -cne $filterSession) { continue }
        $collecting = $false
        $truthPath = Join-Path $dir 'truth.json'
        if ([IO.File]::Exists($truthPath)) {
            $truth = Read-TelephoneDashboardOptionalJson -Path $truthPath
            if ([bool]$truth.valid -and $truth.value -is [Collections.IDictionary] -and $truth.value.Contains('batches')) {
                foreach ($batch in @($truth.value.batches)) {
                    if ($batch -isnot [Collections.IDictionary]) { continue }
                    $closed = $false
                    if ($batch.Contains('closed')) { $closed = [bool]$batch.closed }
                    $counted = 0
                    $n = 0
                    if ($batch.Contains('counted')) { try { $counted = [int]$batch.counted } catch { $counted = 0 } }
                    if ($batch.Contains('n')) { try { $n = [int]$batch.n } catch { $n = 0 } }
                    if (-not $closed -and $n -gt 0 -and $counted -lt $n) { $collecting = $true }
                }
            }
        }
        [void]$records.Add([ordered]@{
            lead_session_id = $session
            collecting = [bool]$collecting
        })
    }
    return @($records)
}

function Get-TelephoneDashboardProjection {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$StateRoot
    )

    $groups = [Collections.Generic.List[object]]::new()
    $configPresent = $false
    $descriptors = [Collections.Generic.List[object]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and [IO.File]::Exists($ConfigPath)) {
        $configPresent = $true
        $configSafety = Test-TelephoneCompletePathChain -Path $ConfigPath -RequireRegularFile -Label 'Dashboard config'
        if (-not [bool]$configSafety.ok) {
            $configCode = $(if ([string]::IsNullOrWhiteSpace([string]$configSafety.error)) { 'UNREADABLE_EVIDENCE' } else { [string]$configSafety.error })
            [void]$groups.Add((New-TelephoneDashboardObservedGroup -Project 'config' -Findings @([ordered]@{ code = $configCode; severity = 'fail_closed' })))
        } else {
            $config = Read-TelephoneDashboardOptionalJson -Path $ConfigPath -SchemaName 'dashboard-config'
            if ([bool]$config.valid) {
                foreach ($row in @($config.value.projects)) {
                    $descriptorPath = [string]$row.descriptor_file
                    $scan = Get-TelephoneDashboardDescriptorScan -DescriptorPath $descriptorPath
                    [void]$descriptors.Add($scan)
                }
            } else {
                $configCode = $(if ([string]$config.error -ceq 'REPARSE_POINT') { 'REPARSE_POINT' } elseif ([string]$config.error -ceq 'PATH_ESCAPE') { 'PATH_ESCAPE' } else { 'MALFORMED_EVIDENCE' })
                [void]$groups.Add((New-TelephoneDashboardObservedGroup -Project 'config' -Findings @([ordered]@{ code = $configCode; severity = 'fail_closed' })))
            }
        }
    }

    $implicitRoot = ''
    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        $implicitRoot = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_STATE_ROOT)) {
        $implicitRoot = [IO.Path]::GetFullPath([string]$env:TELEPHONE_LINE_STATE_ROOT).TrimEnd('\')
    }
    if (-not [string]::IsNullOrWhiteSpace($implicitRoot) -and $descriptors.Count -eq 0) {
        if ([IO.Directory]::Exists($implicitRoot) -or [IO.File]::Exists($implicitRoot)) {
            $implicitProbe = Test-TelephoneDashboardConfiguredDirectory -Path $implicitRoot -Label 'Implicit state root'
            if ([bool]$implicitProbe.ok) {
                [void]$descriptors.Add([ordered]@{
                    valid = $true
                    descriptor = [ordered]@{
                        protocol_version = 'telephone-line-dashboard-project-descriptor-v1'
                        project = 'state-root'
                        state_root = [string]$implicitProbe.path
                        terminal_state = 'active'
                    }
                    findings = @()
                    state_root = [string]$implicitProbe.path
                })
            } else {
                $impCode = $(if ([string]::IsNullOrWhiteSpace([string]$implicitProbe.error)) { 'UNREADABLE_EVIDENCE' } else { [string]$implicitProbe.error })
                [void]$groups.Add((New-TelephoneDashboardObservedGroup -Project 'state-root' -Findings @([ordered]@{ code = $impCode; severity = 'fail_closed' })))
            }
        }
    }

    foreach ($entry in $descriptors) {
        if (-not [bool]$entry.valid) {
            [void]$groups.Add((New-TelephoneDashboardObservedGroup `
                -Project $(if ($null -ne $entry.descriptor) { [string]$entry.descriptor.project } else { 'descriptor' }) `
                -Findings @($entry.findings)))
            continue
        }
        $descriptor = $entry.descriptor
        $root = [string]$entry.state_root
        $filterSession = if ($descriptor.Contains('lead_session_id')) { [string]$descriptor.lead_session_id } else { '' }
        $filterRun = if ($descriptor.Contains('lead_run_id')) { [string]$descriptor.lead_run_id } else { '' }
        $terminalState = if ($descriptor.Contains('terminal_state')) { [string]$descriptor.terminal_state } else { 'active' }
        if ($descriptor.Contains('current_state_file') -and -not [string]::IsNullOrWhiteSpace([string]$descriptor.current_state_file)) {
            [void]$groups.Add((Get-TelephoneDashboardCurrentStateGroup -Descriptor $descriptor))
            continue
        }
        $jobsRoot = Join-Path $root 'jobs'
        $runsRoot = Join-Path $root 'runs'
        $jobScans = [Collections.Generic.List[object]]::new()
        $runScans = [Collections.Generic.List[object]]::new()
        $entryFindings = [Collections.Generic.List[object]]::new()
        foreach ($existingFinding in @($entry.findings)) {
            Add-TelephoneDashboardFinding -Findings $entryFindings -Code ([string]$existingFinding.code) -Severity ([string]$existingFinding.severity)
        }
        $seenJobRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $jobRootList = [Collections.Generic.List[string]]::new()
        if ([IO.Directory]::Exists($jobsRoot) -or [IO.File]::Exists($jobsRoot)) {
            $jobsProbe = Test-TelephoneDashboardConfiguredDirectory -Path $jobsRoot -Label 'Telephone jobs root'
            if (-not [bool]$jobsProbe.ok) {
                Add-TelephoneDashboardFinding -Findings $entryFindings -Code $(if ([string]::IsNullOrWhiteSpace([string]$jobsProbe.error)) { 'UNREADABLE_EVIDENCE' } else { [string]$jobsProbe.error })
            } else {
                [void]$jobRootList.Add([string]$jobsProbe.path)
            }
        }
        $rawDirectRoots = @()
        if ($descriptor -is [Collections.IDictionary] -and $descriptor.Contains('direct_job_roots')) {
            $rawDirectRoots = @($descriptor['direct_job_roots'])
        } elseif ($null -ne $descriptor.PSObject.Properties['direct_job_roots']) {
            $rawDirectRoots = @($descriptor.direct_job_roots)
        }
        $seenDirectRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($rawRoot in @($rawDirectRoots)) {
            $probe = Test-TelephoneDashboardConfiguredDirectory -Path ([string]$rawRoot) -Label 'Direct job root'
            if (-not [bool]$probe.ok) {
                Add-TelephoneDashboardFinding -Findings $entryFindings -Code $(if ([string]::IsNullOrWhiteSpace([string]$probe.error)) { 'UNREADABLE_EVIDENCE' } else { [string]$probe.error })
                continue
            }
            $fullDirect = [string]$probe.path
            if (-not $seenDirectRoots.Add($fullDirect)) { continue }
            if ($jobRootList.Count -ge [int]$script:TelephoneDashboardMaxConfiguredJobRoots) {
                Add-TelephoneDashboardFinding -Findings $entryFindings -Code 'UNREADABLE_EVIDENCE'
                continue
            }
            [void]$jobRootList.Add($fullDirect)
        }
        $sessionEventsRoot = Get-TelephoneDashboardSessionEventsRoot -Descriptor $descriptor
        if (-not [string]::IsNullOrWhiteSpace($sessionEventsRoot)) {
            $sessionProbe = Test-TelephoneDashboardConfiguredDirectory -Path $sessionEventsRoot -Label 'Session events root'
            if (-not [bool]$sessionProbe.ok) {
                Add-TelephoneDashboardFinding -Findings $entryFindings -Code $(if ([string]::IsNullOrWhiteSpace([string]$sessionProbe.error)) { 'UNREADABLE_EVIDENCE' } else { [string]$sessionProbe.error })
            }
        }
        foreach ($scanRoot in @($jobRootList)) {
            if (-not [IO.Directory]::Exists($scanRoot)) { continue }
            if (Test-TelephoneDashboardPathReparse -Path $scanRoot) {
                Add-TelephoneDashboardFinding -Findings $entryFindings -Code 'REPARSE_POINT'
                continue
            }
            $childDirs = @()
            try {
                $childDirs = @(Get-ChildItem -LiteralPath $scanRoot -Directory -Force -ErrorAction Stop | Sort-Object Name)
            } catch {
                Add-TelephoneDashboardFinding -Findings $entryFindings -Code 'UNREADABLE_EVIDENCE'
                continue
            }
            foreach ($dir in $childDirs) {
                try {
                    if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        Add-TelephoneDashboardFinding -Findings $entryFindings -Code 'REPARSE_POINT'
                        continue
                    }
                } catch {
                    Add-TelephoneDashboardFinding -Findings $entryFindings -Code 'UNREADABLE_EVIDENCE'
                    continue
                }
                $fullJob = [IO.Path]::GetFullPath($dir.FullName).TrimEnd('\')
                if (-not $seenJobRoots.Add($fullJob)) { continue }
                $dispatchPath = Join-Path $dir.FullName 'dispatch.json'
                $requestPath = Join-Path $dir.FullName 'request.json'
                if ([IO.File]::Exists($dispatchPath)) {
                    [void]$jobScans.Add((Get-TelephoneDashboardJobScan -JobRoot $dir.FullName -Descriptor $descriptor))
                } elseif ([IO.File]::Exists($requestPath)) {
                    [void]$jobScans.Add((Get-TelephoneDashboardDirectRouteScan -JobRoot $dir.FullName -Descriptor $descriptor))
                }
            }
        }
        if ([IO.Directory]::Exists($runsRoot) -or [IO.File]::Exists($runsRoot)) {
            $runsProbe = Test-TelephoneDashboardConfiguredDirectory -Path $runsRoot -Label 'App Server runs root'
            if (-not [bool]$runsProbe.ok) {
                Add-TelephoneDashboardFinding -Findings $entryFindings -Code $(if ([string]::IsNullOrWhiteSpace([string]$runsProbe.error)) { 'UNREADABLE_EVIDENCE' } else { [string]$runsProbe.error })
            } else {
                $runDirs = @()
                try {
                    $runDirs = @(Get-ChildItem -LiteralPath ([string]$runsProbe.path) -Directory -Force -ErrorAction Stop | Sort-Object Name)
                } catch {
                    Add-TelephoneDashboardFinding -Findings $entryFindings -Code 'UNREADABLE_EVIDENCE'
                    $runDirs = @()
                }
                foreach ($dir in $runDirs) {
                    try {
                        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                            Add-TelephoneDashboardFinding -Findings $entryFindings -Code 'REPARSE_POINT'
                            continue
                        }
                    } catch {
                        Add-TelephoneDashboardFinding -Findings $entryFindings -Code 'UNREADABLE_EVIDENCE'
                        continue
                    }
                    [void]$runScans.Add((Get-TelephoneDashboardRunScan -RunRoot $dir.FullName))
                }
            }
        }
        $closurePath = Join-Path $root 'closure.json'
        $closureRead = Read-TelephoneDashboardOptionalJson -Path $closurePath -SchemaName 'dashboard-closure' -Root $root
        $closure = $null
        if ([bool]$closureRead.present) {
            if ([bool]$closureRead.valid) {
                $receiptPath = [string]$closureRead.value.receipt.path
                $receiptMatch = $false
                $receiptSafety = Test-TelephoneCompletePathChain -Path $receiptPath -Root $root -RequireRegularFile -Label 'Closure receipt'
                if (-not [bool]$receiptSafety.ok) {
                    Add-TelephoneDashboardFinding -Findings $entryFindings -Code $(if ([string]::IsNullOrWhiteSpace([string]$receiptSafety.error)) { 'UNREADABLE_EVIDENCE' } else { [string]$receiptSafety.error })
                } else {
                    try {
                        $identity = Get-TelephoneFileIdentity -Path $receiptPath
                        if ([string]$identity.sha256 -ceq [string]$closureRead.value.receipt.sha256 -and [int64]$identity.bytes -eq [int64]$closureRead.value.receipt.bytes) {
                            $receiptMatch = $true
                        }
                    } catch { $receiptMatch = $false }
                }
                $closure = [ordered]@{
                    valid = [bool]$receiptMatch
                    receipt_sha256 = [string]$closureRead.value.receipt.sha256
                    session_id = [string]$closureRead.value.lead_session_id
                    run_id = $(if ($closureRead.value.Contains('lead_run_id')) { [string]$closureRead.value.lead_run_id } else { '' })
                }
            } else {
                if ([string]$closureRead.error -ceq 'REPARSE_POINT') {
                    Add-TelephoneDashboardFinding -Findings $entryFindings -Code 'REPARSE_POINT'
                } elseif ([string]$closureRead.error -ceq 'PATH_ESCAPE') {
                    Add-TelephoneDashboardFinding -Findings $entryFindings -Code 'PATH_ESCAPE'
                } else {
                    Add-TelephoneDashboardFinding -Findings $entryFindings -Code 'MALFORMED_EVIDENCE'
                }
                $closure = [ordered]@{ valid = $false; receipt_sha256 = ''; session_id = ''; run_id = '' }
            }
        }

        $bucket = @{}
        $telephoneByJobId = @{}
        $directByJobId = @{}
        foreach ($job in $jobScans) {
            $jid = [string]$job.job_id
            if ([string]::IsNullOrWhiteSpace($jid)) { continue }
            if ([bool]$job.direct_route -and -not [bool]$job.dispatch.valid) {
                $directByJobId[$jid] = $job
            } else {
                $telephoneByJobId[$jid] = $job
            }
        }
        $proofJobIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $proofDirectSessions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($job in $jobScans) {
            $jid = [string]$job.job_id
            $isOwner = $false
            if (Test-TelephoneDashboardExactSuccessorJob -Candidate $job -Descriptor $descriptor) { $isOwner = $true }
            if (Test-TelephoneDashboardDirectPackageOwner -Job $job -AllJobs @($jobScans) -Descriptor $descriptor -DirectByJobId $directByJobId -TelephoneByJobId $telephoneByJobId) { $isOwner = $true }
            if (-not $isOwner) { continue }
            if (-not [string]::IsNullOrWhiteSpace($jid)) { [void]$proofJobIds.Add($jid) }
            $ownerSession = Get-TelephoneDashboardJobDirectSession -Job $job -DirectByJobId $directByJobId
            if (-not [string]::IsNullOrWhiteSpace($ownerSession)) { [void]$proofDirectSessions.Add($ownerSession) }
        }
        foreach ($job in $jobScans) {
            if (Test-TelephoneDashboardSupersededFailure -Job $job -AllJobs @($jobScans) -Descriptor $descriptor -StateRoot $root -Closure $closure) {
                continue
            }
            if (Test-TelephoneDashboardDirectHistoryRetired -Job $job -AllJobs @($jobScans) -Descriptor $descriptor -DirectByJobId $directByJobId -ProofJobIds @($proofJobIds) -ProofDirectSessions @($proofDirectSessions)) {
                continue
            }
            $session = Get-TelephoneDashboardCorrelatedLeadSession -Job $job -TelephoneByJobId $telephoneByJobId -Descriptor $descriptor -FilterSession $filterSession
            if (-not [string]::IsNullOrWhiteSpace($filterSession) -and $session -cne $filterSession) { continue }
            $projectName = if (-not [string]::IsNullOrWhiteSpace([string]$job.project)) { [string]$job.project } else { [string]$descriptor.project }
            if ([string]$projectName -cne [string]$descriptor.project -and [string]$descriptor.project -cne 'state-root') {
                if (-not [string]::IsNullOrWhiteSpace([string]$job.project)) { continue }
            }
            $ownerJobId = [string]$job.job_id
            $directSessionForFresh = Get-TelephoneDashboardJobDirectSession -Job $job -DirectByJobId $directByJobId
            $onProvenFreshSession = $false
            if (-not [string]::IsNullOrWhiteSpace($directSessionForFresh) -and $proofDirectSessions.Contains($directSessionForFresh)) {
                $sessionRetiredForFresh = $false
                $authorityForFresh = Get-TelephoneDashboardDirectRouteAuthority -Descriptor $descriptor
                foreach ($retiredSid in @($authorityForFresh.retired_session_ids)) {
                    if ($directSessionForFresh -ceq [string]$retiredSid) { $sessionRetiredForFresh = $true; break }
                }
                $onProvenFreshSession = -not $sessionRetiredForFresh
            }
            $isExactAuthorizedJob = $false
            foreach ($exactId in @(Get-TelephoneDashboardDescriptorExactJobIds -Descriptor $descriptor)) {
                if (-not [string]::IsNullOrWhiteSpace($ownerJobId) -and $ownerJobId -ceq [string]$exactId) { $isExactAuthorizedJob = $true; break }
            }
            $stripFresh = $false
            if (-not [string]::IsNullOrWhiteSpace($ownerJobId) -and $proofJobIds.Contains($ownerJobId)) { $stripFresh = $true }
            elseif ($isExactAuthorizedJob -and $onProvenFreshSession) { $stripFresh = $true }
            if ($stripFresh) {
                $job.findings = @($job.findings | Where-Object { [string]$_.code -cne 'FRESH_DIRECT_SESSION_REQUIRED' })
            }
            $runKeys = [Collections.Generic.List[string]]::new()
            if (-not [string]::IsNullOrWhiteSpace($filterRun)) {
                [void]$runKeys.Add($filterRun)
            } else {
                $seenEventRuns = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($row in @($job.events)) {
                    if ($null -eq $row -or (Test-TelephoneDashboardMalformedRow -Row $row)) { continue }
                    $rowRun = ''
                    if ($row -is [Collections.IDictionary] -and $row.Contains('lead_run_id')) { $rowRun = [string]$row.lead_run_id }
                    if ($seenEventRuns.Add($rowRun)) { [void]$runKeys.Add($rowRun) }
                }
                if ($runKeys.Count -eq 0) { [void]$runKeys.Add('') }
            }
            foreach ($runId in @($runKeys)) {
                $key = Get-TelephoneDashboardGroupKey -Project ([string]$descriptor.project) -SessionId $session -RunId $runId
                if (-not $bucket.Contains($key)) {
                    $bucket[$key] = [ordered]@{ project = [string]$descriptor.project; session = $session; run = $runId; jobs = [Collections.Generic.List[object]]::new(); runs = [Collections.Generic.List[object]]::new(); events = [Collections.Generic.List[object]]::new() }
                }
                $jobAlready = $false
                foreach ($existingJob in @($bucket[$key].jobs)) {
                    if ([string]$existingJob.job_root -ceq [string]$job.job_root) { $jobAlready = $true; break }
                }
                if (-not $jobAlready) { [void]$bucket[$key].jobs.Add($job) }
                foreach ($event in @(Convert-TelephoneDashboardEventsFromLog -Rows @($job.events) -Project ([string]$descriptor.project) -SessionId $session -RunId $runId)) {
                    [void]$bucket[$key].events.Add($event)
                }
            }
        }
        foreach ($run in $runScans) {
            $session = [string]$run.session_id
            if (-not [string]::IsNullOrWhiteSpace($filterSession) -and $session -cne $filterSession) { continue }
            if (-not [string]::IsNullOrWhiteSpace($filterRun) -and [string]$run.run_id -cne $filterRun) { continue }
            $key = Get-TelephoneDashboardGroupKey -Project ([string]$descriptor.project) -SessionId $session -RunId ([string]$run.run_id)
            if (-not $bucket.Contains($key)) {
                $bucket[$key] = [ordered]@{ project = [string]$descriptor.project; session = $session; run = [string]$run.run_id; jobs = [Collections.Generic.List[object]]::new(); runs = [Collections.Generic.List[object]]::new(); events = [Collections.Generic.List[object]]::new() }
            }
            [void]$bucket[$key].runs.Add($run)
            foreach ($event in @(Convert-TelephoneDashboardEventsFromLog -Rows @($run.events) -Project ([string]$descriptor.project) -SessionId $session -RunId ([string]$run.run_id))) {
                [void]$bucket[$key].events.Add($event)
            }
        }
        if ($bucket.Count -eq 0) {
            $supersededOnly = $false
            if (@($jobScans).Count -gt 0) {
                $supersededOnly = $true
                foreach ($job in $jobScans) {
                    $hidden = (Test-TelephoneDashboardSupersededFailure -Job $job -AllJobs @($jobScans) -Descriptor $descriptor -StateRoot $root -Closure $closure) -or
                        (Test-TelephoneDashboardDirectHistoryRetired -Job $job -AllJobs @($jobScans) -Descriptor $descriptor -DirectByJobId $directByJobId -ProofJobIds @($proofJobIds) -ProofDirectSessions @($proofDirectSessions))
                    if (-not $hidden) {
                        $supersededOnly = $false
                        break
                    }
                }
            }
            $keepEmpty = -not $supersededOnly
            foreach ($finding in @($entryFindings)) {
                if ([string]$finding.severity -ceq 'fail_closed') { $keepEmpty = $true }
            }
            if ($keepEmpty) {
                $key = Get-TelephoneDashboardGroupKey -Project ([string]$descriptor.project) -SessionId $filterSession -RunId $filterRun
                $bucket[$key] = [ordered]@{ project = [string]$descriptor.project; session = $filterSession; run = $filterRun; jobs = [Collections.Generic.List[object]]::new(); runs = [Collections.Generic.List[object]]::new(); events = [Collections.Generic.List[object]]::new() }
            }
        }
        $supervisorScan = Get-TelephoneDashboardSupervisorScan -Descriptor $descriptor -StateRoot $root
        $mailboxScan = Get-TelephoneDashboardMailboxScan -Descriptor $descriptor -StateRoot $root
        foreach ($key in @($bucket.Keys)) {
            $item = $bucket[$key]
            $groupClosure = $null
            if ($null -ne $closure) {
                if ([string]::IsNullOrWhiteSpace([string]$closure.session_id) -or [string]$closure.session_id -ceq [string]$item.session) {
                    $groupClosure = $closure
                }
            }
            $supFindings = [Collections.Generic.List[object]]::new()
            foreach ($f in @($entryFindings)) { [void]$supFindings.Add($f) }
            $supRunId = ''
            $supStatus = ''
            $pausedFlag = [bool]$supervisorScan.paused
            foreach ($sharedFinding in @($supervisorScan.shared_findings)) { [void]$supFindings.Add($sharedFinding) }
            foreach ($record in @($supervisorScan.records)) {
                $projectOk = (-not [string]::IsNullOrWhiteSpace([string]$record.project) -and -not [string]::IsNullOrWhiteSpace([string]$item.project) -and [string]$record.project -ceq [string]$item.project)
                $sessionOk = (-not [string]::IsNullOrWhiteSpace([string]$record.lead_session_id) -and -not [string]::IsNullOrWhiteSpace([string]$item.session) -and [string]$record.lead_session_id -ceq [string]$item.session)
                $runOk = $true
                if (-not [string]::IsNullOrWhiteSpace([string]$item.run)) {
                    $runOk = (-not [string]::IsNullOrWhiteSpace([string]$record.lead_run_id) -and [string]$record.lead_run_id -ceq [string]$item.run)
                } elseif (-not [string]::IsNullOrWhiteSpace([string]$record.lead_run_id)) {
                    $runOk = $false
                }
                if (-not ($projectOk -and $sessionOk -and $runOk)) { continue }
                $record.matched = $true
                $supRunId = [string]$record.run_id
                $supStatus = [string]$record.status
                if ($pausedFlag) { $supStatus = 'paused' }
                if ([string]$record.terminal -ceq 'cancelled' -or [string]$record.status -ceq 'cancelled') {
                    $supStatus = 'cancelled'
                    [void]$supFindings.Add([ordered]@{ code = 'SUPERVISOR_CANCELLED'; severity = 'fail_closed' })
                } elseif ([string]$record.terminal -ceq 'failed' -or [string]$record.status -ceq 'failed') {
                    $supStatus = 'failed'
                    [void]$supFindings.Add([ordered]@{ code = 'SUPERVISOR_FAILED'; severity = 'fail_closed' })
                }
                foreach ($f in @($record.findings)) { if ($null -ne $f) { [void]$supFindings.Add($f) } }
            }
            foreach ($mailbox in @($mailboxScan)) {
                if ([string]::IsNullOrWhiteSpace([string]$item.session) -or [string]::IsNullOrWhiteSpace([string]$mailbox.lead_session_id)) { continue }
                if ([string]$mailbox.lead_session_id -cne [string]$item.session) { continue }
                if ([bool]$mailbox.collecting) {
                    [void]$supFindings.Add([ordered]@{ code = 'BATCH_COLLECTING'; severity = 'info' })
                }
            }
            $hasSup = (-not [string]::IsNullOrWhiteSpace($supRunId) -or $pausedFlag -or @($supervisorScan.shared_findings).Count -gt 0)
            $projected = Get-TelephoneDashboardGroupProjection `
                -Project ([string]$item.project) `
                -SessionId ([string]$item.session) `
                -RunId ([string]$item.run) `
                -TerminalState $terminalState `
                -Jobs @($item.jobs) `
                -Runs @($item.runs) `
                -Events @($item.events) `
                -Closure $groupClosure `
                -ExtraFindings @($supFindings) `
                -SupervisorRunId $supRunId `
                -SupervisorStatus $supStatus `
                -PausedByPascal $pausedFlag `
                -HasSupervisorEvidence:$hasSup
            [void]$groups.Add($projected)
        }
        foreach ($record in @($supervisorScan.records)) {
            if ([bool]$record.matched) { continue }
            $extra = [Collections.Generic.List[object]]::new()
            foreach ($sharedFinding in @($supervisorScan.shared_findings)) { [void]$extra.Add($sharedFinding) }
            foreach ($f in @($record.findings)) { if ($null -ne $f) { [void]$extra.Add($f) } }
            $status = [string]$record.status
            if ([bool]$supervisorScan.paused) { $status = 'paused' }
            if ([string]::IsNullOrWhiteSpace($status)) { $status = 'orphan' }
            if ([string]::IsNullOrWhiteSpace([string]$record.project) -or [string]::IsNullOrWhiteSpace([string]$record.lead_session_id)) {
                [void]$extra.Add([ordered]@{ code = 'SUPERVISOR_INCOMPLETE_IDENTITY'; severity = 'fail_closed' })
                $status = 'orphan'
            }
            $descSession = if ($descriptor.Contains('lead_session_id')) { [string]$descriptor.lead_session_id } else { '' }
            $descRun = if ($descriptor.Contains('lead_run_id')) { [string]$descriptor.lead_run_id } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($descSession) -and -not [string]::IsNullOrWhiteSpace([string]$record.lead_session_id) -and [string]$record.lead_session_id -cne $descSession) {
                [void]$extra.Add([ordered]@{ code = 'SUPERVISOR_MISMATCH'; severity = 'fail_closed' })
                $status = 'orphan'
            }
            if (-not [string]::IsNullOrWhiteSpace($descRun) -and -not [string]::IsNullOrWhiteSpace([string]$record.lead_run_id) -and [string]$record.lead_run_id -cne $descRun) {
                [void]$extra.Add([ordered]@{ code = 'SUPERVISOR_MISMATCH'; severity = 'fail_closed' })
                $status = 'orphan'
            }
            if ($status -ceq 'orphan') { [void]$extra.Add([ordered]@{ code = 'SUPERVISOR_ORPHAN'; severity = 'fail_closed' }) }
            if (-not [string]::IsNullOrWhiteSpace([string]$record.project) -and [string]$record.project -cne [string]$descriptor.project) {
                [void]$extra.Add([ordered]@{ code = 'SUPERVISOR_MISMATCH'; severity = 'fail_closed' })
                $status = 'orphan'
            }
            [void]$groups.Add((New-TelephoneDashboardObservedGroup `
                -Project ([string]$descriptor.project) `
                -SessionId ([string]$record.lead_session_id) `
                -RunId $(if (-not [string]::IsNullOrWhiteSpace([string]$record.lead_run_id)) { [string]$record.lead_run_id } else { [string]$record.run_id }) `
                -Phase 'execute' `
                -Findings @($extra) `
                -SupervisorRunId ([string]$record.run_id) `
                -SupervisorStatus $status `
                -PausedByPascal ([bool]$supervisorScan.paused) `
                -HasSupervisorEvidence))
        }
    }

    $visibleGroups = [Collections.Generic.List[object]]::new()
    foreach ($group in $groups) {
        if ([bool]$group.disappeared) { continue }
        [void]$visibleGroups.Add($group)
    }

    return [ordered]@{
        protocol_version = 'telephone-line-dashboard-projection-v1'
        observational = $true
        updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        config_present = [bool]$configPresent
        groups = @($visibleGroups)
    }
}

function Format-TelephoneDashboardSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Projection)

    $lines = [Collections.Generic.List[string]]::new()
    [void]$lines.Add('Telephone Dashboard (read-only observer)')
    [void]$lines.Add('Colors: green=evidence matches; yellow=fail-closed gap; hidden=exact terminal retirement.')
    [void]$lines.Add('This observer never dispatches, retries, advances, judges PASS, or edits a registry.')
    if (@($Projection.groups).Count -eq 0) {
        [void]$lines.Add('No visible projects. Configure descriptors or TELEPHONE_LINE_STATE_ROOT.')
    }
    foreach ($group in @($Projection.groups)) {
        $findings = @($group.findings | ForEach-Object { [string]$_.code }) -join ','
        if ([string]::IsNullOrWhiteSpace($findings)) { $findings = 'none' }
        $jobId = Get-TelephoneDashboardMapText -Map $group -Name 'line_job_id'
        $stage = Get-TelephoneDashboardMapText -Map $group -Name 'stage'
        $role = Get-TelephoneDashboardMapText -Map $group -Name 'role'
        $route = Get-TelephoneDashboardMapText -Map $group -Name 'route'
        $dup = 0
        try { $dup = [int](Get-TelephoneDashboardMapText -Map $group -Name 'duplicate_count' -Default '0') } catch { $dup = 0 }
        $provenance = Get-TelephoneDashboardMapText -Map $group -Name 'provenance'
        if ([string]::IsNullOrWhiteSpace($provenance)) { $provenance = 'none' }
        [void]$lines.Add(('[{0}] project={1} lead={2} run={3} job={4} stage={5} role={6} route={7} phase={8} dup={9} provenance={10} lead/exec/audit/corr/close={11}/{12}/{13}/{14}/{15} findings={16}' -f `
            [string]$group.color, [string]$group.project, [string]$group.lead_session_id, [string]$group.lead_run_id, $jobId, $stage, $role, $route, [string]$group.phase, $dup, $provenance, `
            [int][bool]$group.lead, [int][bool]$group.execution, [int][bool]$group.final_audit, [int][bool]$group.correction, [int][bool]$group.closure, $findings))
        if ($group.Contains('lanes')) {
            $laneText = @($group.lanes | ForEach-Object { ([string]$_.package_id + ':' + [string]$_.state) }) -join ','
            [void]$lines.Add(('  current=v{0} failure={1} automatic={2} requires_pascal={3} lanes={4}' -f [int]$group.current_state_version, [string]$group.failure_class, [string]$group.automatic_action, [bool]$group.requires_pascal, $laneText))
        }
    }
    return ([string]::Join("`n", $lines) + "`n")
}
