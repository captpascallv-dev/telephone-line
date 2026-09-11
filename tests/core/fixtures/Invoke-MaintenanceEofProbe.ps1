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
    $lifePath = Join-Path $runRoot 'host-drain-lifecycle.json'
    $captured=Invoke-TelephoneLeadDrainedProcess -FileName $py -Arguments @($parentPath,$session,$run,$childPath,$pidfile) -WorkingDirectory $root -StdoutPath $events -StderrPath $err -LifecyclePath $lifePath -OwnerPath (Join-Path $runRoot 'owner.json') -EventsPath $events -SessionId $session -RunId $run -Role host -ReturnOnNativeComplete
    if ($captured -is [Collections.IDictionary] -and (([bool]$captured.returned_on_native_complete) -or ([bool]$captured.drain_handoff_pending))) {
        Assert-Eof (-not [bool]$captured.process_exited) 'ReturnOnNativeComplete waited for OS exit instead of handing readers to OpenDrain.'
        $measured = Wait-TelephoneLeadOpenDrainUntilMeasured -ProcessId ([int]$captured.pid) -SessionId $session -RunId $run -LifecyclePath $lifePath
        Assert-Eof ($null -ne $measured -and [bool]$measured.process_exited -and [bool]$measured.stdout_eof -and [bool]$measured.stderr_eof) 'OpenDrain holder did not retain original readers until measured OS exit/EOF.'
        $captured.process_exited = [bool]$measured.process_exited
        $captured.stdout_eof = [bool]$measured.stdout_eof
        $captured.stderr_eof = [bool]$measured.stderr_eof
        if ($measured.Contains('exit_code') -and $null -ne $measured.exit_code) { $captured.exit_code = [int]$measured.exit_code }
    }
    Assert-Eof ([bool]$captured.process_exited) 'Drain host exited before original readers finished.'
    Assert-Eof ([bool]$captured.stdout_eof -and [bool]$captured.stderr_eof) 'Drain returned without both reader EOFs.'
    Assert-Eof ([int]$captured.exit_code -eq 23) 'Measured OS parent exit was not 23.'
    Assert-Eof ([IO.File]::ReadAllText($events).Contains(('LATE-STDOUT-' + ('Q'*32768)))) 'Late stdout payload was truncated.'
    Assert-Eof ([IO.File]::ReadAllText($err).Contains(('LATE-STDERR-' + ('R'*32768)))) 'Late stderr payload was truncated.'
    $lifeDoc = Json (Join-Path $runRoot 'host-drain-lifecycle.json')
    Assert-Eof ([bool]$lifeDoc.process_exited -and [bool]$lifeDoc.stdout_eof -and [bool]$lifeDoc.stderr_eof) 'Lifecycle file was not a measured terminal.'
    $pendingOverwrite = [ordered]@{
        protocol_version='telephone-line-drained-process-v1'
        pid=[int]$captured.pid
        start_time_utc_ticks=[int64]$captured.start_time_utc_ticks
        started_at_utc=[string]$captured.started_at_utc
        executable_path=[string]$captured.executable_path
        process_exited=$false
        stdout_eof=$false
        stderr_eof=$false
        timed_out=$false
        native_turn_complete=$true
        recorded_at_utc=[DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-TelephoneLeadDrainLifecycleFile -Path (Join-Path $runRoot 'host-drain-lifecycle.json') -Identity $pendingOverwrite -ProcessExited $false -StdoutEof $false -StderrEof $false -NativeTurnComplete $true -Role host -SessionId $session -RunId $run
    $afterOverwrite = Json (Join-Path $runRoot 'host-drain-lifecycle.json')
    Assert-Eof ([bool]$afterOverwrite.process_exited -and [bool]$afterOverwrite.stdout_eof -and [bool]$afterOverwrite.stderr_eof) 'A later pending snapshot overwrote a measured terminal.'
    $unknown=[ordered]@{}
    foreach($k in $lifeDoc.Keys){$unknown[$k]=$lifeDoc[$k]}
    $unknown['exit_code']=$null
    $unknown['exit_code_observed']=$false
    Assert-Eof (-not (Test-TelephoneLeadDurableDrainTerminal -Doc $unknown -SessionId $session -RunId $run)) 'Unknown exit was promoted to terminal.'
    $unknown.Remove('exit_code')
    $unknown.Remove('exit_code_observed')
    Assert-Eof (-not (Test-TelephoneLeadDurableDrainTerminal -Doc $unknown -SessionId $session -RunId $run)) 'A missing exit observation was promoted to terminal.'
    $result=[ordered]@{ok=$true;native_events='labelled fault injection';independent_parent_exit=[int]$captured.exit_code;stdout_eof=[bool]$captured.stdout_eof;stderr_eof=[bool]$captured.stderr_eof;stdout_tail_chars=32768;stderr_tail_chars=32768;measured_terminal=$true;pending_overwrite_rejected=$true;unknown_exit_rejected=$true;shared_processes_targeted=$false}
    $result|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $root 'observations.json') -Encoding utf8
    Write-Output '{"ok":true,"late_pipe_eof":true,"measured_terminal":true}'
} catch {
    [ordered]@{ok=$false;error=$_.Exception.Message;position=$_.InvocationInfo.PositionMessage}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $root 'ERROR.json') -Encoding utf8
    throw
} finally {
    foreach($p in $owned){try{if(-not $p.HasExited){$p.Kill()};$p.Dispose()}catch{}}
}
