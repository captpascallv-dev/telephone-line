# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string]$SourceRoot = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))),
    [string]$PublicCandidateRoot = '',
    [string]$InstalledRoot = '',
    [string]$SupervisorStateRoot = '',
    [string]$PerformanceEvidencePath = '',
    [string]$FailureMatrixEvidencePath = '',
    [string]$ReleaseGatesEvidencePath = '',
    [switch]$SkipOfflineTests,
    [string]$ResultPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
. (Join-Path $root 'src\core\TelephoneLine.Common.ps1')
. (Join-Path $root 'src\control-plane\TelephoneControlPlane.Common.ps1')

function Test-ReadinessIdentity {
    param([object]$Identity)
    try { $actual = Get-TelephoneFileIdentity -Path ([string]$Identity.path); Assert-TelephoneFileIdentity -Expected $Identity -Actual $actual -Label 'Release evidence'; return $true } catch { return $false }
}

function Read-ReadinessTypedEvidence {
    param([object]$Identity,[string]$Protocol)
    if (-not (Test-ReadinessIdentity $Identity)) { return $null }
    try { $read=Read-TelephoneJson -Path ([string]$Identity.path);if([string]$read.value.protocol_version-cne$Protocol){return $null};return $read.value } catch { return $null }
}

function Get-ReadinessPercentile {
    param([double[]]$Values, [double]$Percentile)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return -1 }
    $rank = [math]::Ceiling(($Percentile / 100.0) * $sorted.Count) - 1
    if ($rank -lt 0) { $rank = 0 }; if ($rank -ge $sorted.Count) { $rank = $sorted.Count - 1 }
    return [double]$sorted[$rank]
}

$checks = [ordered]@{}; $findings = [Collections.Generic.List[string]]::new()
$head = ((& git -C $root rev-parse HEAD) -join '').Trim(); $tree = ((& git -C $root rev-parse 'HEAD^{tree}') -join '').Trim(); $status = @(& git -C $root status --short)
$checks.source_clean = ($status.Count -eq 0); if (-not $checks.source_clean) { [void]$findings.Add('SOURCE_NOT_CLEAN') }
$catalog = Get-Content -Raw -LiteralPath (Join-Path $root 'src\catalog\routes.json') | ConvertFrom-Json -Depth 32
$routeCount = @($catalog.routes).Count; $checks.route_denominator_eight = ($routeCount -eq 8); if (-not $checks.route_denominator_eight) { [void]$findings.Add('ROUTE_DENOMINATOR_DRIFT') }

$parseErrors = [Collections.Generic.List[string]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Filter '*.ps1')) { $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors);if($errors.Count-gt 0){[void]$parseErrors.Add($file.FullName.Substring($root.Length+1))} }
$checks.powershell_parse = ($parseErrors.Count -eq 0); if (-not $checks.powershell_parse) { [void]$findings.Add('POWERSHELL_PARSE_FAILED') }
$jsonErrors = [Collections.Generic.List[string]]::new()
foreach ($file in @((Get-ChildItem -LiteralPath (Join-Path $root 'schemas') -File -Filter '*.json')) + @(Get-Item -LiteralPath (Join-Path $root 'release-manifest.json'))) { try{$null=Get-Content -Raw -LiteralPath $file.FullName|ConvertFrom-Json -Depth 64}catch{[void]$jsonErrors.Add($file.FullName.Substring($root.Length+1))} }
$checks.json_parse = ($jsonErrors.Count -eq 0); if (-not $checks.json_parse) { [void]$findings.Add('JSON_PARSE_FAILED') }
$controlPlane = Get-TelephoneControlPlaneDoctorReport -ProductRoot $root -SupervisorStateRoot $SupervisorStateRoot
$checks.control_plane_bundled = ([bool]$controlPlane.bundled_present -and [bool]$controlPlane.schemas_valid -and [bool]$controlPlane.powershell_parse_valid -and [bool]$controlPlane.controller_is_authority_bounded)
if (-not $checks.control_plane_bundled) { [void]$findings.Add('CONTROL_PLANE_CONSUMER_PATH_INCOMPLETE') }
$controlRunner=Get-TelephoneFileIdentity -Path (Join-Path $root 'tests\control-plane\test_control_plane.ps1')
$supervisorRunner=Get-TelephoneFileIdentity -Path (Join-Path $root 'tests\supervisor\test_wired_supervisor.ps1')
$appServerRunner=Get-TelephoneFileIdentity -Path (Join-Path $root 'tests\lead-side\codex-app-server\test_codex_app_server_lead.ps1')
$installRunner=Get-TelephoneFileIdentity -Path (Join-Path $root 'tests\install\test_install_lifecycle.ps1')
$offlineRunner=Get-TelephoneFileIdentity -Path (Join-Path $root 'tests\Invoke-OfflineTests.ps1')

$privacyRoot = $root
if (-not [string]::IsNullOrWhiteSpace($PublicCandidateRoot) -and [IO.Directory]::Exists($PublicCandidateRoot)) { $privacyRoot = [IO.Path]::GetFullPath($PublicCandidateRoot).TrimEnd('\') }
$manifestPath = Join-Path $privacyRoot 'release-manifest.json'; $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -Depth 64
$allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); [void]$allowed.Add('release-manifest.json')
$identityErrors = [Collections.Generic.List[string]]::new()
foreach ($entry in @($manifest.files)) {
    $relative = ([string]$entry.path).Replace('\','/'); [void]$allowed.Add($relative)
    $path = Join-Path $privacyRoot $relative.Replace('/','\')
    if (-not [IO.File]::Exists($path)) { [void]$identityErrors.Add($relative); continue }
    $id = Get-TelephoneFileIdentity -Path $path
    if ([int64]$entry.bytes -ne [int64]$id.bytes -or [string]$entry.sha256 -cne [string]$id.sha256) { [void]$identityErrors.Add($relative) }
}
$actual = [Collections.Generic.List[string]]::new()
foreach ($file in Get-ChildItem -LiteralPath $privacyRoot -Recurse -File -Force) {
    if ($file.FullName.Substring($privacyRoot.Length+1) -match '(^|\\)\.git(\\|$)') { continue }
    [void]$actual.Add($file.FullName.Substring($privacyRoot.Length+1).Replace('\','/'))
}
$extraFiles = @($actual | Where-Object { -not $allowed.Contains([string]$_) } | Sort-Object)
$checks.public_allowlist_exact = ($identityErrors.Count -eq 0 -and $extraFiles.Count -eq 0)
if (-not $checks.public_allowlist_exact) { [void]$findings.Add('PUBLIC_CANDIDATE_ALLOWLIST_OR_IDENTITY_FAILED') }
$forbiddenNeedles = @(('Con'+'certo'),'C:\Users\'+('Pas'+'cal'),'BEGIN PRIVATE KEY','BEGIN RSA PRIVATE KEY','BEGIN OPENSSH PRIVATE KEY','"access_token"','"refresh_token"')
$privacyHits = [Collections.Generic.List[string]]::new()
foreach ($relative in $actual) {
    $path = Join-Path $privacyRoot $relative.Replace('/','\')
    $bytes = [IO.File]::ReadAllBytes($path); $text = [Text.Encoding]::UTF8.GetString($bytes)
    foreach ($needle in $forbiddenNeedles) { if ($text.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase)-ge 0) { [void]$privacyHits.Add($relative); break } }
}
$checks.redistribution_privacy = ($privacyHits.Count -eq 0); if (-not $checks.redistribution_privacy) { [void]$findings.Add('REDISTRIBUTION_PRIVACY_FAILED') }

$candidate = [ordered]@{ configured=$false;exists=$false;git_present=$false;head='';untracked_files=0;remote_count=0;clean=$false;extra_files=$extraFiles;identity_errors=@($identityErrors) }
if (-not [string]::IsNullOrWhiteSpace($PublicCandidateRoot)) {
    $public=[IO.Path]::GetFullPath($PublicCandidateRoot).TrimEnd('\');$candidate.configured=$true;$candidate.exists=[IO.Directory]::Exists($public)
    if($candidate.exists){$candidate.git_present=Test-Path -LiteralPath (Join-Path $public '.git');if($candidate.git_present){$candidate.head=((& git -C $public rev-parse HEAD)-join'').Trim();$candidate.untracked_files=@(& git -C $public ls-files --others --exclude-standard).Count;$candidate.remote_count=@(& git -C $public remote).Count;$candidate.clean=@(& git -C $public status --short).Count-eq 0}}
}
$checks.single_public_candidate=(-not$candidate.configured-or($candidate.exists-and$candidate.git_present-and[int]$candidate.remote_count-eq 0));if(-not$checks.single_public_candidate){[void]$findings.Add('PUBLIC_CANDIDATE_IDENTITY_FAILED')}
$checks.public_candidate_clean=(-not$candidate.configured-or[bool]$candidate.clean);if(-not$checks.public_candidate_clean){[void]$findings.Add('PUBLIC_CANDIDATE_NOT_CLEAN')}

$installed = [ordered]@{ configured=$false;pointer_present=$false;source_sha256='';identity_ok=$false }
if(-not[string]::IsNullOrWhiteSpace($InstalledRoot)){$installed.configured=$true;$pointerPath=Join-Path([IO.Path]::GetFullPath($InstalledRoot).TrimEnd('\'))'current.json';if([IO.File]::Exists($pointerPath)){try{$pointer=(Read-TelephoneJson -Path $pointerPath).value;$installed.pointer_present=$true;$installed.source_sha256=[string]$pointer.source_sha256;$installed.identity_ok=([string]$pointer.source_sha256-cmatch'^[0-9a-f]{64}$')}catch{}}}

$performance=[ordered]@{present=$false;identity_bound=$false;sample_count=0;p50_ms=-1;p95_ms=-1;within_gate=$false;evidence_files_valid=$false}
if(-not[string]::IsNullOrWhiteSpace($PerformanceEvidencePath)-and[IO.File]::Exists($PerformanceEvidencePath)){try{$read=Read-TelephoneJson -Path $PerformanceEvidencePath -SchemaName 'control-plane-performance-evidence';$perf=$read.value;$samples=[double[]]@($perf.samples_ms);$performance.present=$true;$performance.sample_count=$samples.Count;$performance.p50_ms=Get-ReadinessPercentile -Values $samples -Percentile 50;$performance.p95_ms=Get-ReadinessPercentile -Values $samples -Percentile 95;$raw=Read-ReadinessTypedEvidence -Identity $perf.raw_log -Protocol 'telephone-line-control-plane-test-result-v2';$runnerOk=(Test-ReadinessIdentity $perf.runner)-and[string]$perf.runner.sha256-ceq[string]$controlRunner.sha256-and[string]$perf.command_sha256-ceq(Get-TelephoneControlPlaneSha256 -Text ([string]$controlRunner.sha256+'|-TestRoot'));$performance.evidence_files_valid=($null-ne$raw-and[bool]$raw.success-and[bool]$raw.zero_residue-and@($perf.evidence_files|Where-Object{-not(Test-ReadinessIdentity $_)}).Count-eq 0);$performance.identity_bound=($runnerOk-and[int]$perf.exit_code-eq0-and[bool]$perf.zero_residue-and[string]$perf.source_head-ceq$head-and[string]$perf.source_tree-ceq$tree-and[bool]$installed.identity_ok-and[string]$perf.installed_source_sha256-ceq[string]$installed.source_sha256);$performance.within_gate=($performance.identity_bound-and$performance.evidence_files_valid-and$performance.sample_count-ge20-and$performance.p50_ms-lt120000-and$performance.p95_ms-lt300000)}catch{}}
$checks.cold_start_performance=[bool]$performance.within_gate;if(-not$checks.cold_start_performance){[void]$findings.Add('PERFORMANCE_RAW_EVIDENCE_MISSING_OR_FAILED')}

$failureMatrix=[ordered]@{present=$false;identity_bound=$false;positions=@();successful_lanes_preserved=$false;no_successful_lane_rerun=$false;evidence_files_valid=$false;complete=$false}
if (-not [string]::IsNullOrWhiteSpace($FailureMatrixEvidencePath) -and [IO.File]::Exists($FailureMatrixEvidencePath)) {
    try {
        $read = Read-TelephoneJson -Path $FailureMatrixEvidencePath -SchemaName 'control-plane-failure-matrix-evidence'
        $matrix = $read.value
        $failureMatrix.present = $true
        $matrixRaw=Read-ReadinessTypedEvidence -Identity $matrix.raw_log -Protocol 'telephone-line-control-plane-test-result-v2';$matrixRunnerOk=(Test-ReadinessIdentity $matrix.runner)-and[string]$matrix.runner.sha256-ceq[string]$controlRunner.sha256-and[string]$matrix.command_sha256-ceq(Get-TelephoneControlPlaneSha256 -Text ([string]$controlRunner.sha256+'|-TestRoot'))
        $failureMatrix.identity_bound = ($matrixRunnerOk -and $null-ne$matrixRaw -and [bool]$matrixRaw.success -and [bool]$matrixRaw.zero_residue -and [int]$matrix.exit_code -eq 0 -and [bool]$matrix.zero_residue -and [string]$matrix.source_head -ceq $head -and [string]$matrix.source_tree -ceq $tree -and [bool]$installed.identity_ok -and [string]$matrix.installed_source_sha256 -ceq [string]$installed.source_sha256)
        $positions = @($matrix.cases.position | Sort-Object -Unique)
        $failureMatrix.positions = $positions
        $preserved = $true; $noRerun = $true; $files = $true
        foreach ($case in @($matrix.cases)) {
            if ((Get-TelephoneControlPlaneJsonFingerprint -Value $case.successful_before) -cne (Get-TelephoneControlPlaneJsonFingerprint -Value $case.successful_after)) { $preserved = $false }
            foreach ($id in @($case.relaunched_package_ids)) { if ([string]$id -cne [string]$case.target_package_id) { $noRerun = $false } }
            if (@($case.evidence_files | Where-Object { -not (Test-ReadinessIdentity $_) }).Count -gt 0) { $files = $false }
        }
        $failureMatrix.successful_lanes_preserved = $preserved; $failureMatrix.no_successful_lane_rerun = $noRerun; $failureMatrix.evidence_files_valid = $files
        $failureMatrix.complete = ($failureMatrix.identity_bound -and $files -and $preserved -and $noRerun -and @('before_session','after_prompt','after_result' | Where-Object { $positions -notcontains $_ }).Count -eq 0)
    } catch { }
}
$checks.three_point_lane_failure_matrix=[bool]$failureMatrix.complete;if(-not$checks.three_point_lane_failure_matrix){[void]$findings.Add('FAILURE_MATRIX_RAW_EVIDENCE_MISSING_OR_FAILED')}

$releaseGates=[ordered]@{present=$false;identity_bound=$false;complete=$false;failed=@()}
if (-not [string]::IsNullOrWhiteSpace($ReleaseGatesEvidencePath) -and [IO.File]::Exists($ReleaseGatesEvidencePath)) {
    try {
        $read = Read-TelephoneJson -Path $ReleaseGatesEvidencePath -SchemaName 'control-plane-release-gates-evidence'; $e = $read.value; $releaseGates.present = $true
        $releaseGates.identity_bound = ((Test-ReadinessIdentity $e.runner) -and [string]$e.runner.sha256 -ceq [string]$offlineRunner.sha256 -and [string]$e.command_sha256 -ceq (Get-TelephoneControlPlaneSha256 -Text ([string]$offlineRunner.sha256+'|offline')) -and [int]$e.exit_code -eq 0 -and [bool]$e.zero_residue -and [string]$e.source_head -ceq $head -and [string]$e.source_tree -ceq $tree -and [bool]$installed.identity_ok -and [string]$e.installed_source_sha256 -ceq [string]$installed.source_sha256)
        $failed = [Collections.Generic.List[string]]::new()
        $expectedRunners=@{automatic_next_wave=$controlRunner;lead_recovery=$controlRunner;restart_reconstruction=$controlRunner;wired=$supervisorRunner;wireless=$appServerRunner;mixed=$controlRunner;cancel_stop=$supervisorRunner;update_uninstall=$installRunner}
        $gatesRaw=Read-ReadinessTypedEvidence -Identity $e.raw_log -Protocol 'telephone-line-control-plane-release-gates-raw-v1'
        foreach ($name in @('automatic_next_wave','lead_recovery','restart_reconstruction','wired','wireless','mixed','cancel_stop','update_uninstall')) {
            $row = $e.gates[$name]
            $artifact=Read-ReadinessTypedEvidence -Identity $row.artifact -Protocol 'telephone-line-control-plane-release-gate-result-v1';$runnerOk=(Test-ReadinessIdentity $row.runner)-and[string]$row.runner.sha256-ceq[string]$expectedRunners[$name].sha256
            if (-not [bool]$row.success -or -not $runnerOk -or $null-eq$artifact -or [string]$artifact.gate_name-cne$name -or -not[bool]$artifact.success -or -not[bool]$artifact.zero_residue -or [string]$artifact.source_head-cne$head -or [string]$artifact.source_tree-cne$tree) { [void]$failed.Add($name) }
        }
        $releaseGates.failed = @($failed); $releaseGates.complete = ($releaseGates.identity_bound -and $null-ne$gatesRaw -and [bool]$gatesRaw.zero_residue -and $failed.Count -eq 0)
    } catch { }
}
$checks.eight_release_gates=[bool]$releaseGates.complete;if(-not$checks.eight_release_gates){[void]$findings.Add('EIGHT_RELEASE_GATES_EVIDENCE_MISSING_OR_FAILED')}

$offline=[ordered]@{ran=$false;success=$false;exit_code=-1;assertions=0;residue=$true}
if (-not $SkipOfflineTests) {
    $pwsh = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName); $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh; $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'tests\Invoke-OfflineTests.ps1'))) { [void]$info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync(); $process.WaitForExit(); $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
        $offline.ran = $true; $offline.exit_code = [int]$process.ExitCode
        if ($process.ExitCode -eq 0) { $parsed = $stdout | ConvertFrom-Json -Depth 64; $offline.success = [bool]$parsed.success; $offline.residue = [bool]$parsed.residue; if ($null -ne $parsed.PSObject.Properties['assertions']) { $offline.assertions = [int]$parsed.assertions } }
        if ($process.ExitCode -ne 0 -or -not $offline.success -or $offline.residue) { [void]$findings.Add('OFFLINE_TESTS_FAILED') }
    } finally { $process.Dispose() }
} else { [void]$findings.Add('OFFLINE_TESTS_NOT_RUN') }
$checks.offline_tests=([bool]$offline.ran-and[bool]$offline.success-and-not[bool]$offline.residue);$checks.shared_host_destructive_test_not_automatic=$true
$success=@($checks.Values|Where-Object{$_-ne$true}).Count-eq0
$result=[ordered]@{protocol_version='telephone-line-open-source-readiness-result-v1';success=[bool]$success;terminal=$(if($success){'READY_FOR_PASCAL_README_REVIEW'}else{'OPEN_SOURCE_CONTROL_PLANE_NOT_READY'});source=[ordered]@{root=$root;head=$head;tree=$tree;clean=[bool]$checks.source_clean};route_count=$routeCount;checks=$checks;findings=@($findings);parse_errors=@($parseErrors);json_errors=@($jsonErrors);privacy_hits=@($privacyHits);extra_files=$extraFiles;identity_errors=@($identityErrors);control_plane=$controlPlane;public_candidate=$candidate;installed=$installed;performance=$performance;failure_matrix=$failureMatrix;release_gates=$releaseGates;offline_tests=$offline;install_performed=$false;public_candidate_synced=$false;public_action=$false;completed_at_utc=[DateTimeOffset]::UtcNow.ToString('o')}
if(-not[string]::IsNullOrWhiteSpace($ResultPath)){$null=Write-TelephoneJsonReplace -Path $ResultPath -Value $result}
$result | ConvertTo-Json -Depth 40
if(-not$success){exit 1}
