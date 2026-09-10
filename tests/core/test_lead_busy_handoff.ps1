# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$TestRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo 'src/core/TelephoneLine.Common.ps1')
$root=[IO.Path]::GetFullPath($TestRoot)
[IO.Directory]::CreateDirectory($root)|Out-Null
$worktree=Join-Path $root 'workspace';[IO.Directory]::CreateDirectory($worktree)|Out-Null
$runs=Join-Path $root 'runs';$prior=Join-Path $runs 'old-owning-turn';[IO.Directory]::CreateDirectory($prior)|Out-Null
$session='fixture-original-busy-lead'
$assertions=0
function Assert-Busy($condition,$message){$script:assertions++;if(-not $condition){throw $message}}
function Json-Busy($path,$value){[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 32),[Text.UTF8Encoding]::new($false))}
function New-HoldProcess($seconds){
 $pi=[Diagnostics.ProcessStartInfo]::new();$pi.FileName=[Environment]::ProcessPath;$pi.UseShellExecute=$false;$pi.CreateNoWindow=$true
 foreach($arg in @('-NoProfile','-NonInteractive','-Command',('Start-Sleep -Seconds '+$seconds))){$pi.ArgumentList.Add($arg)}
 return [Diagnostics.Process]::Start($pi)
}
$launcher=Join-Path $root 'busy-launcher.ps1'
$scriptText=@'
param([string]$WorktreePath,[string]$PromptFile,[string]$ResumeSessionId,[string]$RunId)
$ErrorActionPreference='Stop'
$prior=Join-Path $env:BUSY_TEST_RUNS 'old-owning-turn'
$owner=Get-Content -Raw -LiteralPath (Join-Path $prior 'owner.json')|ConvertFrom-Json
$process=Get-Process -Id $owner.pid -ErrorAction SilentlyContinue
$alive=$null -ne $process -and $process.StartTime.ToUniversalTime().Ticks -eq $owner.start_time_utc_ticks
[IO.File]::AppendAllText($env:BUSY_TEST_LAUNCH_CALLS,([DateTimeOffset]::UtcNow.ToString('o')+"`n"))
if($alive){throw "This isolated Wired Lead root already has an active run: $prior"}
if($env:BUSY_TEST_UNKNOWN -eq '1'){throw 'unrelated unknown launcher failure'}
$runRoot=Join-Path $env:BUSY_TEST_RUNS $RunId
[IO.Directory]::CreateDirectory($runRoot)|Out-Null
if([IO.File]::Exists((Join-Path $runRoot 'native-turn.txt'))){throw 'duplicate native turn'}
[IO.File]::WriteAllText((Join-Path $runRoot 'native-turn.txt'),$ResumeSessionId)
$ack=@{protocol_version='telephone-line-lead-wake-ack-v1';session_id=$ResumeSessionId;run_id=$RunId;wake_key='fixture-wake';event='turn.started';acknowledged_at_utc=[DateTimeOffset]::UtcNow.ToString('o')}
[IO.File]::WriteAllText((Join-Path $runRoot 'lead-wake-ack.json'),($ack|ConvertTo-Json))
@{state='completed';run_root=$runRoot;run_id=$RunId}|ConvertTo-Json -Compress
'@
[IO.File]::WriteAllText($launcher,$scriptText)
$env:BUSY_TEST_RUNS=$runs;$env:BUSY_TEST_LAUNCH_CALLS=Join-Path $root 'launch-calls.txt'
Json-Busy (Join-Path $prior 'lead-run.json') @{run_id='old-owning-turn';resume_session_id=$session;worktree=$worktree}
[IO.File]::WriteAllText((Join-Path $prior 'lead-final.txt'),'final exists while old owner is still alive')
$ownerProcess=New-HoldProcess 4
$childProcess=New-HoldProcess 6
try {
 $oldOwner=@{pid=$ownerProcess.Id;start_time_utc_ticks=$ownerProcess.StartTime.ToUniversalTime().Ticks}
 $oldChild=@{pid=$childProcess.Id;start_time_utc_ticks=$childProcess.StartTime.ToUniversalTime().Ticks}
 Json-Busy (Join-Path $prior 'owner.json') $oldOwner
 Json-Busy (Join-Path $prior 'cli-child.json') $oldChild
 $prompt=Join-Path $root 'wake-prompt.md';[IO.File]::WriteAllText($prompt,'fixture receipt callback; provider already finished')
 $runId='telephone-fixture-busy'
 $launch=Invoke-TelephoneFrozenLeadLauncher -LauncherPath $launcher -ExtraArguments @() -Worktree $worktree -PromptFile $prompt -SessionId $session -RunId $runId
 Assert-Busy (-not (Test-TelephoneOwnerAlive -Owner $oldOwner) -and -not (Test-TelephoneOwnerAlive -Owner $oldChild)) 'Continuation started while the old owner or CLI was alive.'
 Assert-Busy (@(Get-Content -LiteralPath $env:BUSY_TEST_LAUNCH_CALLS).Count -eq 2) 'Expected exactly one refused launch and one handoff launch.'
 Assert-Busy ([IO.File]::Exists((Join-Path $launch.run_root 'native-turn.txt'))) 'No exact callback turn was started.'
 $again=Invoke-TelephoneFrozenLeadLauncher -LauncherPath $launcher -ExtraArguments @() -Worktree $worktree -PromptFile $prompt -SessionId $session -RunId $runId
 Assert-Busy ($again.run_root -ceq $launch.run_root -and @(Get-Content -LiteralPath $env:BUSY_TEST_LAUNCH_CALLS).Count -eq 2) 'Recovered handoff launched again.'
 $paths=Get-TelephoneJobPaths -JobRoot (Join-Path $root 'completed-job');[IO.Directory]::CreateDirectory($paths.root)|Out-Null
 $dispatch=@{line_job_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'}
 $wake=@{wake_run_id=$runId;wake_key='fixture-wake'}
 Complete-TelephoneOwnerJobDelivery -JobPaths $paths -Dispatch $dispatch -Launch $launch -WakeIdentity $wake -LeadSessionId $session
 $delivery=(Read-TelephoneJson -Path $paths.delivery).value
 Assert-Busy ($delivery.automatic_callback_success -eq $true -and $delivery.lead_session_id -ceq $session) 'The actual delivery function did not close the handoff.'
 $env:BUSY_TEST_UNKNOWN='1'
 $errorText='';try{Invoke-TelephoneFrozenLeadLauncher -LauncherPath $launcher -ExtraArguments @() -Worktree $worktree -PromptFile $prompt -SessionId $session -RunId 'unknown-failure'|Out-Null}catch{$errorText=$_.Exception.Message}
 Assert-Busy ($errorText -ceq 'LEAD_WAKE_FAILED') ('Unknown failure was retried or misclassified: '+$errorText)
 Assert-Busy (-not [IO.File]::Exists((Join-Path $root 'prior-owner-handoff-unknown-failure.json'))) 'Unknown failure gained handoff authority.'
 $env:BUSY_TEST_UNKNOWN=''
 # A valid refusal for another Lead cannot authorize a retry for this Lead.
 $foreignOwner=New-HoldProcess 3
 try {
  Json-Busy (Join-Path $prior 'owner.json') @{pid=$foreignOwner.Id;start_time_utc_ticks=$foreignOwner.StartTime.ToUniversalTime().Ticks}
  $errorText='';try{Invoke-TelephoneFrozenLeadLauncher -LauncherPath $launcher -ExtraArguments @() -Worktree $worktree -PromptFile $prompt -SessionId 'foreign-lead' -RunId 'foreign-handoff'|Out-Null}catch{$errorText=$_.Exception.Message}
  Assert-Busy ($errorText -ceq 'LEAD_WAKE_FAILED') 'Foreign Lead busy refusal was treated as a supported handoff.'
  Assert-Busy (-not [IO.File]::Exists((Join-Path $root 'prior-owner-handoff-foreign-handoff.json'))) 'Foreign Lead received a handoff record.'
 } finally {$foreignOwner.Dispose()}
 @{success=$true;fixture_only=$true;assertions=$assertions;callback_turns=1;refused_launches=1;waited_for_owner_and_cli=$true;delivery_kind=$delivery.delivery_kind;real_sws_consumption_claimed=$false}|ConvertTo-Json
} finally {$ownerProcess.Dispose();$childProcess.Dispose()}
