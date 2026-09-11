# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$TestRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repo 'src\supervisor\TelephoneSupervisor.Common.ps1')
$root=[IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
if(Test-Path -LiteralPath $root){throw 'Use a new isolated fixture root.'}
[IO.Directory]::CreateDirectory($root)|Out-Null
$install=Join-Path $root 'install'
$dir=Join-Path $install 'src\supervisor'
[IO.Directory]::CreateDirectory($dir)|Out-Null
$target=Join-Path $dir 'Start-TelephoneSupervisorHostVisible.ps1'
$invoke=Join-Path $dir 'Invoke-TelephoneSupervisor.ps1'
[IO.File]::WriteAllText($target,'# fixture only')
[IO.File]::WriteAllText($invoke,'# fixture only')
$wrapper=Join-Path $root 'FixtureWrapper.exe'
$source=Join-Path $root 'FixtureWrapper.cs'
$code='public static class FixtureWrapper { public static int Main() { string target=@"'+$target.Replace('"','""')+'"; return target.Length==0 ? 1 : 0; } }'
[IO.File]::WriteAllText($source,$code)
$resource=Join-Path $root 'compiled-target.txt'
[IO.File]::WriteAllText($resource,$target,[Text.UTF8Encoding]::new($false))
$csc=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /target:winexe ('/out:'+$wrapper) ('/resource:'+$resource) $source
if($LASTEXITCODE -ne 0){throw 'Fixture compiler failed.'}
$bytes=[IO.File]::ReadAllBytes($wrapper)
$sha=Get-TelephoneSupervisorSha256Hex -Bytes $bytes
$sidecar=$wrapper+'.identity.json'
$identity=[ordered]@{protocol_version='telephone-line-supervisor-wrapper-identity-v1';wrapper_path=$wrapper;sha256=$sha;install_root=$install;target_script=$target;working_directory=$install}
function SaveIdentity { [IO.File]::WriteAllText($sidecar,($identity|ConvertTo-Json -Depth 10)) }
$script:checks=[Collections.Generic.List[string]]::new()
function Assert-Check([bool]$Ok,[string]$Name){if(-not $Ok){throw $Name};$script:checks.Add($Name)}
function ReadAction([string]$Work=$install,[string]$ArgumentText=''){return Resolve-TelephoneSupervisorPhysicalTaskAction -Execute $wrapper -Arguments $ArgumentText -WorkingDirectory $Work}
$missing=ReadAction
Assert-Check ($missing.action_kind -ceq 'unrecognized') 'missing sidecar rejects compiled target alone'
SaveIdentity
$valid=ReadAction
Assert-Check ($valid.action_kind -ceq 'verified-no-console-wrapper' -and $valid.action_script -ceq $invoke -and $valid.state_root -ceq (Join-Path $install 'supervisor-state')) 'verified wrapper resolves exact default consumer'
$wrongWork=ReadAction -Work $root
Assert-Check ([string]::IsNullOrWhiteSpace($wrongWork.action_script)) 'different working directory rejected'
$extra=ReadAction -ArgumentText '-StateRoot foreign'
Assert-Check ([string]::IsNullOrWhiteSpace($extra.action_script)) 'extra wrapper arguments rejected'
[IO.File]::WriteAllBytes($wrapper,($bytes+[byte]0))
$changed=ReadAction
Assert-Check ([string]::IsNullOrWhiteSpace($changed.action_script)) 'changed current binary rejects stale sidecar'
[IO.File]::WriteAllBytes($wrapper,$bytes)
$identity.target_script=Join-Path $root 'wrong\Start-TelephoneSupervisorHostVisible.ps1'
SaveIdentity
$wrongTarget=ReadAction
Assert-Check ([string]::IsNullOrWhiteSpace($wrongTarget.action_script)) 'sidecar target different from compiled target rejected'
$identity.target_script=$target
$identity.install_root=$root
SaveIdentity
$wrongRoot=ReadAction
Assert-Check ([string]::IsNullOrWhiteSpace($wrongRoot.action_script)) 'sidecar install different from compiled root rejected'
$identity.install_root=$install
SaveIdentity
$wrongHost=Resolve-TelephoneSupervisorPhysicalTaskAction -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments ('-File "'+$invoke+'"') -WorkingDirectory $install
Assert-Check ([string]::IsNullOrWhiteSpace($wrongHost.action_script)) 'wrong executable cannot be rescued by script-looking arguments'
$pwsh=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$explicitHost=Resolve-TelephoneSupervisorPhysicalTaskAction -Execute $pwsh -Arguments ('-File "'+$target+'" -InstallRoot "'+$install+'" -StateRoot "'+(Join-Path $root 'explicit')+'"') -WorkingDirectory $install
Assert-Check ($explicitHost.action_script -ceq $invoke -and $explicitHost.state_root -ceq (Join-Path $root 'explicit')) 'PowerShell explicit state retained'
$task=[ordered]@{registered=$true;install_root=$valid.install_root;state_root=$valid.state_root;action_script=$valid.action_script;action_arguments=''}
$view=Get-TelephoneSupervisorInstallFileView -InstallRoot $install
Assert-Check ($view.known -and -not $view.redirected -and $view.physical_root -ceq $install) 'regular physical installation resolves to the actual opened file root'
$absent=Get-TelephoneSupervisorInstallFileView -InstallRoot (Join-Path $root 'absent-install')
Assert-Check (-not $absent.known -and -not [string]::IsNullOrWhiteSpace($absent.error)) 'missing physical identity stays unknown'
$previous=[Environment]::GetEnvironmentVariable('TELEPHONE_LINE_SUPERVISOR_STATE_ROOT','Process')
try {
 $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT=Join-Path $root 'obsolete-state'
 $resolved=Resolve-TelephoneSupervisorDoctorState -InstallRoot $install -Task $task
 Assert-Check ($resolved.source -ceq 'verified-installed-task' -and $resolved.state_root -ceq $valid.state_root) 'verified installed task wins over inherited obsolete environment'
 $explicit=Resolve-TelephoneSupervisorDoctorState -InstallRoot $install -SupervisorStateRoot (Join-Path $root 'requested-supervisor') -Task $task
 Assert-Check ($explicit.source -ceq 'explicit-supervisor-state' -and $explicit.state_root -ceq (Join-Path $root 'requested-supervisor')) 'explicit exact supervisor audit retained'
 $line=Resolve-TelephoneSupervisorDoctorState -InstallRoot $install -StateRoot (Join-Path $root 'line') -Task $task
 Assert-Check ($line.source -ceq 'verified-installed-task' -and $line.state_root -ceq $valid.state_root) 'line-state input does not redirect a verified supervisor task'
 $foreign=Resolve-TelephoneSupervisorDoctorState -InstallRoot (Join-Path $root 'foreign-install') -Task $task
 Assert-Check ($foreign.source -ceq 'caller-environment-or-default' -and $foreign.state_root -ceq $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT) 'another install never borrows verified owner state'
 $legacy=Resolve-TelephoneSupervisorDoctorState -InstallRoot $install -StateRoot (Join-Path $root 'line') -Task @{registered=$false}
 Assert-Check ($legacy.state_root -ceq $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT) 'existing dedicated supervisor environment remains the legacy fallback'
 $env:TELEPHONE_LINE_SUPERVISOR_STATE_ROOT=''
 $child=Resolve-TelephoneSupervisorDoctorState -InstallRoot $install -StateRoot (Join-Path $root 'line') -Task @{registered=$false}
 Assert-Check ($child.source -ceq 'line-state-child' -and $child.state_root -ceq (Join-Path $root 'line\supervisor')) 'line-state supervisor child remains the no-task no-environment fallback'
} finally {[Environment]::SetEnvironmentVariable('TELEPHONE_LINE_SUPERVISOR_STATE_ROOT',$previous,'Process')}
$result=[ordered]@{success=$true;fixture_only=$true;actual_scheduler_mutated=$false;actual_business_consumer=$false;assertions=$checks.Count;checks=@($checks)}
[IO.File]::WriteAllText((Join-Path $root 'TEST_RESULT.json'),($result|ConvertTo-Json -Depth 10))
$result|ConvertTo-Json -Depth 10
