# SPDX-License-Identifier: MPL-2.0
# Run the real starter and relay helpers. Breakpoints control only the ordering
# and observe actual process creation and the exact atomic publication target.
[CmdletBinding()]
param(
 [string]$SourceRoot = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))),
 [Parameter(Mandatory=$true)][string]$TestRoot,
 [ValidateSet('Recovery','PublicationFailure')][string]$Case = 'Recovery'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$source=[IO.Path]::GetFullPath($SourceRoot)
$base=[IO.Path]::GetFullPath($TestRoot)
if([IO.Directory]::Exists($base)){throw 'Use a fresh isolated test root'}
$null=[IO.Directory]::CreateDirectory($base)
$state=Join-Path $base 'state';$work=Join-Path $base 'work';$runs=Join-Path $base 'lead-runs'
foreach($dir in @($state,$work,$runs)){$null=[IO.Directory]::CreateDirectory($dir)}
$envNames=@('TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY','TELEPHONE_LINE_DASHBOARD_OPT_OUT','TELEPHONE_LINE_SUPERVISOR_RUN_ID','TELEPHONE_LINE_SUPERVISOR_STATE_ROOT','TELEPHONE_TEST_LEAD_LOG','TELEPHONE_TEST_LEAD_RUNS','TELEPHONE_TEST_LEAD_TURNS','TELEPHONE_TEST_LEAD_NATIVE_EVENTS','TELEPHONE_TEST_COLLECTOR_IDLE_MS','TELEPHONE_LINE_INSTALL_ROOT')
$saved=@{};foreach($n in $envNames){$saved[$n]=[Environment]::GetEnvironmentVariable($n,'Process')}
$env:TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY='1';$env:TELEPHONE_LINE_DASHBOARD_OPT_OUT='1'
$env:TELEPHONE_LINE_SUPERVISOR_RUN_ID='';$env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT=''
$env:TELEPHONE_LINE_INSTALL_ROOT=''
$env:TELEPHONE_TEST_LEAD_LOG=Join-Path $base 'lead-calls.jsonl';$env:TELEPHONE_TEST_LEAD_RUNS=$runs
$env:TELEPHONE_TEST_LEAD_TURNS=Join-Path $base 'lead-turns.jsonl';$env:TELEPHONE_TEST_LEAD_NATIVE_EVENTS=''
$env:TELEPHONE_TEST_COLLECTOR_IDLE_MS='100'
$common=Join-Path $source 'src/core/TelephoneLine.Common.ps1';$starter=Join-Path $source 'src/core/Start-TelephoneLineJob.ps1'
. $common
$job=[Guid]::NewGuid().ToString('D');$jobPath=Join-Path $state ('jobs/'+$job);$counter=Join-Path $base 'route-count.txt'
$request=@{protocol_version='telephone-line-dispatch-v1';line_job_id=$job;project='starter-recovery-concurrency';stage='ISOLATED_ACTUAL_STARTER';role='execution';route='mock-route';summary='Actual initial starter interleaved with exact relay restoration';lead=@{protocol_version='telephone-line-lead-binding-v1';session_id='isolated-starter-race-lead';worktree=$work;launcher=@{path=(Join-Path $source 'tests/core/fixtures/mock-lead-launcher.ps1');arguments=@()}};command=@{executable=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;working_directory=$base;arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $source 'tests/core/fixtures/mock-route.ps1'),'-CounterPath',$counter,'-DelayMilliseconds','1500')}}
$requestPath=Join-Path $base 'request.json'
$null=Write-TelephoneJsonCreateNew -Path $requestPath -Value $request
$global:StarterRaceProbe=@{source=$source;test_root=$base;job_root=$jobPath;case=$Case;restoration=$null;move_observations=[Collections.Generic.List[object]]::new();started=[Collections.Generic.List[object]]::new();interleave_count=0}
$breaks=[Collections.Generic.List[object]]::new()
$starterLines=[IO.File]::ReadAllLines($starter)
$interleaveLine=0
for($i=0;$i -lt $starterLines.Length;$i++){if($starterLines[$i].Contains("Write-TelephoneLifecycleStatus -Paths "+'$paths'+" -Phase 'dispatched'")){$interleaveLine=$i+1;break}}
if(-not $interleaveLine){throw 'Actual starter interleave location not found'}
$commonLines=[IO.File]::ReadAllLines($common)
$moveLine=0;$startLine=0
for($i=0;$i -lt $commonLines.Length;$i++){
 if(-not $moveLine -and $commonLines[$i].Contains('[IO.File]::Move($temporary, $full)')){$moveLine=$i+1}
 if($commonLines[$i].Contains('if ($null -eq $process) { throw "Failed to start telephone-line process:')){$startLine=$i+1}
}
if(-not $moveLine -or -not $startLine){throw 'Actual helper observation locations not found'}
$breaks.Add((Set-PSBreakpoint -Script $common -Line $moveLine -Action {
 if([string]$full -eq (Join-Path $global:StarterRaceProbe.job_root 'relay-owner.json')){
  if($global:StarterRaceProbe.case -eq 'PublicationFailure'){
   # A genuine non-cooperating writer must still make create-new fail. Do not
   # replace the product writer or swallow its actual filesystem exception.
   [IO.File]::WriteAllText([string]$full, '{}')
  }
  $global:StarterRaceProbe.move_observations.Add(@{target=[string]$full;exists_before_move=[IO.File]::Exists([string]$full);stack=@(Get-PSCallStack|ForEach-Object{$_.Position.Text})})
 }
}))
$breaks.Add((Set-PSBreakpoint -Script $common -Line $startLine -Action {
 if($null -ne $process){
  $global:StarterRaceProbe.started.Add(@{script=[string]$ScriptPath;pid=[int]$process.Id;start_time_utc_ticks=[int64]$process.StartTime.ToUniversalTime().Ticks})
 }
}))
$breaks.Add((Set-PSBreakpoint -Script $starter -Line $interleaveLine -Action {
 if($global:StarterRaceProbe.case -ne 'Recovery'){return}
 $global:StarterRaceProbe.interleave_count++
 $global:StarterRaceProbe.restoration=Restore-TelephoneExactJobRelay -JobRoot $global:StarterRaceProbe.job_root
 if($global:StarterRaceProbe.restoration.restored){
  $owner=$global:StarterRaceProbe.restoration.owner
  $global:StarterRaceProbe.started.Add(@{script=(Join-Path $global:StarterRaceProbe.source 'src/core/Invoke-TelephoneLineRelay.ps1');pid=[int]$owner.pid;start_time_utc_ticks=[int64]$owner.start_time_utc_ticks})
 }
}))
$result=@{protocol_version='telephone-actual-starter-race-probe-v1';case=$Case;source_identity=@{starter_sha256=(Get-FileHash -LiteralPath $starter).Hash.ToLowerInvariant();common_sha256=(Get-FileHash -LiteralPath $common).Hash.ToLowerInvariant()};starter_returned=$false;error=$null;cleanup_used=$false;transport_observed=$false}
try{
 try{$raw=& $starter -RequestFile $requestPath -StateRoot $state;$result.starter_returned=$true;$result.starter=($raw -join [Environment]::NewLine)|ConvertFrom-Json -AsHashtable}
 catch{$result.error=@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message;stack=$_.ScriptStackTrace;position=$_.InvocationInfo.PositionMessage}}
 foreach($bp in $breaks){Remove-PSBreakpoint -Breakpoint $bp}
 $breaks.Clear()
 $deadline=[DateTime]::UtcNow.AddSeconds(35)
 while([DateTime]::UtcNow -lt $deadline){
  if([IO.File]::Exists((Join-Path $jobPath 'delivery.json'))){$result.transport_observed=$true;break}
  Start-Sleep -Milliseconds 100
 }
 $result.trace=$global:StarterRaceProbe
 $result.route_count=if([IO.File]::Exists($counter)){@([IO.File]::ReadAllLines($counter)).Count}else{0}
 $result.lead_count=if([IO.File]::Exists($env:TELEPHONE_TEST_LEAD_LOG)){@([IO.File]::ReadAllLines($env:TELEPHONE_TEST_LEAD_LOG)).Count}else{0}
 $result.receipt=if([IO.File]::Exists((Join-Path $jobPath 'receipt.json'))){(Read-TelephoneJson -Path (Join-Path $jobPath 'receipt.json')).value}else{$null}
 $result.relay_launch_count=@($global:StarterRaceProbe.started|Where-Object {$_.script.EndsWith('Invoke-TelephoneLineRelay.ps1')}).Count
 $result.exact_collision_observed=(!$result.starter_returned -and @($global:StarterRaceProbe.move_observations|Where-Object exists_before_move).Count -gt 0 -and $result.error.stack.Contains('Start-TelephoneLineJob.ps1'))
 $singleDelivery=$result.relay_launch_count -eq 1 -and $result.route_count -eq 1 -and $result.lead_count -eq 1 -and $result.transport_observed -and $result.receipt.transport_complete
 $result.check_passed=if($Case -eq 'PublicationFailure'){
  $result.exact_collision_observed -and $singleDelivery
 }else{
  $result.starter_returned -and $result.starter.lead_should_exit_now -and $singleDelivery -and $global:StarterRaceProbe.interleave_count -eq 1 -and $global:StarterRaceProbe.restoration.restored
 }
}finally{
 foreach($bp in $breaks){Remove-PSBreakpoint -Breakpoint $bp}
 $deadline=[DateTime]::UtcNow.AddSeconds(5)
 do{
  $live=@($global:StarterRaceProbe.started|Where-Object {Test-TelephoneOwnerAlive -Owner $_})
  if(!$live.Count){break}
  Start-Sleep -Milliseconds 100
 }while([DateTime]::UtcNow -lt $deadline)
 foreach($owner in $live){
  if(Test-TelephoneOwnerAlive -Owner $owner){$proc=Get-Process -Id $owner.pid;try{$proc.Kill();$proc.WaitForExit(5000)|Out-Null;$result.cleanup_used=$true}finally{$proc.Dispose()}}
 }
 $result.tracked_alive_after=@($global:StarterRaceProbe.started|Where-Object {Test-TelephoneOwnerAlive -Owner $_}).Count
 $result.check_passed=$result.check_passed -and -not $result.cleanup_used -and $result.tracked_alive_after -eq 0
 foreach($n in $envNames){[Environment]::SetEnvironmentVariable($n,$saved[$n],'Process')}
 [IO.File]::WriteAllText((Join-Path $base 'RESULT.json'),($result|ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($false))
}
$result|Select-Object case,check_passed,starter_returned,exact_collision_observed,relay_launch_count,route_count,lead_count,transport_observed,cleanup_used,tracked_alive_after,error|ConvertTo-Json -Depth 4
if(-not $result.check_passed){exit 1}
