# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'Telephone Line v0.1 supports Windows only.'
}

. (Join-Path $PSScriptRoot '..\..\core\TelephoneLine.Common.ps1')

$script:CursorExternalProductRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
$script:CursorExternalProfileId = 'cursor-external-lead'
$script:CursorExternalRouteId = 'direct-grok-cli'
$script:CursorExternalDirectGrokRelative = 'src\adapters\direct-grok-cli\Invoke-DirectGrokRoute.ps1'
$script:CursorExternalStarterRelative = 'src\core\Start-TelephoneLineJob.ps1'
$script:CursorExternalForbiddenTokenPattern = [regex]'(?i)^(fast|priority|ultrafast)$'
$script:CursorExternalSessionPattern = [regex]'^[A-Za-z0-9._:-]+$'

function Get-CursorExternalProductRoot {
    [CmdletBinding()]
    param()
    return [string]$script:CursorExternalProductRoot
}

function Write-CursorExternalStdoutJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Value)

    $json = ($Value | ConvertTo-Json -Depth 64).Replace("`r`n", "`n") + "`n"
    $utf8 = [Text.UTF8Encoding]::new($false)
    try { [Console]::OutputEncoding = $utf8 } catch { }
    [Console]::Out.Write($json)
}

function Get-CursorExternalDictString {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Dict,
        [Parameter(Mandatory = $true)][string]$Key
    )
    if ($Dict -isnot [Collections.IDictionary] -or -not $Dict.Contains($Key) -or $null -eq $Dict[$Key]) {
        return ''
    }
    return [string]$Dict[$Key]
}

function Test-CursorExternalPathInside {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $full = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return $full.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-CursorExternalReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-CursorExternalNoReparseChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "$Label path is missing a volume root."
    }
    if (Test-CursorExternalReparsePoint -Path $root) {
        throw "$Label path is a reparse point."
    }
    $relative = [IO.Path]::GetRelativePath($root, $full)
    $current = $root.TrimEnd('\')
    foreach ($segment in @($relative.Replace('/', '\').Split([char]'\'))) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -ceq '.') { continue }
        $current = Join-Path $current $segment
        if (([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) -and (Test-CursorExternalReparsePoint -Path $current)) {
            throw "$Label path is a reparse point."
        }
    }
    return [IO.Path]::GetFullPath($full).TrimEnd('\')
}

function ConvertTo-CursorExternalFlatStringArray {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    $flat = [Collections.Generic.List[string]]::new()
    $stack = [Collections.Generic.Stack[object]]::new()
    $stack.Push($Value)
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
            $flat.Add($item)
            continue
        }
        if ($item -is [Array] -or $item -is [Collections.IList]) {
            $count = if ($item -is [Array]) { $item.Length } else { $item.Count }
            $index = $count - 1
            while ($index -ge 0) {
                $stack.Push($item[$index])
                $index -= 1
            }
            continue
        }
        $flat.Add([string]$item)
    }
    $arr = [string[]]::new($flat.Count)
    for ($i = 0; $i -lt $flat.Count; $i++) { $arr[$i] = $flat[$i] }
    return $arr
}

function Get-CursorExternalNamedArgumentValues {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object]$Items,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $values = [Collections.Generic.List[string]]::new()
    $tokens = @(ConvertTo-CursorExternalFlatStringArray -Value $Items)
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i] -ceq $Name -and ($i + 1) -lt $tokens.Count) {
            $values.Add([string]$tokens[$i + 1])
        }
    }
    return [string[]]@($values)
}

function Get-CursorExternalNamedArgumentValue {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object]$Items,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $values = @(Get-CursorExternalNamedArgumentValues -Items $Items -Name $Name)
    if ($values.Count -eq 0) { return $null }
    return [string]$values[0]
}

function Get-CursorExternalNormalizedArgumentName {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    $value = ([string]$Text).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    $stripped = $value.TrimStart([char]'-').TrimStart([char]'/')
    return $stripped.Replace('_', '-').ToLowerInvariant()
}

function Test-CursorExternalForbiddenValue {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    $value = ([string]$Text).Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    return $script:CursorExternalForbiddenTokenPattern.IsMatch($value)
}

function Test-CursorExternalAllowFastName {
    [CmdletBinding()]
    param([AllowNull()][string]$NormalizedName)

    $name = [string]$NormalizedName
    return $name -ceq 'allow-fast' -or $name -ceq 'allowfast'
}

function Test-CursorExternalServiceTierKey {
    [CmdletBinding()]
    param([AllowNull()][string]$NormalizedName)

    $name = [string]$NormalizedName
    return $name -ceq 'service-tier' -or $name -ceq 'servicetier'
}

function Split-CursorExternalAssignmentToken {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    $value = [string]$Text
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    if ($value -match '^[A-Za-z]:[\\/]') { return $null }
    $equals = $value.IndexOf([char]'=')
    if ($equals -gt 0) {
        return [ordered]@{
            key = $value.Substring(0, $equals)
            value = $value.Substring($equals + 1)
        }
    }
    $colon = $value.IndexOf([char]':')
    if ($colon -gt 0) {
        $key = $value.Substring(0, $colon)
        $startsSwitch = $key.StartsWith('-', [StringComparison]::Ordinal) -or $key.StartsWith('/', [StringComparison]::Ordinal)
        $normalized = Get-CursorExternalNormalizedArgumentName -Text $key
        if ($startsSwitch -or (Test-CursorExternalServiceTierKey -NormalizedName $normalized) -or (Test-CursorExternalAllowFastName -NormalizedName $normalized)) {
            return [ordered]@{
                key = $key
                value = $value.Substring($colon + 1)
            }
        }
    }
    return $null
}

function Test-CursorExternalForbiddenToken {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    $value = [string]$Text
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    $trimmed = $value.Trim()
    if (Test-CursorExternalForbiddenValue -Text $trimmed) { return $true }
    $normalized = Get-CursorExternalNormalizedArgumentName -Text $trimmed
    if (Test-CursorExternalForbiddenValue -Text $normalized) { return $true }
    if (Test-CursorExternalAllowFastName -NormalizedName $normalized) { return $true }
    $assignment = Split-CursorExternalAssignmentToken -Text $trimmed
    if ($null -eq $assignment) { return $false }
    $keyName = Get-CursorExternalNormalizedArgumentName -Text ([string]$assignment.key)
    if (Test-CursorExternalAllowFastName -NormalizedName $keyName) { return $true }
    if ((Test-CursorExternalServiceTierKey -NormalizedName $keyName) -and (Test-CursorExternalForbiddenValue -Text ([string]$assignment.value))) {
        return $true
    }
    return $false
}

function Assert-CursorExternalNoForbiddenTokens {
    [CmdletBinding()]
    param([AllowEmptyCollection()][AllowNull()][string[]]$Arguments)

    $tokens = @($Arguments | ForEach-Object { [string]$_ })
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        if (Test-CursorExternalForbiddenToken -Text $tokens[$i]) {
            throw 'Dispatch arguments must not contain Fast, priority, or ultrafast tokens.'
        }
        $name = Get-CursorExternalNormalizedArgumentName -Text $tokens[$i]
        if ((Test-CursorExternalServiceTierKey -NormalizedName $name) -and (($i + 1) -lt $tokens.Count)) {
            if (Test-CursorExternalForbiddenValue -Text $tokens[$i + 1]) {
                throw 'Dispatch arguments must not contain Fast, priority, or ultrafast tokens.'
            }
        }
    }
}

function Protect-CursorExternalText {
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [int]$MaxLength = 500)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $safe = [string]$Text
    if ($safe.Length -le $MaxLength) { return $safe }
    return $safe.Substring(0, $MaxLength) + '...[truncated]'
}

function Read-CursorExternalLeadDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LeadRunRoot,
        [Parameter(Mandatory = $true)][string]$Worktree
    )

    $runRoot = Assert-TelephoneDirectoryPath -Path $LeadRunRoot -Label 'Lead run root'
    Assert-CursorExternalNoReparseChain -Path $runRoot -Label 'Lead run root' | Out-Null
    $descriptorPath = Join-Path $runRoot 'lead-run.json'
    $descriptorRead = Read-TelephoneJson -Path $descriptorPath
    $descriptor = $descriptorRead.value
    if ($descriptor -isnot [Collections.IDictionary]) {
        throw 'Lead descriptor is malformed.'
    }
    $recordedWorktree = Get-CursorExternalDictString -Dict $descriptor -Key 'worktree'
    if ([string]::IsNullOrWhiteSpace($recordedWorktree)) {
        throw 'Lead descriptor worktree is missing.'
    }
    $recordedFull = [IO.Path]::GetFullPath($recordedWorktree).TrimEnd('\')
    $injectedFull = [IO.Path]::GetFullPath($Worktree).TrimEnd('\')
    if (-not $recordedFull.Equals($injectedFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Lead descriptor worktree does not match the injected worktree.'
    }
    return [ordered]@{
        identity = $descriptorRead.identity
        value = $descriptor
        run_root = $runRoot
        worktree = $injectedFull
        recorded_session_id = Get-CursorExternalDictString -Dict $descriptor -Key 'session_id'
        recorded_launcher = Get-CursorExternalDictString -Dict $descriptor -Key 'launcher'
    }
}

function Get-CursorExternalSessionIdsFromEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $identity = Get-TelephoneFileIdentity -Path $Path
    $bytes = [IO.File]::ReadAllBytes([string]$identity.path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'Lead event stream must not contain a UTF-8 BOM.'
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).Replace("`r`n", "`n").Replace("`r", "`n")
    $ids = [Collections.Generic.List[string]]::new()
    foreach ($line in @($text.Split([char]0x0A))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $record = $line | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
        if ($record -isnot [Collections.IDictionary]) {
            throw 'Lead event stream contains a non-object record.'
        }
        $type = Get-CursorExternalDictString -Dict $record -Key 'type'
        if ($type -cne 'thread.started') { continue }
        $id = Get-CursorExternalDictString -Dict $record -Key 'thread_id'
        if ([string]::IsNullOrWhiteSpace($id)) {
            $id = Get-CursorExternalDictString -Dict $record -Key 'session_id'
        }
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'Lead event stream has a thread.started event without a session id.'
        }
        $ids.Add($id)
    }
    return [string[]]@($ids)
}

function Resolve-CursorExternalLeadSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LeadRunRoot,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [string]$CallerSessionId = ''
    )

    $descriptor = Read-CursorExternalLeadDescriptor -LeadRunRoot $LeadRunRoot -Worktree $Worktree
    $eventsPath = Join-Path $descriptor.run_root 'codex-events.jsonl'
    if (-not [IO.File]::Exists($eventsPath)) {
        throw 'Lead event stream is missing.'
    }
    $ids = @(Get-CursorExternalSessionIdsFromEvents -Path $eventsPath)
    if ($ids.Count -eq 0) {
        throw 'Lead event stream has no session.'
    }
    $derived = [string]$ids[0]
    foreach ($id in $ids) {
        if ([string]$id -cne $derived) {
            throw 'Lead event stream has more than one session.'
        }
    }
    if (-not $script:CursorExternalSessionPattern.IsMatch($derived)) {
        throw 'Derived Lead session id is malformed.'
    }
    if (-not [string]::IsNullOrWhiteSpace($CallerSessionId) -and $CallerSessionId -cne $derived) {
        throw 'Caller-supplied session id does not match the derived Lead session.'
    }
    $recorded = [string]$descriptor.recorded_session_id
    if (-not [string]::IsNullOrWhiteSpace($recorded) -and $recorded -cne $derived) {
        throw 'Lead descriptor session id does not match the derived Lead session.'
    }
    return [ordered]@{
        session_id = $derived
        run_root = [string]$descriptor.run_root
        worktree = [string]$descriptor.worktree
        descriptor = $descriptor
    }
}

function Assert-CursorExternalScratchDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$LeadWorktree,
        [Parameter(Mandatory = $true)][string]$ProductRoot
    )

    $workspace = Assert-TelephoneDirectoryPath -Path $WorkspacePath -Label 'Direct Grok scratch'
    Assert-CursorExternalNoReparseChain -Path $workspace -Label 'Direct Grok scratch' | Out-Null
    $lead = [IO.Path]::GetFullPath($LeadWorktree).TrimEnd('\')
    $product = [IO.Path]::GetFullPath($ProductRoot).TrimEnd('\')
    if ($workspace.Equals($lead, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Direct Grok scratch must not be the Lead worktree.'
    }
    if ($workspace.Equals($product, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Direct Grok scratch must not be the product tree.'
    }
    if ((Test-CursorExternalPathInside -Candidate $workspace -Root $lead) -or (Test-CursorExternalPathInside -Candidate $lead -Root $workspace)) {
        throw 'Direct Grok scratch overlaps the Lead worktree.'
    }
    if ((Test-CursorExternalPathInside -Candidate $workspace -Root $product) -or (Test-CursorExternalPathInside -Candidate $product -Root $workspace)) {
        throw 'Direct Grok scratch overlaps the product tree.'
    }
    $children = @([IO.Directory]::GetFileSystemEntries($workspace))
    if ($children.Count -gt 0) {
        throw 'Direct Grok scratch must be empty.'
    }
    return $workspace
}

function Assert-CursorExternalJobAbsent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($StateRoot)) {
        throw "$Label state root is required."
    }
    $full = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    $jobRoot = Join-Path $full ('jobs\' + $JobId)
    if ([IO.Directory]::Exists($jobRoot) -or [IO.File]::Exists($jobRoot)) {
        throw "$Label job already exists; create-new refused."
    }
    return $jobRoot
}

function Assert-CursorExternalOutputAbsent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        throw "$Label already exists; create-new refused."
    }
    return $full
}

function Get-CursorExternalDirectGrokEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProductRoot)

    $path = Join-Path $ProductRoot $script:CursorExternalDirectGrokRelative
    return Assert-TelephoneRegularFilePath -Path $path -Label 'Direct Grok adapter'
}

function Get-CursorExternalStarterPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProductRoot)

    $path = Join-Path $ProductRoot $script:CursorExternalStarterRelative
    return Assert-TelephoneRegularFilePath -Path $path -Label 'Telephone Line starter'
}

function New-CursorExternalDirectGrokArgumentList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EntryPath,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$JobId
    )

    $list = [Collections.Generic.List[string]]::new()
    foreach ($item in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $EntryPath,
            '-Operation', 'start',
            '-StateRoot', $StateRoot,
            '-WorkspacePath', $WorkspacePath,
            '-PromptFile', $PromptFile,
            '-JobId', $JobId,
            '-GrokTimeoutSeconds', '0',
            '-WaitTimeoutSeconds', '0'
        )) {
        $list.Add([string]$item)
    }
    return [string[]]@($list)
}

function Assert-CursorExternalDirectGrokArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$EntryPath
    )

    Assert-CursorExternalNoForbiddenTokens -Arguments $Arguments
    $fileValues = @(Get-CursorExternalNamedArgumentValues -Items $Arguments -Name '-File')
    if ($fileValues.Count -ne 1) {
        throw 'Dispatch command must bind exactly one -File entry.'
    }
    $fileFull = [IO.Path]::GetFullPath([string]$fileValues[0])
    $entryFull = [IO.Path]::GetFullPath($EntryPath)
    if (-not $fileFull.Equals($entryFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Dispatch command must point at the existing Direct Grok adapter.'
    }
    $operation = Get-CursorExternalNamedArgumentValue -Items $Arguments -Name '-Operation'
    if ($operation -cne 'start') {
        throw 'Dispatch command must use Operation start.'
    }
    foreach ($name in @('-GrokTimeoutSeconds', '-WaitTimeoutSeconds')) {
        $timeoutValues = @(Get-CursorExternalNamedArgumentValues -Items $Arguments -Name $name)
        if ($timeoutValues.Count -ne 1 -or [string]$timeoutValues[0] -cne '0') {
            throw "Timeout argument must be 0: $name"
        }
    }
    $native = @(Get-CursorExternalNamedArgumentValues -Items $Arguments -Name '-NativeSessionId')
    if ($native.Count -ne 0) {
        throw 'Adapter start must not receive a native session id.'
    }
}

function New-CursorExternalLeadBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [AllowNull()][AllowEmptyCollection()][string[]]$LauncherArguments
    )

    $argsList = @()
    if ($null -ne $LauncherArguments) {
        $argsList = @($LauncherArguments | ForEach-Object { [string]$_ })
    }
    Assert-CursorExternalNoForbiddenTokens -Arguments $argsList
    foreach ($item in $argsList) {
        if ([string]$item -ceq '-File') {
            throw 'Lead launcher arguments cannot add a second route.'
        }
    }
    $binding = [ordered]@{
        protocol_version = 'telephone-line-lead-binding-v1'
        session_id = [string]$SessionId
        worktree = [string]$Worktree
        launcher = [ordered]@{
            path = [string]$LauncherPath
            arguments = @($argsList)
        }
    }
    $json = (($binding | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n")
    Assert-TelephoneJsonSchema -JsonText $json -SchemaName 'lead-binding' -Label 'Lead binding'
    return $binding
}

function New-CursorExternalDispatchRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LineJobId,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$Route,
        [Parameter(Mandatory = $true)][string]$Summary,
        [Parameter(Mandatory = $true)][string]$BindingPath,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments
    )

    $request = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'
        line_job_id = [string]$LineJobId
        project = [string]$Project
        stage = [string]$Stage
        role = [string]$Role
        route = [string]$Route
        summary = [string]$Summary
        lead = [ordered]@{
            binding_file = [string]$BindingPath
        }
        command = [ordered]@{
            executable = [string]$Executable
            working_directory = [string]$WorkingDirectory
            arguments = @($Arguments | ForEach-Object { [string]$_ })
        }
    }
    $json = (($request | ConvertTo-Json -Depth 16).Replace("`r`n", "`n") + "`n")
    Assert-TelephoneDispatchRequestText -JsonText $json
    return $request
}

function Get-CursorExternalPreparedDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LeadRunRoot,
        [Parameter(Mandatory = $true)][string]$LeadWorktree,
        [Parameter(Mandatory = $true)][string]$LeadLauncher,
        [AllowNull()][AllowEmptyCollection()][string[]]$LeadLauncherArguments,
        [string]$SessionId = '',
        [Parameter(Mandatory = $true)][string]$LineJobId,
        [Parameter(Mandatory = $true)][string]$ExecutorJobId,
        [Parameter(Mandatory = $true)][string]$TelephoneLineStateRoot,
        [Parameter(Mandatory = $true)][string]$DirectGrokStateRoot,
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$BindingOutputPath,
        [Parameter(Mandatory = $true)][string]$RequestOutputPath,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Summary,
        [string]$Role = 'execution',
        [string]$Route = 'direct-grok-cli'
    )

    if ($LineJobId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'line_job_id must be a UUID.'
    }
    if ($ExecutorJobId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'executor job id must be a UUID.'
    }
    if ($Role -cnotin @('execution', 'review')) {
        throw 'role must be execution or review.'
    }
    if ([string]$Route -cne $script:CursorExternalRouteId) {
        throw 'This compatibility profile only emits the existing Direct Grok adapter.'
    }
    foreach ($label in @($Project, $Stage, $Summary)) {
        if ([string]::IsNullOrWhiteSpace([string]$label)) {
            throw 'Dispatch field is empty.'
        }
    }

    $injectedLauncherArguments = @()
    if ($null -ne $LeadLauncherArguments) {
        $injectedLauncherArguments = @($LeadLauncherArguments | ForEach-Object { [string]$_ })
    }
    Assert-CursorExternalNoForbiddenTokens -Arguments $injectedLauncherArguments

    $productRoot = Get-CursorExternalProductRoot
    $worktree = Assert-TelephoneDirectoryPath -Path $LeadWorktree -Label 'Lead worktree'
    Assert-CursorExternalNoReparseChain -Path $worktree -Label 'Lead worktree' | Out-Null
    $launcherPath = Assert-TelephoneRegularFilePath -Path $LeadLauncher -Label 'Lead launcher'
    $resolved = Resolve-CursorExternalLeadSession -LeadRunRoot $LeadRunRoot -Worktree $worktree -CallerSessionId $SessionId
    $workspace = Assert-CursorExternalScratchDirectory -WorkspacePath $WorkspacePath -LeadWorktree $worktree -ProductRoot $productRoot
    $promptPath = Assert-TelephoneRegularFilePath -Path $PromptFile -Label 'Prompt file'
    $grokEntry = Get-CursorExternalDirectGrokEntry -ProductRoot $productRoot
    $null = Get-CursorExternalStarterPath -ProductRoot $productRoot
    $telephoneState = [IO.Path]::GetFullPath($TelephoneLineStateRoot).TrimEnd('\')
    $grokState = [IO.Path]::GetFullPath($DirectGrokStateRoot).TrimEnd('\')
    $null = Assert-CursorExternalJobAbsent -StateRoot $telephoneState -JobId $LineJobId -Label 'Telephone Line'
    $null = Assert-CursorExternalJobAbsent -StateRoot $grokState -JobId $ExecutorJobId -Label 'Direct Grok'
    $bindingPath = Assert-CursorExternalOutputAbsent -Path $BindingOutputPath -Label 'Lead binding'
    $requestPath = Assert-CursorExternalOutputAbsent -Path $RequestOutputPath -Label 'Dispatch request'
    $recordedLauncher = [string]$resolved.descriptor.recorded_launcher
    if (-not [string]::IsNullOrWhiteSpace($recordedLauncher)) {
        $recordedFull = [IO.Path]::GetFullPath($recordedLauncher)
        if (-not $recordedFull.Equals($launcherPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Lead descriptor launcher does not match the injected launcher.'
        }
    }
    $argumentList = @(New-CursorExternalDirectGrokArgumentList -EntryPath $grokEntry -StateRoot $grokState -WorkspacePath $workspace -PromptFile $promptPath -JobId $ExecutorJobId)
    Assert-CursorExternalDirectGrokArguments -Arguments $argumentList -EntryPath $grokEntry
    $binding = New-CursorExternalLeadBinding -SessionId ([string]$resolved.session_id) -Worktree $worktree -LauncherPath $launcherPath -LauncherArguments $LeadLauncherArguments
    $executable = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $executable = Assert-TelephoneRegularFilePath -Path $executable -Label 'Route executable'
    $request = New-CursorExternalDispatchRequest -LineJobId $LineJobId -Project $Project -Stage $Stage -Role $Role -Route $Route -Summary $Summary -BindingPath $bindingPath -Executable $executable -WorkingDirectory $workspace -Arguments $argumentList
    return [ordered]@{
        product_root = $productRoot
        session_id = [string]$resolved.session_id
        worktree = $worktree
        launcher = $launcherPath
        grok_entry = $grokEntry
        workspace = $workspace
        prompt = $promptPath
        telephone_state_root = $telephoneState
        grok_state_root = $grokState
        line_job_id = $LineJobId
        executor_job_id = $ExecutorJobId
        binding_path = $bindingPath
        request_path = $requestPath
        binding = $binding
        request = $request
        started = $false
    }
}

function Resolve-CursorExternalJobStage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$JobRoot)

    $root = [IO.Path]::GetFullPath($JobRoot).TrimEnd('\')
    if ([IO.File]::Exists((Join-Path $root 'receipt.json'))) { return 'receipt_sealed' }
    $anyOwnerAlive = $false
    foreach ($name in @('owner.json', 'command-owner.json', 'relay-owner.json')) {
        $ownerPath = Join-Path $root $name
        if (-not [IO.File]::Exists($ownerPath)) { continue }
        $owner = (Read-TelephoneJson -Path $ownerPath).value
        if (Test-TelephoneOwnerAlive -Owner $owner) {
            $anyOwnerAlive = $true
        }
    }
    if ($anyOwnerAlive) { return 'running' }
    $intentExists = $false
    foreach ($name in @('launch-intent.json', 'command-start-intent.json', 'command-launch.json')) {
        if ([IO.File]::Exists((Join-Path $root $name))) { $intentExists = $true; break }
    }
    if ($intentExists) { return 'interrupted_no_receipt' }
    foreach ($name in @('dispatch.json', 'request.json', 'lead-run.json', 'lead-binding.json')) {
        if ([IO.File]::Exists((Join-Path $root $name))) { return 'dispatched' }
    }
    return 'unknown'
}

function Get-CursorExternalLeadIdentityFromJob {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$JobRoot)

    $root = [IO.Path]::GetFullPath($JobRoot).TrimEnd('\')
    foreach ($name in @('lead-binding.json', 'dispatch.json', 'request.json', 'lead-run.json')) {
        $path = Join-Path $root $name
        if (-not [IO.File]::Exists($path)) { continue }
        $parsed = (Read-TelephoneJson -Path $path).value
        if ($parsed -isnot [Collections.IDictionary]) { continue }
        if ($name -ceq 'dispatch.json' -and $parsed.Contains('lead') -and $parsed.lead -is [Collections.IDictionary]) {
            return [ordered]@{
                session_id = Get-CursorExternalDictString -Dict $parsed.lead -Key 'session_id'
                worktree = Get-CursorExternalDictString -Dict $parsed.lead -Key 'worktree'
            }
        }
        $sessionId = Get-CursorExternalDictString -Dict $parsed -Key 'session_id'
        $worktree = Get-CursorExternalDictString -Dict $parsed -Key 'worktree'
        if (-not [string]::IsNullOrWhiteSpace($sessionId) -or -not [string]::IsNullOrWhiteSpace($worktree)) {
            return [ordered]@{
                session_id = $sessionId
                worktree = $worktree
            }
        }
    }
    return [ordered]@{
        session_id = ''
        worktree = ''
    }
}
