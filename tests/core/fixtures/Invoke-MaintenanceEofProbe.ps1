# SPDX-License-Identifier: MPL-2.0
# Real OS/pipe probe; native event records are explicitly labelled fault injection.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ArtifactRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $repo 'src\core\TelephoneLine.Common.ps1')
$root=[IO.Path]::GetFullPath($ArtifactRoot)
[IO.Directory]::CreateDirectory($root)|Out-Null
$owned=[Collections.Generic.List[object]]::new()
function Assert-Eof([bool]$Ok,[string]$Message) { if(-not $Ok){throw $Message} }
function Json([string]$Path) { return ([IO.File]::ReadAllText($Path)|ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String) }
try {
    $session=[Guid]::NewGuid().ToString()
    $run='late-inherited-pipe'
    $state=Join-Path $root 'lead-state'
    $runRoot=Join-Path $state $run
    [IO.Directory]::CreateDirectory($runRoot)|Out-Null
    $py=(Get-Command python.exe -ErrorAction Stop).Source
    $childPath=Join-Path $root 'delayed_child.py'
    $parentPath=Join-Path $root 'parent.py'
    [IO.File]::WriteAllText($childPath, @'
import sys,time
time.sleep(6)
sys.stdout.write("LATE-STDOUT-" + "Q"*32768 + "\n")
sys.stdout.flush()
sys.stderr.write("LATE-STDERR-" + "R"*32768 + "\n")
sys.stderr.flush()
'@,[Text.UTF8Encoding]::new($false))
    $parentCode=@'
import sys,time,json,subprocess,pathlib
session,run,child,pidfile=sys.argv[1:]
for event in [
 {"type":"thread.started","thread_id":session},
 {"type":"turn.started","turn_id":"fault-injection","session_id":session,"run_id":run},
 {"type":"turn.completed","turn_id":"fault-injection","session_id":session,"run_id":run}]:
 print(json.dumps(event),flush=True)
time.sleep(2)
childproc=subprocess.Popen([sys.executable,child],close_fds=False)
pathlib.Path(pidfile).write_text(str(childproc.pid))
sys.exit(23)
'@
    [IO.File]::WriteAllText($parentPath,$parentCode,[Text.UTF8Encoding]::new($false))
    $events=Join-Path $runRoot 'codex-events.jsonl'
    $err=Join-Path $runRoot 'codex-stderr.txt'
    $pidfile=Join-Path $root 'child-pid.txt'
    $null=Write-TelephoneJsonCreateNew -Path (Join-Path $runRoot 'lead-run.json') -Value ([ordered]@{
        protocol_version='huhu-concerto-cli-lead-run-v1';run_id=$run;requested_run_id=$run;resume_session_id=$session;events_path=$events;worktree=$root
    })
    $captured=Invoke-TelephoneLeadDrainedProcess -FileName $py -Arguments @($parentPath,$session,$run,$childPath,$pidfile) -WorkingDirectory $root -StdoutPath $events -StderrPath $err -LifecyclePath (Join-Path $runRoot 'host-drain-lifecycle.json') -OwnerPath (Join-Path $runRoot 'owner.json') -EventsPath $events -SessionId $session -RunId $run -Role host -ReturnOnNativeComplete
    Assert-Eof ([bool]$captured.returned_on_native_complete -and -not [bool]$captured.process_exited) 'Did not retain the real open drain at injected native completion.'
    $parent=Get-Process -Id ([int]$captured.pid) -ErrorAction Stop
    $null=$parent.Handle
    [void]$owned.Add($parent)
    Assert-Eof ($parent.WaitForExit(5000)) 'Parent did not exit independently.'
    Assert-Eof ($parent.ExitCode -eq 23) 'Independent OS parent exit was not 23.'
    $child=Get-Process -Id ([int]([IO.File]::ReadAllText($pidfile))) -ErrorAction Stop
    [void]$owned.Add($child)
    $early=Complete-TelephoneLeadOpenDrain -ProcessId ([int]$captured.pid) -SessionId $session -RunId $run -WaitMilliseconds 50
    Assert-Eof ([bool]$early.process_exited -and [bool]$early.pending -and -not [bool]$early.stdout_eof -and -not [bool]$early.stderr_eof) 'Parent exit or reader closure was falsely reported as stream EOF.'
    $earlyHandoff=Json (Join-Path $runRoot 'host-drain-handoff.json')
    Assert-Eof ([bool]$earlyHandoff.pending -and -not [bool]$earlyHandoff.stdout_eof) 'Background completion falsely published EOF while inherited pipe was live.'
    Assert-Eof (-not $child.HasExited) 'Late writer was not alive during pending observation.'
    Assert-Eof ($child.WaitForExit(10000)) 'Late writer did not finish naturally.'
    $done=Complete-TelephoneLeadOpenDrain -ProcessId ([int]$captured.pid) -SessionId $session -RunId $run -WaitMilliseconds 2000
    Assert-Eof (-not [bool]$done.pending -and [bool]$done.stdout_eof -and [bool]$done.stderr_eof -and $done.exit_code -eq 23) 'Real EOF or observed exit was not retained.'
    Assert-Eof ([IO.File]::ReadAllText($events).Contains(('LATE-STDOUT-' + ('Q'*32768)))) 'Late stdout payload was truncated.'
    Assert-Eof ([IO.File]::ReadAllText($err).Contains(('LATE-STDERR-' + ('R'*32768)))) 'Late stderr payload was truncated.'
    $missing=Wait-TelephoneLeadOwnedDrainTerminal -RunRoot $runRoot -WaitMilliseconds 1
    Assert-Eof ([bool]$missing.pending -and [string]$missing.child_observation_status -ceq 'missing_unproven') 'Missing child identity was promoted to absence.'
    $handoff=Json (Join-Path $runRoot 'host-drain-handoff.json')
    $unknown=[ordered]@{}
    foreach($k in $handoff.Keys){$unknown[$k]=$handoff[$k]}
    $unknown['exit_code']=$null
    $unknown['exit_code_observed']=$false
    Assert-Eof (-not (Test-TelephoneLeadDurableDrainTerminal -Doc $unknown -SessionId $session -RunId $run)) 'Unknown exit was promoted to terminal.'
    $unknown.Remove('exit_code')
    $unknown.Remove('exit_code_observed')
    Assert-Eof (-not (Test-TelephoneLeadDurableDrainTerminal -Doc $unknown -SessionId $session -RunId $run)) 'A missing exit observation was promoted to terminal.'
    $result=[ordered]@{ok=$true;native_events='labelled fault injection';independent_parent_exit=$parent.ExitCode;early=$early;early_handoff=$earlyHandoff;late=$done;stdout_tail_chars=32768;stderr_tail_chars=32768;missing_child=$missing;unknown_exit_rejected=$true;shared_processes_targeted=$false}
    $result|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $root 'observations.json') -Encoding utf8
    Write-Output '{"ok":true,"late_pipe_eof":true,"missing_child_unknown":true}'
} catch {
    [ordered]@{ok=$false;error=$_.Exception.Message;position=$_.InvocationInfo.PositionMessage}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $root 'ERROR.json') -Encoding utf8
    throw
} finally {
    foreach($p in $owned){try{if(-not $p.HasExited){$p.Kill()};$p.Dispose()}catch{}}
}
