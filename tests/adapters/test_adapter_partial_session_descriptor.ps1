# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot,[Parameter(Mandatory)][string]$BaselineSchemaPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $repo 'src\core\TelephoneLine.Common.ps1')
. (Join-Path $repo 'src\contracts\TelephoneLine.AdapterContract.ps1')
. (Join-Path $repo 'src\install\TelephoneLineInstall.Common.ps1')
[void][IO.Directory]::CreateDirectory($TestRoot)
$path=Join-Path $repo 'src\adapters\direct-cursor\adapter.json'
$text=[IO.File]::ReadAllText($path)
$beforeSchema=Get-Content -LiteralPath $BaselineSchemaPath -Raw|ConvertFrom-Json -AsHashtable
$doc=[Text.Json.JsonDocument]::Parse($text)
$errors=[Collections.Generic.List[string]]::new()
try { Invoke-TelephoneSchemaCheck -RootSchema $beforeSchema -Schema $beforeSchema -Element $doc.RootElement -Path '$' -Errors $errors }
finally { $doc.Dispose() }
if ($errors.Count -ne 1 -or $errors[0] -cne '$.capabilities: unknown field partial_session_admission.') { throw ('Baseline failure changed: '+($errors -join ';')) }
$loaded=Read-TelephoneAdapterDescriptor -Path $path -AdapterRoot (Split-Path $path -Parent)
if ($loaded.descriptor.capabilities.partial_session_admission -cne $true) { throw 'Partial-session capability was lost' }
$follow=New-TelephoneAdapterInvocation -Adapter $loaded -Operation follow_up -NativeSessionId 'existing-native-session'
if ($follow.native_session_id -cne 'existing-native-session' -or $follow.automatic_rerun) { throw 'Session/replay contract changed' }
$badType=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
$badType.capabilities.partial_session_admission='true'
$unknown=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
$unknown.capabilities.unreviewed_capability=$true
$refused=0
foreach($negative in @($badType,$unknown)){
    $failed=$false
    try { Assert-TelephoneJsonSchema -JsonText ($negative|ConvertTo-Json -Depth 10) -SchemaName adapter } catch { $failed=$true }
    if (-not $failed) { throw 'Invalid capability accepted' }
    $refused++
}
# This is the real descriptor-report path invoked by the installation Doctor.
$report=Get-TelephoneInstallAdapterReports -InstallRoot $repo
if ($report.validated -ne 8 -or $report.errors -ne 0) { throw 'Actual Doctor descriptor path is not 8/8' }
$result=[ordered]@{
    success=$true;baseline_schema_errors=@($errors);partial_session_admission_retained=$true
    exact_native_session_retained=$true;automatic_rerun=$false;typed_and_unknown_negatives_refused=$refused
    source_doctor_adapter_report=$report;harness_launched=$false
}
[IO.File]::WriteAllText((Join-Path $TestRoot 'DESCRIPTOR_ACCEPTANCE.json'),($result|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$result|ConvertTo-Json -Depth 12

