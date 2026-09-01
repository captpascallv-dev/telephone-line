# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MockArgList = @()
foreach ($item in @($args)) { $script:MockArgList += [string]$item }

$script:Version = [string]$env:TELEPHONE_TEST_APP_SERVER_VERSION
if ([string]::IsNullOrWhiteSpace($script:Version)) { $script:Version = 'codex-cli telephone-test-mock' }
$script:CrashAt = [string]$env:TELEPHONE_TEST_APP_SERVER_CRASH_AT
$script:StorePath = [string]$env:TELEPHONE_APP_SERVER_THREAD_STORE
if ([string]::IsNullOrWhiteSpace($script:StorePath)) {
    $script:StorePath = [string]$env:TELEPHONE_TEST_APP_SERVER_STORE
}
$script:Initialized = $false
$script:Handshake = 'none'
$script:Forbidden = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @(
    'jsonrpc', 'excludeTurns', 'initialTurnsPage', 'dynamicTools', 'experimentalRawEvents',
    'turnsBackwardsCursor', 'itemsBackwardsCursor', 'additionalContext',
    'responsesapiClientMetadata', 'allowProviderModelFallback', 'runtimeWorkspaceRoots',
    'permissions', 'multiAgentMode', 'historyMode', 'projectId', 'environments',
    'selectedCapabilityRoots', 'mockExperimentalField', 'collaborationMode',
    'canAcceptDirectInput'
)) { [void]$script:Forbidden.Add($name) }

function Get-MockNamedValue {
    param([string]$Name)
    for ($i = 0; $i -lt $script:MockArgList.Count; $i++) {
        if ($script:MockArgList[$i] -ceq $Name -and ($i + 1) -lt $script:MockArgList.Count) {
            return [string]$script:MockArgList[$i + 1]
        }
        if ($script:MockArgList[$i].StartsWith(($Name + '='), [StringComparison]::Ordinal)) {
            return $script:MockArgList[$i].Substring(($Name + '=').Length)
        }
    }
    return $null
}

function Test-MockHasArg {
    param([string]$Name)
    foreach ($item in $script:MockArgList) {
        if ([string]$item -ceq $Name) { return $true }
        if ([string]$item.StartsWith(($Name + '='), [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Invoke-MockCrash {
    param([string]$Point)
    if ([string]::IsNullOrWhiteSpace($script:CrashAt) -or $script:CrashAt -cne $Point) { return }
    $nthRaw = [string]$env:TELEPHONE_TEST_APP_SERVER_CRASH_ON_NTH
    $countPath = [string]$env:TELEPHONE_TEST_APP_SERVER_CRASH_COUNT_PATH
    if (-not [string]::IsNullOrWhiteSpace($nthRaw) -and -not [string]::IsNullOrWhiteSpace($countPath)) {
        $nth = 0
        if (-not [int]::TryParse($nthRaw, [ref]$nth) -or $nth -le 0) { return }
        $n = 0
        if ([IO.File]::Exists($countPath)) {
            [void][int]::TryParse(([IO.File]::ReadAllText($countPath, [Text.UTF8Encoding]::new($false, $true)).Trim()), [ref]$n)
        }
        $n++
        $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($countPath))
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not [IO.Directory]::Exists($parent)) {
            [IO.Directory]::CreateDirectory($parent) | Out-Null
        }
        [IO.File]::WriteAllText($countPath, ([string]$n + "`n"), [Text.UTF8Encoding]::new($false))
        if ($n -ne $nth) { return }
        Write-MockEvent -Name ('crash:' + [string]$Point + ':' + [string]$PID)
        exit 99
    }
    $oncePath = [string]$env:TELEPHONE_TEST_APP_SERVER_CRASH_ONCE_PATH
    if (-not [string]::IsNullOrWhiteSpace($oncePath)) {
        if ([IO.File]::Exists($oncePath)) { return }
        $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($oncePath))
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not [IO.Directory]::Exists($parent)) {
            [IO.Directory]::CreateDirectory($parent) | Out-Null
        }
        [IO.File]::WriteAllText($oncePath, "crashed`n", [Text.UTF8Encoding]::new($false))
        Write-MockEvent -Name ('crash:' + [string]$Point + ':' + [string]$PID)
        exit 99
    }
    Write-MockEvent -Name ('crash:' + [string]$Point + ':' + [string]$PID)
    exit 99
}

function ConvertTo-MockJson {
    param($Value)
    return (($Value | ConvertTo-Json -Depth 64 -Compress).Replace("`r`n", "`n"))
}

function Read-MockStore {
    $empty = [ordered]@{ threads = [ordered]@{} }
    if ([string]::IsNullOrWhiteSpace($script:StorePath) -or -not [IO.File]::Exists($script:StorePath)) {
        return $empty
    }
    $text = [IO.File]::ReadAllText($script:StorePath, [Text.UTF8Encoding]::new($false, $true))
    if ([string]::IsNullOrWhiteSpace($text)) { return $empty }
    $doc = $text | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    if ($doc -isnot [Collections.IDictionary]) { return $empty }
    if (-not $doc.Contains('threads') -or $doc.threads -isnot [Collections.IDictionary]) {
        $doc.threads = [ordered]@{}
    }
    return $doc
}

function Write-MockStore {
    param($Doc)
    if ([string]::IsNullOrWhiteSpace($script:StorePath)) { return }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($script:StorePath))
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $json = (($Doc | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n")
    $tmp = $script:StorePath + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
    [IO.File]::Copy($tmp, $script:StorePath, $true)
    [IO.File]::Delete($tmp)
}

function Get-MockRequestedServiceTier {
    param($Params)
    if ($Params -is [Collections.IDictionary] -and $Params.Contains('serviceTier')) {
        return [string]$Params['serviceTier']
    }
    return ''
}

function Test-MockRequestExplicitDefaultServiceTier {
    param($Params)
    if ($Params -isnot [Collections.IDictionary] -or -not $Params.Contains('serviceTier')) { return $false }
    $raw = $Params['serviceTier']
    if ([object]::ReferenceEquals($raw, $null)) { return $false }
    if ($raw -isnot [string]) { return $false }
    return ([string]$raw -ceq 'default')
}

function Get-MockReturnedServiceTier {
    param($Params)
    if ([string]$env:TELEPHONE_TEST_APP_SERVER_RETURN_NULL_TIER -ceq '1') { return $null }
    if ([string]$env:TELEPHONE_TEST_APP_SERVER_RETURN_EMPTY_TIER -ceq '1') { return '' }
    $forced = [string]$env:TELEPHONE_TEST_APP_SERVER_RETURN_TIER
    if (-not [string]::IsNullOrWhiteSpace($forced)) { return $forced }
    $requested = Get-MockRequestedServiceTier -Params $Params
    if (-not [string]::IsNullOrWhiteSpace($requested)) { return $requested }
    $inherited = [string]$env:TELEPHONE_TEST_APP_SERVER_INHERITED_TIER
    if (-not [string]::IsNullOrWhiteSpace($inherited)) { return $inherited }
    return 'default'
}

function Write-MockServiceTierEvent {
    param($Params, [string]$Method)
    if (Test-MockRequestExplicitDefaultServiceTier -Params $Params) {
        Write-MockEvent -Name ('explicit_default_tier:' + $Method)
    } else {
        Write-MockEvent -Name ('nondefault_tier:' + $Method)
    }
}

function Get-MockStatusObject {
    $type = [string]$env:TELEPHONE_TEST_APP_SERVER_STATUS
    if ([string]::IsNullOrWhiteSpace($type)) { $type = 'idle' }
    $status = [ordered]@{ type = $type }
    if ($type -ceq 'active') {
        $flags = @()
        $raw = [string]$env:TELEPHONE_TEST_APP_SERVER_ACTIVE_FLAGS
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $flags = @($raw.Split([char]',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ceq 'waitingOnApproval' -or $_ -ceq 'waitingOnUserInput' })
        }
        $status.activeFlags = @($flags)
    }
    return $status
}

function Get-MockTurnUserText {
    param($Turn)
    if ($Turn -isnot [Collections.IDictionary]) { return '' }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in (Get-MockJsonArrayItems -Value (Get-MockDictValue -Dict $Turn -Key 'items'))) {
        if ($item -isnot [Collections.IDictionary]) { continue }
        foreach ($part in (Get-MockJsonArrayItems -Value (Get-MockDictValue -Dict $item -Key 'content'))) {
            if ($part -is [Collections.IDictionary] -and $part.Contains('text')) {
                [void]$parts.Add([string]$part['text'])
            }
        }
        if ($item.Contains('text')) { [void]$parts.Add([string]$item['text']) }
    }
    return [string]::Join("`n", $parts)
}

function Test-MockTurnHasWakeMarker {
    param($Turn)
    $text = Get-MockTurnUserText -Turn $Turn
    return ($text.IndexOf('tl-wake:', [StringComparison]::Ordinal) -ge 0)
}

function Test-MockThreadHasInProgressTurn {
    param($Thread)
    if ($Thread -isnot [Collections.IDictionary]) { return $false }
    foreach ($turn in (Get-MockJsonArrayItems -Value (Get-MockDictValue -Dict $Thread -Key 'turns'))) {
        if ($turn -is [Collections.IDictionary] -and (Get-MockDictString -Dict $turn -Key 'status') -ceq 'inProgress') {
            return $true
        }
    }
    return $false
}

function Get-MockEffectiveStatus {
    param($Thread)
    $forced = [string]$env:TELEPHONE_TEST_APP_SERVER_STATUS
    if (-not [string]::IsNullOrWhiteSpace($forced)) { return Get-MockStatusObject }
    if (Test-MockThreadHasInProgressTurn -Thread $Thread) {
        return [ordered]@{ type = 'active'; activeFlags = @() }
    }
    return [ordered]@{ type = 'idle' }
}

function Get-MockForeignActiveTurnId {
    $id = [string]$env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_TURN_ID
    if ([string]::IsNullOrWhiteSpace($id)) { return '' }
    return $id
}

function Test-MockForeignActiveHeld {
    $path = [string]$env:TELEPHONE_TEST_APP_SERVER_FOREIGN_ACTIVE_HOLD_PATH
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    return -not [IO.File]::Exists($path)
}

function Ensure-MockForeignActiveTurn {
    param($Thread, $Store)
    $turnId = Get-MockForeignActiveTurnId
    if ([string]::IsNullOrWhiteSpace($turnId) -or $Thread -isnot [Collections.IDictionary]) { return $false }
    $held = Test-MockForeignActiveHeld
    $turns = [Collections.Generic.List[object]]::new()
    $found = $false
    $changed = $false
    foreach ($turn in (Get-MockJsonArrayItems -Value (Get-MockDictValue -Dict $Thread -Key 'turns'))) {
        if ($turn -is [Collections.IDictionary] -and (Get-MockDictString -Dict $turn -Key 'id') -ceq $turnId) {
            $found = $true
            if (-not $held -and (Get-MockDictString -Dict $turn -Key 'status') -ceq 'inProgress') {
                $turn['status'] = 'completed'
                $now = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $turn['completedAt'] = $now
                $turn['durationMs'] = 1
                $changed = $true
            }
        }
        $turns.Add($turn)
    }
    if ($held -and -not $found) {
        $turns.Add((New-MockTurn -TurnId $turnId -Items @((New-MockUserMessage -Text 'original Lead dispatch turn' -ItemId ('um-' + $turnId))) -Status 'inProgress'))
        $changed = $true
    }
    if ($changed) {
        $Thread['turns'] = @($turns)
        $Thread['status'] = Get-MockEffectiveStatus -Thread $Thread
        if ($null -ne $Store) { Save-MockThread -Store $Store -Thread $Thread }
        return $true
    }
    return $false
}

function New-MockThread {
    param([string]$ThreadId)
    $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cwd = [IO.Path]::GetFullPath((Get-Location).Path)
    return [ordered]@{
        id = $ThreadId
        sessionId = $ThreadId
        forkedFromId = $null
        parentThreadId = $null
        preview = ''
        ephemeral = $false
        section = $null
        sectionEnteredAt = $null
        modelProvider = 'openai'
        createdAt = $now
        updatedAt = $now
        recencyAt = $now
        status = Get-MockStatusObject
        path = $null
        cwd = $cwd
        cliVersion = [string]$script:Version
        source = 'appServer'
        threadSource = $null
        agentNickname = $null
        agentRole = $null
        gitInfo = $null
        name = $null
        turns = @()
    }
}

function Add-MockOptional0147ThreadFields {
    param($Thread)
    if ($Thread -isnot [Collections.IDictionary]) { return $Thread }
    if ([string]$env:TELEPHONE_TEST_APP_SERVER_EMIT_OPTIONAL_0147 -ceq '1') {
        $Thread['canAcceptDirectInput'] = $false
        $Thread['extra'] = [ordered]@{}
        $Thread['historyMode'] = 'legacy'
    }
    if ([string]$env:TELEPHONE_TEST_APP_SERVER_PROJECT_ID_NULL -ceq '1') {
        $Thread['projectId'] = $null
    }
    $unknown = [string]$env:TELEPHONE_TEST_APP_SERVER_UNKNOWN_THREAD_KEY
    if (-not [string]::IsNullOrWhiteSpace($unknown)) { $Thread[$unknown] = $true }
    $malformed = [string]$env:TELEPHONE_TEST_APP_SERVER_MALFORMED_OPTIONAL
    if ($malformed -ceq 'canAcceptDirectInput') { $Thread['canAcceptDirectInput'] = 'yes' }
    elseif ($malformed -ceq 'extra') { $Thread['extra'] = [ordered]@{ leftover = '1' } }
    elseif ($malformed -ceq 'historyMode') { $Thread['historyMode'] = 'bogus' }
    return $Thread
}

function Add-MockOptional0147WrapperFields {
    param($Result, [string]$Method = 'thread/start')
    if ($Result -isnot [Collections.IDictionary]) { return $Result }
    if ([string]$env:TELEPHONE_TEST_APP_SERVER_EMIT_OPTIONAL_0147 -ceq '1') {
        $Result['activePermissionProfile'] = [ordered]@{ id = ':workspace'; extends = $null }
        $Result['multiAgentMode'] = 'explicitRequestOnly'
        $Result['runtimeWorkspaceRoots'] = @()
        if ([string]$Method -ceq 'thread/resume') {
            $Result['initialTurnsPage'] = [ordered]@{ data = @(); backwardsCursor = $null; nextCursor = $null }
            $Result['turnsBackwardsCursor'] = $null
            $Result['itemsBackwardsCursor'] = $null
        }
    }
    $unknown = [string]$env:TELEPHONE_TEST_APP_SERVER_UNKNOWN_WRAPPER_KEY
    if (-not [string]::IsNullOrWhiteSpace($unknown)) { $Result[$unknown] = $true }
    $malformed = [string]$env:TELEPHONE_TEST_APP_SERVER_MALFORMED_OPTIONAL
    if ($malformed -ceq 'activePermissionProfile') { $Result['activePermissionProfile'] = 'not-an-object' }
    elseif ($malformed -ceq 'initialTurnsPage') { $Result['initialTurnsPage'] = 1 }
    elseif ($malformed -ceq 'multiAgentMode') { $Result['multiAgentMode'] = 123 }
    elseif ($malformed -ceq 'runtimeWorkspaceRoots') { $Result['runtimeWorkspaceRoots'] = 'cwd' }
    return $Result
}

function New-MockTurn {
    param(
        [string]$TurnId,
        [AllowEmptyCollection()][object[]]$Items = @(),
        [string]$Status = 'inProgress'
    )
    $now = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $completed = $null
    $duration = $null
    if ($Status -ceq 'completed' -or $Status -ceq 'failed' -or $Status -ceq 'interrupted') {
        $completed = $now
        $duration = 1
    }
    return [ordered]@{
        id = $TurnId
        items = @($Items)
        itemsView = 'full'
        status = $Status
        error = $null
        startedAt = $now
        completedAt = $completed
        durationMs = $duration
    }
}

function New-MockUserMessage {
    param([string]$Text, [string]$ItemId)
    return [ordered]@{
        type = 'userMessage'
        id = $ItemId
        clientId = $null
        content = @(
            [ordered]@{ type = 'text'; text = [string]$Text; text_elements = @() }
        )
    }
}

function Convert-MockTurnShape {
    param($Turn)
    if ($Turn -isnot [Collections.IDictionary]) { return $Turn }
    $id = Get-MockDictString -Dict $Turn -Key 'id'
    $items = [Collections.Generic.List[object]]::new()
    foreach ($item in (Get-MockJsonArrayItems -Value (Get-MockDictValue -Dict $Turn -Key 'items'))) { $items.Add($item) }
    $status = Get-MockDictString -Dict $Turn -Key 'status'
    if ([string]::IsNullOrWhiteSpace($status)) { $status = 'inProgress' }
    if ($Turn.Contains('itemsView') -and $Turn.Contains('startedAt') -and $Turn.Contains('error') -and $Turn.Contains('completedAt') -and $Turn.Contains('durationMs')) {
        return $Turn
    }
    return (New-MockTurn -TurnId $id -Items $items -Status $status)
}

function New-MockThreadStartResult {
    param($Thread, $Params, [string]$Method = 'thread/start')
    $cwd = Get-MockDictString -Dict $Thread -Key 'cwd'
    if ([string]::IsNullOrWhiteSpace($cwd)) { $cwd = [IO.Path]::GetFullPath((Get-Location).Path) }
    $tier = Get-MockReturnedServiceTier -Params $Params
    $result = [ordered]@{
        thread = $Thread
        model = 'mock-model'
        modelProvider = 'openai'
        cwd = $cwd
        instructionSources = @()
        approvalPolicy = 'never'
        approvalsReviewer = 'user'
        sandbox = [ordered]@{ type = 'dangerFullAccess' }
        reasoningEffort = $null
    }
    if ([string]$env:TELEPHONE_TEST_APP_SERVER_OMIT_SERVICE_TIER -cne '1') {
        $result.serviceTier = $tier
    }
    $result = Add-MockOptional0147WrapperFields -Result $result -Method $Method
    $null = Add-MockOptional0147ThreadFields -Thread $Thread
    $omitField = [string]$env:TELEPHONE_TEST_APP_SERVER_OMIT_WRAPPER_FIELD
    if (-not [string]::IsNullOrWhiteSpace($omitField) -and $result.Contains($omitField)) {
        $kept = [ordered]@{}
        foreach ($key in @($result.Keys)) {
            if ([string]$key -cne $omitField) { $kept[$key] = $result[$key] }
        }
        $result = $kept
    }
    return $result
}

function New-MockPendingParams {
    param([string]$Method, [string]$ThreadId, [string]$TurnId)
    $base = [ordered]@{
        threadId = [string]$ThreadId
        turnId = [string]$TurnId
        itemId = 'item-' + [string]$TurnId
        startedAtMs = [int64]1
    }
    if ($Method -ceq 'item/commandExecution/requestApproval') {
        $base.environmentId = $null
        return $base
    }
    if ($Method -ceq 'item/fileChange/requestApproval') {
        return [ordered]@{
            threadId = [string]$ThreadId
            turnId = [string]$TurnId
            itemId = 'item-' + [string]$TurnId
            startedAtMs = [int64]1
        }
    }
    if ($Method -ceq 'item/permissions/requestApproval') {
        return [ordered]@{
            threadId = [string]$ThreadId
            turnId = [string]$TurnId
            itemId = 'item-' + [string]$TurnId
            environmentId = $null
            startedAtMs = [int64]1
            cwd = [IO.Path]::GetFullPath((Get-Location).Path)
            reason = $null
            permissions = [ordered]@{ type = 'workspaceWrite' }
        }
    }
    if ($Method -ceq 'item/tool/requestUserInput') {
        return [ordered]@{
            threadId = [string]$ThreadId
            turnId = [string]$TurnId
            itemId = 'item-' + [string]$TurnId
            questions = @()
            isBlocking = $true
            autoResolutionMs = $null
        }
    }
    return $base
}

function Get-OrCreate-MockThread {
    param([string]$ThreadId, [switch]$Create)
    $store = Read-MockStore
    if ($store.threads.Contains($ThreadId)) {
        return [ordered]@{ store = $store; thread = $store.threads[$ThreadId] }
    }
    if (-not $Create) { throw "unknown thread $ThreadId" }
    $thread = New-MockThread -ThreadId $ThreadId
    $store.threads[$ThreadId] = $thread
    Write-MockStore -Doc $store
    return [ordered]@{ store = $store; thread = $thread }
}

function Save-MockThread {
    param($Store, $Thread)
    $Store.threads[(Get-MockDictString -Dict $Thread -Key 'id')] = $Thread
    Write-MockStore -Doc $Store
}

function Assert-MockStableParams {
    param($Node)
    if ($null -eq $Node) { return }
    $stack = [Collections.Generic.Stack[object]]::new()
    $stack.Push($Node)
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        if ($item -is [Collections.IDictionary]) {
            foreach ($key in @($item.Keys)) {
                if ($script:Forbidden.Contains([string]$key)) { throw "experimental field $key" }
                if ([string]$key -ceq 'experimentalApi' -and [bool]$item[$key] -eq $true) { throw 'experimentalApi' }
                if ($null -ne $item[$key]) { $stack.Push($item[$key]) }
            }
            continue
        }
        if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) {
            foreach ($child in @($item)) { if ($null -ne $child) { $stack.Push($child) } }
        }
    }
}

function Write-MockLine {
    param($Value)
    [Console]::Out.WriteLine((ConvertTo-MockJson -Value $Value))
    [Console]::Out.Flush()
}

function Write-MockEvent {
    param([string]$Name)
    $path = [string]$env:TELEPHONE_TEST_APP_SERVER_EVENT_LOG
    if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($Name)) { return }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path))
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not [IO.Directory]::Exists($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [IO.File]::AppendAllText($path, ($Name + "`n"), [Text.UTF8Encoding]::new($false))
}

function Get-MockPendingSpecs {
    $specs = [Collections.Generic.List[object]]::new()
    $multi = [string]$env:TELEPHONE_TEST_APP_SERVER_PENDING_METHODS
    if (-not [string]::IsNullOrWhiteSpace($multi)) {
        $i = 0
        foreach ($raw in @($multi.Split([char]','))) {
            $method = $raw.Trim()
            if ([string]::IsNullOrWhiteSpace($method)) { continue }
            $i += 1
            $specs.Add([ordered]@{ method = $method; id = ('pending-' + $i.ToString()) })
        }
    }
    $oneMethod = [string]$env:TELEPHONE_TEST_APP_SERVER_PENDING_METHOD
    $oneId = [string]$env:TELEPHONE_TEST_APP_SERVER_PENDING_ID
    if (-not [string]::IsNullOrWhiteSpace($oneMethod)) {
        if ([string]::IsNullOrWhiteSpace($oneId)) { $oneId = 'pending-' + [Guid]::NewGuid().ToString('N') }
        $specs.Add([ordered]@{ method = $oneMethod; id = $oneId })
    }
    return @($specs)
}

function Write-MockStderrVolume {
    $secret = [string]$env:TELEPHONE_TEST_APP_SERVER_STDERR_SECRET
    if (-not [string]::IsNullOrWhiteSpace($secret)) {
        [Console]::Error.WriteLine($secret)
    }
    $volume = 0
    [void][int]::TryParse([string]$env:TELEPHONE_TEST_APP_SERVER_STDERR_BYTES, [ref]$volume)
    if ($volume -le 0) { return }
    $left = $volume
    while ($left -gt 0) {
        $n = [Math]::Min(1024, $left)
        [Console]::Error.WriteLine(('E' * $n))
        $left -= $n
    }
    [Console]::Error.Flush()
}

function Wait-MockCompletedHold {
    $hold = [string]$env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH
    if ([string]::IsNullOrWhiteSpace($hold)) { return }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(60)
    while (-not [IO.File]::Exists($hold) -and [DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    $delayMs = 0
    [void][int]::TryParse([string]$env:TELEPHONE_TEST_APP_SERVER_COMPLETED_DELAY_MS, [ref]$delayMs)
    if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
}

function Write-MockPostStartEvents {
    param([string]$ThreadId, $Turn)
    $delayMs = 0
    [void][int]::TryParse([string]$env:TELEPHONE_TEST_APP_SERVER_POST_START_DELAY_MS, [ref]$delayMs)
    if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
    $status = Get-MockStatusObject
    if ([string]$env:TELEPHONE_TEST_APP_SERVER_POST_START_SEQUENCE -ceq 'full' -and $status.type -cne 'active') {
        $status = [ordered]@{ type = 'active'; activeFlags = @('waitingOnApproval', 'waitingOnUserInput') }
    }
    Write-MockLine -Value ([ordered]@{
        method = 'thread/status/changed'
        params = [ordered]@{ threadId = $ThreadId; status = $status }
    })
    Write-MockEvent -Name 'status_changed'
    $secret = [string]$env:TELEPHONE_TEST_APP_SERVER_PENDING_SECRET
    $errorSecret = [string]$env:TELEPHONE_TEST_APP_SERVER_ERROR_SECRET
    if (-not [string]::IsNullOrWhiteSpace($errorSecret)) {
        Write-MockLine -Value ([ordered]@{
            method = 'item/unknownExperimental/request'
            params = [ordered]@{ message = $errorSecret }
        })
        Write-MockEvent -Name 'unknown_request'
    }
    $ids = [Collections.Generic.List[string]]::new()
    $turnId = Get-MockDictString -Dict $Turn -Key 'id'
    foreach ($spec in @(Get-MockPendingSpecs)) {
        $params = New-MockPendingParams -Method ([string]$spec.method) -ThreadId $ThreadId -TurnId $turnId
        Write-MockLine -Value ([ordered]@{
            id = [string]$spec.id
            method = [string]$spec.method
            params = $params
        })
        Write-MockEvent -Name ('pending:' + [string]$spec.method)
        $ids.Add([string]$spec.id)
    }
    if ([string]$env:TELEPHONE_TEST_APP_SERVER_INJECT_FOREIGN -ceq '1') {
        Write-MockLine -Value ([ordered]@{
            method = 'thread/status/changed'
            params = [ordered]@{ threadId = 'other-thread-id'; status = [ordered]@{ type = 'systemError'; activeFlags = @() } }
        })
        Write-MockEvent -Name 'foreign_status'
        Write-MockLine -Value ([ordered]@{
            id = 'foreign-pending'
            method = 'item/commandExecution/requestApproval'
            params = [ordered]@{ threadId = 'other-thread-id'; turnId = 'other-turn-id' }
        })
        Write-MockEvent -Name 'foreign_pending'
        Write-MockLine -Value ([ordered]@{
            id = 'cross-turn-pending'
            method = 'item/tool/requestUserInput'
            params = [ordered]@{ threadId = [string]$ThreadId; turnId = 'other-turn-id' }
        })
        Write-MockEvent -Name 'cross_turn_pending'
        Write-MockLine -Value ([ordered]@{
            method = 'serverRequest/resolved'
            params = [ordered]@{ threadId = [string]$ThreadId; turnId = 'other-turn-id'; requestId = 'foreign-pending' }
        })
        Write-MockEvent -Name 'foreign_resolved'
        Write-MockLine -Value ([ordered]@{
            method = 'serverRequest/resolved'
            params = [ordered]@{ requestId = 'unknown-resolution' }
        })
        Write-MockEvent -Name 'unknown_resolved'
        Write-MockLine -Value ([ordered]@{
            method = 'turn/completed'
            params = [ordered]@{ threadId = 'other-thread-id'; turn = [ordered]@{ id = [string]$turnId; status = 'completed' } }
        })
        Write-MockEvent -Name 'foreign_thread_terminal'
        Write-MockLine -Value ([ordered]@{
            method = 'turn/completed'
            params = [ordered]@{ threadId = [string]$ThreadId; turn = [ordered]@{ id = 'other-turn-id'; status = 'completed' } }
        })
        Write-MockEvent -Name 'foreign_turn_terminal'
        Write-MockLine -Value ([ordered]@{
            method = 'turn/completed'
            params = [ordered]@{ threadId = [string]$ThreadId; turn = [ordered]@{ id = [string]$turnId } }
        })
        Write-MockEvent -Name 'malformed_terminal'
        Write-MockLine -Value ([ordered]@{
            method = 'turn/completed'
            params = [ordered]@{ threadId = [string]$ThreadId; turn = [ordered]@{ id = [string]$turnId; status = 'banana' } }
        })
        Write-MockEvent -Name 'unknown_terminal'
        Write-MockLine -Value ([ordered]@{
            method = 'turn/completed'
            params = [ordered]@{ threadId = [string]$ThreadId; turnId = [string]$turnId }
        })
        Write-MockEvent -Name 'non_object_turn_terminal'
    }
    if ([string]$env:TELEPHONE_TEST_APP_SERVER_INJECT_PROTOCOL_NEGATIVES -ceq '1') {
        Write-MockLine -Value ([ordered]@{
            method = 'thread/status/changed'
            params = [ordered]@{ threadId = [string]$ThreadId; status = [ordered]@{ type = 'idle'; extra = $true } }
        })
        Write-MockEvent -Name 'malformed_same_thread_status'
        foreach ($alias in @('complete', 'success', 'error', 'systemError', 'cancelled', 'canceled')) {
            Write-MockLine -Value ([ordered]@{
                method = 'turn/completed'
                params = [ordered]@{ threadId = [string]$ThreadId; turn = [ordered]@{ id = [string]$turnId; status = $alias } }
            })
            Write-MockEvent -Name ('alias_terminal:' + $alias)
        }
        Write-MockLine -Value ([ordered]@{
            method = 'turn/completed'
            params = [ordered]@{ threadId = [string]$ThreadId; turn = [ordered]@{ id = [string]$turnId; error = [ordered]@{ message = 'boom' } } }
        })
        Write-MockEvent -Name 'error_only_terminal'
        Write-MockLine -Value ([ordered]@{
            method = 'serverRequest/resolved'
            params = [ordered]@{ requestId = 'bound-pending-1' }
        })
        Write-MockEvent -Name 'resolved_missing_thread'
    }
    if ([string]$env:TELEPHONE_TEST_APP_SERVER_RESOLVE_PENDING -ceq '1') {
        foreach ($rid in @($ids)) {
            Write-MockLine -Value ([ordered]@{
                method = 'serverRequest/resolved'
                params = [ordered]@{ threadId = [string]$ThreadId; requestId = $rid }
            })
            Write-MockEvent -Name ('resolved:' + $rid)
        }
    }
    Wait-MockCompletedHold
    Invoke-MockCrash -Point 'before-turn-completed'
    $terminalStatus = [string]$env:TELEPHONE_TEST_APP_SERVER_TURN_STATUS
    if ([string]::IsNullOrWhiteSpace($terminalStatus)) { $terminalStatus = 'completed' }
    $Turn['status'] = $terminalStatus
    $got = Get-OrCreate-MockThread -ThreadId $ThreadId -Create
    $thread = $got['thread']
    $store = $got['store']
    $turns = [Collections.Generic.List[object]]::new()
    foreach ($existing in (Get-MockJsonArrayItems -Value (Get-MockDictValue -Dict $thread -Key 'turns'))) {
        if ($existing -is [Collections.IDictionary] -and (Get-MockDictString -Dict $existing -Key 'id') -ceq (Get-MockDictString -Dict $Turn -Key 'id')) {
            $turns.Add($Turn)
        } else {
            $turns.Add($existing)
        }
    }
    $thread['turns'] = @($turns)
    $thread['status'] = Get-MockStatusObject
    Save-MockThread -Store $store -Thread $thread
    Write-MockLine -Value ([ordered]@{
        method = 'turn/completed'
        params = [ordered]@{ threadId = $ThreadId; turn = $Turn }
    })
    Write-MockEvent -Name 'turn_completed'
}

function Complete-MockInProgressTurns {
    param($Thread, $Store)
    $hold = [string]$env:TELEPHONE_TEST_APP_SERVER_HOLD_COMPLETED_PATH
    if (-not [string]::IsNullOrWhiteSpace($hold) -and -not [IO.File]::Exists($hold)) { return }
    $threadId = Get-MockDictString -Dict $Thread -Key 'id'
    $changed = $false
    $turns = [Collections.Generic.List[object]]::new()
    foreach ($turn in (Get-MockJsonArrayItems -Value (Get-MockDictValue -Dict $Thread -Key 'turns'))) {
        if ($turn -is [Collections.IDictionary] -and (Get-MockDictString -Dict $turn -Key 'status') -ceq 'inProgress') {
            if (-not (Test-MockTurnHasWakeMarker -Turn $turn)) {
                $turns.Add($turn)
                continue
            }
            $turn['status'] = 'completed'
            $changed = $true
            $turns.Add($turn)
            Write-MockLine -Value ([ordered]@{
                method = 'turn/completed'
                params = [ordered]@{ threadId = $threadId; turn = $turn }
            })
            Write-MockEvent -Name 'turn_completed_resume'
            continue
        }
        $turns.Add($turn)
    }
    if ($changed) {
        $Thread['turns'] = @($turns)
        $Thread['status'] = Get-MockEffectiveStatus -Thread $Thread
        Save-MockThread -Store $Store -Thread $Thread
    }
}

function Write-MockResult {
    param([string]$Id, $Result)
    Write-MockLine -Value ([ordered]@{ id = $Id; result = $Result })
}

function Write-MockError {
    param([string]$Id, [string]$Message, $Code = -32600)
    Write-MockLine -Value ([ordered]@{
        id = $Id
        error = [ordered]@{ code = $Code; message = $Message }
    })
}

function Get-MockDictValue {
    param($Dict, [string]$Key)
    if ($Dict -isnot [Collections.IDictionary] -or -not $Dict.Contains($Key)) { return }
    Write-Output -NoEnumerate -InputObject $Dict[$Key]
}

function Get-MockJsonArrayItems {
    param($Value)
    $items = [Collections.Generic.List[object]]::new()
    if ([object]::ReferenceEquals($Value, $null)) {
        Write-Output -NoEnumerate -InputObject ([object[]]@())
        return
    }
    if ($Value -is [Collections.IDictionary]) {
        $items.Add($Value)
        Write-Output -NoEnumerate -InputObject ([object[]]@($items))
        return
    }
    if ($Value -is [string]) {
        Write-Output -NoEnumerate -InputObject ([object[]]@())
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { $items.Add($item) }
        Write-Output -NoEnumerate -InputObject ([object[]]@($items))
        return
    }
    Write-Output -NoEnumerate -InputObject ([object[]]@())
}

function Get-MockDictString {
    param($Dict, [string]$Key)
    $value = Get-MockDictValue -Dict $Dict -Key $Key
    if ([object]::ReferenceEquals($value, $null)) { return '' }
    return [string]$value
}

function Get-MockInputText {
    param($Params)
    if ($Params -isnot [Collections.IDictionary]) { return '' }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in (Get-MockJsonArrayItems -Value (Get-MockDictValue -Dict $Params -Key 'input'))) {
        if ($item -is [Collections.IDictionary] -and $item.Contains('text')) {
            [void]$parts.Add([string]$item['text'])
        }
    }
    return [string]::Join("`n", $parts)
}

function Invoke-MockGenerateSchema {
    $out = Get-MockNamedValue -Name '--out'
    if ([string]$env:TELEPHONE_TEST_APP_SERVER_SCHEMA_FAIL -ceq '1') {
        [Console]::Error.WriteLine('schema generation failed')
        exit 2
    }
    if ([string]::IsNullOrWhiteSpace($out)) { throw 'generate-json-schema requires --out' }
    $full = [IO.Path]::GetFullPath($out)
    [IO.Directory]::CreateDirectory($full) | Out-Null
    $files = [ordered]@{
        'initialize.json' = '{"title":"initialize","stable":true}'
        'thread-start.json' = '{"title":"thread/start","stable":true}'
        'thread-resume.json' = '{"title":"thread/resume","stable":true}'
        'thread-read.json' = '{"title":"thread/read","includeTurns":true}'
        'turn-start.json' = '{"title":"turn/start","stable":true}'
        'thread-status.json' = '{"title":"thread/status/changed","values":["notLoaded","idle","systemError","active"]}'
    }
    foreach ($name in @($files.Keys)) {
        [IO.File]::WriteAllText((Join-Path $full $name), ($files[$name] + "`n"), [Text.UTF8Encoding]::new($false))
    }
    $extra = [string]$env:TELEPHONE_TEST_APP_SERVER_SCHEMA_EXTRA
    if (-not [string]::IsNullOrWhiteSpace($extra)) {
        [IO.File]::WriteAllText((Join-Path $full 'extra-drift.json'), ($extra + "`n"), [Text.UTF8Encoding]::new($false))
    }
    exit 0
}

function Start-MockStdio {
    $utf8 = [Text.UTF8Encoding]::new($false)
    try { [Console]::InputEncoding = $utf8; [Console]::OutputEncoding = $utf8 } catch { }
    Write-MockStderrVolume
    while ($true) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { break }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $msg = $line | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
        if ($msg -isnot [Collections.IDictionary]) { continue }
        if ($msg.Contains('jsonrpc')) {
            $rid = Get-MockDictString -Dict $msg -Key 'id'
            if (-not [string]::IsNullOrWhiteSpace($rid)) { Write-MockError -Id $rid -Message 'jsonrpc is forbidden' }
            continue
        }
        $method = Get-MockDictString -Dict $msg -Key 'method'
        $id = Get-MockDictString -Dict $msg -Key 'id'
        $params = Get-MockDictValue -Dict $msg -Key 'params'
        try { Assert-MockStableParams -Node $params } catch {
            if (-not [string]::IsNullOrWhiteSpace($id)) { Write-MockError -Id $id -Message ([string]$_.Exception.Message) }
            continue
        }
        if ($method -ceq 'initialize') {
            $caps = $null
            if ($params -is [Collections.IDictionary] -and $params.Contains('capabilities')) { $caps = $params['capabilities'] }
            if ($caps -is [Collections.IDictionary] -and $caps.Contains('experimentalApi') -and [bool]$caps['experimentalApi'] -eq $true) {
                Write-MockError -Id $id -Message 'experimentalApi'
                continue
            }
            $script:Handshake = 'initialize'
            Invoke-MockCrash -Point 'after-initialize'
            Write-MockResult -Id $id -Result ([ordered]@{ protocolVersion = '2' })
            continue
        }
        if ($method -ceq 'initialized') {
            if ($script:Handshake -cne 'initialize') { continue }
            $script:Handshake = 'ready'
            $script:Initialized = $true
            Invoke-MockCrash -Point 'after-initialized'
            continue
        }
        if (-not $script:Initialized) {
            if (-not [string]::IsNullOrWhiteSpace($id)) { Write-MockError -Id $id -Message 'not initialized' }
            continue
        }
        if ($method -ceq 'thread/start') {
            Write-MockEvent -Name ('process:' + [string]$PID + ':thread/start')
            Invoke-MockCrash -Point 'before-thread-start'
            Write-MockServiceTierEvent -Params $params -Method 'thread/start'
            $threadId = [string]$env:TELEPHONE_TEST_APP_SERVER_THREAD_ID
            if ([string]::IsNullOrWhiteSpace($threadId)) { $threadId = [Guid]::NewGuid().ToString('D') }
            $got = Get-OrCreate-MockThread -ThreadId $threadId -Create
            Invoke-MockCrash -Point 'after-thread-start'
            $thread = $got['thread']
            if ([string]$env:TELEPHONE_TEST_APP_SERVER_OMIT_THREAD_ID -ceq '1') {
                $thread = [ordered]@{}
                foreach ($key in @($got['thread'].Keys)) {
                    if ([string]$key -cne 'id') { $thread[$key] = $got['thread'][$key] }
                }
            } elseif ([string]$env:TELEPHONE_TEST_APP_SERVER_FOREIGN_THREAD_ID -ceq '1') {
                $thread = [ordered]@{}
                foreach ($key in @($got['thread'].Keys)) { $thread[$key] = $got['thread'][$key] }
                $thread.id = 'foreign-thread-id'
            }
            if ([string]$env:TELEPHONE_TEST_APP_SERVER_UNWRAP_THREAD -ceq '1') {
                Write-MockResult -Id $id -Result $thread
            } else {
                Write-MockResult -Id $id -Result (New-MockThreadStartResult -Thread $thread -Params $params -Method 'thread/start')
            }
            continue
        }
        if ($method -ceq 'thread/resume') {
            $threadId = Get-MockDictString -Dict $params -Key 'threadId'
            Invoke-MockCrash -Point 'before-thread-resume'
            Write-MockServiceTierEvent -Params $params -Method 'thread/resume'
            $got = Get-OrCreate-MockThread -ThreadId $threadId -Create
            $thread = $got['thread']
            $store = $got['store']
            $null = Ensure-MockForeignActiveTurn -Thread $thread -Store $store
            $thread['status'] = Get-MockEffectiveStatus -Thread $thread
            Save-MockThread -Store $store -Thread $thread
            Invoke-MockCrash -Point 'after-thread-resume'
            Write-MockLine -Value ([ordered]@{
                method = 'thread/status/changed'
                params = [ordered]@{ threadId = $threadId; status = $thread['status'] }
            })
            $outThread = $thread
            if ([string]$env:TELEPHONE_TEST_APP_SERVER_OMIT_THREAD_ID -ceq '1') {
                $outThread = [ordered]@{}
                foreach ($key in @($thread.Keys)) {
                    if ([string]$key -cne 'id') { $outThread[$key] = $thread[$key] }
                }
            } elseif ([string]$env:TELEPHONE_TEST_APP_SERVER_FOREIGN_THREAD_ID -ceq '1') {
                $outThread = [ordered]@{}
                foreach ($key in @($thread.Keys)) { $outThread[$key] = $thread[$key] }
                $outThread.id = 'foreign-thread-id'
            }
            if ([string]$env:TELEPHONE_TEST_APP_SERVER_UNWRAP_THREAD -ceq '1') {
                Write-MockResult -Id $id -Result $outThread
            } else {
                Write-MockResult -Id $id -Result (New-MockThreadStartResult -Thread $outThread -Params $params -Method 'thread/resume')
            }
            Complete-MockInProgressTurns -Thread $thread -Store $store
            continue
        }
        if ($method -ceq 'thread/read') {
            $threadId = Get-MockDictString -Dict $params -Key 'threadId'
            $got = Get-OrCreate-MockThread -ThreadId $threadId -Create
            $include = $true
            if ($params -is [Collections.IDictionary] -and $params.Contains('includeTurns')) { $include = [bool]$params['includeTurns'] }
            $thread = $got['thread']
            $null = Ensure-MockForeignActiveTurn -Thread $thread -Store $got['store']
            $thread['status'] = Get-MockEffectiveStatus -Thread $thread
            if (-not $include) {
                $clone = [ordered]@{}
                foreach ($key in @($thread.Keys)) { $clone[$key] = $thread[$key] }
                $clone.turns = @()
                $thread = $clone
            }
            $extra = [string]$env:TELEPHONE_TEST_APP_SERVER_EXTRA_TURNS
            if (-not [string]::IsNullOrWhiteSpace($extra) -and $include) {
                $extraTurns = $extra | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
                $turns = [Collections.Generic.List[object]]::new()
                foreach ($t in (Get-MockJsonArrayItems -Value (Get-MockDictValue -Dict $thread -Key 'turns'))) { $turns.Add((Convert-MockTurnShape -Turn $t)) }
                if ($extraTurns -is [Collections.IDictionary]) {
                    $turns.Add((Convert-MockTurnShape -Turn $extraTurns))
                } else {
                    foreach ($t in (Get-MockJsonArrayItems -Value $extraTurns)) { $turns.Add((Convert-MockTurnShape -Turn $t)) }
                }
                $clone = [ordered]@{}
                foreach ($key in @($got['thread'].Keys)) { $clone[$key] = $got['thread'][$key] }
                $clone.turns = @($turns)
                $thread = $clone
            }
            Write-MockEvent -Name ('process:' + [string]$PID + ':thread/read')
            Invoke-MockCrash -Point 'after-thread-read'
            Write-MockResult -Id $id -Result ([ordered]@{ thread = $thread })
            continue
        }
        if ($method -ceq 'turn/start') {
            $threadId = Get-MockDictString -Dict $params -Key 'threadId'
            $got = Get-OrCreate-MockThread -ThreadId $threadId -Create
            $thread = $got['thread']
            $store = $got['store']
            $null = Ensure-MockForeignActiveTurn -Thread $thread -Store $store
            if (Test-MockThreadHasInProgressTurn -Thread $thread) {
                Write-MockEvent -Name 'turn/start_busy'
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    Write-MockError -Id $id -Message 'turn already in progress' -Code -32000
                }
                continue
            }
            $forcedStartMessage = [string]$env:TELEPHONE_TEST_APP_SERVER_TURN_START_ERROR_MESSAGE
            if (-not [string]::IsNullOrWhiteSpace($forcedStartMessage)) {
                $forcedCode = -32000
                $forcedCodeRaw = [string]$env:TELEPHONE_TEST_APP_SERVER_TURN_START_ERROR_CODE
                if (-not [string]::IsNullOrWhiteSpace($forcedCodeRaw)) {
                    $parsedForced = 0
                    if ([int]::TryParse($forcedCodeRaw, [ref]$parsedForced)) { $forcedCode = [int]$parsedForced }
                }
                Write-MockEvent -Name 'turn/start_unrelated_error'
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    Write-MockError -Id $id -Message $forcedStartMessage -Code $forcedCode
                }
                continue
            }
            Write-MockEvent -Name 'turn/start'
            Write-MockEvent -Name ('process:' + [string]$PID + ':turn/start')
            Invoke-MockCrash -Point 'before-turn-start'
            $text = Get-MockInputText -Params $params
            $turnId = 'turn-' + [Guid]::NewGuid().ToString('N')
            $historySecret = [string]$env:TELEPHONE_TEST_APP_SERVER_HISTORY_SECRET
            $items = [Collections.Generic.List[object]]::new()
            $items.Add((New-MockUserMessage -Text $text -ItemId ('item-' + $turnId)))
            if (-not [string]::IsNullOrWhiteSpace($historySecret)) {
                $items.Add([ordered]@{
                    type = 'assistantMessage'
                    id = 'asst-' + $turnId
                    clientId = $null
                    content = @(
                        [ordered]@{ type = 'text'; text = $historySecret; text_elements = @() }
                    )
                })
            }
            $turn = New-MockTurn -TurnId $turnId -Items @($items) -Status 'inProgress'
            if ([string]$env:TELEPHONE_TEST_APP_SERVER_OMIT_TURN_ID -ceq '1') {
                $turn = [ordered]@{}
                foreach ($key in @((New-MockTurn -TurnId $turnId -Items @($items) -Status 'inProgress').Keys)) {
                    if ([string]$key -cne 'id') { $turn[$key] = (New-MockTurn -TurnId $turnId -Items @($items) -Status 'inProgress')[$key] }
                }
                $turn.items = @($items)
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_TEST_APP_SERVER_FOREIGN_TURN_ID)) {
                $turn['id'] = [string]$env:TELEPHONE_TEST_APP_SERVER_FOREIGN_TURN_ID
            }
            Write-MockServiceTierEvent -Params $params -Method 'turn/start'
            $turns = [Collections.Generic.List[object]]::new()
            foreach ($existing in (Get-MockJsonArrayItems -Value (Get-MockDictValue -Dict $thread -Key 'turns'))) { $turns.Add($existing) }
            $turns.Add($turn)
            $thread['turns'] = @($turns)
            $thread['status'] = Get-MockEffectiveStatus -Thread $thread
            Save-MockThread -Store $store -Thread $thread
            Invoke-MockCrash -Point 'after-turn-start'
            if ([string]$env:TELEPHONE_TEST_APP_SERVER_UNWRAP_TURN -ceq '1') {
                Write-MockResult -Id $id -Result $turn
            } else {
                $turnResult = [ordered]@{ turn = $turn }
                if ([string]$env:TELEPHONE_TEST_APP_SERVER_TURN_START_EXTRA -ceq '1' -or -not [string]::IsNullOrWhiteSpace([string]$env:TELEPHONE_TEST_APP_SERVER_FOREIGN_TURN_ID)) {
                    $turnResult.threadId = 'other-thread-id'
                    $turnResult.serviceTier = Get-MockReturnedServiceTier -Params $params
                }
                Write-MockResult -Id $id -Result $turnResult
            }
            Write-MockEvent -Name 'turn_start_result'
            Invoke-MockCrash -Point 'after-turn-start-response'
            Write-MockPostStartEvents -ThreadId $threadId -Turn $turn
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            Write-MockError -Id $id -Message ("unsupported method " + $method)
        }
    }
    exit 0
}

if ($script:MockArgList -contains 'generate-json-schema') {
    Invoke-MockGenerateSchema
}
if ($script:MockArgList -contains 'app-server') {
    $listen = Get-MockNamedValue -Name '--listen'
    if (-not [string]::IsNullOrWhiteSpace($listen) -and $listen -cne 'stdio://') {
        [Console]::Error.WriteLine('stdio-only')
        exit 2
    }
    Start-MockStdio
}
if (Test-MockHasArg -Name '--version' -or ($script:MockArgList.Count -eq 1 -and $script:MockArgList[0] -ceq '--version')) {
    if ([string]$env:TELEPHONE_TEST_APP_SERVER_VERSION_FAIL -ceq '1') { exit 2 }
    [Console]::Out.WriteLine($script:Version)
    exit 0
}

[Console]::Error.WriteLine('unsupported mock invocation')
exit 2
