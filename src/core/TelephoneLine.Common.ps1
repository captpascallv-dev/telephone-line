# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'Telephone Line v0.1 supports Windows only.'
}

$script:TelephoneSchemaCache = @{}
$script:TelephoneLifecycleEventsMaxBytes = 8388608

$script:TelephonePublicErrorCatalog = [ordered]@{
    TRANSPORT_ERROR = 'Telephone-line transport failed.'
    COMMAND_HOST_ERROR = 'The telephone-line command host could not complete the frozen command.'
    COMMAND_START_FAILED = 'The telephone-line command host did not start.'
    COMMAND_START_AMBIGUOUS_NO_RERUN = 'The command host did not publish its startup identity. The external task was not automatically rerun.'
    COMMAND_HOST_INTERRUPTED = 'The command host ended without a durable receipt. The external task was not automatically rerun.'
    LEAD_WAKE_FAILED = 'Lead wake did not complete from durable known state.'
    LEAD_WAKE_AMBIGUOUS = 'Lead wake was ambiguous after launch. A second Lead turn was not started.'
    LEAD_CLI_UNLAUNCHABLE = 'The configured Lead CLI executable could not be created as a process. The receipt was kept pending.'
    LEAD_WAKE_INCOMPLETE_HOST = 'Lead native turn evidence exists but the host did not publish a terminal. The receipt was kept pending.'
    LEAD_WAKE_PRE_TURN_CONFLICT = 'Lead wake hit a verified pre-native-turn active-writer conflict. The original receipt stayed eligible; the executor was not rerun.'
    TRUSTED_CONSUMPTION_REJECTED = 'Trusted manual consumption evidence did not bind to this receipt, wake key, and original session.'
    SUPERVISOR_CLAIMED_NOT_STARTED = 'A claimed supervisor run had no owner and was proven not started.'
    SUPERVISOR_CLAIMED_UNKNOWN = 'A claimed supervisor run had no owner and could not be proven not-started or attached.'
    BATCH_CONTRACT_INVALID = 'The telephone-line batch contract was invalid. The executor was not rerun.'
}

function Get-TelephonePublicErrorMessage {
    [CmdletBinding()]
    param([string]$ErrorCode)

    $code = [string]$ErrorCode
    if (-not [string]::IsNullOrWhiteSpace($code) -and $script:TelephonePublicErrorCatalog.Contains($code)) {
        return [string]$script:TelephonePublicErrorCatalog[$code]
    }
    return [string]$script:TelephonePublicErrorCatalog['TRANSPORT_ERROR']
}

function Get-TelephoneDurableErrorCode {
    [CmdletBinding()]
    param([string]$ErrorCode)

    $code = [string]$ErrorCode
    if (-not [string]::IsNullOrWhiteSpace($code) -and $script:TelephonePublicErrorCatalog.Contains($code)) {
        return $code
    }
    return 'TRANSPORT_ERROR'
}

function Test-TelephoneKnownPublicErrorMessage {
    [CmdletBinding()]
    param([AllowNull()][string]$Message)

    $text = [string]$Message
    if ([string]::IsNullOrEmpty($text)) { return $false }
    foreach ($known in @($script:TelephonePublicErrorCatalog.Values)) {
        if ($text -ceq [string]$known) { return $true }
    }
    return $false
}

function Get-TelephoneSanitizedMessage {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Message,
        [string]$ErrorCode
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$ErrorCode)) {
        return Get-TelephonePublicErrorMessage -ErrorCode $ErrorCode
    }
    $text = [string]$Message
    if (Test-TelephoneKnownPublicErrorMessage -Message $text) {
        return $text
    }
    return Get-TelephonePublicErrorMessage -ErrorCode 'TRANSPORT_ERROR'
}

function Get-TelephoneSchemaRoot {
    [CmdletBinding()]
    param()

    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\schemas'))
    if (-not [IO.Directory]::Exists($root)) { throw 'Telephone-line schema directory is missing.' }
    return $root
}

function Get-TelephoneSchemaPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('dispatch', 'receipt', 'lead-binding', 'adapter', 'catalog', 'release-manifest', 'codex-app-server-lead-profile', 'codex-app-server-lead-run', 'codex-app-server-lead-status', 'codex-app-server-lead-intent', 'codex-app-server-lead-bound-turn', 'codex-app-server-lead-ack', 'codex-app-server-lead-owner', 'codex-app-server-lead-child', 'codex-app-server-lead-result', 'codex-app-server-lead-failure', 'codex-app-server-lead-recovery', 'codex-app-server-lead-status-sources', 'lifecycle-status', 'dashboard-config', 'dashboard-project-descriptor', 'dashboard-lifecycle-event', 'dashboard-projection', 'dashboard-closure', 'telephone-line-batch', 'wired-supervisor-request', 'wired-supervisor-owner', 'wired-supervisor-status', 'wired-supervisor-control', 'control-plane-wave-spec', 'control-plane-wave-manifest', 'control-plane-current-pointer', 'control-plane-current-state', 'control-plane-continuation-capsule', 'control-plane-action-intent', 'control-plane-action-result', 'control-plane-event', 'control-plane-transition', 'control-plane-history-index', 'control-plane-lane-attempt', 'control-plane-performance-evidence', 'control-plane-failure-matrix-evidence', 'control-plane-release-gates-evidence')]
        [string]$Name
    )

    $path = Join-Path (Get-TelephoneSchemaRoot) ($Name + '.schema.json')
    if (-not [IO.File]::Exists($path)) { throw "Telephone-line schema is missing: $Name" }
    return $path
}

function Get-TelephoneCachedSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($script:TelephoneSchemaCache.ContainsKey($Name)) {
        return $script:TelephoneSchemaCache[$Name]
    }
    $path = Get-TelephoneSchemaPath -Name $Name
    $text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($path))
    $schema = $text | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    $script:TelephoneSchemaCache[$Name] = $schema
    return $schema
}

function Resolve-TelephoneSchemaRef {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$RootSchema,
        [Parameter(Mandatory = $true)][object]$Schema
    )

    if ($Schema -isnot [Collections.IDictionary] -or -not $Schema.Contains('$ref')) {
        return $Schema
    }
    $ref = [string]$Schema['$ref']
    if ($ref -cnotmatch '^#/\$defs/([A-Za-z0-9_]+)$') {
        throw "Unsupported schema reference."
    }
    $name = [string]$Matches[1]
    $defs = $RootSchema['$defs']
    if ($null -eq $defs -or -not $defs.Contains($name)) {
        throw "Telephone-line schema definition is missing."
    }
    return $defs[$name]
}

function Test-TelephoneJsonType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Element,
        [Parameter(Mandatory = $true)][string]$TypeName
    )

    $node = [System.Text.Json.JsonElement]$Element
    switch ($TypeName) {
        'object' { return $node.ValueKind -eq [System.Text.Json.JsonValueKind]::Object }
        'array' { return $node.ValueKind -eq [System.Text.Json.JsonValueKind]::Array }
        'string' { return $node.ValueKind -eq [System.Text.Json.JsonValueKind]::String }
        'boolean' { return $node.ValueKind -eq [System.Text.Json.JsonValueKind]::True -or $node.ValueKind -eq [System.Text.Json.JsonValueKind]::False }
        'null' { return $node.ValueKind -eq [System.Text.Json.JsonValueKind]::Null }
        'integer' {
            if ($node.ValueKind -ne [System.Text.Json.JsonValueKind]::Number) { return $false }
            $n = [int64]0
            return $node.TryGetInt64([ref]$n)
        }
        'number' { return $node.ValueKind -eq [System.Text.Json.JsonValueKind]::Number }
        default { throw 'Unsupported schema type.' }
    }
}

function Test-TelephoneJsonConst {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Element,
        [AllowNull()][object]$Const
    )

    $node = [System.Text.Json.JsonElement]$Element
    if ($null -eq $Const) {
        return $node.ValueKind -eq [System.Text.Json.JsonValueKind]::Null
    }
    if ($Const -is [bool]) {
        if ($Const) { return $node.ValueKind -eq [System.Text.Json.JsonValueKind]::True }
        return $node.ValueKind -eq [System.Text.Json.JsonValueKind]::False
    }
    if ($Const -is [string]) {
        return $node.ValueKind -eq [System.Text.Json.JsonValueKind]::String -and $node.GetString() -ceq [string]$Const
    }
    if ($Const -is [byte] -or $Const -is [int16] -or $Const -is [uint16] -or $Const -is [int] -or $Const -is [uint32] -or $Const -is [int64] -or $Const -is [uint64] -or $Const -is [decimal]) {
        if ($node.ValueKind -ne [System.Text.Json.JsonValueKind]::Number) { return $false }
        $n = [int64]0
        if (-not $node.TryGetInt64([ref]$n)) { return $false }
        return $n -eq [int64]$Const
    }
    return $false
}

function Invoke-TelephoneSchemaCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$RootSchema,
        [Parameter(Mandatory = $true)][object]$Schema,
        [Parameter(Mandatory = $true)][object]$Element,
        [Parameter(Mandatory = $true)][string]$Path,
        [Collections.Generic.List[string]]$Errors
    )

    $Element = [System.Text.Json.JsonElement]$Element

    $Schema = Resolve-TelephoneSchemaRef -RootSchema $RootSchema -Schema $Schema
    if ($Schema -isnot [Collections.IDictionary]) {
        $Errors.Add("${Path}: schema node is invalid.")
        return
    }

    if ($Schema.Contains('oneOf')) {
        $matchCount = 0
        foreach ($option in @($Schema.oneOf)) {
            $optionErrors = [Collections.Generic.List[string]]::new()
            Invoke-TelephoneSchemaCheck -RootSchema $RootSchema -Schema $option -Element $Element -Path $Path -Errors $optionErrors
            if ($optionErrors.Count -eq 0) { $matchCount += 1 }
        }
        if ($matchCount -ne 1) {
            $Errors.Add("${Path}: value must match exactly one allowed shape.")
        }
        return
    }

    if ($Schema.Contains('type')) {
        $typeName = [string]$Schema.type
        if (-not (Test-TelephoneJsonType -Element $Element -TypeName $typeName)) {
            $Errors.Add("${Path}: expected type $typeName.")
            return
        }
    }

    if ($Schema.Contains('const') -and -not (Test-TelephoneJsonConst -Element $Element -Const $Schema.const)) {
        $Errors.Add("${Path}: const mismatch.")
        return
    }

    if ($Schema.Contains('enum')) {
        $matched = $false
        foreach ($item in @($Schema.enum)) {
            if (Test-TelephoneJsonConst -Element $Element -Const $item) { $matched = $true; break }
        }
        if (-not $matched) {
            $Errors.Add("${Path}: value is not in the allowed enum.")
            return
        }
    }

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
        $value = $Element.GetString()
        if ($Schema.Contains('minLength') -and $value.Length -lt [int]$Schema.minLength) {
            $Errors.Add("${Path}: string is shorter than minLength.")
        }
        if ($Schema.Contains('maxLength') -and $value.Length -gt [int]$Schema.maxLength) {
            $Errors.Add("${Path}: string is longer than maxLength.")
        }
        if ($Schema.Contains('pattern') -and -not [Regex]::IsMatch($value, [string]$Schema.pattern)) {
            $Errors.Add("${Path}: string does not match the required pattern.")
        }
    }

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Number -and $Schema.Contains('minimum')) {
        $n = [int64]0
        if ($Element.TryGetInt64([ref]$n) -and $n -lt [int64]$Schema.minimum) {
            $Errors.Add("${Path}: integer is below minimum.")
        }
    }

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $propertyMap = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        if ($Schema.Contains('properties') -and $null -ne $Schema.properties) {
            foreach ($key in @($Schema.properties.Keys)) {
                $propertyMap[[string]$key] = $Schema.properties[$key]
            }
        }
        if ($Schema.Contains('required')) {
            $present = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) { [void]$present.Add($property.Name) }
            foreach ($name in @($Schema.required)) {
                if (-not $present.Contains([string]$name)) {
                    $Errors.Add("${Path}: missing required field $name.")
                }
            }
        }
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $propertyMap.ContainsKey($property.Name)) {
                if ($Schema.Contains('additionalProperties') -and $Schema.additionalProperties -eq $false) {
                    $Errors.Add("${Path}: unknown field $($property.Name).")
                }
                continue
            }
            Invoke-TelephoneSchemaCheck -RootSchema $RootSchema -Schema $propertyMap[$property.Name] -Element $property.Value -Path ($Path + '.' + $property.Name) -Errors $Errors
        }
    }

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            if ($Schema.Contains('items')) {
                Invoke-TelephoneSchemaCheck -RootSchema $RootSchema -Schema $Schema.items -Element $item -Path ($Path + "[$index]") -Errors $Errors
            }
            $index += 1
        }
        if ($Schema.Contains('minItems') -and $index -lt [int]$Schema.minItems) {
            $Errors.Add("${Path}: array is shorter than minItems.")
        }
        if ($Schema.Contains('maxItems') -and $index -gt [int]$Schema.maxItems) {
            $Errors.Add("${Path}: array is longer than maxItems.")
        }
    }
}

function Assert-TelephoneJsonSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Parameter(Mandatory = $true)][string]$SchemaName,
        [string]$Label = 'JSON'
    )

    $schema = Get-TelephoneCachedSchema -Name $SchemaName
    $doc = [System.Text.Json.JsonDocument]::Parse($JsonText)
    try {
        $errors = [Collections.Generic.List[string]]::new()
        Invoke-TelephoneSchemaCheck -RootSchema $schema -Schema $schema -Element $doc.RootElement -Path '$' -Errors $errors
        if ($errors.Count -gt 0) {
            $shown = @($errors | Select-Object -First 8) -join '; '
            throw (Get-TelephoneSanitizedMessage -Message "$Label failed schema ${SchemaName}: $shown")
        }
    } finally {
        $doc.Dispose()
    }
}

function Assert-TelephoneObjectFieldAllowlist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Element,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $node = [System.Text.Json.JsonElement]$Element
    if ($node.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
        throw "$Label must be an object."
    }
    $allowedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Allowed) { [void]$allowedSet.Add($name) }
    foreach ($property in $node.EnumerateObject()) {
        if (-not $allowedSet.Contains($property.Name)) {
            throw "$Label has an unknown field."
        }
    }
}

function Get-TelephoneJsonPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Element,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $node = [System.Text.Json.JsonElement]$Element
    foreach ($property in $node.EnumerateObject()) {
        if ($property.Name -ceq $Name) { return $property.Value }
    }
    return $null
}

function Read-TelephoneFileBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $stream = [IO.FileStream]::new(
        $full,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    )
    try {
        $length = [int]$stream.Length
        if ($length -lt 0) { throw "Invalid length for $full" }
        $bytes = [byte[]]::new($length)
        $offset = 0
        while ($offset -lt $length) {
            $n = $stream.Read($bytes, $offset, $length - $offset)
            if ($n -le 0) { throw "Short read of $full" }
            $offset += $n
        }
        Write-Output -NoEnumerate -InputObject $bytes
        return
    } finally {
        $stream.Dispose()
    }
}

function Get-TelephoneFileIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Expected a regular file: $full"
    }
    $bytes = Read-TelephoneFileBytes -Path $item.FullName
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$bytes.Length
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
}

function Assert-TelephoneFileIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not [IO.Path]::GetFullPath([string]$Expected.path).Equals([IO.Path]::GetFullPath([string]$Actual.path), [StringComparison]::OrdinalIgnoreCase) -or
        [int64]$Expected.bytes -ne [int64]$Actual.bytes -or
        [string]$Expected.sha256 -cne [string]$Actual.sha256) {
        throw "$Label identity changed."
    }
}

function Assert-TelephoneRegularFilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) { throw "$Label is not a regular file." }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "$Label must be a regular file, not a directory." }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label path is a reparse point."
    }
    return $item.FullName
}

function Test-TelephoneDashboardEnvTruthy {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $false }
    return ([string]$Value -match '^(?i:1|true|yes|on)$')
}

function Get-TelephoneDashboardEnvValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$ProcessOnly
    )
    $targets = if ($ProcessOnly) {
        @([EnvironmentVariableTarget]::Process)
    } else {
        @([EnvironmentVariableTarget]::Process, [EnvironmentVariableTarget]::User, [EnvironmentVariableTarget]::Machine)
    }
    foreach ($target in $targets) {
        try { $candidate = [Environment]::GetEnvironmentVariable($Name, $target) } catch { $candidate = '' }
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            return [string]$candidate
        }
    }
    return ''
}

function Register-TelephoneDashboardLineSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LineStateRoot,
        [string]$LineJobId = '',
        [string]$Project = '',
        [string]$LeadSessionId = '',
        [string]$LeadRunId = '',
        [string]$Route = '',
        [string]$DashboardStateRoot = ''
    )
    $dashCommon = Join-Path $PSScriptRoot '..\dashboard\TelephoneDashboard.Common.ps1'
    if (-not [IO.File]::Exists($dashCommon)) { return [ordered]@{ registered = $false; reason = 'dashboard_common_missing' } }
    . $dashCommon
    $dashRoot = $DashboardStateRoot
    if ([string]::IsNullOrWhiteSpace($dashRoot)) { $dashRoot = Get-TelephoneDashboardStateRoot }
    $dashRoot = [IO.Path]::GetFullPath($dashRoot).TrimEnd('\')
    [IO.Directory]::CreateDirectory($dashRoot) | Out-Null
    $paths = Get-TelephoneDashboardPaths -StateRoot $dashRoot
    $sourcePath = [string]$paths.line_sources
    $lockPath = Join-Path $dashRoot 'line-sources.lock'
    $lineRoot = [IO.Path]::GetFullPath($LineStateRoot).TrimEnd('\')
    $now = [DateTimeOffset]::UtcNow.ToString('o')
    $gate = Open-TelephoneExclusiveGate -Path $lockPath -WaitMilliseconds 15000
    if ($null -eq $gate) { return [ordered]@{ registered = $false; reason = 'source_lock' } }
    try {
        $doc = [ordered]@{
            protocol_version = 'telephone-line-dashboard-line-sources-v1'
            updated_at_utc = $now
            last_success_at_utc = ''
            last_read_error_at_utc = ''
            sources = @()
        }
        if ([IO.File]::Exists($sourcePath)) {
            try {
                $existing = (Read-TelephoneJson -Path $sourcePath).value
                if ($existing -isnot [Collections.IDictionary]) { throw 'malformed' }
                if ($existing.Contains('last_success_at_utc')) { $doc.last_success_at_utc = [string]$existing['last_success_at_utc'] }
                if ($existing.Contains('last_read_error_at_utc')) { $doc.last_read_error_at_utc = [string]$existing['last_read_error_at_utc'] }
                if ($existing.Contains('sources') -and $null -ne $existing['sources']) { $doc.sources = @($existing['sources']) }
                if ($existing.Contains('updated_at_utc')) { $doc['prior_updated_at_utc'] = [string]$existing['updated_at_utc'] }
            } catch {
                $malformed = [string]$paths.line_sources_malformed
                if ([string]::IsNullOrWhiteSpace($malformed)) { $malformed = Join-Path $dashRoot 'line-sources.malformed.json' }
                try { [IO.File]::Copy($sourcePath, $malformed, $true) } catch [IO.IOException] { }
                $doc.last_read_error_at_utc = $now
                $lastValidPath = [string]$paths.line_sources_last_valid
                if ([string]::IsNullOrWhiteSpace($lastValidPath)) { $lastValidPath = Join-Path $dashRoot 'line-sources.last-valid.json' }
                if ([IO.File]::Exists($lastValidPath)) {
                    try {
                        $valid = (Read-TelephoneJson -Path $lastValidPath).value
                        if ($valid -is [Collections.IDictionary]) {
                            if ($valid.Contains('sources') -and $null -ne $valid['sources']) { $doc.sources = @($valid['sources']) }
                            if ($valid.Contains('last_success_at_utc')) { $doc.last_success_at_utc = [string]$valid['last_success_at_utc'] }
                            $doc.updated_at_utc = $now
                            $doc['source_discovery_error'] = 'malformed'
                            $null = Write-TelephoneJsonReplace -Path $sourcePath -Value $doc
                            return [ordered]@{ registered = $false; reason = 'source_malformed'; path = $sourcePath; dashboard_state_root = $dashRoot; last_valid_restored = $true }
                        }
                    } catch { }
                }
                return [ordered]@{ registered = $false; reason = 'source_malformed'; path = $sourcePath; dashboard_state_root = $dashRoot; last_valid_restored = $false }
            }
        }
        $kept = [Collections.Generic.List[object]]::new()
        $replaced = $false
        foreach ($row in @($doc.sources)) {
            $rowRoot = ''
            $rowJob = ''
            if ($row -is [Collections.IDictionary]) {
                if ($row.Contains('state_root')) { $rowRoot = [string]$row['state_root'] }
                if ($row.Contains('line_job_id')) { $rowJob = [string]$row['line_job_id'] }
            }
            $sameRoot = (-not [string]::IsNullOrWhiteSpace($rowRoot) -and $rowRoot.Equals($lineRoot, [StringComparison]::OrdinalIgnoreCase))
            if ($sameRoot -and ([string]$rowJob -ceq [string]$LineJobId)) {
                $replaced = $true
                continue
            }
            [void]$kept.Add($row)
        }
        [void]$kept.Add([ordered]@{
            state_root = $lineRoot
            line_job_id = [string]$LineJobId
            project = [string]$Project
            lead_session_id = [string]$LeadSessionId
            lead_run_id = [string]$LeadRunId
            route = [string]$Route
            registered_at_utc = $now
        })
        $doc.sources = @($kept)
        $doc.updated_at_utc = $now
        $doc.last_read_error_at_utc = ''
        if ($doc.Contains('source_discovery_error')) { $doc.Remove('source_discovery_error') }
        $null = Write-TelephoneJsonReplace -Path $sourcePath -Value $doc
        $lastValidPath = [string]$paths.line_sources_last_valid
        if ([string]::IsNullOrWhiteSpace($lastValidPath)) { $lastValidPath = Join-Path $dashRoot 'line-sources.last-valid.json' }
        try { $null = Write-TelephoneJsonReplace -Path $lastValidPath -Value $doc } catch { }
        return [ordered]@{ registered = $true; replaced = [bool]$replaced; path = $sourcePath; dashboard_state_root = $dashRoot }
    } finally {
        $gate.Dispose()
    }
}

function Invoke-TelephoneDashboardEnsure {
    [CmdletBinding()]
    param()

    $processOnly = Test-TelephoneDashboardEnvTruthy -Value (Get-TelephoneDashboardEnvValue -Name 'TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY' -ProcessOnly)
    $configuredPath = Get-TelephoneDashboardEnvValue -Name 'TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT' -ProcessOnly:$processOnly
    $optOut = Test-TelephoneDashboardEnvTruthy -Value (Get-TelephoneDashboardEnvValue -Name 'TELEPHONE_LINE_DASHBOARD_OPT_OUT' -ProcessOnly:$processOnly)
    if ([string]::IsNullOrWhiteSpace($configuredPath) -and $optOut) {
        return [pscustomobject][ordered]@{ configured=$false; attempted=$false; healthy=$true; started=$false; already_running=$false; watcher_pid=0; error_code=''; source='opt-out'; observational=$true }
    }
    $source = 'override'
    if ([string]::IsNullOrWhiteSpace($configuredPath)) {
        $configuredPath = Join-Path $PSScriptRoot '..\dashboard\Ensure-TelephoneDashboard.ps1'
        $source = 'bundled'
    }

    try {
        $scriptPath = Assert-TelephoneRegularFilePath -Path $configuredPath -Label 'Dashboard ensure script'
        $raw = @(& $scriptPath -ErrorAction Stop)
        $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'Dashboard ensure script returned no result.' }
        $result = $text | ConvertFrom-Json -Depth 16
        if ($null -eq $result.PSObject.Properties['healthy'] -or $result.healthy -ne $true) { throw 'Dashboard ensure script did not report a healthy watcher.' }
        $watcherPid = 0
        if ($null -ne $result.PSObject.Properties['watcher_pid']) { $watcherPid = [int]$result.watcher_pid }
        return [pscustomobject][ordered]@{
            configured = $true
            attempted = $true
            healthy = $true
            started = [bool]$result.started
            already_running = [bool]$result.already_running
            watcher_pid = $watcherPid
            error_code = ''
            source = $source
            observational = $true
        }
    } catch {
        return [pscustomobject][ordered]@{ configured=$true; attempted=$true; healthy=$false; started=$false; already_running=$false; watcher_pid=0; error_code='DASHBOARD_ENSURE_FAILED'; source=$source; observational=$true }
    }
}

function Assert-TelephoneDirectoryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not [IO.Directory]::Exists($full)) { throw "$Label directory does not exist." }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw "$Label must be a directory, not a file." }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label path is a reparse point."
    }
    return $full
}

function Assert-TelephoneRelativePathSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    foreach ($segment in $Path.Replace('/', '\').Split([char]'\')) {
        if ($segment -ceq '..') { throw "$Label path escape is not allowed." }
    }
}

function Resolve-TelephonePathInsideRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Assert-TelephoneRelativePathSafe -Path $Path -Label $Label
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $combined = if ([IO.Path]::IsPathRooted($Path)) {
        [IO.Path]::GetFullPath($Path)
    } else {
        [IO.Path]::GetFullPath((Join-Path $rootFull $Path))
    }
    $prefix = $rootFull + '\'
    $probe = $combined.TrimEnd('\')
    if (-not ($probe.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or ($probe + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
        throw "$Label path escapes its required root."
    }
    return Assert-TelephoneExistingComponentChain -Path $probe -Root $rootFull -Label $Label
}

function Assert-TelephoneExistingComponentChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$RequireRegularFile
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $probe = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $prefix = $rootFull + '\'
    if (-not ($probe.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or ($probe + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
        throw "$Label path escapes its required root."
    }

    $relative = [IO.Path]::GetRelativePath($rootFull, $probe)
    if ($relative.StartsWith('..', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label path escapes its required root."
    }

    $current = $rootFull
    if (-not [IO.Directory]::Exists($current)) {
        throw "$Label trusted root is missing."
    }
    $rootItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) {
        throw "$Label trusted root must be a directory."
    }
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label path is a reparse point."
    }

    $segments = [Collections.Generic.List[string]]::new()
    foreach ($part in @($relative.Replace('/', '\').Split([char]'\'))) {
        if ([string]::IsNullOrEmpty($part) -or $part -ceq '.') { continue }
        [void]$segments.Add([string]$part)
    }
    if ($segments.Count -eq 0) {
        if ($RequireRegularFile) { throw "$Label must be a regular file, not a directory." }
        return $current
    }

    for ($i = 0; $i -lt $segments.Count; $i++) {
        $segment = [string]$segments[$i]
        $isLast = ($i -eq ($segments.Count - 1))
        if ($segment -ceq '..' -or $segment.IndexOfAny([char[]]@('*', '?', '"', '<', '>', '|')) -ge 0) {
            throw "$Label path escape is not allowed."
        }
        if (-not [IO.Directory]::Exists($current)) {
            throw "$Label path component is missing."
        }
        $currentInfo = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (-not $currentInfo.PSIsContainer) {
            throw "$Label path component is not a directory."
        }
        if (($currentInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label path is a reparse point."
        }

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
            if ($RequireRegularFile -or -not $isLast) {
                throw "$Label path component is missing."
            }
            return [IO.Path]::GetFullPath((Join-Path $current $segment))
        }
        if ($ordinalNames.Count -ne 1) {
            throw "$Label path component is ambiguous."
        }

        $item = Get-Item -LiteralPath $matched[0] -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label path is a reparse point."
        }
        if ($isLast) {
            if ($RequireRegularFile -and $item.PSIsContainer) {
                throw "$Label must be a regular file, not a directory."
            }
            return $item.FullName
        }
        if (-not $item.PSIsContainer) {
            throw "$Label path component is not a directory."
        }
        $current = $item.FullName
    }
    return $current
}

function Assert-TelephoneContainedRegularFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Assert-TelephoneRelativePathSafe -Path $Path -Label $Label
    $rootFull = Assert-TelephoneDirectoryPath -Path $Root -Label "$Label root"
    $combined = if ([IO.Path]::IsPathRooted($Path)) {
        [IO.Path]::GetFullPath($Path)
    } else {
        [IO.Path]::GetFullPath((Join-Path $rootFull $Path))
    }
    $resolved = Assert-TelephoneExistingComponentChain -Path $combined -Root $rootFull -Label $Label -RequireRegularFile
    return Assert-TelephoneRegularFilePath -Path $resolved -Label $Label
}

function Test-TelephoneLooksRemotePath {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return ($text -match '(?i)https?://|webhook://|callback://')
}

function Test-TelephoneCompletePathChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Root = '',
        [string]$Label = 'Path',
        [switch]$AllowMissing,
        [switch]$RequireRegularFile
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [ordered]@{ ok = $false; path = ''; error = 'UNREADABLE_EVIDENCE' }
    }
    if (Test-TelephoneLooksRemotePath -Value $Path) {
        return [ordered]@{ ok = $false; path = [string]$Path; error = 'PATH_ESCAPE' }
    }
    try {
        Assert-TelephoneRelativePathSafe -Path $Path -Label $Label
        $probe = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $volume = [IO.Path]::GetPathRoot($probe)
        if ([string]::IsNullOrWhiteSpace($volume)) {
            return [ordered]@{ ok = $false; path = $probe; error = 'PATH_ESCAPE' }
        }
        $afterVolume = $probe.Substring([Math]::Min($probe.Length, $volume.Length))
        if ($afterVolume.IndexOf(':') -ge 0) {
            return [ordered]@{ ok = $false; path = $probe; error = 'PATH_ESCAPE' }
        }
        if (-not [string]::IsNullOrWhiteSpace($Root)) {
            $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
            $prefix = $rootFull + '\'
            if (-not ($probe.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or ($probe + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
                return [ordered]@{ ok = $false; path = $probe; error = 'PATH_ESCAPE' }
            }
        }
        $current = $probe
        $existing = [Collections.Generic.List[string]]::new()
        $rootStop = ''
        if (-not [string]::IsNullOrWhiteSpace($Root)) {
            $rootStop = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        }
        $volumeFull = [IO.Path]::GetFullPath($volume).TrimEnd('\')
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
                [void]$existing.Insert(0, $current)
            }
            if (-not [string]::IsNullOrWhiteSpace($rootStop) -and $current.Equals($rootStop, [StringComparison]::OrdinalIgnoreCase)) { break }
            if ($current.Equals($volumeFull, [StringComparison]::OrdinalIgnoreCase) -or $current.Equals($volume.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { break }
            $parent = [IO.Path]::GetDirectoryName($current)
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) { break }
            $current = $parent.TrimEnd('\')
        }
        foreach ($itemPath in $existing) {
            if ($itemPath.Equals($volumeFull, [StringComparison]::OrdinalIgnoreCase) -or $itemPath.Equals($volume.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            try {
                $item = Get-Item -LiteralPath $itemPath -Force -ErrorAction Stop
            } catch {
                return [ordered]@{ ok = $false; path = $probe; error = 'UNREADABLE_EVIDENCE' }
            }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return [ordered]@{ ok = $false; path = $probe; error = 'REPARSE_POINT' }
            }
        }
        $existsFile = [IO.File]::Exists($probe)
        $existsDir = [IO.Directory]::Exists($probe)
        if (-not $existsFile -and -not $existsDir) {
            if (-not $AllowMissing) {
                return [ordered]@{ ok = $false; path = $probe; error = 'UNREADABLE_EVIDENCE' }
            }
            return [ordered]@{ ok = $true; path = $probe; error = '' }
        }
        if ($RequireRegularFile) {
            try {
                $null = Assert-TelephoneRegularFilePath -Path $probe -Label $Label
            } catch {
                $message = [string]$_.Exception.Message
                if ($message -match 'reparse') {
                    return [ordered]@{ ok = $false; path = $probe; error = 'REPARSE_POINT' }
                }
                return [ordered]@{ ok = $false; path = $probe; error = 'UNREADABLE_EVIDENCE' }
            }
        }
        return [ordered]@{ ok = $true; path = $probe; error = '' }
    } catch {
        $message = [string]$_.Exception.Message
        $code = 'UNREADABLE_EVIDENCE'
        if ($message -match 'reparse') { $code = 'REPARSE_POINT' }
        elseif ($message -match 'escape') { $code = 'PATH_ESCAPE' }
        return [ordered]@{ ok = $false; path = [string]$Path; error = $code }
    }
}

function Read-TelephoneSharedUtf8 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $stream = [IO.FileStream]::new(
        $full,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    )
    try {
        $memory = [IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
        } finally {
            $memory.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
    return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
}

function Read-TelephoneJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('dispatch', 'receipt', 'lead-binding', 'adapter', 'catalog', 'release-manifest', 'codex-app-server-lead-profile', 'codex-app-server-lead-run', 'codex-app-server-lead-status', 'codex-app-server-lead-intent', 'codex-app-server-lead-bound-turn', 'codex-app-server-lead-ack', 'codex-app-server-lead-owner', 'codex-app-server-lead-child', 'codex-app-server-lead-result', 'codex-app-server-lead-failure', 'codex-app-server-lead-recovery', 'codex-app-server-lead-status-sources', 'lifecycle-status', 'dashboard-config', 'dashboard-project-descriptor', 'dashboard-lifecycle-event', 'dashboard-projection', 'dashboard-closure', 'telephone-line-batch', 'wired-supervisor-request', 'wired-supervisor-owner', 'wired-supervisor-status', 'wired-supervisor-control', 'control-plane-wave-spec', 'control-plane-wave-manifest', 'control-plane-current-pointer', 'control-plane-current-state', 'control-plane-continuation-capsule', 'control-plane-action-intent', 'control-plane-action-result', 'control-plane-event', 'control-plane-transition', 'control-plane-history-index', 'control-plane-lane-attempt', 'control-plane-performance-evidence', 'control-plane-failure-matrix-evidence', 'control-plane-release-gates-evidence')]
        [string]$SchemaName
    )

    $identity = Get-TelephoneFileIdentity -Path $Path
    $text = [Text.UTF8Encoding]::new($false, $true).GetString((Read-TelephoneFileBytes -Path ([string]$identity.path)))
    if (-not [string]::IsNullOrWhiteSpace($SchemaName)) {
        Assert-TelephoneJsonSchema -JsonText $text -SchemaName $SchemaName -Label ([IO.Path]::GetFileName($Path))
    }
    return [ordered]@{
        identity = $identity
        value = $text | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
        text = $text
    }
}

function Write-TelephoneBytesCreateNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    try {
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        [IO.File]::Move($temporary, $full)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    return Get-TelephoneFileIdentity -Path $full
}

function Write-TelephoneJsonCreateNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = ($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    return Write-TelephoneBytesCreateNew -Path $Path -Bytes $bytes
}

function Write-TelephoneTextCreateNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    return Write-TelephoneBytesCreateNew -Path $Path -Bytes $bytes
}

function Write-TelephoneBytesReplace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    $backup = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.bak-' + [Guid]::NewGuid().ToString('N'))
    try {
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        if ([IO.File]::Exists($full)) {
            [IO.File]::Replace($temporary, $full, $backup)
            if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
        } else {
            [IO.File]::Move($temporary, $full)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
    return Get-TelephoneFileIdentity -Path $full
}

function Write-TelephoneJsonReplace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $json = ($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    return Write-TelephoneBytesReplace -Path $Path -Bytes $bytes
}

function Assert-TelephoneDispatchRequestText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$JsonText)

    $doc = [System.Text.Json.JsonDocument]::Parse($JsonText)
    try {
        $root = $doc.RootElement
        Assert-TelephoneObjectFieldAllowlist -Element $root -Allowed @(
            'protocol_version', 'line_job_id', 'project', 'stage', 'role', 'route', 'summary', 'lead', 'nested_target', 'command', 'batch', 'control_plane'
        ) -Label 'Dispatch request'
        $protocol = Get-TelephoneJsonPropertyValue -Element $root -Name 'protocol_version'
        if ($null -eq $protocol -or ([System.Text.Json.JsonElement]$protocol).GetString() -cne 'telephone-line-dispatch-v1') {
            throw 'Unsupported telephone-line dispatch protocol.'
        }
        $lead = Get-TelephoneJsonPropertyValue -Element $root -Name 'lead'
        if ($null -eq $lead) { throw 'Dispatch request is missing lead.' }
        Assert-TelephoneObjectFieldAllowlist -Element $lead -Allowed @(
            'protocol_version', 'session_id', 'worktree', 'launcher', 'binding_file'
        ) -Label 'Lead'
        $nested = Get-TelephoneJsonPropertyValue -Element $root -Name 'nested_target'
        if ($null -ne $nested) {
            Assert-TelephoneObjectFieldAllowlist -Element $nested -Allowed @(
                'protocol_version', 'session_id', 'worktree', 'launcher', 'binding_file'
            ) -Label 'Nested target'
            $nestedLauncher = Get-TelephoneJsonPropertyValue -Element $nested -Name 'launcher'
            if ($null -ne $nestedLauncher) {
                Assert-TelephoneObjectFieldAllowlist -Element $nestedLauncher -Allowed @('path', 'arguments') -Label 'Nested target launcher'
            }
        }
        $launcher = Get-TelephoneJsonPropertyValue -Element $lead -Name 'launcher'
        if ($null -ne $launcher) {
            Assert-TelephoneObjectFieldAllowlist -Element $launcher -Allowed @('path', 'arguments') -Label 'Lead launcher'
        }
        $command = Get-TelephoneJsonPropertyValue -Element $root -Name 'command'
        if ($null -eq $command) { throw 'Dispatch request is missing command.' }
        Assert-TelephoneObjectFieldAllowlist -Element $command -Allowed @(
            'executable', 'working_directory', 'arguments', 'stdin_file'
        ) -Label 'Command'
        $batch = Get-TelephoneJsonPropertyValue -Element $root -Name 'batch'
        if ($null -ne $batch) {
            Assert-TelephoneObjectFieldAllowlist -Element $batch -Allowed @(
                'protocol_version', 'batch_id', 'package_id', 'package_ids', 'n', 'retry_of'
            ) -Label 'Batch'
        }
        $controlPlane = Get-TelephoneJsonPropertyValue -Element $root -Name 'control_plane'
        if ($null -ne $controlPlane) {
            Assert-TelephoneObjectFieldAllowlist -Element $controlPlane -Allowed @(
                'protocol_version', 'project', 'project_epoch', 'wave_id', 'control_state_root', 'supervisor_state_root', 'install_root', 'manifest_path', 'source_spec', 'authority',
                'activation_generation', 'lead_run_id', 'package_id', 'batch_id', 'attempt', 'route', 'workspace', 'write_lease_id'
            ) -Label 'Control-plane job binding'
        }
    } finally {
        $doc.Dispose()
    }
}

function Read-TelephoneLeadBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Lead)

    if ($null -eq $Lead) { throw 'Lead binding is required.' }
    $callerSessionId = if ($Lead.Contains('session_id')) { [string]$Lead.session_id } else { '' }
    $callerWorktree = if ($Lead.Contains('worktree')) { [string]$Lead.worktree } else { '' }
    $binding = $null
    if ($Lead.Contains('binding_file') -and -not [string]::IsNullOrWhiteSpace([string]$Lead.binding_file)) {
        $bindingRead = Read-TelephoneJson -Path ([string]$Lead.binding_file) -SchemaName 'lead-binding'
        $binding = $bindingRead.value
    } else {
        if ($null -eq $Lead.launcher) { throw 'Lead launcher is required.' }
        $launcherArguments = $Lead.launcher.arguments
        if ($launcherArguments -is [string] -or $launcherArguments -isnot [Collections.IEnumerable]) {
            throw 'Lead launcher arguments must be an array.'
        }
        $binding = [ordered]@{
            protocol_version = [string]$Lead.protocol_version
            session_id = [string]$Lead.session_id
            worktree = [string]$Lead.worktree
            launcher = [ordered]@{
                path = [string]$Lead.launcher.path
                arguments = @($launcherArguments | ForEach-Object { [string]$_ })
            }
        }
        Assert-TelephoneJsonSchema -JsonText (($binding | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n") -SchemaName 'lead-binding' -Label 'Lead binding'
    }

    if ([string]$binding.protocol_version -cne 'telephone-line-lead-binding-v1') {
        throw 'Lead binding protocol is invalid.'
    }
    $sessionId = [string]$binding.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'Lead binding session id is required.' }
    if (-not [string]::IsNullOrWhiteSpace($callerSessionId) -and $callerSessionId -cne $sessionId) {
        throw 'Caller-supplied session id does not match the frozen Lead binding.'
    }
    $worktree = Assert-TelephoneDirectoryPath -Path ([string]$binding.worktree) -Label 'Lead worktree'
    if (-not [string]::IsNullOrWhiteSpace($callerWorktree)) {
        $callerFull = [IO.Path]::GetFullPath($callerWorktree).TrimEnd('\')
        if (-not $callerFull.Equals($worktree, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Caller-supplied worktree does not match the frozen Lead binding.'
        }
    }
    $launcherPath = Assert-TelephoneRegularFilePath -Path ([string]$binding.launcher.path) -Label 'Lead launcher'
    $launcherArguments = @($binding.launcher.arguments | ForEach-Object { [string]$_ })
    return [ordered]@{
        protocol_version = 'telephone-line-lead-binding-v1'
        session_id = $sessionId
        worktree = $worktree
        launcher = [ordered]@{
            path = $launcherPath
            arguments = $launcherArguments
        }
    }
}

function Resolve-TelephoneLeadSessionId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Lead)

    return [string](Read-TelephoneLeadBinding -Lead $Lead).session_id
}

function Assert-TelephoneReceiptBound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$ReceiptRead,
        [Parameter(Mandatory = $true)][object]$DispatchRead
    )

    if ([string]::IsNullOrWhiteSpace([string]$ReceiptRead.text)) {
        throw 'Telephone receipt text is missing for schema validation.'
    }
    Assert-TelephoneJsonSchema -JsonText ([string]$ReceiptRead.text) -SchemaName 'receipt' -Label 'Telephone receipt'
    $receipt = $ReceiptRead.value
    $dispatch = $DispatchRead.value
    if ([string]$receipt.protocol_version -cne 'telephone-line-receipt-v1') { throw 'Telephone receipt protocol is invalid.' }
    foreach ($field in @('line_job_id', 'project', 'stage', 'role', 'route', 'summary')) {
        if ([string]$receipt[$field] -cne [string]$dispatch[$field]) { throw "Telephone receipt is not bound to dispatch field: $field" }
    }
    if (-not $receipt.Contains('dispatch') -or $null -eq $receipt.dispatch) { throw 'Telephone receipt lacks its dispatch identity.' }
    Assert-TelephoneFileIdentity -Expected $DispatchRead.identity -Actual $receipt.dispatch -Label 'Telephone receipt dispatch'
    if ($receipt.transport_complete -isnot [bool]) { throw 'Telephone receipt lacks a strict transport terminal.' }
    if ($receipt.absolute_task_timeout -ne $false -or $receipt.automatic_rerun -ne $false -or $receipt.project_judgment -ne $false) {
        throw 'Telephone receipt crossed the transport-only boundary.'
    }
    return $receipt
}

function New-TelephoneTransportFailureReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$DispatchRead,
        [Parameter(Mandatory = $true)][string]$ErrorCode,
        [Parameter(Mandatory = $true)][string]$ErrorMessage,
        [AllowNull()][object]$StartedAtUtc
    )

    $dispatch = $DispatchRead.value
    $started = $null
    if ($null -ne $StartedAtUtc -and -not [string]::IsNullOrWhiteSpace([string]$StartedAtUtc)) {
        $started = [string]$StartedAtUtc
    }
    return [ordered]@{
        protocol_version = 'telephone-line-receipt-v1'
        line_job_id = [string]$dispatch.line_job_id
        project = [string]$dispatch.project
        stage = [string]$dispatch.stage
        role = [string]$dispatch.role
        route = [string]$dispatch.route
        summary = [string]$dispatch.summary
        dispatch = $DispatchRead.identity
        transport_complete = $false
        command_exit_code = $null
        command_error_code = Get-TelephoneDurableErrorCode -ErrorCode $ErrorCode
        command_error_message = Get-TelephonePublicErrorMessage -ErrorCode $ErrorCode
        stdout = $null
        stderr = $null
        started_at_utc = $started
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        absolute_task_timeout = $false
        automatic_rerun = $false
        project_judgment = $false
    }
}

function New-TelephoneWakeIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LineJobId,
        [Parameter(Mandatory = $true)][object]$ReceiptIdentity,
        [Parameter(Mandatory = $true)][string]$LeadSessionId,
        [ValidateSet('owner', 'nested')][string]$Kind = 'owner'
    )

    $jobId = ([string]$LineJobId).ToLowerInvariant()
    $receiptSha = [string]$ReceiptIdentity.sha256
    $sessionId = [string]$LeadSessionId
    if ([string]::IsNullOrWhiteSpace($jobId) -or [string]::IsNullOrWhiteSpace($receiptSha) -or [string]::IsNullOrWhiteSpace($sessionId)) {
        throw 'Wake identity inputs are incomplete.'
    }
    $seed = $jobId + '|' + $receiptSha + '|' + $sessionId
    $wakeRunId = 'telephone-' + $jobId
    if ($Kind -ceq 'nested') {
        $seed = $seed + '|nested'
        $wakeRunId = 'telephone-' + $jobId + '-nested'
    }
    $material = [Text.UTF8Encoding]::new($false).GetBytes($seed)
    $wakeKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($material)).ToLowerInvariant()
    return [ordered]@{
        protocol_version = 'telephone-line-wake-identity-v1'
        line_job_id = $jobId
        receipt = $ReceiptIdentity
        lead_session_id = $sessionId
        kind = $Kind
        wake_run_id = $wakeRunId
        wake_key = $wakeKey
    }
}

function Test-TelephoneOwnerAlive {
    [CmdletBinding()]
    param([AllowNull()][object]$Owner)

    if ($null -eq $Owner) { return $false }
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

function Disable-TelephoneHandleInherit {
    [CmdletBinding()]
    param([AllowNull()][object]$FileStream)
    if ($null -eq $FileStream) { return }
    try {
        if ($null -eq ('TelephoneNativeHandles' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class TelephoneNativeHandles {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);
}
"@
        }
        $raw = $FileStream.SafeFileHandle.DangerousGetHandle()
        [void][TelephoneNativeHandles]::SetHandleInformation($raw, 1, 0)
    } catch { }
}

function Open-TelephoneExclusiveGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(0, 60000)][int]$WaitMilliseconds = 0
    )

    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) | Out-Null
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($WaitMilliseconds)
    do {
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            Disable-TelephoneHandleInherit -FileStream $stream
            return $stream
        } catch [IO.IOException] {
            if ([DateTimeOffset]::UtcNow -ge $deadline) { return $null }
            Start-Sleep -Milliseconds 25
        }
    } while ($true)
}

function Get-TelephoneDictString {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Dict,
        [Parameter(Mandatory = $true)][string]$Key
    )
    if ($Dict -isnot [Collections.IDictionary] -or -not $Dict.Contains($Key) -or $null -eq $Dict[$Key]) { return '' }
    return [string]$Dict[$Key]
}

function Read-TelephoneJsonlCompleteRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$StopAfterNativeWakePair,
        [string]$ExpectedSessionId = ''
    )

    $text = Read-TelephoneSharedUtf8 -Path $Path
    if ([string]::IsNullOrEmpty($text)) { return @() }
    if ($text.StartsWith([char]0xFEFF)) {
        throw 'Lead event stream must not contain a UTF-8 BOM.'
    }
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $endsWithNewline = $normalized.EndsWith("`n")
    $lines = $normalized.Split([char]0x0A)
    $records = [Collections.Generic.List[Collections.IDictionary]]::new()
    $lastIndex = $lines.Length - 1
    for ($i = 0; $i -le $lastIndex; $i++) {
        $line = [string]$lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $isTrailingIncomplete = ($i -eq $lastIndex -and -not $endsWithNewline)
        try {
            $record = $line | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
        } catch {
            if ($isTrailingIncomplete) { break }
            throw 'Lead event stream contains a malformed complete record.'
        }
        if ($record -isnot [Collections.IDictionary]) {
            if ($isTrailingIncomplete) { break }
            throw 'Lead event stream contains a malformed complete record.'
        }
        $records.Add($record)
        if ($StopAfterNativeWakePair) {
            if ([string]::IsNullOrWhiteSpace($ExpectedSessionId)) {
                throw 'Native wake event pair requires the expected session id.'
            }
            if (Test-TelephoneNativeWakeEventPair -Records $records -ExpectedSessionId $ExpectedSessionId) {
                break
            }
        }
    }
    return @($records)
}

function Test-TelephoneNativeLeadRunBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Run,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId,
        [Parameter(Mandatory = $true)][string]$ExpectedRunId,
        [Parameter(Mandatory = $true)][string]$EventsPath
    )
    $protocol = Get-TelephoneDictString -Dict $Run -Key 'protocol_version'
    if ($protocol -cne 'huhu-concerto-cli-lead-run-v1') {
        throw 'Lead run metadata protocol is not a native wired Lead run.'
    }
    $resume = Get-TelephoneDictString -Dict $Run -Key 'resume_session_id'
    if ([string]::IsNullOrWhiteSpace($resume) -or $resume -cne $ExpectedSessionId) {
        throw 'Lead run metadata does not bind the expected resume session.'
    }
    $runId = Get-TelephoneDictString -Dict $Run -Key 'run_id'
    $requested = Get-TelephoneDictString -Dict $Run -Key 'requested_run_id'
    if ([string]::IsNullOrWhiteSpace($runId) -and [string]::IsNullOrWhiteSpace($requested)) {
        throw 'Lead run metadata does not bind the requested wake run.'
    }
    if (-not [string]::IsNullOrWhiteSpace($runId) -and $runId -cne $ExpectedRunId) {
        throw 'Lead run metadata binds a different wake run.'
    }
    if (-not [string]::IsNullOrWhiteSpace($requested) -and $requested -cne $ExpectedRunId) {
        throw 'Lead run metadata requested a different wake run.'
    }
    $statedEvents = Get-TelephoneDictString -Dict $Run -Key 'events_path'
    if (-not [string]::IsNullOrWhiteSpace($statedEvents)) {
        $statedFull = [IO.Path]::GetFullPath($statedEvents).TrimEnd('\')
        $expectedFull = [IO.Path]::GetFullPath($EventsPath).TrimEnd('\')
        if (-not $statedFull.Equals($expectedFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Lead run metadata events path is outside the exact run root.'
        }
    }
    return $true
}

function Test-TelephoneNativeWakeEventPair {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][AllowNull()][object]$Records,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId
    )
    $items = [Collections.Generic.List[object]]::new()
    if ($null -eq $Records) {
    } elseif ($Records -is [Collections.IDictionary]) {
        $items.Add($Records)
    } else {
        foreach ($item in @($Records)) { $items.Add($item) }
    }
    $seenExactThread = $false
    foreach ($record in $items) {
        if ($record -isnot [Collections.IDictionary]) { throw 'Lead event stream contains a malformed complete record.' }
        $type = Get-TelephoneDictString -Dict $record -Key 'type'
        if ($type -ceq 'thread.started') {
            $id = Get-TelephoneDictString -Dict $record -Key 'thread_id'
            if ([string]::IsNullOrWhiteSpace($id)) { $id = Get-TelephoneDictString -Dict $record -Key 'session_id' }
            if ([string]::IsNullOrWhiteSpace($id)) { throw 'Lead event stream has a thread.started event without a session id.' }
            if ($id -cne $ExpectedSessionId) { throw 'Lead event stream started a different session.' }
            $seenExactThread = $true
        } elseif ($type -ceq 'turn.started') {
            if (-not $seenExactThread) { throw 'Lead event stream started a turn without the matching thread.' }
            return $true
        }
    }
    return $false
}

function Test-TelephoneNativeWakeEventStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId
    )
    $records = @(Read-TelephoneJsonlCompleteRecords -Path $Path -StopAfterNativeWakePair -ExpectedSessionId $ExpectedSessionId)
    return [bool](Test-TelephoneNativeWakeEventPair -Records $records -ExpectedSessionId $ExpectedSessionId)
}

function Test-TelephonePathContainedInRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    } catch {
        return $false
    }
    if ($full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $rootFull + '\'
    return $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-TelephoneNativeWakeInputBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Run,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [string]$ExpectedWakeKey = '',
        [string]$ExpectedReceiptSha256 = ''
    )
    if ([string]::IsNullOrWhiteSpace($ExpectedWakeKey) -and [string]::IsNullOrWhiteSpace($ExpectedReceiptSha256)) {
        return $true
    }
    $promptPath = ''
    $promptSha = ''
    if ($Run.Contains('prompt') -and $Run['prompt'] -is [Collections.IDictionary]) {
        $prompt = $Run['prompt']
        if ($prompt.Contains('path')) { $promptPath = [string]$prompt['path'] }
        if ($prompt.Contains('sha256')) { $promptSha = [string]$prompt['sha256'] }
    }
    if ([string]::IsNullOrWhiteSpace($promptPath)) {
        throw 'Lead native attempt is missing the frozen prompt identity.'
    }
    if ([string]::IsNullOrWhiteSpace($promptSha) -or $promptSha -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw 'Lead native attempt is missing the frozen prompt hash.'
    }
    $fullPrompt = [IO.Path]::GetFullPath($promptPath)
    if (-not (Test-TelephonePathContainedInRoot -Path $fullPrompt -Root $RunRoot) -and -not [IO.File]::Exists($fullPrompt)) {
        throw 'Lead native attempt prompt is missing.'
    }
    if (-not [IO.File]::Exists($fullPrompt)) {
        throw 'Lead native attempt prompt is missing.'
    }
    $identity = Get-TelephoneFileIdentity -Path $fullPrompt
    if ([string]$identity.sha256 -cne $promptSha.ToLowerInvariant()) {
        throw 'Lead native attempt prompt identity drifted from the frozen input.'
    }
    $body = [IO.File]::ReadAllText($fullPrompt)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedReceiptSha256)) {
        $receiptLine = '(?m)^- receipt_sha256:\s*' + [regex]::Escape($ExpectedReceiptSha256) + '\s*$'
        if ($body -notmatch $receiptLine) {
            throw 'Lead native attempt prompt does not contain the intended receipt.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedWakeKey)) {
        $wakeLine = '(?m)^- wake_key:\s*' + [regex]::Escape($ExpectedWakeKey) + '\s*$'
        if ($body -notmatch $wakeLine) {
            throw 'Lead native attempt prompt does not contain the intended wake key.'
        }
    }
    return $true
}

function Write-TelephoneCanonicalWakeAck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$RunId = '',
        [string]$WakeKey = '',
        [string]$ReceiptSha256 = ''
    )
    $ack = [ordered]@{
        protocol_version = 'telephone-line-lead-wake-ack-v1'
        session_id = $SessionId
        event = 'turn.started'
        acknowledged_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if (-not [string]::IsNullOrWhiteSpace($RunId)) { $ack['run_id'] = [string]$RunId }
    if (-not [string]::IsNullOrWhiteSpace($WakeKey)) { $ack['wake_key'] = [string]$WakeKey }
    if (-not [string]::IsNullOrWhiteSpace($ReceiptSha256)) { $ack['receipt_sha256'] = [string]$ReceiptSha256 }
    try {
        $null = Write-TelephoneJsonCreateNew -Path $Path -Value $ack
    } catch [IO.IOException] {
        if (-not [IO.File]::Exists($Path)) { throw }
        $existingText = Read-TelephoneSharedUtf8 -Path $Path
        $existing = $existingText | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        if ([string]$existing.protocol_version -cne 'telephone-line-lead-wake-ack-v1') {
            throw 'Lead wake acknowledgment protocol is invalid.'
        }
        if ([string]$existing.session_id -cne $SessionId) {
            throw 'Lead wake run started another session.'
        }
        if ([string]$existing.event -cne 'turn.started') {
            throw 'Lead wake acknowledgment is missing an event.'
        }
        if (-not [string]::IsNullOrWhiteSpace($RunId) -and $existing.Contains('run_id') -and -not [string]::IsNullOrWhiteSpace([string]$existing['run_id']) -and [string]$existing['run_id'] -cne $RunId) {
            throw 'Lead wake acknowledgment binds a different wake run.'
        }
        if (-not [string]::IsNullOrWhiteSpace($WakeKey) -and $existing.Contains('wake_key') -and -not [string]::IsNullOrWhiteSpace([string]$existing['wake_key']) -and [string]$existing['wake_key'] -cne $WakeKey) {
            throw 'Lead wake acknowledgment binds a different receipt wake key.'
        }
        if (-not [string]::IsNullOrWhiteSpace($ReceiptSha256) -and $existing.Contains('receipt_sha256') -and -not [string]::IsNullOrWhiteSpace([string]$existing['receipt_sha256']) -and [string]$existing['receipt_sha256'] -cne $ReceiptSha256) {
            throw 'Lead wake acknowledgment binds a different receipt.'
        }
    }
}

# Current Understanding (execution, 2026-08-27 native wired ack):
# 1. Phase: close black-box f6ac98b6 LEAD_WAKE_AMBIGUOUS on candidate 1b02e9b; preserve accepted App Server/mock ack; amend the same one commit over 6c9d25e.
# 2. Denominator: exact run-root lead-run.json plus ordered native thread.started then turn.started is a wired ack; persist canonical lead-wake-ack.json; no invented success.
# 3. Only next step: recognize that pair, prove delivery while Lead is active, fail-closed negatives, frozen union.
# 4. Frozen non-goals: no schema/App Server/adapter/dashboard writes, no runtime activation, no real smoke.
# 5. Exit: focused native proofs + frozen union, clean one commit over 6c9d25e, self_accepted=false; not project PASS.
function Wait-TelephoneLeadWakeAcknowledged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId,
        [string]$ExpectedRunId = '',
        [string]$ExpectedWakeKey = '',
        [string]$ExpectedReceiptSha256 = '',
        [ValidateRange(1, 600)][int]$StartupTimeoutSeconds = 120
    )

    $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    $ackPath = Join-Path $root 'lead-wake-ack.json'
    $ownerPath = Join-Path $root 'owner.json'
    $finalPath = Join-Path $root 'launcher-final.txt'
    $runMetaPath = Join-Path $root 'lead-run.json'
    $eventsPath = Join-Path $root 'codex-events.jsonl'
    $expectedRun = if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId)) { [string]$ExpectedRunId } else { [IO.Path]::GetFileName($root) }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ([IO.File]::Exists($ackPath)) {
            try {
                $text = Read-TelephoneSharedUtf8 -Path $ackPath
                if ([string]::IsNullOrWhiteSpace($text)) { throw [IO.IOException]::new('Lead wake acknowledgment is still empty.') }
                $ack = $text | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
                if ([string]$ack.protocol_version -cne 'telephone-line-lead-wake-ack-v1') {
                    throw 'Lead wake acknowledgment protocol is invalid.'
                }
                if ([string]$ack.session_id -cne $ExpectedSessionId) {
                    throw 'Lead wake run started another session.'
                }
                if ([string]::IsNullOrWhiteSpace([string]$ack.event)) {
                    throw 'Lead wake acknowledgment is missing an event.'
                }
                if ($ack.Contains('run_id') -and -not [string]::IsNullOrWhiteSpace([string]$ack['run_id']) -and [string]$ack['run_id'] -cne $expectedRun) {
                    throw 'Lead wake acknowledgment binds a different wake run.'
                }
                if (-not [string]::IsNullOrWhiteSpace($ExpectedWakeKey)) {
                    if ($ack.Contains('wake_key') -and -not [string]::IsNullOrWhiteSpace([string]$ack['wake_key']) -and [string]$ack['wake_key'] -cne $ExpectedWakeKey) {
                        throw 'Lead wake acknowledgment binds a different receipt wake key.'
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($ExpectedReceiptSha256)) {
                    if ($ack.Contains('receipt_sha256') -and -not [string]::IsNullOrWhiteSpace([string]$ack['receipt_sha256']) -and [string]$ack['receipt_sha256'] -cne $ExpectedReceiptSha256) {
                        throw 'Lead wake acknowledgment binds a different receipt.'
                    }
                }
                $ackNeedsRunBind = (-not $ack.Contains('run_id') -or [string]::IsNullOrWhiteSpace([string]$ack['run_id']))
                $ackNeedsWakeBind = (-not [string]::IsNullOrWhiteSpace($ExpectedWakeKey) -and (-not $ack.Contains('wake_key') -or [string]::IsNullOrWhiteSpace([string]$ack['wake_key'])))
                $ackNeedsReceiptBind = (-not [string]::IsNullOrWhiteSpace($ExpectedReceiptSha256) -and (-not $ack.Contains('receipt_sha256') -or [string]::IsNullOrWhiteSpace([string]$ack['receipt_sha256'])))
                $promptRun = $null
                if ([IO.File]::Exists($runMetaPath)) {
                    $promptRun = (Read-TelephoneJson -Path $runMetaPath).value
                }
                $appRunPath = Join-Path $root 'run.json'
                $appRunValidated = $false
                if ($null -eq $promptRun -and [IO.File]::Exists($appRunPath)) {
                    $appRun = (Read-TelephoneJson -Path $appRunPath).value
                    if ($appRun -is [Collections.IDictionary] -and [string]$appRun.protocol_version -ceq 'telephone-line-codex-app-server-lead-run-v1') {
                        if ([string]::IsNullOrWhiteSpace([string]$appRun.run_id) -or [string]$appRun.run_id -cne $expectedRun) {
                            throw 'Lead wake acknowledgment binds a different wake run.'
                        }
                        if ([string]::IsNullOrWhiteSpace([string]$appRun.thread_id) -or [string]$appRun.thread_id -cne $ExpectedSessionId) {
                            throw 'Lead wake run started another session.'
                        }
                        $appRunValidated = $true
                        if ($appRun.Contains('callback') -and $appRun['callback'] -is [Collections.IDictionary]) {
                            $promptRun = [ordered]@{ prompt = $appRun['callback'] }
                        }
                    }
                }
                if ($ackNeedsRunBind) {
                    if ($null -ne $promptRun -and [IO.File]::Exists($runMetaPath)) {
                        $null = Test-TelephoneNativeLeadRunBinding -Run $promptRun -ExpectedSessionId $ExpectedSessionId -ExpectedRunId $expectedRun -EventsPath $eventsPath
                    } elseif ($appRunValidated) {
                        # App Server run.json protocol, run_id, and thread_id were validated above.
                    } else {
                        throw [IO.IOException]::new('Lead wake acknowledgment is missing a bound run id.')
                    }
                }
                if ($ackNeedsWakeBind -or $ackNeedsReceiptBind) {
                    if ($null -eq $promptRun) {
                        throw [IO.IOException]::new('Lead wake acknowledgment is missing the intended receipt wake key.')
                    }
                    try {
                        $null = Test-TelephoneNativeWakeInputBinding -Run $promptRun -RunRoot $root -ExpectedWakeKey $ExpectedWakeKey -ExpectedReceiptSha256 $ExpectedReceiptSha256
                    } catch {
                        $bindMsg = [string]$_.Exception.Message
                        if ($bindMsg -match 'missing|still empty|does not contain') {
                            throw [IO.IOException]::new($bindMsg)
                        }
                        throw
                    }
                }
                return [ordered]@{
                    run_root = $root
                    lead_session_id = $ExpectedSessionId
                    event = [string]$ack.event
                    run_id = $expectedRun
                    acknowledged_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
                }
            } catch [IO.IOException] {
                Start-Sleep -Milliseconds 200
                continue
            } catch [System.Text.DecoderFallbackException] {
                Start-Sleep -Milliseconds 200
                continue
            } catch {
                $isIncompleteJson = $_.Exception -is [System.Text.Json.JsonException] -or
                    [string]$_.FullyQualifiedErrorId -match 'Json' -or
                    [string]$_.Exception.Message -match 'JSON'
                if ($isIncompleteJson -and [DateTimeOffset]::UtcNow -lt $deadline) {
                    Start-Sleep -Milliseconds 200
                    continue
                }
                throw
            }
        }
        if ([IO.File]::Exists($runMetaPath)) {
            try {
                $runText = Read-TelephoneSharedUtf8 -Path $runMetaPath
                if ([string]::IsNullOrWhiteSpace($runText)) { throw [IO.IOException]::new('Lead run metadata is still empty.') }
                $runMeta = $runText | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
                if ($runMeta -isnot [Collections.IDictionary]) { throw 'Lead run metadata is not an object.' }
                $null = Test-TelephoneNativeLeadRunBinding -Run $runMeta -ExpectedSessionId $ExpectedSessionId -ExpectedRunId $expectedRun -EventsPath $eventsPath
                if ([IO.File]::Exists($eventsPath)) {
                    if (Test-TelephoneNativeWakeEventStream -Path $eventsPath -ExpectedSessionId $ExpectedSessionId) {
                        $null = Test-TelephoneNativeWakeInputBinding -Run $runMeta -RunRoot $root -ExpectedWakeKey $ExpectedWakeKey -ExpectedReceiptSha256 $ExpectedReceiptSha256
                        Write-TelephoneCanonicalWakeAck -Path $ackPath -SessionId $ExpectedSessionId -RunId $expectedRun -WakeKey $ExpectedWakeKey -ReceiptSha256 $ExpectedReceiptSha256
                        return [ordered]@{
                            run_root = $root
                            lead_session_id = $ExpectedSessionId
                            event = 'turn.started'
                            run_id = $expectedRun
                            wake_key = [string]$ExpectedWakeKey
                            receipt_sha256 = [string]$ExpectedReceiptSha256
                            acknowledged_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
                        }
                    }
                }
            } catch [IO.IOException] {
                Start-Sleep -Milliseconds 200
                continue
            } catch [System.Text.DecoderFallbackException] {
                Start-Sleep -Milliseconds 200
                continue
            } catch {
                $msg = [string]$_.Exception.Message
                if ($msg -ceq 'Lead event stream contains a malformed complete record.') { throw }
                $isIncompleteJson = $_.Exception -is [System.Text.Json.JsonException] -or
                    [string]$_.FullyQualifiedErrorId -match 'Json' -or
                    $msg -match 'JSON'
                if ($isIncompleteJson -and [DateTimeOffset]::UtcNow -lt $deadline) {
                    Start-Sleep -Milliseconds 200
                    continue
                }
                throw
            }
        }
        if ([IO.File]::Exists($ownerPath)) {
            try {
                $owner = (Read-TelephoneJson -Path $ownerPath).value
                if (-not (Test-TelephoneOwnerAlive -Owner $owner) -and -not [IO.File]::Exists($ackPath)) {
                    throw 'Lead wake process ended before accepting the resumed turn.'
                }
            } catch [IO.IOException] {
                Start-Sleep -Milliseconds 200
                continue
            }
        } elseif ([IO.File]::Exists($finalPath)) {
            throw 'Lead wake completed without an exact session acknowledgment.'
        }
        Start-Sleep -Milliseconds 200
    }
    throw 'Lead wake did not acknowledge the exact resumed turn within the startup window.'
}

function Wait-TelephoneLeadOfficialTerminal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId
    )

    $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    $finalPath = Join-Path $root 'launcher-final.txt'
    $ackPath = Join-Path $root 'lead-wake-ack.json'
    $ownerPath = Join-Path $root 'owner.json'
    $official = @('completed', 'failed', 'interrupted')
    while ($true) {
        if ([IO.File]::Exists($finalPath)) {
            try {
                $text = (Read-TelephoneSharedUtf8 -Path $finalPath).Trim()
                if ([string]::IsNullOrWhiteSpace($text)) { throw [IO.IOException]::new('Lead official terminal is still empty.') }
                if ($text -cnotin $official) { throw 'Lead official terminal is not a proven state.' }
                if ([IO.File]::Exists($ackPath)) {
                    $ackText = Read-TelephoneSharedUtf8 -Path $ackPath
                    if (-not [string]::IsNullOrWhiteSpace($ackText)) {
                        $ack = $ackText | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
                        if ([string]$ack.session_id -cne $ExpectedSessionId) {
                            throw 'Lead official terminal belongs to another session.'
                        }
                    }
                }
                return [ordered]@{
                    run_root = $root
                    session_id = $ExpectedSessionId
                    state = $text
                    recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
                }
            } catch [IO.IOException] {
                Start-Sleep -Milliseconds 200
                continue
            } catch [System.Text.DecoderFallbackException] {
                Start-Sleep -Milliseconds 200
                continue
            }
        }
        if ([IO.File]::Exists($ownerPath)) {
            try {
                $owner = (Read-TelephoneJson -Path $ownerPath).value
                if (-not (Test-TelephoneOwnerAlive -Owner $owner) -and -not [IO.File]::Exists($finalPath)) {
                    throw 'Lead wake ended without an official terminal.'
                }
            } catch [IO.IOException] {
                Start-Sleep -Milliseconds 200
                continue
            }
        } elseif ([IO.File]::Exists($ackPath) -and -not [IO.File]::Exists($finalPath)) {
            try {
                $ackText = Read-TelephoneSharedUtf8 -Path $ackPath
                if (-not [string]::IsNullOrWhiteSpace($ackText)) {
                    $ack = $ackText | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
                    if ([string]$ack.session_id -cne $ExpectedSessionId) {
                        throw 'Lead wake acknowledgment belongs to another session.'
                    }
                }
            } catch [IO.IOException] {
                Start-Sleep -Milliseconds 200
                continue
            } catch [System.Text.DecoderFallbackException] {
                Start-Sleep -Milliseconds 200
                continue
            }
        }
        Start-Sleep -Milliseconds 200
    }
}

function Get-TelephoneLifecycleEventKind {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Phase)
    switch ([string]$Phase) {
        'dispatched' { return 'lead' }
        'lead' { return 'lead' }
        'execution' { return 'execute' }
        'execute' { return 'execute' }
        'nested_target' { return 'sync' }
        'owner_acceptance' { return 'review' }
        'review' { return 'review' }
        'modify' { return 'modify' }
        'closure' { return 'closure' }
        'delivered' { return 'closure' }
        'failed' { return 'closure' }
        'retired' { return 'closure' }
        'restart' { return 'restart' }
        default { return 'lead' }
    }
}

function Get-TelephoneUtf8Sha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Read-TelephoneOptionalOwnerRecord {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return $null }
    try {
        return (Read-TelephoneJson -Path $Path).value
    } catch {
        return $null
    }
}

function Write-TelephoneCommandChildExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Dispatch,
        [AllowNull()][object]$ExitCode
    )
    if ([IO.File]::Exists([string]$Paths.command_child_exit)) { return }
    $value = [ordered]@{
        protocol_version = 'telephone-line-command-child-exit-v1'
        line_job_id = [string]$Dispatch.line_job_id
        command_exit_code = $(if ($null -eq $ExitCode -or [string]::IsNullOrWhiteSpace([string]$ExitCode)) { $null } else { [int]$ExitCode })
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try {
        $null = Write-TelephoneJsonCreateNew -Path ([string]$Paths.command_child_exit) -Value $value
    } catch [IO.IOException] { }
}

function New-TelephoneCommandBoundReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$DispatchRead,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [AllowNull()][object]$ExitCode,
        [string]$ErrorCode = $null,
        [string]$ErrorMessage = $null,
        [AllowNull()][object]$StartedAtUtc,
        [bool]$TransportComplete = $true
    )
    $dispatch = $DispatchRead.value
    $started = $null
    if ($null -ne $StartedAtUtc -and -not [string]::IsNullOrWhiteSpace([string]$StartedAtUtc)) {
        $started = [string]$StartedAtUtc
    }
    $code = $null
    if ($null -ne $ExitCode -and -not [string]::IsNullOrWhiteSpace([string]$ExitCode)) {
        try { $code = [int]$ExitCode } catch { $code = $null }
    }
    return [ordered]@{
        protocol_version = 'telephone-line-receipt-v1'
        line_job_id = [string]$dispatch.line_job_id
        project = [string]$dispatch.project
        stage = [string]$dispatch.stage
        role = [string]$dispatch.role
        route = [string]$dispatch.route
        summary = [string]$dispatch.summary
        dispatch = $DispatchRead.identity
        transport_complete = [bool]$TransportComplete
        command_exit_code = $code
        command_error_code = $(if ([string]::IsNullOrWhiteSpace($ErrorCode)) { $null } else { Get-TelephoneDurableErrorCode -ErrorCode $ErrorCode })
        command_error_message = $(if ([string]::IsNullOrWhiteSpace($ErrorCode)) { $null } else { Get-TelephonePublicErrorMessage -ErrorCode $ErrorCode })
        stdout = if ([IO.File]::Exists([string]$Paths.stdout)) { Get-TelephoneFileIdentity -Path ([string]$Paths.stdout) } else { $null }
        stderr = if ([IO.File]::Exists([string]$Paths.stderr)) { Get-TelephoneFileIdentity -Path ([string]$Paths.stderr) } else { $null }
        started_at_utc = $started
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        absolute_task_timeout = $false
        automatic_rerun = $false
        project_judgment = $false
    }
}

function Publish-TelephoneCommandReceiptOnce {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][object]$Receipt
    )
    try {
        return (Write-TelephoneJsonCreateNew -Path ([string]$Paths.receipt) -Value $Receipt)
    } catch [IO.IOException] {
        return $null
    }
}

function Test-TelephoneCommandStdoutPresent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Paths)
    if (-not [IO.File]::Exists([string]$Paths.stdout)) { return $false }
    try {
        return ([IO.FileInfo]::new([string]$Paths.stdout).Length -gt 0)
    } catch {
        return $false
    }
}

function Test-TelephoneCommandLaunchAlive {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Paths)
    if (-not [IO.File]::Exists([string]$Paths.command_launch)) { return $false }
    try {
        $launch = (Read-TelephoneJson -Path ([string]$Paths.command_launch)).value
        $owner = $null
        if ($launch -is [Collections.IDictionary] -and $launch.Contains('owner')) { $owner = $launch.owner }
        return (Test-TelephoneOwnerAlive -Owner $owner)
    } catch {
        return $false
    }
}

function Sync-TelephoneCommandOwnerCompletion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Paths)

    if ([IO.File]::Exists([string]$Paths.receipt)) { return 'receipt' }
    if (-not [IO.File]::Exists([string]$Paths.dispatch)) { return 'no_dispatch' }
    if ((Test-TelephoneCommandLaunchAlive -Paths $Paths) -and -not [IO.File]::Exists([string]$Paths.command_owner)) {
        return 'waiting_launch'
    }
    $gate = Open-TelephoneExclusiveGate -Path ([string]$Paths.command_gate) -WaitMilliseconds 250
    if ($null -eq $gate) { return 'busy' }
    try {
        if ([IO.File]::Exists([string]$Paths.receipt)) { return 'receipt' }
        $dispatchRead = Read-TelephoneJson -Path ([string]$Paths.dispatch) -SchemaName 'dispatch'
        $dispatch = $dispatchRead.value
        $owner = Read-TelephoneOptionalOwnerRecord -Path ([string]$Paths.command_owner)
        $child = Read-TelephoneOptionalOwnerRecord -Path ([string]$Paths.command_child)
        $ownerAlive = Test-TelephoneOwnerAlive -Owner $owner
        $childAlive = Test-TelephoneOwnerAlive -Owner $child
        $startedAt = $null
        if ($null -ne $child -and -not [string]::IsNullOrWhiteSpace([string]$child.started_at_utc)) {
            $startedAt = [string]$child.started_at_utc
        } elseif ($null -ne $owner -and -not [string]::IsNullOrWhiteSpace([string]$owner.started_at_utc)) {
            $startedAt = [string]$owner.started_at_utc
        }

        # The live command host owns publication. Child exit and its durable
        # exit/receipt records are separate writes; recovery must not win that gap.
        if ($ownerAlive) { return 'waiting_owner' }

        if ($childAlive) {
            try {
                $proc = Get-Process -Id ([int]$child.pid) -ErrorAction Stop
                try {
                    $ticks = [int64]$proc.StartTime.ToUniversalTime().Ticks
                    if ($ticks -eq [int64]$child.start_time_utc_ticks) {
                        $null = $proc.WaitForExit(400)
                        if ($proc.HasExited) {
                            $code = $proc.ExitCode
                            Write-TelephoneCommandChildExit -Paths $Paths -Dispatch $dispatch -ExitCode $code
                            $receipt = New-TelephoneCommandBoundReceipt -DispatchRead $dispatchRead -Paths $Paths -ExitCode $code -StartedAtUtc $startedAt -TransportComplete $true
                            $null = Publish-TelephoneCommandReceiptOnce -Paths $Paths -Receipt $receipt
                            return 'reconciled'
                        }
                    }
                } finally {
                    $proc.Dispose()
                }
            } catch { }
            return 'waiting_child'
        }

        if ([IO.File]::Exists([string]$Paths.command_child_exit)) {
            $exit = $null
            try { $exit = (Read-TelephoneJson -Path ([string]$Paths.command_child_exit)).value } catch { $exit = $null }
            if ($null -eq $exit) { return 'malformed_child_exit' }
            $code = $null
            try { $code = $exit.command_exit_code } catch { $code = $null }
            $receipt = New-TelephoneCommandBoundReceipt -DispatchRead $dispatchRead -Paths $Paths -ExitCode $code -StartedAtUtc $startedAt -TransportComplete $true
            $null = Publish-TelephoneCommandReceiptOnce -Paths $Paths -Receipt $receipt
            return 'reconciled'
        }

        $produced = Test-TelephoneCommandStdoutPresent -Paths $Paths
        if ($null -ne $child -and -not $childAlive -and $produced) {
            $receipt = New-TelephoneCommandBoundReceipt -DispatchRead $dispatchRead -Paths $Paths -ExitCode $null -StartedAtUtc $startedAt -TransportComplete $true
            $null = Publish-TelephoneCommandReceiptOnce -Paths $Paths -Receipt $receipt
            return 'reconciled'
        }

        if (-not $ownerAlive -and -not $childAlive) {
            if ($null -eq $owner -and $null -eq $child) { return 'no_owner' }
            if (-not $produced) {
                $receipt = New-TelephoneTransportFailureReceipt -DispatchRead $dispatchRead `
                    -ErrorCode 'COMMAND_HOST_INTERRUPTED' `
                    -ErrorMessage (Get-TelephonePublicErrorMessage -ErrorCode 'COMMAND_HOST_INTERRUPTED') `
                    -StartedAtUtc $startedAt
                $receipt.stdout = if ([IO.File]::Exists([string]$Paths.stdout)) { Get-TelephoneFileIdentity -Path ([string]$Paths.stdout) } else { $null }
                $receipt.stderr = if ([IO.File]::Exists([string]$Paths.stderr)) { Get-TelephoneFileIdentity -Path ([string]$Paths.stderr) } else { $null }
                $null = Publish-TelephoneCommandReceiptOnce -Paths $Paths -Receipt $receipt
                return 'interrupted'
            }
        }
        return 'pending'
    } finally {
        $gate.Dispose()
    }
}

function Write-TelephonePublicLifecycleEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Transport,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$LeadSessionId,
        [string]$LeadRunId = '',
        [string]$LineJobId = '',
        [string]$ReceiptSha256 = $null,
        [AllowNull()][object]$Provenance = $null
    )

    if (Test-TelephoneDashboardEnvTruthy -Value (Get-TelephoneDashboardEnvValue -Name 'TELEPHONE_LINE_DASHBOARD_OPT_OUT')) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($Project) -or [string]::IsNullOrWhiteSpace($LeadSessionId)) {
        return $null
    }
    $dir = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $rootSafety = Test-TelephoneCompletePathChain -Path $dir -AllowMissing -Label 'Lifecycle event root'
    if (-not [bool]$rootSafety.ok) { return $null }
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $eventsPath = Join-Path $dir 'lifecycle-events.jsonl'
    $lockPath = Join-Path $dir 'lifecycle-events.lock'
    $fileSafety = Test-TelephoneCompletePathChain -Path $eventsPath -Root $dir -AllowMissing -Label 'Lifecycle event file'
    if (-not [bool]$fileSafety.ok) { return $null }
    $gate = Open-TelephoneExclusiveGate -Path $lockPath -WaitMilliseconds 2000
    if ($null -eq $gate) { return $null }
    try {
        $existing = [Collections.Generic.List[object]]::new()
        $maxOrdinal = 0
        if ([IO.File]::Exists($eventsPath)) {
            $item = Get-Item -LiteralPath $eventsPath -Force -ErrorAction SilentlyContinue
            if ($null -eq $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
            if ([int64]$item.Length -gt [int64]$script:TelephoneLifecycleEventsMaxBytes) { return $null }
            $text = Read-TelephoneSharedUtf8 -Path $eventsPath
            $lengthAfter = [int64]([IO.FileInfo]::new($eventsPath).Length)
            if ($lengthAfter -gt [int64]$script:TelephoneLifecycleEventsMaxBytes) { return $null }
            foreach ($line in @($text -split "`n")) {
                $trim = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($trim)) { continue }
                try {
                    $row = $trim | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
                    [void]$existing.Add($row)
                    $ord = 0
                    try { $ord = [int]$row.ordinal } catch { $ord = 0 }
                    if ($ord -gt $maxOrdinal) { $maxOrdinal = $ord }
                } catch { }
            }
        }
        $key = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f [string]$Kind, [string]$Transport, [string]$Project, [string]$LeadSessionId, [string]$LeadRunId, [string]$LineJobId, [string]$ReceiptSha256
        $incomingProvenance = $null
        if ($null -ne $Provenance -and $Provenance -is [Collections.IDictionary] -and $Provenance.Contains('sha256') -and -not [string]::IsNullOrWhiteSpace([string]$Provenance.sha256)) {
            $incomingProvenance = [ordered]@{
                path = [string]$Provenance.path
                bytes = [int64]$Provenance.bytes
                sha256 = [string]$Provenance.sha256
            }
        } else {
            $incomingProvenance = [ordered]@{
                path = 'lifecycle-events.jsonl'
                bytes = [int64]$key.Length
                sha256 = Get-TelephoneUtf8Sha256 -Text $key
            }
        }
        $duplicateHit = $null
        foreach ($row in $existing) {
            $rowKey = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f [string]$row.kind, [string]$row.transport, [string]$row.project, [string]$row.lead_session_id, [string]$row.lead_run_id, [string]$row.line_job_id, [string]$row.receipt_sha256
            if ($rowKey -ceq $key) {
                $row.duplicate = $true
                try { $row.duplicate_count = [int]$row.duplicate_count + 1 } catch { $row.duplicate_count = 1 }
                $storedSha = ''
                if ($row -is [Collections.IDictionary] -and $row.Contains('provenance') -and $null -ne $row.provenance) {
                    try { $storedSha = [string]$row.provenance.sha256 } catch { $storedSha = '' }
                }
                $incomingSha = [string]$incomingProvenance.sha256
                if ([string]::IsNullOrWhiteSpace($storedSha) -or [string]::IsNullOrWhiteSpace($incomingSha) -or $storedSha -cne $incomingSha) {
                    $row.provenance_ambiguous = $true
                }
                $duplicateHit = $row
                break
            }
        }
        if ($null -ne $duplicateHit) {
            $rewrite = New-Object System.Text.StringBuilder
            foreach ($row in $existing) {
                [void]$rewrite.Append((($row | ConvertTo-Json -Depth 16 -Compress) + "`n"))
            }
            $null = Write-TelephoneBytesReplace -Path $eventsPath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($rewrite.ToString()))
            return $duplicateHit
        }
        $event = [ordered]@{
            protocol_version = 'telephone-line-dashboard-lifecycle-event-v1'
            ordinal = $maxOrdinal + 1
            kind = [string]$Kind
            transport = [string]$Transport
            project = [string]$Project
            lead_session_id = [string]$LeadSessionId
            lead_run_id = [string]$LeadRunId
            line_job_id = [string]$LineJobId
            receipt_sha256 = $(if ([string]::IsNullOrWhiteSpace($ReceiptSha256)) { $null } else { [string]$ReceiptSha256 })
            provenance = $incomingProvenance
            provenance_ambiguous = $false
            duplicate = $false
            duplicate_count = 0
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        Assert-TelephoneJsonSchema -JsonText (($event | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n") -SchemaName 'dashboard-lifecycle-event' -Label 'lifecycle event'
        $lineBytes = [Text.UTF8Encoding]::new($false).GetBytes((($event | ConvertTo-Json -Depth 16 -Compress) + "`n"))
        $stream = [IO.File]::Open($eventsPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $stream.Write($lineBytes, 0, $lineBytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        return $event
    } finally {
        $gate.Dispose()
    }
}

function Write-TelephoneLifecycleStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][string]$Phase,
        [bool]$Idle = $false
    )

    # The relay and collector both publish this status after delivery. Serialize
    # their read/replace cycle so File.Replace cannot move the other's target
    # out from under it while creating its temporary backup.
    $statusGate = Open-TelephoneExclusiveGate -Path ([string]$Paths.lifecycle_status + '.lock') -WaitMilliseconds 10000
    if ($null -eq $statusGate) { throw 'Lifecycle status writer is still owned.' }
    try {
    $jobId = ''
    $project = ''
    $session = ''
    if ($Paths.Contains('dispatch') -and [IO.File]::Exists([string]$Paths.dispatch)) {
        try {
            $dispatch = (Read-TelephoneJson -Path ([string]$Paths.dispatch)).value
            $jobId = [string]$dispatch.line_job_id
            $project = [string]$dispatch.project
            if ($null -ne $dispatch.lead) { $session = [string]$dispatch.lead.session_id }
        } catch { }
    }
    $previousPhase = $null
    if ([IO.File]::Exists([string]$Paths.lifecycle_status)) {
        try { $previousPhase = [string](Read-TelephoneJson -Path ([string]$Paths.lifecycle_status)).value.phase } catch { $previousPhase = $null }
    }
    $status = [ordered]@{
        protocol_version = 'telephone-line-lifecycle-status-v1'
        line_job_id = $jobId
        phase = [string]$Phase
        idle = [bool]$Idle
        automatic_rerun = $false
        replacement_started = $false
        updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $written = Write-TelephoneJsonReplace -Path ([string]$Paths.lifecycle_status) -Value $status
    if ([string]$previousPhase -ceq [string]$Phase) { return $written }
    try {
        if (-not [string]::IsNullOrWhiteSpace($project) -and -not [string]::IsNullOrWhiteSpace($session)) {
            $root = if ($Paths.Contains('root')) { [string]$Paths.root } else { [IO.Path]::GetDirectoryName([string]$Paths.lifecycle_status) }
            $null = Write-TelephonePublicLifecycleEvent -Root $root -Kind (Get-TelephoneLifecycleEventKind -Phase $Phase) -Transport 'wired' -Project $project -LeadSessionId $session -LineJobId $jobId
        }
    } catch { }
    return $written
    } finally {
        $statusGate.Dispose()
    }
}

function Test-TelephoneLifecycleIdleGap {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$JobRoot)

    $paths = Get-TelephoneJobPaths -JobRoot $JobRoot
    $hasDispatch = [IO.File]::Exists($paths.dispatch)
    $hasDelivery = [IO.File]::Exists($paths.delivery)
    $status = $null
    if ([IO.File]::Exists($paths.lifecycle_status)) {
        $status = (Read-TelephoneJson -Path $paths.lifecycle_status).value
    }
    $idleGap = $false
    $reason = ''
    if ($null -ne $status) {
        $phase = [string]$status.phase
        $terminal = $phase -cin @('delivered', 'failed', 'retired')
        if ([bool]$status.idle -eq $true -and -not $terminal) {
            $idleGap = $true
            $reason = 'lifecycle_idle_before_terminal'
        } elseif ($hasDelivery -and $phase -cin @('dispatched', 'execution', 'nested_target', 'owner_acceptance')) {
            $idleGap = $true
            $reason = 'delivery_before_owner_terminal_phase'
        }
    }
    return [ordered]@{
        idle_gap = [bool]$idleGap
        reason = $reason
        has_dispatch = [bool]$hasDispatch
        has_delivery = [bool]$hasDelivery
        phase = if ($null -ne $status) { [string]$status.phase } else { '' }
        idle = if ($null -ne $status) { [bool]$status.idle } else { $false }
    }
}

function Initialize-TelephoneSupervisorJobAssignNative {
    [CmdletBinding()]
    param()
    if ($null -ne ('TelephoneLineJobAssign.Native' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace TelephoneLineJobAssign {
    public static class Native {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr OpenJobObject(uint dwDesiredAccess, bool bInheritHandle, string lpName);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);
        public static bool AssignPidToNamedJob(string name, int pid) {
            uint[] accesses = new uint[] { 0x0010001Fu, 0x1F003Fu, 0x0000001Fu, 0x0000000Du, 0x00000001u };
            foreach (uint access in accesses) {
                IntPtr job = OpenJobObject(access, false, name);
                if (job == IntPtr.Zero) { continue; }
                try {
                    IntPtr process = OpenProcess(0x00000101u, false, pid);
                    if (process == IntPtr.Zero) { process = OpenProcess(0x001F0FFFu, false, pid); }
                    if (process == IntPtr.Zero) { continue; }
                    try {
                        if (AssignProcessToJobObject(job, process)) { return true; }
                    } finally {
                        CloseHandle(process);
                    }
                } finally {
                    CloseHandle(job);
                }
            }
            return false;
        }
    }
}
'@
}

function Add-TelephoneProcessToSupervisorRunJob {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $runId = [string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID
    if ([string]::IsNullOrWhiteSpace($runId)) { return $false }
    if ($runId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { return $false }
    if ($ProcessId -le 0) { return $false }
    try {
        Initialize-TelephoneSupervisorJobAssignNative
        return [bool][TelephoneLineJobAssign.Native]::AssignPidToNamedJob(('Local\TelephoneLine.WiredRun.' + $runId), [int]$ProcessId)
    } catch {
        return $false
    }
}

function Test-TelephoneSupervisorRunStopRequested {
    [CmdletBinding()]
    param()
    $runId = [string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID
    $supState = [string]$env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT
    if ([string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($supState)) { return $false }
    try {
        $stopPath = Join-Path (Join-Path (Join-Path $supState 'runs') $runId) 'stop.requested'
        return [IO.File]::Exists($stopPath)
    } catch {
        return $false
    }
}

function Start-TelephoneHiddenPowerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $powerShellPath
    $supervised = -not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID)
    $argv = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($Arguments)
    if ($supervised) {
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        foreach ($argument in $argv) { [void]$info.ArgumentList.Add([string]$argument) }
    } else {
        $info.UseShellExecute = $true
        $info.CreateNoWindow = $false
        $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $quoted = [Collections.Generic.List[string]]::new()
        foreach ($argument in $argv) {
            $one = [string]$argument
            if ($one -match '[\s"]') { [void]$quoted.Add('"' + ($one.Replace('"', '"')) + '"') }
            else { [void]$quoted.Add($one) }
        }
        $info.Arguments = [string]::Join(' ', $quoted)
    }
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw "Failed to start telephone-line process: $ScriptPath" }
    try {
        $processId = [int]$process.Id
        $ticks = [int64]0
        $startedAt = [DateTimeOffset]::UtcNow.ToString('o')
        try {
            $ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
            $startedAt = $process.StartTime.ToUniversalTime().ToString('o')
        } catch { }
        if ($ticks -eq 0) {
            $live = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -ne $live) {
                try {
                    $ticks = [int64]$live.StartTime.ToUniversalTime().Ticks
                    $startedAt = $live.StartTime.ToUniversalTime().ToString('o')
                } finally {
                    $live.Dispose()
                }
            }
        }
        if ($supervised) { $null = Add-TelephoneProcessToSupervisorRunJob -ProcessId $processId }
        return [ordered]@{
            pid = $processId
            start_time_utc_ticks = $ticks
            started_at_utc = $startedAt
        }
    } finally {
        $process.Dispose()
    }
}

function Get-TelephoneJobPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$JobRoot)

    $root = [IO.Path]::GetFullPath($JobRoot).TrimEnd('\')
    return [ordered]@{
        root = $root
        dispatch = Join-Path $root 'dispatch.json'
        lead_binding = Join-Path $root 'lead-binding.json'
        command_start_intent = Join-Path $root 'command-start-intent.json'
        command_gate = Join-Path $root 'command-start.lock'
        command_launch = Join-Path $root 'command-launch.json'
        command_owner = Join-Path $root 'command-owner.json'
        command_child = Join-Path $root 'command-child.json'
        command_child_exit = Join-Path $root 'command-child-exit.json'
        relay_owner = Join-Path $root 'relay-owner.json'
        stdout = Join-Path $root 'route-stdout.txt'
        stderr = Join-Path $root 'route-stderr.txt'
        receipt = Join-Path $root 'receipt.json'
        wake_prompt = Join-Path $root 'wake-prompt.md'
        wake_intent = Join-Path $root 'wake-intent.json'
        wake_attempt = Join-Path $root 'wake-attempt.json'
        wake_launch_result = Join-Path $root 'wake-launch-result.json'
        delivery_lock = Join-Path $root 'delivery.lock'
        delivery_claim = Join-Path $root 'delivery-claim.json'
        relay_error = Join-Path $root 'relay-error.json'
        delivery = Join-Path $root 'delivery.json'
        nested_wake_prompt = Join-Path $root 'nested-wake-prompt.md'
        nested_wake_intent = Join-Path $root 'nested-wake-intent.json'
        nested_wake_attempt = Join-Path $root 'nested-wake-attempt.json'
        nested_wake_launch_result = Join-Path $root 'nested-wake-launch-result.json'
        nested_terminal = Join-Path $root 'nested-terminal.json'
        owner_wake_prompt = Join-Path $root 'owner-wake-prompt.md'
        owner_wake_intent = Join-Path $root 'owner-wake-intent.json'
        owner_wake_attempt = Join-Path $root 'owner-wake-attempt.json'
        owner_wake_launch_result = Join-Path $root 'owner-wake-launch-result.json'
        lifecycle_status = Join-Path $root 'lifecycle-status.json'
        lifecycle_events = Join-Path $root 'lifecycle-events.jsonl'
        lifecycle_events_lock = Join-Path $root 'lifecycle-events.lock'
        mailbox_ref = Join-Path $root 'mailbox-ref.json'
        wake_reconcile = Join-Path $root 'wake-reconcile.json'
        cli_diagnostic = Join-Path $root 'cli-diagnostic.json'
        launch_failure = Join-Path $root 'launch-failure.json'
        wake_retry = Join-Path $root 'wake-retry.json'
        trusted_consumption = Join-Path $root 'trusted-consumption.json'
    }
}

function Get-TelephoneStateRootFromJobRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$JobRoot)
    $root = [IO.Path]::GetFullPath($JobRoot).TrimEnd('\')
    $jobsDir = [IO.Path]::GetDirectoryName($root)
    if ([string]::IsNullOrWhiteSpace($jobsDir) -or [IO.Path]::GetFileName($jobsDir) -cne 'jobs') {
        throw 'Telephone job root is not under a jobs directory.'
    }
    return [IO.Path]::GetDirectoryName($jobsDir)
}

function Get-TelephoneLeadCanonicalIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Lead)
    $session = [string]$Lead.session_id
    $worktree = [IO.Path]::GetFullPath([string]$Lead.worktree).TrimEnd('\')
    if ($null -eq $Lead.launcher) { throw 'Lead launcher is required.' }
    $launcherPath = [IO.Path]::GetFullPath([string]$Lead.launcher.path)
    $arguments = @()
    if ($null -ne $Lead.launcher.arguments) {
        $arguments = @($Lead.launcher.arguments | ForEach-Object { [string]$_ })
    }
    $material = $session + '|' + $worktree + '|' + $launcherPath + '|' + [string]::Join("`n", $arguments)
    return [ordered]@{
        session_id = $session
        worktree = $worktree
        launcher_path = $launcherPath
        launcher_arguments = @($arguments)
        identity_sha256 = Get-TelephoneUtf8Sha256 -Text $material
    }
}

function Get-TelephoneLeadProfileIdentity {
    [CmdletBinding()]
    param([AllowNull()][object]$Lead)
    if ($null -eq $Lead -or $null -eq $Lead.launcher -or $null -eq $Lead.launcher.arguments) { return $null }
    $arguments = @($Lead.launcher.arguments | ForEach-Object { [string]$_ })
    for ($index = 0; $index -lt ($arguments.Count - 1); $index++) {
        if ([string]$arguments[$index] -ceq '-ProfilePath') {
            $profilePath = [string]$arguments[$index + 1]
            if ([string]::IsNullOrWhiteSpace($profilePath) -or -not [IO.File]::Exists($profilePath)) { return $null }
            return (Get-TelephoneFileIdentity -Path $profilePath)
        }
    }
    return $null
}

function ConvertTo-TelephoneComparableLeadIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Canonical,
        [AllowNull()][object]$Profile = $null
    )
    $profileRecord = $null
    if ($null -ne $Profile) {
        $profileRecord = [ordered]@{
            path = [string]$Profile.path
            bytes = [int64]$Profile.bytes
            sha256 = [string]$Profile.sha256
        }
    }
    return [ordered]@{
        session_id = [string]$Canonical.session_id
        worktree = [string]$Canonical.worktree
        launcher_path = [string]$Canonical.launcher_path
        identity_sha256 = [string]$Canonical.identity_sha256
        profile = $profileRecord
    }
}

function ConvertTo-TelephoneComparableLeadIdentityFromItem {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Item)
    $profileRecord = $null
    if ($Item -is [Collections.IDictionary] -and $Item.Contains('profile') -and $null -ne $Item.profile) {
        $profileRecord = [ordered]@{
            path = [string]$Item.profile.path
            bytes = [int64]$Item.profile.bytes
            sha256 = [string]$Item.profile.sha256
        }
    }
    return [ordered]@{
        session_id = [string]$Item.lead_session_id
        worktree = [string]$Item.lead_worktree
        launcher_path = [string]$Item.lead_launcher_path
        identity_sha256 = [string]$Item.lead_identity_sha256
        profile = $profileRecord
    }
}

function Test-TelephoneComparableLeadIdentityWellFormed {
    [CmdletBinding()]
    param([AllowNull()][object]$Identity)
    if ($null -eq $Identity) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Identity.session_id)) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Identity.worktree)) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Identity.launcher_path)) { return $false }
    if ([string]$Identity.identity_sha256 -cnotmatch '^[0-9a-f]{64}$') { return $false }
    if ($null -ne $Identity.profile) {
        if ([string]::IsNullOrWhiteSpace([string]$Identity.profile.path)) { return $false }
        try { $null = [int64]$Identity.profile.bytes } catch { return $false }
        if ([string]$Identity.profile.sha256 -cnotmatch '^[0-9a-f]{64}$') { return $false }
    }
    return $true
}

function Test-TelephoneComparableLeadIdentityEqual {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Left,
        [AllowNull()][object]$Right
    )
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if ([string]$Left.session_id -cne [string]$Right.session_id) { return $false }
    if ([string]$Left.worktree -cne [string]$Right.worktree) { return $false }
    if ([string]$Left.launcher_path -cne [string]$Right.launcher_path) { return $false }
    if ([string]$Left.identity_sha256 -cne [string]$Right.identity_sha256) { return $false }
    $leftHas = ($null -ne $Left.profile)
    $rightHas = ($null -ne $Right.profile)
    if ($leftHas -ne $rightHas) { return $false }
    if ($leftHas) {
        if ([string]$Left.profile.path -cne [string]$Right.profile.path) { return $false }
        if ([int64]$Left.profile.bytes -ne [int64]$Right.profile.bytes) { return $false }
        if ([string]$Left.profile.sha256 -cne [string]$Right.profile.sha256) { return $false }
    }
    return $true
}

function New-TelephoneBatchMissingOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackageId,
        [AllowNull()][object]$Job = $null
    )
    $row = [ordered]@{ package_id = [string]$PackageId }
    if ($null -eq $Job) { return $row }
    $row.line_job_id = [string]$Job.dispatch.line_job_id
    $row.route = [string]$Job.dispatch.route
    $row.job_root = [string]$Job.paths.root
    if ($null -ne $Job.dispatch.command) {
        $row.command = [ordered]@{
            executable = [string]$Job.dispatch.command.executable
            working_directory = [string]$Job.dispatch.command.working_directory
        }
    }
    $row.receipt_present = [IO.File]::Exists([string]$Job.paths.receipt)
    if ([IO.File]::Exists([string]$Job.paths.command_owner)) {
        try {
            $owner = (Read-TelephoneJson -Path ([string]$Job.paths.command_owner)).value
            $row.command_owner = [ordered]@{
                pid = [int]$owner.pid
                start_time_utc_ticks = [int64]$owner.start_time_utc_ticks
            }
        } catch { }
    }
    if ([IO.File]::Exists([string]$Job.paths.command_start_intent)) {
        $row.command_start_intent = $true
    }
    return $row
}

function Get-TelephoneLeadMailboxPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$LeadKey
    )
    $state = Assert-TelephoneDirectoryPath -Path $StateRoot -Label 'State root'
    $key = [string]$LeadKey
    if ($key -cnotmatch '^[0-9a-f]{64}$') { throw 'Lead mailbox identity is invalid.' }
    $leadRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $state 'leads') $key))
    $parent = [IO.Path]::GetDirectoryName($leadRoot)
    $leadsDir = [IO.Path]::GetFullPath((Join-Path $state 'leads'))
    if (-not $parent.Equals($leadsDir, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Lead mailbox path escaped the state root.'
    }
    $batchRoot = Join-Path $leadRoot 'batches'
    $itemRoot = Join-Path $leadRoot 'mailbox'
    return [ordered]@{
        state_root = $state
        lead_key = $key
        lead_root = $leadRoot
        gate = Join-Path $leadRoot 'gate.lock'
        owner = Join-Path $leadRoot 'owner.json'
        seq = Join-Path $leadRoot 'seq.json'
        mailbox = $itemRoot
        batches = $batchRoot
        truth = Join-Path $leadRoot 'truth.json'
        fail_closed = Join-Path $leadRoot 'fail-closed.json'
    }
}

function Get-TelephoneBatchPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$MailboxPaths,
        [Parameter(Mandatory = $true)][string]$BatchId
    )
    $batchId = [string]$BatchId
    if ($batchId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'Batch id must be a UUID.'
    }
    $root = Join-Path ([string]$MailboxPaths.batches) $batchId
    return [ordered]@{
        root = $root
        collection = Join-Path $root 'collection.json'
        manifest = Join-Path $root 'manifest.json'
        wake_prompt = Join-Path $root 'wake-prompt.md'
        wake_intent = Join-Path $root 'wake-intent.json'
        wake_attempt = Join-Path $root 'wake-attempt.json'
        wake_launch_result = Join-Path $root 'wake-launch-result.json'
        fail_closed = Join-Path $root 'fail-closed.json'
    }
}

function New-TelephoneCollectorOwnerRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LeadKey,
        [string]$ActiveBatchId = ''
    )
    $self = Get-Process -Id $PID
    try {
        $doc = [ordered]@{
            protocol_version = 'telephone-line-mailbox-owner-v1'
            pid = [int]$PID
            start_time_utc_ticks = [int64]$self.StartTime.ToUniversalTime().Ticks
            started_at_utc = $self.StartTime.ToUniversalTime().ToString('o')
            lead_identity_sha256 = [string]$LeadKey
        }
        if (-not [string]::IsNullOrWhiteSpace($ActiveBatchId)) { $doc.active_batch_id = [string]$ActiveBatchId }
        if (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID)) {
            $doc.supervisor_run_id = [string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID
        }
        return $doc
    } finally {
        $self.Dispose()
    }
}

function Resolve-TelephoneCollectorCrashMailboxPaths {
    [CmdletBinding()]
    param(
        [object]$MailboxPaths = $null,
        [object]$Job = $null
    )
    if ($null -ne $MailboxPaths -and $MailboxPaths -is [Collections.IDictionary] -and $MailboxPaths.Contains('lead_root')) {
        $root = [string]$MailboxPaths.lead_root
        if (-not [string]::IsNullOrWhiteSpace($root)) { return $MailboxPaths }
    }
    if ($null -eq $Job -or $null -eq $Job.paths -or [string]::IsNullOrWhiteSpace([string]$Job.paths.root)) { return $null }
    try {
        $stateRoot = Get-TelephoneStateRootFromJobRoot -JobRoot ([string]$Job.paths.root)
        $leadKey = ''
        if ($Job -is [Collections.IDictionary] -and $Job.Contains('canonical') -and $null -ne $Job.canonical) {
            $leadKey = [string]$Job.canonical.identity_sha256
        }
        if ([string]::IsNullOrWhiteSpace($leadKey) -and $null -ne $Job.lead) {
            $leadKey = [string](Get-TelephoneLeadCanonicalIdentity -Lead $Job.lead).identity_sha256
        }
        if ([string]::IsNullOrWhiteSpace($leadKey)) { return $null }
        return (Get-TelephoneLeadMailboxPaths -StateRoot $stateRoot -LeadKey $leadKey)
    } catch {
        return $null
    }
}

function Test-TelephoneCollectorCrashAfter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Point,
        [object]$MailboxPaths = $null
    )
    if ([string]$env:TELEPHONE_TEST_COLLECTOR_CRASH_AFTER -cne $Point) { return }
    $root = $null
    if ($null -ne $MailboxPaths -and $MailboxPaths -is [Collections.IDictionary] -and $MailboxPaths.Contains('lead_root')) {
        $root = [string]$MailboxPaths.lead_root
    }
    if (-not [string]::IsNullOrWhiteSpace($root) -and [IO.Directory]::Exists($root)) {
        $safePoint = ($Point -replace '[^A-Za-z0-9_]', '_')
        $marker = Join-Path $root ('.collector-crash-' + $safePoint)
        if ([IO.File]::Exists($marker)) { return }
        try {
            [IO.File]::WriteAllText($marker, ([DateTimeOffset]::UtcNow.ToString('o') + "`n"), [Text.UTF8Encoding]::new($false))
        } catch { }
    }
    exit 99
}

function Get-TelephoneCollectorIdleMilliseconds {
    [CmdletBinding()]
    param()
    $raw = [string][Environment]::GetEnvironmentVariable('TELEPHONE_TEST_COLLECTOR_IDLE_MS')
    if ([string]::IsNullOrWhiteSpace($raw)) { return 8000 }
    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed) -or $parsed -lt 50) { return 8000 }
    if ($parsed -gt 120000) { return 120000 }
    return $parsed
}

function Resolve-TelephoneDispatchBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Dispatch,
        [Parameter(Mandatory = $true)][string]$LineJobId
    )
    $jobId = [string]$LineJobId
    if ($Dispatch -is [Collections.IDictionary] -and $Dispatch.Contains('batch') -and $null -ne $Dispatch.batch) {
        $batch = $Dispatch.batch
        $batchId = [string]$batch.batch_id
        $packageId = [string]$batch.package_id
        $packageIds = @($batch.package_ids | ForEach-Object { [string]$_ })
        $n = [int]$batch.n
        if ($batchId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
            throw 'Batch id must be a UUID.'
        }
        if ([string]::IsNullOrWhiteSpace($packageId)) { throw 'Batch package_id is required.' }
        if ($packageIds.Count -lt 1) { throw 'Batch package_ids must be a non-empty set.' }
        $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($id in $packageIds) {
            if (-not $unique.Add([string]$id)) { throw 'Batch package_ids must be unique.' }
        }
        if (-not $unique.Contains($packageId)) { throw 'Batch package_id must be a member of package_ids.' }
        if ($n -ne $packageIds.Count) { throw 'Batch n must equal the frozen package-id set size.' }
        $retryOf = $null
        if ($batch -is [Collections.IDictionary] -and $batch.Contains('retry_of')) { $retryOf = $batch.retry_of }
        $implicit = $false
        if ($batch -is [Collections.IDictionary] -and $batch.Contains('implicit')) { $implicit = [bool]$batch.implicit }
        return [ordered]@{
            protocol_version = 'telephone-line-batch-v1'
            batch_id = $batchId
            package_id = $packageId
            package_ids = @($packageIds)
            n = $n
            retry_of = $retryOf
            implicit = $implicit
        }
    }
    return [ordered]@{
        protocol_version = 'telephone-line-batch-v1'
        batch_id = $jobId
        package_id = $jobId
        package_ids = @($jobId)
        n = 1
        retry_of = $null
        implicit = $true
    }
}

function Resolve-TelephoneRequestBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Request,
        [Parameter(Mandatory = $true)][string]$LineJobId
    )
    return (Resolve-TelephoneDispatchBatch -Dispatch $Request -LineJobId $LineJobId)
}

function Test-TelephoneStartFailedCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Receipt
    )
    if ([string]$Receipt.command_error_code -cne 'COMMAND_START_FAILED') { return $false }
    if ([IO.File]::Exists([string]$Paths.command_child)) { return $false }
    if ([IO.File]::Exists([string]$Paths.stdout) -or [IO.File]::Exists([string]$Paths.stderr)) { return $false }
    $owner = $null
    if ([IO.File]::Exists([string]$Paths.command_owner)) {
        try { $owner = (Read-TelephoneJson -Path ([string]$Paths.command_owner)).value } catch { return $false }
        if (Test-TelephoneOwnerAlive -Owner $owner) { return $false }
    }
    foreach ($name in @('native-session.json', 'native_session.json', 'session.json')) {
        if ([IO.File]::Exists((Join-Path ([string]$Paths.root) $name))) { return $false }
    }
    return $true
}

function Get-TelephoneReceiptClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Receipt
    )
    $code = [string]$Receipt.command_error_code
    if ($code -ceq 'COMMAND_START_AMBIGUOUS_NO_RERUN') { return 'start_ambiguous' }
    if ($code -ceq 'COMMAND_START_FAILED') {
        if (Test-TelephoneStartFailedCounts -Paths $Paths -Receipt $Receipt) { return 'start_failed' }
        return 'start_failed_unqualified'
    }
    $complete = $false
    if ($Receipt -is [Collections.IDictionary] -and $Receipt.Contains('transport_complete')) {
        $complete = [bool]$Receipt.transport_complete
    }
    $exit = $Receipt.command_exit_code
    if ($complete -and ($null -eq $exit -or [int]$exit -eq 0) -and [string]::IsNullOrWhiteSpace($code)) { return 'success' }
    if ($complete -and $null -ne $exit -and [int]$exit -eq 0 -and [string]::IsNullOrWhiteSpace($code)) { return 'success' }
    return 'execution_failure'
}

function ConvertTo-TelephoneFrozenLauncherNamedArguments {
    [CmdletBinding()]
    param([object[]]$Arguments)
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return @{} }
    if (($Arguments.Count % 2) -ne 0) { throw 'Frozen Lead launcher arguments must be name/value pairs.' }
    $named = @{}
    $reserved = @('WorktreePath', 'PromptFile', 'ResumeSessionId', 'RunId')
    for ($index = 0; $index -lt $Arguments.Count; $index += 2) {
        $token = [string]$Arguments[$index]
        if ($token -notmatch '^-[A-Za-z][A-Za-z0-9_-]*$') { throw 'Frozen Lead launcher argument name is invalid.' }
        $name = $token.Substring(1)
        if ($name -in $reserved -or $named.ContainsKey($name)) { throw 'Frozen Lead launcher argument name is duplicate or reserved.' }
        $named[$name] = [string]$Arguments[$index + 1]
    }
    return $named
}

. (Join-Path $PSScriptRoot 'TelephoneLeadRuntime.Common.ps1')

function Invoke-TelephonePriorOwnerHandoff {
    [CmdletBinding()]
    param(
        [string]$LauncherPath, [object[]]$ExtraArguments, [string]$Worktree,
        [string]$PromptFile, [string]$SessionId, [string]$RunId,
        [object]$Captured = $null
    )
    $folder = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PromptFile))
    $recordPath = Join-Path $folder ('prior-owner-handoff-' + $RunId + '.json')
    $claimPath = Join-Path $folder ('prior-owner-handoff-' + $RunId + '-launch.json')
    $resultPath = Join-Path $folder ('prior-owner-handoff-' + $RunId + '-result.json')
    if (-not [IO.File]::Exists($recordPath)) {
        if ($null -eq $Captured -or -not [bool]$Captured.process_exited -or [int]$Captured.exit_code -eq 0 -or
            [bool]$Captured.native_turn_complete -or -not [string]::IsNullOrWhiteSpace([string]$Captured.stdout)) { return $null }
        $plain = [regex]::Replace([string]$Captured.stderr, '(?m)^\s*\|\s?', '')
        $match = [regex]::Match($plain, 'This isolated Wired Lead root already has an active run:\s*([A-Za-z]:\\[^\r\n]+)')
        if (-not $match.Success -or -not $plain.Contains($LauncherPath)) { return $null }
        $priorRoot = [IO.Path]::GetFullPath($match.Groups[1].Value.Trim()).TrimEnd('\')
        $priorRecord = (Read-TelephoneJson -Path (Join-Path $priorRoot 'lead-run.json')).value
        if ([string]$priorRecord.resume_session_id -cne $SessionId -or
            -not [IO.Path]::GetFullPath([string]$priorRecord.worktree).TrimEnd('\').Equals([IO.Path]::GetFullPath($Worktree).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { return $null }
        $targetRoot = Join-Path ([IO.Path]::GetDirectoryName($priorRoot)) $RunId
        # This supported refusal precedes any new run directory or native process.
        if ([IO.Directory]::Exists($targetRoot)) { return $null }
        $ownerRead = Read-TelephoneJson -Path (Join-Path $priorRoot 'owner.json')
        $owners = @($ownerRead.value)
        $childPath = Join-Path $priorRoot 'cli-child.json'
        if ([IO.File]::Exists($childPath)) { $owners += (Read-TelephoneJson -Path $childPath).value }
        foreach ($owner in $owners) {
            if ([int]$owner.pid -le 0 -or [int64]$owner.start_time_utc_ticks -le 0) { return $null }
        }
        $record = [ordered]@{
            protocol_version = 'telephone-line-prior-owner-handoff-v1'
            session_id = $SessionId; run_id = $RunId
            launcher = Get-TelephoneFileIdentity -Path $LauncherPath
            prompt = Get-TelephoneFileIdentity -Path $PromptFile
            extra_arguments = @($ExtraArguments)
            worktree = [IO.Path]::GetFullPath($Worktree).TrimEnd('\')
            prior_run_root = $priorRoot; target_run_root = $targetRoot
            prior_record = Get-TelephoneFileIdentity -Path (Join-Path $priorRoot 'lead-run.json')
            prior_owners = $owners
            refusal = $Captured
            new_turn_started = $false; provider_rerun = $false
            recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        try { $null = Write-TelephoneJsonCreateNew -Path $recordPath -Value $record } catch [IO.IOException] { }
    }
    $record = (Read-TelephoneJson -Path $recordPath).value
    if ([string]$record.protocol_version -cne 'telephone-line-prior-owner-handoff-v1' -or [string]$record.session_id -cne $SessionId -or [string]$record.run_id -cne $RunId -or
        -not [IO.Path]::GetFullPath($Worktree).TrimEnd('\').Equals([string]$record.worktree,[StringComparison]::OrdinalIgnoreCase) -or
        ((@($record.extra_arguments) -join "`n") -cne (@($ExtraArguments) -join "`n"))) { throw 'LEAD_WAKE_AMBIGUOUS' }
    foreach ($pair in @(@($record.launcher,$LauncherPath),@($record.prompt,$PromptFile),@($record.prior_record,(Join-Path ([string]$record.prior_run_root) 'lead-run.json')))) {
        $actual = Get-TelephoneFileIdentity -Path ([string]$pair[1])
        if ([string]$pair[0].sha256 -cne [string]$actual.sha256 -or [int64]$pair[0].bytes -ne [int64]$actual.bytes -or [string]$pair[0].path -cne [string]$actual.path) { throw 'LEAD_WAKE_AMBIGUOUS' }
    }
    if ([IO.File]::Exists($resultPath)) { return (Read-TelephoneJson -Path $resultPath).value.launch }
    if ([IO.File]::Exists($claimPath)) {
        # A crash after the launch claim is ambiguous. Never manufacture a retry.
        throw 'LEAD_WAKE_AMBIGUOUS'
    }
    while ($true) {
        if (Test-TelephoneSupervisorRunStopRequested) { throw 'LEAD_WAKE_FAILED' }
        $alive = $false
        foreach ($owner in @($record.prior_owners)) { if (Test-TelephoneOwnerAlive -Owner $owner) { $alive = $true } }
        if (-not $alive) { break }
        Start-Sleep -Milliseconds 200
    }
    if ([IO.Directory]::Exists([string]$record.target_run_root)) { throw 'LEAD_WAKE_AMBIGUOUS' }
    # CreateNew is the single launch claim, also across collector restarts.
    try { $null = Write-TelephoneJsonCreateNew -Path $claimPath -Value ([ordered]@{
        protocol_version = 'telephone-line-prior-owner-launch-v1'
        session_id = $SessionId; run_id = $RunId; prior_owners_released = $true
        executor_rerun = $false; recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }) } catch [IO.IOException] { throw 'LEAD_WAKE_AMBIGUOUS' }
    $launch = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $LauncherPath -ExtraArguments $ExtraArguments -Worktree $Worktree -PromptFile $PromptFile -SessionId $SessionId -RunId $RunId -PriorOwnerRetry
    $null = Write-TelephoneJsonCreateNew -Path $resultPath -Value ([ordered]@{
        protocol_version = 'telephone-line-prior-owner-handoff-result-v1'
        session_id = $SessionId; run_id = $RunId; launch = $launch
        executor_rerun = $false; recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    return $launch
}

function Invoke-TelephoneFrozenLeadLauncher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [object[]]$ExtraArguments,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [switch]$PriorOwnerRetry
    )
    $null = ConvertTo-TelephoneFrozenLauncherNamedArguments -Arguments $ExtraArguments
    Set-TelephoneLastLeadLaunchDiagnostic -Diagnostic $null
    if (-not $PriorOwnerRetry) {
        $handoff = Invoke-TelephonePriorOwnerHandoff -LauncherPath $LauncherPath -ExtraArguments $ExtraArguments -Worktree $Worktree -PromptFile $PromptFile -SessionId $SessionId -RunId $RunId
        if ($null -ne $handoff) { return $handoff }
    }
    $extraForLaunch = @($ExtraArguments)
    $frozenCmd = Get-TelephoneLeadNamedArgumentValue -Arguments $ExtraArguments -Name 'CodexCommand'
    $stablePolicy = Get-TelephoneLeadStableCliPolicy
    if (-not [string]::IsNullOrWhiteSpace($frozenCmd) -and -not [string]::IsNullOrWhiteSpace([string]$stablePolicy.executable)) {
        $resolvedCli = Resolve-TelephoneLeadCliExecutable -FrozenExecutable $frozenCmd -Probe
        if (-not [bool]$resolvedCli.launchable) { throw 'LEAD_CLI_UNLAUNCHABLE' }
        $extraForLaunch = @(Copy-TelephoneLeadExtraArgumentsWithCli -Arguments $ExtraArguments -Executable ([string]$resolvedCli.executable))
    }
    $fileName = $LauncherPath
    $drainArgs = [Collections.Generic.List[string]]::new()
    if ([IO.Path]::GetExtension($LauncherPath) -ieq '.ps1') {
        $fileName = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        foreach ($item in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $LauncherPath)) {
            [void]$drainArgs.Add([string]$item)
        }
    }
    foreach ($item in @(
        '-WorktreePath', [string]$Worktree,
        '-PromptFile', [string]$PromptFile,
        '-ResumeSessionId', [string]$SessionId,
        '-RunId', [string]$RunId
    ) + @($extraForLaunch)) {
        [void]$drainArgs.Add([string]$item)
    }
    $workdir = [string]$Worktree
    $stateHint = Get-TelephoneLeadNamedArgumentValue -Arguments $extraForLaunch -Name 'StateRootOverride'
    if ([string]::IsNullOrWhiteSpace($stateHint) -and -not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_LEAD_STATE_ROOT)) {
        $stateHint = [string]$env:TELEPHONE_LINE_LEAD_STATE_ROOT
    }
    $runRootHint = ''
    if (-not [string]::IsNullOrWhiteSpace($stateHint)) {
        $runRootHint = [IO.Path]::GetFullPath((Join-Path $stateHint $RunId)).TrimEnd('\')
    }
    $lifecyclePath = ''
    $ownerPath = ''
    $eventsPath = ''
    if (-not [string]::IsNullOrWhiteSpace($runRootHint)) {
        $lifecyclePath = Join-Path $runRootHint 'host-drain-lifecycle.json'
        $ownerPath = Join-Path $runRootHint 'owner.json'
        $eventsPath = Join-Path $runRootHint 'codex-events.jsonl'
        if ([IO.Directory]::Exists($runRootHint)) {
            $existingConflict = Test-TelephoneLeadPreTurnActiveWriterConflict -RunRoot $runRootHint -ExpectedSessionId $SessionId -ExpectedRunId $RunId
            if ([bool]$existingConflict.matched) {
                $diag = New-TelephoneLeadLaunchDiagnostic -Code 'LEAD_WAKE_PRE_TURN_CONFLICT' -Executable $fileName -WorkingDirectory $workdir -Captured ([ordered]@{ stderr = [string]$existingConflict.stderr; exit_code = $existingConflict.exit_code; process_exited = $true }) -RunId $RunId -SessionId $SessionId -RunRoot $runRootHint
                Set-TelephoneLastLeadLaunchDiagnostic -Diagnostic $diag
                throw 'LEAD_WAKE_PRE_TURN_CONFLICT'
            }
        }
        $admission = Test-TelephoneLeadRunRootAdmission -RunRoot $runRootHint -ExpectedSessionId $SessionId -ExpectedRunId $RunId
        if (-not [bool]$admission.ok) {
            $diag = New-TelephoneLeadLaunchDiagnostic -Code 'LEAD_WAKE_FAILED' -Executable $fileName -WorkingDirectory $workdir -CreateProcessError ([string]$admission.reason) -RunId $RunId -SessionId $SessionId -RunRoot $runRootHint
            Set-TelephoneLastLeadLaunchDiagnostic -Diagnostic $diag
            throw 'LEAD_WAKE_FAILED'
        }
        [IO.Directory]::CreateDirectory($runRootHint) | Out-Null
    }
    $captured = $null
    try {
        $captured = Invoke-TelephoneLeadDrainedProcess -FileName $fileName -Arguments @($drainArgs) -WorkingDirectory $workdir -LifecyclePath $lifecyclePath -OwnerPath $ownerPath -EventsPath $eventsPath -SessionId $SessionId -RunId $RunId -Role 'host' -ReturnOnNativeComplete
    } catch {
        $diag = New-TelephoneLeadLaunchDiagnostic -Code 'LEAD_CLI_UNLAUNCHABLE' -Executable $fileName -WorkingDirectory $workdir -CreateProcessError ([string]$_.Exception.Message) -RunId $RunId -SessionId $SessionId
        Set-TelephoneLastLeadLaunchDiagnostic -Diagnostic $diag
        throw 'LEAD_CLI_UNLAUNCHABLE'
    }
    if (-not [bool]$captured.process_exited -and -not [bool]$captured.native_turn_complete) {
        $diag = New-TelephoneLeadLaunchDiagnostic -Code 'LEAD_WAKE_INCOMPLETE_HOST' -Executable $fileName -WorkingDirectory $workdir -Captured $captured -RunId $RunId -SessionId $SessionId -RunRoot $runRootHint
        Set-TelephoneLastLeadLaunchDiagnostic -Diagnostic $diag
        throw 'LEAD_WAKE_INCOMPLETE_HOST'
    }
    $conflict = Test-TelephoneLeadPreTurnActiveWriterConflict -RunRoot $runRootHint -StderrText ([string]$captured.stderr) -ExitCode $(if ([bool]$captured.process_exited) { [int]$captured.exit_code } else { $null }) -ExpectedSessionId $SessionId -ExpectedRunId $RunId
    if ([bool]$conflict.matched) {
        if ($null -ne $conflict.writer -and [string]$conflict.writer_identity_status -ceq 'bound' -and -not [string]::IsNullOrWhiteSpace($runRootHint)) {
            $priorPath = Join-Path $runRootHint 'prior-writer.json'
            if (-not [IO.File]::Exists($priorPath)) {
                try { $null = Write-TelephoneJsonCreateNew -Path $priorPath -Value $conflict.writer } catch [IO.IOException] { }
            }
        }
        $diag = New-TelephoneLeadLaunchDiagnostic -Code 'LEAD_WAKE_PRE_TURN_CONFLICT' -Executable $fileName -WorkingDirectory $workdir -Captured $captured -RunId $RunId -SessionId $SessionId -RunRoot $(if (-not [string]::IsNullOrWhiteSpace([string]$conflict.run_root)) { [string]$conflict.run_root } else { $runRootHint })
        Set-TelephoneLastLeadLaunchDiagnostic -Diagnostic $diag
        throw 'LEAD_WAKE_PRE_TURN_CONFLICT'
    }
    if ([bool]$captured.native_turn_complete -and -not [bool]$captured.process_exited -and -not [string]::IsNullOrWhiteSpace($runRootHint)) {
        Set-TelephoneLastLeadLaunchDiagnostic -Diagnostic $null
        return [ordered]@{
            run_root = $runRootHint
            state = 'native_complete_host_lingering'
            wake_run_id = [string]$RunId
            process_exited = $false
            native_turn_complete = $true
            pid = [int]$captured.pid
            executable_path = [string]$captured.executable_path
        }
    }
    if (-not $PriorOwnerRetry) {
        $handoff = Invoke-TelephonePriorOwnerHandoff -LauncherPath $LauncherPath -ExtraArguments $ExtraArguments -Worktree $Worktree -PromptFile $PromptFile -SessionId $SessionId -RunId $RunId -Captured $captured
        if ($null -ne $handoff) { return $handoff }
    }
    if ([int]$captured.exit_code -ne 0 -or [string]::IsNullOrWhiteSpace([string]$captured.stdout)) {
        $code = 'LEAD_WAKE_FAILED'
        $diag = New-TelephoneLeadLaunchDiagnostic -Code $code -Executable $fileName -WorkingDirectory $workdir -Captured $captured -RunId $RunId -SessionId $SessionId -RunRoot $runRootHint
        Set-TelephoneLastLeadLaunchDiagnostic -Diagnostic $diag
        throw $code
    }
    $launch = $null
    try {
        $launch = [string]$captured.stdout | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    } catch {
        $diag = New-TelephoneLeadLaunchDiagnostic -Code 'LEAD_WAKE_FAILED' -Executable $fileName -WorkingDirectory $workdir -Captured $captured -RunId $RunId -SessionId $SessionId -RunRoot $runRootHint
        Set-TelephoneLastLeadLaunchDiagnostic -Diagnostic $diag
        throw 'LEAD_WAKE_FAILED'
    }
    if ([string]::IsNullOrWhiteSpace([string]$launch.run_root)) {
        $diag = New-TelephoneLeadLaunchDiagnostic -Code 'LEAD_WAKE_FAILED' -Executable $fileName -WorkingDirectory $workdir -Captured $captured -RunId $RunId -SessionId $SessionId -RunRoot $runRootHint
        Set-TelephoneLastLeadLaunchDiagnostic -Diagnostic $diag
        throw 'LEAD_WAKE_FAILED'
    }
    return $launch
}

function Save-TelephoneNamedLaunchResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$WakeKey,
        [Parameter(Mandatory = $true)][string]$LineJobId
    )
    $record = [ordered]@{
        protocol_version = 'telephone-line-wake-launch-result-v1'
        line_job_id = [string]$LineJobId
        wake_run_id = $RunId
        wake_key = $WakeKey
        run_root = [string]$Launch.run_root
        state = [string]$Launch.state
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try { $null = Write-TelephoneJsonCreateNew -Path $Path -Value $record } catch [IO.IOException] { }
    if (-not [IO.File]::Exists($Path)) { return $null }
    return (Read-TelephoneJson -Path $Path).value
}

function Invoke-TelephoneNamedWakeAttach {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LaunchResultPath,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [object[]]$ExtraArguments,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$WakeKey,
        [Parameter(Mandatory = $true)][string]$LineJobId
    )
    Set-TelephoneLastLeadLaunchDiagnostic -Diagnostic $null
    if ([IO.File]::Exists($LaunchResultPath)) { return (Read-TelephoneJson -Path $LaunchResultPath).value }
    $jobDir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($LaunchResultPath))
    $diagnosticPath = Join-Path $jobDir 'wake-reconcile.json'
    $cliDiagnosticPath = Join-Path $jobDir 'cli-diagnostic.json'
    $retryPath = Join-Path $jobDir 'wake-retry.json'
    $attemptsDir = Join-Path $jobDir 'wake-attempts'
    $extraForLaunch = @($ExtraArguments)
    $frozenCmd = Get-TelephoneLeadNamedArgumentValue -Arguments $ExtraArguments -Name 'CodexCommand'
    $stablePolicy = Get-TelephoneLeadStableCliPolicy
    $hasConfiguredCli = -not [string]::IsNullOrWhiteSpace([string]$stablePolicy.executable)
    if (-not [string]::IsNullOrWhiteSpace($frozenCmd) -and $hasConfiguredCli) {
        $resolvedCli = Resolve-TelephoneLeadCliExecutable -FrozenExecutable $frozenCmd -Probe
        if ($null -ne $resolvedCli.diagnostic) {
            try { $null = Write-TelephoneJsonCreateNew -Path $cliDiagnosticPath -Value $resolvedCli.diagnostic } catch [IO.IOException] { }
        }
        if (-not [bool]$resolvedCli.launchable) { throw 'LEAD_CLI_UNLAUNCHABLE' }
        $extraForLaunch = @(Copy-TelephoneLeadExtraArgumentsWithCli -Arguments $ExtraArguments -Executable ([string]$resolvedCli.executable))
    }
    $stateHint = Get-TelephoneLeadNamedArgumentValue -Arguments $ExtraArguments -Name 'StateRootOverride'
    if ([string]::IsNullOrWhiteSpace($stateHint) -and -not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_LEAD_STATE_ROOT)) {
        $stateHint = [string]$env:TELEPHONE_LINE_LEAD_STATE_ROOT
    }
    $runRootHint = ''
    if (-not [string]::IsNullOrWhiteSpace($stateHint)) {
        $runRootHint = [IO.Path]::GetFullPath((Join-Path $stateHint $RunId)).TrimEnd('\')
    }

    function Read-TelephoneWakeRetryIndex {
        param([string]$Path)
        if (-not [IO.File]::Exists($Path)) {
            return [ordered]@{
                protocol_version = 'telephone-line-wake-retry-v1'
                original_wake_run_id = [string]$RunId
                wake_key = [string]$WakeKey
                line_job_id = [string]$LineJobId
                lead_session_id = [string]$SessionId
                failed_run_root = $runRootHint
                current_attempt = 0
                attempts = @()
            }
        }
        try {
            $doc = (Read-TelephoneJson -Path $Path).value
            if ($doc -isnot [Collections.IDictionary]) { throw 'invalid' }
            if (-not $doc.Contains('attempts') -or $null -eq $doc['attempts']) { $doc['attempts'] = @() }
            return $doc
        } catch {
            return [ordered]@{
                protocol_version = 'telephone-line-wake-retry-v1'
                original_wake_run_id = [string]$RunId
                wake_key = [string]$WakeKey
                line_job_id = [string]$LineJobId
                lead_session_id = [string]$SessionId
                failed_run_root = $runRootHint
                current_attempt = 0
                attempts = @()
            }
        }
    }

    function Test-TelephoneWakeAttemptAccepted {
        param([string]$AttemptRunId, [string]$AttemptRoot)
        if ([string]::IsNullOrWhiteSpace($AttemptRoot) -or -not [IO.Directory]::Exists($AttemptRoot)) { return $false }
        $ackPath = Join-Path $AttemptRoot 'lead-wake-ack.json'
        if (-not [IO.File]::Exists($ackPath)) { return $false }
        try {
            $ack = (Read-TelephoneJson -Path $ackPath).value
            if ([string]$ack.protocol_version -cne 'telephone-line-lead-wake-ack-v1') { return $false }
            if ([string]$ack.session_id -cne $SessionId) { return $false }
            if ($ack.Contains('run_id') -and -not [string]::IsNullOrWhiteSpace([string]$ack['run_id']) -and [string]$ack['run_id'] -cne $AttemptRunId) { return $false }
            if (-not $ack.Contains('run_id') -or [string]::IsNullOrWhiteSpace([string]$ack['run_id'])) { return $false }
            if (-not [string]::IsNullOrWhiteSpace([string]$WakeKey)) {
                if (-not $ack.Contains('wake_key') -or [string]$ack['wake_key'] -cne [string]$WakeKey) { return $false }
            }
            return $true
        } catch {
            return $false
        }
    }

    $index = Read-TelephoneWakeRetryIndex -Path $retryPath
    foreach ($row in @($index.attempts)) {
        if ($row -isnot [Collections.IDictionary]) { continue }
        $attemptRun = ''
        $attemptRoot = ''
        if ($row.Contains('retry_wake_run_id')) { $attemptRun = [string]$row['retry_wake_run_id'] }
        if ($row.Contains('run_root')) { $attemptRoot = [string]$row['run_root'] }
        if ([string]::IsNullOrWhiteSpace($attemptRoot) -and -not [string]::IsNullOrWhiteSpace($stateHint) -and -not [string]::IsNullOrWhiteSpace($attemptRun)) {
            $attemptRoot = [IO.Path]::GetFullPath((Join-Path $stateHint $attemptRun)).TrimEnd('\')
        }
        $accepted = $false
        if ($row.Contains('accepted')) { $accepted = [bool]$row['accepted'] }
        if (-not $accepted) { $accepted = Test-TelephoneWakeAttemptAccepted -AttemptRunId $attemptRun -AttemptRoot $attemptRoot }
        if (-not $accepted -or [string]::IsNullOrWhiteSpace($attemptRoot)) { continue }
        $launch = [ordered]@{ run_root = $attemptRoot; state = 'attached'; wake_run_id = $attemptRun; wake_key = [string]$WakeKey }
        $saved = Save-TelephoneNamedLaunchResult -Path $LaunchResultPath -Launch $launch -RunId $attemptRun -WakeKey $WakeKey -LineJobId $LineJobId
        if ($null -ne $saved) { return $saved }
        return $launch
    }

    if (-not [string]::IsNullOrWhiteSpace($runRootHint) -and [IO.Directory]::Exists($runRootHint)) {
        $conflict = Test-TelephoneLeadPreTurnActiveWriterConflict -RunRoot $runRootHint -ExpectedSessionId $SessionId -ExpectedRunId $RunId
        if ([bool]$conflict.matched) {
            $diag = New-TelephoneLeadLaunchDiagnostic -Code 'LEAD_WAKE_PRE_TURN_CONFLICT' -RunId $RunId -SessionId $SessionId -RunRoot $runRootHint -Captured ([ordered]@{ stderr = [string]$conflict.stderr; exit_code = $conflict.exit_code; process_exited = $true })
            Set-TelephoneLastLeadLaunchDiagnostic -Diagnostic $diag
            if (-not [bool]$conflict.retry_eligible -or [bool]$conflict.writer_alive -or [string]$conflict.writer_identity_status -cne 'bound') {
                throw 'LEAD_WAKE_PRE_TURN_CONFLICT'
            }
            $currentAttempt = 0
            try { $currentAttempt = [int]$index['current_attempt'] } catch { $currentAttempt = 0 }
            if ($currentAttempt -gt 0) {
                $currentRow = $null
                foreach ($row in @($index.attempts)) {
                    if ($row -is [Collections.IDictionary] -and [int]$row['attempt'] -eq $currentAttempt) { $currentRow = $row; break }
                }
                if ($null -ne $currentRow) {
                    $status = ''
                    if ($currentRow.Contains('status')) { $status = [string]$currentRow['status'] }
                    if ($status -cin @('intent', 'launched', 'accepted', 'ambiguous')) {
                        throw 'LEAD_WAKE_AMBIGUOUS'
                    }
                }
            }
            $nextAttempt = 1
            foreach ($row in @($index.attempts)) {
                if ($row -is [Collections.IDictionary] -and $row.Contains('attempt')) {
                    $n = [int]$row['attempt']
                    if ($n -ge $nextAttempt) { $nextAttempt = $n + 1 }
                }
            }
            $retryRunId = [string]$RunId + '-retry-' + [string]$nextAttempt
            [IO.Directory]::CreateDirectory($attemptsDir) | Out-Null
            $intentPath = Join-Path $attemptsDir ('attempt-' + [string]$nextAttempt + '-intent.json')
            $resultPath = Join-Path $attemptsDir ('attempt-' + [string]$nextAttempt + '-result.json')
            $intent = [ordered]@{
                protocol_version = 'telephone-line-wake-attempt-intent-v1'
                original_wake_run_id = [string]$RunId
                wake_key = [string]$WakeKey
                line_job_id = [string]$LineJobId
                lead_session_id = [string]$SessionId
                attempt = [int]$nextAttempt
                retry_wake_run_id = $retryRunId
                writer_released = $true
                executor_rerun = $false
                recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            }
            try { $null = Write-TelephoneJsonCreateNew -Path $intentPath -Value $intent } catch [IO.IOException] {
                throw 'LEAD_WAKE_AMBIGUOUS'
            }
            $attemptRows = [Collections.Generic.List[object]]::new()
            foreach ($row in @($index.attempts)) { [void]$attemptRows.Add($row) }
            [void]$attemptRows.Add([ordered]@{
                attempt = [int]$nextAttempt
                retry_wake_run_id = $retryRunId
                intent_path = $intentPath
                result_path = $resultPath
                status = 'intent'
                accepted = $false
                recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            })
            $index['protocol_version'] = 'telephone-line-wake-retry-v1'
            $index['original_wake_run_id'] = [string]$RunId
            $index['wake_key'] = [string]$WakeKey
            $index['line_job_id'] = [string]$LineJobId
            $index['lead_session_id'] = [string]$SessionId
            $index['failed_run_root'] = $runRootHint
            $index['current_attempt'] = [int]$nextAttempt
            $index['attempts'] = @($attemptRows)
            $index['writer_released'] = $true
            $index['executor_rerun'] = $false
            $index['recorded_at_utc'] = [DateTimeOffset]::UtcNow.ToString('o')
            $null = Write-TelephoneJsonReplace -Path $retryPath -Value $index
            $launchRetry = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $LauncherPath -ExtraArguments $extraForLaunch -Worktree $Worktree -PromptFile $PromptFile -SessionId $SessionId -RunId $retryRunId
            $launchRetry['wake_run_id'] = $retryRunId
            $launchRetry['wake_key'] = [string]$WakeKey
            $result = [ordered]@{
                protocol_version = 'telephone-line-wake-attempt-result-v1'
                original_wake_run_id = [string]$RunId
                wake_key = [string]$WakeKey
                attempt = [int]$nextAttempt
                retry_wake_run_id = $retryRunId
                run_root = [string]$launchRetry.run_root
                accepted = $true
                recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            }
            try { $null = Write-TelephoneJsonCreateNew -Path $resultPath -Value $result } catch [IO.IOException] { }
            $attemptRows[$attemptRows.Count - 1]['status'] = 'accepted'
            $attemptRows[$attemptRows.Count - 1]['accepted'] = $true
            $attemptRows[$attemptRows.Count - 1]['run_root'] = [string]$launchRetry.run_root
            $index['attempts'] = @($attemptRows)
            $null = Write-TelephoneJsonReplace -Path $retryPath -Value $index
            $savedRetry = Save-TelephoneNamedLaunchResult -Path $LaunchResultPath -Launch $launchRetry -RunId $retryRunId -WakeKey $WakeKey -LineJobId $LineJobId
            if ($null -ne $savedRetry) { return $savedRetry }
            return $launchRetry
        }
        $reconcile = Invoke-TelephoneLeadWakeReconcile -LaunchResultPath $LaunchResultPath -RunId $RunId -SessionId $SessionId -ExtraArguments $extraForLaunch -Worktree $Worktree -DiagnosticPath $diagnosticPath
        if ([string]$reconcile.decision -cin @('attached', 'recovered_attach') -and $null -ne $reconcile.launch) {
            $savedReconcile = Save-TelephoneNamedLaunchResult -Path $LaunchResultPath -Launch $reconcile.launch -RunId $RunId -WakeKey $WakeKey -LineJobId $LineJobId
            if ($null -ne $savedReconcile) { return $savedReconcile }
            return $reconcile.launch
        }
        $code = [string]$reconcile.error_code
        if ([string]::IsNullOrWhiteSpace($code)) { $code = 'LEAD_WAKE_AMBIGUOUS' }
        throw $code
    }
    $launch = Invoke-TelephoneFrozenLeadLauncher -LauncherPath $LauncherPath -ExtraArguments $extraForLaunch -Worktree $Worktree -PromptFile $PromptFile -SessionId $SessionId -RunId $RunId
    $saved = Save-TelephoneNamedLaunchResult -Path $LaunchResultPath -Launch $launch -RunId $RunId -WakeKey $WakeKey -LineJobId $LineJobId
    if ($null -ne $saved) { return $saved }
    return $launch
}

function New-TelephoneOwnerWakePromptText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Dispatch,
        [Parameter(Mandatory = $true)][object]$Receipt,
        [Parameter(Mandatory = $true)][object]$ReceiptIdentity,
        [AllowNull()][object]$NestedTerminal = $null,
        [string]$WakeKey = ''
    )
    $text = @"
# Telephone-line durable receipt delivery

The external route produced a durable receipt. This message delivers the telephone-line result only. It does not judge project content, correctness, or acceptance.

- line_job_id: $([string]$Dispatch.line_job_id)
- project: $([string]$Dispatch.project)
- stage: $([string]$Dispatch.stage)
- role: $([string]$Dispatch.role)
- route: $([string]$Dispatch.route)
- summary: $([string]$Dispatch.summary)
- receipt: $([string]$ReceiptIdentity.path)
- receipt_bytes: $([int64]$ReceiptIdentity.bytes)
- receipt_sha256: $([string]$ReceiptIdentity.sha256)
- wake_key: $([string]$WakeKey)
- transport_complete: $([bool]$Receipt.transport_complete)
- command_exit_code: $($Receipt.command_exit_code)

Resume the exact Lead session recorded in the frozen Lead binding. If another external hop is required, dispatch it through the telephone line and end the Lead turn immediately. Never wait online for an external route.
"@
    if ($null -ne $NestedTerminal) {
        $text = $text + @"

Nested target official terminal:
- nested_session_id: $([string]$NestedTerminal.session_id)
- nested_state: $([string]$NestedTerminal.state)
- nested_wake_run_id: $([string]$NestedTerminal.wake_run_id)
"@
    }
    return $text
}

function New-TelephoneBatchWakePromptText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$Lead
    )
    $lines = [Collections.Generic.List[string]]::new()
    [void]$lines.Add('# Telephone-line batch receipt delivery')
    [void]$lines.Add('')
    [void]$lines.Add('The mailbox closed this batch at exact N/N. This message delivers pointers to the durable receipts only. It does not judge project content, correctness, or acceptance.')
    [void]$lines.Add('')
    [void]$lines.Add('- batch_id: ' + [string]$Manifest.batch_id)
    [void]$lines.Add('- n: ' + [string]$Manifest.n)
    [void]$lines.Add('- counted: ' + [string]$Manifest.counted)
    [void]$lines.Add('- lead_session_id: ' + [string]$Lead.session_id)
    [void]$lines.Add('- closed: true')
    [void]$lines.Add('- acceptance_eligible: ' + ([bool]$Manifest.acceptance_eligible).ToString().ToLowerInvariant())
    [void]$lines.Add('')
    [void]$lines.Add('Receipts in mailbox FIFO order:')
    foreach ($item in @($Manifest.items)) {
        [void]$lines.Add(('- sequence ' + [string]$item.sequence + ': package_id=' + [string]$item.package_id + ' line_job_id=' + [string]$item.line_job_id + ' classification=' + [string]$item.classification + ' receipt_sha256=' + [string]$item.receipt.sha256))
    }
    [void]$lines.Add('')
    [void]$lines.Add('Resume the exact Lead session recorded in the frozen Lead binding. Never wait online for an external route.')
    return ([string]::Join("`n", $lines) + "`n")
}

function Write-TelephoneMailboxFailClosed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BatchId,
        [Parameter(Mandatory = $true)][string]$Code,
        [string]$LeadSessionId = ''
    )
    $record = [ordered]@{
        protocol_version = 'telephone-line-mailbox-fail-closed-v1'
        batch_id = [string]$BatchId
        lead_session_id = [string]$LeadSessionId
        retrying = $false
        error_code = [string]$Code
        error_message = Get-TelephonePublicErrorMessage -ErrorCode $Code
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try { $null = Write-TelephoneJsonCreateNew -Path $Path -Value $record } catch [IO.IOException] { }
}

function Enter-TelephoneLeadCollectorOwner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$MailboxPaths,
        [Parameter(Mandatory = $true)][string]$LeadKey
    )
    $gate = Open-TelephoneExclusiveGate -Path ([string]$MailboxPaths.gate) -WaitMilliseconds 15000
    if ($null -eq $gate) { throw 'Lead mailbox collector gate is held.' }
    try {
        $ownerPath = [string]$MailboxPaths.owner
        if ([IO.File]::Exists($ownerPath)) {
            $existing = $null
            try {
                $existing = (Read-TelephoneJson -Path $ownerPath).value
            } catch {
                Write-TelephoneMailboxFailClosed -Path ([string]$MailboxPaths.fail_closed) -BatchId '00000000-0000-0000-0000-000000000000' -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ''
                throw 'Lead mailbox collector owner is malformed.'
            }
            if ($existing -isnot [Collections.IDictionary] -or -not $existing.Contains('pid') -or -not $existing.Contains('start_time_utc_ticks')) {
                Write-TelephoneMailboxFailClosed -Path ([string]$MailboxPaths.fail_closed) -BatchId '00000000-0000-0000-0000-000000000000' -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ''
                throw 'Lead mailbox collector owner is malformed.'
            }
            $existingKey = ''
            if ($existing.Contains('lead_identity_sha256')) { $existingKey = [string]$existing.lead_identity_sha256 }
            if (-not [string]::IsNullOrWhiteSpace($existingKey) -and $existingKey -cne $LeadKey) {
                Write-TelephoneMailboxFailClosed -Path ([string]$MailboxPaths.fail_closed) -BatchId '00000000-0000-0000-0000-000000000000' -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ''
                throw 'Lead mailbox collector owner identity drifted.'
            }
            if (Test-TelephoneOwnerAlive -Owner $existing) {
                if ([int]$existing.pid -eq [int]$PID) { return $true }
                return $false
            }
        }
        $self = New-TelephoneCollectorOwnerRecord -LeadKey $LeadKey
        if ([IO.File]::Exists($ownerPath)) {
            $null = Write-TelephoneJsonReplace -Path $ownerPath -Value $self
        } else {
            try { $null = Write-TelephoneJsonCreateNew -Path $ownerPath -Value $self } catch [IO.IOException] {
                $again = (Read-TelephoneJson -Path $ownerPath).value
                if (Test-TelephoneOwnerAlive -Owner $again -and [int]$again.pid -ne [int]$PID) { return $false }
                throw
            }
        }
        Test-TelephoneCollectorCrashAfter -Point 'owner_claim' -MailboxPaths $MailboxPaths
        return $true
    } finally {
        $gate.Dispose()
    }
}

function Ensure-TelephoneLeadCollector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$LeadKey,
        [Parameter(Mandatory = $true)][string]$RelayScript
    )
    $paths = Get-TelephoneLeadMailboxPaths -StateRoot $StateRoot -LeadKey $LeadKey
    [IO.Directory]::CreateDirectory([string]$paths.lead_root) | Out-Null
    $existing = $null
    $gate = Open-TelephoneExclusiveGate -Path ([string]$paths.gate) -WaitMilliseconds 15000
    if ($null -eq $gate) { throw 'Lead mailbox collector gate is held.' }
    try {
        if ([IO.File]::Exists([string]$paths.owner)) {
            try {
                $existing = (Read-TelephoneJson -Path ([string]$paths.owner)).value
            } catch {
                Write-TelephoneMailboxFailClosed -Path ([string]$paths.fail_closed) -BatchId '00000000-0000-0000-0000-000000000000' -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ''
                throw 'Lead mailbox collector owner is malformed.'
            }
            if ($existing -isnot [Collections.IDictionary] -or -not $existing.Contains('pid') -or -not $existing.Contains('start_time_utc_ticks')) {
                Write-TelephoneMailboxFailClosed -Path ([string]$paths.fail_closed) -BatchId '00000000-0000-0000-0000-000000000000' -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ''
                throw 'Lead mailbox collector owner is malformed.'
            }
            $existingKey = ''
            if ($existing.Contains('lead_identity_sha256')) { $existingKey = [string]$existing.lead_identity_sha256 }
            if (-not [string]::IsNullOrWhiteSpace($existingKey) -and $existingKey -cne $LeadKey) {
                Write-TelephoneMailboxFailClosed -Path ([string]$paths.fail_closed) -BatchId '00000000-0000-0000-0000-000000000000' -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ''
                throw 'Lead mailbox collector owner identity drifted.'
            }
            if (Test-TelephoneOwnerAlive -Owner $existing) { return $existing }
        }
    } finally {
        $gate.Dispose()
    }
    $launch = Start-TelephoneHiddenPowerShell -ScriptPath $RelayScript -Arguments @('-Collector', '-StateRoot', [string]$paths.state_root, '-LeadKey', $LeadKey)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ([IO.File]::Exists([string]$paths.owner)) {
            try {
                $owner = (Read-TelephoneJson -Path ([string]$paths.owner)).value
                if (Test-TelephoneOwnerAlive -Owner $owner) { return $owner }
            } catch { }
        }
        if (-not (Test-TelephoneOwnerAlive -Owner $launch)) { break }
        Start-Sleep -Milliseconds 50
    }
    if ([IO.File]::Exists([string]$paths.owner)) {
        $owner = (Read-TelephoneJson -Path ([string]$paths.owner)).value
        if (Test-TelephoneOwnerAlive -Owner $owner) { return $owner }
    }
    throw 'Lead mailbox collector did not start.'
}

function Register-TelephoneSupervisorBoundLineStateRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LineStateRoot)
    $runId = [string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID
    $supState = [string]$env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT
    if ([string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($supState)) { return $false }
    if ($runId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { return $false }
    $root = ''
    try { $root = [IO.Path]::GetFullPath($LineStateRoot).TrimEnd('\') } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($root) -or -not [IO.Directory]::Exists($root)) { return $false }
    $runDir = Join-Path (Join-Path $supState 'runs') $runId
    if (-not [IO.Directory]::Exists($runDir)) { return $false }
    $path = Join-Path $runDir 'bound-line-state-roots.json'
    $roots = [Collections.Generic.List[string]]::new()
    if ([IO.File]::Exists($path)) {
        try {
            $doc = (Read-TelephoneJson -Path $path).value
            if ($doc -is [Collections.IDictionary] -and $doc.Contains('state_roots')) {
                foreach ($item in @($doc.state_roots)) {
                    $one = [string]$item
                    if (-not [string]::IsNullOrWhiteSpace($one) -and -not $roots.Contains($one)) { [void]$roots.Add($one) }
                }
            }
        } catch { }
    }
    if (-not $roots.Contains($root)) { [void]$roots.Add($root) }
    $record = [ordered]@{
        protocol_version = 'telephone-line-supervisor-bound-line-state-v1'
        supervisor_run_id = $runId
        state_roots = @($roots)
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try {
        if ([IO.File]::Exists($path)) { $null = Write-TelephoneJsonReplace -Path $path -Value $record }
        else { $null = Write-TelephoneJsonCreateNew -Path $path -Value $record }
        return $true
    } catch {
        return $false
    }
}

function Restore-TelephoneExactJobRelay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobRoot,
        [string]$RelayScript = '',
        [switch]$InitialLaunch
    )
    $result = [ordered]@{
        protocol_version = 'telephone-line-exact-relay-restore-v1'
        job_root = ''
        restored = $false
        reason = ''
        owner = $null
        provider_replayed = $false
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $root = ''
    try { $root = [IO.Path]::GetFullPath($JobRoot).TrimEnd('\') } catch { $result.reason = 'job_root_invalid'; return $result }
    $result.job_root = $root
    $paths = Get-TelephoneJobPaths -JobRoot $root
    if ([IO.File]::Exists($paths.delivery)) { $result.reason = 'already_delivered'; return $result }
    $relayOwner = $null
    if ([IO.File]::Exists($paths.relay_owner)) {
        try { $relayOwner = (Read-TelephoneJson -Path $paths.relay_owner).value } catch { $relayOwner = $null }
    }
    if (Test-TelephoneOwnerAlive -Owner $relayOwner) { $result.reason = 'relay_alive'; $result.owner = $relayOwner; return $result }
    $scriptPath = $RelayScript
    if ([string]::IsNullOrWhiteSpace($scriptPath)) { $scriptPath = Join-Path $PSScriptRoot 'Invoke-TelephoneLineRelay.ps1' }
    if (-not [IO.File]::Exists($scriptPath)) { $result.reason = 'relay_script_missing'; return $result }
    $gate = $null
    try {
        $gate = Open-TelephoneExclusiveGate -Path (Join-Path $root 'relay-restore.lock') -WaitMilliseconds 8000
        if ($null -eq $gate) { $result.reason = 'restore_lock_busy'; return $result }
        $relayOwner = $null
        if ([IO.File]::Exists($paths.relay_owner)) {
            try { $relayOwner = (Read-TelephoneJson -Path $paths.relay_owner).value } catch { $relayOwner = $null }
        }
        if (Test-TelephoneOwnerAlive -Owner $relayOwner) { $result.reason = 'relay_alive'; $result.owner = $relayOwner; return $result }
        if ([IO.File]::Exists($paths.delivery)) { $result.reason = 'already_delivered'; return $result }
        $newRelay = Start-TelephoneHiddenPowerShell -ScriptPath $scriptPath -Arguments @('-JobRoot', $root)
        if (-not $InitialLaunch) {
            $attemptPath = Join-Path $root ('relay-resume-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '.json')
            try { $null = Write-TelephoneJsonCreateNew -Path $attemptPath -Value $newRelay } catch { }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID)) {
            $newRelay['supervisor_run_id'] = [string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID
        }
        if (-not (Test-TelephoneOwnerAlive -Owner $newRelay)) {
            $result.reason = 'relay_launch_not_alive'
            $result.owner = $newRelay
            return $result
        }
        $lineagePath = Join-Path $root 'supervisor-lineage.json'
        if ([IO.File]::Exists($lineagePath) -and [int]$newRelay.pid -gt 0) {
            $prevRun = [string]$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID
            try {
                $lineage = (Read-TelephoneJson -Path $lineagePath).value
                if ($lineage -is [Collections.IDictionary] -and -not [string]::IsNullOrWhiteSpace([string]$lineage.supervisor_run_id)) {
                    $env:TELEPHONE_LINE_SUPERVISOR_RUN_ID = [string]$lineage.supervisor_run_id
                    $null = Add-TelephoneProcessToSupervisorRunJob -ProcessId ([int]$newRelay.pid)
                }
            } catch { }
            finally { $env:TELEPHONE_LINE_SUPERVISOR_RUN_ID = $prevRun }
        }
        if ($InitialLaunch) {
            # Initial launch and restoration hold the same gate. A restorer may
            # have won before the starter arrived, so adopt its live owner above.
            # Real publication failures must still propagate to the starter.
            if ([IO.File]::Exists($paths.relay_owner)) {
                $null = Write-TelephoneJsonReplace -Path $paths.relay_owner -Value $newRelay
            } else {
                $null = Write-TelephoneJsonCreateNew -Path $paths.relay_owner -Value $newRelay
            }
        } else {
            try { $null = Write-TelephoneJsonReplace -Path $paths.relay_owner -Value $newRelay } catch {
                try { $null = Write-TelephoneJsonCreateNew -Path $paths.relay_owner -Value $newRelay } catch { }
            }
        }
        $result.restored = $true
        $result.reason = 'relay_restored'
        $result.owner = $newRelay
        return $result
    } finally {
        if ($null -ne $gate) { $gate.Dispose() }
    }
}

function Get-TelephoneNextMailboxSequence {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$MailboxPaths)
    $seqPath = [string]$MailboxPaths.seq
    $current = 0
    if ([IO.File]::Exists($seqPath)) {
        $doc = (Read-TelephoneJson -Path $seqPath).value
        $current = [int]$doc.n
    }
    $next = $current + 1
    $null = Write-TelephoneJsonReplace -Path $seqPath -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-seq-v1'
        n = $next
        updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })
    return $next
}

function Get-TelephoneMailboxItemId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LeadKey,
        [Parameter(Mandatory = $true)][string]$LineJobId,
        [Parameter(Mandatory = $true)][string]$ReceiptSha256
    )
    return (Get-TelephoneUtf8Sha256 -Text ($LeadKey + '|' + $LineJobId + '|' + $ReceiptSha256))
}

function Add-TelephoneMailboxItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][object]$DispatchRead,
        [Parameter(Mandatory = $true)][object]$ReceiptRead,
        [Parameter(Mandatory = $true)][object]$JobPaths
    )
    $dispatch = $DispatchRead.value
    $receipt = $ReceiptRead.value
    $lead = Read-TelephoneLeadBinding -Lead $dispatch.lead
    $canonical = Get-TelephoneLeadCanonicalIdentity -Lead $lead
    $profile = Get-TelephoneLeadProfileIdentity -Lead $lead
    $batch = Resolve-TelephoneDispatchBatch -Dispatch $dispatch -LineJobId ([string]$dispatch.line_job_id)
    $classification = Get-TelephoneReceiptClassification -Paths $JobPaths -Receipt $receipt
    if ($classification -ceq 'start_ambiguous' -or $classification -ceq 'start_failed_unqualified') {
        return [ordered]@{ counted = $false; classification = $classification; lead_key = [string]$canonical.identity_sha256; batch = $batch }
    }
    $mailbox = Get-TelephoneLeadMailboxPaths -StateRoot $StateRoot -LeadKey ([string]$canonical.identity_sha256)
    [IO.Directory]::CreateDirectory([string]$mailbox.mailbox) | Out-Null
    foreach ($existingJob in @(Get-TelephoneStateJobs -StateRoot $StateRoot)) {
        if ([string]$existingJob.paths.root -ceq [string]$JobPaths.root) { continue }
        if ([string]$existingJob.batch.batch_id -cne [string]$batch.batch_id) { continue }
        if ([string]$existingJob.canonical.identity_sha256 -cne [string]$canonical.identity_sha256) {
            throw 'Mailbox item identity drifted.'
        }
        $existingSnap = $existingJob.identity
        $incomingSnap = ConvertTo-TelephoneComparableLeadIdentity -Canonical $canonical -Profile $profile
        if (-not (Test-TelephoneComparableLeadIdentityEqual -Left $existingSnap -Right $incomingSnap)) {
            throw 'Mailbox item identity drifted.'
        }
    }
    $itemId = Get-TelephoneMailboxItemId -LeadKey ([string]$canonical.identity_sha256) -LineJobId ([string]$dispatch.line_job_id) -ReceiptSha256 ([string]$ReceiptRead.identity.sha256)
    $itemPath = Join-Path ([string]$mailbox.mailbox) ($itemId + '.json')
    $gate = Open-TelephoneExclusiveGate -Path ([string]$mailbox.gate) -WaitMilliseconds 15000
    if ($null -eq $gate) { throw 'Lead mailbox collector gate is held.' }
    try {
        if ([IO.File]::Exists($itemPath)) {
            $existing = (Read-TelephoneJson -Path $itemPath).value
            $expected = [ordered]@{
                lead_session_id = [string]$canonical.session_id
                lead_worktree = [string]$canonical.worktree
                lead_launcher_path = [string]$canonical.launcher_path
                lead_identity_sha256 = [string]$canonical.identity_sha256
                line_job_id = [string]$dispatch.line_job_id
                batch_id = [string]$batch.batch_id
                package_id = [string]$batch.package_id
            }
            foreach ($field in @($expected.Keys)) {
                if ([string]$existing[$field] -cne [string]$expected[$field]) {
                    throw 'Mailbox item identity drifted.'
                }
            }
            $existingSnap = ConvertTo-TelephoneComparableLeadIdentityFromItem -Item $existing
            $incomingSnap = ConvertTo-TelephoneComparableLeadIdentity -Canonical $canonical -Profile $profile
            if (-not (Test-TelephoneComparableLeadIdentityEqual -Left $existingSnap -Right $incomingSnap)) {
                throw 'Mailbox item identity drifted.'
            }
            if ([string]$existing.receipt.sha256 -cne [string]$ReceiptRead.identity.sha256) { throw 'Mailbox item receipt drifted.' }
            if ([string]$existing.dispatch.sha256 -cne [string]$DispatchRead.identity.sha256) { throw 'Mailbox item dispatch drifted.' }
            return [ordered]@{ counted = $true; classification = [string]$existing.classification; lead_key = [string]$canonical.identity_sha256; batch = $batch; item = $existing; item_id = $itemId }
        }
        $sequence = Get-TelephoneNextMailboxSequence -MailboxPaths $mailbox
        $item = [ordered]@{
            protocol_version = 'telephone-line-mailbox-item-v1'
            item_id = $itemId
            sequence = $sequence
            batch_id = [string]$batch.batch_id
            package_id = [string]$batch.package_id
            package_ids = @($batch.package_ids)
            n = [int]$batch.n
            retry_of = $batch.retry_of
            implicit = [bool]$batch.implicit
            line_job_id = [string]$dispatch.line_job_id
            lead_session_id = [string]$canonical.session_id
            lead_worktree = [string]$canonical.worktree
            lead_identity_sha256 = [string]$canonical.identity_sha256
            lead_launcher_path = [string]$canonical.launcher_path
            classification = $classification
            dispatch = $DispatchRead.identity
            receipt = $ReceiptRead.identity
            job_root = [string]$JobPaths.root
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        if ($null -ne $profile) {
            $item['profile'] = [ordered]@{ path = [string]$profile.path; bytes = [int64]$profile.bytes; sha256 = [string]$profile.sha256 }
        }
        $null = Write-TelephoneJsonCreateNew -Path $itemPath -Value $item
        $ref = [ordered]@{
            protocol_version = 'telephone-line-mailbox-ref-v1'
            lead_identity_sha256 = [string]$canonical.identity_sha256
            batch_id = [string]$batch.batch_id
            item_id = $itemId
            item_path = $itemPath
        }
        try { $null = Write-TelephoneJsonCreateNew -Path ([string]$JobPaths.mailbox_ref) -Value $ref } catch [IO.IOException] { }
        return [ordered]@{ counted = $true; classification = $classification; lead_key = [string]$canonical.identity_sha256; batch = $batch; item = $item; item_id = $itemId }
    } finally {
        $gate.Dispose()
    }
}

function Get-TelephoneMailboxItems {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$MailboxPaths)
    $items = [Collections.Generic.List[object]]::new()
    $dir = [string]$MailboxPaths.mailbox
    if (-not [IO.Directory]::Exists($dir)) { return @() }
    foreach ($file in @([IO.Directory]::GetFiles($dir, '*.json'))) {
        $name = [IO.Path]::GetFileName($file)
        if ($name.StartsWith('.')) { continue }
        try {
            $item = (Read-TelephoneJson -Path $file).value
            if ([string]$item.protocol_version -cne 'telephone-line-mailbox-item-v1') { continue }
            $items.Add($item)
        } catch {
            throw 'Mailbox item is malformed.'
        }
    }
    return @($items | Sort-Object { [int]$_.sequence }, { [string]$_.created_at_utc }, { [string]$_.item_id })
}

function Get-TelephoneStateJobs {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    $jobs = [Collections.Generic.List[object]]::new()
    $jobsRoot = Join-Path ([IO.Path]::GetFullPath($StateRoot)) 'jobs'
    if (-not [IO.Directory]::Exists($jobsRoot)) { return @() }
    foreach ($dir in @([IO.Directory]::GetDirectories($jobsRoot))) {
        $paths = Get-TelephoneJobPaths -JobRoot $dir
        if (-not [IO.File]::Exists($paths.dispatch)) { continue }
        try {
            $dispatchRead = Read-TelephoneJson -Path $paths.dispatch -SchemaName 'dispatch'
            $dispatch = $dispatchRead.value
            $lead = Read-TelephoneLeadBinding -Lead $dispatch.lead
            $canonical = Get-TelephoneLeadCanonicalIdentity -Lead $lead
            $profile = Get-TelephoneLeadProfileIdentity -Lead $lead
            $batch = Resolve-TelephoneDispatchBatch -Dispatch $dispatch -LineJobId ([string]$dispatch.line_job_id)
            $jobs.Add([ordered]@{
                paths = $paths
                dispatch_read = $dispatchRead
                dispatch = $dispatch
                lead = $lead
                canonical = $canonical
                profile = $profile
                identity = (ConvertTo-TelephoneComparableLeadIdentity -Canonical $canonical -Profile $profile)
                batch = $batch
            })
        } catch { }
    }
    return @($jobs)
}

function Get-TelephoneLeadJobs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$LeadKey
    )
    return @(Get-TelephoneStateJobs -StateRoot $StateRoot | Where-Object { [string]$_.canonical.identity_sha256 -ceq $LeadKey })
}

function Write-TelephoneMailboxTruth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$MailboxPaths,
        [Parameter(Mandatory = $true)][object]$Batches
    )
    $null = Write-TelephoneJsonReplace -Path ([string]$MailboxPaths.truth) -Value ([ordered]@{
        protocol_version = 'telephone-line-mailbox-truth-v1'
        lead_identity_sha256 = [string]$MailboxPaths.lead_key
        observational = $true
        updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        batches = @($Batches)
    })
}

function Convert-TelephoneCollectionToObservationalBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LeadKey,
        [Parameter(Mandatory = $true)][object]$Collection
    )
    $missingRows = @()
    if ($Collection -is [Collections.IDictionary] -and $Collection.Contains('missing') -and $null -ne $Collection.missing) {
        $missingRows = @($Collection.missing)
    }
    $missingIds = @()
    if ($Collection -is [Collections.IDictionary] -and $Collection.Contains('missing_package_ids') -and $null -ne $Collection.missing_package_ids) {
        $missingIds = @($Collection.missing_package_ids | ForEach-Object { [string]$_ })
    }
    if ($missingRows.Count -gt 0 -and $missingIds.Count -eq 0) {
        $missingIds = @($missingRows | ForEach-Object { [string]$_.package_id })
    }
    $implicit = $false
    if ($Collection -is [Collections.IDictionary] -and $Collection.Contains('implicit')) { $implicit = [bool]$Collection.implicit }
    $closed = $false
    if ($Collection -is [Collections.IDictionary] -and $Collection.Contains('closed')) { $closed = [bool]$Collection.closed }
    $eligible = $closed
    if ($Collection -is [Collections.IDictionary] -and $Collection.Contains('acceptance_eligible')) { $eligible = [bool]$Collection.acceptance_eligible }
    return [ordered]@{
        lead_identity_sha256 = [string]$LeadKey
        batch_id = [string]$Collection.batch_id
        n = [int]$Collection.n
        counted = [int]$Collection.counted
        missing = @($missingRows)
        missing_package_ids = @($missingIds)
        state = [string]$Collection.state
        closed = $closed
        acceptance_eligible = $eligible
        implicit = $implicit
    }
}

function Merge-TelephoneMailboxTruthBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$MailboxPaths,
        [Parameter(Mandatory = $true)][object]$BatchRow
    )
    $batches = [Collections.Generic.List[object]]::new()
    $replaced = $false
    $truthPath = [string]$MailboxPaths.truth
    if ([IO.File]::Exists($truthPath)) {
        try {
            $truth = (Read-TelephoneJson -Path $truthPath).value
            foreach ($row in @($truth.batches)) {
                if ([string]$row.batch_id -ceq [string]$BatchRow.batch_id) {
                    $batches.Add($BatchRow)
                    $replaced = $true
                } else {
                    $batches.Add($row)
                }
            }
        } catch { }
    }
    if (-not $replaced) { $batches.Add($BatchRow) }
    $null = Write-TelephoneMailboxTruth -MailboxPaths $MailboxPaths -Batches @($batches)
}

function Get-TelephoneMailboxObservationalBatches {
    [CmdletBinding()]
    param([string]$StateRoot)
    $rows = [Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($StateRoot) -or -not [IO.Directory]::Exists($StateRoot)) { return @() }
    $leadsRoot = Join-Path ([IO.Path]::GetFullPath($StateRoot)) 'leads'
    if (-not [IO.Directory]::Exists($leadsRoot)) { return @() }
    foreach ($leadDir in @([IO.Directory]::GetDirectories($leadsRoot))) {
        $leadKey = [IO.Path]::GetFileName($leadDir)
        if ($leadKey -cnotmatch '^[0-9a-f]{64}$') { continue }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $batchesDir = Join-Path $leadDir 'batches'
        if ([IO.Directory]::Exists($batchesDir)) {
            foreach ($batchDir in @([IO.Directory]::GetDirectories($batchesDir))) {
                $collectionPath = Join-Path $batchDir 'collection.json'
                if (-not [IO.File]::Exists($collectionPath)) { continue }
                try {
                    $collection = (Read-TelephoneJson -Path $collectionPath).value
                    $row = Convert-TelephoneCollectionToObservationalBatch -LeadKey $leadKey -Collection $collection
                    if ([string]::IsNullOrWhiteSpace([string]$row.batch_id)) { continue }
                    if ($seen.Add([string]$row.batch_id)) { $rows.Add($row) }
                } catch { }
            }
        }
        $truthPath = Join-Path $leadDir 'truth.json'
        if (-not [IO.File]::Exists($truthPath)) { continue }
        try {
            $truth = (Read-TelephoneJson -Path $truthPath).value
            $truthKey = [string]$truth.lead_identity_sha256
            if (-not [string]::IsNullOrWhiteSpace($truthKey) -and $truthKey -cne $leadKey) { continue }
            foreach ($row in @($truth.batches)) {
                $batchId = [string]$row.batch_id
                if ([string]::IsNullOrWhiteSpace($batchId) -or -not $seen.Add($batchId)) { continue }
                $rows.Add((Convert-TelephoneCollectionToObservationalBatch -LeadKey $leadKey -Collection $row))
            }
        } catch { }
    }
    return @($rows)
}

function Add-TelephoneControlPlaneDeliveryBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Delivery,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Dispatch,
        [Parameter(Mandatory = $true)][object]$JobPaths
    )
    if (-not $Dispatch.Contains('control_plane') -or $null -eq $Dispatch.control_plane) { return $Delivery }
    $binding=$Dispatch.control_plane;$batch=Resolve-TelephoneDispatchBatch -Dispatch $Dispatch -LineJobId ([string]$Dispatch.line_job_id)
    $dispatchIdentity=Get-TelephoneFileIdentity -Path (Assert-TelephoneRegularFilePath -Path ([string]$JobPaths.dispatch) -Label 'Control-plane delivery dispatch')
    $receiptIdentity=Get-TelephoneFileIdentity -Path (Assert-TelephoneRegularFilePath -Path ([string]$JobPaths.receipt) -Label 'Control-plane delivery receipt')
    $Delivery['control_plane']=[ordered]@{
        protocol_version='telephone-line-control-plane-delivery-binding-v1';project=[string]$binding.project;project_epoch=[string]$binding.project_epoch;wave_id=[string]$binding.wave_id
        activation_generation=[string]$binding.activation_generation;lead_run_id=[string]$binding.lead_run_id;package_id=[string]$batch.package_id;batch_id=[string]$batch.batch_id
        attempt=[int]$binding.attempt;route=[string]$Dispatch.route;workspace=[string]$Dispatch.command.working_directory;write_lease_id=[string]$binding.write_lease_id
        dispatch_sha256=[string]$dispatchIdentity.sha256;receipt_sha256=[string]$receiptIdentity.sha256
    }
    return $Delivery
}

function Write-TelephoneLeadRetryingRelayError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$JobPaths,
        [Parameter(Mandatory = $true)][string]$LineJobId,
        [Parameter(Mandatory = $true)][string]$LeadSessionId,
        [Parameter(Mandatory = $true)][string]$ErrorCode,
        [AllowNull()][object]$Diagnostic = $null
    )
    $historyRoot = Join-Path ([string]$JobPaths.root) 'relay-error.history'
    [IO.Directory]::CreateDirectory($historyRoot) | Out-Null
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmssfff')
    if ([IO.File]::Exists($JobPaths.relay_error)) {
        $dest = Join-Path $historyRoot ($stamp + '-relay-error.json')
        try { [IO.File]::Copy($JobPaths.relay_error, $dest, $false) } catch [IO.IOException] { }
    }
    if ([IO.File]::Exists($JobPaths.launch_failure)) {
        $destFail = Join-Path $historyRoot ($stamp + '-launch-failure.json')
        try { [IO.File]::Copy($JobPaths.launch_failure, $destFail, $false) } catch [IO.IOException] { }
    }
    $relayError = [ordered]@{
        protocol_version = 'telephone-line-relay-error-v1'
        line_job_id = [string]$LineJobId
        lead_session_id = [string]$LeadSessionId
        retrying = $true
        error_code = [string]$ErrorCode
        error_message = Get-TelephonePublicErrorMessage -ErrorCode $ErrorCode
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        original_preserved = [IO.File]::Exists((Join-Path $historyRoot ($stamp + '-relay-error.json')))
    }
    if ($null -ne $Diagnostic) { $relayError['launch_diagnostic'] = $Diagnostic }
    if ([IO.File]::Exists($JobPaths.relay_error)) {
        $null = Write-TelephoneJsonReplace -Path $JobPaths.relay_error -Value $relayError
    } else {
        try { $null = Write-TelephoneJsonCreateNew -Path $JobPaths.relay_error -Value $relayError } catch [IO.IOException] {
            $null = Write-TelephoneJsonReplace -Path $JobPaths.relay_error -Value $relayError
        }
    }
    if ($null -ne $Diagnostic) {
        $attemptDiag = Join-Path $historyRoot ($stamp + '-diagnostic.json')
        try { $null = Write-TelephoneJsonCreateNew -Path $attemptDiag -Value $Diagnostic } catch [IO.IOException] { }
        try { $null = Write-TelephoneJsonReplace -Path $JobPaths.launch_failure -Value $Diagnostic } catch { }
    }
}

function Test-TelephoneTrustedConsumingRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConsumingRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId,
        [string]$ForbiddenRunId = '',
        [string]$ExpectedReceiptSha256 = '',
        [string]$ExpectedWakeKey = ''
    )
    try {
        $root = [IO.Path]::GetFullPath($ConsumingRoot).TrimEnd('\')
    } catch {
        return [ordered]@{ ok = $false; reason = 'consuming_run_invalid' }
    }
    if (-not [IO.Directory]::Exists($root)) {
        return [ordered]@{ ok = $false; reason = 'consuming_run_missing' }
    }
    $metaPath = Join-Path $root 'lead-run.json'
    $ownerPath = Join-Path $root 'owner.json'
    $eventsPath = Join-Path $root 'codex-events.jsonl'
    $hostTerminal = Join-Path $root 'host-terminal.json'
    $session = ''
    $run = ''
    $meta = $null
    if ([IO.File]::Exists($metaPath)) {
        try {
            $meta = (Read-TelephoneJson -Path $metaPath).value
            if ($meta -is [Collections.IDictionary]) {
                if ($meta.Contains('resume_session_id')) { $session = [string]$meta['resume_session_id'] }
                if ([string]::IsNullOrWhiteSpace($session) -and $meta.Contains('session_id')) { $session = [string]$meta['session_id'] }
                if ($meta.Contains('run_id')) { $run = [string]$meta['run_id'] }
            }
        } catch {
            return [ordered]@{ ok = $false; reason = 'consuming_run_unreadable' }
        }
    }
    if ([string]::IsNullOrWhiteSpace($session) -and [IO.File]::Exists($ownerPath)) {
        try {
            $owner = (Read-TelephoneJson -Path $ownerPath).value
            if ($owner -is [Collections.IDictionary]) {
                if ($owner.Contains('session_id')) { $session = [string]$owner['session_id'] }
                if ([string]::IsNullOrWhiteSpace($run) -and $owner.Contains('run_id')) { $run = [string]$owner['run_id'] }
            }
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($session)) {
        return [ordered]@{ ok = $false; reason = 'consuming_run_unbound' }
    }
    if ($session -cne $ExpectedSessionId) {
        return [ordered]@{ ok = $false; reason = 'consuming_run_wrong_session' }
    }
    if (-not [string]::IsNullOrWhiteSpace($ForbiddenRunId) -and $run -ceq $ForbiddenRunId) {
        return [ordered]@{ ok = $false; reason = 'consuming_run_is_failed_original' }
    }
    if (-not [IO.File]::Exists($eventsPath)) {
        return [ordered]@{ ok = $false; reason = 'consuming_run_event_missing'; session_id = $session; run_id = $run; root = $root }
    }
    $nativeTurn = $false
    $allocationOnly = $false
    $eventRunIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $foreignRun = $false
    try {
        foreach ($line in @([IO.File]::ReadAllLines($eventsPath))) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $evt = $line | ConvertFrom-Json -AsHashtable -Depth 16 -DateKind String
            } catch {
                continue
            }
            if ($evt -isnot [Collections.IDictionary]) { continue }
            $etype = ''
            if ($evt.Contains('type')) { $etype = [string]$evt['type'] }
            elseif ($evt.Contains('event')) { $etype = [string]$evt['event'] }
            $evtSession = ''
            if ($evt.Contains('session_id')) { $evtSession = [string]$evt['session_id'] }
            $evtRun = ''
            if ($evt.Contains('run_id')) { $evtRun = [string]$evt['run_id'] }
            $threadId = ''
            if ($evt.Contains('thread_id')) { $threadId = [string]$evt['thread_id'] }
            if ($etype -ceq 'thread.started' -or $etype -ceq 'session.created') {
                $allocationOnly = $true
                if (-not [string]::IsNullOrWhiteSpace($threadId) -and $threadId -cne $ExpectedSessionId) {
                    return [ordered]@{ ok = $false; reason = 'consuming_run_wrong_session'; session_id = $session; run_id = $run; root = $root }
                }
                if (-not [string]::IsNullOrWhiteSpace($evtSession) -and $evtSession -cne $ExpectedSessionId) {
                    return [ordered]@{ ok = $false; reason = 'consuming_run_wrong_session'; session_id = $session; run_id = $run; root = $root }
                }
                if (-not [string]::IsNullOrWhiteSpace($evtRun)) {
                    [void]$eventRunIds.Add($evtRun)
                    if (-not [string]::IsNullOrWhiteSpace($ForbiddenRunId) -and $evtRun -ceq $ForbiddenRunId) { $foreignRun = $true }
                }
                continue
            }
            if ($etype -ceq 'turn.started' -or $etype -ceq 'turn.completed') {
                if (-not [string]::IsNullOrWhiteSpace($evtSession) -and $evtSession -cne $ExpectedSessionId) {
                    return [ordered]@{ ok = $false; reason = 'consuming_run_wrong_session'; session_id = $session; run_id = $run; root = $root }
                }
                if (-not [string]::IsNullOrWhiteSpace($threadId) -and $threadId -cne $ExpectedSessionId) {
                    return [ordered]@{ ok = $false; reason = 'consuming_run_wrong_session'; session_id = $session; run_id = $run; root = $root }
                }
                if (-not [string]::IsNullOrWhiteSpace($evtRun) -and -not [string]::IsNullOrWhiteSpace($run) -and $evtRun -cne $run) {
                    return [ordered]@{ ok = $false; reason = 'consuming_run_event_foreign'; session_id = $session; run_id = $run; root = $root }
                }
                if (-not [string]::IsNullOrWhiteSpace($evtRun)) {
                    [void]$eventRunIds.Add($evtRun)
                    if (-not [string]::IsNullOrWhiteSpace($ForbiddenRunId) -and $evtRun -ceq $ForbiddenRunId) { $foreignRun = $true }
                }
                $nativeTurn = $true
            }
        }
    } catch {
        return [ordered]@{ ok = $false; reason = 'consuming_run_event_unreadable'; session_id = $session; run_id = $run; root = $root }
    }
    $preTurnExit = $false
    if ([IO.File]::Exists($hostTerminal)) {
        try {
            $term = (Read-TelephoneJson -Path $hostTerminal).value
            $exitCode = 0
            if ($term -is [Collections.IDictionary] -and $term.Contains('exit_code')) { $exitCode = [int]$term['exit_code'] }
            if ($exitCode -ne 0) { $preTurnExit = $true }
        } catch { }
    }
    if (-not $nativeTurn) {
        if ($preTurnExit) {
            return [ordered]@{ ok = $false; reason = 'consuming_run_rejected_pre_turn'; session_id = $session; run_id = $run; root = $root }
        }
        if ($allocationOnly) {
            return [ordered]@{ ok = $false; reason = 'consuming_run_allocation_only'; session_id = $session; run_id = $run; root = $root }
        }
        return [ordered]@{ ok = $false; reason = 'consuming_run_event_missing'; session_id = $session; run_id = $run; root = $root }
    }
    if ($foreignRun -and ($eventRunIds.Count -eq 1 -or [string]::IsNullOrWhiteSpace($run) -or -not $eventRunIds.Contains($run))) {
        return [ordered]@{ ok = $false; reason = 'consuming_run_is_failed_original'; session_id = $session; run_id = $run; root = $root }
    }
    if ($eventRunIds.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($run) -and -not $eventRunIds.Contains($run)) {
        return [ordered]@{ ok = $false; reason = 'consuming_run_event_foreign'; session_id = $session; run_id = $run; root = $root }
    }
    if ($meta -is [Collections.IDictionary] -and (-not [string]::IsNullOrWhiteSpace($ExpectedReceiptSha256) -or -not [string]::IsNullOrWhiteSpace($ExpectedWakeKey))) {
        try {
            $null = Test-TelephoneNativeWakeInputBinding -Run $meta -RunRoot $root -ExpectedWakeKey $ExpectedWakeKey -ExpectedReceiptSha256 $ExpectedReceiptSha256
        } catch {
            return [ordered]@{ ok = $false; reason = 'consuming_run_input_mismatch'; session_id = $session; run_id = $run; root = $root }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($ExpectedReceiptSha256) -or -not [string]::IsNullOrWhiteSpace($ExpectedWakeKey)) {
        return [ordered]@{ ok = $false; reason = 'consuming_run_input_unbound'; session_id = $session; run_id = $run; root = $root }
    }
    return [ordered]@{ ok = $true; reason = ''; session_id = $session; run_id = $run; root = $root }
}

function Test-TelephoneMailboxItemConsumed {
    [CmdletBinding()]
    param([AllowNull()][object]$Item)
    if ($null -eq $Item -or $Item -isnot [Collections.IDictionary]) { return $false }
    if ($Item.Contains('trusted_manual_closeout') -and [bool]$Item['trusted_manual_closeout']) { return $true }
    $kind = ''
    if ($Item.Contains('delivery_kind')) { $kind = [string]$Item['delivery_kind'] }
    if ($kind -ceq 'AUTOMATIC_WAKE_ACK' -or $kind -ceq 'MANUAL_TRUSTED_CONSUMPTION') { return $true }
    if ($Item.Contains('automatic_callback_success') -and [bool]$Item['automatic_callback_success']) { return $true }
    return $false
}

function Merge-TelephoneTrustedCollectionConsumption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$MailboxPaths,
        [Parameter(Mandatory = $true)][string]$BatchId,
        [Parameter(Mandatory = $true)][string]$LineJobId,
        [Parameter(Mandatory = $true)][string]$ReceiptSha256,
        [Parameter(Mandatory = $true)][string]$EvidenceSha256,
        [bool]$SiblingPending = $false
    )
    $batchPaths = Get-TelephoneBatchPaths -MailboxPaths $MailboxPaths -BatchId $BatchId
    [IO.Directory]::CreateDirectory([string]$batchPaths.root) | Out-Null
    $existing = $null
    if ([IO.File]::Exists([string]$batchPaths.collection)) {
        $existing = (Read-TelephoneJson -Path ([string]$batchPaths.collection)).value
        if ($existing -isnot [Collections.IDictionary]) { throw 'mailbox_collection_invalid' }
    }
    $n = 1
    $counted = 1
    $packageIds = @()
    $missing = @()
    $implicit = $false
    $retryOf = $null
    $protocol = 'telephone-line-batch-collection-v1'
    if ($existing -is [Collections.IDictionary]) {
        if ($existing.Contains('n')) { $n = [int]$existing['n'] }
        if ($existing.Contains('counted')) { $counted = [int]$existing['counted'] }
        if ($existing.Contains('package_ids') -and $null -ne $existing['package_ids']) { $packageIds = @($existing['package_ids']) }
        if ($existing.Contains('missing') -and $null -ne $existing['missing']) { $missing = @($existing['missing']) }
        if ($existing.Contains('implicit')) { $implicit = [bool]$existing['implicit'] }
        if ($existing.Contains('retry_of')) { $retryOf = $existing['retry_of'] }
        if ($existing.Contains('protocol_version')) { $protocol = [string]$existing['protocol_version'] }
    }
    $incomplete = $false
    if ($n -gt $counted) { $incomplete = $true }
    if ($missing.Count -gt 0) { $incomplete = $true }
    if ($SiblingPending) { $incomplete = $true }
    $state = 'lead_consumed'
    if ($incomplete) { $state = 'lead_consumed_pending_siblings' }
    $collection = [ordered]@{}
    if ($existing -is [Collections.IDictionary]) {
        foreach ($key in @($existing.Keys)) { $collection[$key] = $existing[$key] }
    }
    $collection['protocol_version'] = $protocol
    $collection['batch_id'] = $BatchId
    $collection['n'] = $n
    $collection['counted'] = $counted
    $collection['closed'] = (-not $incomplete)
    $collection['acceptance_eligible'] = $false
    $collection['state'] = $state
    $collection['lead_consumed_line_job_id'] = $LineJobId
    $collection['lead_consumed_receipt_sha256'] = $ReceiptSha256
    $collection['lead_consumed_evidence_sha256'] = $EvidenceSha256
    if ($packageIds.Count -gt 0) { $collection['package_ids'] = @($packageIds) }
    $collection['missing'] = @($missing)
    $collection['implicit'] = [bool]$implicit
    $collection['retry_of'] = $retryOf
    $collection['updated_at_utc'] = [DateTimeOffset]::UtcNow.ToString('o')
    $null = Write-TelephoneJsonReplace -Path ([string]$batchPaths.collection) -Value $collection
    return $collection
}

function Assert-TelephoneTrustedMailboxCloseoutIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$JobPaths,
        [Parameter(Mandatory = $true)][object]$Dispatch,
        [Parameter(Mandatory = $true)][string]$LeadSessionId,
        [Parameter(Mandatory = $true)][string]$ReceiptSha256,
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][string]$LeadKey,
        [Parameter(Mandatory = $true)][string]$BatchId,
        [Parameter(Mandatory = $true)][string]$ItemId
    )
    $lead = $null
    if ($Dispatch -is [Collections.IDictionary] -and $Dispatch.Contains('lead')) { $lead = $Dispatch['lead'] }
    elseif ($null -ne $Dispatch.lead) { $lead = $Dispatch.lead }
    if ($null -eq $lead) { throw 'mailbox_lead_binding_missing' }
    $canonical = Get-TelephoneLeadCanonicalIdentity -Lead $lead
    if ([string]$canonical.identity_sha256 -cne $LeadKey) { throw 'mailbox_lead_identity_mismatch' }
    if ([string]$canonical.session_id -cne $LeadSessionId) { throw 'mailbox_lead_session_mismatch' }
    $lineJobId = [string]$Dispatch.line_job_id
    if ([string]::IsNullOrWhiteSpace($lineJobId)) { throw 'mailbox_item_job_mismatch' }
    $itemLead = ''
    $itemBatch = ''
    $itemJob = ''
    $itemOwnId = ''
    if ($Item.Contains('lead_identity_sha256')) { $itemLead = [string]$Item['lead_identity_sha256'] }
    if ($Item.Contains('batch_id')) { $itemBatch = [string]$Item['batch_id'] }
    if ($Item.Contains('line_job_id')) { $itemJob = [string]$Item['line_job_id'] }
    if ($Item.Contains('item_id')) { $itemOwnId = [string]$Item['item_id'] }
    if ([string]::IsNullOrWhiteSpace($itemLead) -or $itemLead -cne $LeadKey) { throw 'mailbox_item_foreign_lead' }
    if ([string]::IsNullOrWhiteSpace($itemBatch) -or $itemBatch -cne $BatchId) { throw 'mailbox_item_batch_mismatch' }
    if ([string]::IsNullOrWhiteSpace($itemJob) -or $itemJob -cne $lineJobId) { throw 'mailbox_item_job_mismatch' }
    $itemReceiptSha = ''
    if ($Item.Contains('receipt') -and $Item['receipt'] -is [Collections.IDictionary] -and $Item['receipt'].Contains('sha256')) {
        $itemReceiptSha = [string]$Item['receipt']['sha256']
    } elseif ($Item.Contains('receipt_sha256')) {
        $itemReceiptSha = [string]$Item['receipt_sha256']
    }
    if ([string]::IsNullOrWhiteSpace($itemReceiptSha) -or $itemReceiptSha -cne $ReceiptSha256) { throw 'mailbox_item_receipt_mismatch' }
    if ([IO.File]::Exists([string]$JobPaths.dispatch)) {
        $dispatchSha = [string](Get-TelephoneFileIdentity -Path ([string]$JobPaths.dispatch)).sha256
        $itemDispatchSha = ''
        if ($Item.Contains('dispatch') -and $Item['dispatch'] -is [Collections.IDictionary] -and $Item['dispatch'].Contains('sha256')) {
            $itemDispatchSha = [string]$Item['dispatch']['sha256']
        } elseif ($Item.Contains('dispatch_sha256')) {
            $itemDispatchSha = [string]$Item['dispatch_sha256']
        }
        if (-not [string]::IsNullOrWhiteSpace($itemDispatchSha) -and $itemDispatchSha -cne $dispatchSha) { throw 'mailbox_item_dispatch_mismatch' }
    }
    $expectedItemId = Get-TelephoneMailboxItemId -LeadKey ([string]$canonical.identity_sha256) -LineJobId $lineJobId -ReceiptSha256 $ReceiptSha256
    if ($ItemId -cne $expectedItemId) { throw 'mailbox_item_id_mismatch' }
    if (-not [string]::IsNullOrWhiteSpace($itemOwnId) -and $itemOwnId -cne $expectedItemId) { throw 'mailbox_item_id_mismatch' }
    return [ordered]@{
        canonical = $canonical
        expected_item_id = $expectedItemId
        line_job_id = $lineJobId
    }
}

function Complete-TelephoneTrustedMailboxCloseout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$JobPaths,
        [Parameter(Mandatory = $true)][object]$Dispatch,
        [Parameter(Mandatory = $true)][string]$LeadSessionId,
        [Parameter(Mandatory = $true)][object]$WakeIdentity,
        [Parameter(Mandatory = $true)][string]$ReceiptSha256,
        [Parameter(Mandatory = $true)][string]$EvidenceSha256
    )
    if (-not [IO.File]::Exists($JobPaths.mailbox_ref)) {
        return [ordered]@{ mailbox_closeout = $false; mailbox_item_updated = $false; mailbox_truth_merged = $false; mailbox_required = $false }
    }
    $ref = (Read-TelephoneJson -Path $JobPaths.mailbox_ref).value
    if ($ref -isnot [Collections.IDictionary]) { throw 'mailbox_ref_invalid' }
    $leadKey = ''
    $batchId = ''
    $itemId = ''
    $statedItemPath = ''
    if ($ref.Contains('lead_identity_sha256')) { $leadKey = [string]$ref['lead_identity_sha256'] }
    if ($ref.Contains('batch_id')) { $batchId = [string]$ref['batch_id'] }
    if ($ref.Contains('item_id')) { $itemId = [string]$ref['item_id'] }
    if ($ref.Contains('item_path')) { $statedItemPath = [string]$ref['item_path'] }
    if ($leadKey -cnotmatch '^[0-9a-f]{64}$') { throw 'mailbox_lead_key_invalid' }
    if ([string]::IsNullOrWhiteSpace($batchId) -or [string]::IsNullOrWhiteSpace($itemId)) { throw 'mailbox_identity_incomplete' }
    $jobRoot = [IO.Path]::GetFullPath([string]$JobPaths.root).TrimEnd('\')
    $stateRoot = Get-TelephoneStateRootFromJobRoot -JobRoot $jobRoot
    if (-not (Test-TelephonePathContainedInRoot -Path $jobRoot -Root $stateRoot)) { throw 'mailbox_job_outside_state_root' }
    $mailbox = Get-TelephoneLeadMailboxPaths -StateRoot $stateRoot -LeadKey $leadKey
    $canonicalItem = [IO.Path]::GetFullPath((Join-Path ([string]$mailbox.mailbox) ($itemId + '.json')))
    if (-not (Test-TelephonePathContainedInRoot -Path $canonicalItem -Root ([string]$mailbox.lead_root))) { throw 'mailbox_item_escaped_lead_root' }
    if (-not [string]::IsNullOrWhiteSpace($statedItemPath)) {
        $statedFull = [IO.Path]::GetFullPath($statedItemPath)
        if (-not (Test-TelephonePathContainedInRoot -Path $statedFull -Root $stateRoot)) { throw 'mailbox_item_outside_state_root' }
        if (-not $statedFull.Equals($canonicalItem, [StringComparison]::OrdinalIgnoreCase)) { throw 'mailbox_item_path_mismatch' }
    }
    $lineJobId = [string]$Dispatch.line_job_id
    $gate = Open-TelephoneExclusiveGate -Path ([string]$mailbox.gate) -WaitMilliseconds 15000
    if ($null -eq $gate) { throw 'mailbox_gate_held' }
    try {
        if (-not [IO.File]::Exists($canonicalItem)) { throw 'mailbox_item_missing' }
        $item = (Read-TelephoneJson -Path $canonicalItem).value
        if ($item -isnot [Collections.IDictionary]) { throw 'mailbox_item_invalid' }
        $existingKind = ''
        if ($item.Contains('delivery_kind')) { $existingKind = [string]$item['delivery_kind'] }
        if ($existingKind -ceq 'AUTOMATIC_WAKE_ACK') { throw 'automatic_mailbox_item' }
        $bound = Assert-TelephoneTrustedMailboxCloseoutIdentity -JobPaths $JobPaths -Dispatch $Dispatch -LeadSessionId $LeadSessionId -ReceiptSha256 $ReceiptSha256 -Item $item -LeadKey $leadKey -BatchId $batchId -ItemId $itemId
        $lineJobId = [string]$bound.line_job_id
        $alreadyTrusted = ($item.Contains('trusted_manual_closeout') -and [bool]$item['trusted_manual_closeout'])
        if ($alreadyTrusted) {
            if ($item.Contains('trusted_receipt_sha256') -and [string]$item['trusted_receipt_sha256'] -cne $ReceiptSha256) { throw 'mailbox_item_receipt_mismatch' }
            if ($item.Contains('trusted_evidence_sha256') -and -not [string]::IsNullOrWhiteSpace([string]$item['trusted_evidence_sha256']) -and [string]$item['trusted_evidence_sha256'] -cne $EvidenceSha256) { throw 'mailbox_item_evidence_mismatch' }
        } else {
            $item['trusted_manual_closeout'] = $true
            $item['trusted_receipt_sha256'] = $ReceiptSha256
            $item['trusted_evidence_sha256'] = $EvidenceSha256
            $item['trusted_closed_at_utc'] = [DateTimeOffset]::UtcNow.ToString('o')
            $null = Write-TelephoneJsonReplace -Path $canonicalItem -Value $item
        }
        $siblingPending = $false
        if ([IO.Directory]::Exists([string]$mailbox.mailbox)) {
            foreach ($siblingPath in @([IO.Directory]::GetFiles([string]$mailbox.mailbox, '*.json'))) {
                $siblingFull = [IO.Path]::GetFullPath($siblingPath)
                if ($siblingFull.Equals($canonicalItem, [StringComparison]::OrdinalIgnoreCase)) { continue }
                try {
                    $sibling = (Read-TelephoneJson -Path $siblingFull).value
                    if ($sibling -isnot [Collections.IDictionary]) { continue }
                    $sibBatch = ''
                    if ($sibling.Contains('batch_id')) { $sibBatch = [string]$sibling['batch_id'] }
                    if ($sibBatch -cne $batchId) { continue }
                    if (-not (Test-TelephoneMailboxItemConsumed -Item $sibling)) { $siblingPending = $true }
                } catch { throw }
            }
        }
        $null = Merge-TelephoneTrustedCollectionConsumption -MailboxPaths $mailbox -BatchId $batchId -LineJobId $lineJobId -ReceiptSha256 $ReceiptSha256 -EvidenceSha256 $EvidenceSha256 -SiblingPending $siblingPending
        $existingRow = $null
        if ([IO.File]::Exists([string]$mailbox.truth)) {
            $truth = (Read-TelephoneJson -Path ([string]$mailbox.truth)).value
            foreach ($row in @($truth.batches)) {
                if ([string]$row.batch_id -ceq $batchId) {
                    $existingRow = $row
                    break
                }
            }
        }
        $merged = [ordered]@{}
        if ($existingRow -is [Collections.IDictionary]) {
            foreach ($key in @($existingRow.Keys)) { $merged[$key] = $existingRow[$key] }
        } elseif ($null -ne $existingRow) {
            foreach ($prop in @($existingRow.PSObject.Properties)) { $merged[$prop.Name] = $prop.Value }
        } else {
            $merged['protocol_version'] = 'telephone-line-mailbox-truth-batch-v1'
            $merged['batch_id'] = $batchId
        }
        $merged['protocol_version'] = 'telephone-line-mailbox-truth-batch-v1'
        $merged['batch_id'] = $batchId
        $merged['trusted_manual_consumed'] = (-not $siblingPending)
        $merged['receipt_sha256'] = $ReceiptSha256
        $merged['evidence_sha256'] = $EvidenceSha256
        $merged['line_job_id'] = $lineJobId
        $merged['closed'] = (-not $siblingPending)
        if ($siblingPending) { $merged['closed'] = $false }
        $merged['recorded_at_utc'] = [DateTimeOffset]::UtcNow.ToString('o')
        Merge-TelephoneMailboxTruthBatch -MailboxPaths $mailbox -BatchRow $merged
        $closeout = [ordered]@{
            protocol_version = 'telephone-line-mailbox-closeout-v1'
            line_job_id = $lineJobId
            lead_session_id = $LeadSessionId
            wake_key = [string]$WakeIdentity.wake_key
            wake_run_id = [string]$WakeIdentity.wake_run_id
            receipt_sha256 = $ReceiptSha256
            evidence_sha256 = $EvidenceSha256
            batch_id = $batchId
            item_id = $itemId
            item_path = $canonicalItem
            siblings_pending = [bool]$siblingPending
            recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $closeoutPath = Join-Path $jobRoot 'mailbox-closeout.json'
        if (-not [IO.File]::Exists($closeoutPath)) {
            $null = Write-TelephoneJsonCreateNew -Path $closeoutPath -Value $closeout
        } else {
            $null = Write-TelephoneJsonReplace -Path $closeoutPath -Value $closeout
        }
        return [ordered]@{
            mailbox_closeout = $true
            mailbox_item_updated = $true
            mailbox_truth_merged = $true
            mailbox_required = $true
            siblings_pending = [bool]$siblingPending
            item_path = $canonicalItem
        }
    } finally {
        $gate.Dispose()
    }
}

function Complete-TelephoneTrustedCloseoutResidue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$JobPaths,
        [Parameter(Mandatory = $true)][object]$Dispatch,
        [Parameter(Mandatory = $true)][string]$LeadSessionId,
        [Parameter(Mandatory = $true)][object]$WakeIdentity,
        [Parameter(Mandatory = $true)][string]$ReceiptSha256,
        [Parameter(Mandatory = $true)][object]$EvidenceIdentity,
        [Parameter(Mandatory = $true)][object]$Record
    )
    $mailbox = Complete-TelephoneTrustedMailboxCloseout -JobPaths $JobPaths -Dispatch $Dispatch -LeadSessionId $LeadSessionId -WakeIdentity $WakeIdentity -ReceiptSha256 $ReceiptSha256 -EvidenceSha256 ([string]$EvidenceIdentity.sha256)
    if ([IO.File]::Exists($JobPaths.mailbox_ref)) {
        if (-not [bool]$mailbox.mailbox_item_updated -or -not [bool]$mailbox.mailbox_truth_merged -or -not [bool]$mailbox.mailbox_closeout) {
            throw 'mailbox_closeout_incomplete'
        }
    }
    if (-not [IO.File]::Exists($JobPaths.trusted_consumption)) {
        $null = Write-TelephoneJsonReplace -Path $JobPaths.trusted_consumption -Value $Record
    }
    $null = Write-TelephoneLifecycleStatus -Paths $JobPaths -Phase 'delivered' -Idle $true
    return $mailbox
}

function Test-TelephoneRelayErrorBlocksWait {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$JobPaths)
    if (-not [IO.File]::Exists($JobPaths.relay_error)) { return $false }
    try {
        $existing = (Read-TelephoneJson -Path $JobPaths.relay_error).value
        if ($existing -is [Collections.IDictionary] -and $existing.Contains('retrying') -and [bool]$existing['retrying']) {
            return $false
        }
        if ($existing -is [Collections.IDictionary] -and [string]$existing.error_code -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT') {
            return $false
        }
    } catch { }
    return $true
}

function Complete-TelephoneTrustedManualConsumption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedReceiptSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedWakeKey,
        [Parameter(Mandatory = $true)][string]$ExpectedLeadSessionId,
        [Parameter(Mandatory = $true)][string]$ConsumptionEvidencePath,
        [Parameter(Mandatory = $true)][string]$ExpectedEvidenceSha256,
        [switch]$Execute
    )
    $paths = Get-TelephoneJobPaths -JobRoot $JobRoot
    $dispatchRead = Read-TelephoneJson -Path $paths.dispatch -SchemaName 'dispatch'
    $dispatch = $dispatchRead.value
    $leadSessionId = [string]$dispatch.lead.session_id
    if ($leadSessionId -cne [string]$ExpectedLeadSessionId) {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'session_mismatch'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
    }
    if (-not [IO.File]::Exists($paths.receipt)) {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'receipt_missing'; delivery_present = $false; automatic = $false }
    }
    $receiptRead = Read-TelephoneJson -Path $paths.receipt -SchemaName 'receipt'
    $actualSha = [string]$receiptRead.identity.sha256
    if ($actualSha -cne ([string]$ExpectedReceiptSha256).ToLowerInvariant()) {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'receipt_sha256_mismatch'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
    }
    $wakeIdentity = New-TelephoneWakeIdentity -LineJobId ([string]$dispatch.line_job_id) -ReceiptIdentity $receiptRead.identity -LeadSessionId $leadSessionId
    if ([string]$wakeIdentity.wake_key -cne ([string]$ExpectedWakeKey).ToLowerInvariant()) {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'wake_key_mismatch'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
    }
    $evidencePath = Assert-TelephoneRegularFilePath -Path $ConsumptionEvidencePath -Label 'Trusted consumption evidence'
    $evidenceIdentity = Get-TelephoneFileIdentity -Path $evidencePath
    if ([string]$evidenceIdentity.sha256 -cne ([string]$ExpectedEvidenceSha256).ToLowerInvariant()) {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'evidence_sha256_mismatch'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
    }
    $evidenceRead = Read-TelephoneJson -Path $evidencePath
    $evidence = $evidenceRead.value
    $kind = ''
    $evidenceSession = ''
    $evidenceWake = ''
    $evidenceReceipt = ''
    $evidenceOriginalRun = ''
    $evidenceConsumingRoot = ''
    $automatic = $false
    if ($evidence -is [Collections.IDictionary]) {
        if ($evidence.Contains('kind')) { $kind = [string]$evidence['kind'] }
        if ($evidence.Contains('lead_session_id')) { $evidenceSession = [string]$evidence['lead_session_id'] }
        if ($evidence.Contains('wake_key')) { $evidenceWake = [string]$evidence['wake_key'] }
        if ($evidence.Contains('automatic_callback_success')) { $automatic = [bool]$evidence['automatic_callback_success'] }
        if ($evidence.Contains('original_wake_run_id')) { $evidenceOriginalRun = [string]$evidence['original_wake_run_id'] }
        if ($evidence.Contains('actual_consuming_run_root')) { $evidenceConsumingRoot = [string]$evidence['actual_consuming_run_root'] }
        if ($evidence.Contains('receipt') -and $evidence['receipt'] -is [Collections.IDictionary] -and $evidence['receipt'].Contains('sha256')) {
            $evidenceReceipt = [string]$evidence['receipt']['sha256']
        }
    }
    if ($automatic) {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'automatic_callback_claim'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
    }
    if ($kind -cnotmatch 'MANUAL' -and $kind -cnotmatch 'EXPLICIT_PASCAL') {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'untrusted_kind'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
    }
    if ($evidenceSession -cne $leadSessionId -or $evidenceWake -cne [string]$wakeIdentity.wake_key -or $evidenceReceipt -cne $actualSha) {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'evidence_binding_mismatch'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
    }
    if ([string]::IsNullOrWhiteSpace($evidenceOriginalRun) -or $evidenceOriginalRun -cne [string]$wakeIdentity.wake_run_id) {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = $(if ([string]::IsNullOrWhiteSpace($evidenceOriginalRun)) { 'original_run_missing' } else { 'original_run_mismatch' }); delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
    }
    if ([string]::IsNullOrWhiteSpace($evidenceConsumingRoot)) {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'consuming_run_missing'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
    }
    $consumeCheck = Test-TelephoneTrustedConsumingRun -ConsumingRoot $evidenceConsumingRoot -ExpectedSessionId $leadSessionId -ForbiddenRunId $evidenceOriginalRun -ExpectedReceiptSha256 $actualSha -ExpectedWakeKey ([string]$wakeIdentity.wake_key)
    if (-not [bool]$consumeCheck.ok) {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = [string]$consumeCheck.reason; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
    }
    if ([string]$consumeCheck.run_id -ceq $evidenceOriginalRun) {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'consuming_run_is_failed_original'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
    }
    if ([IO.File]::Exists($paths.mailbox_ref)) {
        try {
            $previewRef = (Read-TelephoneJson -Path $paths.mailbox_ref).value
            if ($previewRef -is [Collections.IDictionary] -and $previewRef.Contains('item_path') -and -not [string]::IsNullOrWhiteSpace([string]$previewRef['item_path'])) {
                $previewItem = [IO.Path]::GetFullPath([string]$previewRef['item_path'])
                $previewState = Get-TelephoneStateRootFromJobRoot -JobRoot ([string]$paths.root)
                if (-not (Test-TelephonePathContainedInRoot -Path $previewItem -Root $previewState)) {
                    return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'mailbox_item_outside_state_root'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
                }
                $previewKey = ''
                $previewItemId = ''
                if ($previewRef.Contains('lead_identity_sha256')) { $previewKey = [string]$previewRef['lead_identity_sha256'] }
                if ($previewRef.Contains('item_id')) { $previewItemId = [string]$previewRef['item_id'] }
                if ($previewKey -cmatch '^[0-9a-f]{64}$' -and -not [string]::IsNullOrWhiteSpace($previewItemId)) {
                    $previewMailbox = Get-TelephoneLeadMailboxPaths -StateRoot $previewState -LeadKey $previewKey
                    $canonicalPreview = [IO.Path]::GetFullPath((Join-Path ([string]$previewMailbox.mailbox) ($previewItemId + '.json')))
                    if (-not $previewItem.Equals($canonicalPreview, [StringComparison]::OrdinalIgnoreCase)) {
                        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'mailbox_item_path_mismatch'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
                    }
                    if ([IO.File]::Exists($canonicalPreview)) {
                        $previewItemDoc = (Read-TelephoneJson -Path $canonicalPreview).value
                        if ($previewItemDoc -isnot [Collections.IDictionary]) {
                            return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'mailbox_item_invalid'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
                        }
                        try {
                            Assert-TelephoneTrustedMailboxCloseoutIdentity -JobPaths $paths -Dispatch $dispatch -LeadSessionId $leadSessionId -ReceiptSha256 $actualSha -Item $previewItemDoc -LeadKey $previewKey -BatchId ([string]$previewRef['batch_id']) -ItemId $previewItemId | Out-Null
                        } catch {
                            return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = [string]$_.Exception.Message; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
                        }
                    }
                }
            }
        } catch {
            return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'mailbox_destination_invalid'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
        }
    }
    function Test-TelephoneTrustedDeliveryRecord {
        param([AllowNull()][object]$Existing)
        if ($null -eq $Existing -or $Existing -isnot [Collections.IDictionary]) { return $false }
        $existingKind = ''
        if ($Existing.Contains('delivery_kind')) { $existingKind = [string]$Existing['delivery_kind'] }
        if ($existingKind -ceq 'AUTOMATIC_WAKE_ACK' -or [bool]$(if ($Existing.Contains('automatic_callback_success')) { $Existing['automatic_callback_success'] } else { $false })) {
            return $false
        }
        if ($existingKind -cne 'MANUAL_TRUSTED_CONSUMPTION') { return $false }
        $existingSession = ''
        $existingWake = ''
        $existingReceipt = ''
        $existingEvidence = ''
        if ($Existing.Contains('lead_session_id')) { $existingSession = [string]$Existing['lead_session_id'] }
        if ($Existing.Contains('wake_key')) { $existingWake = [string]$Existing['wake_key'] }
        if ($Existing.Contains('receipt_sha256')) { $existingReceipt = [string]$Existing['receipt_sha256'] }
        if ($Existing.Contains('consumption_evidence') -and $Existing['consumption_evidence'] -is [Collections.IDictionary] -and $Existing['consumption_evidence'].Contains('sha256')) {
            $existingEvidence = [string]$Existing['consumption_evidence']['sha256']
        }
        if ($existingSession -cne $leadSessionId) { return $false }
        if ($existingWake -cne [string]$wakeIdentity.wake_key) { return $false }
        if ([string]::IsNullOrWhiteSpace($existingReceipt) -or $existingReceipt -cne $actualSha) { return $false }
        if ([string]::IsNullOrWhiteSpace($existingEvidence) -or $existingEvidence -cne [string]$evidenceIdentity.sha256) { return $false }
        return $true
    }
    function Test-TelephoneTrustedCloseoutComplete {
        $closeoutPath = Join-Path ([string]$paths.root) 'mailbox-closeout.json'
        if (-not [IO.File]::Exists($paths.trusted_consumption) -or -not [IO.File]::Exists($paths.lifecycle_status)) { return $false }
        if (-not [IO.File]::Exists($paths.mailbox_ref)) { return $true }
        if (-not [IO.File]::Exists($closeoutPath)) { return $false }
        try {
            $refDoc = (Read-TelephoneJson -Path $paths.mailbox_ref).value
            if ($refDoc -isnot [Collections.IDictionary]) { return $false }
            $key = ''
            $batch = ''
            $itemId = ''
            if ($refDoc.Contains('lead_identity_sha256')) { $key = [string]$refDoc['lead_identity_sha256'] }
            if ($refDoc.Contains('batch_id')) { $batch = [string]$refDoc['batch_id'] }
            if ($refDoc.Contains('item_id')) { $itemId = [string]$refDoc['item_id'] }
            $state = Get-TelephoneStateRootFromJobRoot -JobRoot ([string]$paths.root)
            $box = Get-TelephoneLeadMailboxPaths -StateRoot $state -LeadKey $key
            $itemPath = [IO.Path]::GetFullPath((Join-Path ([string]$box.mailbox) ($itemId + '.json')))
            if (-not [IO.File]::Exists($itemPath)) { return $false }
            $itemDoc = (Read-TelephoneJson -Path $itemPath).value
            if ($itemDoc -isnot [Collections.IDictionary] -or -not [bool]$itemDoc['trusted_manual_closeout']) { return $false }
            if ([string]$itemDoc['trusted_evidence_sha256'] -cne [string]$evidenceIdentity.sha256) { return $false }
            if ([string]$itemDoc['trusted_receipt_sha256'] -cne $actualSha) { return $false }
            $closeoutDoc = (Read-TelephoneJson -Path $closeoutPath).value
            if ($closeoutDoc -isnot [Collections.IDictionary]) { return $false }
            $closeReceipt = ''
            $closeEvidence = ''
            $closeJob = ''
            if ($closeoutDoc.Contains('receipt_sha256')) { $closeReceipt = [string]$closeoutDoc['receipt_sha256'] }
            if ($closeoutDoc.Contains('evidence_sha256')) { $closeEvidence = [string]$closeoutDoc['evidence_sha256'] }
            if ($closeoutDoc.Contains('line_job_id')) { $closeJob = [string]$closeoutDoc['line_job_id'] }
            if ([string]::IsNullOrWhiteSpace($closeReceipt) -or $closeReceipt -cne $actualSha) { return $false }
            if ([string]::IsNullOrWhiteSpace($closeEvidence) -or $closeEvidence -cne [string]$evidenceIdentity.sha256) { return $false }
            if ([string]::IsNullOrWhiteSpace($closeJob) -or $closeJob -cne [string]$dispatch.line_job_id) { return $false }
            $consDoc = (Read-TelephoneJson -Path $paths.trusted_consumption).value
            if ($consDoc -isnot [Collections.IDictionary]) { return $false }
            $consReceipt = ''
            $consEvidence = ''
            $consJob = ''
            $consWake = ''
            if ($consDoc.Contains('receipt_sha256')) { $consReceipt = [string]$consDoc['receipt_sha256'] }
            if ($consDoc.Contains('line_job_id')) { $consJob = [string]$consDoc['line_job_id'] }
            if ($consDoc.Contains('wake_key')) { $consWake = [string]$consDoc['wake_key'] }
            if ($consDoc.Contains('consumption_evidence') -and $consDoc['consumption_evidence'] -is [Collections.IDictionary] -and $consDoc['consumption_evidence'].Contains('sha256')) {
                $consEvidence = [string]$consDoc['consumption_evidence']['sha256']
            }
            if ([string]::IsNullOrWhiteSpace($consReceipt) -or $consReceipt -cne $actualSha) { return $false }
            if ([string]::IsNullOrWhiteSpace($consEvidence) -or $consEvidence -cne [string]$evidenceIdentity.sha256) { return $false }
            if ([string]::IsNullOrWhiteSpace($consJob) -or $consJob -cne [string]$dispatch.line_job_id) { return $false }
            if ([string]::IsNullOrWhiteSpace($consWake) -or $consWake -cne [string]$wakeIdentity.wake_key) { return $false }
            $lifeDoc = (Read-TelephoneJson -Path $paths.lifecycle_status).value
            if ($lifeDoc -isnot [Collections.IDictionary]) { return $false }
            $lifeJob = ''
            $lifePhase = ''
            if ($lifeDoc.Contains('line_job_id')) { $lifeJob = [string]$lifeDoc['line_job_id'] }
            if ($lifeDoc.Contains('phase')) { $lifePhase = [string]$lifeDoc['phase'] }
            if ([string]::IsNullOrWhiteSpace($lifeJob) -or $lifeJob -cne [string]$dispatch.line_job_id) { return $false }
            if ($lifePhase -cne 'delivered') { return $false }
            if (-not [IO.File]::Exists([string]$box.truth)) { return $false }
            $truthDoc = (Read-TelephoneJson -Path ([string]$box.truth)).value
            $found = $false
            foreach ($row in @($truthDoc.batches)) {
                if ([string]$row.batch_id -cne $batch) { continue }
                $found = $true
                if ([string]$row.evidence_sha256 -cne [string]$evidenceIdentity.sha256) { return $false }
                $rowReceipt = ''
                try { $rowReceipt = [string]$row.receipt_sha256 } catch { $rowReceipt = '' }
                if (-not [string]::IsNullOrWhiteSpace($rowReceipt) -and $rowReceipt -cne $actualSha) { return $false }
            }
            if (-not $found) { return $false }
            $batchPaths = Get-TelephoneBatchPaths -MailboxPaths $box -BatchId $batch
            if (-not [IO.File]::Exists([string]$batchPaths.collection)) { return $false }
            $colDoc = (Read-TelephoneJson -Path ([string]$batchPaths.collection)).value
            if ($colDoc -isnot [Collections.IDictionary]) { return $false }
            if ([string]$colDoc.state -ceq 'awaiting_delivery') { return $false }
            if ($colDoc.Contains('acceptance_eligible') -and [bool]$colDoc['acceptance_eligible']) { return $false }
            $colState = [string]$colDoc.state
            if ($colState -cne 'lead_consumed' -and $colState -cne 'lead_consumed_pending_siblings') { return $false }
            if (-not $colDoc.Contains('lead_consumed_receipt_sha256') -or [string]$colDoc['lead_consumed_receipt_sha256'] -cne $actualSha) { return $false }
            if (-not $colDoc.Contains('lead_consumed_evidence_sha256') -or [string]$colDoc['lead_consumed_evidence_sha256'] -cne [string]$evidenceIdentity.sha256) { return $false }
            if (-not $colDoc.Contains('lead_consumed_line_job_id') -or [string]$colDoc['lead_consumed_line_job_id'] -cne [string]$dispatch.line_job_id) { return $false }
            if (-not [IO.File]::Exists($paths.trusted_consumption)) { return $false }
            try {
                Assert-TelephoneTrustedMailboxCloseoutIdentity -JobPaths $paths -Dispatch $dispatch -LeadSessionId $leadSessionId -ReceiptSha256 $actualSha -Item $itemDoc -LeadKey $key -BatchId $batch -ItemId $itemId | Out-Null
            } catch {
                return $false
            }
            return $true
        } catch {
            return $false
        }
    }
    $record = [ordered]@{
        protocol_version = 'telephone-line-trusted-consumption-v1'
        line_job_id = [string]$dispatch.line_job_id
        lead_session_id = $leadSessionId
        wake_key = [string]$wakeIdentity.wake_key
        wake_run_id = [string]$wakeIdentity.wake_run_id
        receipt_sha256 = $actualSha
        consumption_evidence = $evidenceIdentity
        original_wake_run_id = $evidenceOriginalRun
        actual_consuming_run_root = [string]$consumeCheck.root
        kind = 'MANUAL_TRUSTED_CONSUMPTION'
        automatic_callback_success = $false
        native_wake_ack_created = $false
        old_failure_preserved = [IO.File]::Exists($paths.relay_error)
        executed = [bool]$Execute
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if ([IO.File]::Exists($paths.delivery)) {
        $existing = (Read-TelephoneJson -Path $paths.delivery).value
        if (-not (Test-TelephoneTrustedDeliveryRecord -Existing $existing)) {
            $existingKind = ''
            if ($existing -is [Collections.IDictionary] -and $existing.Contains('delivery_kind')) { $existingKind = [string]$existing['delivery_kind'] }
            $reason = 'delivery_already_present_non_manual'
            if ($existingKind -ceq 'AUTOMATIC_WAKE_ACK') { $reason = 'automatic_delivery_present' }
            elseif ($existing -is [Collections.IDictionary] -and $existingKind -ceq 'MANUAL_TRUSTED_CONSUMPTION') { $reason = 'delivery_identity_incomplete' }
            return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = $reason; delivery_present = $true; automatic = $false }
        }
        if (Test-TelephoneTrustedCloseoutComplete) {
            return [ordered]@{
                ok = $true
                code = 'ALREADY_CLOSED'
                reason = 'idempotent'
                delivery_present = $true
                automatic = $false
                delivery_kind = 'MANUAL_TRUSTED_CONSUMPTION'
            }
        }
        if (-not $Execute) {
            return [ordered]@{
                ok = $true
                code = 'DRY_RUN'
                reason = 'validated_unexecuted_closeout_repair'
                delivery_present = $true
                automatic = $false
                record = $record
            }
        }
        $gateRepair = Open-TelephoneExclusiveGate -Path $paths.delivery_lock -WaitMilliseconds 5000
        if ($null -eq $gateRepair) {
            return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'delivery_lock'; delivery_present = $true; automatic = $false }
        }
        try {
            $mailboxRepair = Complete-TelephoneTrustedCloseoutResidue -JobPaths $paths -Dispatch $dispatch -LeadSessionId $leadSessionId -WakeIdentity $wakeIdentity -ReceiptSha256 $actualSha -EvidenceIdentity $evidenceIdentity -Record $record
            return [ordered]@{
                ok = $true
                code = 'MANUAL_CLOSED'
                reason = 'trusted_closeout_repaired'
                delivery_present = $true
                automatic = $false
                delivery_kind = 'MANUAL_TRUSTED_CONSUMPTION'
                old_failure_preserved = [IO.File]::Exists($paths.relay_error)
                native_wake_ack_created = $false
                mailbox_closeout = [bool]$mailboxRepair.mailbox_closeout
                mailbox_item_updated = [bool]$mailboxRepair.mailbox_item_updated
                mailbox_truth_merged = [bool]$mailboxRepair.mailbox_truth_merged
            }
        } finally {
            $gateRepair.Dispose()
        }
    }
    if (-not $Execute) {
        return [ordered]@{
            ok = $true
            code = 'DRY_RUN'
            reason = 'validated_unexecuted'
            delivery_present = $false
            automatic = $false
            record = $record
        }
    }
    $delivery = [ordered]@{
        protocol_version = 'telephone-line-delivery-v1'
        line_job_id = [string]$dispatch.line_job_id
        lead_session_id = $leadSessionId
        wake_run_id = [string]$wakeIdentity.wake_run_id
        wake_key = [string]$wakeIdentity.wake_key
        receipt_sha256 = $actualSha
        lead_run_root = [string]$consumeCheck.root
        launcher_state = 'manual_trusted_consumption'
        delivery_kind = 'MANUAL_TRUSTED_CONSUMPTION'
        automatic_callback_success = $false
        native_wake_ack_created = $false
        consumption_evidence = $evidenceIdentity
        delivered_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $delivery = Add-TelephoneControlPlaneDeliveryBinding -Delivery $delivery -Dispatch $dispatch -JobPaths $paths
    $gate = Open-TelephoneExclusiveGate -Path $paths.delivery_lock -WaitMilliseconds 5000
    if ($null -eq $gate) {
        return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'delivery_lock'; delivery_present = [IO.File]::Exists($paths.delivery); automatic = $false }
    }
    $mailboxCloseout = $false
    $mailboxItemUpdated = $false
    $mailboxTruthMerged = $false
    try {
        if ([IO.File]::Exists($paths.delivery)) {
            $existing = (Read-TelephoneJson -Path $paths.delivery).value
            if (-not (Test-TelephoneTrustedDeliveryRecord -Existing $existing)) {
                return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'delivery_already_present_non_manual'; delivery_present = $true; automatic = $false }
            }
            if (Test-TelephoneTrustedCloseoutComplete) {
                return [ordered]@{ ok = $true; code = 'ALREADY_CLOSED'; reason = 'idempotent'; delivery_present = $true; automatic = $false; delivery_kind = 'MANUAL_TRUSTED_CONSUMPTION' }
            }
            $mailboxRepair = Complete-TelephoneTrustedCloseoutResidue -JobPaths $paths -Dispatch $dispatch -LeadSessionId $leadSessionId -WakeIdentity $wakeIdentity -ReceiptSha256 $actualSha -EvidenceIdentity $evidenceIdentity -Record $record
            return [ordered]@{
                ok = $true
                code = 'MANUAL_CLOSED'
                reason = 'trusted_closeout_repaired'
                delivery_present = $true
                automatic = $false
                delivery_kind = 'MANUAL_TRUSTED_CONSUMPTION'
                old_failure_preserved = [IO.File]::Exists($paths.relay_error)
                native_wake_ack_created = $false
                mailbox_closeout = [bool]$mailboxRepair.mailbox_closeout
            }
        }
        try { $null = Write-TelephoneJsonCreateNew -Path $paths.delivery -Value $delivery } catch [IO.IOException] { }
        if (-not [IO.File]::Exists($paths.delivery)) {
            return [ordered]@{ ok = $false; code = 'TRUSTED_CONSUMPTION_REJECTED'; reason = 'delivery_write_failed'; delivery_present = $false; automatic = $false }
        }
        $mailbox = Complete-TelephoneTrustedCloseoutResidue -JobPaths $paths -Dispatch $dispatch -LeadSessionId $leadSessionId -WakeIdentity $wakeIdentity -ReceiptSha256 $actualSha -EvidenceIdentity $evidenceIdentity -Record $record
        $mailboxCloseout = [bool]$mailbox.mailbox_closeout
        $mailboxItemUpdated = [bool]$mailbox.mailbox_item_updated
        $mailboxTruthMerged = [bool]$mailbox.mailbox_truth_merged
    } finally {
        $gate.Dispose()
    }
    return [ordered]@{
        ok = $true
        code = 'MANUAL_CLOSED'
        reason = 'trusted_manual_consumption'
        delivery_present = $true
        automatic = $false
        delivery_kind = 'MANUAL_TRUSTED_CONSUMPTION'
        old_failure_preserved = [IO.File]::Exists($paths.relay_error)
        native_wake_ack_created = $false
        mailbox_closeout = [bool]$mailboxCloseout
        mailbox_item_updated = [bool]$mailboxItemUpdated
        mailbox_truth_merged = [bool]$mailboxTruthMerged
    }
}

function Complete-TelephoneOwnerJobDelivery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$JobPaths,
        [Parameter(Mandatory = $true)][object]$Dispatch,
        [Parameter(Mandatory = $true)][object]$Launch,
        [Parameter(Mandatory = $true)][object]$WakeIdentity,
        [Parameter(Mandatory = $true)][string]$LeadSessionId
    )
    $attemptRunId = ''
    if ($Launch -is [Collections.IDictionary] -and $Launch.Contains('wake_run_id')) {
        $attemptRunId = [string]$Launch['wake_run_id']
    } elseif ($null -ne $Launch.PSObject.Properties['wake_run_id']) {
        $attemptRunId = [string]$Launch.wake_run_id
    }
    if ([string]::IsNullOrWhiteSpace($attemptRunId) -and -not [string]::IsNullOrWhiteSpace([string]$Launch.run_root)) {
        $attemptRunId = [IO.Path]::GetFileName([IO.Path]::GetFullPath([string]$Launch.run_root).TrimEnd('\'))
    }
    $wakeAcknowledgment = Wait-TelephoneLeadWakeAcknowledged -RunRoot ([string]$Launch.run_root) -ExpectedSessionId $LeadSessionId -ExpectedRunId $attemptRunId -ExpectedWakeKey ([string]$WakeIdentity.wake_key) -ExpectedReceiptSha256 $(if ([IO.File]::Exists($JobPaths.receipt)) { [string](Get-TelephoneFileIdentity -Path $JobPaths.receipt).sha256 } else { '' })
    $drainTerminal = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Launch.run_root)) {
        $drainTerminal = Wait-TelephoneLeadOwnedDrainTerminal -RunRoot ([string]$Launch.run_root) -WaitMilliseconds 1500
    }
    $delivery = [ordered]@{
        protocol_version = 'telephone-line-delivery-v1'
        line_job_id = [string]$Dispatch.line_job_id
        lead_session_id = $LeadSessionId
        wake_run_id = [string]$WakeIdentity.wake_run_id
        attempt_run_id = [string]$attemptRunId
        wake_key = [string]$WakeIdentity.wake_key
        lead_run_root = [string]$Launch.run_root
        launcher_state = [string]$Launch.state
        delivery_kind = 'AUTOMATIC_WAKE_ACK'
        automatic_callback_success = $true
        wake_acknowledgment = $wakeAcknowledgment
        owned_drain_terminal = $drainTerminal
        owned_drain_pending = [bool]$(if ($null -ne $drainTerminal -and $drainTerminal.Contains('pending')) { $drainTerminal['pending'] } else { $true })
        delivered_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $delivery=Add-TelephoneControlPlaneDeliveryBinding -Delivery $delivery -Dispatch $Dispatch -JobPaths $JobPaths
    if ([IO.File]::Exists($JobPaths.nested_terminal)) {
        $nestedDone = (Read-TelephoneJson -Path $JobPaths.nested_terminal).value
        $delivery['nested_terminal'] = [ordered]@{
            session_id = [string]$nestedDone.session_id
            state = [string]$nestedDone.state
            wake_run_id = [string]$nestedDone.wake_run_id
        }
    }
    try { $null = Write-TelephoneJsonCreateNew -Path $JobPaths.delivery -Value $delivery } catch [IO.IOException] { }
    if (-not [IO.File]::Exists($JobPaths.delivery)) { throw 'LEAD_DELIVERY_WRITE_FAILED' }
    $null = Write-TelephoneLifecycleStatus -Paths $JobPaths -Phase 'delivered' -Idle $false
}

function Invoke-TelephoneSingleJobWake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][object]$ReceiptRead,
        [object]$MailboxPaths = $null
    )
    $crashMailbox = Resolve-TelephoneCollectorCrashMailboxPaths -MailboxPaths $MailboxPaths -Job $Job
    $paths = $Job.paths
    $dispatch = $Job.dispatch
    $lead = $Job.lead
    $leadSessionId = [string]$lead.session_id
    if ([IO.File]::Exists($paths.delivery)) { return }
    $null = Invoke-TelephoneLeadSessionResidueReconcile -Lead $lead -MailboxPaths $MailboxPaths -JobPaths $paths
    $receiptIdentity = $ReceiptRead.identity
    $receipt = $ReceiptRead.value
    $wakeIdentity = New-TelephoneWakeIdentity -LineJobId ([string]$dispatch.line_job_id) -ReceiptIdentity $receiptIdentity -LeadSessionId $leadSessionId
    $wakeRunId = [string]$wakeIdentity.wake_run_id
    $nestedDone = $null
    if ([IO.File]::Exists($paths.nested_terminal)) {
        $nestedDone = (Read-TelephoneJson -Path $paths.nested_terminal).value
    }
    $wakeText = New-TelephoneOwnerWakePromptText -Dispatch $dispatch -Receipt $receipt -ReceiptIdentity $receiptIdentity -NestedTerminal $nestedDone -WakeKey ([string]$wakeIdentity.wake_key)
    if (-not [IO.File]::Exists($paths.wake_prompt)) {
        try { $null = Write-TelephoneTextCreateNew -Path $paths.wake_prompt -Text $wakeText } catch [IO.IOException] { }
    }
    $wakePromptIdentity = Get-TelephoneFileIdentity -Path $paths.wake_prompt
    $claim = [ordered]@{
        protocol_version = 'telephone-line-delivery-claim-v1'
        line_job_id = [string]$dispatch.line_job_id
        lead_session_id = $leadSessionId
        lead_worktree = [string]$lead.worktree
        wake_run_id = $wakeRunId
        wake_key = [string]$wakeIdentity.wake_key
        wake_prompt = $wakePromptIdentity
        claimed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if (-not [IO.File]::Exists($paths.delivery_claim)) {
        try { $null = Write-TelephoneJsonCreateNew -Path $paths.delivery_claim -Value $claim } catch [IO.IOException] { }
    }
    $intent = [ordered]@{
        protocol_version = 'telephone-line-wake-intent-v1'
        line_job_id = [string]$dispatch.line_job_id
        lead_session_id = $leadSessionId
        wake_run_id = $wakeRunId
        wake_key = [string]$wakeIdentity.wake_key
        receipt = $receiptIdentity
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if (-not [IO.File]::Exists($paths.wake_intent)) {
        try { $null = Write-TelephoneJsonCreateNew -Path $paths.wake_intent -Value $intent } catch [IO.IOException] { }
    }
    $frozenIntent = (Read-TelephoneJson -Path $paths.wake_intent).value
    if ([string]$frozenIntent.wake_run_id -cne $wakeRunId -or [string]$frozenIntent.wake_key -cne [string]$wakeIdentity.wake_key) {
        throw 'Frozen wake identity does not match this receipt.'
    }
    $ownerExtra = @($lead.launcher.arguments)
    $attemptCreated = $false
    if (-not [IO.File]::Exists($paths.wake_attempt)) {
        $attempt = [ordered]@{
            protocol_version = 'telephone-line-wake-attempt-v1'
            line_job_id = [string]$dispatch.line_job_id
            lead_session_id = $leadSessionId
            wake_run_id = $wakeRunId
            wake_key = [string]$wakeIdentity.wake_key
            receipt = $receiptIdentity
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        try {
            $null = Write-TelephoneJsonCreateNew -Path $paths.wake_attempt -Value $attempt
            $attemptCreated = $true
        } catch [IO.IOException] { }
    }
    $launch = $null
    try {
        if ($attemptCreated) {
            Test-TelephoneCollectorCrashAfter -Point 'send' -MailboxPaths $crashMailbox
            $launch = Invoke-TelephoneFrozenLeadLauncher -LauncherPath ([string]$lead.launcher.path) -ExtraArguments $ownerExtra -Worktree ([string]$lead.worktree) -PromptFile ([string]$paths.wake_prompt) -SessionId $leadSessionId -RunId $wakeRunId
            $saved = Save-TelephoneNamedLaunchResult -Path $paths.wake_launch_result -Launch $launch -RunId $wakeRunId -WakeKey ([string]$wakeIdentity.wake_key) -LineJobId ([string]$dispatch.line_job_id)
            if ($null -ne $saved) { $launch = $saved }
        } else {
            $launch = Invoke-TelephoneNamedWakeAttach -LaunchResultPath $paths.wake_launch_result -LauncherPath ([string]$lead.launcher.path) -ExtraArguments $ownerExtra -Worktree ([string]$lead.worktree) -PromptFile ([string]$paths.wake_prompt) -SessionId $leadSessionId -RunId $wakeRunId -WakeKey ([string]$wakeIdentity.wake_key) -LineJobId ([string]$dispatch.line_job_id)
        }
        Test-TelephoneCollectorCrashAfter -Point 'ack' -MailboxPaths $crashMailbox
        Complete-TelephoneOwnerJobDelivery -JobPaths $paths -Dispatch $dispatch -Launch $launch -WakeIdentity $wakeIdentity -LeadSessionId $leadSessionId
        Test-TelephoneCollectorCrashAfter -Point 'delivery' -MailboxPaths $crashMailbox
    } catch {
        $msg = [string]$_.Exception.Message
        $diag = Get-TelephoneLastLeadLaunchDiagnostic
        if ($null -eq $diag) {
            $diag = New-TelephoneLeadLaunchDiagnostic -Code $(if ([string]::IsNullOrWhiteSpace($msg)) { 'LEAD_WAKE_FAILED' } else { $msg }) -RunId $wakeRunId -SessionId $leadSessionId
        }
        try { $null = Write-TelephoneJsonReplace -Path $paths.launch_failure -Value $diag } catch { }
        if ($msg -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT' -or [string]$diag.error_code -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT') {
            Write-TelephoneLeadRetryingRelayError -JobPaths $paths -LineJobId ([string]$dispatch.line_job_id) -LeadSessionId $leadSessionId -ErrorCode 'LEAD_WAKE_PRE_TURN_CONFLICT' -Diagnostic $diag
            return
        }
        throw
    }
}

function Invoke-TelephoneClosedBatchWake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$MailboxPaths,
        [Parameter(Mandatory = $true)][object]$BatchPaths,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$Lead,
        [Parameter(Mandatory = $true)][object]$JobsByPackage
    )
    $leadSessionId = [string]$Lead.session_id
    $n = [int]$Manifest.n
    $implicit = [bool]$Manifest.implicit
    $null = Invoke-TelephoneLeadSessionResidueReconcile -Lead $Lead -MailboxPaths $MailboxPaths
    if ($n -eq 1) {
        $item = @($Manifest.items)[0]
        $job = $JobsByPackage[[string]$item.package_id]
        if ($null -eq $job) { throw 'Closed batch job is missing.' }
        $receiptRead = Read-TelephoneJson -Path $job.paths.receipt -SchemaName 'receipt'
        Invoke-TelephoneSingleJobWake -Job $job -ReceiptRead $receiptRead -MailboxPaths $MailboxPaths
        return
    }
    $wakeRunId = [string]$Manifest.wake_run_id
    $wakeKey = [string]$Manifest.wake_key
    $wakeIdentity = [ordered]@{ wake_run_id = $wakeRunId; wake_key = $wakeKey }
    if (-not [IO.File]::Exists($BatchPaths.wake_prompt)) {
        $text = New-TelephoneBatchWakePromptText -Manifest $Manifest -Lead $Lead
        try { $null = Write-TelephoneTextCreateNew -Path $BatchPaths.wake_prompt -Text $text } catch [IO.IOException] { }
    }
    $promptIdentity = Get-TelephoneFileIdentity -Path $BatchPaths.wake_prompt
    if (-not [IO.File]::Exists($BatchPaths.wake_intent)) {
        $intent = [ordered]@{
            protocol_version = 'telephone-line-wake-intent-v1'
            line_job_id = [string]$Manifest.batch_id
            lead_session_id = $leadSessionId
            wake_run_id = $wakeRunId
            wake_key = $wakeKey
            batch_id = [string]$Manifest.batch_id
            wake_prompt = $promptIdentity
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        try { $null = Write-TelephoneJsonCreateNew -Path $BatchPaths.wake_intent -Value $intent } catch [IO.IOException] { }
    }
    $attemptCreated = $false
    if (-not [IO.File]::Exists($BatchPaths.wake_attempt)) {
        $attempt = [ordered]@{
            protocol_version = 'telephone-line-wake-attempt-v1'
            line_job_id = [string]$Manifest.batch_id
            lead_session_id = $leadSessionId
            wake_run_id = $wakeRunId
            wake_key = $wakeKey
            batch_id = [string]$Manifest.batch_id
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        try {
            $null = Write-TelephoneJsonCreateNew -Path $BatchPaths.wake_attempt -Value $attempt
            $attemptCreated = $true
        } catch [IO.IOException] { }
    }
    $extra = @($Lead.launcher.arguments)
    $launch = $null
    if ($attemptCreated) {
        Test-TelephoneCollectorCrashAfter -Point 'send' -MailboxPaths $MailboxPaths
        $launch = Invoke-TelephoneFrozenLeadLauncher -LauncherPath ([string]$Lead.launcher.path) -ExtraArguments $extra -Worktree ([string]$Lead.worktree) -PromptFile ([string]$BatchPaths.wake_prompt) -SessionId $leadSessionId -RunId $wakeRunId
        $saved = Save-TelephoneNamedLaunchResult -Path $BatchPaths.wake_launch_result -Launch $launch -RunId $wakeRunId -WakeKey $wakeKey -LineJobId ([string]$Manifest.batch_id)
        if ($null -ne $saved) { $launch = $saved }
    } else {
        $launch = Invoke-TelephoneNamedWakeAttach -LaunchResultPath $BatchPaths.wake_launch_result -LauncherPath ([string]$Lead.launcher.path) -ExtraArguments $extra -Worktree ([string]$Lead.worktree) -PromptFile ([string]$BatchPaths.wake_prompt) -SessionId $leadSessionId -RunId $wakeRunId -WakeKey $wakeKey -LineJobId ([string]$Manifest.batch_id)
    }
    Test-TelephoneCollectorCrashAfter -Point 'ack' -MailboxPaths $MailboxPaths
    $wakeAcknowledgment = Wait-TelephoneLeadWakeAcknowledged -RunRoot ([string]$Launch.run_root) -ExpectedSessionId $leadSessionId -ExpectedRunId $wakeRunId
    foreach ($item in @($Manifest.items)) {
        $job = $JobsByPackage[[string]$item.package_id]
        if ($null -eq $job) { continue }
        if ([IO.File]::Exists($job.paths.delivery)) { continue }
        $claim = [ordered]@{
            protocol_version = 'telephone-line-delivery-claim-v1'
            line_job_id = [string]$item.line_job_id
            lead_session_id = $leadSessionId
            lead_worktree = [string]$Lead.worktree
            wake_run_id = $wakeRunId
            wake_key = $wakeKey
            wake_prompt = $promptIdentity
            claimed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        if (-not [IO.File]::Exists($job.paths.delivery_claim)) {
            try { $null = Write-TelephoneJsonCreateNew -Path $job.paths.delivery_claim -Value $claim } catch [IO.IOException] { }
        }
        $delivery = [ordered]@{
            protocol_version = 'telephone-line-delivery-v1'
            line_job_id = [string]$item.line_job_id
            lead_session_id = $leadSessionId
            wake_run_id = $wakeRunId
            wake_key = $wakeKey
            lead_run_root = [string]$Launch.run_root
            launcher_state = [string]$Launch.state
            wake_acknowledgment = $wakeAcknowledgment
            batch_id = [string]$Manifest.batch_id
            delivered_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $delivery=Add-TelephoneControlPlaneDeliveryBinding -Delivery $delivery -Dispatch $job.dispatch -JobPaths $job.paths
        $null = Write-TelephoneLifecycleStatus -Paths $job.paths -Phase 'delivered' -Idle $false
        try { $null = Write-TelephoneJsonCreateNew -Path $job.paths.delivery -Value $delivery } catch [IO.IOException] { }
    }
    Test-TelephoneCollectorCrashAfter -Point 'delivery' -MailboxPaths $MailboxPaths
}

function New-TelephoneCollectorFailedAmbiguousResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$BatchPaths,
        [AllowNull()][object]$Batch = $null
    )
    $n = 0
    if ($null -ne $Batch -and $Batch -is [Collections.IDictionary] -and $Batch.Contains('n') -and $null -ne $Batch.n) {
        try { $n = [int]$Batch.n } catch { $n = 0 }
    }
    return [ordered]@{
        state = 'failed_ambiguous'
        closed = $false
        counted = 0
        n = $n
        missing = @()
        collection = $null
        manifest = $null
        batch_paths = $BatchPaths
        jobs_by_package = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        counted_items = @()
        frozen_identity = $null
    }
}

function Get-TelephoneCollectorUpdateInt {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Update,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Update -or $Update -isnot [Collections.IDictionary] -or -not $Update.Contains($Name) -or $null -eq $Update[$Name]) { return 0 }
    try { return [int]$Update[$Name] } catch { return 0 }
}

function Get-TelephoneCollectorUpdateMissing {
    [CmdletBinding()]
    param([AllowNull()][object]$Update)
    if ($null -eq $Update -or $Update -isnot [Collections.IDictionary] -or -not $Update.Contains('missing') -or $null -eq $Update.missing) {
        return @()
    }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($row in @($Update.missing)) {
        if ($null -eq $row) { continue }
        $rows.Add($row)
    }
    return @($rows)
}

function Update-TelephoneLeadBatchCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$MailboxPaths,
        [Parameter(Mandatory = $true)][object]$Batch,
        [Parameter(Mandatory = $true)][object]$Jobs,
        [Parameter(Mandatory = $true)][object]$Items,
        [object]$AllJobs = $null
    )
    $batchId = [string]$Batch.batch_id
    $batchPaths = Get-TelephoneBatchPaths -MailboxPaths $MailboxPaths -BatchId $batchId
    [IO.Directory]::CreateDirectory([string]$batchPaths.root) | Out-Null
    if ([IO.File]::Exists($batchPaths.fail_closed) -or [IO.File]::Exists($MailboxPaths.fail_closed)) {
        return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
    }
    $n = [int]$Batch.n
    $packageIds = @($Batch.package_ids)
    $scanJobs = @($AllJobs)
    if ($null -eq $AllJobs) { $scanJobs = @($Jobs) }
    foreach ($foreign in $scanJobs) {
        if ([string]$foreign.batch.batch_id -cne $batchId) { continue }
        if ([string]$foreign.canonical.identity_sha256 -cne [string]$MailboxPaths.lead_key) {
            Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$foreign.canonical.session_id)
            return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
        }
    }
    $jobsForBatch = @($Jobs | Where-Object { [string]$_.batch.batch_id -ceq $batchId })
    $frozenIdentity = $null
    foreach ($job in $jobsForBatch) {
        $jobIdentity = $job.identity
        if ($null -eq $jobIdentity) {
            $jobIdentity = ConvertTo-TelephoneComparableLeadIdentity -Canonical $job.canonical -Profile $job.profile
        }
        if (-not (Test-TelephoneComparableLeadIdentityWellFormed -Identity $jobIdentity) -or [string]$jobIdentity.identity_sha256 -cne [string]$MailboxPaths.lead_key) {
            Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$job.canonical.session_id)
            return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
        }
        if ($null -eq $frozenIdentity) { $frozenIdentity = $jobIdentity }
        elseif (-not (Test-TelephoneComparableLeadIdentityEqual -Left $frozenIdentity -Right $jobIdentity)) {
            Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$job.canonical.session_id)
            return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
        }
        if ([int]$job.batch.n -ne $n) {
            Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$job.canonical.session_id)
            return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
        }
        $left = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($packageId in @($job.batch.package_ids)) { [void]$left.Add([string]$packageId) }
        $right = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($packageId in $packageIds) { [void]$right.Add([string]$packageId) }
        if ($left.Count -ne $right.Count -or $left.Count -ne @($job.batch.package_ids).Count) {
            Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$job.canonical.session_id)
            return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
        }
        foreach ($packageId in $packageIds) {
            if (-not $left.Contains([string]$packageId)) {
                Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$job.canonical.session_id)
                return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
            }
        }
    }
    $packageJobCount = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($job in $jobsForBatch) {
        $packageId = [string]$job.batch.package_id
        if ($packageJobCount.ContainsKey($packageId)) {
            Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$job.canonical.session_id)
            return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
        }
        $packageJobCount[$packageId] = $job
    }
    foreach ($job in $jobsForBatch) {
        if (-not [IO.File]::Exists($job.paths.receipt)) { continue }
        try {
            $receipt = (Read-TelephoneJson -Path $job.paths.receipt -SchemaName 'receipt').value
            $classification = Get-TelephoneReceiptClassification -Paths $job.paths -Receipt $receipt
            if ($classification -ceq 'start_ambiguous' -or $classification -ceq 'start_failed_unqualified') {
                Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$job.canonical.session_id)
                return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
            }
        } catch {
            Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$job.canonical.session_id)
            return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
        }
        if ([IO.File]::Exists($job.paths.delivery)) {
            try {
                $delivery = (Read-TelephoneJson -Path $job.paths.delivery).value
                $ack = $null
                if ($delivery -is [Collections.IDictionary] -and $delivery.Contains('wake_acknowledgment')) { $ack = $delivery.wake_acknowledgment }
                if ($null -eq $ack) {
                    Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'LEAD_WAKE_AMBIGUOUS' -LeadSessionId ([string]$job.canonical.session_id)
                    return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
                }
            } catch {
                Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'LEAD_WAKE_AMBIGUOUS' -LeadSessionId ([string]$job.canonical.session_id)
                return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
            }
        }
    }
    $countedItems = [Collections.Generic.List[object]]::new()
    $seenPackage = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenReceipt = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in @($Items | Where-Object { [string]$_.batch_id -ceq $batchId })) {
        if ([int]$item.n -ne $n) {
            Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$item.lead_session_id)
            return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
        }
        $itemIdentity = ConvertTo-TelephoneComparableLeadIdentityFromItem -Item $item
        if (-not (Test-TelephoneComparableLeadIdentityWellFormed -Identity $itemIdentity) -or [string]$itemIdentity.identity_sha256 -cne [string]$MailboxPaths.lead_key) {
            Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$item.lead_session_id)
            return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
        }
        if ($null -eq $frozenIdentity) { $frozenIdentity = $itemIdentity }
        elseif (-not (Test-TelephoneComparableLeadIdentityEqual -Left $frozenIdentity -Right $itemIdentity)) {
            Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$item.lead_session_id)
            return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
        }
        if (-not $seenPackage.Add([string]$item.package_id)) {
            Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$item.lead_session_id)
            return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
        }
        if (-not $seenReceipt.Add([string]$item.receipt.sha256)) {
            Write-TelephoneMailboxFailClosed -Path $batchPaths.fail_closed -BatchId $batchId -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId ([string]$item.lead_session_id)
            return (New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPaths -Batch $Batch)
        }
        $countedItems.Add($item)
    }
    $countedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $countedItems) { [void]$countedIds.Add([string]$item.package_id) }
    $missing = [Collections.Generic.List[object]]::new()
    foreach ($packageId in $packageIds) {
        if ($countedIds.Contains([string]$packageId)) { continue }
        $job = $null
        if ($packageJobCount.ContainsKey([string]$packageId)) { $job = $packageJobCount[[string]$packageId] }
        $missing.Add((New-TelephoneBatchMissingOwnership -PackageId ([string]$packageId) -Job $job))
    }
    $counted = $countedItems.Count
    $closed = ($counted -eq $n)
    $state = 'collecting'
    $allDelivered = $false
    if ($closed) {
        $allDelivered = $true
        foreach ($item in $countedItems) {
            $job = $null
            if ($packageJobCount.ContainsKey([string]$item.package_id)) { $job = $packageJobCount[[string]$item.package_id] }
            if ($null -eq $job -or -not [IO.File]::Exists($job.paths.delivery)) { $allDelivered = $false; break }
        }
        if ($allDelivered) { $state = 'delivered' }
        else { $state = 'closed_queued_behind_busy' }
        if ([IO.File]::Exists($batchPaths.wake_launch_result) -and -not $allDelivered) { $state = 'callback_active' }
    }
    $collection = [ordered]@{
        protocol_version = 'telephone-line-batch-collection-v1'
        batch_id = $batchId
        n = $n
        counted = $counted
        closed = $closed
        acceptance_eligible = $closed
        state = $state
        package_ids = @($packageIds)
        counted_package_ids = @($countedItems | ForEach-Object { [string]$_.package_id })
        missing = @($missing)
        retry_of = $Batch.retry_of
        implicit = [bool]$Batch.implicit
        updated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $null = Merge-TelephoneMailboxTruthBatch -MailboxPaths $MailboxPaths -BatchRow (Convert-TelephoneCollectionToObservationalBatch -LeadKey ([string]$MailboxPaths.lead_key) -Collection $collection)
    $null = Write-TelephoneJsonReplace -Path $batchPaths.collection -Value $collection
    Test-TelephoneCollectorCrashAfter -Point 'collection' -MailboxPaths $MailboxPaths
    $manifest = $null
    if ($closed -and -not [IO.File]::Exists($batchPaths.manifest)) {
        $fifo = @($countedItems | Sort-Object { [int]$_.sequence }, { [string]$_.created_at_utc }, { [string]$_.item_id })
        $manifestItems = [Collections.Generic.List[object]]::new()
        foreach ($item in $fifo) {
            $itemIdentity = ConvertTo-TelephoneComparableLeadIdentityFromItem -Item $item
            $profileRecord = $null
            if ($null -ne $itemIdentity.profile) { $profileRecord = $itemIdentity.profile }
            $manifestItems.Add([ordered]@{
                package_id = [string]$item.package_id
                line_job_id = [string]$item.line_job_id
                sequence = [int]$item.sequence
                classification = [string]$item.classification
                lead_session_id = [string]$itemIdentity.session_id
                lead_worktree = [string]$itemIdentity.worktree
                lead_launcher_path = [string]$itemIdentity.launcher_path
                lead_identity_sha256 = [string]$itemIdentity.identity_sha256
                profile = $profileRecord
                dispatch = $item.dispatch
                receipt = $item.receipt
            })
        }
        $leadSession = [string]$frozenIdentity.session_id
        $leadWorktree = [string]$frozenIdentity.worktree
        $leadKey = [string]$frozenIdentity.identity_sha256
        $seed = $leadKey + '|' + $batchId
        $wakeRunId = if ($n -eq 1 -or [bool]$Batch.implicit) {
            'telephone-' + [string]$fifo[0].line_job_id
        } else {
            'telephone-batch-' + $batchId
        }
        $draft = [ordered]@{
            protocol_version = 'telephone-line-batch-v1'
            batch_id = $batchId
            lead_session_id = $leadSession
            lead_worktree = $leadWorktree
            lead_identity_sha256 = $leadKey
            n = $n
            counted = $counted
            closed = $true
            acceptance_eligible = $true
            package_ids = @($packageIds)
            items = @($manifestItems)
            wake_run_id = $wakeRunId
            wake_key = ('0' * 64)
            retry_of = $Batch.retry_of
            implicit = [bool]$Batch.implicit
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $draftJson = ($draft | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n"
        $wakeKey = Get-TelephoneUtf8Sha256 -Text ($seed + '|' + $wakeRunId + '|' + $draftJson)
        $draft.wake_key = $wakeKey
        $null = Write-TelephoneJsonCreateNew -Path $batchPaths.manifest -Value $draft
        $null = Read-TelephoneJson -Path $batchPaths.manifest -SchemaName 'telephone-line-batch'
        Test-TelephoneCollectorCrashAfter -Point 'manifest' -MailboxPaths $MailboxPaths
    }
    if ([IO.File]::Exists($batchPaths.manifest)) {
        $manifest = (Read-TelephoneJson -Path $batchPaths.manifest -SchemaName 'telephone-line-batch').value
    }
    return [ordered]@{
        state = $state
        closed = $closed
        counted = $counted
        n = $n
        missing = @($missing)
        collection = $collection
        manifest = $manifest
        batch_paths = $batchPaths
        jobs_by_package = $packageJobCount
        counted_items = @($countedItems)
        frozen_identity = $frozenIdentity
    }
}

function Invoke-TelephoneLeadSessionResidueReconcile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Lead,
        [AllowNull()][object]$MailboxPaths = $null,
        [AllowNull()][object]$JobPaths = $null
    )
    $sessionId = ''
    try { $sessionId = [string]$Lead.session_id } catch { $sessionId = '' }
    $record = [ordered]@{
        protocol_version = 'telephone-line-session-residue-reconcile-v1'
        session_id = $sessionId
        lead_state_root = ''
        scanned = 0
        recovered = 0
        skipped_foreign = 0
        skipped_active = 0
        refused = @()
        pending = @()
        recovered_runs = @()
        provider_replayed = $false
        source = 'collector_or_wake'
        error = ''
        persist_paths = [Collections.Generic.List[string]]::new()
        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        $record.error = 'missing_session'
        return $record
    }
    $stateHint = ''
    try {
        $args = @()
        if ($null -ne $Lead.launcher -and $null -ne $Lead.launcher.arguments) {
            $args = @($Lead.launcher.arguments)
        }
        $stateHint = Get-TelephoneLeadNamedArgumentValue -Arguments $args -Name 'StateRootOverride'
    } catch { $stateHint = '' }
    if ([string]::IsNullOrWhiteSpace($stateHint) -and -not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_LINE_LEAD_STATE_ROOT)) {
        $stateHint = [string]$env:TELEPHONE_LINE_LEAD_STATE_ROOT
    }
    $record.lead_state_root = [string]$stateHint
    $reconcile = $null
    try {
        $reconcile = Reconcile-TelephoneLeadCompletedOwnedResidue -LeadStateRoot $stateHint -ExpectedSessionId $sessionId
    } catch {
        $record.error = [string]$_.Exception.Message
        $record.provider_replayed = $false
    }
    if ($null -ne $reconcile -and $reconcile -is [Collections.IDictionary]) {
        foreach ($key in @('scanned', 'recovered', 'skipped_foreign', 'skipped_active', 'provider_replayed', 'persist_path', 'lead_state_root')) {
            if ($reconcile.Contains($key)) { $record[$key] = $reconcile[$key] }
        }
        if ($reconcile.Contains('refused')) { $record.refused = @($reconcile.refused) }
        if ($reconcile.Contains('pending')) { $record.pending = @($reconcile.pending) }
        if ($reconcile.Contains('recovered_runs')) { $record.recovered_runs = @($reconcile.recovered_runs) }
        $record.provider_replayed = $false
    }
    $payload = ConvertTo-TelephonePersistableRecord -Value $record
    $targets = [Collections.Generic.List[string]]::new()
    if ($null -ne $MailboxPaths -and $MailboxPaths -is [Collections.IDictionary] -and $MailboxPaths.Contains('lead_root') -and -not [string]::IsNullOrWhiteSpace([string]$MailboxPaths.lead_root)) {
        [void]$targets.Add((Join-Path ([string]$MailboxPaths.lead_root) 'residue-reconcile.json'))
    }
    if ($null -ne $JobPaths -and $JobPaths -is [Collections.IDictionary] -and $JobPaths.Contains('root') -and -not [string]::IsNullOrWhiteSpace([string]$JobPaths.root)) {
        [void]$targets.Add((Join-Path ([string]$JobPaths.root) 'residue-reconcile.json'))
    }
    if (-not [string]::IsNullOrWhiteSpace($stateHint) -and [IO.Directory]::Exists($stateHint)) {
        [void]$targets.Add((Join-Path ([IO.Path]::GetFullPath($stateHint).TrimEnd('\')) ('session-residue-reconcile-' + $sessionId.ToLowerInvariant() + '.json')))
    }
    foreach ($path in @($targets)) {
        try {
            if ([IO.File]::Exists($path)) { $null = Write-TelephoneJsonReplace -Path $path -Value $payload }
            else { $null = Write-TelephoneJsonCreateNew -Path $path -Value $payload }
            [void]$record.persist_paths.Add($path)
        } catch {
            try {
                $null = Write-TelephoneJsonReplace -Path $path -Value $payload
                [void]$record.persist_paths.Add($path)
            } catch { }
        }
    }
    return $record
}

function Invoke-TelephoneLeadCollectorCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$LeadKey
    )
    $mailbox = Get-TelephoneLeadMailboxPaths -StateRoot $StateRoot -LeadKey $LeadKey
    [IO.Directory]::CreateDirectory([string]$mailbox.lead_root) | Out-Null
    [IO.Directory]::CreateDirectory([string]$mailbox.mailbox) | Out-Null
    [IO.Directory]::CreateDirectory([string]$mailbox.batches) | Out-Null
    $owns = Enter-TelephoneLeadCollectorOwner -MailboxPaths $mailbox -LeadKey $LeadKey
    if (-not $owns) { return }
    $idleMs = Get-TelephoneCollectorIdleMilliseconds
    $idleSince = $null
    while ($true) {
        if (Test-TelephoneSupervisorRunStopRequested) { return }
        if ([IO.File]::Exists([string]$mailbox.fail_closed)) { return }
        $allJobs = @(Get-TelephoneStateJobs -StateRoot $StateRoot)
        $jobs = @($allJobs | Where-Object { [string]$_.canonical.identity_sha256 -ceq $LeadKey })
        $items = @(Get-TelephoneMailboxItems -MailboxPaths $mailbox)
        $batches = @{}
        foreach ($job in $jobs) {
            $id = [string]$job.batch.batch_id
            if (-not $batches.ContainsKey($id)) { $batches[$id] = $job.batch }
        }
        foreach ($item in $items) {
            $id = [string]$item.batch_id
            if (-not $batches.ContainsKey($id)) {
                $batches[$id] = [ordered]@{
                    protocol_version = 'telephone-line-batch-v1'
                    batch_id = $id
                    package_id = [string]$item.package_id
                    package_ids = @($item.package_ids)
                    n = [int]$item.n
                    retry_of = $item.retry_of
                    implicit = [bool]$item.implicit
                }
            }
        }
        $truthBatches = [Collections.Generic.List[object]]::new()
        $openWork = $false
        foreach ($batchId in @($batches.Keys | Sort-Object)) {
            $batch = $batches[$batchId]
            $update = $null
            try {
                $update = Update-TelephoneLeadBatchCollection -MailboxPaths $mailbox -Batch $batch -Jobs $jobs -Items $items -AllJobs $allJobs
            } catch {
                $batchPathsNow = Get-TelephoneBatchPaths -MailboxPaths $mailbox -BatchId ([string]$batchId)
                $failSession = ''
                foreach ($job in $jobs) {
                    if ([string]$job.batch.batch_id -ceq [string]$batchId) {
                        $failSession = [string]$job.canonical.session_id
                        break
                    }
                }
                try {
                    Write-TelephoneMailboxFailClosed -Path $batchPathsNow.fail_closed -BatchId ([string]$batchId) -Code 'BATCH_CONTRACT_INVALID' -LeadSessionId $failSession
                } catch { }
                $update = New-TelephoneCollectorFailedAmbiguousResult -BatchPaths $batchPathsNow -Batch $batch
            }
            $missingRows = @(Get-TelephoneCollectorUpdateMissing -Update $update)
            $missingIds = [Collections.Generic.List[string]]::new()
            foreach ($missingRow in $missingRows) {
                if ($missingRow -isnot [Collections.IDictionary] -or -not $missingRow.Contains('package_id')) { continue }
                $missingId = [string]$missingRow.package_id
                if ([string]::IsNullOrWhiteSpace($missingId)) { continue }
                $missingIds.Add($missingId)
            }
            $closedNow = $false
            if ($update -is [Collections.IDictionary] -and $update.Contains('closed')) { $closedNow = [bool]$update.closed }
            $stateNow = ''
            if ($update -is [Collections.IDictionary] -and $update.Contains('state')) { $stateNow = [string]$update.state }
            $truthBatches.Add([ordered]@{
                batch_id = [string]$batchId
                n = (Get-TelephoneCollectorUpdateInt -Update $update -Name 'n')
                counted = (Get-TelephoneCollectorUpdateInt -Update $update -Name 'counted')
                missing = @($missingRows)
                missing_package_ids = @($missingIds)
                state = $stateNow
                closed = $closedNow
                acceptance_eligible = $closedNow
                implicit = [bool]$batch.implicit
            })
            if ($stateNow -ceq 'failed_ambiguous') { continue }
            if (-not $closedNow) { $openWork = $true; continue }
            $jobsByPackage = $null
            if ($update -is [Collections.IDictionary] -and $update.Contains('jobs_by_package')) { $jobsByPackage = $update.jobs_by_package }
            $countedItems = @()
            if ($update -is [Collections.IDictionary] -and $update.Contains('counted_items') -and $null -ne $update.counted_items) {
                $countedItems = @($update.counted_items)
            }
            $allDelivered = $true
            foreach ($item in $countedItems) {
                if ($null -eq $item) { $allDelivered = $false; break }
                $job = $null
                $packageId = [string]$item.package_id
                if ($null -ne $jobsByPackage) {
                    try {
                        if ($jobsByPackage.ContainsKey($packageId)) { $job = $jobsByPackage[$packageId] }
                    } catch { $job = $null }
                }
                if ($null -eq $job -or -not [IO.File]::Exists($job.paths.delivery)) { $allDelivered = $false; break }
            }
            if ($allDelivered) { continue }
            $openWork = $true
            $manifestNow = $null
            if ($update -is [Collections.IDictionary] -and $update.Contains('manifest')) { $manifestNow = $update.manifest }
            if ($null -eq $manifestNow) { continue }
            $batchPathsWake = $null
            if ($update -is [Collections.IDictionary] -and $update.Contains('batch_paths')) { $batchPathsWake = $update.batch_paths }
            if ($null -eq $batchPathsWake) { continue }
            $lead = $null
            foreach ($job in $jobs) {
                if ([string]$job.batch.batch_id -ceq $batchId) { $lead = $job.lead; break }
            }
            if ($null -eq $lead) { continue }
            try {
                $null = Invoke-TelephoneLeadSessionResidueReconcile -Lead $lead -MailboxPaths $mailbox
                Invoke-TelephoneClosedBatchWake -MailboxPaths $mailbox -BatchPaths $batchPathsWake -Manifest $manifestNow -Lead $lead -JobsByPackage $jobsByPackage
            } catch {
                $attempted = [IO.File]::Exists($batchPathsWake.wake_attempt) -or [IO.File]::Exists($batchPathsWake.wake_launch_result)
                $msg = [string]$_.Exception.Message
                $code = 'LEAD_WAKE_FAILED'
                if ($msg -ceq 'LEAD_CLI_UNLAUNCHABLE' -or $msg -ceq 'LEAD_WAKE_INCOMPLETE_HOST' -or $msg -ceq 'LEAD_WAKE_AMBIGUOUS' -or $msg -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT') { $code = $msg }
                elseif ($attempted) { $code = 'LEAD_WAKE_AMBIGUOUS' }
                $retrying = ($code -ceq 'LEAD_WAKE_PRE_TURN_CONFLICT')
                if (-not $retrying) {
                    Write-TelephoneMailboxFailClosed -Path $batchPathsWake.fail_closed -BatchId $batchId -Code $code -LeadSessionId ([string]$lead.session_id)
                }
                $diag = Get-TelephoneLastLeadLaunchDiagnostic
                foreach ($job in $jobs) {
                    if ([string]$job.batch.batch_id -cne $batchId) { continue }
                    if ([IO.File]::Exists($job.paths.delivery)) { continue }
                    if ($retrying) {
                        Write-TelephoneLeadRetryingRelayError -JobPaths $job.paths -LineJobId ([string]$job.dispatch.line_job_id) -LeadSessionId ([string]$lead.session_id) -ErrorCode $code -Diagnostic $diag
                        continue
                    }
                    if ([IO.File]::Exists($job.paths.relay_error)) { continue }
                    $relayError = [ordered]@{
                        protocol_version = 'telephone-line-relay-error-v1'
                        line_job_id = [string]$job.dispatch.line_job_id
                        lead_session_id = [string]$lead.session_id
                        retrying = $false
                        error_code = $code
                        error_message = Get-TelephonePublicErrorMessage -ErrorCode $code
                        recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
                    }
                    if ($null -ne $diag) { $relayError['launch_diagnostic'] = $diag }
                    try { $null = Write-TelephoneJsonCreateNew -Path $job.paths.relay_error -Value $relayError } catch [IO.IOException] { }
                    if ($null -ne $diag) {
                        try { $null = Write-TelephoneJsonReplace -Path $job.paths.launch_failure -Value $diag } catch { }
                    }
                }
            }
        }
        $null = Write-TelephoneMailboxTruth -MailboxPaths $mailbox -Batches @($truthBatches)
        if ($openWork) {
            $idleSince = $null
            Start-Sleep -Milliseconds 200
            continue
        }
        if ($null -eq $idleSince) { $idleSince = [DateTimeOffset]::UtcNow }
        if (([DateTimeOffset]::UtcNow - $idleSince).TotalMilliseconds -ge $idleMs) { return }
        Start-Sleep -Milliseconds 200
    }
}

function Wait-TelephoneJobDelivery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$JobPaths,
        [int]$PollMilliseconds = 200,
        [string]$StateRoot = '',
        [string]$LeadKey = '',
        [string]$RelayScript = ''
    )
    $ensureAt = [DateTimeOffset]::MinValue
    while ($true) {
        if ([IO.File]::Exists($JobPaths.delivery)) { return $true }
        if (Test-TelephoneRelayErrorBlocksWait -JobPaths $JobPaths) { return $false }
        $refPath = [string]$JobPaths.mailbox_ref
        if ([IO.File]::Exists($refPath)) {
            try {
                $ref = (Read-TelephoneJson -Path $refPath).value
                $resolvedState = $StateRoot
                if ([string]::IsNullOrWhiteSpace($resolvedState)) {
                    $resolvedState = Get-TelephoneStateRootFromJobRoot -JobRoot ([string]$JobPaths.root)
                }
                $leadKeyNow = $LeadKey
                if ([string]::IsNullOrWhiteSpace($leadKeyNow)) { $leadKeyNow = [string]$ref.lead_identity_sha256 }
                $mailbox = Get-TelephoneLeadMailboxPaths -StateRoot $resolvedState -LeadKey $leadKeyNow
                $batchPaths = Get-TelephoneBatchPaths -MailboxPaths $mailbox -BatchId ([string]$ref.batch_id)
                if ([IO.File]::Exists($batchPaths.fail_closed) -or [IO.File]::Exists($mailbox.fail_closed)) { return $false }
            } catch { }
        }
        if (-not [string]::IsNullOrWhiteSpace($StateRoot) -and -not [string]::IsNullOrWhiteSpace($LeadKey) -and -not [string]::IsNullOrWhiteSpace($RelayScript)) {
            if (([DateTimeOffset]::UtcNow - $ensureAt).TotalMilliseconds -ge 500) {
                try { $null = Ensure-TelephoneLeadCollector -StateRoot $StateRoot -LeadKey $LeadKey -RelayScript $RelayScript } catch { }
                $ensureAt = [DateTimeOffset]::UtcNow
            }
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
}

function Test-TelephoneJobMailboxPendingWait {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$JobRoot)
    try {
        $paths = Get-TelephoneJobPaths -JobRoot $JobRoot
        if (-not [IO.File]::Exists($paths.dispatch)) { return $false }
        $dispatch = (Read-TelephoneJson -Path $paths.dispatch).value
        $lead = Read-TelephoneLeadBinding -Lead $dispatch.lead
        $canonical = Get-TelephoneLeadCanonicalIdentity -Lead $lead
        $stateRoot = Get-TelephoneStateRootFromJobRoot -JobRoot $JobRoot
        $mailbox = Get-TelephoneLeadMailboxPaths -StateRoot $stateRoot -LeadKey ([string]$canonical.identity_sha256)
        if ([IO.File]::Exists([string]$mailbox.owner)) {
            try {
                $owner = (Read-TelephoneJson -Path ([string]$mailbox.owner)).value
                if (Test-TelephoneOwnerAlive -Owner $owner) { return $true }
            } catch { }
        }
        $batch = Resolve-TelephoneDispatchBatch -Dispatch $dispatch -LineJobId ([string]$dispatch.line_job_id)
        $batchPaths = Get-TelephoneBatchPaths -MailboxPaths $mailbox -BatchId ([string]$batch.batch_id)
        if ([IO.File]::Exists($batchPaths.collection)) {
            $collection = (Read-TelephoneJson -Path $batchPaths.collection).value
            if ([string]$collection.state -cin @('collecting', 'closed_queued_behind_busy', 'callback_active')) { return $true }
        }
        if ([IO.File]::Exists($mailbox.truth)) {
            $truth = (Read-TelephoneJson -Path $mailbox.truth).value
            foreach ($row in @($truth.batches)) {
                if ([string]$row.batch_id -cne [string]$batch.batch_id) { continue }
                if ([string]$row.state -cin @('collecting', 'closed_queued_behind_busy', 'callback_active')) { return $true }
            }
        }
    } catch { }
    return $false
}

function Invoke-TelephoneControlPlaneLifecycleWake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Dispatch,
        [Parameter(Mandatory = $true)][string]$JobRoot,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    if (-not $Dispatch.Contains('control_plane') -or $null -eq $Dispatch.control_plane) { return [ordered]@{ configured = $false; started = $false } }
    $binding = $Dispatch.control_plane
    $wakeRecordPath = Join-Path $JobRoot ('control-plane-wake-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '.json')
    try {
        if ([string]$binding.protocol_version -cne 'telephone-line-control-plane-job-binding-v1') { throw 'Control-plane job binding protocol is invalid.' }
        if ([string]$binding.project -cne [string]$Dispatch.project) { throw 'Control-plane job binding project drifted.' }
        foreach ($field in @('control_state_root','supervisor_state_root','install_root','manifest_path')) {
            if ([string]::IsNullOrWhiteSpace([string]$binding[$field])) { throw ('Control-plane job binding is missing ' + $field + '.') }
        }
        $manifest = Get-TelephoneFileIdentity -Path (Assert-TelephoneRegularFilePath -Path ([string]$binding.manifest_path) -Label 'Control-plane manifest')
        $install = [IO.Path]::GetFullPath([string]$binding.install_root).TrimEnd('\')
        $projectKey = Get-TelephoneUtf8Sha256 -Text ([string]$binding.project)
        $dirtyRoot = Join-Path (Join-Path ([IO.Path]::GetFullPath([string]$binding.supervisor_state_root).TrimEnd('\')) 'control-plane') 'dirty'
        [IO.Directory]::CreateDirectory($dirtyRoot) | Out-Null
        $dirtyPath = Join-Path $dirtyRoot ($projectKey + '.json'); $dirtyGate = Open-TelephoneExclusiveGate -Path ($dirtyPath + '.lock') -WaitMilliseconds 10000
        if ($null -eq $dirtyGate) { throw 'Control-plane dirty generation is already owned.' }
        try {
            $prior = if ([IO.File]::Exists($dirtyPath)) { (Read-TelephoneJson -Path $dirtyPath).value } else { [ordered]@{ generation=0; ack_generation=0 } }
            $dirty = [ordered]@{ protocol_version='telephone-line-control-plane-dirty-v1';project=[string]$binding.project;generation=([int64]$prior.generation+1);ack_generation=[int64]$prior.ack_generation;reason=$Reason;manifest=$manifest;dirty_at_utc=[DateTimeOffset]::UtcNow.ToString('o');next_reconcile_at_utc=[DateTimeOffset]::UtcNow.ToString('o') }
            $dirtyIdentity = Write-TelephoneJsonReplace -Path $dirtyPath -Value $dirty
        } finally { $dirtyGate.Dispose() }
        $supervisorScript = Assert-TelephoneRegularFilePath -Path (Join-Path $install 'src\supervisor\Invoke-TelephoneSupervisor.ps1') -Label 'Control-plane supervisor'
        $owner = Start-TelephoneHiddenPowerShell -ScriptPath $supervisorScript -Arguments @('-InstallRoot',$install,'-StateRoot',[string]$binding.supervisor_state_root)
        $record = [ordered]@{
            protocol_version = 'telephone-line-control-plane-lifecycle-wake-v1'; line_job_id = [string]$Dispatch.line_job_id; project = [string]$Dispatch.project
            project_epoch = [string]$binding.project_epoch; wave_id = [string]$binding.wave_id; reason = $Reason; manifest = $manifest; dirty_generation = $dirtyIdentity; supervisor_owner = $owner
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o'); automatic = $true; heartbeat_required = $false; project_judgment = $false
        }
        $identity = Write-TelephoneJsonCreateNew -Path $wakeRecordPath -Value $record
        return [ordered]@{ configured = $true; started = $true; wake = $identity; owner = $owner }
    } catch {
        $errorRecord = [ordered]@{
            protocol_version = 'telephone-line-control-plane-lifecycle-wake-error-v1'; line_job_id = [string]$Dispatch.line_job_id; reason = $Reason
            error = [string]$_.Exception.Message; created_at_utc = [DateTimeOffset]::UtcNow.ToString('o'); project_judgment = $false
        }
        try { $null = Write-TelephoneJsonCreateNew -Path ($wakeRecordPath + '.error') -Value $errorRecord } catch { }
        return [ordered]@{ configured = $true; started = $false; error = [string]$_.Exception.Message }
    }
}
