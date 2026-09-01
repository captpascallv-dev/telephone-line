# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SpecFile,
    [string]$OutputFile,
    [switch]$Activate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneControlPlane.Common.ps1')

function Write-ControlPlaneImmutableJson {
    param([string]$Path, [object]$Value, [string]$SchemaName = '')
    $text = ConvertTo-TelephoneControlPlaneJson -Value $Value
    if (-not [string]::IsNullOrWhiteSpace($SchemaName)) { Assert-TelephoneJsonSchema -JsonText $text -SchemaName $SchemaName -Label $SchemaName }
    $expected = Get-TelephoneControlPlaneValueIdentity -Path $Path -Value $Value
    if ([IO.File]::Exists($Path)) {
        $actual = Get-TelephoneFileIdentity -Path $Path
        if ([string]$actual.sha256 -cne [string]$expected.sha256) { throw ('Immutable control-plane file drifted: ' + $Path) }
        return $actual
    }
    return (Write-TelephoneJsonCreateNew -Path $Path -Value $Value)
}

function Write-ControlPlaneImmutableText {
    param([string]$Path, [string]$Text)
    $normalized = $Text.Replace("`r`n", "`n")
    if (-not $normalized.EndsWith("`n", [StringComparison]::Ordinal)) { $normalized += "`n" }
    $expectedBytes = [Text.UTF8Encoding]::new($false).GetBytes($normalized)
    $expectedSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expectedBytes)).ToLowerInvariant()
    if ([IO.File]::Exists($Path)) {
        $actual = Get-TelephoneFileIdentity -Path $Path
        if ([string]$actual.sha256 -cne $expectedSha) { throw ('Immutable control-plane text drifted: ' + $Path) }
        return $actual
    }
    return (Write-TelephoneTextCreateNew -Path $Path -Text $normalized)
}

$specRead = Read-TelephoneJson -Path $SpecFile -SchemaName 'control-plane-wave-spec'
$spec = $specRead.value
$authority = Get-TelephoneFileIdentity -Path (Assert-TelephoneRegularFilePath -Path ([string]$spec.authority_path) -Label 'Control-plane authority')
$controlRoot = [IO.Path]::GetFullPath([string]$spec.control_state_root).TrimEnd('\')
[IO.Directory]::CreateDirectory($controlRoot) | Out-Null
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\supervisor\TelephoneSupervisor.Common.ps1')
$routeCatalog = Get-Content -LiteralPath (Join-Path $repoRoot 'src\catalog\routes.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String
$routeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($routeRow in @($routeCatalog.routes)) { [void]$routeIds.Add([string]$routeRow.route_id) }
$installRoot = if ($spec.Contains('install_root') -and -not [string]::IsNullOrWhiteSpace([string]$spec.install_root)) { [IO.Path]::GetFullPath([string]$spec.install_root).TrimEnd('\') } else { $repoRoot }
$supervisorRoot = if ($spec.Contains('supervisor_state_root') -and -not [string]::IsNullOrWhiteSpace([string]$spec.supervisor_state_root)) { [IO.Path]::GetFullPath([string]$spec.supervisor_state_root).TrimEnd('\') } else { Join-Path $controlRoot 'supervisor-state' }
$waveId = if ($spec.Contains('wave_id') -and -not [string]::IsNullOrWhiteSpace([string]$spec.wave_id)) { [string]$spec.wave_id } else { 'wave-' + ([string]$specRead.identity.sha256).Substring(0, 16) }
$paths = Get-TelephoneControlPlanePaths -ControlStateRoot $controlRoot -Project ([string]$spec.project) -ProjectEpoch ([string]$spec.project_epoch) -WaveId $waveId
[IO.Directory]::CreateDirectory([string]$paths.wave_root) | Out-Null
$manifestPath = if ([string]::IsNullOrWhiteSpace($OutputFile)) { [string]$paths.manifest } else { [IO.Path]::GetFullPath($OutputFile) }
if (-not $manifestPath.Equals([string]$paths.manifest, [StringComparison]::OrdinalIgnoreCase)) { throw 'Wave manifest must use its immutable project/epoch/wave path.' }
if ([IO.File]::Exists($manifestPath)) {
    $existing = Read-TelephoneJson -Path $manifestPath -SchemaName 'control-plane-wave-manifest'
    if ([string]$existing.value.source_spec.sha256 -cne [string]$specRead.identity.sha256) { throw 'Existing versioned manifest belongs to another source spec.' }
    if ($Activate -or -not [IO.File]::Exists([string]$paths.pointer)) {
        $previous = Get-TelephoneControlPlaneOptionalIdentity -Path ([string]$paths.pointer)
        $pointer = [ordered]@{ protocol_version = 'telephone-line-control-plane-current-pointer-v1'; project = [string]$spec.project; project_epoch = [string]$spec.project_epoch; wave_id = $waveId; batch_id = [string]$existing.value.batch_id; activation_generation=[string]$existing.value.activation_generation; manifest = $existing.identity; previous_pointer = $previous; activated_at_utc = [DateTimeOffset]::UtcNow.ToString('o') }
        $null = Write-TelephoneJsonReplace -Path ([string]$paths.pointer) -Value $pointer
        $null = Register-TelephoneControlPlaneDashboard -Manifest $existing.value -Paths $paths -DashboardConfigPath $(if ($spec.Contains('dashboard_config_path')) { [string]$spec.dashboard_config_path } else { '' })
        $null = Register-TelephoneControlPlaneSupervisor -Manifest $existing.value -Paths $paths -ManifestIdentity $existing.identity
    }
    [ordered]@{ created = $false; replayed = $true; activated = [bool]($Activate -or -not [IO.File]::Exists([string]$paths.pointer)); manifest = $existing.identity; batch_id = [string]$existing.value.batch_id; batch_n = [int]$existing.value.batch_n; current_pointer = Get-TelephoneControlPlaneOptionalIdentity -Path ([string]$paths.pointer) } | ConvertTo-Json -Depth 16
    exit 0
}

$inputRows = [Collections.Generic.List[object]]::new()
$packageIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$lineIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$requestBatchIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($lane in @($spec.lanes)) {
    $packageId = [string]$lane.package_id
    if (-not $routeIds.Contains([string]$lane.route)) { throw 'Wave lane route is outside the frozen eight-route catalog.' }
    if (-not $packageIds.Add($packageId)) { throw 'Wave spec contains a duplicate package_id.' }
    $sourceRequest = $null
    if ($lane.Contains('request_file') -and -not [string]::IsNullOrWhiteSpace([string]$lane.request_file)) {
        $requestPath = Assert-TelephoneRegularFilePath -Path ([string]$lane.request_file) -Label 'Telephone request'
        $sourceRequest = Read-TelephoneJson -Path $requestPath
        Assert-TelephoneDispatchRequestText -JsonText ([string]$sourceRequest.text)
    }
    $lineId = if ($lane.Contains('line_job_id') -and -not [string]::IsNullOrWhiteSpace([string]$lane.line_job_id)) { [string]$lane.line_job_id } elseif ($null -ne $sourceRequest) { [string]$sourceRequest.value.line_job_id } else { New-TelephoneControlPlaneDeterministicGuid -Seed (([string]$spec.project) + '|' + ([string]$spec.project_epoch) + '|' + $waveId + '|' + $packageId) }
    if ($lineId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'Wave line_job_id must be a UUID.' }
    if ($null -ne $sourceRequest -and [string]$sourceRequest.value.line_job_id -cne $lineId) { throw 'Wave spec line_job_id disagrees with its source request.' }
    if (-not $lineIds.Add($lineId)) { throw 'Wave spec contains a duplicate line_job_id.' }
    if ($null -ne $sourceRequest) {
        $resolved = Resolve-TelephoneRequestBatch -Request $sourceRequest.value -LineJobId $lineId
        if (-not [string]::IsNullOrWhiteSpace([string]$resolved.batch_id)) { [void]$requestBatchIds.Add([string]$resolved.batch_id) }
    }
    [void]$inputRows.Add([ordered]@{ lane = $lane; package_id = $packageId; line_job_id = $lineId; source_request = $sourceRequest })
}
if ($requestBatchIds.Count -gt 1) { throw 'Wave source requests belong to multiple batch ids.' }
$batchId = if ($spec.Contains('batch_id') -and -not [string]::IsNullOrWhiteSpace([string]$spec.batch_id)) { [string]$spec.batch_id } elseif ($requestBatchIds.Count -eq 1) { @($requestBatchIds)[0] } else { New-TelephoneControlPlaneDeterministicGuid -Seed (([string]$spec.project) + '|' + ([string]$spec.project_epoch) + '|' + $waveId + '|' + ([string]$specRead.identity.sha256)) }
if ($requestBatchIds.Count -eq 1 -and @($requestBatchIds)[0] -cne $batchId) { throw 'Wave batch_id disagrees with its requests.' }
$activationGeneration = Get-TelephoneControlPlaneSha256 -Text (([string]$spec.project) + '|' + ([string]$spec.project_epoch) + '|' + $waveId + '|' + $batchId + '|' + ([string]$specRead.identity.sha256) + '|' + ([string]$authority.sha256))
$packageIdArray = @($inputRows | ForEach-Object { [string]$_.package_id })
$leadBinding = $null
if ($spec.Contains('lead_binding_file') -and -not [string]::IsNullOrWhiteSpace([string]$spec.lead_binding_file)) {
    $leadBinding = Read-TelephoneLeadBinding -Lead ([ordered]@{ binding_file = [string]$spec.lead_binding_file; session_id = [string]$spec.lead.session_id })
}
$laneDrafts = [Collections.Generic.List[object]]::new()
foreach ($row in $inputRows) {
    $lane = $row.lane; $packageId = [string]$row.package_id; $lineId = [string]$row.line_job_id
    $workspacePath = [IO.Path]::GetFullPath([string]$lane.workspace).TrimEnd('\')
    if (-not [IO.Directory]::Exists($workspacePath)) { [IO.Directory]::CreateDirectory($workspacePath) | Out-Null }
    $workspace = Assert-TelephoneDirectoryPath -Path $workspacePath -Label 'Wave workspace'
    $telephoneState = [IO.Path]::GetFullPath([string]$lane.telephone_state_root).TrimEnd('\')
    if (-not [IO.Directory]::Exists($telephoneState)) { [IO.Directory]::CreateDirectory($telephoneState) | Out-Null }
    $cardPath = if ($lane.Contains('card_file') -and -not [string]::IsNullOrWhiteSpace([string]$lane.card_file)) { Assert-TelephoneRegularFilePath -Path ([string]$lane.card_file) -Label 'Wave source card' } else { Join-Path (Join-Path ([string]$paths.wave_root) 'cards') ((Get-TelephoneControlPlaneSha256 -Text $packageId) + '.md') }
    if (-not [IO.File]::Exists($cardPath)) {
        if (-not $lane.Contains('card_text') -or [string]::IsNullOrWhiteSpace([string]$lane.card_text)) { throw 'High-level wave lane requires card_text when card_file is absent.' }
        $null = Write-ControlPlaneImmutableText -Path $cardPath -Text ([string]$lane.card_text)
    }
    $cardText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($cardPath))
    $characters = $cardText.Length
    if ([string]$lane.route -match '(?i)direct-cursor' -and ($characters -lt 1 -or $characters -gt 12000)) { throw 'Direct Cursor card is outside the 1-12000 character contract.' }
    $allowed = [Collections.Generic.List[string]]::new(); $workspacePrefix = $workspace.TrimEnd('\') + '\'
    foreach ($relativeValue in @($lane.allowed_write_paths)) {
        $relative = ([string]$relativeValue).Replace('/', '\')
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|\\)\.\.(\\|$)') { throw 'Allowed write path must be a contained relative file.' }
        $full = [IO.Path]::GetFullPath((Join-Path $workspace $relative))
        if (-not $full.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Allowed write path escapes its workspace.' }
        $parent = [IO.Path]::GetDirectoryName($full); if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        if (-not [IO.File]::Exists($full)) { [IO.File]::WriteAllBytes($full, [byte[]]@()) }
        [void]$allowed.Add($relative.Replace('\', '/'))
    }
    $writeLeaseId = Get-TelephoneControlPlaneSha256 -Text ($workspace + '|' + ((@($allowed) -join '|')))
    $source = $row.source_request
    if ($null -eq $source -and $null -eq $leadBinding) { throw 'High-level wave construction requires lead_binding_file.' }
    $sourceValue = if ($null -eq $source) { $null } else { $source.value }
    if ($null -ne $sourceValue) {
        if ([string]$sourceValue.project -cne [string]$spec.project -or [string]$sourceValue.role -cne [string]$lane.role -or [string]$sourceValue.route -cne [string]$lane.route) { throw 'Source request project/role/route disagrees with the frozen lane.' }
        $sourceBatch = Resolve-TelephoneRequestBatch -Request $sourceValue -LineJobId $lineId
        if ([string]$sourceBatch.package_id -cne $packageId) { throw 'Source request package disagrees with the frozen lane.' }
    }
    $requestLead = if ($null -ne $sourceValue) { Read-TelephoneLeadBinding -Lead $sourceValue.lead } else { $leadBinding }
    if ([string]$requestLead.session_id -cne [string]$spec.lead.session_id) { throw 'Wave request Lead session disagrees with the frozen control-plane Lead.' }
    $command = if ($null -ne $sourceValue) { $sourceValue.command } elseif ($lane.Contains('command')) { $lane.command } else { $null }
    if ($null -eq $command) { throw 'High-level wave lane requires a route command.' }
    $commandExe = Assert-TelephoneRegularFilePath -Path ([string]$command.executable) -Label 'Route executable'
    $commandWorking = Assert-TelephoneDirectoryPath -Path ([string]$command.working_directory) -Label 'Route working directory'
    if (-not $commandWorking.Equals($workspace, [StringComparison]::OrdinalIgnoreCase)) { throw 'Route command working_directory must equal the frozen lane workspace.' }
    $controlBinding = [ordered]@{
        protocol_version = 'telephone-line-control-plane-job-binding-v1'; project = [string]$spec.project; project_epoch = [string]$spec.project_epoch; wave_id = $waveId
        control_state_root = $controlRoot; supervisor_state_root = $supervisorRoot; install_root = $installRoot; manifest_path = $manifestPath; source_spec = $specRead.identity; authority = $authority
        activation_generation=$activationGeneration;lead_run_id=[string]$spec.lead.run_id;package_id=$packageId;batch_id=$batchId;attempt=1;route=[string]$lane.route;workspace=$workspace;write_lease_id=$writeLeaseId
    }
    $requestValue = [ordered]@{
        protocol_version = 'telephone-line-dispatch-v1'; line_job_id = $lineId; project = [string]$spec.project
        stage = $(if ($lane.Contains('stage') -and -not [string]::IsNullOrWhiteSpace([string]$lane.stage)) { [string]$lane.stage } else { $packageId })
        role = [string]$lane.role; route = [string]$lane.route; summary = $(if ($lane.Contains('summary') -and -not [string]::IsNullOrWhiteSpace([string]$lane.summary)) { [string]$lane.summary } else { $packageId })
        lead = $requestLead; command = [ordered]@{ executable = $commandExe; working_directory = $commandWorking; arguments = @($command.arguments | ForEach-Object { [string]$_ }) }
        batch = [ordered]@{ protocol_version = 'telephone-line-batch-v1'; batch_id = $batchId; n = $inputRows.Count; package_id = $packageId; package_ids = $packageIdArray }
        control_plane = $controlBinding
    }
    if ($command.Contains('stdin_file') -and -not [string]::IsNullOrWhiteSpace([string]$command.stdin_file)) { $requestValue.command['stdin_file'] = [string]$command.stdin_file }
    $requestPath = Join-Path (Join-Path ([string]$paths.wave_root) 'requests') ((Get-TelephoneControlPlaneSha256 -Text $packageId) + '.request.json')
    $requestIdentity = Write-ControlPlaneImmutableJson -Path $requestPath -Value $requestValue
    Assert-TelephoneDispatchRequestText -JsonText ([IO.File]::ReadAllText($requestPath))
    $startJobCommand = [ordered]@{
        executable = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName); working_directory = $installRoot
        arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $installRoot 'src\core\Start-TelephoneLineJob.ps1'),'-RequestFile',$requestPath,'-StateRoot',$telephoneState)
    }
    if ([string]$spec.lead.transport -ceq 'wired') {
        $supervisorRunId = New-TelephoneControlPlaneDeterministicGuid -Seed (([string]$spec.project) + '|' + ([string]$spec.project_epoch) + '|' + $waveId + '|' + $packageId + '|wired-supervisor')
        $pointerPath = Join-Path $installRoot 'current.json'
        $installedIdentity = if ([IO.File]::Exists($pointerPath)) {
            $pointer = (Read-TelephoneJson -Path $pointerPath).value
            [ordered]@{ version_id=[string]$pointer.version_id; source_sha256=[string]$pointer.source_sha256; install_root=$installRoot }
        } else {
            $sourceId = Get-TelephoneFileIdentity -Path (Join-Path $installRoot 'release-manifest.json')
            [ordered]@{ version_id=[string]$sourceId.sha256; source_sha256=[string]$sourceId.sha256; install_root=$installRoot }
        }
        $supervisorRequest = [ordered]@{
            protocol_version='telephone-line-wired-supervisor-request-v1'; run_id=$supervisorRunId; request_sha256=''; project=[string]$spec.project; stage=('CONTROL_PLANE_' + $waveId + '_' + $packageId)
            lead_session_id=[string]$spec.lead.session_id; lead_run_id=('control-plane-' + $waveId + '-' + $packageId); summary=('Supervisor-owned launch for ' + $packageId)
            worktree=$workspace; command=$startJobCommand; installed_version=$installedIdentity; created_at_utc='2000-01-01T00:00:00Z'
        }
        $supervisorRequest.request_sha256 = Get-TelephoneSupervisorRequestHash -Request $supervisorRequest
        $supervisorRequestPath = Join-Path (Join-Path ([string]$paths.wave_root) 'supervisor-requests') ((Get-TelephoneControlPlaneSha256 -Text $packageId) + '.json')
        $supervisorRequestIdentity = Write-ControlPlaneImmutableJson -Path $supervisorRequestPath -Value $supervisorRequest -SchemaName 'wired-supervisor-request'
        $starter = [ordered]@{
            executable = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName); working_directory = $installRoot
            arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $installRoot 'src\supervisor\Start-TelephoneWiredRun.ps1'),'-RequestFile',$supervisorRequestPath,'-StateRoot',$supervisorRoot,'-InstallRoot',$installRoot)
        }
        $launchOwner=[ordered]@{kind='wired_supervisor';state_root=$supervisorRoot;run_id=$supervisorRunId;request=$supervisorRequestIdentity;request_sha256=[string]$supervisorRequest.request_sha256}
    } else {
        if (-not $lane.Contains('starter_command') -or [string]$lane.starter_command.arguments -notmatch '(?i)app.server|app-server') { throw 'Wireless control-plane lane requires an explicit typed App Server starter.' }
        $starter = [ordered]@{ executable=$(Assert-TelephoneRegularFilePath -Path ([string]$lane.starter_command.executable) -Label 'Wireless App Server starter'); working_directory=$(Assert-TelephoneDirectoryPath -Path ([string]$lane.starter_command.working_directory) -Label 'Wireless App Server starter working directory'); arguments=@($lane.starter_command.arguments|ForEach-Object{[string]$_}) }
        $launchOwner=[ordered]@{kind='wireless_app_server';starter_sha256=(Get-TelephoneControlPlaneJsonFingerprint -Value $starter)}
    }
    [void]$laneDrafts.Add([ordered]@{
        package_id = $packageId; role = [string]$lane.role; route = [string]$lane.route; line_job_id = $lineId; request = $requestIdentity
        telephone_state_root = $telephoneState; workspace = $workspace; card = Get-TelephoneFileIdentity -Path $cardPath; card_characters = $characters
        allowed_write_paths = @($allowed); write_lease_id = $writeLeaseId
        launch_grace_seconds = $(if ($lane.Contains('launch_grace_seconds')) { [int]$lane.launch_grace_seconds } else { 30 })
        callback_grace_seconds = $(if ($lane.Contains('callback_grace_seconds')) { [int]$lane.callback_grace_seconds } else { 60 })
        starter_command = $starter; launch_owner = $launchOwner
    })
}

$next = if ($spec.Contains('next_transition') -and $null -ne $spec.next_transition) { $spec.next_transition } else { [ordered]@{ transition_id = 'manual-next'; kind = 'manual'; authorized = $false; idempotency_key = 'manual:' + $batchId } }
$actionDrafts = [Collections.Generic.List[object]]::new(); $actionIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); $actionKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$sequence = 0
foreach ($action in @($spec.actions)) {
    $sequence += 1
    if (-not $actionIds.Add([string]$action.action_id) -or -not $actionKeys.Add([string]$action.idempotency_key)) { throw 'Wave actions must have unique ids and idempotency keys.' }
    $kind = [string]$action.kind
    if ($kind -ceq 'lane_recovery' -and [string]$action.trigger.kind -cne 'lane_failed') { throw 'lane_recovery requires a lane_failed trigger.' }
    if ($kind -ceq 'second_turn' -and [string]$action.trigger.kind -notin @('json_true','file_text_equals','file_exists')) { throw 'second_turn requires a durable admission-result trigger.' }
    if ($kind -ceq 'next_wave') {
        if (-not [bool]$next.authorized -or [string]$next.kind -cne 'next_wave' -or [string]$next.idempotency_key -cne [string]$action.idempotency_key) { throw 'next_wave action is not bound to the exact authorized next transition.' }
        if ([string]$action.trigger.kind -cnotin @('all_lanes_delivered','all_lanes_terminal')) { throw 'next_wave requires a complete-denominator trigger.' }
    }
    $targetLane = $null
    $replacementValue = $null
    if ($kind -ceq 'lane_recovery') {
        $target = [string]$action.trigger.target_package_id
        $targetLane = @($laneDrafts | Where-Object { [string]$_.package_id -ceq $target })
        if ($targetLane.Count -ne 1) { throw 'lane_recovery must target exactly one frozen package.' }
        if (-not $action.Contains('replacement') -or $null -eq $action.replacement) { throw 'lane_recovery requires a typed replacement attempt.' }
        if ([string]$action.replacement.package_id -cne $target -or [string]$action.replacement.retry_of_line_job_id -cne [string]$targetLane[0].line_job_id) { throw 'lane_recovery replacement lineage is invalid.' }
        $replacementLine = [string]$action.replacement.line_job_id
        if ($replacementLine -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or $replacementLine -ceq [string]$targetLane[0].line_job_id) { throw 'lane_recovery replacement line_job_id is invalid.' }
        $replacementRequestPath = Assert-TelephoneRegularFilePath -Path ([string]$action.replacement.request_file) -Label 'Lane recovery request'
        $replacementRequest = Read-TelephoneJson -Path $replacementRequestPath
        Assert-TelephoneDispatchRequestText -JsonText ([string]$replacementRequest.text)
        if ([string]$replacementRequest.value.line_job_id -cne $replacementLine -or [string]$replacementRequest.value.project -cne [string]$spec.project) { throw 'Lane recovery request identity drifted.' }
        $replacementLead = Read-TelephoneLeadBinding -Lead $replacementRequest.value.lead
        if ([string]$replacementLead.session_id -cne [string]$spec.lead.session_id -or [string]$replacementRequest.value.route -cne [string]$targetLane[0].route -or [string]$replacementRequest.value.role -cne [string]$targetLane[0].role) { throw 'Lane recovery request changed the frozen Lead, route, or role.' }
        $replacementWorking = Assert-TelephoneDirectoryPath -Path ([string]$replacementRequest.value.command.working_directory) -Label 'Lane recovery working directory'
        if (-not $replacementWorking.Equals([string]$targetLane[0].workspace, [StringComparison]::OrdinalIgnoreCase)) { throw 'Lane recovery request changed the frozen workspace.' }
        $replacementBatch = Resolve-TelephoneRequestBatch -Request $replacementRequest.value -LineJobId $replacementLine
        if ([string]$replacementBatch.package_id -cne $target -or [string]$replacementBatch.retry_of -cne $batchId -or [string]$replacementBatch.batch_id -ceq $batchId) { throw 'Lane recovery request must be a new bounded retry batch for the same package.' }
        $replacementRequestValue = $replacementRequest.value
        $replacementRequestValue['control_plane'] = [ordered]@{
            protocol_version = 'telephone-line-control-plane-job-binding-v1'; project = [string]$spec.project; project_epoch = [string]$spec.project_epoch; wave_id = $waveId
            control_state_root = $controlRoot; supervisor_state_root = $supervisorRoot; install_root = $installRoot; manifest_path = $manifestPath; source_spec = $specRead.identity; authority = $authority
            activation_generation=$activationGeneration;lead_run_id=[string]$spec.lead.run_id;package_id=$target;batch_id=[string]$replacementBatch.batch_id;attempt=[int]$action.replacement.attempt;route=[string]$targetLane[0].route;workspace=[string]$targetLane[0].workspace;write_lease_id=[string]$targetLane[0].write_lease_id
        }
        $canonicalReplacementPath = Join-Path (Join-Path ([string]$paths.wave_root) 'requests') ('replacement-' + (Get-TelephoneControlPlaneSha256 -Text ($target + '|' + [string]$action.replacement.attempt)) + '.request.json')
        $canonicalReplacementIdentity = Write-ControlPlaneImmutableJson -Path $canonicalReplacementPath -Value $replacementRequestValue
        $replacementStartCommand = [ordered]@{ executable=[string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName); working_directory=$installRoot; arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $installRoot 'src\core\Start-TelephoneLineJob.ps1'),'-RequestFile',$canonicalReplacementPath,'-StateRoot',[string]$targetLane[0].telephone_state_root) }
        if ([string]$spec.lead.transport -ceq 'wired') {
            $replacementSupervisorRunId = New-TelephoneControlPlaneDeterministicGuid -Seed (([string]$spec.project) + '|' + ([string]$spec.project_epoch) + '|' + $waveId + '|' + $target + '|' + [string]$action.replacement.attempt + '|wired-supervisor')
            $pointerPath = Join-Path $installRoot 'current.json'
            $replacementInstalled = if ([IO.File]::Exists($pointerPath)) { $p=(Read-TelephoneJson -Path $pointerPath).value;[ordered]@{version_id=[string]$p.version_id;source_sha256=[string]$p.source_sha256;install_root=$installRoot} } else { $id=Get-TelephoneFileIdentity -Path (Join-Path $installRoot 'release-manifest.json');[ordered]@{version_id=[string]$id.sha256;source_sha256=[string]$id.sha256;install_root=$installRoot} }
            $replacementSupervisorRequest = [ordered]@{ protocol_version='telephone-line-wired-supervisor-request-v1';run_id=$replacementSupervisorRunId;request_sha256='';project=[string]$spec.project;stage=('CONTROL_PLANE_RECOVERY_' + $waveId + '_' + $target);lead_session_id=[string]$spec.lead.session_id;lead_run_id=('control-plane-recovery-' + $waveId + '-' + $target);summary=('Supervisor-owned recovery launch for ' + $target);worktree=[string]$targetLane[0].workspace;command=$replacementStartCommand;installed_version=$replacementInstalled;created_at_utc='2000-01-01T00:00:00Z' }
            $replacementSupervisorRequest.request_sha256 = Get-TelephoneSupervisorRequestHash -Request $replacementSupervisorRequest
            $replacementSupervisorRequestPath = Join-Path (Join-Path ([string]$paths.wave_root) 'supervisor-requests') ('replacement-' + (Get-TelephoneControlPlaneSha256 -Text ($target + '|' + [string]$action.replacement.attempt)) + '.json')
            $null = Write-ControlPlaneImmutableJson -Path $replacementSupervisorRequestPath -Value $replacementSupervisorRequest -SchemaName 'wired-supervisor-request'
            $replacementStarter = [ordered]@{ executable=[string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName);working_directory=$installRoot;arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $installRoot 'src\supervisor\Start-TelephoneWiredRun.ps1'),'-RequestFile',$replacementSupervisorRequestPath,'-StateRoot',$supervisorRoot,'-InstallRoot',$installRoot) }
        } else { $replacementStarter = $replacementStartCommand }
        $replacementValue = [ordered]@{
            package_id = $target; line_job_id = $replacementLine; retry_of_line_job_id = [string]$targetLane[0].line_job_id
            attempt = [int]$action.replacement.attempt; request = $canonicalReplacementIdentity; starter_command = $replacementStarter
            telephone_state_root = [string]$targetLane[0].telephone_state_root; workspace = [string]$targetLane[0].workspace; write_lease_id = [string]$targetLane[0].write_lease_id
        }
    }
    $commandExe = Assert-TelephoneRegularFilePath -Path ([string]$action.command.executable) -Label 'Control-plane action executable'
    $commandWorking = Assert-TelephoneDirectoryPath -Path ([string]$action.command.working_directory) -Label 'Control-plane action working directory'
    $commandValue = [ordered]@{ executable = $commandExe; working_directory = $commandWorking; arguments = @($action.command.arguments | ForEach-Object { [string]$_ }) }
    if ($kind -ceq 'lane_recovery') { $commandValue = $replacementValue.starter_command }
    $expected = if ($action.Contains('expected_postcondition') -and $null -ne $action.expected_postcondition) { $action.expected_postcondition } else { [ordered]@{ kind = 'exit_zero' } }
    if ($kind -ceq 'lane_recovery' -and [string]$spec.lead.transport -ceq 'wired') {
        $expected = [ordered]@{ kind='supervisor_request_published';state_root=$supervisorRoot;run_id=$replacementSupervisorRunId;request_sha256=[string]$replacementSupervisorRequest.request_sha256 }
    }
    $contract = [ordered]@{
        project = [string]$spec.project; project_epoch = [string]$spec.project_epoch; wave_id = $waveId; batch_id = $batchId; authority = $authority; source_spec = $specRead.identity
        lead = $spec.lead; command_sha256 = Get-TelephoneControlPlaneJsonFingerprint -Value $commandValue; expected_postcondition = $expected
        target_package_id = $(if ($null -eq $targetLane) { $null } else { [string]$targetLane[0].package_id })
        target_line_job_id = $(if ($null -eq $targetLane) { $null } else { [string]$targetLane[0].line_job_id })
        target_workspace = $(if ($null -eq $targetLane) { $null } else { [string]$targetLane[0].workspace })
        target_write_lease_id = $(if ($null -eq $targetLane) { $null } else { [string]$targetLane[0].write_lease_id })
        replacement = $replacementValue
        retry_policy = $(if ($action.Contains('retry_policy')) { [string]$action.retry_policy } else { 'conflict_if_ambiguous' })
    }
    $contract['contract_fingerprint'] = Get-TelephoneControlPlaneJsonFingerprint -Value $contract
    $dependencyRows = [object[]]@($(if ($action.Contains('depends_on')) { @($action.depends_on | ForEach-Object { [string]$_ }) } else { @() }))
    [void]$actionDrafts.Add([ordered]@{
        action_id = [string]$action.action_id; kind = $kind; sequence = $(if ($action.Contains('sequence')) { [int]$action.sequence } else { $sequence })
        depends_on = $dependencyRows
        idempotency_key = [string]$action.idempotency_key; trigger = $action.trigger; command = $commandValue; contract = $contract
    })
}
$transitionActions=@($actionDrafts|Where-Object{[string]$_.kind-ceq'next_wave'})
if([string]$next.kind-ceq'next_wave' -and [bool]$next.authorized){
    if($transitionActions.Count-ne1-or[string]$transitionActions[0].idempotency_key-cne[string]$next.idempotency_key){throw 'Authorized next transition requires one exact next_wave action.'}
    $maxSequence=(@($actionDrafts|ForEach-Object{[int]$_.sequence}|Measure-Object -Maximum).Maximum)
    if([int]$transitionActions[0].sequence-ne[int]$maxSequence){throw 'next_wave action must be last in the wave.'}
} elseif($transitionActions.Count-gt0){throw 'next_wave action requires an authorized next-wave transition.'}

$manifest = [ordered]@{
    protocol_version = 'telephone-line-control-plane-wave-manifest-v1'; project = [string]$spec.project; project_epoch = [string]$spec.project_epoch; goal_summary = [string]$spec.goal_summary
    authority = $authority; lead = $spec.lead; wave_id = $waveId; batch_id = $batchId; batch_n = $laneDrafts.Count; control_state_root = $controlRoot
    supervisor_state_root = $supervisorRoot; install_root = $installRoot; activation_generation = $activationGeneration; projection_stale_after_seconds = $(if ($spec.Contains('projection_stale_after_seconds')) { [int]$spec.projection_stale_after_seconds } else { 120 })
    lanes = @($laneDrafts.ToArray()); actions = @($actionDrafts.ToArray()); next_transition = $next; source_spec = $specRead.identity; generated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$manifestIdentity = Write-ControlPlaneImmutableJson -Path $manifestPath -Value $manifest -SchemaName 'control-plane-wave-manifest'
$activateNow = ($Activate -or -not [IO.File]::Exists([string]$paths.pointer))
$pointerIdentity = $null; $dashboard = $null; $registration = $null
if ($activateNow) {
    $previous = Get-TelephoneControlPlaneOptionalIdentity -Path ([string]$paths.pointer)
    $pointer = [ordered]@{ protocol_version = 'telephone-line-control-plane-current-pointer-v1'; project = [string]$spec.project; project_epoch = [string]$spec.project_epoch; wave_id = $waveId; batch_id = $batchId; activation_generation=$activationGeneration; manifest = $manifestIdentity; previous_pointer = $previous; activated_at_utc = [DateTimeOffset]::UtcNow.ToString('o') }
    $pointerText = ConvertTo-TelephoneControlPlaneJson -Value $pointer; Assert-TelephoneJsonSchema -JsonText $pointerText -SchemaName 'control-plane-current-pointer' -Label 'control-plane current pointer'
    $pointerIdentity = Write-TelephoneJsonReplace -Path ([string]$paths.pointer) -Value $pointer
    $dashboard = Register-TelephoneControlPlaneDashboard -Manifest $manifest -Paths $paths -DashboardConfigPath $(if ($spec.Contains('dashboard_config_path')) { [string]$spec.dashboard_config_path } else { '' })
    $registration = Register-TelephoneControlPlaneSupervisor -Manifest $manifest -Paths $paths -ManifestIdentity $manifestIdentity
}
[ordered]@{
    created = $true; replayed = $false; activated = [bool]$activateNow; manifest = $manifestIdentity; current_pointer = $pointerIdentity
    dashboard_binding = $dashboard; supervisor_registration = $registration; batch_id = $batchId; batch_n = $laneDrafts.Count
    canonical_request_count = $laneDrafts.Count; scaffolded_path_count = @($laneDrafts | ForEach-Object { @($_.allowed_write_paths) }).Count
} | ConvertTo-Json -Depth 24
