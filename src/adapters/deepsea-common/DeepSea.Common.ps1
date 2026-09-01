# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Telephone Line v0.1 adapters support Windows only.' }

$script:DeepSeaPublicErrorCatalog = [ordered]@{
    ADAPTER_TRANSPORT_FAILED = 'Telephone-line adapter transport failed.'
    ADAPTER_NATIVE_SESSION_MISMATCH = 'Adapter native session id does not match the frozen session.'
    ADAPTER_NATIVE_SESSION_MISSING = 'Adapter native session id is missing or unknown.'
    ADAPTER_DURABLE_STATE_MISSING = 'Adapter durable state was not found.'
    ADAPTER_DUPLICATE_INCOMPLETE = 'Adapter duplicate start found incomplete durable state; refusing automatic rerun.'
    ADAPTER_HEADLESS_RESULT_INVALID = 'Headless returned a malformed, ambiguous, or nonterminal result.'
    ADAPTER_REQUEST_INVALID = 'Adapter request is invalid.'
    ADAPTER_SIDECAR_REJECTED = 'DeepSea adapters reject sidecar or direct-plugin shapes.'
    ADAPTER_PROMPT_REQUIRED = 'DeepSea start and follow-up require workspace and prompt identities.'
    ADAPTER_HEADLESS_INVOCATION_FAILED = 'User-installed DSH Headless command did not complete.'
    ADAPTER_OPERATION_UNSUPPORTED = 'Adapter does not advertise the requested operation.'
    MODEL_PROTOCOL_UNAVAILABLE = 'The selected model protocol is unavailable on this route.'
}

$script:DeepSeaPluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'dsh-plugin'))

function Get-DeepSeaPublicErrorMessage {
    [CmdletBinding()]
    param([string]$ErrorCode)
    $code = [string]$ErrorCode
    if (-not [string]::IsNullOrWhiteSpace($code) -and $script:DeepSeaPublicErrorCatalog.Contains($code)) {
        return [string]$script:DeepSeaPublicErrorCatalog[$code]
    }
    return [string]$script:DeepSeaPublicErrorCatalog['ADAPTER_TRANSPORT_FAILED']
}

function Get-DeepSeaDurableErrorCode {
    [CmdletBinding()]
    param([string]$ErrorCode)
    $code = [string]$ErrorCode
    if (-not [string]::IsNullOrWhiteSpace($code) -and $script:DeepSeaPublicErrorCatalog.Contains($code)) {
        return $code
    }
    return 'ADAPTER_TRANSPORT_FAILED'
}

function ConvertTo-DeepSeaPublicFailure {
    [CmdletBinding()]
    param([AllowNull()][string]$Message, [string]$ErrorCode)
    $code = Get-DeepSeaDurableErrorCode -ErrorCode $ErrorCode
    $text = [string]$Message
    if ([string]::IsNullOrWhiteSpace($ErrorCode)) {
        if ($text -cmatch '(?i)MODEL_PROTOCOL_UNAVAILABLE|model protocol is unavailable') { $code = 'MODEL_PROTOCOL_UNAVAILABLE' }
        elseif ($text -cmatch '(?i)does not advertise|operation is not supported|unsupported operation') { $code = 'ADAPTER_OPERATION_UNSUPPORTED' }
        elseif ($text -cmatch '(?i)native session id does not match|another session') { $code = 'ADAPTER_NATIVE_SESSION_MISMATCH' }
        elseif ($text -cmatch '(?i)malformed, ambiguous, or nonterminal|Headless result|session record') { $code = 'ADAPTER_HEADLESS_RESULT_INVALID' }
        elseif ($text -cmatch '(?i)missing or unknown|native session id is required|is malformed') { $code = 'ADAPTER_NATIVE_SESSION_MISSING' }
        elseif ($text -cmatch '(?i)sidecar|direct-plugin') { $code = 'ADAPTER_SIDECAR_REJECTED' }
        elseif ($text -cmatch '(?i)request') { $code = 'ADAPTER_REQUEST_INVALID' }
        elseif ($text -cmatch '(?i)incomplete durable') { $code = 'ADAPTER_DUPLICATE_INCOMPLETE' }
        elseif ($text -cmatch '(?i)durable state was not found') { $code = 'ADAPTER_DURABLE_STATE_MISSING' }
        elseif ($text -cmatch '(?i)workspace and prompt') { $code = 'ADAPTER_PROMPT_REQUIRED' }
        elseif ($text -cmatch '(?i)Headless command') { $code = 'ADAPTER_HEADLESS_INVOCATION_FAILED' }
        else { $code = 'ADAPTER_TRANSPORT_FAILED' }
    }
    return [ordered]@{
        error_code = $code
        error_message = Get-DeepSeaPublicErrorMessage -ErrorCode $code
    }
}

function Get-DeepSeaFileIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Expected a regular file.' }
    $bytes = [IO.File]::ReadAllBytes($full)
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$bytes.Length
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
}

function Get-DeepSeaTextIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    return [ordered]@{
        bytes = [int64]$bytes.Length
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
}

function Write-DeepSeaJsonCreateNew {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((($Value | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n"))
    $stream = [IO.FileStream]::new($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    return Get-DeepSeaFileIdentity -Path $full
}

function Write-DeepSeaJsonReplace {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((($Value | ConvertTo-Json -Depth 32).Replace("`r`n", "`n") + "`n"))
    [IO.File]::WriteAllBytes($full, $bytes)
    return Get-DeepSeaFileIdentity -Path $full
}

function Read-DeepSeaJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $identity = Get-DeepSeaFileIdentity -Path $Path
    $bytes = [IO.File]::ReadAllBytes([string]$identity.path)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    return [ordered]@{
        identity = $identity
        value = $text | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
    }
}

function Assert-DeepSeaHeadlessBoundary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $name = [IO.Path]::GetFileName($full)
    if ([IO.Path]::GetExtension($full) -ieq '.mjs') { throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_SIDECAR_REJECTED') }
    if ($name -match '(?i)sidecar|direct-plugin') { throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_SIDECAR_REJECTED') }
}

function Assert-DeepSeaNativeSessionId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value, [string]$Label = 'Adapter native session id')
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -cnotmatch '^[A-Za-z0-9._:-]{1,128}$') {
        throw "$Label is malformed."
    }
}

function Assert-DeepSeaJobId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value, [string]$Label = 'job_id')
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -cnotmatch '^[A-Za-z0-9_-]{1,128}$') {
        throw "Adapter request $Label is invalid."
    }
}

function ConvertTo-DeepSeaPublicOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)
    switch ([string]$Value) {
        'start' { return 'start' }
        'follow_up' { return 'follow_up' }
        'followup' { return 'follow_up' }
        'recover' { return 'recover' }
        'status' { return 'recover' }
        default { throw 'Request operation must be start, followup, follow_up, status, or recover.' }
    }
}

function Test-DeepSeaCapability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Route,
        [Parameter(Mandatory = $true)][string]$Operation
    )
    if (-not $Route.Contains('capabilities') -or $null -eq $Route.capabilities) { return $false }
    $caps = $Route.capabilities
    if (-not $caps.Contains($Operation)) { return $false }
    return [bool]$caps[$Operation]
}

function Test-DeepSeaForbiddenModelVariant {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Model)
    return [bool]($Model -imatch '(^|[^A-Za-z0-9])(fast|priority|ultrafast)([^A-Za-z0-9]|$)')
}

function Get-DeepSeaRouteConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Route,
        [string]$Model,
        [string]$ReasoningEffort,
        [bool]$ModelSpecified = $false,
        [bool]$ReasoningEffortSpecified = $false
    )
    $provider = [string]$Route.provider
    if ($provider -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw 'Adapter request is invalid.'
    }
    $allowed = @()
    if ($Route.Contains('allowed_reasoning_effort') -and $null -ne $Route.allowed_reasoning_effort) {
        $allowed = @($Route.allowed_reasoning_effort | ForEach-Object { [string]$_ })
    }
    if ($allowed.Count -lt 1) { throw 'Adapter request is invalid.' }
    foreach ($item in $allowed) {
        if ([string]::IsNullOrWhiteSpace($item) -or $item -cnotmatch '^[A-Za-z0-9._:-]{1,32}$') {
            throw 'Adapter request is invalid.'
        }
    }
    $model = if ($ModelSpecified) { [string]$Model } else { [string]$Route.model }
    $effort = ''
    if ($ReasoningEffortSpecified) {
        $effort = [string]$ReasoningEffort
    } elseif ($Route.Contains('reasoning_effort') -and $null -ne $Route.reasoning_effort) {
        $effort = [string]$Route.reasoning_effort
    }
    if ([string]::IsNullOrWhiteSpace($model)) { throw 'Adapter request is invalid.' }
    $model = $model.Trim()
    if ($model -cnotmatch '^[A-Za-z0-9._:-]{1,128}$') { throw 'Adapter request is invalid.' }
    if (Test-DeepSeaForbiddenModelVariant -Model $model) { throw 'Adapter request is invalid.' }
    if ($ReasoningEffortSpecified -or -not [string]::IsNullOrWhiteSpace($effort)) {
        if ([string]::IsNullOrWhiteSpace($effort)) { throw 'Adapter request is invalid.' }
        $effort = $effort.Trim()
        if ($effort -cnotmatch '^[A-Za-z0-9._:-]{1,32}$') { throw 'Adapter request is invalid.' }
        if ($effort -cnotin $allowed) { throw 'Adapter request is invalid.' }
    } else {
        $effort = ''
    }
    return [ordered]@{
        provider = $provider
        model = $model
        reasoning_effort = $effort
        allowed_reasoning_effort = @($allowed)
    }
}

function Resolve-DeepSeaHeadlessTarget {
    [CmdletBinding()]
    param([string]$DshCommand, [string]$MockHeadlessPath)
    $path = $null
    $source = $null
    if (-not [string]::IsNullOrWhiteSpace($MockHeadlessPath)) {
        $path = [IO.Path]::GetFullPath($MockHeadlessPath)
        $source = 'mock'
    } elseif (-not [string]::IsNullOrWhiteSpace($DshCommand)) {
        $path = [IO.Path]::GetFullPath($DshCommand)
        $source = 'explicit'
    } else {
        $cmd = Get-Command 'dsh' -ErrorAction SilentlyContinue
        if ($null -eq $cmd) { $cmd = Get-Command 'dsh.cmd' -ErrorAction SilentlyContinue }
        if ($null -eq $cmd -or [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $profileBin = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh\profiles\node_modules\@deepseek-ai\dsh\lib\bin.js'
            if ([IO.File]::Exists($profileBin)) {
                $path = [IO.Path]::GetFullPath($profileBin)
                $source = 'dsh-home'
            } else {
                throw 'User-installed DSH Headless command was not found. Pass -DshCommand.'
            }
        } else {
            $path = [IO.Path]::GetFullPath([string]$cmd.Source)
            $source = 'path'
        }
    }
    Assert-DeepSeaHeadlessBoundary -Path $path
    if (-not [IO.File]::Exists($path)) { throw 'User-installed DSH Headless command does not exist.' }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'User-installed DSH Headless command is not a regular file.'
    }
    $extension = [IO.Path]::GetExtension($path)
    $kind = if ($extension -ieq '.ps1') { 'powershell-headless' } elseif ($extension -ieq '.js') { 'node-javascript' } else { 'executable' }
    $name = [IO.Path]::GetFileNameWithoutExtension($path)
    if ($name -imatch '^(codex|cursor|grok)$') { throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_SIDECAR_REJECTED') }
    return [ordered]@{ path = $path; kind = $kind; source = $source }
}

function Get-DeepSeaSubscriptionStorePath {
    [CmdletBinding()]
    param()
    $override = [Environment]::GetEnvironmentVariable('TELEPHONE_LINE_DSH_SUBSCRIPTION_STORE')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        return [IO.Path]::GetFullPath($override)
    }
    return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh\subscription-oauth.json'
}

function Copy-DeepSeaRegularFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
    $src = Get-DeepSeaFileIdentity -Path $Source
    $parent = [IO.Path]::GetDirectoryName($Destination)
    if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::Copy([string]$src.path, $Destination, $true)
    $copied = Get-DeepSeaFileIdentity -Path $Destination
    if ([int64]$copied.bytes -ne [int64]$src.bytes -or [string]$copied.sha256 -cne [string]$src.sha256) {
        throw 'Contained plugin copy identity mismatch.'
    }
    return $copied
}

function New-DeepSeaContainedProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$HomeRoot,
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ReasoningEffort,
        [Parameter(Mandatory = $true)][bool]$IncludeSubscriptionOauth
    )
    if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort) -and $ReasoningEffort -cnotmatch '^[A-Za-z0-9._:-]{1,32}$') {
        throw 'Adapter request is invalid.'
    }
    $dshHome = [IO.Path]::GetFullPath($HomeRoot).TrimEnd('\')
    [IO.Directory]::CreateDirectory($dshHome) | Out-Null
    $profileDir = Join-Path $dshHome 'profiles\headless'
    $pluginDir = Join-Path $profileDir 'plugins\telephone-line'
    [IO.Directory]::CreateDirectory($pluginDir) | Out-Null
    $shared = @(
        'package.json',
        'resolve-modules.mjs',
        'headless-startup.mjs',
        'headless-runner.mjs'
    )
    $subscriptionFiles = @(
        'subscription-store.mjs',
        'subscription-llm.mjs',
        'llm-plugin.mjs'
    )
    foreach ($name in $shared) {
        $null = Copy-DeepSeaRegularFile -Source (Join-Path $script:DeepSeaPluginRoot $name) -Destination (Join-Path $pluginDir $name)
    }
    if ($IncludeSubscriptionOauth) {
        foreach ($name in $subscriptionFiles) {
            $null = Copy-DeepSeaRegularFile -Source (Join-Path $script:DeepSeaPluginRoot $name) -Destination (Join-Path $pluginDir $name)
        }
    }
    $profilePackage = [ordered]@{
        name = 'dsh-profile-headless'
        private = $true
        dependencies = [ordered]@{}
        dsh = [ordered]@{
            profile = [ordered]@{
                bundles = @('@deepseek-ai/dsh-base', '@deepseek-ai/dsh-headless')
            }
        }
    }
    $null = Write-DeepSeaJsonCreateNew -Path (Join-Path $profileDir 'package.json') -Value $profilePackage
    $cordisRoot = "# dsh profile root composed from bundles then cordis.patch.yml.`n[]`n"
    [IO.File]::WriteAllText((Join-Path $profileDir 'cordis.yml'), $cordisRoot, [Text.UTF8Encoding]::new($false))
    $insert = [Collections.Generic.List[string]]::new()
    if ($IncludeSubscriptionOauth) {
        [void]$insert.Add('    - id: telephone-line-llm-subscription')
        [void]$insert.Add('      name: ./plugins/telephone-line/llm-plugin.mjs')
    }
    [void]$insert.Add('    - id: telephone-line-headless-startup')
    [void]$insert.Add('      name: ./plugins/telephone-line/headless-startup.mjs')
    [void]$insert.Add('    - id: telephone-line-headless-runner')
    [void]$insert.Add('      name: ./plugins/telephone-line/headless-runner.mjs')
    [void]$insert.Add('      inject: [headlessStartup]')
    [void]$insert.Add('      config:')
    [void]$insert.Add('        task: !!js ctx.headlessStartup.task')
    [void]$insert.Add('        resumeSessionId: !!js ctx.headlessStartup.resumeSessionId')
    [void]$insert.Add('        sessionOut: !!js ctx.headlessStartup.sessionOut')
    if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) {
        [void]$insert.Add("        reasoningEffort: $ReasoningEffort")
    }
    $patch = @(
        '# Telephone Line contained DSH overlay. Plugin names are relative to this profile directory.',
        '- insert:',
        ($insert -join "`n"),
        '',
        '- id: agent-default-model',
        '  config:',
        "    provider: $Provider",
        "    model: $Model",
        '',
        '- id: session-telemetry-otel',
        '  disabled: true',
        '',
        '- id: web',
        '  disabled: true',
        '',
        '- id: web-search-deepseek',
        '  disabled: true',
        '',
        '- id: tool-web',
        '  disabled: true',
        '',
        '- id: session-title-llm',
        '  disabled: true',
        '',
        '- id: headless-startup',
        '  disabled: true',
        '',
        '- id: headless-runner',
        '  disabled: true',
        '',
        '- id: hmr',
        '  disabled: true',
        ''
    ) -join "`n"
    $patchPath = Join-Path $profileDir 'cordis.patch.yml'
    [IO.File]::WriteAllText($patchPath, $patch.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    foreach ($path in @($profileDir, $pluginDir, $patchPath, (Join-Path $profileDir 'cordis.yml'), (Join-Path $profileDir 'package.json'))) {
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Contained DSH profile path is a reparse point.' }
    }
    return [ordered]@{
        home = $dshHome
        profile_dir = $profileDir
        plugin_dir = $pluginDir
        patch = $patchPath
        provider = $Provider
        model = $Model
        reasoning_effort = $ReasoningEffort
    }
}

function Invoke-DeepSeaOwnedHarness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Target,
        [Parameter(Mandatory = $true)][string]$HomeRoot,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Task,
        [string]$ResumeSessionId,
        [Parameter(Mandatory = $true)][string]$SessionOutPath,
        [string]$CommunityCredentialKey
    )
    Assert-DeepSeaHeadlessBoundary -Path ([string]$Target.path)
    if ([string]::IsNullOrWhiteSpace($Task)) { throw 'Headless mode requires a non-empty prompt.' }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $info.WorkingDirectory = $Workspace
    $info.Environment['DSH_HOME'] = $HomeRoot
    $info.Environment['DSH_TELEMETRY_DISABLED'] = '1'
    $info.Environment['DSH_TELEMETRY_MODE'] = 'DISABLED'
    $info.Environment['TELEPHONE_LINE_DSH_SUBSCRIPTION_STORE'] = (Get-DeepSeaSubscriptionStorePath)
    if ($info.Environment.ContainsKey('TELEPHONE_LINE_DSH_CODEX_COMMUNITY_KEY')) {
        [void]$info.Environment.Remove('TELEPHONE_LINE_DSH_CODEX_COMMUNITY_KEY')
    }
    if (-not [string]::IsNullOrWhiteSpace($CommunityCredentialKey)) {
        $info.Environment['TELEPHONE_LINE_DSH_CODEX_COMMUNITY_KEY'] = $CommunityCredentialKey
    }
    $info.Environment['NODE_USE_ENV_PROXY'] = '1'
    foreach ($drop in @('XAI_API_KEY', 'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'CURSOR_API_KEY')) {
        if ($info.Environment.ContainsKey($drop)) { [void]$info.Environment.Remove($drop) }
    }
    $dshArgs = [Collections.Generic.List[string]]::new()
    [void]$dshArgs.Add('--profile')
    [void]$dshArgs.Add('headless')
    if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) {
        [void]$dshArgs.Add('--resume')
        [void]$dshArgs.Add($ResumeSessionId)
    }
    [void]$dshArgs.Add('--session-out')
    [void]$dshArgs.Add($SessionOutPath)
    [void]$dshArgs.Add($Task)
    if ([string]$Target.kind -ceq 'node-javascript') {
        $node = Get-Command node -ErrorAction SilentlyContinue
        if ($null -eq $node -or [string]::IsNullOrWhiteSpace([string]$node.Source)) {
            throw 'Node is required to launch DSH Headless.'
        }
        $info.FileName = [string]$node.Source
        [void]$info.ArgumentList.Add([string]$Target.path)
        foreach ($argument in @($dshArgs)) { [void]$info.ArgumentList.Add([string]$argument) }
    } elseif ([string]$Target.kind -ceq 'powershell-headless') {
        $info.FileName = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $psArgs = [Collections.Generic.List[string]]::new()
        foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', [string]$Target.path,
            '-Profile', 'headless',
            '-SessionOut', $SessionOutPath,
            '-Task', $Task
        )) { [void]$psArgs.Add([string]$argument) }
        if (-not [string]::IsNullOrWhiteSpace($ResumeSessionId)) {
            [void]$psArgs.Add('-Resume')
            [void]$psArgs.Add($ResumeSessionId)
        }
        foreach ($argument in @($psArgs)) { [void]$info.ArgumentList.Add([string]$argument) }
    } else {
        $extension = [IO.Path]::GetExtension([string]$Target.path)
        $info.FileName = [string]$Target.path
        if ($extension -ieq '.cmd' -or $extension -ieq '.bat') {
            # cmd.exe shims receive %* from the raw Arguments string. ArgumentList quoting
            # is not forwarded into batch %*, so keep this as a single Windows command tail.
            $quote = {
                param([string]$Value)
                if ($Value -notmatch '[\s&<>|^()"]') { return $Value }
                return '"' + ($Value.Replace('"', '""')) + '"'
            }
            $parts = [Collections.Generic.List[string]]::new()
            foreach ($argument in @($dshArgs)) { [void]$parts.Add((& $quote ([string]$argument))) }
            $info.Arguments = [string]::Join(' ', @($parts))
        } else {
            foreach ($argument in @($dshArgs)) { [void]$info.ArgumentList.Add([string]$argument) }
        }
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [ordered]@{
            exit_code = [int]$process.ExitCode
            stdout = [string]$stdoutTask.GetAwaiter().GetResult()
            stderr = [string]$stderrTask.GetAwaiter().GetResult()
            kind = [string]$Target.kind
            executable = [string]$Target.path
            child_harness_launched = $false
        }
    } finally { $process.Dispose() }
}

function ConvertFrom-DeepSeaSessionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedProvider,
        [Parameter(Mandatory = $true)][string]$ExpectedModel,
        [string]$ExpectedNativeSessionId
    )
    $read = Read-DeepSeaJson -Path $Path
    $value = $read.value
    if ($value -isnot [Collections.IDictionary]) { throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_HEADLESS_RESULT_INVALID') }
    $required = @('protocol_version', 'native_session_id', 'provider', 'model', 'loop_owner')
    if ($value.Count -ne $required.Count) { throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_HEADLESS_RESULT_INVALID') }
    foreach ($key in $required) {
        if (-not $value.Contains($key)) { throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_HEADLESS_RESULT_INVALID') }
    }
    if ([string]$value.protocol_version -cne 'telephone-line-dsh-session-v1') {
        throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_HEADLESS_RESULT_INVALID')
    }
    if ([string]$value.loop_owner -cne 'dsh') { throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_HEADLESS_RESULT_INVALID') }
    if ([string]$value.provider -cne $ExpectedProvider -or [string]$value.model -cne $ExpectedModel) {
        throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_HEADLESS_RESULT_INVALID')
    }
    $native = [string]$value.native_session_id
    Assert-DeepSeaNativeSessionId -Value $native -Label 'Headless native session id'
    if (-not [string]::IsNullOrWhiteSpace($ExpectedNativeSessionId) -and $native -cne $ExpectedNativeSessionId) {
        throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_NATIVE_SESSION_MISMATCH')
    }
    return $value
}

function ConvertFrom-DeepSeaResultText {
    [CmdletBinding()]
    param([AllowNull()][string]$Stdout)
    $text = [string]$Stdout
    if (-not [string]::IsNullOrWhiteSpace($text)) { $text = $text.Trim().TrimStart([char]0xFEFF) }
    if ([string]::IsNullOrWhiteSpace($text)) { throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_HEADLESS_RESULT_INVALID') }
    if ($text.Contains('```')) { throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_HEADLESS_RESULT_INVALID') }
    if ($text.Length -gt 1048576) { throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_HEADLESS_RESULT_INVALID') }
    return $text
}

function Read-DeepSeaPromptText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $identity = Get-DeepSeaFileIdentity -Path $Path
    $bytes = [IO.File]::ReadAllBytes([string]$identity.path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'Prompt must be UTF-8 without BOM.'
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Prompt is empty.' }
    if ($text.Length -gt 12000) { throw 'Request prompt exceeds the durable runner limit.' }
    return [ordered]@{ text = $text; identity = [ordered]@{ bytes = [int64]$identity.bytes; sha256 = [string]$identity.sha256 } }
}

function Get-DeepSeaJobPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Id)
    Assert-DeepSeaJobId -Value $Id
    $stateRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $jobsRoot = [IO.Path]::GetFullPath((Join-Path $stateRoot 'jobs'))
    $jobRoot = [IO.Path]::GetFullPath((Join-Path $jobsRoot $Id))
    $prefix = $jobsRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $jobRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $jobRoot.Length -le $prefix.Length) {
        throw 'Adapter request job id escaped the state root.'
    }
    if ([IO.Directory]::Exists($jobRoot)) {
        $item = Get-Item -LiteralPath $jobRoot -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Adapter request job path is not a regular directory.'
        }
    }
    return [ordered]@{
        root = $jobRoot
        request = Join-Path $jobRoot 'request.json'
        result = Join-Path $jobRoot 'result.json'
        receipt = Join-Path $jobRoot 'receipt.json'
        dsh_home = Join-Path $jobRoot 'dsh-home'
        session_out = Join-Path $jobRoot 'dsh-session.json'
    }
}

function Get-DeepSeaBindingPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$SessionId)
    $sessionRoot = Join-Path $Root ('sessions\' + $SessionId)
    return [ordered]@{ root = $sessionRoot; binding = Join-Path $sessionRoot 'binding.json' }
}

function Write-DeepSeaAdapterResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RouteId,
        [Parameter(Mandatory = $true)][string]$Operation,
        [AllowEmptyString()][string]$NativeSessionId,
        [AllowEmptyString()][string]$JobId,
        [Parameter(Mandatory = $true)][bool]$Complete,
        [Parameter(Mandatory = $true)][bool]$ExactNativeSession,
        [object]$ReceiptIdentity,
        [object]$ResultIdentity,
        [Collections.IDictionary]$Extra
    )
    $payload = [ordered]@{
        protocol_version = 'telephone-line-adapter-result-v1'
        route_id = $RouteId
        operation = $Operation
        native_session_id = $NativeSessionId
        job_id = $JobId
        automatic_rerun = $false
        replacement_started = $false
        headless_only = $true
        dsh_owned = $true
        child_harness_launched = $false
        exact_native_session = [bool]$ExactNativeSession
        transport_complete = [bool]$Complete
        receipt = $ReceiptIdentity
    }
    if ($null -ne $ResultIdentity) { $payload.result = $ResultIdentity }
    if ($null -ne $Extra) {
        foreach ($key in @($Extra.Keys)) { $payload[$key] = $Extra[$key] }
    }
    $payload | ConvertTo-Json -Depth 16
}

function Invoke-DeepSeaPublicAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Route,
        [Parameter(Mandatory = $true)][string]$Operation,
        [string]$NativeSessionId,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$WorkspacePath,
        [string]$PromptFile,
        [string]$RequestFile,
        [string]$JobId,
        [string]$DshCommand,
        [string]$MockHeadlessPath,
        [string]$Mode,
        [string[]]$AllowedWritePath,
        [string]$Model,
        [string]$ReasoningEffort,
        [string]$CommunityCredentialKey,
        [bool]$ModelSpecified = $false,
        [bool]$ReasoningEffortSpecified = $false
    )

    $routeId = [string]$Route.route_id
    $exactNative = $false
    if ($Route.Contains('capabilities') -and $null -ne $Route.capabilities -and $Route.capabilities.Contains('exact_native_session')) {
        $exactNative = [bool]$Route.capabilities.exact_native_session
    }
    $state = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    [IO.Directory]::CreateDirectory($state) | Out-Null
    $config = $null
    try {
        $config = Get-DeepSeaRouteConfig -Route $Route -Model $Model -ReasoningEffort $ReasoningEffort -ModelSpecified $ModelSpecified -ReasoningEffortSpecified $ReasoningEffortSpecified
    } catch {
        $failure = ConvertTo-DeepSeaPublicFailure -Message $_.Exception.Message -ErrorCode 'ADAPTER_REQUEST_INVALID'
        Write-DeepSeaAdapterResult -RouteId $routeId -Operation $Operation -NativeSessionId '' -JobId $(if ([string]::IsNullOrWhiteSpace($JobId)) { '' } else { $JobId }) -Complete $false -ExactNativeSession $exactNative -ReceiptIdentity $null -ResultIdentity $null -Extra ([ordered]@{
            error_code = [string]$failure.error_code
            error_message = [string]$failure.error_message
            dsh_owned = $true
            child_harness_launched = $false
            exact_native_session = $exactNative
        })
        exit 4
    }
    $extra = [ordered]@{
        provider = [string]$config.provider
        model = [string]$config.model
        reasoning_effort = [string]$config.reasoning_effort
        exact_native_session = $exactNative
        dsh_owned = $true
        child_harness_launched = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($CommunityCredentialKey)) {
        if ([string]$config.provider -cne 'openai-codex' -or $CommunityCredentialKey -cnotmatch '^[A-Za-z0-9._:-]{1,64}$') {
            throw 'Adapter request is invalid.'
        }
        $extra.community_credential_key = $CommunityCredentialKey
    }
    if ($Route.Contains('ExtraFields') -and $null -ne $Route.ExtraFields) {
        $more = & $Route.ExtraFields -Mode $Mode -AllowedWritePath $AllowedWritePath
        if ($null -ne $more) {
            foreach ($key in @($more.Keys)) { $extra[$key] = $more[$key] }
        }
    }

    if (-not (Test-DeepSeaCapability -Route $Route -Operation $Operation)) {
        $code = if ($Route.Contains('unavailable_code') -and -not [string]::IsNullOrWhiteSpace([string]$Route.unavailable_code)) {
            [string]$Route.unavailable_code
        } else {
            'ADAPTER_OPERATION_UNSUPPORTED'
        }
        $failure = ConvertTo-DeepSeaPublicFailure -ErrorCode $code
        if ($Operation -eq 'start') {
            $job = $JobId
            if ([string]::IsNullOrWhiteSpace($job)) { $job = [Guid]::NewGuid().ToString('D') }
            $paths = Get-DeepSeaJobPaths -Root $state -Id $job
            if ([IO.Directory]::Exists($paths.root) -and [IO.File]::Exists($paths.receipt)) {
                $receipt = (Read-DeepSeaJson -Path $paths.receipt).value
                $resultIdentity = $null
                if ([IO.File]::Exists($paths.result)) { $resultIdentity = Get-DeepSeaFileIdentity -Path $paths.result }
                Write-DeepSeaAdapterResult -RouteId $routeId -Operation $Operation -NativeSessionId ([string]$receipt.native_session_id) -JobId $job -Complete ([bool]$receipt.transport_complete) -ExactNativeSession $exactNative -ReceiptIdentity (Get-DeepSeaFileIdentity -Path $paths.receipt) -ResultIdentity $resultIdentity -Extra $extra
                exit 0
            }
            if ([IO.Directory]::Exists($paths.root) -and -not [IO.File]::Exists($paths.receipt)) {
                throw 'Adapter duplicate start found incomplete durable state; refusing automatic rerun.'
            }
            [IO.Directory]::CreateDirectory($paths.root) | Out-Null
            $requestIdentity = Write-DeepSeaJsonCreateNew -Path $paths.request -Value ([ordered]@{
                protocol_version = [string]$Route.request_protocol
                operation = $Operation
                job_id = $job
                headless_only = $true
                dsh_owned = $true
                provider = [string]$config.provider
                model = [string]$config.model
                reasoning_effort = [string]$config.reasoning_effort
            })
            $receiptIdentity = Write-DeepSeaJsonCreateNew -Path $paths.receipt -Value ([ordered]@{
                protocol_version = [string]$Route.receipt_protocol
                job_id = $job
                native_session_id = ''
                request = $requestIdentity
                result = $null
                transport_complete = $false
                automatic_rerun = $false
                replacement_started = $false
                headless_only = $true
                dsh_owned = $true
                child_harness_launched = $false
                exact_native_session = $exactNative
                error_code = [string]$failure.error_code
                error_message = [string]$failure.error_message
                completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            })
            $extra.error_code = [string]$failure.error_code
            $extra.error_message = [string]$failure.error_message
            Write-DeepSeaAdapterResult -RouteId $routeId -Operation $Operation -NativeSessionId '' -JobId $job -Complete $false -ExactNativeSession $exactNative -ReceiptIdentity $receiptIdentity -ResultIdentity $null -Extra $extra
            exit 4
        }
        Write-DeepSeaAdapterResult -RouteId $routeId -Operation $Operation -NativeSessionId $(if ($Operation -eq 'start') { '' } else { $NativeSessionId }) -JobId $(if ([string]::IsNullOrWhiteSpace($JobId)) { '' } else { $JobId }) -Complete $false -ExactNativeSession $exactNative -ReceiptIdentity $null -ResultIdentity $null -Extra ([ordered]@{
            provider = [string]$config.provider
            model = [string]$config.model
            reasoning_effort = [string]$config.reasoning_effort
            error_code = [string]$failure.error_code
            error_message = [string]$failure.error_message
            child_harness_launched = $false
        })
        exit 4
    }

    $requestFileValue = $null
    if (-not [string]::IsNullOrWhiteSpace($RequestFile)) {
        if (-not [bool]$Route.supports_request_file) { throw 'Request file is not supported for this route.' }
        $requestIdentity = Get-DeepSeaFileIdentity -Path $RequestFile
        $parsed = ([Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes([string]$requestIdentity.path))) | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
        if ($parsed -isnot [Collections.IDictionary]) { throw 'DeepSea request file is malformed.' }
        if ($Route.Contains('AssertRequestFile') -and $null -ne $Route.AssertRequestFile) {
            $null = & $Route.AssertRequestFile -Request $parsed
        }
        $translated = ConvertTo-DeepSeaPublicOperation -Value ([string]$parsed.operation)
        if ($translated -cne $Operation) { throw 'Request file operation does not match -Operation.' }
        if (-not (Test-DeepSeaCapability -Route $Route -Operation $translated)) {
            throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_OPERATION_UNSUPPORTED')
        }
        $requestFileValue = $parsed
    }

    if ($Operation -eq 'start' -and -not [string]::IsNullOrWhiteSpace($NativeSessionId)) { throw 'Adapter start must not receive a native session id.' }
    if ($Operation -ne 'start' -and [string]::IsNullOrWhiteSpace($NativeSessionId)) { throw 'Adapter native session id is required.' }
    if ($Operation -ne 'start') { Assert-DeepSeaNativeSessionId -Value $NativeSessionId }

    $job = $JobId
    if ([string]::IsNullOrWhiteSpace($job) -and $null -ne $requestFileValue -and $requestFileValue.Contains('job_id') -and -not [string]::IsNullOrWhiteSpace([string]$requestFileValue.job_id)) {
        $job = [string]$requestFileValue.job_id
    }
    if ([string]::IsNullOrWhiteSpace($job)) { $job = [Guid]::NewGuid().ToString('D') }
    if ($null -ne $requestFileValue -and $requestFileValue.Contains('job_id') -and -not [string]::IsNullOrWhiteSpace([string]$requestFileValue.job_id) -and [string]$requestFileValue.job_id -cne $job) {
        throw 'Request file job_id does not match -JobId.'
    }

    $paths = Get-DeepSeaJobPaths -Root $state -Id $job
    if ($null -ne $requestFileValue) {
        if ($requestFileValue.Contains('mode') -and -not [string]::IsNullOrWhiteSpace([string]$requestFileValue.mode)) {
            $Mode = [string]$requestFileValue.mode
        }
        if ($requestFileValue.Contains('allowed_write_paths')) {
            $AllowedWritePath = @($requestFileValue.allowed_write_paths | ForEach-Object { [string]$_ })
        }
    }

    if ($Operation -eq 'recover') {
        $bindingPaths = Get-DeepSeaBindingPaths -Root $state -SessionId $NativeSessionId
        if (-not [IO.File]::Exists($bindingPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
        $binding = (Read-DeepSeaJson -Path $bindingPaths.binding).value
        if ([string]$binding.native_session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
        $latestPaths = Get-DeepSeaJobPaths -Root $state -Id ([string]$binding.latest_job_id)
        if (-not [IO.File]::Exists($latestPaths.receipt)) { throw 'Adapter durable state was not found.' }
        $receipt = (Read-DeepSeaJson -Path $latestPaths.receipt).value
        $resultIdentity = $null
        if ([IO.File]::Exists($latestPaths.result)) { $resultIdentity = Get-DeepSeaFileIdentity -Path $latestPaths.result }
        Write-DeepSeaAdapterResult -RouteId $routeId -Operation 'recover' -NativeSessionId $NativeSessionId -JobId ([string]$binding.latest_job_id) -Complete ([bool]$receipt.transport_complete) -ExactNativeSession $exactNative -ReceiptIdentity (Get-DeepSeaFileIdentity -Path $latestPaths.receipt) -ResultIdentity $resultIdentity -Extra $extra
        exit 0
    }

    if ([IO.Directory]::Exists($paths.root)) {
        if (-not [IO.File]::Exists($paths.receipt)) { throw 'Adapter duplicate start found incomplete durable state; refusing automatic rerun.' }
        $receipt = (Read-DeepSeaJson -Path $paths.receipt).value
        $resultIdentity = $null
        if ([IO.File]::Exists($paths.result)) { $resultIdentity = Get-DeepSeaFileIdentity -Path $paths.result }
        Write-DeepSeaAdapterResult -RouteId $routeId -Operation $Operation -NativeSessionId ([string]$receipt.native_session_id) -JobId $job -Complete ([bool]$receipt.transport_complete) -ExactNativeSession $exactNative -ReceiptIdentity (Get-DeepSeaFileIdentity -Path $paths.receipt) -ResultIdentity $resultIdentity -Extra $extra
        exit 0
    }

    if ($Operation -eq 'follow_up') {
        $bindingPaths = Get-DeepSeaBindingPaths -Root $state -SessionId $NativeSessionId
        if (-not [IO.File]::Exists($bindingPaths.binding)) { throw 'Adapter native session id is missing or unknown.' }
        $existingBinding = (Read-DeepSeaJson -Path $bindingPaths.binding).value
        if ([string]$existingBinding.native_session_id -cne $NativeSessionId) { throw 'Adapter native session id does not match the frozen session.' }
        if ($null -ne $requestFileValue -and $requestFileValue.Contains('binding_id') -and [string]$requestFileValue.binding_id -cne $NativeSessionId) {
            throw 'Adapter native session id does not match the frozen session.'
        }
    }

    $needsPrompt = ($Operation -eq 'start' -or $Operation -eq 'follow_up')
    $promptText = $null
    $promptIdentity = $null
    if ($needsPrompt) {
        if ($null -ne $requestFileValue -and $requestFileValue.Contains('prompt') -and $requestFileValue.prompt -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$requestFileValue.prompt)) {
            $promptText = [string]$requestFileValue.prompt
            if ($promptText.Length -gt 12000) { throw 'Request prompt exceeds the durable runner limit.' }
            $promptIdentity = Get-DeepSeaTextIdentity -Text $promptText
        } elseif (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
            $loaded = Read-DeepSeaPromptText -Path $PromptFile
            $promptText = [string]$loaded.text
            $promptIdentity = $loaded.identity
        } else {
            throw 'DeepSea start and follow-up require workspace and prompt identities.'
        }
    }

    $workspace = $WorkspacePath
    if ($null -ne $requestFileValue -and $requestFileValue.Contains('cwd') -and -not [string]::IsNullOrWhiteSpace([string]$requestFileValue.cwd)) {
        $workspace = [string]$requestFileValue.cwd
    }
    if ($needsPrompt -and [string]::IsNullOrWhiteSpace($workspace)) { throw 'DeepSea start and follow-up require workspace and prompt identities.' }
    if (-not [string]::IsNullOrWhiteSpace($workspace)) { $workspace = [IO.Path]::GetFullPath($workspace).TrimEnd('\') }

    if ($Route.Contains('AssertAdapterInput') -and $null -ne $Route.AssertAdapterInput) {
        & $Route.AssertAdapterInput -Operation $Operation -Workspace $workspace -Mode $Mode -AllowedWritePath $AllowedWritePath -RequestFile $requestFileValue
    }

    [IO.Directory]::CreateDirectory($paths.root) | Out-Null
    $requestRecord = [ordered]@{
        protocol_version = [string]$Route.request_protocol
        operation = $Operation
        job_id = $job
        workspace = $workspace
        headless_only = $true
        dsh_owned = $true
        provider = [string]$config.provider
        model = [string]$config.model
        reasoning_effort = [string]$config.reasoning_effort
    }
    if ($needsPrompt) { $requestRecord.prompt = $promptIdentity }
    if ($Operation -ne 'start') { $requestRecord.native_session_id = $NativeSessionId }
    foreach ($key in @($extra.Keys)) {
        if ($key -cin @('provider', 'model', 'reasoning_effort', 'dsh_owned', 'child_harness_launched', 'exact_native_session')) { continue }
        $requestRecord[$key] = $extra[$key]
    }
    $requestIdentity = Write-DeepSeaJsonCreateNew -Path $paths.request -Value $requestRecord

    $includeSubscription = $false
    if ($Route.Contains('include_subscription_oauth')) { $includeSubscription = [bool]$Route.include_subscription_oauth }
    elseif ($Route.Contains('include_pi_oauth')) { $includeSubscription = [bool]$Route.include_pi_oauth }
    $profile = $null
    $headlessResult = $null
    $failure = $null
    try {
        $profile = New-DeepSeaContainedProfile -HomeRoot $paths.dsh_home -Provider ([string]$config.provider) -Model ([string]$config.model) -ReasoningEffort ([string]$config.reasoning_effort) -IncludeSubscriptionOauth $includeSubscription
        $target = Resolve-DeepSeaHeadlessTarget -DshCommand $DshCommand -MockHeadlessPath $MockHeadlessPath
        $resume = if ($Operation -eq 'follow_up') { $NativeSessionId } else { '' }
        $run = Invoke-DeepSeaOwnedHarness -Target $target -HomeRoot ([string]$profile.home) -Workspace $workspace -Task $promptText -ResumeSessionId $resume -SessionOutPath $paths.session_out -CommunityCredentialKey $CommunityCredentialKey
        if ([int]$run.exit_code -ne 0) { throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_HEADLESS_INVOCATION_FAILED') }
        if (-not [IO.File]::Exists($paths.session_out)) { throw (Get-DeepSeaPublicErrorMessage -ErrorCode 'ADAPTER_HEADLESS_RESULT_INVALID') }
        $expectedNative = if ($Operation -eq 'follow_up') { $NativeSessionId } else { '' }
        $sessionRecord = ConvertFrom-DeepSeaSessionRecord -Path $paths.session_out -ExpectedProvider ([string]$config.provider) -ExpectedModel ([string]$config.model) -ExpectedNativeSessionId $expectedNative
        $resultText = ConvertFrom-DeepSeaResultText -Stdout ([string]$run.stdout)
        $headlessResult = [ordered]@{
            native_session_id = [string]$sessionRecord.native_session_id
            result_text = $resultText
            provider = [string]$sessionRecord.provider
            model = [string]$sessionRecord.model
        }
    } catch {
        $failure = ConvertTo-DeepSeaPublicFailure -Message $_.Exception.Message
    }

    if ($null -ne $failure) {
        $receiptIdentity = Write-DeepSeaJsonCreateNew -Path $paths.receipt -Value ([ordered]@{
            protocol_version = [string]$Route.receipt_protocol
            job_id = $job
            native_session_id = if ($Operation -eq 'start') { '' } else { $NativeSessionId }
            request = $requestIdentity
            result = $null
            transport_complete = $false
            automatic_rerun = $false
            replacement_started = $false
            headless_only = $true
            dsh_owned = $true
            child_harness_launched = $false
            exact_native_session = $exactNative
            error_code = [string]$failure.error_code
            error_message = [string]$failure.error_message
            completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        })
        Write-DeepSeaAdapterResult -RouteId $routeId -Operation $Operation -NativeSessionId $(if ($Operation -eq 'start') { '' } else { $NativeSessionId }) -JobId $job -Complete $false -ExactNativeSession $exactNative -ReceiptIdentity $receiptIdentity -ResultIdentity $null -Extra $extra
        exit 4
    }

    $native = [string]$headlessResult.native_session_id
    $resultIdentity = Write-DeepSeaJsonCreateNew -Path $paths.result -Value ([ordered]@{
        protocol_version = [string]$Route.result_protocol
        route_id = $routeId
        job_id = $job
        native_session_id = $native
        result_text = [string]$headlessResult.result_text
        provider = [string]$headlessResult.provider
        model = [string]$headlessResult.model
        reasoning_effort = [string]$config.reasoning_effort
        loop_owner = 'dsh'
        transport_complete = $true
    })
    $receiptIdentity = Write-DeepSeaJsonCreateNew -Path $paths.receipt -Value ([ordered]@{
        protocol_version = [string]$Route.receipt_protocol
        job_id = $job
        native_session_id = $native
        request = $requestIdentity
        result = $resultIdentity
        transport_complete = $true
        automatic_rerun = $false
        replacement_started = $false
        headless_only = $true
        dsh_owned = $true
        child_harness_launched = $false
        exact_native_session = $exactNative
        error_code = $null
        error_message = $null
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    })

    $bindingPaths = Get-DeepSeaBindingPaths -Root $state -SessionId $native
    $bindingValue = [ordered]@{
        protocol_version = [string]$Route.binding_protocol
        native_session_id = $native
        latest_job_id = $job
        provider = [string]$config.provider
        model = [string]$config.model
        reasoning_effort = [string]$config.reasoning_effort
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if (-not [IO.File]::Exists($bindingPaths.binding)) { $null = Write-DeepSeaJsonCreateNew -Path $bindingPaths.binding -Value $bindingValue }
    else { $null = Write-DeepSeaJsonReplace -Path $bindingPaths.binding -Value $bindingValue }

    Write-DeepSeaAdapterResult -RouteId $routeId -Operation $Operation -NativeSessionId $native -JobId $job -Complete $true -ExactNativeSession $exactNative -ReceiptIdentity $receiptIdentity -ResultIdentity $resultIdentity -Extra $extra
    exit 0
}
