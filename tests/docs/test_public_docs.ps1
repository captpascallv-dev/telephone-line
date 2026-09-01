# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

function Assert-DocsTest {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Test-PathInsideCandidate {
    param([Parameter(Mandatory = $true)][string]$FullPath)
    $probe = [IO.Path]::GetFullPath($FullPath).TrimEnd('\')
    $root = $repoRoot
    $prefix = $root + '\'
    return ($probe.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or ($probe + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))
}

function Get-MarkdownWithoutCode {
    param([Parameter(Mandatory = $true)][string]$Text)
    $withoutFences = [regex]::Replace($Text, '(?s)```.*?```', ' ')
    return [regex]::Replace($withoutFences, '`[^`]*`', ' ')
}

function Get-RelativeMarkdownLinks {
    param([Parameter(Mandatory = $true)][string]$Text)
    $body = Get-MarkdownWithoutCode -Text $Text
    $links = [Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($body, '\[[^\]]*\]\(([^)]+)\)')) {
        [void]$links.Add([string]$match.Groups[1].Value.Trim())
    }
    return @($links)
}

function Get-ScriptParameterNames {
    param([Parameter(Mandatory = $true)][string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-DocsTest ($null -eq $errors -or @($errors).Count -eq 0) "Failed to parse parameter block: $Path"
    $names = [Collections.Generic.List[string]]::new()
    if ($null -ne $ast.ParamBlock) {
        foreach ($parameter in @($ast.ParamBlock.Parameters)) {
            [void]$names.Add([string]$parameter.Name.VariablePath.UserPath)
        }
    }
    return @($names)
}

function Test-NinthDenied {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Label)
    $ninthDenied = @(
        'no ninth is planned',
        'not a v0.1 addition',
        'fork or a later proposal'
    )
    $idx = 0
    while ($true) {
        $found = $Text.IndexOf('ninth', $idx, [StringComparison]::OrdinalIgnoreCase)
        if ($found -lt 0) { break }
        $windowStart = [Math]::Max(0, $found - 80)
        $windowLen = [Math]::Min(200, $Text.Length - $windowStart)
        $window = $Text.Substring($windowStart, $windowLen)
        $denied = $false
        foreach ($token in $ninthDenied) {
            if ($window.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $denied = $true; break }
        }
        Assert-DocsTest $denied "$Label announces a ninth route near: $window"
        $idx = $found + 5
    }
}

try {
    $readmePath = Join-Path $repoRoot 'README.md'
    $licensePath = Join-Path $repoRoot 'LICENSE'
    $contributingPath = Join-Path $repoRoot 'CONTRIBUTING.md'
    $securityPath = Join-Path $repoRoot 'SECURITY.md'
    $licensingPath = Join-Path $repoRoot 'docs\licensing.md'
    $quickStartPath = Join-Path $repoRoot 'docs\quick-start.md'
    $readme = [IO.File]::ReadAllText($readmePath)
    $license = [IO.File]::ReadAllText($licensePath)
    $contributing = [IO.File]::ReadAllText($contributingPath)
    $security = [IO.File]::ReadAllText($securityPath)
    $licensing = [IO.File]::ReadAllText($licensingPath)
    $quickStart = [IO.File]::ReadAllText($quickStartPath)
    $readmeLines = [IO.File]::ReadAllLines($readmePath)
    $firstScreenCount = [Math]::Min(40, $readmeLines.Length)
    $firstScreen = [string]::Join("`n", $readmeLines[0..($firstScreenCount - 1)])

    Assert-DocsTest ($firstScreen.Contains('Codex stays the Lead')) 'README first 40 lines omit Codex stays the Lead.'
    Assert-DocsTest ($firstScreen.Contains('Other harnesses do the heavy work')) 'README first 40 lines omit other harnesses do the heavy work.'
    Assert-DocsTest ($firstScreen.Contains('Codex sleeps while they run')) 'README first 40 lines omit Codex sleeps while they run.'
    Assert-DocsTest ($firstScreen.Contains('resumes on the exact callback')) 'README first 40 lines omit exact callback.'
    Assert-DocsTest ($firstScreen.Contains('Codex-first')) 'README first 40 lines omit Codex-first.'
    Assert-DocsTest ($firstScreen.Contains('Codex CLI is the only currently built-in Lead')) 'README first 40 lines omit the only currently built-in Lead fact.'
    Assert-DocsTest ($firstScreen.Contains('not substitute Lead entries')) 'README first 40 lines omit execution-or-review-sides fact.'
    Assert-DocsTest ($firstScreen.Contains('It is not a second built-in Lead entry')) 'README first 40 lines omit that Direct Codex CLI is not a second Lead.'
    Assert-DocsTest ([regex]::IsMatch($readme, '(?i)multi[\s\-]*harness[\s\-]*orchestrat') -eq $false) 'README contains multi-harness orchestrator or an equivalent.'
    $readme_first_screen_codex_first = 1

    $sequence = @(
        'Who needs multi-Harness collaboration',
        'Why multiple Harnesses rather than merely multiple models',
        'The pain before this project',
        'How the telephone line solves transport continuity without judging project correctness',
        'Operational recommendations learned from real use'
    )
    $pos = -1
    foreach ($item in $sequence) {
        $idx = $readme.IndexOf($item, [StringComparison]::Ordinal)
        Assert-DocsTest ($idx -ge 0) "README is missing lead item: $item"
        Assert-DocsTest ($idx -gt $pos) "README lead item out of order: $item"
        $pos = $idx
    }
    foreach ($pain in @('manual relay', 'lost sessions', 'waiting online', 'duplicate runs', 'timeouts', 'quota fragmentation')) {
        Assert-DocsTest ($readme.Contains($pain)) "README omits pain phrase: $pain"
    }
    Assert-DocsTest ($readme.Contains('tools, permissions, sessions, workspace, context, and independent quota pools')) 'README omits the Harness-vs-model reason list.'
    foreach ($rec in @('one Lead', 'exact-session callback', 'bounded package acceptance', 'no model waiting online', 'no absolute task timeout', 'no blind rerun', 'one final independent audit only at a major terminal')) {
        Assert-DocsTest ($readme.Contains($rec)) "README omits operational recommendation: $rec"
    }
    $readme_lead_sequence_present = 1

    $claimPatterns = @(
        [regex]'(?i)\bx\s+faster\b',
        [regex]'(?i)\bx\s+cheaper\b',
        [regex]'(?i)\bSLA\b',
        [regex]'(?i)guaranteed\s+quota',
        [regex]'(?i)\bbenchmark\b',
        [regex]'(?i)\broadmap\b',
        [regex]'(?i)(\d+\s*%|\d+\s*x)\W{0,12}(sav(?:e|ing|ings)|faster|cheaper|cost|quota|speed)',
        [regex]'(?i)(sav(?:e|ing|ings)|faster|cheaper|cost|quota|speed)\W{0,12}(\d+\s*%|\d+\s*x)'
    )
    foreach ($pattern in $claimPatterns) {
        Assert-DocsTest ($pattern.IsMatch($readme) -eq $false) ("README contains a forbidden claim matching " + [string]$pattern)
    }
    $readme_no_forbidden_claims = 1

    Assert-DocsTest (-not [regex]::IsMatch($security, '(?i)\bplaceholder\b')) 'SECURITY.md still contains a pre-publication placeholder.'
    Assert-DocsTest ($security.Contains('private vulnerability reporting')) 'SECURITY.md does not provide a private vulnerability reporting path.'

    $inviteIdx = $readme.IndexOf('Community Lead adapters', [StringComparison]::Ordinal)
    Assert-DocsTest ($inviteIdx -ge 0) 'README does not invite community Lead adapters.'
    $inviteWindow = $readme.Substring($inviteIdx)
    foreach ($gate in @(
        'unified contract',
        'native-session recovery',
        'Lead sleep and callback',
        'no whole-task timeout',
        'privacy checks',
        'compatibility tests',
        'code review'
    )) {
        Assert-DocsTest ($inviteWindow.Contains($gate)) "README community Lead invitation omits gate: $gate"
    }
    Assert-DocsTest ($inviteWindow.Contains('not current capability')) 'README presents community Lead adapters as current capability.'
    Assert-DocsTest ([regex]::IsMatch($readme, '(?i)(Cursor|Grok|SuperGrok|Claude Code|\bDSH\b|\bPI\b) is the only currently built-in Lead') -eq $false) 'README states that another Harness is currently a Lead.'
    $readme_community_lead_gated = 1

    $docFiles = [Collections.Generic.List[string]]::new()
    [void]$docFiles.Add('README.md')
    [void]$docFiles.Add('CONTRIBUTING.md')
    [void]$docFiles.Add('SECURITY.md')
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') -Recurse -File -Force | Sort-Object FullName)) {
        $rel = $file.FullName.Substring($repoRoot.Length).TrimStart('\').Replace('\', '/')
        [void]$docFiles.Add($rel)
    }
    foreach ($rel in $docFiles) {
        $full = Join-Path $repoRoot ($rel.Replace('/', '\'))
        Assert-DocsTest ([IO.File]::Exists($full)) "Missing doc file $rel"
        $text = [IO.File]::ReadAllText($full)
        $baseDir = [IO.Path]::GetDirectoryName($full)
        foreach ($target in @(Get-RelativeMarkdownLinks -Text $text)) {
            if ([string]::IsNullOrWhiteSpace($target)) { continue }
            if ($target.StartsWith('#', [StringComparison]::Ordinal)) { continue }
            $lower = $target.ToLowerInvariant()
            if ($lower.StartsWith('http://') -or $lower.StartsWith('https://') -or $lower.StartsWith('mailto:')) { continue }
            $pathOnly = $target.Split('#')[0]
            if ([string]::IsNullOrWhiteSpace($pathOnly)) { continue }
            $resolved = [IO.Path]::GetFullPath((Join-Path $baseDir ($pathOnly.Replace('/', '\'))))
            Assert-DocsTest (Test-PathInsideCandidate -FullPath $resolved) "Link in $rel escapes the candidate: $target"
            Assert-DocsTest ([IO.File]::Exists($resolved)) "Broken relative link in $rel -> $target"
        }
    }
    $docs_links_resolve = 1

    $licenseBytes = [IO.File]::ReadAllBytes($licensePath)
    Assert-DocsTest ($license.Contains('Mozilla Public License Version 2.0')) 'LICENSE is missing the MPL-2.0 title and version line.'
    foreach ($heading in @(
        '1. Definitions',
        '2. License Grants and Conditions',
        '3. Responsibilities',
        '4. Inability to Comply Due to Statute or Regulation',
        '5. Termination',
        '6. Disclaimer of Warranty',
        '7. Limitation of Liability',
        '8. Litigation',
        '9. Miscellaneous',
        '10. Versions of the License'
    )) {
        Assert-DocsTest ($license.Contains($heading)) "LICENSE is missing section heading: $heading"
    }
    Assert-DocsTest ($license.Contains('Exhibit A - Source Code Form License Notice')) 'LICENSE is missing Exhibit A.'
    Assert-DocsTest ($license.Contains('Exhibit B - "Incompatible With Secondary Licenses" Notice')) 'LICENSE is missing Exhibit B.'
    $collapsedLicense = [regex]::Replace($license, '\s+', ' ').Trim()
    $exhibitA = 'This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.'
    Assert-DocsTest ($collapsedLicense.Contains($exhibitA)) 'LICENSE is missing the canonical Exhibit A notice sentence.'
    foreach ($placeholder in @('[yyyy]', '[name of copyright owner]', 'TODO', 'FIXME')) {
        Assert-DocsTest ($license.Contains($placeholder) -eq $false) "LICENSE contains placeholder $placeholder"
    }
    Assert-DocsTest ($licenseBytes.Length -ge 15000) ("LICENSE is only " + $licenseBytes.Length + ' bytes.')
    $license_is_mpl2_complete = 1

    Assert-DocsTest ($licensing.Contains('file-level copyleft')) 'docs/licensing.md does not state file-level copyleft.'
    Assert-DocsTest ($licensing.Contains('Larger Work')) 'docs/licensing.md does not state the Larger Work allowance.'
    Assert-DocsTest ([regex]::IsMatch($licensing, 'LICENSE.*govern') -or $licensing.Contains('LICENSE](../LICENSE) governs')) 'docs/licensing.md does not state that LICENSE governs on conflict.'
    $licensing_notes_consistent = 1

    $hostParams = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(
        'NoLogo', 'NoProfile', 'NonInteractive', 'ExecutionPolicy', 'File', 'Command',
        'WorkingDirectory', 'OutputFormat', 'InputFormat', 'ConfigurationName', 'Version',
        'Help', 'Login', 'Sta', 'Mta', 'NoExit', 'NoInteractive', 'EncodedCommand', 'Args',
        'WindowStyle', 'NoNewWindow', 'EncodedArguments'
    )) { [void]$hostParams.Add($name) }
    $scriptPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($quickStart, '(?:src|tests)/[A-Za-z0-9._/-]+\.ps1')) {
        [void]$scriptPaths.Add([string]$match.Value)
    }
    Assert-DocsTest ($scriptPaths.Count -gt 0) 'docs/quick-start.md cites no repository script path.'
    $knownParams = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($posix in $scriptPaths) {
        $full = [IO.Path]::GetFullPath((Join-Path $repoRoot ($posix.Replace('/', '\'))))
        Assert-DocsTest (Test-PathInsideCandidate -FullPath $full) "Quick start script path escapes the candidate: $posix"
        Assert-DocsTest ([IO.File]::Exists($full)) "Quick start cites missing script $posix"
        foreach ($name in @(Get-ScriptParameterNames -Path $full)) {
            [void]$knownParams.Add($name)
        }
    }
    foreach ($match in [regex]::Matches($quickStart, '(?<![A-Za-z0-9])-([A-Za-z][A-Za-z0-9]*)')) {
        $name = [string]$match.Groups[1].Value
        if ($hostParams.Contains($name)) { continue }
        Assert-DocsTest ($knownParams.Contains($name)) "Quick start cites parameter -$name that is not on a cited script."
    }
    $quick_start_commands_real = 1

    $githubFiles = @(
        '.github/ISSUE_TEMPLATE/bug_report.md',
        '.github/ISSUE_TEMPLATE/adapter_proposal.md',
        '.github/ISSUE_TEMPLATE/config.yml',
        '.github/pull_request_template.md'
    )
    foreach ($rel in $githubFiles) {
        $full = Join-Path $repoRoot ($rel.Replace('/', '\'))
        Assert-DocsTest ([IO.File]::Exists($full)) "Missing template $rel"
        Assert-DocsTest (([IO.File]::ReadAllText($full).Trim().Length) -gt 0) "Empty template $rel"
    }
    $configPath = Join-Path $repoRoot '.github\ISSUE_TEMPLATE\config.yml'
    $configText = [IO.File]::ReadAllText($configPath)
    Assert-DocsTest ([regex]::IsMatch($configText, '(?m)^blank_issues_enabled:\s*(true|false)\s*$')) 'config.yml is missing blank_issues_enabled.'
    $yamlOk = $false
    $yamlCommand = Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue
    if ($null -ne $yamlCommand) {
        $null = $configText | ConvertFrom-Yaml
        $yamlOk = $true
    } else {
        Assert-DocsTest ([regex]::IsMatch($configText, '(?m)^contact_links:\s*$') -or $configText.Contains('contact_links:')) 'config.yml failed the offline structural check.'
        $yamlOk = $true
    }
    Assert-DocsTest $yamlOk 'config.yml did not parse.'
    foreach ($match in [regex]::Matches($configText, '(?m)^\s+url:\s*(\S+)\s*$')) {
        $url = [string]$match.Groups[1].Value.Trim().Trim('"').Trim("'")
        $lower = $url.ToLowerInvariant()
        if ($lower.StartsWith('http://') -or $lower.StartsWith('https://') -or $lower.StartsWith('mailto:')) {
            throw "config.yml contact link is not a repository file: $url"
        }
        $candidates = @(
            (Join-Path $repoRoot ($url.Replace('/', '\'))),
            (Join-Path (Join-Path $repoRoot '.github\ISSUE_TEMPLATE') ($url.Replace('/', '\'))),
            (Join-Path (Join-Path $repoRoot '.github') ($url.Replace('/', '\')))
        )
        $exists = $false
        foreach ($candidate in $candidates) {
            $resolved = [IO.Path]::GetFullPath($candidate)
            if ((Test-PathInsideCandidate -FullPath $resolved) -and [IO.File]::Exists($resolved)) { $exists = $true; break }
        }
        Assert-DocsTest $exists "config.yml contact link does not point at an existing repository file: $url"
    }
    $templates_valid = 1

    $appServerLeadDocs = [IO.File]::ReadAllText((Join-Path $repoRoot 'docs\codex-app-server-lead.md'))
    foreach ($pair in @(
        @{ label = 'README'; text = $readme },
        @{ label = 'CONTRIBUTING'; text = $contributing },
        @{ label = 'quick start'; text = $quickStart },
        @{ label = 'codex app-server lead'; text = $appServerLeadDocs }
    )) {
        Assert-DocsTest ($pair.text.Contains('exactly eight routes')) "$($pair.label) does not state exactly eight routes."
        Test-NinthDenied -Text $pair.text -Label $pair.label
        Assert-DocsTest ([regex]::IsMatch($pair.text, '(?i)\bGUI\b') -eq $false) "$($pair.label) announces a GUI."
        Assert-DocsTest ([regex]::IsMatch($pair.text, '(?i)hosted service') -eq $false) "$($pair.label) announces a hosted service."
        Assert-DocsTest ([regex]::IsMatch($pair.text, '(?i)\btelemetry\b') -eq $false) "$($pair.label) announces telemetry."
        Assert-DocsTest ([regex]::IsMatch($pair.text, '(?i)\bmarketplace\b') -eq $false) "$($pair.label) announces a marketplace."
        Assert-DocsTest ([regex]::IsMatch($pair.text, '(?i)\bbilling\b') -eq $false) "$($pair.label) announces billing."
        Assert-DocsTest ([regex]::IsMatch($pair.text, '(?i)\bmacOS\b|\bLinux\b|Mac OS') -eq $false) "$($pair.label) claims another OS."
    }
    $eight_routes_consistent = 1

    $writeSet = @(
        'README.md',
        'LICENSE',
        'CONTRIBUTING.md',
        'SECURITY.md',
        'docs/licensing.md',
        'docs/quick-start.md',
        'docs/dashboard.md',
        '.github/ISSUE_TEMPLATE/bug_report.md',
        '.github/ISSUE_TEMPLATE/adapter_proposal.md',
        '.github/ISSUE_TEMPLATE/config.yml',
        '.github/pull_request_template.md',
        'tests/docs/test_public_docs.ps1',
        'tests/Invoke-OfflineTests.ps1'
    )
    $usersWin = 'C:' + [char]92 + 'Users' + [char]92
    $usersUnix = '/' + 'Users' + '/'
    $privateRepoMarker = 'private' + '-' + 'repository' + '-' + 'marker'
    $internalOperatorMarker = 'internal' + '-' + 'operator' + '-' + 'alias'
    $unpublishedProjectMarker = 'unpublished' + '-' + 'project' + '-' + 'marker'
    $privacyPatterns = @(
        @{ id = 'users_prefix'; re = [regex][regex]::Escape($usersWin) },
        @{ id = 'unix_users'; re = [regex][regex]::Escape($usersUnix) },
        @{ id = 'private_repo_marker'; re = [regex][regex]::Escape($privateRepoMarker) },
        @{ id = 'internal_operator_marker'; re = [regex][regex]::Escape($internalOperatorMarker) },
        @{ id = 'unpublished_project_marker'; re = [regex][regex]::Escape($unpublishedProjectMarker) },
        @{ id = 'openai_sk'; re = [regex]('sk' + '-[A-Za-z0-9_-]{16,}') },
        @{ id = 'xai_key_value'; re = [regex]('\bxai' + '-[A-Za-z0-9]{20,}\b') },
        @{ id = 'bearer'; re = [regex]('Bearer' + '\s+[A-Za-z0-9._\-+/=]{20,}') },
        @{ id = 'jwt'; re = [regex]('eyJ' + '[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+') },
        @{ id = 'email'; re = [regex]('[A-Za-z0-9._%+-]+' + [char]64 + '[A-Za-z0-9.-]+\.[A-Za-z]{2,}') }
    )
    foreach ($rel in $writeSet) {
        $full = Join-Path $repoRoot ($rel.Replace('/', '\'))
        Assert-DocsTest ([IO.File]::Exists($full)) "Write-set file missing: $rel"
        $text = [IO.File]::ReadAllText($full)
        foreach ($pattern in $privacyPatterns) {
            Assert-DocsTest ($pattern.re.IsMatch($text) -eq $false) ("Privacy hit " + [string]$pattern.id + ' ' + $rel)
        }
    }
    $public_docs_privacy_clean = 1

    $workflowPath = Join-Path $repoRoot '.github\workflows\ci.yml'
    Assert-DocsTest ([IO.File]::Exists($workflowPath)) 'CI workflow is missing.'
    $workflow = [IO.File]::ReadAllText($workflowPath)
    Assert-DocsTest ($workflow.Contains('pull_request:')) 'CI workflow omitted pull_request.'
    Assert-DocsTest ($workflow.Contains('push:')) 'CI workflow omitted push.'
    Assert-DocsTest ($workflow.Contains('workflow_dispatch:')) 'CI workflow omitted workflow_dispatch.'
    Assert-DocsTest ($workflow.Contains('cancel-in-progress: true')) 'CI workflow omitted concurrency cancellation.'
    Assert-DocsTest ($workflow.Contains('type: choice')) 'CI workflow omitted explicit mode choice.'
    Assert-DocsTest ($workflow.Contains('default: smoke')) 'CI workflow omitted smoke as the default manual mode.'
    $offlineInvocations = [regex]::Matches($workflow, '-File tests/Invoke-OfflineTests\.ps1')
    Assert-DocsTest ($offlineInvocations.Count -eq 1) ('CI workflow must invoke the full offline suite exactly once, found ' + [string]$offlineInvocations.Count + '.')
    Assert-DocsTest ($workflow.Contains("if: steps.mode.outputs.mode == 'full'")) 'Full offline suite is not gated on explicit full mode.'
    Assert-DocsTest ($workflow.Contains("Automatic pull_request and main push must remain smoke.")) 'CI workflow omitted the automatic-event smoke guard.'
    Assert-DocsTest ($workflow.Contains('Full verification is manual workflow_dispatch only.')) 'CI workflow omitted the manual-only full guard.'
    Assert-DocsTest ($workflow.Contains('CallbackOwnerOnly')) 'Smoke omitted callback-owner-only coverage.'
    Assert-DocsTest ($workflow.Contains('tests/core/test_telephone_line.ps1')) 'Smoke omitted core Telephone coverage.'
    Assert-DocsTest ($workflow.Contains('tests/contracts/test_contracts.ps1')) 'Smoke omitted contract coverage.'
    Assert-DocsTest ($workflow.Contains('tests/docs/test_public_docs.ps1')) 'Smoke omitted docs coverage.'
    Assert-DocsTest ($workflow.Contains('tests/packaging/test_packaging.ps1')) 'Smoke omitted manifest/packaging coverage.'
    Assert-DocsTest ($workflow.Contains('Classify verification mode')) 'CI mode classifier step is missing.'
    Assert-DocsTest ($workflow.Contains("`$eventName -eq 'pull_request' -or `$eventName -eq 'push'")) 'PR/main classifier does not force smoke.'
    Assert-DocsTest ($workflow.Contains("`$eventName -eq 'workflow_dispatch' -and `$requested -eq 'full'")) 'Manual classifier omitted explicit full.'
    $ci_event_to_mode = 1
    $ci_full_run_count = $offlineInvocations.Count

    [ordered]@{
        success = $true
        readme_first_screen_codex_first = $readme_first_screen_codex_first
        readme_lead_sequence_present = $readme_lead_sequence_present
        readme_no_forbidden_claims = $readme_no_forbidden_claims
        readme_community_lead_gated = $readme_community_lead_gated
        docs_links_resolve = $docs_links_resolve
        license_is_mpl2_complete = $license_is_mpl2_complete
        licensing_notes_consistent = $licensing_notes_consistent
        quick_start_commands_real = $quick_start_commands_real
        templates_valid = $templates_valid
        eight_routes_consistent = $eight_routes_consistent
        public_docs_privacy_clean = $public_docs_privacy_clean
        ci_event_to_mode = $ci_event_to_mode
        ci_full_run_count = $ci_full_run_count
        assertions = $assertions
    } | ConvertTo-Json -Compress
} catch {
    [ordered]@{
        success = $false
        error = [string]$_.Exception.Message
        assertions = $assertions
    } | ConvertTo-Json -Compress
    exit 1
} finally {
    if ([IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
