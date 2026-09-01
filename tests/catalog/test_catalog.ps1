# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$TestRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $repoRoot 'src\core\TelephoneLine.Common.ps1')
$assertions = 0
$testRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

function Assert-CatalogTest {
    param([bool]$Condition, [string]$Message)
    $script:assertions += 1
    if (-not $Condition) { throw $Message }
}

function Count-OrdinalPhrase {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Phrase)
    $count = 0
    $start = 0
    while ($start -le $Text.Length) {
        $idx = $Text.IndexOf($Phrase, $start, [StringComparison]::Ordinal)
        if ($idx -lt 0) { break }
        $count += 1
        $start = $idx + $Phrase.Length
        if ($Phrase.Length -eq 0) { break }
    }
    return $count
}

function Test-PathInsideCandidate {
    param([Parameter(Mandatory = $true)][string]$FullPath)
    $probe = [IO.Path]::GetFullPath($FullPath).TrimEnd('\')
    $root = $repoRoot
    $prefix = $root + '\'
    return ($probe.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or ($probe + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))
}

function Convert-PosixToCandidate {
    param([Parameter(Mandatory = $true)][string]$Posix)
    Assert-CatalogTest ($Posix.Contains('\') -eq $false) "Path is not POSIX: $Posix"
    Assert-CatalogTest ($Posix.Contains('..') -eq $false) "Path escape in $Posix"
    return [IO.Path]::GetFullPath((Join-Path $repoRoot ($Posix.Replace('/', '\'))))
}

function Get-CatalogSchemaErrors {
    param([Parameter(Mandatory = $true)][string]$JsonText)
    $doc = [System.Text.Json.JsonDocument]::Parse($JsonText)
    try {
        $errors = [Collections.Generic.List[string]]::new()
        Invoke-TelephoneSchemaCheck -RootSchema $script:catalogSchema -Schema $script:catalogSchema -Element $doc.RootElement -Path '$' -Errors $errors
        return ,$errors
    } finally {
        $doc.Dispose()
    }
}

function Get-MarkdownRouteRows {
    param([Parameter(Mandatory = $true)][string]$Path)
    $lines = [IO.File]::ReadAllLines($Path)
    $header = $null
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        if (-not $line.StartsWith('|', [StringComparison]::Ordinal)) { continue }
        $parts = $line.Split([char]'|')
        $cells = [Collections.Generic.List[string]]::new()
        for ($i = 1; $i -lt ($parts.Length - 1); $i++) {
            [void]$cells.Add($parts[$i].Trim())
        }
        if ($cells.Count -eq 0) { continue }
        if ($cells[0].StartsWith('---', [StringComparison]::Ordinal)) { continue }
        if ($null -eq $header) {
            $header = @($cells)
            continue
        }
        $row = [ordered]@{}
        for ($i = 0; $i -lt $header.Count; $i++) {
            $row[[string]$header[$i]] = if ($i -lt $cells.Count) { [string]$cells[$i] } else { '' }
        }
        [void]$rows.Add($row)
    }
    return [ordered]@{ header = $header; rows = @($rows) }
}

try {
    $catalogPath = Join-Path $repoRoot 'src\catalog\routes.json'
    $expectedSchemaPath = [IO.Path]::GetFullPath((Join-Path $repoRoot 'schemas\catalog.schema.json'))
    $schemaPath = Get-TelephoneSchemaPath -Name 'catalog'
    Assert-CatalogTest ([IO.Path]::GetFullPath($schemaPath) -ceq $expectedSchemaPath) 'Get-TelephoneSchemaPath did not return the shipped catalog schema file.'
    Assert-CatalogTest ([IO.File]::Exists($schemaPath)) 'Get-TelephoneSchemaPath returned a missing catalog schema file.'
    $catalogText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($catalogPath))
    $schemaText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($schemaPath))
    $script:catalogSchema = $schemaText | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    $catalog = $catalogText | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    $routes = @($catalog.routes)

    $validErrors = Get-CatalogSchemaErrors -JsonText $catalogText
    Assert-CatalogTest ($validErrors.Count -eq 0) ('Catalog failed schema: ' + (@($validErrors | Select-Object -First 8) -join '; '))
    $unknown = $catalogText | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
    $unknown['unexpected_catalog_field'] = $true
    $unknownText = ($unknown | ConvertTo-Json -Depth 32)
    $unknownPath = Join-Path $testRoot 'catalog.unknown-field.json'
    [IO.File]::WriteAllText($unknownPath, $unknownText, [Text.UTF8Encoding]::new($false))
    $unknownErrors = Get-CatalogSchemaErrors -JsonText $unknownText
    Assert-CatalogTest ($unknownErrors.Count -gt 0) 'Unknown catalog field was accepted.'
    $catalog_schema_valid = 1

    $ninthNode = [System.Text.Json.Nodes.JsonNode]::Parse($catalogText)
    $ninthRoutes = $ninthNode['routes'].AsArray()
    Assert-CatalogTest ($ninthRoutes.Count -eq 8) 'Catalog route array was not eight before the ninth-route probe.'
    [void]$ninthRoutes.Add($ninthRoutes[0].DeepClone())
    $ninthText = $ninthNode.ToJsonString()
    $ninthDoc = [System.Text.Json.JsonDocument]::Parse($ninthText)
    try {
        $ninthErrors = [Collections.Generic.List[string]]::new()
        Invoke-TelephoneSchemaCheck -RootSchema $script:catalogSchema -Schema $script:catalogSchema -Element $ninthDoc.RootElement -Path '$' -Errors $ninthErrors
        Assert-CatalogTest ($ninthErrors.Count -gt 0) 'A ninth catalog route was accepted by the shared validator.'
        $maxItemsHit = $false
        foreach ($err in $ninthErrors) {
            if ([string]$err -match 'maxItems') { $maxItemsHit = $true; break }
        }
        Assert-CatalogTest $maxItemsHit ('Ninth catalog route was rejected without maxItems: ' + (@($ninthErrors | Select-Object -First 8) -join '; '))
    } finally {
        $ninthDoc.Dispose()
    }
    $catalog_ninth_route_rejected = 1

    Assert-CatalogTest ([int]$catalog.denominator -eq 8) 'Catalog denominator is not 8.'
    Assert-CatalogTest ([bool]$catalog.denominator_frozen -eq $true) 'Catalog denominator_frozen is not true.'
    Assert-CatalogTest ($routes.Count -eq 8) 'Catalog route count is not 8.'
    $adapterDirs = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src\adapters') -Directory -Force | Where-Object {
        $_.Name -cne 'deepsea-common'
    } | Sort-Object Name)
    Assert-CatalogTest ($adapterDirs.Count -eq 8) 'Adapter roots excluding deepsea-common are not 8.'
    $catalogIds = [Collections.Generic.List[string]]::new()
    $seenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($route in $routes) {
        $id = [string]$route.route_id
        Assert-CatalogTest ($seenIds.Add($id)) "Duplicate route_id $id"
        [void]$catalogIds.Add($id)
    }
    $dirNames = @($adapterDirs | ForEach-Object { [string]$_.Name })
    Assert-CatalogTest ($dirNames.Count -eq $catalogIds.Count) 'Catalog ids and adapter roots have different counts.'
    foreach ($id in $catalogIds) {
        Assert-CatalogTest ($dirNames -ccontains $id) "Catalog route_id $id has no adapter root."
    }
    foreach ($name in $dirNames) {
        Assert-CatalogTest ($catalogIds -ccontains $name) "Adapter root $name is missing from the catalog."
        $descriptorFile = Join-Path (Join-Path $repoRoot 'src\adapters') (Join-Path $name 'adapter.json')
        Assert-CatalogTest ([IO.File]::Exists($descriptorFile)) "Adapter root $name has no adapter.json."
    }
    $catalog_denominator_eight = 8

    $matchedFields = 0
    foreach ($route in $routes) {
        $id = [string]$route.route_id
        $descriptorPath = Convert-PosixToCandidate -Posix ([string]$route.descriptor)
        $descriptorText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($descriptorPath))
        $descriptor = $descriptorText | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
        Assert-CatalogTest ([string]$route.route_id -ceq [string]$descriptor.route_id) "$id route_id differs from the descriptor."
        $matchedFields += 1
        Assert-CatalogTest ([string]$route.display_name -ceq [string]$descriptor.display_name) "$id display_name differs from the descriptor."
        $matchedFields += 1
        Assert-CatalogTest ([string]$route.windows_entrypoint -ceq [string]$descriptor.windows_entrypoint) "$id windows_entrypoint differs from the descriptor."
        $matchedFields += 1
        Assert-CatalogTest ([string]$route.dependency_boundary -ceq [string]$descriptor.dependency_boundary) "$id dependency_boundary differs from the descriptor."
        $matchedFields += 1
        Assert-CatalogTest ([bool]$route.capabilities.start -eq [bool]$descriptor.capabilities.start) "$id start differs from the descriptor."
        $matchedFields += 1
        Assert-CatalogTest ([bool]$route.capabilities.follow_up -eq [bool]$descriptor.capabilities.follow_up) "$id follow_up differs from the descriptor."
        $matchedFields += 1
        Assert-CatalogTest ([bool]$route.capabilities.recover -eq [bool]$descriptor.capabilities.recover) "$id recover differs from the descriptor."
        $matchedFields += 1
        Assert-CatalogTest ([bool]$route.capabilities.exact_native_session -eq [bool]$descriptor.capabilities.exact_native_session) "$id exact_native_session differs from the descriptor."
        $matchedFields += 1
        $dash = $id.IndexOf([char]'-')
        Assert-CatalogTest ($dash -gt 0) "$id has no family prefix."
        $expectedFamily = $id.Substring(0, $dash)
        Assert-CatalogTest ([string]$route.family -ceq $expectedFamily) "$id family is not derived from the route_id prefix."
        Assert-CatalogTest ([bool]$route.boundary_declared_not_probed -eq $true) "$id boundary_declared_not_probed is not true."
    }
    Assert-CatalogTest ($matchedFields -eq 64) 'Descriptor field match count is not 64.'
    $catalog_matches_descriptors = $matchedFields

    foreach ($route in $routes) {
        if ([string]$route.family -cne 'deepsea') {
            Assert-CatalogTest (-not $route.Contains('default_model')) ('Non-DeepSea route ' + [string]$route.route_id + ' declared default_model.')
            continue
        }
        $id = [string]$route.route_id
        $descriptorPath = Convert-PosixToCandidate -Posix ([string]$route.descriptor)
        $descriptorText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($descriptorPath))
        $descriptor = $descriptorText | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
        Assert-CatalogTest ($route.Contains('default_model')) "$id catalog omitted default_model."
        Assert-CatalogTest ($route.Contains('allowed_reasoning_effort')) "$id catalog omitted allowed_reasoning_effort."
        Assert-CatalogTest ([string]$route.default_model -ceq [string]$descriptor.default_model) "$id default_model differs from the descriptor."
        $catalogHasDefaultEffort = $route.Contains('default_reasoning_effort')
        $descriptorHasDefaultEffort = $descriptor.Contains('default_reasoning_effort')
        Assert-CatalogTest ($catalogHasDefaultEffort -eq $descriptorHasDefaultEffort) "$id default_reasoning_effort presence differs from the descriptor."
        $catalogEfforts = @($route.allowed_reasoning_effort | ForEach-Object { [string]$_ })
        $descriptorEfforts = @($descriptor.allowed_reasoning_effort | ForEach-Object { [string]$_ })
        Assert-CatalogTest ($catalogEfforts.Count -eq $descriptorEfforts.Count) "$id allowed_reasoning_effort count differs from the descriptor."
        for ($i = 0; $i -lt $catalogEfforts.Count; $i++) {
            Assert-CatalogTest ([string]$catalogEfforts[$i] -ceq [string]$descriptorEfforts[$i]) "$id allowed_reasoning_effort differs from the descriptor."
        }
        if ($catalogHasDefaultEffort -and $descriptorHasDefaultEffort) {
            Assert-CatalogTest ([string]$route.default_reasoning_effort -ceq [string]$descriptor.default_reasoning_effort) "$id default_reasoning_effort differs from the descriptor."
            Assert-CatalogTest ($catalogEfforts -ccontains [string]$route.default_reasoning_effort) "$id default_reasoning_effort is outside the allowed set."
        }
    }

    foreach ($route in $routes) {
        $adapterFull = Convert-PosixToCandidate -Posix ([string]$route.adapter_root)
        $adapterDir = Assert-TelephoneDirectoryPath -Path $adapterFull -Label ('Adapter root ' + [string]$route.route_id)
        Assert-CatalogTest (Test-PathInsideCandidate -FullPath $adapterDir) ('adapter_root escaped the candidate: ' + [string]$route.route_id)
        $descriptorFull = Convert-PosixToCandidate -Posix ([string]$route.descriptor)
        $descriptorResolved = Assert-TelephoneRegularFilePath -Path $descriptorFull -Label ('Descriptor ' + [string]$route.route_id)
        Assert-CatalogTest (Test-PathInsideCandidate -FullPath $descriptorResolved) ('descriptor escaped the candidate: ' + [string]$route.route_id)
        $entry = Assert-TelephoneContainedRegularFile -Path ([string]$route.windows_entrypoint) -Root $adapterDir -Label ('Entrypoint ' + [string]$route.route_id)
        Assert-CatalogTest (Test-PathInsideCandidate -FullPath $entry) ('windows_entrypoint escaped the candidate: ' + [string]$route.route_id)
        $entryPrefix = $adapterDir + '\'
        Assert-CatalogTest (([IO.Path]::GetFullPath($entry) + '\').StartsWith($entryPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFullPath($entry).Equals($adapterDir, [StringComparison]::OrdinalIgnoreCase)) ('windows_entrypoint escaped the adapter root: ' + [string]$route.route_id)
        foreach ($docPosix in @($route.docs)) {
            $docFull = Convert-PosixToCandidate -Posix ([string]$docPosix)
            $docResolved = Assert-TelephoneRegularFilePath -Path $docFull -Label ('Doc ' + [string]$docPosix)
            Assert-CatalogTest (Test-PathInsideCandidate -FullPath $docResolved) ('docs path escaped the candidate: ' + [string]$docPosix)
        }
    }
    $catalog_paths_real = 1

    $forbiddenRouteFields = @('lead', 'roles', 'rank', 'score', 'recommended', 'preferred')
    foreach ($route in $routes) {
        foreach ($field in $forbiddenRouteFields) {
            Assert-CatalogTest (-not $route.Contains($field)) ('Route ' + [string]$route.route_id + " contains $field")
        }
    }
    Assert-CatalogTest ([string]$catalog.built_in_lead.route_id -ceq 'direct-codex-cli') 'built_in_lead.route_id is not direct-codex-cli.'
    $catalog_no_invented_lead = 1

    for ($i = 1; $i -lt $routes.Count; $i++) {
        $prev = [string]$routes[$i - 1].route_id
        $curr = [string]$routes[$i].route_id
        Assert-CatalogTest ([string]::CompareOrdinal($prev, $curr) -lt 0) "Catalog is not ordinal-sorted at $prev / $curr"
    }
    $catalog_sorted_stable = 1

    $table = Get-MarkdownRouteRows -Path (Join-Path $repoRoot 'docs\routes.md')
    $expectedHeader = @('route_id', 'display_name', 'family', 'dependency_boundary', 'start', 'follow_up', 'recover', 'exact_native_session')
    Assert-CatalogTest ($table.header.Count -eq $expectedHeader.Count) 'routes.md table header count differs.'
    for ($i = 0; $i -lt $expectedHeader.Count; $i++) {
        Assert-CatalogTest ([string]$table.header[$i] -ceq [string]$expectedHeader[$i]) 'routes.md table header differs.'
    }
    Assert-CatalogTest ($table.rows.Count -eq 8) 'routes.md table does not have eight rows.'
    $tableIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in @($table.rows)) {
        $id = [string]$row.route_id
        Assert-CatalogTest ($tableIds.Add($id)) "routes.md duplicate route_id $id"
        $route = $null
        foreach ($item in $routes) {
            if ([string]$item.route_id -ceq $id) { $route = $item; break }
        }
        Assert-CatalogTest ($null -ne $route) "routes.md route_id $id is not in the catalog."
        Assert-CatalogTest ([string]$row.display_name -ceq [string]$route.display_name) "$id display_name differs in routes.md."
        Assert-CatalogTest ([string]$row.family -ceq [string]$route.family) "$id family differs in routes.md."
        Assert-CatalogTest ([string]$row.dependency_boundary -ceq [string]$route.dependency_boundary) "$id dependency_boundary differs in routes.md."
        Assert-CatalogTest ([string]$row.start -ceq ([string][bool]$route.capabilities.start).ToLowerInvariant()) "$id start differs in routes.md."
        Assert-CatalogTest ([string]$row.follow_up -ceq ([string][bool]$route.capabilities.follow_up).ToLowerInvariant()) "$id follow_up differs in routes.md."
        Assert-CatalogTest ([string]$row.recover -ceq ([string][bool]$route.capabilities.recover).ToLowerInvariant()) "$id recover differs in routes.md."
        Assert-CatalogTest ([string]$row.exact_native_session -ceq ([string][bool]$route.capabilities.exact_native_session).ToLowerInvariant()) "$id exact_native_session differs in routes.md."
    }
    foreach ($route in $routes) {
        Assert-CatalogTest ($tableIds.Contains([string]$route.route_id)) ('Catalog route ' + [string]$route.route_id + ' is missing from routes.md.')
    }
    $docs_routes_agree = 8

    $removedClause = 'no ' + 'tenth is planned; Codex CLI remains'
    $oldDenom = 'exactly ' + 'nine routes'
    foreach ($rel in @('docs\architecture.md', 'docs\adapter-interface.md')) {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot $rel))
        $leadCount = Count-OrdinalPhrase -Text $text -Phrase 'only currently built-in Lead'
        $communityCount = Count-OrdinalPhrase -Text $text -Phrase 'community Lead'
        Assert-CatalogTest ($leadCount -le 1) "$rel repeats only currently built-in Lead."
        Assert-CatalogTest ($communityCount -le 1) "$rel repeats community Lead."
        Assert-CatalogTest ($text.Contains($removedClause) -eq $false) "$rel still contains the removed trailing clause."
    }
    $docs_no_duplicate_positioning = 1

    $positionFiles = @(
        'docs\architecture.md',
        'docs\adapter-interface.md',
        'docs\adapter-authoring.md',
        'docs\routes.md'
    )
    $docs_positioning_present = 0
    foreach ($rel in $positionFiles) {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot $rel))
        Assert-CatalogTest ($text.Contains('Codex CLI')) "$rel does not state Codex CLI."
        Assert-CatalogTest ($text.Contains('built-in Lead')) "$rel does not state the built-in Lead fact."
        Assert-CatalogTest ($text.Contains('exactly eight routes')) "$rel does not state the eight-route denominator."
        $docs_positioning_present += 1
    }

    $docWriteSet = @(
        'docs\architecture.md',
        'docs\adapter-interface.md',
        'docs\adapter-authoring.md',
        'docs\routes.md'
    )
    $ninthDenied = @(
        'no ninth is planned',
        'not a v0.1 addition',
        'fork or a later proposal'
    )
    foreach ($rel in $docWriteSet) {
        $text = [IO.File]::ReadAllText((Join-Path $repoRoot $rel))
        Assert-CatalogTest ($text.Contains($removedClause) -eq $false) "$rel promises a tenth by restoring the removed clause."
        Assert-CatalogTest ($text.Contains($oldDenom) -eq $false) "$rel still states the retired denominator."
        Assert-CatalogTest ([regex]::IsMatch($text, '(?i)\broadmap\b') -eq $false) "$rel contains a roadmap claim."
        Assert-CatalogTest ([regex]::IsMatch($text, '(?i)\bGUI\b') -eq $false) "$rel contains a GUI claim."
        Assert-CatalogTest ([regex]::IsMatch($text, '(?i)hosted service') -eq $false) "$rel contains a hosted-service claim."
        Assert-CatalogTest ([regex]::IsMatch($text, '(?i)\bmacOS\b|\bLinux\b|Mac OS') -eq $false) "$rel claims another OS."
        Assert-CatalogTest ([regex]::IsMatch($text, '(?i)best route') -eq $false) "$rel ranks a best route."
        $idx = 0
        while ($true) {
            $found = $text.IndexOf('ninth', $idx, [StringComparison]::OrdinalIgnoreCase)
            if ($found -lt 0) { break }
            $windowStart = [Math]::Max(0, $found - 80)
            $windowLen = [Math]::Min(200, $text.Length - $windowStart)
            $window = $text.Substring($windowStart, $windowLen)
            $denied = $false
            foreach ($token in $ninthDenied) {
                if ($window.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $denied = $true; break }
            }
            Assert-CatalogTest $denied "$rel promises a ninth route near: $window"
            $idx = $found + 5
        }
    }
    $docs_no_ninth_route_claim = 1

    $privacyFiles = @(
        'src\catalog\routes.json',
        'schemas\catalog.schema.json',
        'docs\routes.md',
        'docs\adapter-authoring.md',
        'docs\architecture.md',
        'docs\adapter-interface.md',
        'tests\catalog\test_catalog.ps1',
        'tests\Invoke-OfflineTests.ps1'
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
    foreach ($rel in $privacyFiles) {
        $full = Join-Path $repoRoot $rel
        $text = [IO.File]::ReadAllText($full)
        foreach ($pattern in $privacyPatterns) {
            Assert-CatalogTest ($pattern.re.IsMatch($text) -eq $false) ("Privacy hit " + [string]$pattern.id + ' ' + $rel)
        }
    }
    $catalog_privacy_clean = 1

    [ordered]@{
        success = $true
        catalog_schema_valid = $catalog_schema_valid
        catalog_ninth_route_rejected = $catalog_ninth_route_rejected
        catalog_denominator_eight = $catalog_denominator_eight
        catalog_matches_descriptors = $catalog_matches_descriptors
        catalog_paths_real = $catalog_paths_real
        catalog_no_invented_lead = $catalog_no_invented_lead
        catalog_sorted_stable = $catalog_sorted_stable
        docs_routes_agree = $docs_routes_agree
        docs_no_duplicate_positioning = $docs_no_duplicate_positioning
        docs_positioning_present = $docs_positioning_present
        docs_no_ninth_route_claim = $docs_no_ninth_route_claim
        catalog_privacy_clean = $catalog_privacy_clean
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
