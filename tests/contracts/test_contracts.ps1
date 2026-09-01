# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
. (Join-Path $repoRoot 'src\contracts\TelephoneLine.AdapterContract.ps1')
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'
$validRoot = Join-Path $fixtureRoot 'valid'
$negativeRoot = Join-Path $fixtureRoot 'negative'
$assertions = 0

function Assert-ContractTest {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Invoke-ContractAdapter {
    param([string]$Executable, [string[]]$Arguments)
    $powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $powerShellPath
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Executable) + @($Arguments)) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Adapter invocation failed: $stderr $stdout" }
        return $stdout
    } finally {
        $process.Dispose()
    }
}

function Test-SchemaRejects {
    param([string]$SchemaName, [string]$Path, [string]$Label)
    $failed = $false
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($Path))
        Assert-TelephoneJsonSchema -JsonText $text -SchemaName $SchemaName -Label $Label
    } catch {
        $failed = $true
    }
    Assert-ContractTest $failed "$Label was accepted."
}

try {
    [IO.Directory]::CreateDirectory($TestRoot) | Out-Null

    foreach ($pair in @(
        @{ name = 'dispatch'; file = 'dispatch.json' },
        @{ name = 'receipt'; file = 'receipt.json' },
        @{ name = 'lead-binding'; file = 'lead-binding.json' },
        @{ name = 'adapter'; file = 'adapter.json' },
        @{ name = 'codex-app-server-lead-profile'; file = 'codex-app-server-lead-profile.json' },
        @{ name = 'codex-app-server-lead-run'; file = 'codex-app-server-lead-run.json' },
        @{ name = 'codex-app-server-lead-status'; file = 'codex-app-server-lead-status.json' },
        @{ name = 'codex-app-server-lead-intent'; file = 'codex-app-server-lead-intent.json' },
        @{ name = 'codex-app-server-lead-bound-turn'; file = 'codex-app-server-lead-bound-turn.json' },
        @{ name = 'codex-app-server-lead-ack'; file = 'codex-app-server-lead-ack.json' },
        @{ name = 'codex-app-server-lead-owner'; file = 'codex-app-server-lead-owner.json' },
        @{ name = 'codex-app-server-lead-child'; file = 'codex-app-server-lead-child.json' },
        @{ name = 'codex-app-server-lead-result'; file = 'codex-app-server-lead-result.json' },
        @{ name = 'codex-app-server-lead-failure'; file = 'codex-app-server-lead-failure.json' },
        @{ name = 'codex-app-server-lead-recovery'; file = 'codex-app-server-lead-recovery.json' },
        @{ name = 'codex-app-server-lead-status-sources'; file = 'codex-app-server-lead-status-sources.json' },
        @{ name = 'lifecycle-status'; file = 'lifecycle-status.json' },
        @{ name = 'dashboard-config'; file = 'dashboard-config.json' },
        @{ name = 'dashboard-project-descriptor'; file = 'dashboard-project-descriptor.json' },
        @{ name = 'dashboard-lifecycle-event'; file = 'dashboard-lifecycle-event.json' },
        @{ name = 'dashboard-closure'; file = 'dashboard-closure.json' },
        @{ name = 'dashboard-projection'; file = 'dashboard-projection.json' },
        @{ name = 'telephone-line-batch'; file = 'telephone-line-batch.json' },
        @{ name = 'wired-supervisor-request'; file = 'wired-supervisor-request.json' },
        @{ name = 'wired-supervisor-owner'; file = 'wired-supervisor-owner.json' },
        @{ name = 'wired-supervisor-status'; file = 'wired-supervisor-status.json' },
        @{ name = 'wired-supervisor-control'; file = 'wired-supervisor-control.json' }
    )) {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes((Join-Path $validRoot $pair.file)))
        Assert-TelephoneJsonSchema -JsonText $text -SchemaName $pair.name -Label $pair.file
        $script:assertions += 1
    }
    $oneShotText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes((Join-Path $validRoot 'adapter.one-shot.json')))
    Assert-TelephoneJsonSchema -JsonText $oneShotText -SchemaName 'adapter' -Label 'adapter.one-shot.json'
    $script:assertions += 1

    Test-SchemaRejects -SchemaName 'dispatch' -Path (Join-Path $negativeRoot 'dispatch.unknown-field.json') -Label 'dispatch.unknown-field'
    Test-SchemaRejects -SchemaName 'dispatch' -Path (Join-Path $negativeRoot 'dispatch.bad-id.json') -Label 'dispatch.bad-id'
    Test-SchemaRejects -SchemaName 'dispatch' -Path (Join-Path $negativeRoot 'dispatch.bad-role.json') -Label 'dispatch.bad-role'
    Test-SchemaRejects -SchemaName 'receipt' -Path (Join-Path $negativeRoot 'receipt.unknown-field.json') -Label 'receipt.unknown-field'
    Test-SchemaRejects -SchemaName 'receipt' -Path (Join-Path $negativeRoot 'receipt.timeout-true.json') -Label 'receipt.timeout-true'
    Test-SchemaRejects -SchemaName 'lead-binding' -Path (Join-Path $negativeRoot 'lead-binding.unknown-field.json') -Label 'lead-binding.unknown-field'
    Test-SchemaRejects -SchemaName 'lead-binding' -Path (Join-Path $negativeRoot 'lead-binding.bad-session.json') -Label 'lead-binding.bad-session'
    Test-SchemaRejects -SchemaName 'adapter' -Path (Join-Path $negativeRoot 'adapter.unknown-field.json') -Label 'adapter.unknown-field'
    Test-SchemaRejects -SchemaName 'adapter' -Path (Join-Path $negativeRoot 'adapter.bad-route-id.json') -Label 'adapter.bad-route-id'
    Test-SchemaRejects -SchemaName 'codex-app-server-lead-profile' -Path (Join-Path $negativeRoot 'codex-app-server-lead-profile.unknown-field.json') -Label 'codex-app-server-lead-profile.unknown-field'
    Test-SchemaRejects -SchemaName 'codex-app-server-lead-run' -Path (Join-Path $negativeRoot 'codex-app-server-lead-run.unknown-field.json') -Label 'codex-app-server-lead-run.unknown-field'
    Test-SchemaRejects -SchemaName 'codex-app-server-lead-status' -Path (Join-Path $negativeRoot 'codex-app-server-lead-status.unknown-field.json') -Label 'codex-app-server-lead-status.unknown-field'
    Test-SchemaRejects -SchemaName 'codex-app-server-lead-intent' -Path (Join-Path $negativeRoot 'codex-app-server-lead-intent.unknown-field.json') -Label 'codex-app-server-lead-intent.unknown-field'
    Test-SchemaRejects -SchemaName 'codex-app-server-lead-bound-turn' -Path (Join-Path $negativeRoot 'codex-app-server-lead-bound-turn.unknown-field.json') -Label 'codex-app-server-lead-bound-turn.unknown-field'
    Test-SchemaRejects -SchemaName 'codex-app-server-lead-ack' -Path (Join-Path $negativeRoot 'codex-app-server-lead-ack.unknown-field.json') -Label 'codex-app-server-lead-ack.unknown-field'
    Test-SchemaRejects -SchemaName 'codex-app-server-lead-owner' -Path (Join-Path $negativeRoot 'codex-app-server-lead-owner.unknown-field.json') -Label 'codex-app-server-lead-owner.unknown-field'
    Test-SchemaRejects -SchemaName 'codex-app-server-lead-child' -Path (Join-Path $negativeRoot 'codex-app-server-lead-child.unknown-field.json') -Label 'codex-app-server-lead-child.unknown-field'
    Test-SchemaRejects -SchemaName 'codex-app-server-lead-result' -Path (Join-Path $negativeRoot 'codex-app-server-lead-result.unknown-field.json') -Label 'codex-app-server-lead-result.unknown-field'
    Test-SchemaRejects -SchemaName 'codex-app-server-lead-failure' -Path (Join-Path $negativeRoot 'codex-app-server-lead-failure.unknown-field.json') -Label 'codex-app-server-lead-failure.unknown-field'
    Test-SchemaRejects -SchemaName 'codex-app-server-lead-recovery' -Path (Join-Path $negativeRoot 'codex-app-server-lead-recovery.unknown-field.json') -Label 'codex-app-server-lead-recovery.unknown-field'
    Test-SchemaRejects -SchemaName 'codex-app-server-lead-status-sources' -Path (Join-Path $negativeRoot 'codex-app-server-lead-status-sources.unknown-field.json') -Label 'codex-app-server-lead-status-sources.unknown-field'
    Test-SchemaRejects -SchemaName 'lifecycle-status' -Path (Join-Path $negativeRoot 'lifecycle-status.unknown-field.json') -Label 'lifecycle-status.unknown-field'
    Test-SchemaRejects -SchemaName 'dashboard-config' -Path (Join-Path $negativeRoot 'dashboard-config.unknown-field.json') -Label 'dashboard-config.unknown-field'
    Test-SchemaRejects -SchemaName 'dashboard-project-descriptor' -Path (Join-Path $negativeRoot 'dashboard-project-descriptor.unknown-field.json') -Label 'dashboard-project-descriptor.unknown-field'
    Test-SchemaRejects -SchemaName 'dashboard-project-descriptor' -Path (Join-Path $negativeRoot 'dashboard-project-descriptor.direct-job-roots-too-many.json') -Label 'dashboard-project-descriptor.direct-job-roots-too-many'
    Test-SchemaRejects -SchemaName 'dashboard-lifecycle-event' -Path (Join-Path $negativeRoot 'dashboard-lifecycle-event.unknown-field.json') -Label 'dashboard-lifecycle-event.unknown-field'
    Test-SchemaRejects -SchemaName 'dashboard-closure' -Path (Join-Path $negativeRoot 'dashboard-closure.unknown-field.json') -Label 'dashboard-closure.unknown-field'
    Test-SchemaRejects -SchemaName 'dashboard-projection' -Path (Join-Path $negativeRoot 'dashboard-projection.unknown-field.json') -Label 'dashboard-projection.unknown-field'
    Test-SchemaRejects -SchemaName 'telephone-line-batch' -Path (Join-Path $negativeRoot 'telephone-line-batch.unknown-field.json') -Label 'telephone-line-batch.unknown-field'
    Test-SchemaRejects -SchemaName 'wired-supervisor-request' -Path (Join-Path $negativeRoot 'wired-supervisor-request.unknown-field.json') -Label 'wired-supervisor-request.unknown-field'
    Test-SchemaRejects -SchemaName 'wired-supervisor-owner' -Path (Join-Path $negativeRoot 'wired-supervisor-owner.unknown-field.json') -Label 'wired-supervisor-owner.unknown-field'
    Test-SchemaRejects -SchemaName 'wired-supervisor-status' -Path (Join-Path $negativeRoot 'wired-supervisor-status.unknown-field.json') -Label 'wired-supervisor-status.unknown-field'
    Test-SchemaRejects -SchemaName 'wired-supervisor-control' -Path (Join-Path $negativeRoot 'wired-supervisor-control.unknown-field.json') -Label 'wired-supervisor-control.unknown-field'
    Test-SchemaRejects -SchemaName 'adapter' -Path (Join-Path $negativeRoot 'adapter.path-escape.json') -Label 'adapter.path-escape'

    $catalogPath = Join-Path $repoRoot 'src\catalog\routes.json'
    $catalogText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($catalogPath))
    $minNode = [System.Text.Json.Nodes.JsonNode]::Parse($catalogText)
    $minRoutes = $minNode['routes'].AsArray()
    Assert-ContractTest ($minRoutes.Count -eq 8) 'Catalog fixture did not have eight routes before minItems probe.'
    $minRoutes.RemoveAt($minRoutes.Count - 1)
    $minPath = Join-Path $TestRoot 'catalog.minItems.json'
    [IO.File]::WriteAllText($minPath, $minNode.ToJsonString(), [Text.UTF8Encoding]::new($false))
    Test-SchemaRejects -SchemaName 'catalog' -Path $minPath -Label 'catalog.minItems'

    $maxNode = [System.Text.Json.Nodes.JsonNode]::Parse($catalogText)
    $maxRoutes = $maxNode['routes'].AsArray()
    Assert-ContractTest ($maxRoutes.Count -eq 8) 'Catalog fixture did not have eight routes before maxItems probe.'
    [void]$maxRoutes.Add($maxRoutes[0].DeepClone())
    $maxPath = Join-Path $TestRoot 'catalog.maxItems.json'
    [IO.File]::WriteAllText($maxPath, $maxNode.ToJsonString(), [Text.UTF8Encoding]::new($false))
    Test-SchemaRejects -SchemaName 'catalog' -Path $maxPath -Label 'catalog.maxItems'

    $malformedFailed = $false
    try {
        $malformed = [IO.File]::ReadAllText((Join-Path $negativeRoot 'malformed.json'), [Text.UTF8Encoding]::new($false, $true))
        Assert-TelephoneJsonSchema -JsonText $malformed -SchemaName 'dispatch' -Label 'malformed'
    } catch { $malformedFailed = $true }
    Assert-ContractTest $malformedFailed 'Malformed JSON was accepted.'

    $unknownRequest = '{"protocol_version":"telephone-line-dispatch-v1","line_job_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1","project":"p","stage":"s","role":"execution","route":"r","summary":"x","lead":{"protocol_version":"telephone-line-lead-binding-v1","session_id":"s1","worktree":"C:\\example\\worktree","launcher":{"path":"C:\\example\\l.ps1","arguments":[]}},"command":{"executable":"C:\\example\\e.exe","working_directory":"C:\\example\\worktree","arguments":[]},"extra":true}'
    $unknownFailed = $false
    try { Assert-TelephoneDispatchRequestText -JsonText $unknownRequest } catch { $unknownFailed = $true }
    Assert-ContractTest $unknownFailed 'Unknown dispatch request field was accepted.'

    $directoryFailed = $false
    try { $null = Get-TelephoneFileIdentity -Path $TestRoot } catch { $directoryFailed = $true }
    Assert-ContractTest $directoryFailed 'A directory was accepted as a regular file.'

    $escapeFailed = $false
    try { $null = Resolve-TelephonePathInsideRoot -Path '..\outside.txt' -Root $TestRoot -Label 'Escape' } catch { $escapeFailed = $true }
    Assert-ContractTest $escapeFailed 'A path escape was accepted.'

    $outside = Join-Path ([IO.Path]::GetTempPath()) ('tl-outside-' + [Guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($outside, 'x', [Text.UTF8Encoding]::new($false))
    try {
        $rootedEscapeFailed = $false
        try { $null = Resolve-TelephonePathInsideRoot -Path $outside -Root $TestRoot -Label 'Outside' } catch { $rootedEscapeFailed = $true }
        Assert-ContractTest $rootedEscapeFailed 'A rooted path outside the adapter root was accepted.'
    } finally {
        if ([IO.File]::Exists($outside)) { [IO.File]::Delete($outside) }
    }

    $worktree = Join-Path $TestRoot 'worktree'
    [IO.Directory]::CreateDirectory($worktree) | Out-Null
    $launcher = Join-Path $fixtureRoot '..\..\core\fixtures\mock-lead-launcher.ps1'
    $launcher = [IO.Path]::GetFullPath($launcher)
    $bindingPath = Join-Path $TestRoot 'lead-binding.json'
    $binding = [ordered]@{
        protocol_version = 'telephone-line-lead-binding-v1'
        session_id = 'exact-session-1'
        worktree = $worktree
        launcher = [ordered]@{ path = $launcher; arguments = @() }
    }
    $null = Write-TelephoneJsonCreateNew -Path $bindingPath -Value $binding
    $resolved = Resolve-TelephoneLeadSessionId -Lead ([ordered]@{
        protocol_version = 'telephone-line-lead-binding-v1'
        session_id = 'exact-session-1'
        worktree = $worktree
        launcher = [ordered]@{ path = $launcher; arguments = @() }
        binding_file = $bindingPath
    })
    Assert-ContractTest ($resolved -ceq 'exact-session-1') 'Frozen Lead binding session was not used.'

    $wrongSessionFailed = $false
    try {
        $null = Resolve-TelephoneLeadSessionId -Lead ([ordered]@{
            session_id = 'other-session'
            worktree = $worktree
            binding_file = $bindingPath
        })
    } catch { $wrongSessionFailed = $true }
    Assert-ContractTest $wrongSessionFailed 'A caller-supplied session silently disagreed with the frozen Lead binding.'

    $adapter = Read-TelephoneAdapterDescriptor -Path (Join-Path $validRoot 'adapter.json') -AdapterRoot $fixtureRoot
    Assert-ContractTest ([string]$adapter.descriptor.route_id -ceq 'mock-native') 'Adapter descriptor route id changed.'
    $sessionStore = Join-Path $TestRoot 'native-session.txt'
    $startInvocation = New-TelephoneAdapterInvocation -Adapter $adapter -Operation start -ExtraArguments @('-SessionStore', $sessionStore)
    Assert-ContractTest ($null -eq $startInvocation.native_session_id) 'Adapter start carried a native session id.'
    $startArgs = [string[]]@($startInvocation.arguments)
    $startOutput = Invoke-ContractAdapter -Executable $startInvocation.executable -Arguments $startArgs
    $startResult = ($startOutput | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String)
    $startResult.route_id = [string]$adapter.descriptor.route_id
    Assert-ContractTest ([string]$startResult.operation -ceq 'start' -and $startResult.automatic_rerun -eq $false) 'Adapter start did not publish a native session.'

    $follow = New-TelephoneAdapterInvocation -Adapter $adapter -Operation follow_up -NativeSessionId ([string]$startResult.native_session_id) -ExtraArguments @('-SessionStore', $sessionStore)
    Assert-TelephoneAdapterFollowUpSession -StartResult $startResult -FollowUpInvocation $follow
    $followArgs = [string[]]@($follow.arguments)
    $followOutput = (Invoke-ContractAdapter -Executable $follow.executable -Arguments $followArgs) | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
    Assert-ContractTest ([string]$followOutput.native_session_id -ceq [string]$startResult.native_session_id) 'Follow-up did not bind the same mock native session.'

    $wrongFollowFailed = $false
    try {
        $null = New-TelephoneAdapterInvocation -Adapter $adapter -Operation follow_up -NativeSessionId 'other-native' -ExtraArguments @('-SessionStore', $sessionStore)
        Assert-TelephoneAdapterFollowUpSession -StartResult $startResult -FollowUpInvocation ([ordered]@{ operation = 'follow_up'; native_session_id = 'other-native'; route_id = 'mock-native' })
    } catch { $wrongFollowFailed = $true }
    Assert-ContractTest $wrongFollowFailed 'Follow-up accepted a different native session.'

    $recover = New-TelephoneAdapterInvocation -Adapter $adapter -Operation recover -NativeSessionId ([string]$startResult.native_session_id) -ExtraArguments @('-SessionStore', $sessionStore)
    $recoverArgs = [string[]]@($recover.arguments)
    $recoverOutput = (Invoke-ContractAdapter -Executable $recover.executable -Arguments $recoverArgs) | ConvertFrom-Json -AsHashtable -Depth 8 -DateKind String
    Assert-ContractTest ($recoverOutput.replacement_started -eq $false -and $recoverOutput.automatic_rerun -eq $false) 'Recover started a replacement command.'

    $startWithSessionFailed = $false
    try { $null = New-TelephoneAdapterInvocation -Adapter $adapter -Operation start -NativeSessionId ([string]$startResult.native_session_id) } catch { $startWithSessionFailed = $true }
    Assert-ContractTest $startWithSessionFailed 'Adapter start reused a native session id.'

    $oneShot = Read-TelephoneAdapterDescriptor -Path 'adapter.one-shot.json' -AdapterRoot $fixtureRoot
    Assert-ContractTest ([bool]$oneShot.descriptor.capabilities.exact_native_session -eq $false) 'One-shot descriptor was required to set exact_native_session true.'
    $oneShotStart = New-TelephoneAdapterInvocation -Adapter $oneShot -Operation start
    Assert-ContractTest ([bool]$oneShotStart.exact_native_session -eq $false) 'Invocation did not copy exact_native_session false.'
    $oneShotFollowFailed = $false
    try { $null = New-TelephoneAdapterInvocation -Adapter $oneShot -Operation follow_up -NativeSessionId 'native-1' } catch { $oneShotFollowFailed = $true }
    Assert-ContractTest $oneShotFollowFailed 'One-shot follow_up was accepted.'
    $oneShotRecover = New-TelephoneAdapterInvocation -Adapter $oneShot -Operation recover -NativeSessionId 'native-1'
    Assert-ContractTest ([bool]$oneShotRecover.exact_native_session -eq $false) 'Recover implied native-session continuation.'

    $casePath = Join-Path 'VaLiD' 'ADAPTER.JSON'
    $caseResolved = Read-TelephoneAdapterDescriptor -Path $casePath -AdapterRoot $fixtureRoot
    Assert-ContractTest ([string]$caseResolved.descriptor.route_id -ceq 'mock-native') 'In-root adapter paths were not accepted case-insensitively.'

    $outsideRoot = Join-Path $TestRoot 'reparse-outside'
    $adapterRoot = Join-Path $TestRoot 'reparse-inside'
    $linkPath = Join-Path $adapterRoot 'escape'
    [IO.Directory]::CreateDirectory($outsideRoot) | Out-Null
    [IO.Directory]::CreateDirectory($adapterRoot) | Out-Null
    $outsideDescriptor = Join-Path $outsideRoot 'adapter.json'
    $outsideEntrypoint = Join-Path $outsideRoot 'windows-entrypoint.ps1'
    $insideDescriptor = Join-Path $adapterRoot 'adapter.json'
    [IO.File]::WriteAllText($outsideEntrypoint, "# SPDX-License-Identifier: MPL-2.0`n", [Text.UTF8Encoding]::new($false))
    $outsideDescriptorObject = [ordered]@{
        protocol_version = 'telephone-line-adapter-v1'
        route_id = 'mock-native'
        display_name = 'Mock Native Adapter'
        windows_entrypoint = 'windows-entrypoint.ps1'
        dependency_boundary = 'offline-mock-route'
        capabilities = [ordered]@{ start = $true; follow_up = $true; recover = $true; exact_native_session = $true }
    }
    $insideDescriptorObject = [ordered]@{
        protocol_version = 'telephone-line-adapter-v1'
        route_id = 'mock-native'
        display_name = 'Mock Native Adapter'
        windows_entrypoint = 'escape\windows-entrypoint.ps1'
        dependency_boundary = 'offline-mock-route'
        capabilities = [ordered]@{ start = $true; follow_up = $true; recover = $true; exact_native_session = $true }
    }
    $null = Write-TelephoneJsonCreateNew -Path $outsideDescriptor -Value $outsideDescriptorObject
    $null = Write-TelephoneJsonCreateNew -Path $insideDescriptor -Value $insideDescriptorObject
    $intermediateReparseRejected = 0
    try {
        $null = New-Item -ItemType Junction -Path $linkPath -Target $outsideRoot
        $descriptorReparseFailed = $false
        try {
            $null = Read-TelephoneAdapterDescriptor -Path 'escape\adapter.json' -AdapterRoot $adapterRoot
        } catch {
            $descriptorReparseFailed = $true
        }
        Assert-ContractTest $descriptorReparseFailed 'An intermediate reparse descriptor path was accepted.'
        $intermediateReparseRejected += 1

        $entrypointReparseFailed = $false
        try {
            $null = Read-TelephoneAdapterDescriptor -Path $insideDescriptor -AdapterRoot $adapterRoot
        } catch {
            $entrypointReparseFailed = $true
        }
        Assert-ContractTest $entrypointReparseFailed 'An intermediate reparse entrypoint path was accepted.'
        $intermediateReparseRejected += 1

        $resolveReparseFailed = $false
        try {
            $null = Resolve-TelephonePathInsideRoot -Path 'escape\adapter.json' -Root $adapterRoot -Label 'Reparse'
        } catch {
            $resolveReparseFailed = $true
        }
        Assert-ContractTest $resolveReparseFailed 'Resolve accepted an intermediate reparse component.'
        $intermediateReparseRejected += 1
    } finally {
        if (Test-Path -LiteralPath $linkPath) {
            $linkItem = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $linkItem -and ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                [IO.Directory]::Delete($linkPath)
            }
        }
    }
    Assert-ContractTest (-not (Test-Path -LiteralPath $linkPath)) 'The in-root reparse fixture was not removed.'

    $commonPath = Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1'
    $parseErrors = $null
    $parseTokens = $null
    $commonAst = [Management.Automation.Language.Parser]::ParseFile($commonPath, [ref]$parseTokens, [ref]$parseErrors)
    Assert-ContractTest ($null -eq $parseErrors -or @($parseErrors).Count -eq 0) 'TelephoneLine.Common.ps1 did not parse.'
    function Get-ContractValidateSetValues {
        param(
            [Parameter(Mandatory = $true)][Management.Automation.Language.Ast]$Ast,
            [Parameter(Mandatory = $true)][string]$FunctionName,
            [Parameter(Mandatory = $true)][string]$ParameterName
        )
        $functions = @($Ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $FunctionName
        }, $true))
        Assert-ContractTest ($functions.Count -eq 1) "Expected one function $FunctionName."
        $param = @($functions[0].Body.ParamBlock.Parameters | Where-Object {
            [string]$_.Name.VariablePath.UserPath -ceq $ParameterName
        }) | Select-Object -First 1
        Assert-ContractTest ($null -ne $param) "Expected parameter $ParameterName on $FunctionName."
        $attr = @($param.Attributes | Where-Object {
            [string]$_.TypeName.Name -ceq 'ValidateSet'
        }) | Select-Object -First 1
        Assert-ContractTest ($null -ne $attr) "Expected ValidateSet on $FunctionName -$ParameterName."
        return @($attr.PositionalArguments | ForEach-Object { [string]$_.SafeGetValue() })
    }
    $pathNames = @(Get-ContractValidateSetValues -Ast $commonAst -FunctionName 'Get-TelephoneSchemaPath' -ParameterName 'Name')
    $readNames = @(Get-ContractValidateSetValues -Ast $commonAst -FunctionName 'Read-TelephoneJson' -ParameterName 'SchemaName')
    Assert-ContractTest ($pathNames.Count -eq $readNames.Count) 'Get-TelephoneSchemaPath and Read-TelephoneJson schema-name sets have different lengths.'
    $pathSorted = @($pathNames)
    $readSorted = @($readNames)
    [Array]::Sort($pathSorted, [StringComparer]::Ordinal)
    [Array]::Sort($readSorted, [StringComparer]::Ordinal)
    for ($i = 0; $i -lt $pathSorted.Count; $i++) {
        Assert-ContractTest ([string]$pathSorted[$i] -ceq [string]$readSorted[$i]) 'Get-TelephoneSchemaPath and Read-TelephoneJson schema-name sets differ.'
    }
    Assert-ContractTest ($pathSorted -ccontains 'catalog') 'Schema-name set is missing catalog.'
    Assert-ContractTest ($pathSorted -ccontains 'release-manifest') 'Schema-name set is missing release-manifest.'
    foreach ($name in $pathNames) {
        $resolved = Get-TelephoneSchemaPath -Name $name
        Assert-ContractTest ([IO.File]::Exists($resolved)) "Schema file missing for $name."
        $expected = [IO.Path]::GetFullPath((Join-Path $repoRoot ('schemas\' + $name + '.schema.json')))
        Assert-ContractTest ([IO.Path]::GetFullPath($resolved) -ceq $expected) "Get-TelephoneSchemaPath did not resolve $name to the shipped schema file."
    }
    $schema_name_surface_consistent = 1

    [ordered]@{
        success = $true
        schema_valid = 28
        schema_negative = 34
        follow_up_same_native_session = 1
        recover_without_rerun = 1
        path_escape_rejected = 1
        unknown_fields_rejected = 1
        exact_native_session_optional = 1
        intermediate_reparse_rejected = $intermediateReparseRejected
        schema_name_surface_consistent = $schema_name_surface_consistent
        assertions = $assertions
    } | ConvertTo-Json -Compress
} finally {
    $reparseLink = Join-Path $TestRoot 'reparse-inside\escape'
    if (Test-Path -LiteralPath $reparseLink) {
        $reparseItem = Get-Item -LiteralPath $reparseLink -Force -ErrorAction SilentlyContinue
        if ($null -ne $reparseItem -and ($reparseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            [IO.Directory]::Delete($reparseLink)
        }
    }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $fullTestRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
    if ($fullTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($fullTestRoot)) {
        Remove-Item -LiteralPath $fullTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
