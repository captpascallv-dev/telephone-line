# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$TestRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo 'src/adapters/direct-cursor/DirectCursor.Common.ps1')
. (Join-Path $repo 'tests/adapters/AdapterTest.Common.ps1')
$assertions=0
$root=[IO.Path]::GetFullPath($TestRoot)
[IO.Directory]::CreateDirectory($root)|Out-Null
function Write-TestJson($path,$value){ [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null; [IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 32),[Text.UTF8Encoding]::new($false)) }
function Reject-Test($call,$pattern){$errorText='';try{&$call|Out-Null}catch{$errorText=$_.Exception.Message};Assert-AdapterTest ($errorText -match $pattern) "Expected refusal $pattern, got $errorText"}
$workspace=Join-Path $root 'workspace'
$main=Join-Path $root 'main'
git init -q $main
git -C $main -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m fixture
git -C $main worktree add -q $workspace
if($LASTEXITCODE -ne 0){throw 'Fixture worktree setup failed.'}
[IO.File]::WriteAllText((Join-Path $workspace 'payload.txt'),'preserved partial')
$source=Join-Path $root 'archive'
$target=Join-Path $root 'new-state'
$native='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
$oldJob='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$job=[Guid]::NewGuid().ToString('D')
$metaPath=Join-Path $root ('native/'+$native+'/meta.json')
$transcriptPath=Join-Path $root ('native/'+$native+'/'+$native+'.jsonl')
Write-TestJson $metaPath @{cwd=$workspace;hasConversation=$true}
[IO.File]::WriteAllText($transcriptPath,'{"role":"assistant","message":{"content":[{"type":"tool_use"}]}}')
$admission=Join-Path $source ('partial-admissions/'+(Get-DirectTextSha256 -Text $native)+'/admission.json')
$registry=Join-Path $source 'cursor-sessions/sessions.json'
$requestPath=Join-Path $source ('jobs/'+$oldJob+'/request.json')
$ownerPath=Join-Path $source ('jobs/'+$oldJob+'/owner.json')
$a=@{protocol_version='telephone-line-direct-cursor-partial-admission-v1';native_session_id=$native;status='provisional';acceptance='pending';continuation_remaining=0;continuation_job_id=$oldJob;workspace=$workspace;mode='Write';model_id='cursor-grok-4.6-xhigh';allowed_write_paths=@('payload.txt');native_evidence=@{meta=@{path=$metaPath};transcript=@{path=$transcriptPath}}}
Write-TestJson $admission $a
Write-TestJson $registry @{sessions=@(@{session_id=$native;acceptance='pending';admission_kind='partial_observed';continuation_remaining=0})}
Write-TestJson $requestPath @{job_id=$oldJob;resume_session_id=$native;workspace=$workspace;mode='Write';model='cursor-grok-4.6-xhigh';allow_fast=$false;allowed_write_paths=@('payload.txt')}
Write-TestJson $ownerPath @{pid=999999;start_time_utc_ticks=1}
$leadPath=Join-Path $root 'lead.json'; Write-TestJson $leadPath @{session_id='fixture-original-lead'}
$journalPath=Join-Path $root 'stop.json'; Write-TestJson $journalPath @(@{pid=999999;expected_ticks=1;state='already_absent'})
$authorityPath=Join-Path $root 'authority.txt';[IO.File]::WriteAllText($authorityPath,'FAKE-SOURCE isolated migration test only')
$paths=@{admission=$admission;registry=$registry;interrupted_request=$requestPath;interrupted_owner=$ownerPath;transcript=$transcriptPath;meta=$metaPath;lead_binding=$leadPath;authority=$authorityPath;stop_journal=$journalPath}
$e=@{};foreach($key in $paths.Keys){$e[$key]=Get-DirectFileIdentity -Path $paths[$key]}
$proof=@{protocol_version='telephone-line-direct-cursor-migration-proof-v1';reason='authorized_installation_migration';service_tier='default';native_session_id=$native;lead_session_id='fixture-original-lead';job_id=$job;source_state_root=$source;target_state_root=$target;evidence=$e;dead_owners=@()}
$proofPath=Join-Path $root 'proof.json';Write-TestJson $proofPath $proof
$registered=Register-DirectCursorMigrationContinuation -ProofPath $proofPath
$argsCheck=@{GrantPath=$registered.grant.path;StateRoot=$target;NativeSessionId=$native;JobId=$job;WorkspacePath=$workspace;Mode='Write';AllowedWritePath=@('payload.txt')}
$null=Assert-DirectCursorMigrationContinuation @argsCheck
Assert-AdapterTest (-not [IO.File]::Exists((Join-Path $target ('sessions/'+$native+'/binding.json')))) 'Registration fabricated a successful binding.'
foreach($key in @('NativeSessionId','JobId','StateRoot','WorkspacePath','Mode','AllowedWritePath')){
    $bad=$argsCheck.Clone();$bad[$key]=switch($key){'StateRoot'{Join-Path $root 'elsewhere'} 'WorkspacePath'{Join-Path $root 'other-workspace'} 'AllowedWritePath'{@('other.txt')} default{'wrong'}}
    Reject-Test {Assert-DirectCursorMigrationContinuation @bad} 'mismatch'
}
$originalBytes=[IO.File]::ReadAllBytes($ownerPath)
$proofBytes=[IO.File]::ReadAllBytes($proofPath)
Write-TestJson $ownerPath @{pid=$PID;start_time_utc_ticks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks}
$proof.evidence.interrupted_owner=Get-DirectFileIdentity -Path $ownerPath;Write-TestJson $proofPath $proof
Reject-Test {Assert-DirectCursorMigrationProof -ProofPath $proofPath} 'still alive'
[IO.File]::WriteAllBytes($ownerPath,$originalBytes);[IO.File]::WriteAllBytes($proofPath,$proofBytes)
[IO.File]::AppendAllText($admission,' ')
Reject-Test {Assert-DirectCursorMigrationContinuation @argsCheck} 'identity changed'
[IO.File]::WriteAllBytes($admission,[Text.UTF8Encoding]::new($false).GetBytes(($a|ConvertTo-Json -Depth 32)))
# Drive the actual public adapter and host with an owned fake CLI executable.
$fake=Join-Path $root 'fake-cursor';$version=Join-Path $fake 'versions/test';[IO.Directory]::CreateDirectory($version)|Out-Null
$cs=@'
using System;
using System.IO;
public class Program {
 public static int Main(string[] args) {
  string cwd=Directory.GetCurrentDirectory(), session="";
  for(int i=0;i<args.Length;i++) {
   if(args[i]=="--version"){Console.WriteLine("1.0.0-test");return 0;}
   if(args[i]=="models"){Console.WriteLine("cursor-grok-4.6-xhigh - Cursor Grok 4.6 Extra High");return 0;}
   if(args[i]=="--workspace" && i+1<args.Length)cwd=args[i+1];
   if(args[i]=="--resume" && i+1<args.Length)session=args[i+1];
  }
  File.AppendAllText(Environment.GetEnvironmentVariable("MIGRATION_TEST_CALLS"),session+"\n");
  if(session!="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")return 42;
  string escaped=cwd.Replace("\\","\\\\").Replace("\"","\\\"");
  Console.WriteLine("{\"type\":\"system\",\"subtype\":\"init\",\"cwd\":\""+escaped+"\",\"session_id\":\""+session+"\",\"model\":\"Cursor Grok 4.6 Extra High\",\"apiKeySource\":\"login\"}");
  Console.WriteLine("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\""+session+"\",\"result\":\"fixture migration resumed\",\"usage\":{}}");
  return 0;
 }
}
'@
$csPath=Join-Path $root 'Fixture.cs';[IO.File]::WriteAllText($csPath,$cs)
& (Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe') /nologo /target:exe (('/out:')+(Join-Path $version 'node.exe')) $csPath
if($LASTEXITCODE -ne 0){throw 'Fixture compile failed.'}
[IO.File]::WriteAllText((Join-Path $version 'index.js'),'// fake')
[IO.File]::WriteAllText((Join-Path $fake 'cursor-agent.ps1'),'# fake')
$env:MIGRATION_TEST_CALLS=Join-Path $root 'cli-calls.txt'
$prompt=Join-Path $root 'prompt.txt';[IO.File]::WriteAllText($prompt,'Continue the preserved fixture only.')
$entry=Join-Path $repo 'src/adapters/direct-cursor/Invoke-DirectCursorRoute.ps1'
$routeArgs=@('-Operation','follow_up','-StateRoot',$target,'-WorkspacePath',$workspace,'-PromptFile',$prompt,'-Mode','Write','-AllowedWritePath','payload.txt','-NativeSessionId',$native,'-JobId',$job,'-MigrationGrantPath',$registered.grant.path,'-CursorAgentRoot',$fake)
$run=Invoke-AdapterEntrypoint -Entrypoint $entry -Arguments $routeArgs
Assert-AdapterTest ($run.exit_code -eq 0) ('Adapter migration failed: '+$run.stderr+' '+$run.stdout)
Assert-AdapterTest ([IO.File]::Exists((Join-Path $target ('jobs/'+$job+'/receipt.json')))) 'No durable receipt.'
Assert-AdapterTest ([IO.File]::Exists((Join-Path $target ('sessions/'+$native+'/binding.json')))) 'Actual successful continuation did not establish binding.'
$again=Invoke-AdapterEntrypoint -Entrypoint $entry -Arguments $routeArgs
Assert-AdapterTest ($again.exit_code -eq 0) ('Recorded job recovery failed: '+$again.stderr)
Assert-AdapterTest (@(Get-Content -LiteralPath $env:MIGRATION_TEST_CALLS).Count -eq 1) 'Recorded job reran the CLI.'
Reject-Test {Assert-DirectCursorMigrationContinuation @argsCheck -Consume} 'accepted binding|already been consumed'
Assert-DirectIdentity -Expected $e.admission -Actual (Get-DirectFileIdentity -Path $admission) -Label 'Archived admission after continuation'
Assert-DirectIdentity -Expected $e.registry -Actual (Get-DirectFileIdentity -Path $registry) -Label 'Archived registry after continuation'
@{success=$true;fixture_only=$true;assertions=$assertions;native_resumed=$native;provider_call_count=1;archived_counter=0;source_archive_unchanged=$true;actual_business_provider_test=$false}|ConvertTo-Json
