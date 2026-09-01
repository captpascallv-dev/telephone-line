# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ManifestFile, [switch]$Apply)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneControlPlane.Common.ps1')

function Get-ControllerJsonProperty {
    param([Parameter(Mandatory = $true)][object]$Value, [Parameter(Mandatory = $true)][string]$Path)
    $current = $Value
    foreach ($name in @($Path -split '\.')) {
        if ($current -is [Collections.IDictionary]) { if (-not $current.Contains($name)) { return $null }; $current = $current[$name] }
        else { $prop = $current.PSObject.Properties[$name]; if ($null -eq $prop) { return $null }; $current = $prop.Value }
    }
    return $current
}

function Test-ControllerTrigger {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Trigger, [Parameter(Mandatory = $true)][Collections.IDictionary]$Current)
    switch ([string]$Trigger.kind) {
        'always' { return $true }
        'all_lanes_delivered' { return (@($Current.lanes | Where-Object { [string]$_.state -cnotin @('delivered','handled') }).Count -eq 0) }
        'all_lanes_terminal' { return (@($Current.lanes | Where-Object { [string]$_.state -cnotin @('delivered','handled','failed','unknown') }).Count -eq 0) }
        'lane_failed' { return (@($Current.lanes | Where-Object { [string]$_.package_id -ceq [string]$Trigger.target_package_id -and [string]$_.state -cin @('failed','unknown') }).Count -eq 1) }
        'file_exists' { return [IO.File]::Exists([string]$Trigger.path) }
        'file_text_equals' { return ([IO.File]::Exists([string]$Trigger.path) -and [IO.File]::ReadAllText([string]$Trigger.path).Trim() -ceq [string]$Trigger.expected_text) }
        'json_true' {
            if (-not [IO.File]::Exists([string]$Trigger.path)) { return $false }
            try { $value = (Read-TelephoneJson -Path ([string]$Trigger.path)).value; $found = Get-ControllerJsonProperty -Value $value -Path ([string]$Trigger.json_property); return ($found -is [bool] -and [bool]$found) } catch { return $false }
        }
        default { throw 'Unsupported controller trigger.' }
    }
}

function Test-ControllerPostcondition {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Postcondition, [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths)
    switch ([string]$Postcondition.kind) {
        'exit_zero' { return $false }
        'file_exists' { return [IO.File]::Exists([string]$Postcondition.path) }
        'file_text_equals' { return ([IO.File]::Exists([string]$Postcondition.path) -and [IO.File]::ReadAllText([string]$Postcondition.path).Trim() -ceq [string]$Postcondition.expected_text) }
        'json_true' {
            if (-not [IO.File]::Exists([string]$Postcondition.path)) { return $false }
            try { $value = (Read-TelephoneJson -Path ([string]$Postcondition.path)).value; $found = Get-ControllerJsonProperty -Value $value -Path ([string]$Postcondition.json_property); return ($found -is [bool] -and [bool]$found) } catch { return $false }
        }
        'current_wave' {
            if (-not [IO.File]::Exists([string]$Paths.pointer)) { return $false }
            try { $pointer = (Read-TelephoneJson -Path ([string]$Paths.pointer) -SchemaName 'control-plane-current-pointer').value; return ([string]$pointer.project_epoch -ceq [string]$Postcondition.project_epoch -and [string]$pointer.wave_id -ceq [string]$Postcondition.wave_id) } catch { return $false }
        }
        'lane_job_exists' { return [IO.File]::Exists((Join-Path (Join-Path (Join-Path ([string]$Postcondition.telephone_state_root) 'jobs') ([string]$Postcondition.line_job_id)) 'dispatch.json')) }
        'supervisor_request_published' {
            $root=[IO.Path]::GetFullPath([string]$Postcondition.state_root).TrimEnd('\');$file=([string]$Postcondition.run_id+'.json')
            foreach($kind in @('inbox','claimed','outbox')){
                $candidate=Join-Path (Join-Path $root $kind) $file
                if(-not[IO.File]::Exists($candidate)){continue}
                try{$value=(Read-TelephoneJson -Path $candidate).value;if([string]$value.run_id-ceq[string]$Postcondition.run_id-and[string]$value.request_sha256-ceq[string]$Postcondition.request_sha256){return $true}}catch{}
            }
            return $false
        }
        default { throw 'Unsupported action postcondition.' }
    }
}

function Assert-ControllerActionContract {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Action, [Parameter(Mandatory = $true)][Collections.IDictionary]$Manifest)
    $contract = $Action.contract
    foreach ($pair in @(@('project','project'),@('project_epoch','project_epoch'),@('wave_id','wave_id'),@('batch_id','batch_id'))) {
        if ([string]$contract[$pair[0]] -cne [string]$Manifest[$pair[1]]) { throw ('Action contract drifted: ' + $pair[0]) }
    }
    Assert-TelephoneFileIdentity -Expected $Manifest.authority -Actual $contract.authority -Label 'Action authority'
    Assert-TelephoneFileIdentity -Expected $Manifest.source_spec -Actual $contract.source_spec -Label 'Action source spec'
    foreach ($name in @('transport','session_id','run_id')) { if ([string]$contract.lead[$name] -cne [string]$Manifest.lead[$name]) { throw ('Action Lead identity drifted: ' + $name) } }
    $commandSha = Get-TelephoneControlPlaneJsonFingerprint -Value $Action.command
    if ([string]$contract.command_sha256 -cne $commandSha) { throw 'Action command hash drifted.' }
    $copy = [ordered]@{}
    foreach ($key in $contract.Keys) { if ([string]$key -cne 'contract_fingerprint') { $copy[$key] = $contract[$key] } }
    if ([string]$contract.contract_fingerprint -cne (Get-TelephoneControlPlaneJsonFingerprint -Value $copy)) { throw 'Action contract fingerprint drifted.' }
    if ([string]$Action.kind -ceq 'custom_authorized') { return 'CUSTOM_ACTION_NOT_AUTOMATIC' }
    if ([string]$Action.kind -ceq 'second_turn') {
        if ([string]$contract.lead.session_id -cne [string]$Manifest.lead.session_id -or [string]$contract.lead.run_id -cne [string]$Manifest.lead.run_id) { throw 'Second turn is not bound to the exact frozen Lead.' }
    }
    if ([string]$Action.kind -ceq 'lane_recovery') {
        if ([string]$Action.trigger.kind -cne 'lane_failed' -or $null -eq $contract.replacement) { throw 'Lane recovery lacks a typed replacement.' }
        $target = @($Manifest.lanes | Where-Object { [string]$_.package_id -ceq [string]$contract.target_package_id })
        if ($target.Count -ne 1 -or [string]$target[0].line_job_id -cne [string]$contract.target_line_job_id -or [string]$target[0].workspace -cne [string]$contract.target_workspace -or [string]$target[0].write_lease_id -cne [string]$contract.target_write_lease_id) { throw 'Lane recovery scope drifted from its frozen lane.' }
        if ([string]$contract.replacement.package_id -cne [string]$target[0].package_id -or [string]$contract.replacement.retry_of_line_job_id -cne [string]$target[0].line_job_id -or [string]$contract.replacement.line_job_id -ceq [string]$target[0].line_job_id) { throw 'Lane recovery lineage is invalid.' }
    }
    if ([string]$Action.kind -ceq 'next_wave') {
        if (-not [bool]$Manifest.next_transition.authorized -or [string]$Manifest.next_transition.kind -cne 'next_wave' -or [string]$Manifest.next_transition.idempotency_key -cne [string]$Action.idempotency_key) { throw 'Next-wave action is not the authorized transition.' }
    }
    return 'OK'
}

function Invoke-ControllerCommand {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Command, [Parameter(Mandatory = $true)][string]$OwnerPath)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Assert-TelephoneRegularFilePath -Path ([string]$Command.executable) -Label 'Controller action executable'
    $info.WorkingDirectory = Assert-TelephoneDirectoryPath -Path ([string]$Command.working_directory) -Label 'Controller action working directory'
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($arg in @($Command.arguments)) { [void]$info.ArgumentList.Add([string]$arg) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $owner = [ordered]@{ pid = [int]$process.Id; start_time_utc_ticks = [int64]$process.StartTime.ToUniversalTime().Ticks; started_at_utc = $process.StartTime.ToUniversalTime().ToString('o') }
        $null = Write-TelephoneJsonReplace -Path $OwnerPath -Value $owner
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync(); $process.WaitForExit()
        return [ordered]@{ exit_code = [int]$process.ExitCode; stdout = [string]$stdoutTask.GetAwaiter().GetResult(); stderr = [string]$stderrTask.GetAwaiter().GetResult(); owner = $owner }
    } finally { $process.Dispose() }
}

function Write-ControllerOutputFile {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Text)
    $payload = if ([string]::IsNullOrEmpty($Text)) { "`n" } else { [string]$Text }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($payload)
    return (Write-TelephoneBytesReplace -Path $Path -Bytes $bytes)
}

function Test-ControllerExistingResult {
    param([string]$Path, [Collections.IDictionary]$Action, [object]$ManifestIdentity)
    if (-not [IO.File]::Exists($Path)) { return $null }
    $read = Read-TelephoneJson -Path $Path -SchemaName 'control-plane-action-result'
    $value = $read.value
    foreach ($name in @('action_id','idempotency_key','kind')) { if ([string]$value[$name] -cne [string]$Action[$name]) { throw 'Existing action result identity drifted.' } }
    Assert-TelephoneFileIdentity -Expected $ManifestIdentity -Actual $value.manifest -Label 'Action result manifest'
    if ([string]$value.contract_fingerprint -cne [string]$Action.contract.contract_fingerprint -or [string]$value.command_sha256 -cne [string]$Action.contract.command_sha256) { throw 'Existing action result contract drifted.' }
    return $read
}

function Publish-ControllerResult {
    param(
        [Collections.IDictionary]$Action, [object]$ManifestIdentity, [object]$IntentIdentity, [object]$StateBefore, [object]$StateAfter,
        [int]$ExitCode, [string]$Status, [string]$StartedAt, [object]$StdoutIdentity, [object]$StderrIdentity, [string]$ResultPath,
        [bool]$Recovered = $false, [int]$RetryCount = 0, [object]$PreservedLaneFingerprints = $null
    )
    $result = [ordered]@{
        protocol_version = 'telephone-line-control-plane-action-result-v1'; action_id = [string]$Action.action_id; idempotency_key = [string]$Action.idempotency_key; kind = [string]$Action.kind
        manifest = $ManifestIdentity; contract_fingerprint = [string]$Action.contract.contract_fingerprint; command_sha256 = [string]$Action.contract.command_sha256; intent = $IntentIdentity
        status = $Status; exit_code = $ExitCode; started_at_utc = $StartedAt; completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        stdout = $StdoutIdentity; stderr = $StderrIdentity; state_before = $StateBefore; state_after = $StateAfter; recovered_after_crash = $Recovered; retry_count = $RetryCount
        preserved_lane_fingerprints = $(if ($null -eq $PreservedLaneFingerprints) { @{} } else { $PreservedLaneFingerprints })
    }
    $text = ConvertTo-TelephoneControlPlaneJson -Value $result; Assert-TelephoneJsonSchema -JsonText $text -SchemaName 'control-plane-action-result' -Label 'control-plane action result'
    if ([IO.File]::Exists($ResultPath)) { return (Test-ControllerExistingResult -Path $ResultPath -Action $Action -ManifestIdentity $ManifestIdentity).identity }
    return (Write-TelephoneJsonCreateNew -Path $ResultPath -Value $result)
}

function Set-ControllerLaneAttempt {
    param([Collections.IDictionary]$Action, [Collections.IDictionary]$Manifest, [Collections.IDictionary]$Paths, [object]$IntentIdentity)
    $replacement = $Action.contract.replacement
    $target = @($Manifest.lanes | Where-Object { [string]$_.package_id -ceq [string]$Action.contract.target_package_id })[0]
    $requestIdentity = Get-TelephoneFileIdentity -Path ([string]$replacement.request.path)
    Assert-TelephoneFileIdentity -Expected $replacement.request -Actual $requestIdentity -Label 'Replacement request'
    $pointer = [ordered]@{
        protocol_version = 'telephone-line-control-plane-lane-attempt-v1'; package_id = [string]$replacement.package_id; original_line_job_id = [string]$target.line_job_id
        line_job_id = [string]$replacement.line_job_id; retry_of_line_job_id = [string]$replacement.retry_of_line_job_id; attempt = [int]$replacement.attempt
        request = $requestIdentity; action_intent = $IntentIdentity; activated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $path = Join-Path ([string]$Paths.lane_attempts) ((Get-TelephoneControlPlaneSha256 -Text ([string]$replacement.package_id)) + '.json')
    [IO.Directory]::CreateDirectory([string]$Paths.lane_attempts) | Out-Null
    $text = ConvertTo-TelephoneControlPlaneJson -Value $pointer; Assert-TelephoneJsonSchema -JsonText $text -SchemaName 'control-plane-lane-attempt' -Label 'lane attempt'
    return (Write-TelephoneJsonReplace -Path $path -Value $pointer)
}

function Set-ControllerBlockedDecision {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Action,
        [Parameter(Mandatory = $true)][object]$ManifestIdentity,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Paths,
        [Parameter(Mandatory = $true)][bool]$Active,
        [string]$Code = ''
    )
    $key=Get-TelephoneControlPlaneSha256 -Text (([string]$ManifestIdentity.sha256)+'|'+[string]$Action.idempotency_key)
    $path=Join-Path ([string]$Paths.actions) ($key+'.blocked.json')
    $prior=$null
    if([IO.File]::Exists($path)){try{$prior=(Read-TelephoneJson -Path $path).value}catch{$prior=$null}}
    if($null-ne$prior-and[string]$prior.protocol_version-ceq'telephone-line-control-plane-action-blocked-v1'-and[string]$prior.action_id-ceq[string]$Action.action_id-and[string]$prior.idempotency_key-ceq[string]$Action.idempotency_key-and[string]$prior.manifest_sha256-ceq[string]$ManifestIdentity.sha256-and[bool]$prior.active-eq$Active-and(-not$Active-or[string]$prior.code-ceq$Code)){return $false}
    $record=[ordered]@{protocol_version='telephone-line-control-plane-action-blocked-v1';action_id=[string]$Action.action_id;idempotency_key=[string]$Action.idempotency_key;manifest_sha256=[string]$ManifestIdentity.sha256;active=$Active;due=$Active;code=$(if($Active){$Code}else{'RESOLVED'});updated_at_utc=[DateTimeOffset]::UtcNow.ToString('o')}
    if($null-ne$prior-and$prior.Contains('code')){$record['previous_code']=[string]$prior.code}
    $null=Write-TelephoneJsonReplace -Path $path -Value $record
    return $true
}

function Add-ControllerBlockedDecision {
    param([Collections.Generic.List[object]]$List,[Collections.IDictionary]$Action,[string]$Code,[object]$ManifestIdentity,[Collections.IDictionary]$Paths,[bool]$Persist)
    [void]$List.Add([ordered]@{action_id=[string]$Action.action_id;code=$Code})
    if($Persist){$null=Set-ControllerBlockedDecision -Action $Action -ManifestIdentity $ManifestIdentity -Paths $Paths -Active $true -Code $Code}
}

$manifestRead = Read-TelephoneJson -Path $ManifestFile -SchemaName 'control-plane-wave-manifest'
$manifest = $manifestRead.value
$stateResult = Update-TelephoneControlPlaneState -ManifestFile $ManifestFile
$paths = $stateResult.paths
if ([bool]$stateResult.inactive_wave) {
    [ordered]@{ applied = $false; inactive_wave = $true; project = [string]$manifest.project; eligible = @(); executed = @(); blocked = @(); current_state = $stateResult.current_identity; automatic_rerun = $false; project_judgment = $false } | ConvertTo-Json -Depth 24
    exit 0
}
[IO.Directory]::CreateDirectory([string]$paths.actions) | Out-Null
$controllerGate = Open-TelephoneExclusiveGate -Path ([string]$paths.controller_gate) -WaitMilliseconds 10000
if ($null -eq $controllerGate) { throw 'Continuity controller is already reconciling this project.' }
try {
    $eligible = [Collections.Generic.List[string]]::new(); $executed = [Collections.Generic.List[object]]::new(); $blocked = [Collections.Generic.List[object]]::new()
    foreach ($action in @($manifest.actions | Sort-Object { [int]$_.sequence })) {
        $contractStatus = Assert-ControllerActionContract -Action $action -Manifest $manifest
        $actionKey = Get-TelephoneControlPlaneSha256 -Text (([string]$manifestRead.identity.sha256) + '|' + [string]$action.idempotency_key)
        $triggered = Test-ControllerTrigger -Trigger $action.trigger -Current $stateResult.current
        if ($contractStatus -ceq 'CUSTOM_ACTION_NOT_AUTOMATIC') {
            if($triggered){Add-ControllerBlockedDecision -List $blocked -Action $action -Code 'CUSTOM_ACTION_NOT_AUTOMATIC' -ManifestIdentity $manifestRead.identity -Paths $paths -Persist ([bool]$Apply)}
            elseif($Apply){$null=Set-ControllerBlockedDecision -Action $action -ManifestIdentity $manifestRead.identity -Paths $paths -Active $false}
            continue
        }
        $dependenciesOk = $true
        foreach ($dependency in @($action.depends_on)) {
            $dep = @($manifest.actions | Where-Object { [string]$_.action_id -ceq [string]$dependency })
            if ($dep.Count -ne 1) { throw 'Action dependency is not in the same manifest.' }
            $depKey = Get-TelephoneControlPlaneSha256 -Text (([string]$manifestRead.identity.sha256) + '|' + [string]$dep[0].idempotency_key)
            $depRetryResult = Join-Path ([string]$paths.actions) ($depKey + '.retry1.result.json')
            $depBaseResult = Join-Path ([string]$paths.actions) ($depKey + '.result.json')
            $depRead = Test-ControllerExistingResult -Path $depRetryResult -Action $dep[0] -ManifestIdentity $manifestRead.identity
            if ($null -eq $depRead) { $depRead = Test-ControllerExistingResult -Path $depBaseResult -Action $dep[0] -ManifestIdentity $manifestRead.identity }
            if ($null -eq $depRead -or [string]$depRead.value.status -cne 'completed') { $dependenciesOk = $false; break }
        }
        if (-not $dependenciesOk) {
            if($triggered){Add-ControllerBlockedDecision -List $blocked -Action $action -Code 'ACTION_DEPENDENCY_PENDING' -ManifestIdentity $manifestRead.identity -Paths $paths -Persist ([bool]$Apply)}
            elseif($Apply){$null=Set-ControllerBlockedDecision -Action $action -ManifestIdentity $manifestRead.identity -Paths $paths -Active $false}
            continue
        }
        $intentPath = Join-Path ([string]$paths.actions) ($actionKey + '.intent.json'); $baseResultPath = Join-Path ([string]$paths.actions) ($actionKey + '.result.json'); $retryResultPath = Join-Path ([string]$paths.actions) ($actionKey + '.retry1.result.json'); $resultPath = $baseResultPath
        $ownerPath = Join-Path ([string]$paths.actions) ($actionKey + '.owner.json'); $retryPath = Join-Path ([string]$paths.actions) ($actionKey + '.retry.json')
        $retryCount = 0
        $existingRetry = Test-ControllerExistingResult -Path $retryResultPath -Action $action -ManifestIdentity $manifestRead.identity
        if ($null -ne $existingRetry) {
            if ([string]$existingRetry.value.status -ceq 'completed') { if($Apply){$null=Set-ControllerBlockedDecision -Action $action -ManifestIdentity $manifestRead.identity -Paths $paths -Active $false};continue }
            Add-ControllerBlockedDecision -List $blocked -Action $action -Code 'ACTION_RETRY_EXHAUSTED' -ManifestIdentity $manifestRead.identity -Paths $paths -Persist ([bool]$Apply);continue
        }
        $existingResult = Test-ControllerExistingResult -Path $baseResultPath -Action $action -ManifestIdentity $manifestRead.identity
        if ($null -ne $existingResult) {
            if ([string]$existingResult.value.status -ceq 'completed') { if($Apply){$null=Set-ControllerBlockedDecision -Action $action -ManifestIdentity $manifestRead.identity -Paths $paths -Active $false};continue }
            if ([string]$existingResult.value.status -ceq 'failed' -and [string]$action.contract.retry_policy -ceq 'safe_once_if_no_effect' -and [int]$existingResult.value.retry_count -lt 1) {
                $resultPath = $retryResultPath; $retryCount = 1
            } else { Add-ControllerBlockedDecision -List $blocked -Action $action -Code 'ACTION_FAILED_CONFLICT' -ManifestIdentity $manifestRead.identity -Paths $paths -Persist ([bool]$Apply);continue }
        }
        if (-not $triggered) { if($Apply){$null=Set-ControllerBlockedDecision -Action $action -ManifestIdentity $manifestRead.identity -Paths $paths -Active $false};continue }
        if ([string]$action.kind -ceq 'next_wave' -and (@($stateResult.current.lanes | Where-Object { [string]$_.state -cnotin @('delivered','handled') }).Count -gt 0)) { Add-ControllerBlockedDecision -List $blocked -Action $action -Code 'NEXT_WAVE_DENOMINATOR_NOT_SAFE' -ManifestIdentity $manifestRead.identity -Paths $paths -Persist ([bool]$Apply);continue }
        if ([string]$action.kind -ceq 'lane_recovery') {
            $targetRows = @($stateResult.current.lanes | Where-Object { [string]$_.package_id -ceq [string]$action.contract.target_package_id -and [string]$_.state -cin @('failed','unknown') })
            if ($targetRows.Count -ne 1) { Add-ControllerBlockedDecision -List $blocked -Action $action -Code 'LANE_RECOVERY_SCOPE_INVALID' -ManifestIdentity $manifestRead.identity -Paths $paths -Persist ([bool]$Apply);continue }
        }
        if($Apply){$null=Set-ControllerBlockedDecision -Action $action -ManifestIdentity $manifestRead.identity -Paths $paths -Active $false}
        [void]$eligible.Add([string]$action.action_id)
        if (-not $Apply) { continue }
        $recovered = $false; $intentRead = $null
        if ([IO.File]::Exists($intentPath)) {
            $intentRead = Read-TelephoneJson -Path $intentPath -SchemaName 'control-plane-action-intent'
            Assert-TelephoneFileIdentity -Expected $manifestRead.identity -Actual $intentRead.value.manifest -Label 'Action intent manifest'
            if ([string]$intentRead.value.contract_fingerprint -cne [string]$action.contract.contract_fingerprint -or [string]$intentRead.value.command_sha256 -cne [string]$action.contract.command_sha256) { throw 'Action intent identity drifted.' }
            if (Test-ControllerPostcondition -Postcondition $action.contract.expected_postcondition -Paths $paths) {
                $recoveredPreserved = [ordered]@{}
                if ([string]$action.kind -ceq 'lane_recovery') {
                    foreach ($lane in @($stateResult.current.lanes | Where-Object { [string]$_.package_id -cne [string]$action.contract.target_package_id })) { $recoveredPreserved[[string]$lane.package_id] = [string]$lane.evidence_fingerprint }
                    $null = Set-ControllerLaneAttempt -Action $action -Manifest $manifest -Paths $paths -IntentIdentity $intentRead.identity
                    $stateResult = Update-TelephoneControlPlaneState -ManifestFile $ManifestFile
                    foreach ($lane in @($stateResult.current.lanes | Where-Object { [string]$_.package_id -cne [string]$action.contract.target_package_id })) {
                        if ([string]$recoveredPreserved[[string]$lane.package_id] -cne [string]$lane.evidence_fingerprint) { throw 'Recovered lane action changed a non-target lane.' }
                    }
                }
                $stdoutIdentity = Write-ControllerOutputFile -Path (Join-Path ([string]$paths.actions) ($actionKey + '.recovered.stdout.txt')) -Text ''
                $stderrIdentity = Write-ControllerOutputFile -Path (Join-Path ([string]$paths.actions) ($actionKey + '.recovered.stderr.txt')) -Text ''
                $resultIdentity = Publish-ControllerResult -Action $action -ManifestIdentity $manifestRead.identity -IntentIdentity $intentRead.identity -StateBefore $intentRead.value.state_before -StateAfter $stateResult.current_identity -ExitCode 0 -Status 'completed' -StartedAt ([string]$intentRead.value.created_at_utc) -StdoutIdentity $stdoutIdentity -StderrIdentity $stderrIdentity -ResultPath $resultPath -Recovered $true -PreservedLaneFingerprints $recoveredPreserved
                [void]$executed.Add([ordered]@{ action_id = [string]$action.action_id; status = 'completed'; exit_code = 0; result = $resultIdentity; recovered_after_crash = $true })
                continue
            }
            $owner = if ([IO.File]::Exists($ownerPath)) { try { (Read-TelephoneJson -Path $ownerPath).value } catch { $null } } else { $null }
            if ($null -ne $owner -and (Test-TelephoneOwnerAlive -Owner $owner)) { Add-ControllerBlockedDecision -List $blocked -Action $action -Code 'ACTION_IN_PROGRESS' -ManifestIdentity $manifestRead.identity -Paths $paths -Persist ([bool]$Apply);continue }
            if ([string]$action.contract.retry_policy -cne 'safe_once_if_no_effect' -or [IO.File]::Exists($retryPath)) {
                Add-ControllerBlockedDecision -List $blocked -Action $action -Code 'ACTION_EFFECT_CONFLICT_REQUIRES_PASCAL' -ManifestIdentity $manifestRead.identity -Paths $paths -Persist ([bool]$Apply);continue
            }
            $retryRecord = [ordered]@{ protocol_version = 'telephone-line-control-plane-action-retry-v1'; action_id = [string]$action.action_id; intent = $intentRead.identity; reason = 'ZERO_POSTCONDITION_AND_NO_LIVE_OWNER'; retry_count = 1; created_at_utc = [DateTimeOffset]::UtcNow.ToString('o') }
            $null = Write-TelephoneJsonCreateNew -Path $retryPath -Value $retryRecord; $retryCount = 1
        } else {
            $startedAt = [DateTimeOffset]::UtcNow.ToString('o')
            $intent = [ordered]@{
                protocol_version = 'telephone-line-control-plane-action-intent-v1'; action_id = [string]$action.action_id; kind = [string]$action.kind; idempotency_key = [string]$action.idempotency_key
                manifest = $manifestRead.identity; contract_fingerprint = [string]$action.contract.contract_fingerprint; command_sha256 = [string]$action.contract.command_sha256
                state_before = $stateResult.current_identity; expected_postcondition = $action.contract.expected_postcondition; retry_policy = [string]$action.contract.retry_policy; created_at_utc = $startedAt
            }
            $intentText = ConvertTo-TelephoneControlPlaneJson -Value $intent; Assert-TelephoneJsonSchema -JsonText $intentText -SchemaName 'control-plane-action-intent' -Label 'control-plane action intent'
            $intentIdentity = Write-TelephoneJsonCreateNew -Path $intentPath -Value $intent; $intentRead = [ordered]@{ value = $intent; identity = $intentIdentity }
        }
        $nonTargetBefore = [ordered]@{}
        if ([string]$action.kind -ceq 'lane_recovery') { foreach ($lane in @($stateResult.current.lanes | Where-Object { [string]$_.package_id -cne [string]$action.contract.target_package_id })) { $nonTargetBefore[[string]$lane.package_id] = [string]$lane.evidence_fingerprint } }
        $runStarted = [DateTimeOffset]::UtcNow.ToString('o'); $run = $null
        try { $run = Invoke-ControllerCommand -Command $action.command -OwnerPath $ownerPath } catch { $run = [ordered]@{ exit_code = 1; stdout = ''; stderr = [string]$_.Exception.Message } }
        $stdoutIdentity = Write-ControllerOutputFile -Path (Join-Path ([string]$paths.actions) ($actionKey + '.' + $retryCount + '.stdout.txt')) -Text ([string]$run.stdout)
        $stderrIdentity = Write-ControllerOutputFile -Path (Join-Path ([string]$paths.actions) ($actionKey + '.' + $retryCount + '.stderr.txt')) -Text ([string]$run.stderr)
        $postconditionOk = ([string]$action.contract.expected_postcondition.kind -ceq 'exit_zero' -and [int]$run.exit_code -eq 0) -or (Test-ControllerPostcondition -Postcondition $action.contract.expected_postcondition -Paths $paths)
        $status = $(if ([int]$run.exit_code -eq 0 -and $postconditionOk) { 'completed' } else { 'failed' })
        if ($status -ceq 'completed' -and [string]$action.kind -ceq 'lane_recovery') { $null = Set-ControllerLaneAttempt -Action $action -Manifest $manifest -Paths $paths -IntentIdentity $intentRead.identity }
        $stateResult = Update-TelephoneControlPlaneState -ManifestFile $ManifestFile
        if ($status -ceq 'completed' -and [string]$action.kind -ceq 'lane_recovery') {
            foreach ($lane in @($stateResult.current.lanes | Where-Object { [string]$_.package_id -cne [string]$action.contract.target_package_id })) {
                if (-not $nonTargetBefore.Contains([string]$lane.package_id) -or [string]$nonTargetBefore[[string]$lane.package_id] -cne [string]$lane.evidence_fingerprint) { throw 'Lane recovery modified or relaunched a successful non-target lane.' }
            }
        }
        $resultIdentity = Publish-ControllerResult -Action $action -ManifestIdentity $manifestRead.identity -IntentIdentity $intentRead.identity -StateBefore $intentRead.value.state_before -StateAfter $stateResult.current_identity -ExitCode ([int]$run.exit_code) -Status $status -StartedAt $runStarted -StdoutIdentity $stdoutIdentity -StderrIdentity $stderrIdentity -ResultPath $resultPath -RetryCount $retryCount -PreservedLaneFingerprints $nonTargetBefore
        $stateResult = Update-TelephoneControlPlaneState -ManifestFile $ManifestFile
        [void]$executed.Add([ordered]@{ action_id = [string]$action.action_id; status = $status; exit_code = [int]$run.exit_code; result = $resultIdentity; retry_count = $retryCount })
        if ($status -cne 'completed') { break }
    }
    if($Apply){$stateResult=Update-TelephoneControlPlaneState -ManifestFile $ManifestFile}
    $unresolvedActions = @($stateResult.current.actions | Where-Object { [string]$_.state -cin @('retryable_failed','blocked','conflict','exhausted') })
    $nextCandidates = [Collections.Generic.List[DateTimeOffset]]::new()
    foreach ($lane in @($stateResult.current.lanes)) {
        try {
            $base = [DateTimeOffset]::Parse([string]$lane.last_evidence_at_utc).ToUniversalTime()
            if ([string]$lane.state -ceq 'starting') { [void]$nextCandidates.Add($base.AddSeconds([int]$lane.launch_grace_seconds + 1)) }
            elseif ([string]$lane.state -ceq 'receipt_ready') { [void]$nextCandidates.Add($base.AddSeconds([int]$lane.callback_grace_seconds + 1)) }
        } catch { }
    }
    if ($unresolvedActions.Count -gt 0) { [void]$nextCandidates.Add([DateTimeOffset]::UtcNow.AddSeconds(30)) }
    $nextReconcile = if ($nextCandidates.Count -gt 0) { @($nextCandidates | Sort-Object)[0].ToUniversalTime().ToString('o') } else { $null }
    [ordered]@{
        applied = [bool]$Apply; inactive_wave = $false; project = [string]$manifest.project; projection_version = [int]$stateResult.current.projection_version
        eligible = @($eligible.ToArray()); executed = @($executed.ToArray()); blocked = @($blocked.ToArray()); current_state = $stateResult.current_identity; continuation_capsule = $stateResult.capsule_identity
        healthy = ([string]$stateResult.current.projection_status -ceq 'healthy' -and $unresolvedActions.Count -eq 0); unresolved_action_count = $unresolvedActions.Count; next_reconcile_at_utc = $nextReconcile
        automatic_rerun = $false; controller_lock = $true; project_judgment = $false
    } | ConvertTo-Json -Depth 32
} finally { $controllerGate.Dispose() }
