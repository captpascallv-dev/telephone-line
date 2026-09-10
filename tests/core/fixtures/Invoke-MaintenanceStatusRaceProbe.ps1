# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ArtifactRoot,[string]$SourceRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($SourceRoot)){$SourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))}
$artifact=[IO.Path]::GetFullPath($ArtifactRoot)
[IO.Directory]::CreateDirectory($artifact)|Out-Null
$childPath=Join-Path $artifact 'writer.ps1'
$barrier=Join-Path $artifact 'go'
$jobRoot=Join-Path $artifact 'job'
[IO.Directory]::CreateDirectory($jobRoot)|Out-Null
$childScript=@'
param([string]$SourceRoot,[string]$JobRoot,[string]$Barrier,[string]$Writer)
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'src\core\TelephoneLine.Common.ps1')
$paths=Get-TelephoneJobPaths -JobRoot $JobRoot
while(-not [IO.File]::Exists($Barrier)){Start-Sleep -Milliseconds 10}
for($i=0;$i -lt 80;$i++){
    $null=Write-TelephoneLifecycleStatus -Paths $paths -Phase 'delivered' -Idle $false
}
[ordered]@{writer=$Writer;completed=80}|ConvertTo-Json -Compress
'@
[IO.File]::WriteAllText($childPath,$childScript,[Text.UTF8Encoding]::new($false))
$children=[Collections.Generic.List[object]]::new()
try{
    foreach($label in @('relay','collector')){
        $info=[Diagnostics.ProcessStartInfo]::new()
        $info.FileName=(Get-Process -Id $PID).Path
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        foreach($arg in @('-NoProfile','-File',$childPath,'-SourceRoot',$SourceRoot,'-JobRoot',$jobRoot,'-Barrier',$barrier,'-Writer',$label)){[void]$info.ArgumentList.Add($arg)}
        $proc=[Diagnostics.Process]::Start($info)
        [void]$children.Add([ordered]@{label=$label;process=$proc;stdout=$proc.StandardOutput.ReadToEndAsync();stderr=$proc.StandardError.ReadToEndAsync()})
    }
    [IO.File]::WriteAllText($barrier,'go')
    $results=@()
    foreach($child in $children){
        if(-not $child.process.WaitForExit(45000)){throw 'Probe bound reached; writer status remains unknown.'}
        $results+=[ordered]@{label=$child.label;exit_code=$child.process.ExitCode;stdout=$child.stdout.GetAwaiter().GetResult();stderr=$child.stderr.GetAwaiter().GetResult()}
    }
    $ok=@($results|Where-Object {$_.exit_code -ne 0}).Count -eq 0
    $status=Get-Content -LiteralPath (Join-Path $jobRoot 'lifecycle-status.json') -Raw|ConvertFrom-Json
    $ok=$ok -and $status.phase -ceq 'delivered'
    $report=[ordered]@{ok=$ok;source_root=$SourceRoot;writers=$results;final_status=$status;production_publisher='Write-TelephoneLifecycleStatus';immutable_receipts_written=$false}
    [IO.File]::WriteAllText((Join-Path $artifact 'observations.json'),($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    Write-Output ($report|ConvertTo-Json -Depth 10 -Compress)
    if(-not $ok){exit 1}
}finally{
    foreach($child in $children){try{if(-not $child.process.HasExited){$child.process.Kill()};$child.process.Dispose()}catch{}}
}

