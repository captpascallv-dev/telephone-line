# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$SpecFile)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TelephoneControlPlane.Common.ps1')

$startSpec = (Read-TelephoneJson -Path $SpecFile -SchemaName 'control-plane-wave-spec').value
foreach ($requiredPathField in @('install_root','supervisor_state_root','dashboard_config_path')) {
    if (-not $startSpec.Contains($requiredPathField) -or [string]::IsNullOrWhiteSpace([string]$startSpec[$requiredPathField])) { throw ('Production wave start requires ' + $requiredPathField + '.') }
}
if (-not $startSpec.lead.Contains('owner_file') -or [string]::IsNullOrWhiteSpace([string]$startSpec.lead.owner_file)) { throw 'Production wave start requires the exact Lead owner_file.' }

function Invoke-TelephoneWaveStarter {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Command)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Assert-TelephoneRegularFilePath -Path ([string]$Command.executable) -Label 'Wave starter executable'
    $info.WorkingDirectory = Assert-TelephoneDirectoryPath -Path ([string]$Command.working_directory) -Label 'Wave starter working directory'
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($arg in @($Command.arguments)) { [void]$info.ArgumentList.Add([string]$arg) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync(); $process.WaitForExit()
        return [ordered]@{ exit_code = [int]$process.ExitCode; stdout = [string]$stdoutTask.GetAwaiter().GetResult(); stderr = [string]$stderrTask.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}

$built = ((& (Join-Path $PSScriptRoot 'New-TelephoneWaveManifest.ps1') -SpecFile $SpecFile -Activate | Out-String) | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String)
$manifestRead = Read-TelephoneJson -Path ([string]$built.manifest.path) -SchemaName 'control-plane-wave-manifest'
$manifest = $manifestRead.value
$paths = Get-TelephoneControlPlanePaths -ControlStateRoot ([string]$manifest.control_state_root) -Project ([string]$manifest.project) -ProjectEpoch ([string]$manifest.project_epoch) -WaveId ([string]$manifest.wave_id)
$gate = Open-TelephoneExclusiveGate -Path (([string]$paths.launch_intent) + '.lock') -WaitMilliseconds 10000
if ($null -eq $gate) { throw 'Wave launch is already owned.' }
try {
    $laneContracts = @($manifest.lanes | ForEach-Object {
        [ordered]@{
            package_id = [string]$_.package_id; line_job_id = [string]$_.line_job_id; route = [string]$_.route; request = $_.request
            workspace = [string]$_.workspace; write_lease_id = [string]$_.write_lease_id; starter_sha256 = Get-TelephoneControlPlaneJsonFingerprint -Value $_.starter_command
        }
    })
    $intent = [ordered]@{
        protocol_version = 'telephone-line-control-plane-wave-launch-intent-v1'; project = [string]$manifest.project; project_epoch = [string]$manifest.project_epoch; wave_id = [string]$manifest.wave_id
        batch_id = [string]$manifest.batch_id; batch_n = [int]$manifest.batch_n; manifest = $manifestRead.identity; lanes = $laneContracts; created_at_utc = [string]$manifest.generated_at_utc
    }
    $intentExpected = Get-TelephoneControlPlaneValueIdentity -Path ([string]$paths.launch_intent) -Value $intent
    if ([IO.File]::Exists([string]$paths.launch_intent)) {
        $actual = Get-TelephoneFileIdentity -Path ([string]$paths.launch_intent)
        if ([string]$actual.sha256 -cne [string]$intentExpected.sha256) { throw 'Wave launch intent identity drifted.' }
    } else { $null = Write-TelephoneJsonCreateNew -Path ([string]$paths.launch_intent) -Value $intent }
    $existing = $null; $existingByPackage = @{}
    if ([IO.File]::Exists([string]$paths.launch_result)) {
        $existing = Read-TelephoneJson -Path ([string]$paths.launch_result)
        if ([string]$existing.value.manifest.sha256 -cne [string]$manifestRead.identity.sha256 -or [int]$existing.value.batch_n -ne [int]$manifest.batch_n) { throw 'Wave launch result identity drifted.' }
        foreach ($row in @($existing.value.package_results)) { $existingByPackage[[string]$row.package_id] = $row }
        if (@($existing.value.package_results | Where-Object { -not [bool]$_.ok }).Count -eq 0) {
            [ordered]@{ launched = $false; replayed = $true; success = $true; manifest = $manifestRead.identity; launch_intent = Get-TelephoneFileIdentity -Path ([string]$paths.launch_intent); launch_result = $existing.identity; package_results = @($existing.value.package_results) } | ConvertTo-Json -Depth 32
            exit 0
        }
    }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($lane in @($manifest.lanes)) {
        $prior = if ($existingByPackage.ContainsKey([string]$lane.package_id)) { $existingByPackage[[string]$lane.package_id] } else { $null }
        if ($null -ne $prior -and [bool]$prior.ok) { $prior.replayed = $true; [void]$results.Add($prior); continue }
        $priorAttempt = 0; if ($null -ne $prior) { try { $priorAttempt = [int]$prior.attempt } catch { $priorAttempt = 1 } }
        $attempt = if ($null -eq $prior) { 1 } else { $priorAttempt + 1 }
        if ($attempt -gt 2) { [void]$results.Add($prior); continue }
        $jobRoot = Join-Path (Join-Path ([string]$lane.telephone_state_root) 'jobs') ([string]$lane.line_job_id)
        if ([IO.Directory]::Exists($jobRoot)) {
            $dispatchPath = Join-Path $jobRoot 'dispatch.json'
            $ok = $false
            if ([IO.File]::Exists($dispatchPath)) {
                try {
                    $dispatch = (Read-TelephoneJson -Path $dispatchPath -SchemaName 'dispatch').value
                    $ok = ([string]$dispatch.line_job_id -ceq [string]$lane.line_job_id -and [string]$dispatch.project -ceq [string]$manifest.project)
                } catch { $ok = $false }
            }
            [void]$results.Add([ordered]@{ package_id = [string]$lane.package_id; line_job_id = [string]$lane.line_job_id; ok = $ok; replayed = $ok; attempt = $attempt; exit_code = $(if ($ok) { 0 } else { 1 }); stdout = ''; stderr = $(if ($ok) { '' } else { 'Existing job root identity mismatch.' }) })
            continue
        }
        try {
            $run = Invoke-TelephoneWaveStarter -Command $lane.starter_command
            [void]$results.Add([ordered]@{ package_id = [string]$lane.package_id; line_job_id = [string]$lane.line_job_id; ok = ([int]$run.exit_code -eq 0); replayed = $false; attempt = $attempt; exit_code = [int]$run.exit_code; stdout = [string]$run.stdout; stderr = [string]$run.stderr })
        } catch {
            [void]$results.Add([ordered]@{ package_id = [string]$lane.package_id; line_job_id = [string]$lane.line_job_id; ok = $false; replayed = $false; attempt = $attempt; exit_code = 1; stdout = ''; stderr = [string]$_.Exception.Message })
        }
    }
    if ($results.Count -ne [int]$manifest.batch_n -or @($results.package_id | Sort-Object -Unique).Count -ne [int]$manifest.batch_n) { throw 'Wave launcher did not preserve the exact batch denominator.' }
    $launchResult = [ordered]@{
        protocol_version = 'telephone-line-control-plane-wave-launch-result-v1'; project = [string]$manifest.project; project_epoch = [string]$manifest.project_epoch; wave_id = [string]$manifest.wave_id
        batch_id = [string]$manifest.batch_id; batch_n = [int]$manifest.batch_n; manifest = $manifestRead.identity; launch_intent = Get-TelephoneFileIdentity -Path ([string]$paths.launch_intent)
        package_results = @($results.ToArray()); completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $launchIdentity = Write-TelephoneJsonReplace -Path ([string]$paths.launch_result) -Value $launchResult
    $state = Update-TelephoneControlPlaneState -ManifestFile ([string]$manifestRead.identity.path)
    $wake = Join-Path ([string]$manifest.install_root) 'src\control-plane\Invoke-TelephoneControlPlaneWake.ps1'
    if ([IO.File]::Exists($wake)) {
        $null = Start-TelephoneHiddenPowerShell -ScriptPath $wake -Arguments @('-SupervisorStateRoot',[string]$manifest.supervisor_state_root,'-InstallRoot',[string]$manifest.install_root)
    }
    $success = (@($results | Where-Object { -not [bool]$_.ok }).Count -eq 0)
    [ordered]@{ launched = $true; replayed = $false; success = $success; manifest = $manifestRead.identity; launch_intent = $launchResult.launch_intent; launch_result = $launchIdentity; current_state = $state.current_identity; package_results = @($results.ToArray()) } | ConvertTo-Json -Depth 32
    if (-not $success) { exit 1 }
} finally { $gate.Dispose() }
