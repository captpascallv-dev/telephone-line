# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'Telephone Line v0.1 supports Windows only.'
}

. (Join-Path $PSScriptRoot '..\..\core\TelephoneLine.Common.ps1')

$script:CodexAppServerProductRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
$script:CodexAppServerProfileProtocol = 'telephone-line-codex-app-server-lead-profile-v1'
$script:CodexAppServerRunProtocol = 'telephone-line-codex-app-server-lead-run-v1'
$script:CodexAppServerStatusProtocol = 'telephone-line-codex-app-server-lead-status-v1'
$script:CodexAppServerWakePrefix = 'tl-wake:'
$script:CodexAppServerClientName = 'telephone-line-codex-app-server-lead'
$script:CodexAppServerClientTitle = 'Telephone Line Codex app-server Lead'
$script:CodexAppServerClientVersion = '0.1.0'
$script:CodexAppServerAllowedMethods = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @(
    'initialize', 'initialized', 'thread/start', 'thread/resume', 'thread/read',
    'turn/start', 'turn/completed', 'thread/status/changed',
    'item/commandExecution/requestApproval', 'item/fileChange/requestApproval',
    'item/permissions/requestApproval', 'item/tool/requestUserInput',
    'serverRequest/resolved'
)) {
    [void]$script:CodexAppServerAllowedMethods.Add($name)
}
$script:CodexAppServerPendingMethods = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @(
    'item/commandExecution/requestApproval',
    'item/fileChange/requestApproval',
    'item/permissions/requestApproval',
    'item/tool/requestUserInput'
)) {
    [void]$script:CodexAppServerPendingMethods.Add($name)
}
$script:CodexAppServerForbiddenParamKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @(
    'jsonrpc', 'excludeTurns', 'initialTurnsPage', 'dynamicTools',
    'experimentalRawEvents', 'turnsBackwardsCursor', 'itemsBackwardsCursor',
    'additionalContext', 'responsesapiClientMetadata', 'allowProviderModelFallback',
    'runtimeWorkspaceRoots', 'permissions', 'multiAgentMode', 'historyMode',
    'projectId', 'environments', 'selectedCapabilityRoots', 'mockExperimentalField',
    'collaborationMode', 'canAcceptDirectInput'
)) {
    [void]$script:CodexAppServerForbiddenParamKeys.Add($name)
}
$script:CodexAppServerServiceTierDefault = 'default'
$script:CodexAppServerTurnStatusAllowlist = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @('completed', 'interrupted', 'failed', 'inProgress')) {
    [void]$script:CodexAppServerTurnStatusAllowlist.Add($name)
}
$script:CodexAppServerOfficialTerminals = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @('completed', 'failed', 'interrupted')) {
    [void]$script:CodexAppServerOfficialTerminals.Add($name)
}
$script:CodexAppServerThreadStatusAllowlist = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @('notLoaded', 'idle', 'systemError', 'active')) {
    [void]$script:CodexAppServerThreadStatusAllowlist.Add($name)
}
$script:CodexAppServerNonDefaultServiceTiers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in @('priority', 'fast', 'flex', 'ultrafast')) {
    [void]$script:CodexAppServerNonDefaultServiceTiers.Add($name)
}
$script:CodexAppServerThreadStartResponseKeys = @(
    'thread', 'model', 'modelProvider', 'serviceTier', 'cwd', 'instructionSources',
    'approvalPolicy', 'approvalsReviewer', 'sandbox', 'reasoningEffort'
)
$script:CodexAppServerCompatibilityCatalogPath = Join-Path $PSScriptRoot 'CodexAppServerCompatibility.psd1'
if (-not [IO.File]::Exists($script:CodexAppServerCompatibilityCatalogPath)) {
    throw 'Codex app-server compatibility catalog is missing.'
}
$script:CodexAppServerCompatibilityCatalog = Import-PowerShellDataFile -LiteralPath $script:CodexAppServerCompatibilityCatalogPath
if (
    $script:CodexAppServerCompatibilityCatalog -isnot [Collections.IDictionary] -or
    [string]$script:CodexAppServerCompatibilityCatalog.ProtocolVersion -cne 'telephone-line-codex-app-server-compatibility-catalog-v1' -or
    [string]$script:CodexAppServerCompatibilityCatalog.ServiceTier -cne $script:CodexAppServerServiceTierDefault
) {
    throw 'Codex app-server compatibility catalog is invalid.'
}
$script:CodexAppServerApprovedCompatibilityEntries = @($script:CodexAppServerCompatibilityCatalog.Entries)
$script:CodexAppServerCompatibilitySurfaceFiles = @($script:CodexAppServerCompatibilityCatalog.SurfaceFiles | ForEach-Object { [string]$_ })
if ($script:CodexAppServerApprovedCompatibilityEntries.Count -eq 0 -or $script:CodexAppServerCompatibilitySurfaceFiles.Count -eq 0) {
    throw 'Codex app-server compatibility catalog is empty.'
}
$script:CodexAppServerStartSerializerExtraKeys = @(
    'runtimeWorkspaceRoots', 'activePermissionProfile', 'multiAgentMode'
)
$script:CodexAppServerResumeSerializerExtraKeys = @(
    'runtimeWorkspaceRoots', 'activePermissionProfile', 'multiAgentMode',
    'initialTurnsPage', 'turnsBackwardsCursor', 'itemsBackwardsCursor'
)
$script:CodexAppServerRejectedRootExtraKeys = @(
    'backwardsCursor', 'nextCursor', 'selectedCapabilityRoots'
)
$script:CodexAppServerNullableSerializerExtraKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @(
    'activePermissionProfile', 'initialTurnsPage', 'turnsBackwardsCursor', 'itemsBackwardsCursor',
    'extra', 'canAcceptDirectInput'
)) {
    [void]$script:CodexAppServerNullableSerializerExtraKeys.Add($name)
}
$script:CodexAppServerTurnStartResponseKeys = @('turn')
$script:CodexAppServerThreadReadResponseKeys = @('thread')
$script:CodexAppServerThreadKeys = @(
    'id', 'sessionId', 'forkedFromId', 'parentThreadId', 'preview', 'ephemeral',
    'section', 'sectionEnteredAt', 'modelProvider', 'createdAt',
    'updatedAt', 'recencyAt', 'status', 'path', 'cwd', 'cliVersion', 'source',
    'threadSource', 'agentNickname', 'agentRole', 'gitInfo', 'name', 'turns'
)
$script:CodexAppServerThreadOptionalKeys = @(
    'extra', 'historyMode', 'canAcceptDirectInput', 'projectId'
)
$script:CodexAppServerTurnKeys = @(
    'id', 'items', 'itemsView', 'status', 'error', 'startedAt', 'completedAt', 'durationMs'
)
$script:CodexAppServerTurnItemsViewAllowlist = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @('notLoaded', 'summary', 'full')) {
    [void]$script:CodexAppServerTurnItemsViewAllowlist.Add($name)
}
$script:CodexAppServerCallbackWritePhases = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @('none', 'turn_start_sending', 'turn_bound', 'acknowledged', 'terminal_publishing', 'terminal')) {
    [void]$script:CodexAppServerCallbackWritePhases.Add($name)
}
$script:CodexAppServerFailFastCrashPoints = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @(
    'after-turn-bind', 'after-ack-in-progress',
    'before-terminal-intent', 'after-terminal-intent', 'after-terminal-final',
    'after-terminal-bound', 'after-terminal-run', 'after-terminal-result',
    'after-failure-snapshot', 'after-recovery-record', 'after-failure-retired',
    'after-recovery-commit-run', 'after-recovery-retired',
    'after-ambiguous-write-pre', 'after-ambiguous-write', 'before-write',
    'before-ack'
)) {
    [void]$script:CodexAppServerFailFastCrashPoints.Add($name)
}
$script:CodexAppServerUserMessageItemKeys = @('type', 'id', 'clientId', 'content')
$script:CodexAppServerUserInputTextKeys = @('type', 'text', 'text_elements')
$script:CodexAppServerUserInputAliasTypes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @('user', 'input_text', 'inputText')) {
    [void]$script:CodexAppServerUserInputAliasTypes.Add($name)
}
$script:CodexAppServerTextElementKeys = @('byteRange', 'placeholder')
$script:CodexAppServerByteRangeKeys = @('start', 'end')
$script:CodexAppServerImageDetailAllowlist = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @('auto', 'low', 'high', 'original')) {
    [void]$script:CodexAppServerImageDetailAllowlist.Add($name)
}
$script:CodexAppServerFailureCodeTable = [ordered]@{
    schema_or_version_mismatch = [ordered]@{ category = 'worker' }
    compatibility_drift_after_bind = [ordered]@{ category = 'worker' }
    transport_lost_before_terminal = [ordered]@{ category = 'worker' }
    worker_failed = [ordered]@{ category = 'worker' }
}
$script:CodexAppServerDurableHistoryRows = [Collections.Generic.List[object]]::new()
$script:CodexAppServerDurableHistoryKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$script:CodexAppServerPendingEnvelopeKeys = @('id', 'method', 'params')
$script:CodexAppServerNotificationEnvelopeKeys = @('method', 'params')
$script:CodexAppServerResolvedNotificationKeys = @('threadId', 'requestId')
$script:CodexAppServerStatusNotificationKeys = @('threadId', 'status')
$script:CodexAppServerCompletedNotificationKeys = @('threadId', 'turn')
$script:CodexAppServerPendingParamSpecs = [ordered]@{
    'item/commandExecution/requestApproval' = [ordered]@{
        Required = @('threadId', 'turnId', 'itemId', 'startedAtMs', 'environmentId')
        Allowed = @('threadId', 'turnId', 'itemId', 'startedAtMs', 'environmentId', 'approvalId', 'reason', 'networkApprovalContext', 'command', 'cwd', 'commandActions', 'proposedExecpolicyAmendment', 'proposedNetworkPolicyAmendments')
    }
    'item/fileChange/requestApproval' = [ordered]@{
        Required = @('threadId', 'turnId', 'itemId', 'startedAtMs')
        Allowed = @('threadId', 'turnId', 'itemId', 'startedAtMs', 'reason', 'grantRoot')
    }
    'item/permissions/requestApproval' = [ordered]@{
        Required = @('threadId', 'turnId', 'itemId', 'environmentId', 'startedAtMs', 'cwd', 'reason', 'permissions')
        Allowed = @('threadId', 'turnId', 'itemId', 'environmentId', 'startedAtMs', 'cwd', 'reason', 'permissions')
    }
    'item/tool/requestUserInput' = [ordered]@{
        Required = @('threadId', 'turnId', 'itemId', 'questions', 'isBlocking', 'autoResolutionMs')
        Allowed = @('threadId', 'turnId', 'itemId', 'questions', 'isBlocking', 'autoResolutionMs')
    }
}
$script:CodexAppServerPublicErrorCatalog = [ordered]@{
    STABLE_PROTOCOL_INVALID = 'Stable protocol response is invalid.'
    DURABLE_CHAIN_INVALID = 'Durable identity chain is invalid.'
    OWNER_INVALID = 'Durable owner record is invalid.'
    THREAD_OWNER_CONFLICT = 'A live callback owner already holds this thread.'
    CALLBACK_QUEUE_INVALID = 'Callback queue state is invalid.'
    THREAD_ID_INVALID = 'Thread id is invalid.'
    SERVICE_TIER_INVALID = 'Service tier is not the explicit default.'
    COMPATIBILITY_DRIFT = 'Installed Codex identity does not match the bound run.'
    RUN_ID_INVALID = 'RunId is invalid.'
    STATE_CONTAINMENT_INVALID = 'State path is not a contained run root.'
    PACKAGE_LOCAL_STATE = 'Runtime state must stay outside the product package.'
    STATUS_SOURCES_INVALID = 'Status sources are invalid.'
    VERSION_PROBE_FAILED = 'Codex version probe failed.'
    SCHEMA_OR_PROFILE_INVALID = 'Codex schema or profile probe failed.'
    WORKTREE_INVALID = 'Worktree is invalid.'
    STATE_ROOT_INVALID = 'State root is invalid.'
    FILESYSTEM_INVALID = 'Filesystem probe failed.'
    BUILDER_FAILED = 'Lead binding was not created.'
    GENERIC_FAILURE = 'Codex app-server Lead failed.'
    CODEX_EXECUTABLE_MISSING = 'Codex executable is missing.'
    CODEX_EXECUTABLE_NOT_ON_PATH = 'Codex executable is not on PATH.'
}

function Get-CodexAppServerProductRoot {
    [CmdletBinding()]
    param()
    return [string]$script:CodexAppServerProductRoot
}

function ConvertTo-CodexAppServerJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Value)
    return ((ConvertTo-Json -InputObject $Value -Depth 64).Replace("`r`n", "`n") + "`n")
}

function Write-CodexAppServerStdoutJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Value)
    $json = ConvertTo-CodexAppServerJson -Value $Value
    $utf8 = [Text.UTF8Encoding]::new($false)
    try { [Console]::OutputEncoding = $utf8 } catch { }
    [Console]::Out.Write($json)
}

function Get-CodexAppServerDictString {
    [CmdletBinding()]
    param([AllowNull()][object]$Dict, [Parameter(Mandatory = $true)][string]$Key)
    if ($Dict -isnot [Collections.IDictionary] -or -not $Dict.Contains($Key) -or (Test-CodexAppServerJsonNull -Value $Dict[$Key])) {
        return ''
    }
    return [string]$Dict[$Key]
}

function Get-CodexAppServerDictObject {
    [CmdletBinding()]
    param([AllowNull()][object]$Dict, [Parameter(Mandatory = $true)][string]$Key)
    if ($Dict -isnot [Collections.IDictionary] -or -not $Dict.Contains($Key)) {
        return
    }
    Write-Output -NoEnumerate -InputObject $Dict[$Key]
}

function Test-CodexAppServerFallbackMessage {
    [CmdletBinding()]
    param([AllowNull()][string]$Message)
    $text = [string]$Message
    return (
        $text.IndexOf('"fallback_required": "cli"', [StringComparison]::Ordinal) -ge 0 -or
        $text.IndexOf('"fallback_required":"cli"', [StringComparison]::Ordinal) -ge 0
    )
}

function Get-CodexAppServerPublicMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Code)
    $name = [string]$Code
    if ($script:CodexAppServerPublicErrorCatalog.Contains($name)) {
        return [string]$script:CodexAppServerPublicErrorCatalog[$name]
    }
    return [string]$script:CodexAppServerPublicErrorCatalog['GENERIC_FAILURE']
}

function Test-CodexAppServerPublicMessage {
    [CmdletBinding()]
    param([AllowNull()][string]$Message)
    $text = [string]$Message
    if ([string]::IsNullOrEmpty($text)) { return $false }
    foreach ($known in @($script:CodexAppServerPublicErrorCatalog.Values)) {
        if ($text -ceq [string]$known) { return $true }
    }
    return (Test-TelephoneKnownPublicErrorMessage -Message $text)
}

function Get-CodexAppServerArchivedResumeAdvice {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ThreadId)
    return ('codex unarchive ' + [string]$ThreadId)
}

function Get-CodexAppServerArchivedThreadErrorMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ThreadId)
    $id = [string]$ThreadId
    $bt = [char]96
    return ('session ' + $id + ' is archived. Run ' + $bt + 'codex unarchive ' + $id + $bt + ' to unarchive it first.')
}

function Test-CodexAppServerArchivedThreadError {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Code,
        [AllowNull()][object]$Message,
        [Parameter(Mandatory = $true)][string]$ThreadId
    )
    if ([string]::IsNullOrWhiteSpace($ThreadId)) { return $false }
    if ($Message -isnot [string]) { return $false }
    $codeNumber = $null
    if (Test-CodexAppServerJsonNumber -Value $Code) {
        $codeNumber = [int64][Math]::Truncate([double]$Code)
    } else {
        return $false
    }
    if ($codeNumber -ne [int64]-32600) { return $false }
    $expected = Get-CodexAppServerArchivedThreadErrorMessage -ThreadId $ThreadId
    return ([string]$Message).Equals($expected, [StringComparison]::Ordinal)
}

function Get-CodexAppServerCaughtRequestError {
    [CmdletBinding()]
    param([AllowNull()][object]$ErrorRecord)
    $cursor = $null
    if ($ErrorRecord -is [Management.Automation.ErrorRecord]) {
        $cursor = $ErrorRecord.Exception
    } elseif ($ErrorRecord -is [Exception]) {
        $cursor = $ErrorRecord
    }
    while ($null -ne $cursor) {
        if ($null -ne $cursor.Data -and $cursor.Data.Contains('telephone.codex.app_server.error_code')) {
            return [ordered]@{
                code = $cursor.Data['telephone.codex.app_server.error_code']
                message = [string]$cursor.Data['telephone.codex.app_server.error_message']
            }
        }
        $cursor = $cursor.InnerException
    }
    return $null
}

function Throw-CodexAppServerRequestError {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Code,
        [AllowNull()][string]$Message
    )
    $ex = [InvalidOperationException]::new((Get-CodexAppServerPublicMessage -Code 'GENERIC_FAILURE'))
    $ex.Data['telephone.codex.app_server.error_code'] = $Code
    $ex.Data['telephone.codex.app_server.error_message'] = [string]$Message
    throw $ex
}

function Test-CodexAppServerBusyRequestError {
    [CmdletBinding()]
    param([AllowNull()][object]$ErrorRecord)
    $caught = Get-CodexAppServerCaughtRequestError -ErrorRecord $ErrorRecord
    if ($null -eq $caught) { return $false }
    $message = [string]$caught.message
    $messageBusy = (
        -not [string]::IsNullOrWhiteSpace($message) -and
        ($message -match '(?i)turn already in progress|already has an active turn|thread is busy')
    )
    if (-not $messageBusy) { return $false }
    $code = $caught.code
    $codeNumber = [int64]0
    $parsed = $false
    if ($code -is [byte] -or $code -is [sbyte] -or $code -is [int16] -or $code -is [uint16] -or $code -is [int] -or $code -is [uint32] -or $code -is [long] -or $code -is [int64] -or $code -is [double] -or $code -is [decimal]) {
        try {
            $codeNumber = [int64]$code
            $parsed = $true
        } catch { $parsed = $false }
    } elseif ($code -is [string]) {
        $parsed = [int64]::TryParse([string]$code, [ref]$codeNumber)
    }
    if ($parsed -and $codeNumber -ne [int64]-32000 -and $codeNumber -ne [int64]-32603 -and $codeNumber -ne [int64]-32600) {
        return $false
    }
    return $true
}

function Write-CodexAppServerTestCommandLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [AllowNull()][object]$ExitCode = $null
    )
    $path = [string]$env:TELEPHONE_TEST_CODEX_COMMAND_LOG
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $record = [ordered]@{
        executable = [string]$Executable
        arguments = @($Arguments | ForEach-Object { [string]$_ })
    }
    if ($null -ne $ExitCode -and (Test-CodexAppServerJsonNumber -Value $ExitCode)) {
        $record.exit_code = [int]$ExitCode
    }
    $line = (($record | ConvertTo-Json -Compress -Depth 8) + "`n")
    [IO.File]::AppendAllText($path, $line, [Text.UTF8Encoding]::new($false))
}

function Consume-CodexAppServerInjectedResumeError {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ThreadId)
    $path = [string]$env:TELEPHONE_TEST_APP_SERVER_ARCHIVED_RESUME_ONCE
    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.File]::Exists($path)) { return $null }
    $doc = $null
    try {
        $doc = ([IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String)
    } catch {
        return $null
    }
    if ($doc -isnot [Collections.IDictionary]) { return $null }
    $remaining = 0
    if ($doc.Contains('remaining')) {
        try { $remaining = [int]$doc.remaining } catch { $remaining = 0 }
    }
    if ($remaining -lt 1) { return $null }
    $doc.remaining = $remaining - 1
    try {
        if ([int]$doc.remaining -le 0) {
            [IO.File]::Delete($path)
        } else {
            [IO.File]::WriteAllText($path, (($doc | ConvertTo-Json -Compress -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
        }
    } catch { }
    $code = [int64]-32600
    if ($doc.Contains('code')) { $code = $doc.code }
    $message = Get-CodexAppServerArchivedThreadErrorMessage -ThreadId $ThreadId
    if ($doc.Contains('message') -and -not [string]::IsNullOrWhiteSpace([string]$doc.message)) {
        $message = [string]$doc.message
    }
    return [ordered]@{
        code = $code
        message = $message
    }
}

function Invoke-CodexAppServerUnarchiveThread {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [string]$WorkingDirectory = ''
    )
    Assert-CodexAppServerThreadId -ThreadId $ThreadId
    if ([string]::IsNullOrWhiteSpace($CodexCommand)) {
        Throw-CodexAppServerPublic -Code 'CODEX_EXECUTABLE_MISSING'
    }
    $exe = Resolve-CodexAppServerExecutable -CodexCommand $CodexCommand
    $arguments = @('unarchive', [string]$ThreadId)
    foreach ($item in @($arguments)) {
        $token = [string]$item
        if (
            $token.IndexOf('Fast', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $token.IndexOf('priority', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $token.IndexOf('ultrafast', [StringComparison]::OrdinalIgnoreCase) -ge 0
        ) {
            Throw-CodexAppServerPublic -Code 'SERVICE_TIER_INVALID'
        }
    }
    try {
        $result = Invoke-CodexAppServerCapturedCommand -CodexCommand $exe -Arguments $arguments -WorkingDirectory $WorkingDirectory -TimeoutMilliseconds 20000
    } catch {
        Write-CodexAppServerTestCommandLog -Executable $exe -Arguments $arguments
        throw
    }
    Write-CodexAppServerTestCommandLog -Executable $exe -Arguments $arguments -ExitCode ([int]$result.exit_code)
    if ([int]$result.exit_code -ne 0) {
        Throw-CodexAppServerPublic -Code 'GENERIC_FAILURE'
    }
    return $result
}

function Protect-CodexAppServerText {
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [int]$MaxLength = 500)
    $safe = [string]$Text
    if (Test-CodexAppServerPublicMessage -Message $safe) { return $safe }
    if (Test-CodexAppServerFallbackMessage -Message $safe) {
        return (Get-CodexAppServerPublicMessage -Code 'COMPATIBILITY_DRIFT')
    }
    return (Get-CodexAppServerPublicMessage -Code 'GENERIC_FAILURE')
}

function Get-CodexAppServerPublicFailure {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Message,
        [string]$Code = 'GENERIC_FAILURE'
    )
    $fallback = ''
    if (Test-CodexAppServerFallbackMessage -Message $Message) { $fallback = 'cli' }
    $resolved = [string]$Code
    if (Test-CodexAppServerPublicMessage -Message $Message) {
        foreach ($key in @($script:CodexAppServerPublicErrorCatalog.Keys)) {
            if ([string]$Message -ceq [string]$script:CodexAppServerPublicErrorCatalog[$key]) {
                $resolved = [string]$key
                break
            }
        }
    } elseif ($fallback -ceq 'cli') {
        $resolved = 'COMPATIBILITY_DRIFT'
    }
    return [ordered]@{
        code = $resolved
        message = (Get-CodexAppServerPublicMessage -Code $resolved)
        fallback_required = $fallback
    }
}

function Throw-CodexAppServerPublic {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Code)
    throw (Get-CodexAppServerPublicMessage -Code $Code)
}

function Get-CodexAppServerSha256Hex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-CodexAppServerCanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { Throw-CodexAppServerPublic -Code 'FILESYSTEM_INVALID' }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-CodexAppServerCanonicalPathEqual {
    [CmdletBinding()]
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    $a = Get-CodexAppServerCanonicalPath -Path $Left
    $b = Get-CodexAppServerCanonicalPath -Path $Right
    return $a.Equals($b, [StringComparison]::OrdinalIgnoreCase)
}

function Test-CodexAppServerExactKeys {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Dict,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Required,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Allowed
    )
    if ($Dict -isnot [Collections.IDictionary]) { return $false }
    foreach ($need in @($Required)) {
        if (-not $Dict.Contains($need)) { return $false }
    }
    foreach ($key in @($Dict.Keys)) {
        if (@($Allowed) -notcontains [string]$key) { return $false }
    }
    return $true
}

function Assert-CodexAppServerExactKeys {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Dict,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Required,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Allowed
    )
    if (-not (Test-CodexAppServerExactKeys -Dict $Dict -Required $Required -Allowed $Allowed)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
}

function Test-CodexAppServerJsonNull {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    return [object]::ReferenceEquals($Value, $null)
}

function Test-CodexAppServerJsonArray {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    return (
        $Value -is [System.Collections.IEnumerable] -and
        $Value -isnot [string] -and
        $Value -isnot [Collections.IDictionary]
    )
}

function Get-CodexAppServerJsonArrayItems {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    $items = [Collections.Generic.List[object]]::new()
    if (Test-CodexAppServerJsonNull -Value $Value) {
        Write-Output -NoEnumerate -InputObject ([object[]]@())
        return
    }
    if ($Value -is [Collections.IDictionary]) {
        $items.Add($Value)
        Write-Output -NoEnumerate -InputObject ([object[]]@($items))
        return
    }
    if (Test-CodexAppServerJsonArray -Value $Value) {
        foreach ($item in $Value) { $items.Add($item) }
        Write-Output -NoEnumerate -InputObject ([object[]]@($items))
        return
    }
    Write-Output -NoEnumerate -InputObject ([object[]]@())
}

function Test-CodexAppServerJsonNumber {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if (Test-CodexAppServerJsonNull -Value $Value) { return $false }
    return ($Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single])
}

function Test-CodexAppServerJsonInteger {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if (-not (Test-CodexAppServerJsonNumber -Value $Value)) { return $false }
    $n = [double]$Value
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $false }
    return (($n % 1) -eq 0)
}

function Test-CodexAppServerJsonString {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    return ($Value -is [string])
}

function Test-CodexAppServerJsonBoolean {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    return ($Value -is [bool])
}

function Test-CodexAppServerJsonEmptyObject {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($Value -isnot [Collections.IDictionary]) { return $false }
    return (@($Value.Keys).Count -eq 0)
}

function Test-CodexAppServerFullyQualifiedWindowsPathString {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if (-not (Test-CodexAppServerJsonString -Value $Value)) { return $false }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return [IO.Path]::IsPathFullyQualified($text)
}

function Test-CodexAppServerAbsolutePathString {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    return (Test-CodexAppServerFullyQualifiedWindowsPathString -Value $Value)
}

function Get-CodexAppServerCombinedExactKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Required,
        [AllowEmptyCollection()][string[]]$Optional = @()
    )
    $out = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in @($Required)) {
        $name = [string]$key
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($seen.Add($name)) { $out.Add($name) }
    }
    foreach ($key in @($Optional)) {
        $name = [string]$key
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($seen.Add($name)) { $out.Add($name) }
    }
    return [string[]]@($out)
}

function Get-CodexAppServerNearestExistingAncestor {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while (-not [IO.File]::Exists($current) -and -not [IO.Directory]::Exists($current)) {
        $parent = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-CodexAppServerPublic -Code 'FILESYSTEM_INVALID'
        }
        $current = $parent
    }
    return [IO.Path]::GetFullPath($current).TrimEnd('\')
}

function Assert-CodexAppServerPathOutsidePackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $product = [IO.Path]::GetFullPath((Get-CodexAppServerProductRoot)).TrimEnd('\')
    $prefix = $product + '\'
    if ($full.Equals($product, [StringComparison]::OrdinalIgnoreCase) -or ($full + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CodexAppServerPublic -Code 'PACKAGE_LOCAL_STATE'
    }
}

function Test-CodexAppServerCompatibilityFailureMessage {
    [CmdletBinding()]
    param([AllowNull()][string]$Message)
    if (Test-CodexAppServerFallbackMessage -Message $Message) { return $true }
    return ([string]$Message -ceq (Get-CodexAppServerPublicMessage -Code 'COMPATIBILITY_DRIFT'))
}

function Test-CodexAppServerReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-CodexAppServerNoReparseChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { Throw-CodexAppServerPublic -Code 'FILESYSTEM_INVALID' }
    if (Test-CodexAppServerReparsePoint -Path $root) { Throw-CodexAppServerPublic -Code 'FILESYSTEM_INVALID' }
    $relative = [IO.Path]::GetRelativePath($root, $full)
    $current = $root.TrimEnd('\')
    foreach ($segment in @($relative.Replace('/', '\').Split([char]'\'))) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -ceq '.') { continue }
        $current = Join-Path $current $segment
        if (([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) -and (Test-CodexAppServerReparsePoint -Path $current)) {
            Throw-CodexAppServerPublic -Code 'FILESYSTEM_INVALID'
        }
    }
    return [IO.Path]::GetFullPath($full).TrimEnd('\')
}

function Get-CodexAppServerWakeMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RunId)
    $id = [string]$RunId
    if ([string]::IsNullOrWhiteSpace($id)) { throw 'RunId is required for the wake marker.' }
    if ($id -notmatch '^[A-Za-z0-9._:-]+$') { throw 'RunId is not a non-sensitive wake marker identity.' }
    return ($script:CodexAppServerWakePrefix + $id)
}

function New-CodexAppServerTurnInputText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PromptText,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $marker = Get-CodexAppServerWakeMarker -RunId $RunId
    $body = [string]$PromptText
    if ($body.IndexOf($marker, [StringComparison]::Ordinal) -ge 0) {
        return $body
    }
    if ([string]::IsNullOrEmpty($body)) { return $marker }
    return ($body.TrimEnd() + "`n`n" + $marker)
}

function Test-CodexAppServerTextHasMarker {
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [Parameter(Mandatory = $true)][string]$Marker)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return ([string]$Text).IndexOf([string]$Marker, [StringComparison]::Ordinal) -ge 0
}

function Get-CodexAppServerLauncherPath {
    [CmdletBinding()]
    param()
    $path = Join-Path $PSScriptRoot 'Invoke-CodexAppServerLeadLauncher.ps1'
    return Assert-TelephoneRegularFilePath -Path $path -Label 'Codex app-server Lead launcher'
}

function Resolve-CodexAppServerExecutable {
    [CmdletBinding()]
    param([string]$CodexCommand)
    if (-not [string]::IsNullOrWhiteSpace($CodexCommand)) {
        $full = [IO.Path]::GetFullPath($CodexCommand)
    if (-not [IO.File]::Exists($full)) { Throw-CodexAppServerPublic -Code 'CODEX_EXECUTABLE_MISSING' }
        return (Assert-CodexAppServerNoReparseChain -Path $full -Label 'Codex executable')
    }
    $cmd = Get-Command 'codex' -ErrorAction SilentlyContinue
    if ($null -eq $cmd -or [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        Throw-CodexAppServerPublic -Code 'CODEX_EXECUTABLE_NOT_ON_PATH'
    }
    return (Assert-CodexAppServerNoReparseChain -Path ([string]$cmd.Source) -Label 'Codex executable')
}

function New-CodexAppServerProcessStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [string]$WorkingDirectory = '',
        [switch]$RedirectStdio
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    if ($RedirectStdio) {
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $info.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    }
    $exe = [IO.Path]::GetFullPath($CodexCommand)
    if ($exe.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
        $info.FileName = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        foreach ($item in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $exe
        )) {
            [void]$info.ArgumentList.Add([string]$item)
        }
    } else {
        $info.FileName = $exe
    }
    foreach ($item in @($Arguments)) {
        [void]$info.ArgumentList.Add([string]$item)
    }
    return $info
}

function Invoke-CodexAppServerCapturedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [string]$WorkingDirectory = '',
        [int]$TimeoutMilliseconds = 30000
    )
    $info = New-CodexAppServerProcessStartInfo -CodexCommand $CodexCommand -Arguments $Arguments -WorkingDirectory $WorkingDirectory -RedirectStdio
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw 'Codex command failed to start.' }
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill($true) } catch { }
            throw 'Codex command exceeded its bounded wait.'
        }
        return [ordered]@{
            exit_code = [int]$process.ExitCode
            stdout = [string]$stdoutTask.GetAwaiter().GetResult()
            stderr = [string]$stderrTask.GetAwaiter().GetResult()
            pid = [int]$process.Id
        }
    } finally {
        $process.Dispose()
    }
}

function Get-CodexAppServerVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CodexCommand)
    $captured = Invoke-CodexAppServerCapturedCommand -CodexCommand $CodexCommand -Arguments @('--version')
    if ([int]$captured.exit_code -ne 0) {
        Throw-CodexAppServerPublic -Code 'VERSION_PROBE_FAILED'
    }
    $version = ([string]$captured.stdout).Trim()
    if ([string]::IsNullOrWhiteSpace($version)) { Throw-CodexAppServerPublic -Code 'VERSION_PROBE_FAILED' }
    return $version
}

function Get-CodexAppServerSchemaFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SchemaDirectory)
    $root = Assert-CodexAppServerNoReparseChain -Path $SchemaDirectory -Label 'Schema directory'
    if (-not [IO.Directory]::Exists($root)) { throw 'Generated schema directory is missing.' }
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName)
    $rows = New-Object 'System.Collections.Generic.List[string]'
    $total = [int64]0
    foreach ($file in $files) {
        $rel = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $total += [int64]$bytes.Length
        $sha = Get-CodexAppServerSha256Hex -Bytes $bytes
        [void]$rows.Add(($rel + "`t" + $bytes.Length.ToString() + "`t" + $sha))
    }
    $canon = ([string]::Join("`n", $rows) + "`n")
    $canonBytes = [Text.UTF8Encoding]::new($false).GetBytes($canon)
    return [ordered]@{
        file_count = [int]$files.Count
        schema_bytes = $total
        fingerprint = (Get-CodexAppServerSha256Hex -Bytes $canonBytes)
    }
}

function Remove-CodexAppServerDirectoryNative {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Label = 'temporary directory')
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Directory]::Exists($full)) { return }
    [IO.Directory]::Delete($full, $true)
    if ([IO.Directory]::Exists($full) -or [IO.File]::Exists($full)) {
        throw "$Label residue remains after native cleanup."
    }
}

function Invoke-CodexAppServerGenerateSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )
    $out = [IO.Path]::GetFullPath($OutputDirectory)
    if ([IO.Directory]::Exists($out)) {
        Remove-CodexAppServerDirectoryNative -Path $out -Label 'schema output'
    }
    [IO.Directory]::CreateDirectory($out) | Out-Null
    $captured = Invoke-CodexAppServerCapturedCommand -CodexCommand $CodexCommand -Arguments @(
        'app-server', 'generate-json-schema', '--out', $out
    )
    if ([int]$captured.exit_code -ne 0) {
        Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID'
    }
    return (Get-CodexAppServerSchemaFingerprint -SchemaDirectory $out)
}

function Read-CodexAppServerGeneratedSchemaDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) { throw 'Generated schema file is missing.' }
    $text = [IO.File]::ReadAllText($full, [Text.UTF8Encoding]::new($false, $true))
    $doc = $text | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    if ($doc -isnot [Collections.IDictionary]) { throw 'Generated schema file is not an object.' }
    return $doc
}

function Test-CodexAppServerSchemaContainerOpen {
    [CmdletBinding()]
    param([AllowNull()][object]$Node)
    if ($Node -isnot [Collections.IDictionary]) { return $false }
    if (-not $Node.Contains('additionalProperties')) { return $true }
    return -not ($Node['additionalProperties'] -eq $false)
}

function Test-CodexAppServerSchemaAllowsJsonNull {
    [CmdletBinding()]
    param([AllowNull()][object]$Node)
    if ($Node -isnot [Collections.IDictionary]) { return $false }
    if ($Node.Contains('type')) {
        $typeNode = $Node['type']
        if ((Test-CodexAppServerJsonString -Value $typeNode) -and ([string]$typeNode -ceq 'null')) { return $true }
        if (Test-CodexAppServerJsonArray -Value $typeNode) {
            foreach ($item in (Get-CodexAppServerJsonArrayItems -Value $typeNode)) {
                if ((Test-CodexAppServerJsonString -Value $item) -and ([string]$item -ceq 'null')) { return $true }
            }
        }
    }
    foreach ($unionKey in @('anyOf', 'oneOf')) {
        if (-not $Node.Contains($unionKey) -or -not (Test-CodexAppServerJsonArray -Value $Node[$unionKey])) { continue }
        foreach ($item in (Get-CodexAppServerJsonArrayItems -Value $Node[$unionKey])) {
            if (Test-CodexAppServerSchemaAllowsJsonNull -Node $item) { return $true }
        }
    }
    return $false
}

function Test-CodexAppServerSchemaServiceTierNullable {
    [CmdletBinding()]
    param([AllowNull()][object]$Doc)
    if ($Doc -isnot [Collections.IDictionary] -or -not $Doc.Contains('properties') -or $Doc['properties'] -isnot [Collections.IDictionary]) {
        return $false
    }
    if (-not $Doc['properties'].Contains('serviceTier')) { return $false }
    return (Test-CodexAppServerSchemaAllowsJsonNull -Node $Doc['properties']['serviceTier'])
}

function Get-CodexAppServerSchemaThreadNode {
    [CmdletBinding()]
    param([AllowNull()][object]$Doc)
    if ($Doc -isnot [Collections.IDictionary] -or -not $Doc.Contains('definitions') -or $Doc['definitions'] -isnot [Collections.IDictionary]) {
        return $null
    }
    if (-not $Doc['definitions'].Contains('Thread')) { return $null }
    return $Doc['definitions']['Thread']
}

function Get-CodexAppServerSchemaSurfaceFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SchemaDirectory,
        [string[]]$RelativePaths = $script:CodexAppServerCompatibilitySurfaceFiles
    )
    $root = Assert-CodexAppServerNoReparseChain -Path $SchemaDirectory -Label 'Schema directory'
    $rows = [Collections.Generic.List[string]]::new()
    $total = [int64]0
    foreach ($relative in @($RelativePaths)) {
        $rel = ([string]$relative).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($rel) -or $rel.StartsWith('../', [StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($rel)) {
            throw 'Compatibility surface path is invalid.'
        }
        $path = Join-Path $root $rel.Replace('/', '\')
        if (-not [IO.File]::Exists($path)) { throw "Generated compatibility surface is missing: $rel" }
        $bytes = [IO.File]::ReadAllBytes($path)
        $total += [int64]$bytes.Length
        $sha = Get-CodexAppServerSha256Hex -Bytes $bytes
        $rows.Add($rel + "`t" + $bytes.Length.ToString() + "`t" + $sha)
    }
    $canon = [Text.UTF8Encoding]::new($false).GetBytes(([string]::Join("`n", $rows) + "`n"))
    return [ordered]@{
        file_count = [int]@($RelativePaths).Count
        schema_bytes = [int64]$total
        fingerprint = Get-CodexAppServerSha256Hex -Bytes $canon
    }
}

function Get-CodexAppServerApprovedCompatibilityEntry {
    [CmdletBinding()]
    param([AllowNull()][object]$License)
    if ($License -isnot [Collections.IDictionary]) { return $null }
    $version = Get-CodexAppServerDictString -Dict $License -Key 'codex_version'
    $fingerprint = Get-CodexAppServerDictString -Dict $License -Key 'schema_fingerprint'
    $tier = Get-CodexAppServerDictString -Dict $License -Key 'service_tier'
    $count = if ($License.Contains('schema_file_count')) { [int]$License['schema_file_count'] } else { 0 }
    $bytes = if ($License.Contains('schema_bytes')) { [int64]$License['schema_bytes'] } else { [int64]0 }
    foreach ($entry in @($script:CodexAppServerApprovedCompatibilityEntries)) {
        if ($entry -isnot [Collections.IDictionary]) { continue }
        if (
            [string]$entry.CodexVersion -ceq $version -and
            [string]$entry.SchemaFingerprint -ceq $fingerprint -and
            [int]$entry.SchemaFileCount -eq $count -and
            [int64]$entry.SchemaBytes -eq $bytes -and
            $tier -ceq $script:CodexAppServerServiceTierDefault
        ) { return $entry }
    }
    return $null
}

function Get-CodexAppServerApprovedCompatibilityEntryByVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CodexVersion)
    $matches = @($script:CodexAppServerApprovedCompatibilityEntries | Where-Object { [string]$_.CodexVersion -ceq $CodexVersion })
    if ($matches.Count -ne 1) { return $null }
    return $matches[0]
}

function Get-CodexAppServerCompatibilitySchemaEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SchemaDirectory)
    $root = Assert-CodexAppServerNoReparseChain -Path $SchemaDirectory -Label 'Schema directory'
    $startDoc = Read-CodexAppServerGeneratedSchemaDocument -Path (Join-Path $root 'v2\ThreadStartResponse.json')
    $resumeDoc = Read-CodexAppServerGeneratedSchemaDocument -Path (Join-Path $root 'v2\ThreadResumeResponse.json')
    $notificationDoc = Read-CodexAppServerGeneratedSchemaDocument -Path (Join-Path $root 'ServerNotification.json')
    $startThread = Get-CodexAppServerSchemaThreadNode -Doc $startDoc
    $resumeThread = Get-CodexAppServerSchemaThreadNode -Doc $resumeDoc
    $startOpen = Test-CodexAppServerSchemaContainerOpen -Node $startDoc
    $resumeOpen = Test-CodexAppServerSchemaContainerOpen -Node $resumeDoc
    $threadOpen = ((Test-CodexAppServerSchemaContainerOpen -Node $startThread) -and (Test-CodexAppServerSchemaContainerOpen -Node $resumeThread))
    $serviceTierNullable = ((Test-CodexAppServerSchemaServiceTierNullable -Doc $startDoc) -and (Test-CodexAppServerSchemaServiceTierNullable -Doc $resumeDoc))
    $emittedAtMsInt64 = $false
    if ($notificationDoc.Contains('properties') -and $notificationDoc.properties -is [Collections.IDictionary] -and $notificationDoc.properties.Contains('emittedAtMs')) {
        $emittedNode = $notificationDoc.properties.emittedAtMs
        if ($emittedNode -is [Collections.IDictionary]) {
            $emittedAtMsInt64 = (
                (Get-CodexAppServerDictString -Dict $emittedNode -Key 'type') -ceq 'integer' -and
                (Get-CodexAppServerDictString -Dict $emittedNode -Key 'format') -ceq 'int64'
            )
        }
    }
    return [ordered]@{
        compatibility_kind = 'passive-serializer-extras'
        extras_are_stable_schema_properties = $false
        start_response_open = [bool]$startOpen
        resume_response_open = [bool]$resumeOpen
        thread_open = [bool]$threadOpen
        service_tier_nullable = [bool]$serviceTierNullable
        notification_emitted_at_ms_int64 = [bool]$emittedAtMsInt64
        start_serializer_extra_keys = @($script:CodexAppServerStartSerializerExtraKeys)
        resume_serializer_extra_keys = @($script:CodexAppServerResumeSerializerExtraKeys)
        thread_serializer_extra_keys = @($script:CodexAppServerThreadOptionalKeys)
        rejected_root_extra_keys = @($script:CodexAppServerRejectedRootExtraKeys)
        containers_open_and_service_tier_nullable = ([bool]$startOpen -and [bool]$resumeOpen -and [bool]$threadOpen -and [bool]$serviceTierNullable -and [bool]$emittedAtMsInt64)
    }
}

function Get-CodexAppServer0147CompatibilitySchemaEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SchemaDirectory)
    return Get-CodexAppServerCompatibilitySchemaEvidence -SchemaDirectory $SchemaDirectory
}

function Get-CodexAppServerSerializerExtraRootKeys {
    [CmdletBinding()]
    param([string]$Method = 'thread/start')
    if ([string]$Method -ceq 'thread/resume') {
        return [string[]]@($script:CodexAppServerResumeSerializerExtraKeys)
    }
    return [string[]]@($script:CodexAppServerStartSerializerExtraKeys)
}

function Get-CodexAppServer0147SerializerExtraRootKeys {
    [CmdletBinding()]
    param([string]$Method = 'thread/start')
    return Get-CodexAppServerSerializerExtraRootKeys -Method $Method
}

function New-CodexAppServerFrozenCompatibilityLicense {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CodexVersion)
    $entry = Get-CodexAppServerApprovedCompatibilityEntryByVersion -CodexVersion $CodexVersion
    if ($null -eq $entry) { Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID' }
    return [ordered]@{
        codex_version = [string]$entry.CodexVersion
        schema_fingerprint = [string]$entry.SchemaFingerprint
        schema_file_count = [int]$entry.SchemaFileCount
        schema_bytes = [int64]$entry.SchemaBytes
        service_tier = [string]$script:CodexAppServerServiceTierDefault
    }
}

function New-CodexAppServer0147FrozenCompatibilityLicense {
    [CmdletBinding()]
    param()
    return New-CodexAppServerFrozenCompatibilityLicense -CodexVersion 'codex-cli 0.147.0'
}

function Test-CodexAppServerCompatibilityLicense {
    [CmdletBinding()]
    param([AllowNull()][object]$License)
    return $null -ne (Get-CodexAppServerApprovedCompatibilityEntry -License $License)
}

function Test-CodexAppServer0147CompatibilityLicense {
    [CmdletBinding()]
    param([AllowNull()][object]$License)
    $entry = Get-CodexAppServerApprovedCompatibilityEntry -License $License
    return ($null -ne $entry -and [string]$entry.AdapterRule -ceq 'app-server-v0147')
}

function Test-CodexAppServerSerializerExtraAllowsJsonNull {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Key)
    return $script:CodexAppServerNullableSerializerExtraKeys.Contains([string]$Key)
}

function Test-CodexAppServer0147SerializerExtraAllowsJsonNull {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Key)
    return Test-CodexAppServerSerializerExtraAllowsJsonNull -Key $Key
}

function Set-CodexAppServerTestOwnedCompatibilityLicense {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][AllowNull()][object]$License
    )
    if ($Client -isnot [Collections.IDictionary]) {
        Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID'
    }
    if (-not (Test-CodexAppServerCompatibilityLicense -License $License)) {
        Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID'
    }
    $Client['compatibility_license'] = $License
}

function Test-CodexAppServerResponseCarriesSerializerExtras {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Result,
        [string]$Method = 'thread/start'
    )
    if ($Result -isnot [Collections.IDictionary]) { return $false }
    foreach ($key in @(Get-CodexAppServerSerializerExtraRootKeys -Method $Method)) {
        if ($Result.Contains($key)) { return $true }
    }
    $thread = $null
    if ($Result.Contains('thread')) { $thread = $Result['thread'] }
    if ($thread -isnot [Collections.IDictionary]) { return $false }
    foreach ($key in @($script:CodexAppServerThreadOptionalKeys)) {
        if ($thread.Contains($key)) { return $true }
    }
    return $false
}

function Test-CodexAppServerResponseCarries0147SerializerExtras {
    [CmdletBinding()]
    param([AllowNull()][object]$Result, [string]$Method = 'thread/start')
    return Test-CodexAppServerResponseCarriesSerializerExtras -Result $Result -Method $Method
}

function Get-CodexAppServerCompatibilityLicenseFromClient {
    [CmdletBinding()]
    param([AllowNull()][object]$Client)
    if ($Client -isnot [Collections.IDictionary] -or -not $Client.Contains('compatibility_license')) {
        return $null
    }
    return $Client['compatibility_license']
}

function New-CodexAppServerProfileObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$CodexVersion,
        [Parameter(Mandatory = $true)][object]$Fingerprint
    )
    return [ordered]@{
        protocol_version = $script:CodexAppServerProfileProtocol
        codex_command = [string]$CodexCommand
        codex_version = [string]$CodexVersion
        schema_file_count = [int]$Fingerprint.file_count
        schema_bytes = [int64]$Fingerprint.schema_bytes
        schema_fingerprint = [string]$Fingerprint.fingerprint
        executable_sha256 = (Get-CodexAppServerExecutableSha256 -Path $CodexCommand)
        service_tier = [string]$script:CodexAppServerServiceTierDefault
        bound_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Invoke-CodexAppServerBindProfile {
    [CmdletBinding()]
    param(
        [string]$CodexCommand,
        [string]$OutputPath,
        [switch]$Force
    )
    $exe = Resolve-CodexAppServerExecutable -CodexCommand $CodexCommand
    $version = Get-CodexAppServerVersion -CodexCommand $exe
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tl-app-server-schema-' + [Guid]::NewGuid().ToString('N'))
    try {
        $fingerprint = Invoke-CodexAppServerGenerateSchema -CodexCommand $exe -OutputDirectory $tempRoot
        $profile = New-CodexAppServerProfileObject -CodexCommand $exe -CodexVersion $version -Fingerprint $fingerprint
        $json = ConvertTo-CodexAppServerJson -Value $profile
        Assert-TelephoneJsonSchema -JsonText $json -SchemaName 'codex-app-server-lead-profile' -Label 'Codex app-server Lead profile'
        $identity = $null
        if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
            $full = Get-CodexAppServerCanonicalPath -Path $OutputPath
            Assert-CodexAppServerStateOutsidePackage -StateRoot ([IO.Path]::GetDirectoryName($full))
            if (([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) -and -not $Force) {
                throw 'Profile output already exists; create-new refused.'
            }
            $publication = if ($Force -and ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full))) { 'profile-force-replace' } else { '' }
            $identity = Write-CodexAppServerJsonReplace -Path $full -Value $profile -PublicationPoint $publication
        }
        return [ordered]@{
            profile = $profile
            identity = $identity
            residue = $false
        }
    } finally {
        Remove-CodexAppServerDirectoryNative -Path $tempRoot -Label 'schema temp'
    }
}

function Get-CodexAppServerExecutableSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Assert-CodexAppServerNoReparseChain -Path ([IO.Path]::GetFullPath($Path)) -Label 'Codex executable'
    $bytes = [IO.File]::ReadAllBytes($full)
    return (Get-CodexAppServerSha256Hex -Bytes $bytes)
}

function Get-CodexAppServerCompatibilityIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )
    if ($Profile -isnot [Collections.IDictionary]) { Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID' }
    $identity = Get-TelephoneFileIdentity -Path $ProfilePath
    $tier = Get-CodexAppServerDictString -Dict $Profile -Key 'service_tier'
    if ($tier -cne $script:CodexAppServerServiceTierDefault) { Throw-CodexAppServerPublic -Code 'SERVICE_TIER_INVALID' }
    $command = Get-CodexAppServerDictString -Dict $Profile -Key 'codex_command'
    if ([string]::IsNullOrWhiteSpace($command)) { Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID' }
    return [ordered]@{
        codex_command = Get-CodexAppServerCanonicalPath -Path $command
        codex_version = Get-CodexAppServerDictString -Dict $Profile -Key 'codex_version'
        executable_sha256 = Get-CodexAppServerDictString -Dict $Profile -Key 'executable_sha256'
        profile_fingerprint = Get-CodexAppServerDictString -Dict $Profile -Key 'schema_fingerprint'
        profile_sha256 = [string]$identity.sha256
        service_tier = [string]$script:CodexAppServerServiceTierDefault
    }
}

function Assert-CodexAppServerCompatibilityEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Actual
    )
    if (-not (Test-CodexAppServerCanonicalPathEqual -Left (Get-CodexAppServerDictString -Dict $Expected -Key 'codex_command') -Right (Get-CodexAppServerDictString -Dict $Actual -Key 'codex_command'))) {
        return $false
    }
    foreach ($key in @('codex_version', 'executable_sha256', 'profile_fingerprint', 'profile_sha256', 'service_tier')) {
        if ((Get-CodexAppServerDictString -Dict $Expected -Key $key) -cne (Get-CodexAppServerDictString -Dict $Actual -Key $key)) {
            return $false
        }
    }
    return $true
}

function Write-CodexAppServerValidatedReplace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$SchemaName,
        [string]$PublicationPoint = '',
        [string]$WriterLabel = ''
    )
    $json = ConvertTo-CodexAppServerJson -Value $Value
    try {
        Assert-TelephoneJsonSchema -JsonText $json -SchemaName $SchemaName -Label $SchemaName
    } catch {
        Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
    }
    return (Write-CodexAppServerJsonReplace -Path $Path -Value $Value -PublicationPoint $PublicationPoint -WriterLabel $WriterLabel)
}

function Read-CodexAppServerValidated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SchemaName,
        [string]$Code = 'DURABLE_CHAIN_INVALID'
    )
    try {
        return (Read-TelephoneJson -Path $Path -SchemaName $SchemaName).value
    } catch {
        Throw-CodexAppServerPublic -Code $Code
    }
}

function Clear-CodexAppServerPublishResidue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [string]$FileName = ''
    )
    if (-not [IO.Directory]::Exists($Directory)) { return }
    foreach ($item in [IO.Directory]::GetFiles($Directory)) {
        $name = [IO.Path]::GetFileName($item)
        if (-not [string]::IsNullOrWhiteSpace($FileName)) {
            $tmpPrefix = '.' + $FileName + '.tmp-'
            $bakPrefix = '.' + $FileName + '.bak-'
            if ($name.StartsWith($tmpPrefix, [StringComparison]::Ordinal) -or $name.StartsWith($bakPrefix, [StringComparison]::Ordinal)) {
                try { [IO.File]::Delete($item) } catch { }
            }
            continue
        }
        if ($name.StartsWith('.', [StringComparison]::Ordinal) -and ($name.Contains('.tmp-') -or $name.Contains('.bak-'))) {
            try { [IO.File]::Delete($item) } catch { }
        }
    }
}

function Get-CodexAppServerCallbackWritePhase {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    if (-not [IO.File]::Exists($Paths.run)) { return 'none' }
    $run = $null
    try {
        $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
    } catch {
        Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
    }
    $phase = Get-CodexAppServerDictString -Dict $run -Key 'callback_write_phase'
    if ([string]::IsNullOrWhiteSpace($phase)) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
    if (-not $script:CodexAppServerCallbackWritePhases.Contains($phase)) { Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID' }
    return $phase
}

function Test-CodexAppServerFallbackWindowClosed {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    if ([IO.File]::Exists($Paths.bound_turn) -or [IO.File]::Exists($Paths.ack)) { return $true }
    if (-not [IO.File]::Exists($Paths.run)) { return $false }
    $phase = Get-CodexAppServerCallbackWritePhase -Paths $Paths
    return ($phase -cne 'none')
}

function Get-CodexAppServerSanitizedPending {
    [CmdletBinding()]
    param([AllowNull()][object]$Pending)
    $out = [Collections.Generic.List[object]]::new()
    foreach ($item in (Get-CodexAppServerJsonArrayItems -Value $Pending)) {
        if ($item -isnot [Collections.IDictionary]) { continue }
        $method = Get-CodexAppServerDictString -Dict $item -Key 'method'
        $id = Get-CodexAppServerDictString -Dict $item -Key 'id'
        if (-not $script:CodexAppServerPendingMethods.Contains($method)) { continue }
        if ([string]::IsNullOrWhiteSpace($id) -or $id -notmatch '^[A-Za-z0-9._:-]+$') { continue }
        $out.Add([ordered]@{ method = $method; id = $id })
    }
    return @($out)
}

function New-CodexAppServerFallbackRequiredError {
    [CmdletBinding()]
    param()
    $err = [ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-mismatch-v1'
        fallback_required = 'cli'
        reason = 'installed_schema_or_version_mismatch'
    }
    throw (ConvertTo-CodexAppServerJson -Value $err).TrimEnd()
}

function Assert-CodexAppServerProfileCurrent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][string]$CodexCommand
    )
    if ($Profile -isnot [Collections.IDictionary]) { Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID' }
    $json = ConvertTo-CodexAppServerJson -Value $Profile
    try {
        Assert-TelephoneJsonSchema -JsonText $json -SchemaName 'codex-app-server-lead-profile' -Label 'Codex app-server Lead profile'
    } catch {
        Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID'
    }
    if ([string]$Profile.protocol_version -cne $script:CodexAppServerProfileProtocol) {
        Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID'
    }
    if ((Get-CodexAppServerDictString -Dict $Profile -Key 'service_tier') -cne $script:CodexAppServerServiceTierDefault) {
        Throw-CodexAppServerPublic -Code 'SERVICE_TIER_INVALID'
    }
    if ($null -eq (Get-CodexAppServerApprovedCompatibilityEntry -License $Profile)) {
        New-CodexAppServerFallbackRequiredError
    }
    $fresh = Invoke-CodexAppServerBindProfile -CodexCommand $CodexCommand
    $live = $fresh.profile
    if (-not (Test-CodexAppServerCanonicalPathEqual -Left ([string]$live.codex_command) -Right (Get-CodexAppServerDictString -Dict $Profile -Key 'codex_command')) -or
        [string]$live.codex_version -cne [string]$Profile.codex_version -or
        [string]$live.schema_fingerprint -cne [string]$Profile.schema_fingerprint -or
        [string]$live.executable_sha256 -cne [string]$Profile.executable_sha256 -or
        [int]$live.schema_file_count -ne [int]$Profile.schema_file_count -or
        [int64]$live.schema_bytes -ne [int64]$Profile.schema_bytes -or
        [string]$live.service_tier -cne [string]$Profile.service_tier) {
        New-CodexAppServerFallbackRequiredError
    }
    return $live
}

function Assert-CodexAppServerStablePayload {
    [CmdletBinding()]
    param([AllowNull()][object]$Payload, [string]$Label = 'payload')
    if ($null -eq $Payload) { return }
    if ($Payload -is [string]) {
        if ([string]$Payload -cmatch '"jsonrpc"') { throw "$Label must not include a jsonrpc field." }
        return
    }
    $stack = [Collections.Generic.Stack[object]]::new()
    $stack.Push($Payload)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($node -is [Collections.IDictionary]) {
            foreach ($key in @($node.Keys)) {
                $name = [string]$key
                if ($script:CodexAppServerForbiddenParamKeys.Contains($name)) {
                    throw "$Label uses forbidden experimental or non-stable field $name."
                }
                if ($name -ceq 'experimentalApi' -or (($name -ceq 'capabilities') -and $node[$key] -is [Collections.IDictionary])) {
                    $caps = $node[$key]
                    if ($name -ceq 'experimentalApi' -and [bool]$node[$key] -eq $true) {
                        throw "$Label must not enable experimentalApi."
                    }
                    if ($caps -is [Collections.IDictionary] -and $caps.Contains('experimentalApi') -and [bool]$caps['experimentalApi'] -eq $true) {
                        throw "$Label must not enable experimentalApi."
                    }
                }
                if ($null -ne $node[$key]) { $stack.Push($node[$key]) }
            }
            continue
        }
        if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
            foreach ($item in @($node)) { if ($null -ne $item) { $stack.Push($item) } }
        }
    }
}

function Assert-CodexAppServerListenStdioOnly {
    [CmdletBinding()]
    param([AllowEmptyCollection()][AllowNull()][string[]]$Arguments)
    $tokens = @($Arguments | ForEach-Object { [string]$_ })
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        if ($token -match '^(ws|wss|unix|http|https):') {
            throw 'Codex app-server listen target must be stdio-only.'
        }
        if ($token -ceq '--listen' -and ($i + 1) -lt $tokens.Count) {
            $target = [string]$tokens[$i + 1]
            if ($target -cne 'stdio://') {
                throw 'Codex app-server listen target must be stdio://.'
            }
        }
        if ($token.StartsWith('--listen=', [StringComparison]::Ordinal)) {
            $target = $token.Substring('--listen='.Length)
            if ($target -cne 'stdio://') {
                throw 'Codex app-server listen target must be stdio://.'
            }
        }
    }
}

function Assert-CodexAppServerRunId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RunId)
    $id = [string]$RunId
    if ([string]::IsNullOrWhiteSpace($id) -or $id -notmatch '^[A-Za-z0-9._:-]+$') {
        Throw-CodexAppServerPublic -Code 'RUN_ID_INVALID'
    }
    if ($id.Contains('..')) { Throw-CodexAppServerPublic -Code 'RUN_ID_INVALID' }
}

function Assert-CodexAppServerStateOutsidePackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateRoot)
    Assert-CodexAppServerPathOutsidePackage -Path $StateRoot
}

function Assert-CodexAppServerBindingOutputPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BindingOutputPath)
    if ([string]::IsNullOrWhiteSpace($BindingOutputPath)) { Throw-CodexAppServerPublic -Code 'FILESYSTEM_INVALID' }
    $full = [IO.Path]::GetFullPath($BindingOutputPath)
    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($parent)) { Throw-CodexAppServerPublic -Code 'FILESYSTEM_INVALID' }
    $ancestor = Get-CodexAppServerNearestExistingAncestor -Path $full
    $null = Assert-CodexAppServerNoReparseChain -Path $ancestor -Label 'Binding output ancestor'
    Assert-CodexAppServerPathOutsidePackage -Path $full
    Assert-CodexAppServerStateOutsidePackage -StateRoot $parent
    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        $null = Assert-CodexAppServerNoReparseChain -Path $full -Label 'Binding output'
    }
    return $full
}

function Get-CodexAppServerRunPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    Assert-CodexAppServerRunId -RunId $RunId
    $root = Assert-CodexAppServerNoReparseChain -Path ([IO.Path]::GetFullPath($StateRoot)) -Label 'State root'
    Assert-CodexAppServerStateOutsidePackage -StateRoot $root
    $runsDir = [IO.Path]::GetFullPath((Join-Path $root 'runs'))
    $runsParent = [IO.Path]::GetDirectoryName($runsDir)
    if (-not $runsParent.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CodexAppServerPublic -Code 'STATE_CONTAINMENT_INVALID'
    }
    if ([IO.Directory]::Exists($runsDir) -or [IO.File]::Exists($runsDir)) {
        $null = Assert-CodexAppServerNoReparseChain -Path $runsDir -Label 'Runs directory'
    }
    $runRoot = [IO.Path]::GetFullPath((Join-Path $runsDir $RunId))
    $parent = [IO.Path]::GetDirectoryName($runRoot)
    if (-not $parent.Equals($runsDir, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CodexAppServerPublic -Code 'STATE_CONTAINMENT_INVALID'
    }
    $leaf = [IO.Path]::GetFileName($runRoot)
    if ($leaf -cne $RunId) { Throw-CodexAppServerPublic -Code 'STATE_CONTAINMENT_INVALID' }
    $prefix = $root.TrimEnd('\') + '\'
    if (-not ($runRoot + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CodexAppServerPublic -Code 'STATE_CONTAINMENT_INVALID'
    }
    if ([IO.Directory]::Exists($runRoot) -or [IO.File]::Exists($runRoot)) {
        $null = Assert-CodexAppServerNoReparseChain -Path $runRoot -Label 'Run root'
    }
    return [ordered]@{
        state_root = $root
        run_root = $runRoot
        gate = Join-Path $runRoot 'gate.lock'
        owner = Join-Path $runRoot 'owner.json'
        child = Join-Path $runRoot 'child.json'
        intent = Join-Path $runRoot 'intent.json'
        run = Join-Path $runRoot 'run.json'
        bound_turn = Join-Path $runRoot 'bound-turn.json'
        transitions = Join-Path $runRoot 'transitions.jsonl'
        status = Join-Path $runRoot 'status.json'
        ack = Join-Path $runRoot 'lead-wake-ack.json'
        final = Join-Path $runRoot 'launcher-final.txt'
        recovery = Join-Path $runRoot 'recovery.json'
        result = Join-Path $runRoot 'launcher-result.json'
        failure = Join-Path $runRoot 'failure.json'
        stderr_evidence = Join-Path $runRoot 'stderr-evidence.json'
        read_lifetime = Join-Path $runRoot 'read-lifetime.json'
        lifecycle_owner = Join-Path $runRoot 'lifecycle-owner.json'
        store = Join-Path $root 'app-server-store.json'
        profile = Join-Path $root 'profile.json'
    }
}

function Assert-CodexAppServerThreadId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ThreadId)
    $id = [string]$ThreadId
    if ([string]::IsNullOrWhiteSpace($id) -or $id -notmatch '^[A-Za-z0-9._:-]+$') {
        Throw-CodexAppServerPublic -Code 'THREAD_ID_INVALID'
    }
    if ($id.Contains('..')) { Throw-CodexAppServerPublic -Code 'THREAD_ID_INVALID' }
}

function Get-CodexAppServerThreadPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ThreadId
    )
    Assert-CodexAppServerThreadId -ThreadId $ThreadId
    $root = Assert-CodexAppServerNoReparseChain -Path ([IO.Path]::GetFullPath($StateRoot)) -Label 'State root'
    Assert-CodexAppServerStateOutsidePackage -StateRoot $root
    $threadsDir = [IO.Path]::GetFullPath((Join-Path $root 'threads'))
    $threadsParent = [IO.Path]::GetDirectoryName($threadsDir)
    if (-not $threadsParent.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CodexAppServerPublic -Code 'STATE_CONTAINMENT_INVALID'
    }
    if ([IO.Directory]::Exists($threadsDir) -or [IO.File]::Exists($threadsDir)) {
        $null = Assert-CodexAppServerNoReparseChain -Path $threadsDir -Label 'Threads directory'
    }
    $threadRoot = [IO.Path]::GetFullPath((Join-Path $threadsDir $ThreadId))
    $parent = [IO.Path]::GetDirectoryName($threadRoot)
    if (-not $parent.Equals($threadsDir, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CodexAppServerPublic -Code 'STATE_CONTAINMENT_INVALID'
    }
    $leaf = [IO.Path]::GetFileName($threadRoot)
    if ($leaf -cne $ThreadId) { Throw-CodexAppServerPublic -Code 'STATE_CONTAINMENT_INVALID' }
    $prefix = $root.TrimEnd('\') + '\'
    if (-not ($threadRoot + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CodexAppServerPublic -Code 'STATE_CONTAINMENT_INVALID'
    }
    if ([IO.Directory]::Exists($threadRoot) -or [IO.File]::Exists($threadRoot)) {
        $null = Assert-CodexAppServerNoReparseChain -Path $threadRoot -Label 'Thread root'
    }
    return [ordered]@{
        state_root = $root
        thread_id = [string]$ThreadId
        thread_root = $threadRoot
        gate = Join-Path $threadRoot 'gate.lock'
        owner = Join-Path $threadRoot 'owner.json'
        store = Join-Path $root 'app-server-store.json'
        profile = Join-Path $root 'profile.json'
        runs = Join-Path $root 'runs'
    }
}

function Get-CodexAppServerOwnerIdleMilliseconds {
    [CmdletBinding()]
    param()
    $raw = [string][Environment]::GetEnvironmentVariable('TELEPHONE_TEST_APP_SERVER_OWNER_IDLE_MS')
    if ([string]::IsNullOrWhiteSpace($raw)) { return 15000 }
    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed) -or $parsed -lt 50) { return 15000 }
    if ($parsed -gt 120000) { return 120000 }
    return $parsed
}

function Get-CodexAppServerAckTimeoutSeconds {
    [CmdletBinding()]
    param()
    $raw = [string][Environment]::GetEnvironmentVariable('TELEPHONE_TEST_APP_SERVER_ACK_TIMEOUT_SECONDS')
    if ([string]::IsNullOrWhiteSpace($raw)) { return 60 }
    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed) -or $parsed -lt 1) { return 60 }
    if ($parsed -gt 120) { return 120 }
    return $parsed
}

function Get-CodexAppServerObservedCallbackState {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Run,
        [AllowNull()][object]$Paths,
        [bool]$OwnerAlive = $false
    )
    $disposition = ''
    $phase = 'none'
    $queueState = ''
    if ($Run -is [Collections.IDictionary]) {
        $disposition = Get-CodexAppServerDictString -Dict $Run -Key 'disposition'
        $phase = Get-CodexAppServerDictString -Dict $Run -Key 'callback_write_phase'
        $queueState = Get-CodexAppServerDictString -Dict $Run -Key 'queue_state'
    }
    $hasFailure = $false
    if ($null -ne $Paths -and $Paths -is [Collections.IDictionary] -and $Paths.Contains('failure')) {
        $hasFailure = [IO.File]::Exists([string]$Paths.failure)
    }
    if ($disposition -ceq 'recovery_required') { return 'recovery_required' }
    if ($disposition -ceq 'failed' -or $disposition -ceq 'interrupted' -or ($hasFailure -and $phase -ceq 'none' -and -not $OwnerAlive)) { return 'failed' }
    if ($disposition -ceq 'completed' -and $phase -ceq 'terminal') { return 'completed' }
    if ($disposition -ceq 'recovered') { return 'recovered' }
    if (($queueState -ceq 'queued' -or [string]::IsNullOrWhiteSpace($queueState)) -and ($phase -ceq 'none' -or [string]::IsNullOrWhiteSpace($phase))) { return 'queued' }
    if ($OwnerAlive -or $queueState -ceq 'callback_active' -or ($phase -cne 'none' -and $phase -cne 'terminal')) { return 'callback_active' }
    if ($queueState -ceq 'queued' -or $phase -ceq 'none') { return 'queued' }
    if ($queueState -ceq 'retired' -and $phase -ceq 'terminal') {
        if ($disposition -ceq 'completed') { return 'completed' }
        if ($disposition -ceq 'failed' -or $disposition -ceq 'interrupted') { return 'failed' }
    }
    return 'queued'
}

function Add-CodexAppServerTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$State
    )
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $line = (([ordered]@{
        at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        state = [string]$State
    } | ConvertTo-Json -Compress) + "`n")
    [IO.File]::AppendAllText($Path, $line, [Text.UTF8Encoding]::new($false))
}

function Invoke-CodexAppServerAbortProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reason)
    try {
        if ($null -eq ('CodexAppServerNativeErrorMode' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CodexAppServerNativeErrorMode {
    [DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint uMode);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);
}
"@
        }
        [void][CodexAppServerNativeErrorMode]::SetErrorMode(0x8003)
    } catch { }
    [Environment]::FailFast([string]$Reason)
}

function Disable-CodexAppServerHandleInherit {
    [CmdletBinding()]
    param([AllowNull()][object]$FileStream)
    if ($null -eq $FileStream) { return }
    try {
        if ($null -eq ('CodexAppServerNativeErrorMode' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CodexAppServerNativeErrorMode {
    [DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint uMode);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);
}
"@
        }
        $raw = $FileStream.SafeFileHandle.DangerousGetHandle()
        [void][CodexAppServerNativeErrorMode]::SetHandleInformation($raw, 1, 0)
    } catch { }
}

function Get-CodexAppServerInjectedCrashWanted {
    [CmdletBinding()]
    param()
    $points = [Collections.Generic.List[string]]::new()
    foreach ($name in @('TELEPHONE_TEST_APP_SERVER_PUBLISH_CRASH_AT', 'TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT')) {
        $value = [string][Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { $points.Add($value) }
    }
    return @($points)
}

function Test-CodexAppServerInjectedCrashMatch {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Point)
    foreach ($wanted in @(Get-CodexAppServerInjectedCrashWanted)) {
        if ([string]$wanted -ceq $Point) { return $true }
    }
    return $false
}

function Invoke-CodexAppServerInjectedCrash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Point)
    if (Test-CodexAppServerInjectedCrashMatch -Point $Point) {
        Invoke-CodexAppServerAbortProcess -Reason ('injected crash at ' + $Point)
    }
}

function Invoke-CodexAppServerWriterScopedCrash {
    [CmdletBinding()]
    param(
        [string]$WriterLabel = '',
        [Parameter(Mandatory = $true)][string]$Cut
    )
    if (-not [string]::IsNullOrWhiteSpace($WriterLabel)) {
        Invoke-CodexAppServerInjectedCrash -Point ($WriterLabel + ':' + $Cut)
        return
    }
    Invoke-CodexAppServerInjectedCrash -Point $Cut
}

function Invoke-CodexAppServerPublishCrash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Point)
    Invoke-CodexAppServerInjectedCrash -Point $Point
}

function Write-CodexAppServerJsonReplace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value,
        [string]$PublicationPoint = '',
        [string]$WriterLabel = ''
    )
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($parent)) { Throw-CodexAppServerPublic -Code 'FILESYSTEM_INVALID' }
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    Clear-CodexAppServerPublishResidue -Directory $parent -FileName ([IO.Path]::GetFileName($full))
    $null = Assert-CodexAppServerNoReparseChain -Path $parent -Label 'Durable parent'
    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        $null = Assert-CodexAppServerNoReparseChain -Path $full -Label 'Durable record'
    }
    $label = [string]$WriterLabel
    if ([string]::IsNullOrWhiteSpace($label)) { $label = [string]$PublicationPoint }
    $json = ConvertTo-CodexAppServerJson -Value $Value
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $tmp = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    $backup = $null
    try {
        $stream = [IO.FileStream]::new($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        Invoke-CodexAppServerWriterScopedCrash -WriterLabel $label -Cut 'after-temp-flush'
        Invoke-CodexAppServerWriterScopedCrash -WriterLabel $label -Cut 'before-replace'
        if ([IO.File]::Exists($full)) {
            $backup = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.bak-' + [Guid]::NewGuid().ToString('N'))
            [IO.File]::Replace($tmp, $full, $backup)
        } else {
            [IO.File]::Move($tmp, $full)
        }
        Invoke-CodexAppServerWriterScopedCrash -WriterLabel $label -Cut 'after-replace'
        $published = [IO.FileStream]::new($full, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $published.Flush($true)
        } finally {
            $published.Dispose()
        }
        Invoke-CodexAppServerWriterScopedCrash -WriterLabel $label -Cut 'durable-publication'
        if (-not [string]::IsNullOrWhiteSpace($PublicationPoint)) {
            Invoke-CodexAppServerPublishCrash -Point $PublicationPoint
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($backup) -and [IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
    return Get-TelephoneFileIdentity -Path $full
}

function Write-CodexAppServerTextReplace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$PublicationPoint = '',
        [string]$WriterLabel = ''
    )
    $doc = [ordered]@{ text = [string]$Text }
    $json = ConvertTo-CodexAppServerJson -Value $doc
    $null = $json
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($parent)) { Throw-CodexAppServerPublic -Code 'FILESYSTEM_INVALID' }
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    Clear-CodexAppServerPublishResidue -Directory $parent -FileName ([IO.Path]::GetFileName($full))
    $null = Assert-CodexAppServerNoReparseChain -Path $parent -Label 'Durable parent'
    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        $null = Assert-CodexAppServerNoReparseChain -Path $full -Label 'Durable record'
    }
    $label = [string]$WriterLabel
    if ([string]::IsNullOrWhiteSpace($label)) { $label = [string]$PublicationPoint }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $tmp = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    $backup = $null
    try {
        $stream = [IO.FileStream]::new($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        Invoke-CodexAppServerWriterScopedCrash -WriterLabel $label -Cut 'after-temp-flush'
        Invoke-CodexAppServerWriterScopedCrash -WriterLabel $label -Cut 'before-replace'
        if ([IO.File]::Exists($full)) {
            $backup = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.bak-' + [Guid]::NewGuid().ToString('N'))
            [IO.File]::Replace($tmp, $full, $backup)
        } else {
            [IO.File]::Move($tmp, $full)
        }
        Invoke-CodexAppServerWriterScopedCrash -WriterLabel $label -Cut 'after-replace'
        $published = [IO.FileStream]::new($full, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $published.Flush($true)
        } finally {
            $published.Dispose()
        }
        Invoke-CodexAppServerWriterScopedCrash -WriterLabel $label -Cut 'durable-publication'
        if (-not [string]::IsNullOrWhiteSpace($PublicationPoint)) {
            Invoke-CodexAppServerPublishCrash -Point $PublicationPoint
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($backup) -and [IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
    return Get-TelephoneFileIdentity -Path $full
}

function New-CodexAppServerOwnerRecord {
    [CmdletBinding()]
    param(
        [string]$ThreadId = '',
        [string]$ActiveRunId = ''
    )
    $self = Get-Process -Id $PID
    try {
        $doc = [ordered]@{
            protocol_version = 'telephone-line-codex-app-server-lead-owner-v1'
            pid = [int]$PID
            start_time_utc_ticks = [int64]$self.StartTime.ToUniversalTime().Ticks
            started_at_utc = $self.StartTime.ToUniversalTime().ToString('o')
        }
        if (-not [string]::IsNullOrWhiteSpace($ThreadId)) { $doc.thread_id = [string]$ThreadId }
        if (-not [string]::IsNullOrWhiteSpace($ActiveRunId)) { $doc.active_run_id = [string]$ActiveRunId }
        return $doc
    } finally {
        $self.Dispose()
    }
}

function Write-CodexAppServerProjectedStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ThreadId = '',
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowEmptyCollection()][string[]]$ActiveFlags,
        [AllowEmptyCollection()][object[]]$Pending,
        [string]$CallbackOwnerState = ''
    )
    $flags = @()
    if ($null -ne $ActiveFlags) { $flags = @($ActiveFlags | ForEach-Object { [string]$_ } | Where-Object { $_ -ceq 'waitingOnApproval' -or $_ -ceq 'waitingOnUserInput' }) }
    $pendingOut = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Pending)) {
        if ($item -isnot [Collections.IDictionary]) { continue }
        $method = Get-CodexAppServerDictString -Dict $item -Key 'method'
        $id = Get-CodexAppServerDictString -Dict $item -Key 'id'
        if ([string]::IsNullOrWhiteSpace($method) -or [string]::IsNullOrWhiteSpace($id)) { continue }
        if (-not $script:CodexAppServerPendingMethods.Contains($method)) { continue }
        $pendingOut.Add([ordered]@{ method = $method; id = $id })
    }
    $doc = [ordered]@{
        protocol_version = $script:CodexAppServerStatusProtocol
        thread_id = [string]$ThreadId
        status = [string]$Status
        active_flags = @($flags)
        pending = @($pendingOut)
        started = $false
        mutated = $false
        observed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if (-not [string]::IsNullOrWhiteSpace($CallbackOwnerState)) {
        $doc.callback_owner_state = [string]$CallbackOwnerState
    }
    $json = ConvertTo-CodexAppServerJson -Value $doc
    Assert-TelephoneJsonSchema -JsonText $json -SchemaName 'codex-app-server-lead-status' -Label 'Codex app-server Lead status'
    return Write-CodexAppServerJsonReplace -Path $Path -Value $doc
}

function ConvertTo-CodexAppServerProjectedStatus {
    [CmdletBinding()]
    param([AllowNull()][object]$StatusNode)
    $invalid = [ordered]@{
        valid = $false
        status = 'notLoaded'
        active_flags = @()
    }
    if ($StatusNode -isnot [Collections.IDictionary]) { return $invalid }
    $keys = @($StatusNode.Keys | ForEach-Object { [string]$_ })
    foreach ($key in $keys) {
        if ($key -cne 'type' -and $key -cne 'activeFlags') { return $invalid }
    }
    $type = Get-CodexAppServerDictString -Dict $StatusNode -Key 'type'
    if (-not $script:CodexAppServerThreadStatusAllowlist.Contains($type)) { return $invalid }
    $outFlags = [Collections.Generic.List[string]]::new()
    if ($type -ceq 'active') {
        if (-not $StatusNode.Contains('activeFlags')) { return $invalid }
        $flags = Get-CodexAppServerDictObject -Dict $StatusNode -Key 'activeFlags'
        foreach ($flag in (Get-CodexAppServerStringRecords -Value $flags)) {
            $name = [string]$flag
            if ($name -cne 'waitingOnApproval' -and $name -cne 'waitingOnUserInput') { return $invalid }
            if ($outFlags -notcontains $name) { $outFlags.Add($name) }
        }
    } elseif ($StatusNode.Contains('activeFlags')) {
        return $invalid
    }
    return [ordered]@{
        valid = $true
        status = $type
        active_flags = @($outFlags)
    }
}

function Get-CodexAppServerThreadIdFromObject {
    [CmdletBinding()]
    param([AllowNull()][object]$Thread)
    if ($Thread -isnot [Collections.IDictionary]) { return '' }
    return (Get-CodexAppServerDictString -Dict $Thread -Key 'id')
}

function Get-CodexAppServerTurnIdsFromThread {
    [CmdletBinding()]
    param([AllowNull()][object]$Thread)
    $ids = [Collections.Generic.List[string]]::new()
    if ($Thread -isnot [Collections.IDictionary]) { return [string[]]@($ids) }
    $turns = Get-CodexAppServerDictObject -Dict $Thread -Key 'turns'
    foreach ($turn in (Get-CodexAppServerJsonArrayItems -Value $turns)) {
        if ($turn -isnot [Collections.IDictionary]) { continue }
        $id = Get-CodexAppServerDictString -Dict $turn -Key 'id'
        if (-not [string]::IsNullOrWhiteSpace($id)) { $ids.Add($id) }
    }
    Write-Output -NoEnumerate -InputObject ([string[]]@($ids))
}

function Get-CodexAppServerItemTextBlob {
    [CmdletBinding()]
    param([AllowNull()][object]$Node)
    $parts = [Collections.Generic.List[string]]::new()
    $stack = [Collections.Generic.Stack[object]]::new()
    if ($null -ne $Node) { $stack.Push($Node) }
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        if ($item -is [string]) {
            if (-not [string]::IsNullOrEmpty($item)) { $parts.Add($item) }
            continue
        }
        if ($item -is [Collections.IDictionary]) {
            foreach ($key in @($item.Keys)) {
                if ($null -ne $item[$key]) { $stack.Push($item[$key]) }
            }
            continue
        }
        if ($item -is [System.Collections.IEnumerable] -and $item -isnot [byte[]]) {
            foreach ($child in @($item)) { if ($null -ne $child) { $stack.Push($child) } }
        }
    }
    return [string]::Join("`n", $parts)
}

function Find-CodexAppServerMatchingTurns {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Thread,
        [Parameter(Mandatory = $true)][string]$Marker,
        [AllowEmptyCollection()][string[]]$BaselineTurnIds
    )
    $baseline = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in @($BaselineTurnIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) { [void]$baseline.Add([string]$id) }
    }
    $matches = [Collections.Generic.List[object]]::new()
    $unexplained = [Collections.Generic.List[string]]::new()
    if ($Thread -isnot [Collections.IDictionary]) {
        return [ordered]@{ matches = @(); unexplained = @() }
    }
    foreach ($turn in @(Get-CodexAppServerDictObject -Dict $Thread -Key 'turns')) {
        if ($turn -isnot [Collections.IDictionary]) { continue }
        $turnId = Get-CodexAppServerDictString -Dict $turn -Key 'id'
        $blob = Get-CodexAppServerItemTextBlob -Node $turn
        $hasMarker = Test-CodexAppServerTextHasMarker -Text $blob -Marker $Marker
        if ($hasMarker) {
            $matches.Add([ordered]@{ turn_id = $turnId; turn = $turn })
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($turnId) -and -not $baseline.Contains($turnId)) {
            $unexplained.Add($turnId)
        }
    }
    return [ordered]@{
        matches = @($matches)
        unexplained = @($unexplained)
    }
}

function New-CodexAppServerClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [string]$StorePath = '',
        [int]$ReadTimeoutMilliseconds = 20000
    )
    Assert-CodexAppServerListenStdioOnly -Arguments @('app-server', '--listen', 'stdio://')
    $info = New-CodexAppServerProcessStartInfo -CodexCommand $CodexCommand -Arguments @(
        'app-server', '--listen', 'stdio://'
    ) -WorkingDirectory $WorkingDirectory -RedirectStdio
    if (-not [string]::IsNullOrWhiteSpace($StorePath)) {
        $info.Environment['TELEPHONE_APP_SERVER_THREAD_STORE'] = [IO.Path]::GetFullPath($StorePath)
    }
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw 'Codex app-server process failed to start.' }
    $child = [ordered]@{
        pid = [int]$process.Id
        start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks
        started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
    }
    return [ordered]@{
        process = $process
        child = $child
        pending = [Collections.Generic.List[object]]::new()
        last_status = [ordered]@{ status = 'notLoaded'; active_flags = @() }
        read_timeout_ms = [int]$ReadTimeoutMilliseconds
        stderr = New-Object 'System.Collections.Generic.List[string]'
    }
}

function Stop-CodexAppServerClient {
    [CmdletBinding()]
    param([AllowNull()][object]$Client)
    if ($null -eq $Client -or $null -eq $Client.process) { return }
    $process = $Client.process
    try {
        try {
            if ($null -ne $process.StandardInput) { $process.StandardInput.Close() }
        } catch { }
        if (-not $process.HasExited) {
            if (-not $process.WaitForExit(2000)) {
                try { $process.Kill($true) } catch { }
                $null = $process.WaitForExit(2000)
            }
        }
    } finally {
        $process.Dispose()
        $Client.process = $null
    }
}

function Write-CodexAppServerReadLifetime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Client
    )
    $concurrent = 0
    $reused = 0
    $accepted = $false
    if ($Client.Contains('stdout_concurrent_starts')) { $concurrent = [int]$Client.stdout_concurrent_starts }
    if ($Client.Contains('stdout_read_reused')) { $reused = [int]$Client.stdout_read_reused }
    if ($Client.Contains('accepted_turn_read')) { $accepted = [bool]$Client.accepted_turn_read }
    $former = 0
    [void][int]::TryParse([string]$env:TELEPHONE_TEST_APP_SERVER_FORMER_READ_TIMEOUT_MS, [ref]$former)
    $null = Write-CodexAppServerJsonReplace -Path $Path -Value ([ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-read-lifetime-v1'
        concurrent_stdout_read_starts = [int]$concurrent
        outstanding_read_reused = [int]$reused
        accepted_turn_unbounded = [bool]$accepted
        absolute_task_timeout = $false
        former_threshold_ms = [int]$former
    })
}

function Enable-CodexAppServerAcceptedTurnRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [string]$ThreadId = '',
        [string]$TurnId = '',
        [string]$EvidencePath = ''
    )
    $Client.accepted_turn_read = $true
    $Client.read_timeout_ms = 0
    if (-not [string]::IsNullOrWhiteSpace($ThreadId)) { $Client.bound_thread_id = [string]$ThreadId }
    if (-not [string]::IsNullOrWhiteSpace($TurnId)) { $Client.bound_turn_id = [string]$TurnId }
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        Write-CodexAppServerReadLifetime -Path $EvidencePath -Client $Client
    }
}

function Read-CodexAppServerRawMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Client)
    $process = $Client.process
    if ($null -eq $process) { throw 'Codex app-server process is not running.' }
    if (-not $Client.Contains('stdout_read_task')) { $Client.stdout_read_task = $null }
    if (-not $Client.Contains('stdout_concurrent_starts')) { $Client.stdout_concurrent_starts = 0 }
    if (-not $Client.Contains('stdout_read_reused')) { $Client.stdout_read_reused = 0 }
    if (-not $Client.Contains('accepted_turn_read')) { $Client.accepted_turn_read = $false }
    $outstanding = $Client.stdout_read_task
    if ($null -ne $outstanding -and -not $outstanding.IsCompleted) {
        $Client.stdout_read_reused = [int]$Client.stdout_read_reused + 1
    } else {
        if ($null -ne $outstanding -and -not $outstanding.IsCompleted) {
            $Client.stdout_concurrent_starts = [int]$Client.stdout_concurrent_starts + 1
            throw 'Codex app-server stdout already has an outstanding read.'
        }
        $Client.stdout_read_task = $process.StandardOutput.ReadLineAsync()
    }
    $task = $Client.stdout_read_task
    $unbounded = $false
    if ($Client.Contains('accepted_turn_read') -and [bool]$Client.accepted_turn_read) { $unbounded = $true }
    $timeoutMs = 60000
    if ($Client.Contains('read_timeout_ms')) { $timeoutMs = [int]$Client.read_timeout_ms }
    if ($unbounded -or $timeoutMs -le 0) {
        $null = $task.Wait([Threading.Timeout]::Infinite)
    } else {
        if (-not $task.Wait($timeoutMs)) {
            if ($process.HasExited) {
                $null = $task.Wait(5000)
                if (-not $task.IsCompleted) { throw 'Codex app-server stdio closed.' }
            } else {
                throw 'Codex app-server stdio read timed out.'
            }
        }
    }
    $raw = $null
    try {
        $raw = $task.GetAwaiter().GetResult()
    } finally {
        $Client.stdout_read_task = $null
    }
    if ($null -eq $raw) { throw 'Codex app-server stdio closed.' }
    $line = [string]$raw
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    $record = $line | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    if ($record -isnot [Collections.IDictionary]) { throw 'Codex app-server emitted a non-object line.' }
    if ($record.Contains('jsonrpc')) { throw 'Codex app-server message included a jsonrpc field.' }
    return $record
}

function Send-CodexAppServerRawMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][object]$Message
    )
    Assert-CodexAppServerStablePayload -Payload $Message -Label 'outbound app-server message'
    if ($Message -is [Collections.IDictionary] -and $Message.Contains('jsonrpc')) {
        throw 'Outbound app-server message must not include jsonrpc.'
    }
    $process = $Client.process
    if ($null -eq $process -or $null -eq $process.StandardInput) {
        throw 'Codex app-server process is not running.'
    }
    $json = (ConvertTo-Json -InputObject $Message -Depth 64 -Compress).Replace("`r`n", "`n")
    $process.StandardInput.WriteLine($json)
    $process.StandardInput.Flush()
}

function Invoke-CodexAppServerRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$Method,
        [AllowNull()][object]$Params
    )
    if (-not $script:CodexAppServerAllowedMethods.Contains($Method) -and $Method -cne 'initialize') {
        throw "Method $Method is not in the stable allowlist."
    }
    Assert-CodexAppServerStablePayload -Payload $Params -Label $Method
    $requestId = [Guid]::NewGuid().ToString('D')
    $message = [ordered]@{
        id = $requestId
        method = $Method
    }
    if ($null -ne $Params) { $message.params = $Params }
    Send-CodexAppServerRawMessage -Client $Client -Message $message
    return Receive-CodexAppServerUntilResponse -Client $Client -RequestId $requestId
}

function Send-CodexAppServerNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$Method,
        [AllowNull()][object]$Params
    )
    $message = [ordered]@{ method = $Method }
    if ($null -ne $Params) { $message.params = $Params }
    Send-CodexAppServerRawMessage -Client $Client -Message $message
}

function Initialize-CodexAppServerSession {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Client)
    $params = [ordered]@{
        clientInfo = [ordered]@{
            name = $script:CodexAppServerClientName
            title = $script:CodexAppServerClientTitle
            version = $script:CodexAppServerClientVersion
        }
        capabilities = [ordered]@{
            experimentalApi = $false
        }
    }
    $null = Invoke-CodexAppServerRequest -Client $Client -Method 'initialize' -Params $params
    Send-CodexAppServerNotification -Client $Client -Method 'initialized' -Params $null
}

function Get-CodexAppServerThreadFromResult {
    [CmdletBinding()]
    param([AllowNull()][object]$Result)
    if ($Result -isnot [Collections.IDictionary] -or -not $Result.Contains('thread')) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    return $Result.thread
}

function Assert-CodexAppServerSandboxShape {
    [CmdletBinding()]
    param([AllowNull()][object]$Sandbox)
    if ($Sandbox -isnot [Collections.IDictionary] -or -not $Sandbox.Contains('type')) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    $type = Get-CodexAppServerDictString -Dict $Sandbox -Key 'type'
    if ($type -ceq 'dangerFullAccess') {
        Assert-CodexAppServerExactKeys -Dict $Sandbox -Required @('type') -Allowed @('type')
        return
    }
    if ($type -ceq 'readOnly') {
        Assert-CodexAppServerExactKeys -Dict $Sandbox -Required @('type', 'networkAccess') -Allowed @('type', 'networkAccess')
        return
    }
    if ($type -ceq 'externalSandbox') {
        Assert-CodexAppServerExactKeys -Dict $Sandbox -Required @('type', 'networkAccess') -Allowed @('type', 'networkAccess')
        return
    }
    if ($type -ceq 'workspaceWrite') {
        Assert-CodexAppServerExactKeys -Dict $Sandbox -Required @('type', 'writableRoots', 'networkAccess', 'excludeTmpdirEnvVar', 'excludeSlashTmp') -Allowed @('type', 'writableRoots', 'networkAccess', 'excludeTmpdirEnvVar', 'excludeSlashTmp')
        return
    }
    Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
}

function Assert-CodexAppServerThreadProjection {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Thread,
        [string]$ExpectedId = '',
        [AllowNull()][object]$CompatibilityLicense = $null
    )
    Assert-CodexAppServerExactKeys -Dict $Thread -Required $script:CodexAppServerThreadKeys -Allowed (Get-CodexAppServerCombinedExactKeys -Required $script:CodexAppServerThreadKeys -Optional $script:CodexAppServerThreadOptionalKeys)
    Assert-CodexAppServerOptionalThreadFields -Thread $Thread -CompatibilityLicense $CompatibilityLicense
    $id = Get-CodexAppServerDictString -Dict $Thread -Key 'id'
    if ([string]::IsNullOrWhiteSpace($id)) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedId) -and $id -cne $ExpectedId) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    $cwd = Get-CodexAppServerDictString -Dict $Thread -Key 'cwd'
    if ([string]::IsNullOrWhiteSpace($cwd)) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
    $projected = ConvertTo-CodexAppServerProjectedStatus -StatusNode (Get-CodexAppServerDictObject -Dict $Thread -Key 'status')
    if (-not [bool]$projected.valid) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
    $turns = Get-CodexAppServerDictObject -Dict $Thread -Key 'turns'
    if (-not (Test-CodexAppServerJsonArray -Value $turns)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    foreach ($turn in (Get-CodexAppServerJsonArrayItems -Value $turns)) {
        $null = Assert-CodexAppServerTurnProjection -Turn $turn
    }
    return $id
}

function Assert-CodexAppServerTurnProjection {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Turn,
        [string]$ExpectedId = ''
    )
    Assert-CodexAppServerExactKeys -Dict $Turn -Required $script:CodexAppServerTurnKeys -Allowed $script:CodexAppServerTurnKeys
    $id = Get-CodexAppServerDictString -Dict $Turn -Key 'id'
    if ([string]::IsNullOrWhiteSpace($id)) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedId) -and $id -cne $ExpectedId) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    $status = Get-CodexAppServerDictString -Dict $Turn -Key 'status'
    if ([string]::IsNullOrWhiteSpace($status) -or -not $script:CodexAppServerTurnStatusAllowlist.Contains($status)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    $view = Get-CodexAppServerDictString -Dict $Turn -Key 'itemsView'
    if ([string]::IsNullOrWhiteSpace($view) -or -not $script:CodexAppServerTurnItemsViewAllowlist.Contains($view)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    $items = Get-CodexAppServerDictObject -Dict $Turn -Key 'items'
    if (-not (Test-CodexAppServerJsonArray -Value $items)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    $error = Get-CodexAppServerDictObject -Dict $Turn -Key 'error'
    if (-not (Test-CodexAppServerJsonNull -Value $error) -and $error -isnot [Collections.IDictionary]) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    foreach ($stamp in @('startedAt', 'completedAt', 'durationMs')) {
        $value = Get-CodexAppServerDictObject -Dict $Turn -Key $stamp
        if (-not (Test-CodexAppServerJsonNull -Value $value) -and -not (Test-CodexAppServerJsonNumber -Value $value)) {
            Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
        }
    }
    return $id
}

function Assert-CodexAppServerOptionalStartResumeFields {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Result,
        [string]$Method = 'thread/start',
        [AllowNull()][object]$CompatibilityLicense = $null
    )
    if ($Result -isnot [Collections.IDictionary]) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
    foreach ($key in @(Get-CodexAppServerSerializerExtraRootKeys -Method $Method)) {
        if (-not $Result.Contains($key)) { continue }
        $value = $Result[$key]
        if (Test-CodexAppServerJsonNull -Value $value) {
            if (-not (Test-CodexAppServerSerializerExtraAllowsJsonNull -Key $key)) {
                Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
            }
            continue
        }
        if ([string]$key -ceq 'activePermissionProfile') {
            Assert-CodexAppServerExactKeys -Dict $value -Required @('id') -Allowed @('id', 'extends')
            if ([string]::IsNullOrWhiteSpace((Get-CodexAppServerDictString -Dict $value -Key 'id'))) {
                Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
            }
            if ($value.Contains('extends')) {
                $extends = $value['extends']
                if (-not (Test-CodexAppServerJsonNull -Value $extends) -and -not (Test-CodexAppServerJsonString -Value $extends)) {
                    Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
                }
            }
            continue
        }
        if ([string]$key -ceq 'initialTurnsPage') {
            Assert-CodexAppServerExactKeys -Dict $value -Required @('data', 'backwardsCursor', 'nextCursor') -Allowed @('data', 'backwardsCursor', 'nextCursor')
            $data = $value['data']
            if (-not (Test-CodexAppServerJsonArray -Value $data)) {
                Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
            }
            foreach ($turn in (Get-CodexAppServerJsonArrayItems -Value $data)) {
                $null = Assert-CodexAppServerTurnProjection -Turn $turn
            }
            foreach ($cursorKey in @('backwardsCursor', 'nextCursor')) {
                $cursor = $value[$cursorKey]
                if (-not (Test-CodexAppServerJsonNull -Value $cursor) -and -not (Test-CodexAppServerJsonString -Value $cursor)) {
                    Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
                }
            }
            continue
        }
        if ([string]$key -ceq 'multiAgentMode') {
            if (Test-CodexAppServerJsonString -Value $value) {
                if ([string]$value -cne 'explicitRequestOnly' -and [string]$value -cne 'proactive') {
                    Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
                }
                continue
            }
            if ($value -is [Collections.IDictionary]) {
                Assert-CodexAppServerExactKeys -Dict $value -Required @('custom') -Allowed @('custom')
                if (-not (Test-CodexAppServerJsonString -Value $value['custom']) -or [string]::IsNullOrWhiteSpace([string]$value['custom'])) {
                    Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
                }
                continue
            }
            Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
        }
        if (@('turnsBackwardsCursor', 'itemsBackwardsCursor') -contains [string]$key) {
            if (-not (Test-CodexAppServerJsonString -Value $value)) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
            continue
        }
        if ([string]$key -ceq 'runtimeWorkspaceRoots') {
            if (-not (Test-CodexAppServerJsonArray -Value $value)) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
            foreach ($root in (Get-CodexAppServerJsonArrayItems -Value $value)) {
                if (-not (Test-CodexAppServerFullyQualifiedWindowsPathString -Value $root)) {
                    Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
                }
            }
        }
    }
}

function Assert-CodexAppServerOptionalThreadFields {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Thread,
        [AllowNull()][object]$CompatibilityLicense = $null
    )
    if ($Thread -isnot [Collections.IDictionary]) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
    $approvedEntry = Get-CodexAppServerApprovedCompatibilityEntry -License $CompatibilityLicense
    $hasExtras = $false
    foreach ($key in @($script:CodexAppServerThreadOptionalKeys)) {
        if ($Thread.Contains($key)) { $hasExtras = $true; break }
    }
    if ($hasExtras -and $null -eq $approvedEntry) {
        Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID'
    }
    foreach ($key in @($script:CodexAppServerThreadOptionalKeys)) {
        if (-not $Thread.Contains($key)) { continue }
        $value = $Thread[$key]
        if ([string]$key -ceq 'projectId') {
            $mode = if ($null -ne $approvedEntry) { [string]$approvedEntry.ProjectIdMode } else { '' }
            if ($mode -cne 'null-only' -or -not (Test-CodexAppServerJsonNull -Value $value)) {
                Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
            }
            continue
        }
        if (Test-CodexAppServerJsonNull -Value $value) {
            if (-not (Test-CodexAppServerSerializerExtraAllowsJsonNull -Key $key)) {
                Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
            }
            continue
        }
        if ([string]$key -ceq 'canAcceptDirectInput') {
            if (-not (Test-CodexAppServerJsonBoolean -Value $value)) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
            continue
        }
        if ([string]$key -ceq 'extra') {
            if (-not (Test-CodexAppServerJsonEmptyObject -Value $value)) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
            continue
        }
        if ([string]$key -ceq 'historyMode') {
            if (-not (Test-CodexAppServerJsonString -Value $value) -or (@('legacy', 'paginated') -notcontains [string]$value)) {
                Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
            }
        }
    }
}

function Assert-CodexAppServerThreadStartOrResumeResponse {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Result,
        [AllowNull()][object]$RequestParams,
        [string]$ExpectedId = '',
        [string]$Method = 'thread/start',
        [AllowNull()][object]$CompatibilityLicense = $null
    )
    $rootExtras = Get-CodexAppServerSerializerExtraRootKeys -Method $Method
    Assert-CodexAppServerExactKeys -Dict $Result -Required $script:CodexAppServerThreadStartResponseKeys -Allowed (Get-CodexAppServerCombinedExactKeys -Required $script:CodexAppServerThreadStartResponseKeys -Optional $rootExtras)
    if (Test-CodexAppServerResponseCarriesSerializerExtras -Result $Result -Method $Method) {
        if (-not (Test-CodexAppServerCompatibilityLicense -License $CompatibilityLicense)) {
            Throw-CodexAppServerPublic -Code 'SCHEMA_OR_PROFILE_INVALID'
        }
    }
    Assert-CodexAppServerOptionalStartResumeFields -Result $Result -Method $Method -CompatibilityLicense $CompatibilityLicense
    Assert-CodexAppServerExactDefaultServiceTier -Result $Result -RequestParams $RequestParams
    $cwd = Get-CodexAppServerDictString -Dict $Result -Key 'cwd'
    if ([string]::IsNullOrWhiteSpace($cwd)) { Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID' }
    $model = Get-CodexAppServerDictString -Dict $Result -Key 'model'
    $provider = Get-CodexAppServerDictString -Dict $Result -Key 'modelProvider'
    if ([string]::IsNullOrWhiteSpace($model) -or [string]::IsNullOrWhiteSpace($provider)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    $sources = Get-CodexAppServerDictObject -Dict $Result -Key 'instructionSources'
    if (-not (Test-CodexAppServerJsonArray -Value $sources)) {
        Throw-CodexAppServerPublic -Code 'STABLE_PROTOCOL_INVALID'
    }
    Assert-CodexAppServerSandboxShape -Sandbox (Get-CodexAppServerDictObject -Dict $Result -Key 'sandbox')
    $thread = Get-CodexAppServerDictObject -Dict $Result -Key 'thread'
    $id = Assert-CodexAppServerThreadProjection -Thread $thread -ExpectedId $ExpectedId -CompatibilityLicense $CompatibilityLicense
    return [ordered]@{
        thread_id = $id
        thread = $thread
        result = $Result
        service_tier = [string]$script:CodexAppServerServiceTierDefault
    }
}

function Assert-CodexAppServerTurnStartResponse {
    [CmdletBinding()]
    param([AllowNull()][object]$Result)
    Assert-CodexAppServerExactKeys -Dict $Result -Required $script:CodexAppServerTurnStartResponseKeys -Allowed $script:CodexAppServerTurnStartResponseKeys
    $turn = Get-CodexAppServerDictObject -Dict $Result -Key 'turn'
    $turnId = Assert-CodexAppServerTurnProjection -Turn $turn
    return [ordered]@{
        turn_id = $turnId
        turn = $turn
        result = $Result
    }
}

function Assert-CodexAppServerThreadReadResponse {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Result,
        [string]$ExpectedId = '',
        [AllowNull()][object]$CompatibilityLicense = $null
    )
    Assert-CodexAppServerExactKeys -Dict $Result -Required $script:CodexAppServerThreadReadResponseKeys -Allowed $script:CodexAppServerThreadReadResponseKeys
    $thread = Get-CodexAppServerDictObject -Dict $Result -Key 'thread'
    $id = Assert-CodexAppServerThreadProjection -Thread $thread -ExpectedId $ExpectedId -CompatibilityLicense $CompatibilityLicense
    return [ordered]@{
        thread_id = $id
        thread = $thread
        result = $Result
    }
}

function Test-CodexAppServerRequestExplicitDefaultServiceTier {
    [CmdletBinding()]
    param([AllowNull()][object]$RequestParams)
    if ($RequestParams -isnot [Collections.IDictionary]) { return $false }
    if (-not $RequestParams.Contains('serviceTier')) { return $false }
    $raw = $RequestParams['serviceTier']
    if (Test-CodexAppServerJsonNull -Value $raw) { return $false }
    if (-not (Test-CodexAppServerJsonString -Value $raw)) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$raw)) { return $false }
    return ([string]$raw -ceq $script:CodexAppServerServiceTierDefault)
}

function Assert-CodexAppServerExactDefaultServiceTier {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Result,
        [AllowNull()][object]$RequestParams
    )
    if ($Result -isnot [Collections.IDictionary]) { Throw-CodexAppServerPublic -Code 'SERVICE_TIER_INVALID' }
    if (-not (Test-CodexAppServerRequestExplicitDefaultServiceTier -RequestParams $RequestParams)) {
        Throw-CodexAppServerPublic -Code 'SERVICE_TIER_INVALID'
    }
    $raw = $null
    if ($Result.Contains('serviceTier')) { $raw = $Result['serviceTier'] }
    if (Test-CodexAppServerJsonNull -Value $raw) { return }
    if (Test-CodexAppServerJsonString -Value $raw) {
        $tier = [string]$raw
        if ([string]::IsNullOrWhiteSpace($tier) -or $tier -cne $script:CodexAppServerServiceTierDefault) {
            Throw-CodexAppServerPublic -Code 'SERVICE_TIER_INVALID'
        }
        return
    }
    Throw-CodexAppServerPublic -Code 'SERVICE_TIER_INVALID'
}

function New-CodexAppServerThreadStartParams {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Worktree)
    return [ordered]@{
        cwd = [string]$Worktree
        serviceTier = [string]$script:CodexAppServerServiceTierDefault
    }
}

function New-CodexAppServerThreadResumeParams {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ThreadId)
    return [ordered]@{
        threadId = [string]$ThreadId
        serviceTier = [string]$script:CodexAppServerServiceTierDefault
    }
}

function Invoke-CodexAppServerThreadStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$Worktree
    )
    $params = New-CodexAppServerThreadStartParams -Worktree $Worktree
    $result = Invoke-CodexAppServerRequest -Client $Client -Method 'thread/start' -Params $params
    $parsed = Assert-CodexAppServerThreadStartOrResumeResponse -Result $result -RequestParams $params -Method 'thread/start' -CompatibilityLicense (Get-CodexAppServerCompatibilityLicenseFromClient -Client $Client)
    $Client.service_tier = [string]$script:CodexAppServerServiceTierDefault
    return $parsed
}

function Invoke-CodexAppServerThreadResume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$ThreadId
    )
    $injected = Consume-CodexAppServerInjectedResumeError -ThreadId $ThreadId
    if ($null -ne $injected) {
        Throw-CodexAppServerRequestError -Code $injected.code -Message ([string]$injected.message)
    }
    $params = New-CodexAppServerThreadResumeParams -ThreadId $ThreadId
    $result = Invoke-CodexAppServerRequest -Client $Client -Method 'thread/resume' -Params $params
    $parsed = Assert-CodexAppServerThreadStartOrResumeResponse -Result $result -RequestParams $params -ExpectedId $ThreadId -Method 'thread/resume' -CompatibilityLicense (Get-CodexAppServerCompatibilityLicenseFromClient -Client $Client)
    $Client.service_tier = [string]$script:CodexAppServerServiceTierDefault
    return $parsed
}

function Invoke-CodexAppServerThreadRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [bool]$IncludeTurns = $true
    )
    $result = Invoke-CodexAppServerRequest -Client $Client -Method 'thread/read' -Params ([ordered]@{
        threadId = [string]$ThreadId
        includeTurns = [bool]$IncludeTurns
    })
    return (Assert-CodexAppServerThreadReadResponse -Result $result -ExpectedId $ThreadId -CompatibilityLicense (Get-CodexAppServerCompatibilityLicenseFromClient -Client $Client))
}

function Invoke-CodexAppServerTurnStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $boundTier = ''
    if ($Client -is [Collections.IDictionary] -and $Client.Contains('service_tier')) {
        $boundTier = [string]$Client.service_tier
    }
    if (-not [string]::IsNullOrWhiteSpace($boundTier) -and $boundTier -cne $script:CodexAppServerServiceTierDefault) {
        Throw-CodexAppServerPublic -Code 'SERVICE_TIER_INVALID'
    }
    $result = Invoke-CodexAppServerRequest -Client $Client -Method 'turn/start' -Params ([ordered]@{
        threadId = [string]$ThreadId
        serviceTier = [string]$script:CodexAppServerServiceTierDefault
        input = @(
            [ordered]@{
                type = 'text'
                text = [string]$Text
                text_elements = @()
            }
        )
    })
    return (Assert-CodexAppServerTurnStartResponse -Result $result)
}

function New-CodexAppServerLeadBindingObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [AllowNull()][AllowEmptyCollection()][string[]]$LauncherArguments
    )
    $argsList = @()
    if ($null -ne $LauncherArguments) { $argsList = @($LauncherArguments | ForEach-Object { [string]$_ }) }
    $binding = [ordered]@{
        protocol_version = 'telephone-line-lead-binding-v1'
        session_id = [string]$SessionId
        worktree = [string]$Worktree
        launcher = [ordered]@{
            path = [string]$LauncherPath
            arguments = @($argsList)
        }
    }
    $json = ConvertTo-CodexAppServerJson -Value $binding
    Assert-TelephoneJsonSchema -JsonText $json -SchemaName 'lead-binding' -Label 'Lead binding'
    return $binding
}

function Get-CodexAppServerCrashPoint {
    [CmdletBinding()]
    param()
    return [string]$env:TELEPHONE_TEST_APP_SERVER_LEAD_CRASH_AT
}

function Invoke-CodexAppServerMaybeCrash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Point)
    $throwAt = [string]$env:TELEPHONE_TEST_APP_SERVER_LEAD_THROW_AT
    if (-not [string]::IsNullOrWhiteSpace($throwAt) -and $throwAt -ceq $Point) {
        throw ('injected exception at ' + $Point)
    }
    Invoke-CodexAppServerInjectedCrash -Point $Point
}

function Write-CodexAppServerLauncherFinal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$State
    )
    if (-not $script:CodexAppServerOfficialTerminals.Contains([string]$State)) {
        Throw-CodexAppServerPublic -Code 'DURABLE_CHAIN_INVALID'
    }
    if ([IO.File]::Exists($Path)) { return }
    $null = Write-CodexAppServerTextReplace -Path $Path -Text ($State + "`n") -PublicationPoint 'terminal' -WriterLabel 'terminal-final'
}

function New-CodexAppServerWakeAck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$TurnId
    )
    return [ordered]@{
        protocol_version = 'telephone-line-lead-wake-ack-v1'
        session_id = [string]$SessionId
        event = 'turn.started'
        turn_id = [string]$TurnId
        acknowledged_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Read-CodexAppServerJsonIfPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$SchemaName = ''
    )
    if (-not [IO.File]::Exists($Path)) { return $null }
    if ([string]::IsNullOrWhiteSpace($SchemaName)) {
        return (Read-TelephoneJson -Path $Path).value
    }
    return (Read-TelephoneJson -Path $Path -SchemaName $SchemaName).value
}

function Invoke-CodexAppServerConnectAndPrepare {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][string]$StatusPath
    )
    $live = Assert-CodexAppServerProfileCurrent -Profile $Profile -CodexCommand $CodexCommand
    $client = New-CodexAppServerClient -CodexCommand $CodexCommand -WorkingDirectory $Worktree -StorePath $StorePath
    $client.compatibility_license = $live
    try {
        $client.bound_thread_id = [string]$ThreadId
        Initialize-CodexAppServerSession -Client $client
        $resumed = $null
        try {
            $resumed = Invoke-CodexAppServerThreadResume -Client $client -ThreadId $ThreadId
        } catch {
            $caught = Get-CodexAppServerCaughtRequestError -ErrorRecord $_
            if ($null -eq $caught -or -not (Test-CodexAppServerArchivedThreadError -Code $caught.code -Message $caught.message -ThreadId $ThreadId)) {
                throw
            }
            $null = Invoke-CodexAppServerUnarchiveThread -CodexCommand $CodexCommand -ThreadId $ThreadId -WorkingDirectory $Worktree
            try {
                $resumed = Invoke-CodexAppServerThreadResume -Client $client -ThreadId $ThreadId
            } catch {
                throw
            }
        }
        $read = Invoke-CodexAppServerThreadRead -Client $client -ThreadId $ThreadId -IncludeTurns $true
        $projected = ConvertTo-CodexAppServerProjectedStatus -StatusNode (Get-CodexAppServerDictObject -Dict $read.thread -Key 'status')
        $statusOut = 'notLoaded'
        $flagsOut = @()
        if ([bool]$projected.valid) {
            $statusOut = [string]$projected.status
            $flagsOut = @($projected.active_flags)
        }
        if ((Get-CodexAppServerDictString -Dict $client.last_status -Key 'status') -cne 'notLoaded') {
            $statusOut = Get-CodexAppServerDictString -Dict $client.last_status -Key 'status'
            $flagsOut = @(Get-CodexAppServerDictObject -Dict $client.last_status -Key 'active_flags')
        }
        $null = Write-CodexAppServerProjectedStatus -Path $StatusPath -ThreadId $ThreadId -Status $statusOut -ActiveFlags @($flagsOut) -Pending @($client.pending)
        return [ordered]@{
            client = $client
            thread_id = [string]$resumed.thread_id
            thread = $read.thread
            baseline_turn_ids = [string[]](Get-CodexAppServerTurnIdsFromThread -Thread $read.thread)
            pending = @($client.pending)
        }
    } catch {
        Stop-CodexAppServerClient -Client $client
        throw
    }
}

function Complete-CodexAppServerBoundTurn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$TurnId,
        [Parameter(Mandatory = $true)][string]$Disposition
    )
    if (-not [IO.File]::Exists($Paths.bound_turn)) {
        $null = Write-TelephoneJsonCreateNew -Path $Paths.bound_turn -Value ([ordered]@{
            protocol_version = 'telephone-line-codex-app-server-lead-bound-turn-v1'
            thread_id = [string]$ThreadId
            turn_id = [string]$TurnId
            bound_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        })
    }
    Add-CodexAppServerTransition -Path $Paths.transitions -State 'turn_bound'
    Invoke-CodexAppServerMaybeCrash -Point 'after-turn-bind'
    Invoke-CodexAppServerMaybeCrash -Point 'before-ack'
    if (-not [IO.File]::Exists($Paths.ack)) {
        $null = Write-TelephoneJsonCreateNew -Path $Paths.ack -Value (New-CodexAppServerWakeAck -SessionId $ThreadId -TurnId $TurnId)
    }
    Add-CodexAppServerTransition -Path $Paths.transitions -State 'acknowledged'
    if ([IO.File]::Exists($Paths.run)) {
        $run = (Read-TelephoneJson -Path $Paths.run -SchemaName 'codex-app-server-lead-run').value
        $run.selected_turn_id = [string]$TurnId
        $run.disposition = [string]$Disposition
        $null = Write-CodexAppServerJsonReplace -Path $Paths.run -Value $run
    }
    Write-CodexAppServerLauncherFinal -Path $Paths.final -State $Disposition
}

function Send-CodexAppServerWakeTurnOnce {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$TurnText
    )
    Add-CodexAppServerTransition -Path $Paths.transitions -State 'turn_start_sending'
    Invoke-CodexAppServerMaybeCrash -Point 'after-ambiguous-write-pre'
    $started = $null
    try {
        $started = Invoke-CodexAppServerTurnStart -Client $Client -ThreadId $ThreadId -Text $TurnText
    } catch {
        Add-CodexAppServerTransition -Path $Paths.transitions -State 'turn_start_ambiguous'
        throw
    }
    Invoke-CodexAppServerMaybeCrash -Point 'after-ambiguous-write'
    return $started
}

function Invoke-CodexAppServerRecoverOrSend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Prepared,
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][string]$TurnText,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$BaselineTurnIds
    )
    if ([IO.File]::Exists($Paths.bound_turn)) {
        $bound = (Read-TelephoneJson -Path $Paths.bound_turn).value
        $turnId = Get-CodexAppServerDictString -Dict $bound -Key 'turn_id'
        if ([string]::IsNullOrWhiteSpace($turnId)) { throw 'Bound turn record is missing turn_id.' }
        Complete-CodexAppServerBoundTurn -Paths $Paths -ThreadId $ThreadId -TurnId $turnId -Disposition 'recovered'
        return [ordered]@{ turn_id = $turnId; recovered = $true; existing = $true }
    }
    $found = Find-CodexAppServerMatchingTurns -Thread $Prepared.thread -Marker $Marker -BaselineTurnIds $BaselineTurnIds
    if (@($found.unexplained).Count -gt 0) {
        throw 'Unexplained new turns were present on the resumed thread.'
    }
    $matchCount = @($found.matches).Count
    if ($matchCount -gt 1) {
        throw 'Multiple or conflicting wake-marker turns were present.'
    }
    if ($matchCount -eq 1) {
        $turnId = [string]$found.matches[0].turn_id
        Complete-CodexAppServerBoundTurn -Paths $Paths -ThreadId $ThreadId -TurnId $turnId -Disposition 'recovered'
        return [ordered]@{ turn_id = $turnId; recovered = $true; existing = $true }
    }
    $started = Send-CodexAppServerWakeTurnOnce -Client $Prepared.client -Paths $Paths -ThreadId $ThreadId -TurnText $TurnText
    Complete-CodexAppServerBoundTurn -Paths $Paths -ThreadId $ThreadId -TurnId ([string]$started.turn_id) -Disposition 'completed'
    return [ordered]@{ turn_id = [string]$started.turn_id; recovered = $false; existing = $false }
}

function Invoke-CodexAppServerWakeCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorktreePath,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$ResumeSessionId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$CodexCommand,
        [string]$ProfilePath
    )
    $worktree = Assert-TelephoneDirectoryPath -Path $WorktreePath -Label 'Lead worktree'
    $worktree = Assert-CodexAppServerNoReparseChain -Path $worktree -Label 'Lead worktree'
    $promptPath = Assert-TelephoneRegularFilePath -Path $PromptFile -Label 'Prompt file'
    $promptIdentity = Get-TelephoneFileIdentity -Path $promptPath
    $promptBytes = [IO.File]::ReadAllBytes([string]$promptIdentity.path)
    $promptText = [Text.UTF8Encoding]::new($false, $true).GetString($promptBytes)
    $threadId = [string]$ResumeSessionId
    if ([string]::IsNullOrWhiteSpace($threadId)) { throw 'ResumeSessionId must be the exact Codex thread id.' }
    $marker = Get-CodexAppServerWakeMarker -RunId $RunId
    $turnText = New-CodexAppServerTurnInputText -PromptText $promptText -RunId $RunId
    $paths = Get-CodexAppServerRunPaths -StateRoot $StateRoot -RunId $RunId
    $exe = Resolve-CodexAppServerExecutable -CodexCommand $CodexCommand
    $profileFile = if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) { [IO.Path]::GetFullPath($ProfilePath) } else { [string]$paths.profile }
    if (-not [IO.File]::Exists($profileFile)) { throw 'Lead profile is missing; bind the installed Codex schema first.' }
    $profile = (Read-TelephoneJson -Path $profileFile -SchemaName 'codex-app-server-lead-profile').value
    [IO.Directory]::CreateDirectory($paths.run_root) | Out-Null
    $gate = Open-TelephoneExclusiveGate -Path $paths.gate -WaitMilliseconds 60000
    if ($null -eq $gate) { throw 'Exclusive per-run gate is held by another launcher.' }
    $clientWrapper = $null
    $existing = $false
    $state = 'completed'
    try {
        if ([IO.File]::Exists($paths.ack)) {
            $existing = $true
            $state = 'completed'
            Write-CodexAppServerLauncherFinal -Path $paths.final -State 'completed'
            return [ordered]@{
                started = $true
                existing = $true
                state = 'completed'
                run_id = [string]$RunId
                run_root = [string]$paths.run_root
            }
        }
        $selfOwner = New-CodexAppServerOwnerRecord
        if (-not [IO.File]::Exists($paths.owner)) {
            $null = Write-TelephoneJsonCreateNew -Path $paths.owner -Value $selfOwner
        } else {
            $owner = (Read-TelephoneJson -Path $paths.owner).value
            if ((Test-TelephoneOwnerAlive -Owner $owner) -and [int]$owner.pid -ne [int]$PID) {
                throw 'Live owner already holds this run.'
            }
            $null = Write-CodexAppServerJsonReplace -Path $paths.owner -Value $selfOwner
        }
        Add-CodexAppServerTransition -Path $paths.transitions -State 'owner_bound'
        if (-not [IO.File]::Exists($paths.intent)) {
            $null = Write-TelephoneJsonCreateNew -Path $paths.intent -Value ([ordered]@{
                protocol_version = 'telephone-line-codex-app-server-lead-intent-v1'
                run_id = [string]$RunId
                thread_id = $threadId
                worktree = $worktree
                callback = [ordered]@{
                    path = [string]$promptIdentity.path
                    bytes = [int64]$promptIdentity.bytes
                    sha256 = [string]$promptIdentity.sha256
                }
                wake_marker = $marker
                profile_fingerprint = [string]$profile.schema_fingerprint
                created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            })
        }
        Invoke-CodexAppServerMaybeCrash -Point 'before-write'
        $env:TELEPHONE_APP_SERVER_THREAD_STORE = [string]$paths.store
        $prepared = Invoke-CodexAppServerConnectAndPrepare -CodexCommand $exe -Worktree $worktree -ThreadId $threadId -StorePath ([string]$paths.store) -Profile $profile -StatusPath ([string]$paths.status)
        $clientWrapper = $prepared.client
        if (-not [IO.File]::Exists($paths.child)) {
            $null = Write-TelephoneJsonCreateNew -Path $paths.child -Value $prepared.client.child
        } else {
            $null = Write-CodexAppServerJsonReplace -Path $paths.child -Value $prepared.client.child
        }
        Add-CodexAppServerTransition -Path $paths.transitions -State 'baseline_recorded'
        $baseline = @($prepared.baseline_turn_ids)
        $intent = (Read-TelephoneJson -Path $paths.intent).value
        if ($intent.Contains('baseline_turn_ids') -and (Test-CodexAppServerJsonArray -Value $intent.baseline_turn_ids)) {
            $baseline = @($intent.baseline_turn_ids | ForEach-Object { [string]$_ })
        } else {
            $intent.baseline_turn_ids = @($baseline)
            $null = Write-CodexAppServerJsonReplace -Path $paths.intent -Value $intent
        }
        if (-not [IO.File]::Exists($paths.run)) {
            $run = [ordered]@{
                protocol_version = $script:CodexAppServerRunProtocol
                run_id = [string]$RunId
                thread_id = $threadId
                worktree = $worktree
                callback = [ordered]@{
                    path = [string]$promptIdentity.path
                    bytes = [int64]$promptIdentity.bytes
                    sha256 = [string]$promptIdentity.sha256
                }
                wake_marker = $marker
                profile_fingerprint = [string]$profile.schema_fingerprint
                baseline_turn_ids = @($baseline)
                selected_turn_id = ''
                disposition = 'in_progress'
                fallback_required = ''
            }
            $json = ConvertTo-CodexAppServerJson -Value $run
            Assert-TelephoneJsonSchema -JsonText $json -SchemaName 'codex-app-server-lead-run' -Label 'Codex app-server Lead run'
            $null = Write-TelephoneJsonCreateNew -Path $paths.run -Value $run
        }
        $wake = Invoke-CodexAppServerRecoverOrSend -Prepared $prepared -Paths $paths -ThreadId $threadId -Marker $marker -TurnText $turnText -BaselineTurnIds $baseline
        $existing = [bool]$wake.existing
        $projected = $prepared.client.last_status
        $null = Write-CodexAppServerProjectedStatus -Path $paths.status -ThreadId $threadId -Status ([string]$projected.status) -ActiveFlags @($projected.active_flags) -Pending @($prepared.client.pending)
        return [ordered]@{
            started = $true
            existing = $existing
            state = $state
            run_id = [string]$RunId
            run_root = [string]$paths.run_root
        }
    } catch {
        $message = [string]$_.Exception.Message
        $fallback = ''
        if ($message.IndexOf('"fallback_required": "cli"', [StringComparison]::Ordinal) -ge 0 -or $message.IndexOf('"fallback_required":"cli"', [StringComparison]::Ordinal) -ge 0) {
            $fallback = 'cli'
            $state = 'fallback_required_cli'
        } else {
            $state = 'failed'
        }
        try {
            if ([IO.File]::Exists($paths.run)) {
                $run = (Read-TelephoneJson -Path $paths.run -SchemaName 'codex-app-server-lead-run').value
                $run.disposition = $state
                $run.fallback_required = $fallback
                $null = Write-CodexAppServerJsonReplace -Path $paths.run -Value $run
            }
        } catch { }
        Write-CodexAppServerLauncherFinal -Path $paths.final -State $state
        if ($fallback -ceq 'cli') {
            Write-CodexAppServerStdoutJson -Value ([ordered]@{
                started = $false
                existing = $false
                state = 'fallback_required_cli'
                run_id = [string]$RunId
                run_root = [string]$paths.run_root
                fallback_required = 'cli'
            })
            return $null
        }
        throw
    } finally {
        Stop-CodexAppServerClient -Client $clientWrapper
        if ($null -ne $gate) { $gate.Dispose() }
    }
}

function Invoke-CodexAppServerBuilderCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorktreePath,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$BindingOutputPath,
        [ValidateSet('app-server', 'cli')][string]$CallbackTransport = 'app-server',
        [string]$CodexCommand,
        [string]$ResumeSessionId = '',
        [string]$CliLauncher = '',
        [AllowNull()][AllowEmptyCollection()][string[]]$CliLauncherArguments,
        [string]$ProfilePath = '',
        [string]$PromptFile = '',
        [string]$RunId = ''
    )
    $worktree = Assert-TelephoneDirectoryPath -Path $WorktreePath -Label 'Lead worktree'
    $worktree = Assert-CodexAppServerNoReparseChain -Path $worktree -Label 'Lead worktree'
    $state = Assert-CodexAppServerNoReparseChain -Path ([IO.Path]::GetFullPath($StateRoot)) -Label 'State root'
    Assert-CodexAppServerStateOutsidePackage -StateRoot $state
    $bindingPath = Assert-CodexAppServerBindingOutputPath -BindingOutputPath $BindingOutputPath
    if ([IO.File]::Exists($bindingPath) -or [IO.Directory]::Exists($bindingPath)) {
        throw 'Lead binding already exists; create-new refused.'
    }
    $hasPrompt = -not [string]::IsNullOrWhiteSpace($PromptFile)
    $hasRunId = -not [string]::IsNullOrWhiteSpace($RunId)
    if ($hasPrompt -xor $hasRunId) {
        throw 'Durable create requires both PromptFile and RunId.'
    }
    if ($hasPrompt) {
        if ($CallbackTransport -cne 'app-server') { throw 'Durable create requires app-server transport.' }
        if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) { throw 'Durable create refuses an existing session id.' }
        return Invoke-CodexAppServerCreateWakeCore `
            -WorktreePath $worktree `
            -PromptFile $PromptFile `
            -RunId $RunId `
            -StateRoot $state `
            -BindingOutputPath $bindingPath `
            -CodexCommand $CodexCommand `
            -ProfilePath $ProfilePath
    }
    if ($CallbackTransport -ceq 'cli') {
        if ([string]::IsNullOrWhiteSpace($CliLauncher)) { throw 'CLI fallback requires an explicit CliLauncher path.' }
        if ([string]::IsNullOrWhiteSpace($ResumeSessionId)) { throw 'CLI fallback requires an explicit existing session id.' }
        $cliPath = Assert-TelephoneRegularFilePath -Path $CliLauncher -Label 'CLI Lead launcher'
        $binding = New-CodexAppServerLeadBindingObject -SessionId $ResumeSessionId -Worktree $worktree -LauncherPath $cliPath -LauncherArguments $CliLauncherArguments
        $identity = Write-TelephoneJsonCreateNew -Path $bindingPath -Value $binding
        return [ordered]@{
            protocol_version = 'telephone-line-codex-app-server-lead-binding-result-v1'
            callback_transport = 'cli'
            started = $false
            thread_id = [string]$ResumeSessionId
            binding = $identity
            fallback_required = ''
        }
    }
    $exe = Resolve-CodexAppServerExecutable -CodexCommand $CodexCommand
    $profileFile = if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) { [IO.Path]::GetFullPath($ProfilePath) } else { Join-Path $state 'profile.json' }
    if (-not [IO.File]::Exists($profileFile)) {
        $null = Invoke-CodexAppServerBindProfile -CodexCommand $exe -OutputPath $profileFile
    }
    $profile = (Read-TelephoneJson -Path $profileFile -SchemaName 'codex-app-server-lead-profile').value
    $live = Assert-CodexAppServerProfileCurrent -Profile $profile -CodexCommand $exe
    $store = Join-Path $state 'app-server-store.json'
    $client = New-CodexAppServerClient -CodexCommand $exe -WorkingDirectory $worktree -StorePath $store
    $client.compatibility_license = $live
    try {
        Initialize-CodexAppServerSession -Client $client
        if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) {
            $resumed = Invoke-CodexAppServerThreadResume -Client $client -ThreadId $ResumeSessionId
            $null = Invoke-CodexAppServerThreadRead -Client $client -ThreadId $ResumeSessionId -IncludeTurns $true
            $threadId = [string]$resumed.thread_id
        } else {
            $started = Invoke-CodexAppServerThreadStart -Client $client -Worktree $worktree
            $threadId = [string]$started.thread_id
        }
    } finally {
        Stop-CodexAppServerClient -Client $client
    }
    $launcher = Get-CodexAppServerLauncherPath
    $launcherArgs = @(
        '-StateRoot', $state,
        '-CodexCommand', $exe,
        '-ProfilePath', $profileFile
    )
    $binding = New-CodexAppServerLeadBindingObject -SessionId $threadId -Worktree $worktree -LauncherPath $launcher -LauncherArguments $launcherArgs
    $identity = Write-TelephoneJsonCreateNew -Path $bindingPath -Value $binding
    return [ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-binding-result-v1'
        callback_transport = 'app-server'
        started = $false
        thread_id = $threadId
        binding = $identity
        fallback_required = ''
    }
}

function Get-CodexAppServerStatusCore {
    [CmdletBinding()]
    param(
        [string]$StateRoot,
        [string]$RunId,
        [string]$SourcesPath,
        [string]$TelephoneStateRoot
    )
    $items = [Collections.Generic.List[object]]::new()
    $roots = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($SourcesPath)) {
        $fullSources = [IO.Path]::GetFullPath($SourcesPath)
        $null = Assert-CodexAppServerNoReparseChain -Path $fullSources -Label 'Status sources'
        $doc = $null
        try {
            $doc = (Read-TelephoneJson -Path $fullSources -SchemaName 'codex-app-server-lead-status-sources').value
        } catch {
            Throw-CodexAppServerPublic -Code 'STATUS_SOURCES_INVALID'
        }
        foreach ($source in @($doc.sources)) {
            if ($source -isnot [Collections.IDictionary]) { Throw-CodexAppServerPublic -Code 'STATUS_SOURCES_INVALID' }
            $root = Get-CodexAppServerDictString -Dict $source -Key 'root'
            if ([string]::IsNullOrWhiteSpace($root)) { Throw-CodexAppServerPublic -Code 'STATUS_SOURCES_INVALID' }
            $fullRoot = [IO.Path]::GetFullPath($root)
            $null = Assert-CodexAppServerNoReparseChain -Path $fullRoot -Label 'Status source root'
            Assert-CodexAppServerStateOutsidePackage -StateRoot $fullRoot
            if ([IO.Directory]::Exists($fullRoot)) { $roots.Add($fullRoot) }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($StateRoot) -and -not [string]::IsNullOrWhiteSpace($RunId)) {
        Assert-CodexAppServerRunId -RunId $RunId
        $paths = Get-CodexAppServerRunPaths -StateRoot $StateRoot -RunId $RunId
        $roots.Add([string]$paths.run_root)
    }
    $runRoots = [Collections.Generic.List[string]]::new()
    foreach ($root in @($roots)) {
        if ([IO.File]::Exists((Join-Path $root 'status.json')) -or [IO.File]::Exists((Join-Path $root 'run.json'))) {
            $runRoots.Add($root)
            continue
        }
        if ([IO.Directory]::Exists($root)) {
            foreach ($dir in [IO.Directory]::GetDirectories($root)) {
                try {
                    $null = Assert-CodexAppServerNoReparseChain -Path $dir -Label 'Status run root'
                    Assert-CodexAppServerStateOutsidePackage -StateRoot $dir
                    $runRoots.Add($dir)
                } catch {
                    continue
                }
            }
        }
    }
    foreach ($root in @($runRoots)) {
        try {
            $null = Assert-CodexAppServerNoReparseChain -Path $root -Label 'Status run root'
            Assert-CodexAppServerStateOutsidePackage -StateRoot $root
        } catch {
            continue
        }
        $statusPath = Join-Path $root 'status.json'
        $runPath = Join-Path $root 'run.json'
        $ackPath = Join-Path $root 'lead-wake-ack.json'
        $status = $null
        try {
            $status = Read-CodexAppServerJsonIfPresent -Path $statusPath -SchemaName 'codex-app-server-lead-status'
        } catch {
            $status = $null
        }
        if ($null -eq $status) {
            $status = [ordered]@{
                protocol_version = $script:CodexAppServerStatusProtocol
                thread_id = ''
                status = 'notLoaded'
                active_flags = @()
                pending = @()
                started = $false
                mutated = $false
            }
        }
        $run = $null
        try { $run = Read-CodexAppServerJsonIfPresent -Path $runPath -SchemaName 'codex-app-server-lead-run' } catch { $run = $null }
        $threadId = Get-CodexAppServerDictString -Dict $status -Key 'thread_id'
        if ([string]::IsNullOrWhiteSpace($threadId) -and $null -ne $run) {
            $threadId = Get-CodexAppServerDictString -Dict $run -Key 'thread_id'
        }
        $pending = Get-CodexAppServerSanitizedPending -Pending (Get-CodexAppServerDictObject -Dict $status -Key 'pending')
        $flags = [Collections.Generic.List[string]]::new()
        foreach ($flag in (Get-CodexAppServerStringRecords -Value (Get-CodexAppServerDictObject -Dict $status -Key 'active_flags'))) {
            $name = [string]$flag
            if ($name -ceq 'waitingOnApproval' -or $name -ceq 'waitingOnUserInput') { $flags.Add($name) }
        }
        $statusName = Get-CodexAppServerDictString -Dict $status -Key 'status'
        if (-not $script:CodexAppServerThreadStatusAllowlist.Contains($statusName)) { $statusName = 'notLoaded' }
        $acknowledged = $false
        if ([IO.File]::Exists($ackPath)) {
            try {
                $ack = Read-CodexAppServerValidated -Path $ackPath -SchemaName 'codex-app-server-lead-ack'
                $ackSession = Get-CodexAppServerDictString -Dict $ack -Key 'session_id'
                $ackTurn = Get-CodexAppServerDictString -Dict $ack -Key 'turn_id'
                if (-not [string]::IsNullOrWhiteSpace($ackSession) -and -not [string]::IsNullOrWhiteSpace($ackTurn)) {
                    if ([string]::IsNullOrWhiteSpace($threadId) -or $ackSession -ceq $threadId) {
                        $acknowledged = $true
                    }
                }
            } catch {
                $acknowledged = $false
            }
        }
        $ownerAlive = $false
        $ownerPath = Join-Path $root 'owner.json'
        if ([IO.File]::Exists($ownerPath)) {
            try {
                $ownerRec = Read-CodexAppServerValidated -Path $ownerPath -SchemaName 'codex-app-server-lead-owner' -Code 'OWNER_INVALID'
                $ownerAlive = Test-TelephoneOwnerAlive -Owner $ownerRec
            } catch { $ownerAlive = $false }
        }
        $runPaths = [ordered]@{
            failure = Join-Path $root 'failure.json'
        }
        $observed = Get-CodexAppServerObservedCallbackState -Run $run -Paths $runPaths -OwnerAlive $ownerAlive
        $items.Add([ordered]@{
            item_root = $root
            thread_id = $threadId
            status = $statusName
            active_flags = @($flags)
            pending = @($pending)
            acknowledged = $acknowledged
            callback_owner_state = [string]$observed
            started = $false
            mutated = $false
        })
    }
    $batches = [Collections.Generic.List[object]]::new()
    if (-not [string]::IsNullOrWhiteSpace($TelephoneStateRoot) -and [IO.Directory]::Exists($TelephoneStateRoot)) {
        foreach ($row in @(Get-TelephoneMailboxObservationalBatches -StateRoot $TelephoneStateRoot)) {
            $batches.Add($row)
        }
    }
    return [ordered]@{
        protocol_version = 'telephone-line-codex-app-server-lead-status-result-v1'
        started = $false
        mutated = $false
        items = @($items)
        batches = @($batches)
    }
}

function Get-CodexAppServerHistoryTurnState {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Phase,
        [bool]$HasBound = $false,
        [bool]$HasAck = $false
    )
    switch ([string]$Phase) {
        'none' { return 'prebind' }
        'turn_start_sending' {
            if ($HasBound) { return 'bound' }
            return 'prebind'
        }
        'turn_bound' { return 'bound' }
        'acknowledged' { return 'acked' }
        'terminal_publishing' { return 'publishing' }
        'terminal' { return 'terminal' }
        default { return '' }
    }
}

function Get-CodexAppServerDurableHistoryKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [string]$Code = '',
        [string]$Category = '',
        [string]$RecordedPhase = '',
        [string]$RecordedDisposition = '',
        [string]$RecordedState = '',
        [string]$CurrentPhase = '',
        [string]$CurrentDisposition = '',
        [string]$TurnState = ''
    )
    return @(
        [string]$Kind,
        [string]$Code,
        [string]$Category,
        [string]$RecordedPhase,
        [string]$RecordedDisposition,
        [string]$RecordedState,
        [string]$CurrentPhase,
        [string]$CurrentDisposition,
        [string]$TurnState
    ) -join '|'
}

function Register-CodexAppServerDurableHistoryRow {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Row)
    $key = Get-CodexAppServerDurableHistoryKey `
        -Kind ([string]$Row.kind) `
        -Code ([string]$Row.code) `
        -Category ([string]$Row.category) `
        -RecordedPhase ([string]$Row.recorded_phase) `
        -RecordedDisposition ([string]$Row.recorded_disposition) `
        -RecordedState ([string]$Row.recorded_state) `
        -CurrentPhase ([string]$Row.current_phase) `
        -CurrentDisposition ([string]$Row.current_disposition) `
        -TurnState ([string]$Row.turn_state)
    if ($script:CodexAppServerDurableHistoryKeys.Contains($key)) {
        throw 'Duplicate durable-history row.'
    }
    [void]$script:CodexAppServerDurableHistoryKeys.Add($key)
    $script:CodexAppServerDurableHistoryRows.Add([ordered]@{
        kind = [string]$Row.kind
        code = [string]$Row.code
        category = [string]$Row.category
        recorded_phase = [string]$Row.recorded_phase
        recorded_disposition = [string]$Row.recorded_disposition
        recorded_state = [string]$Row.recorded_state
        current_phase = [string]$Row.current_phase
        current_disposition = [string]$Row.current_disposition
        turn_state = [string]$Row.turn_state
    })
}

function Initialize-CodexAppServerDurableHistoryTable {
    [CmdletBinding()]
    param()
    if ($script:CodexAppServerDurableHistoryRows.Count -gt 0) { return }
    function Add-CodexAppServerFailureHistory {
        param(
            [string]$Code,
            [string]$Phase,
            [string]$FromDisposition,
            [string]$ToDisposition,
            [string]$TurnState
        )
        Register-CodexAppServerDurableHistoryRow -Row @{
            kind = 'failure'
            code = [string]$Code
            category = 'worker'
            recorded_phase = [string]$Phase
            recorded_disposition = [string]$FromDisposition
            recorded_state = ''
            current_phase = [string]$Phase
            current_disposition = [string]$ToDisposition
            turn_state = [string]$TurnState
        }
    }
    function Add-CodexAppServerRecoveryHistory {
        param(
            [string]$Phase,
            [string]$CurrentDisposition,
            [string]$TurnState
        )
        Register-CodexAppServerDurableHistoryRow -Row @{
            kind = 'recovery'
            code = ''
            category = ''
            recorded_phase = [string]$Phase
            recorded_disposition = ''
            recorded_state = 'recovery_required'
            current_phase = [string]$Phase
            current_disposition = [string]$CurrentDisposition
            turn_state = [string]$TurnState
        }
    }
    $origins = @(
        @{ phase = 'turn_start_sending'; turn = 'prebind' },
        @{ phase = 'turn_start_sending'; turn = 'bound' },
        @{ phase = 'turn_bound'; turn = 'bound' },
        @{ phase = 'acknowledged'; turn = 'acked' }
    )
    foreach ($spec in $origins) {
        foreach ($curDisp in @('in_progress', 'recovery_required', 'recovered')) {
            Add-CodexAppServerRecoveryHistory -Phase ([string]$spec.phase) -CurrentDisposition $curDisp -TurnState ([string]$spec.turn)
        }
    }
    Add-CodexAppServerFailureHistory -Code 'schema_or_version_mismatch' -Phase 'none' -FromDisposition 'in_progress' -ToDisposition 'fallback_required_cli' -TurnState 'prebind'
    Add-CodexAppServerFailureHistory -Code 'schema_or_version_mismatch' -Phase 'none' -FromDisposition 'fallback_required_cli' -ToDisposition 'fallback_required_cli' -TurnState 'prebind'
    Add-CodexAppServerFailureHistory -Code 'schema_or_version_mismatch' -Phase 'none' -FromDisposition 'in_progress' -ToDisposition '' -TurnState 'prebind'
    Add-CodexAppServerFailureHistory -Code 'schema_or_version_mismatch' -Phase 'none' -FromDisposition 'in_progress' -ToDisposition 'in_progress' -TurnState 'prebind'
    Add-CodexAppServerFailureHistory -Code 'worker_failed' -Phase 'none' -FromDisposition 'in_progress' -ToDisposition 'in_progress' -TurnState 'prebind'
    Add-CodexAppServerFailureHistory -Code 'worker_failed' -Phase 'none' -FromDisposition 'fallback_required_cli' -ToDisposition 'fallback_required_cli' -TurnState 'prebind'
    Add-CodexAppServerFailureHistory -Code 'worker_failed' -Phase 'none' -FromDisposition 'fallback_required_cli' -ToDisposition 'in_progress' -TurnState 'prebind'
    Add-CodexAppServerFailureHistory -Code 'worker_failed' -Phase 'none' -FromDisposition 'in_progress' -ToDisposition '' -TurnState 'prebind'
    foreach ($closed in $origins) {
        Add-CodexAppServerFailureHistory -Code 'compatibility_drift_after_bind' -Phase ([string]$closed.phase) -FromDisposition 'in_progress' -ToDisposition 'in_progress' -TurnState ([string]$closed.turn)
        Add-CodexAppServerFailureHistory -Code 'compatibility_drift_after_bind' -Phase ([string]$closed.phase) -FromDisposition 'in_progress' -ToDisposition 'recovery_required' -TurnState ([string]$closed.turn)
        Add-CodexAppServerFailureHistory -Code 'compatibility_drift_after_bind' -Phase ([string]$closed.phase) -FromDisposition 'recovery_required' -ToDisposition 'recovery_required' -TurnState ([string]$closed.turn)
    }
    $boundPhases = @(
        @{ phase = 'turn_start_sending'; turn = 'bound' },
        @{ phase = 'turn_bound'; turn = 'bound' },
        @{ phase = 'acknowledged'; turn = 'acked' }
    )
    foreach ($boundPhase in $boundPhases) {
        Add-CodexAppServerFailureHistory -Code 'transport_lost_before_terminal' -Phase ([string]$boundPhase.phase) -FromDisposition 'in_progress' -ToDisposition 'in_progress' -TurnState ([string]$boundPhase.turn)
        Add-CodexAppServerFailureHistory -Code 'transport_lost_before_terminal' -Phase ([string]$boundPhase.phase) -FromDisposition 'in_progress' -ToDisposition 'recovery_required' -TurnState ([string]$boundPhase.turn)
        Add-CodexAppServerFailureHistory -Code 'transport_lost_before_terminal' -Phase ([string]$boundPhase.phase) -FromDisposition 'recovery_required' -ToDisposition 'recovery_required' -TurnState ([string]$boundPhase.turn)
    }
    Add-CodexAppServerFailureHistory -Code 'worker_failed' -Phase 'turn_start_sending' -FromDisposition 'in_progress' -ToDisposition 'in_progress' -TurnState 'prebind'
    Add-CodexAppServerFailureHistory -Code 'worker_failed' -Phase 'turn_start_sending' -FromDisposition 'in_progress' -ToDisposition 'recovery_required' -TurnState 'prebind'
    Add-CodexAppServerFailureHistory -Code 'worker_failed' -Phase 'turn_start_sending' -FromDisposition 'recovery_required' -ToDisposition 'recovery_required' -TurnState 'prebind'
}

function Test-CodexAppServerDurableHistoryAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [string]$Code = '',
        [string]$Category = '',
        [string]$RecordedPhase = '',
        [string]$RecordedDisposition = '',
        [string]$RecordedState = '',
        [string]$CurrentPhase = '',
        [string]$CurrentDisposition = '',
        [string]$TurnState = ''
    )
    Initialize-CodexAppServerDurableHistoryTable
    $key = Get-CodexAppServerDurableHistoryKey `
        -Kind $Kind `
        -Code $Code `
        -Category $Category `
        -RecordedPhase $RecordedPhase `
        -RecordedDisposition $RecordedDisposition `
        -RecordedState $RecordedState `
        -CurrentPhase $CurrentPhase `
        -CurrentDisposition $CurrentDisposition `
        -TurnState $TurnState
    return $script:CodexAppServerDurableHistoryKeys.Contains($key)
}

function Get-CodexAppServerDurableHistoryTuplesFromDisk {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Paths)
    $tuples = [Collections.Generic.List[object]]::new()
    $phase = 'none'
    $disposition = ''
    if ([IO.File]::Exists($Paths.run)) {
        $run = Read-CodexAppServerValidated -Path $Paths.run -SchemaName 'codex-app-server-lead-run'
        $phase = Get-CodexAppServerDictString -Dict $run -Key 'callback_write_phase'
        $disposition = Get-CodexAppServerDictString -Dict $run -Key 'disposition'
    }
    $turnState = Get-CodexAppServerHistoryTurnState -Phase $phase -HasBound ([IO.File]::Exists($Paths.bound_turn)) -HasAck ([IO.File]::Exists($Paths.ack))
    if ([IO.File]::Exists($Paths.recovery)) {
        $recovery = Read-CodexAppServerValidated -Path $Paths.recovery -SchemaName 'codex-app-server-lead-recovery'
        $tuples.Add([ordered]@{
            kind = 'recovery'
            code = ''
            category = ''
            recorded_phase = Get-CodexAppServerDictString -Dict $recovery -Key 'callback_write_phase'
            recorded_disposition = ''
            recorded_state = Get-CodexAppServerDictString -Dict $recovery -Key 'state'
            current_phase = [string]$phase
            current_disposition = [string]$disposition
            turn_state = [string]$turnState
        })
    }
    if ([IO.File]::Exists($Paths.failure)) {
        $failure = Read-CodexAppServerValidated -Path $Paths.failure -SchemaName 'codex-app-server-lead-failure'
        $tuples.Add([ordered]@{
            kind = 'failure'
            code = Get-CodexAppServerDictString -Dict $failure -Key 'code'
            category = Get-CodexAppServerDictString -Dict $failure -Key 'category'
            recorded_phase = Get-CodexAppServerDictString -Dict $failure -Key 'callback_write_phase'
            recorded_disposition = Get-CodexAppServerDictString -Dict $failure -Key 'disposition'
            recorded_state = ''
            current_phase = [string]$phase
            current_disposition = [string]$disposition
            turn_state = [string]$turnState
        })
    }
    Write-Output -NoEnumerate -InputObject @($tuples.ToArray())
}

Initialize-CodexAppServerDurableHistoryTable
. (Join-Path $PSScriptRoot 'CodexAppServerLead.Lifecycle.ps1')

function Receive-CodexAppServerUntilResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$RequestId
    )
    while ($true) {
        $msg = Read-CodexAppServerRawMessage -Client $Client
        if ($null -eq $msg) { continue }
        $id = Get-CodexAppServerDictString -Dict $msg -Key 'id'
        if ($id -ceq $RequestId) {
            if ($msg.Contains('error') -and -not (Test-CodexAppServerJsonNull -Value $msg['error'])) {
                $err = Get-CodexAppServerDictObject -Dict $msg -Key 'error'
                $code = $null
                $message = ''
                if ($err -is [Collections.IDictionary]) {
                    if ($err.Contains('code')) { $code = $err['code'] }
                    if ($err.Contains('message')) { $message = [string]$err['message'] }
                }
                Throw-CodexAppServerRequestError -Code $code -Message $message
            }
            return ,(Get-CodexAppServerDictObject -Dict $msg -Key 'result')
        }
        $null = Apply-CodexAppServerInboundMessage -Client $Client -Message $msg
    }
}
