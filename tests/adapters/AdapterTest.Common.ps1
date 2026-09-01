# SPDX-License-Identifier: MPL-2.0
Set-StrictMode -Version Latest

function Assert-AdapterTest {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Invoke-AdapterEntrypoint {
    param(
        [Parameter(Mandatory = $true)][string]$Entrypoint,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments
    )
    $powerShellPath = [string]([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $powerShellPath
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Entrypoint) + $Arguments) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $text = [string]$stdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
        $value = $null
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            try { $value = $text | ConvertFrom-Json -AsHashtable -Depth 32 -DateKind String } catch { }
        }
        return [ordered]@{ exit_code = [int]$process.ExitCode; stdout = $text; stderr = $stderr; value = $value }
    } finally { $process.Dispose() }
}

function Copy-AdapterForTest {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
    if ([IO.Directory]::Exists($Destination)) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
}

function Assert-NoPromptBody {
    param([Parameter(Mandatory = $true)][string]$RequestPath, [Parameter(Mandatory = $true)][string]$PromptText)
    $text = [IO.File]::ReadAllText($RequestPath)
    Assert-AdapterTest ($text.Contains('"sha256"')) 'Request is missing prompt identity.'
    Assert-AdapterTest (-not $text.Contains($PromptText)) 'Request copied the prompt body.'
}

function Get-AdapterArtifactSentinelCount {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Sentinels)
    $count = 0
    if (-not [IO.Directory]::Exists($Root)) { return 0 }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $text = [IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false, $true))
        foreach ($sentinel in $Sentinels) {
            if (-not [string]::IsNullOrEmpty($sentinel) -and $text.Contains($sentinel)) { $count += 1 }
        }
    }
    return $count
}

function New-AdapterRuntimeSentinels {
    $at = [char]64
    $id = [Guid]::NewGuid().ToString('N')
    return [ordered]@{
        prompt = 'TLV01' + 'C1' + 'PROMPT' + $id
        email = 'tlv01c1.' + $id + $at + 'example.test'
        path = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('tlv01c1-' + $id)
        key = 'sk' + '-' + 'c1test' + '-' + $id
    }
}
