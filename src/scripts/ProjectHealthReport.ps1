# Presentation projection only. Persisted assessment evidence and history storage stay unchanged.
function Get-ProjectHealthDisplayData {
    param($Snapshot, $History, [string]$EffortConfigPath, [int]$SharedOpportunityMinimum, [double]$QuickWinThreshold)
    $categoryMap = [ordered]@{}
    foreach ($pair in @(
        @('Repos', @('Repos','Repository','Repositories','Microsoft Azure DevOps Repos')),
        @('Pipelines', @('Pipelines','Pipeline','Microsoft Azure DevOps Pipelines')),
        @('Service Connections', @('Service Connections','Service Connection','Microsoft Azure DevOps Service Connections')),
        @('Environments', @('Environments','Environment','Microsoft Azure DevOps Environments')),
        @('Variable Groups', @('Variable Groups','Variable Group','Microsoft Azure DevOps Variable Groups','Microsoft Azure DevOps Distributed Task')),
        @('Projects', @('Projects','Project','Microsoft Azure DevOps Projects')),
        @('Retention Settings', @('Retention Settings','Retention','Microsoft Azure DevOps Retention Settings')),
        @('Organization', @('Organization','Microsoft Azure DevOps Organization'))
    )) { foreach ($label in $pair[1]) { $categoryMap[$label] = $pair[0] } }
    $collectorMap = [ordered]@{
        'Export-AzDevOpsProject' = 'Projects'; 'Export-AzDevOpsReposAndBranchPolicies' = 'Repos'
        'Export-AzDevOpsEnvironmentChecks' = 'Environments'; 'Export-AzDevOpsServiceConnections' = 'Service Connections'
        'Export-AzDevOpsPipelines' = 'Pipelines'; 'Export-AzDevOpsPipelinesSettings' = 'Pipelines'
        'Export-AzDevOpsReleaseDefinitions' = 'Pipelines'; 'Export-AzDevOpsGroups' = 'Pipelines'
        'Export-AzDevOpsVariableGroups' = 'Variable Groups'; 'Export-AzDevOpsRetentionSettings' = 'Retention Settings'
    }
    $effort = Get-Content -LiteralPath $EffortConfigPath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($group in 'categoryDefaults', 'ruleOverrides') {
        if ($effort[$group] -isnot [Collections.IDictionary]) { throw "Effort config requires $group." }
        foreach ($value in $effort[$group].Values) {
            if ($value -cnotin 'Low','Medium','High','Unknown') { throw 'Effort values must be Low, Medium, High or Unknown.' }
        }
    }
    $rules = [ordered]@{}
    foreach ($source in @($Snapshot) + @($History.snapshots)) {
        foreach ($record in $source.results) {
            if (-not $rules.Contains($record.ruleName)) {
                $category = if ($categoryMap.Contains($record.category)) { $categoryMap[$record.category] } else { $record.category }
                $rules[$record.ruleName] = [ordered]@{
                    displayName = $record.displayName; category = $category; severity = $record.severity
                    description = $record.description; recommendation = $record.recommendation
                    documentation = $record.documentation; references = @($record.references)
                }
            }
        }
    }
    $display = [ordered]@{}
    foreach ($key in $Snapshot.Keys) { $display[$key] = $Snapshot[$key] }
    $display.schemaVersion = '2.0'
    $display.rules = $rules; $display.categoryMap = $categoryMap; $display.collectorCategoryMap = $collectorMap
    $effortSource = if ([IO.Path]::GetFullPath($EffortConfigPath) -eq [IO.Path]::GetFullPath("$PSScriptRoot/../../config/effort.json")) { 'config/effort.json' } else { "Custom: $([IO.Path]::GetFileName($EffortConfigPath))" }
    $display.effort = [ordered]@{ categoryDefaults = $effort.categoryDefaults; ruleOverrides = $effort.ruleOverrides; source = $effortSource }
    $display.settings = @{ sharedOpportunityMinimum = $SharedOpportunityMinimum; quickWinThreshold = $QuickWinThreshold }
    $display.results = @($Snapshot.results | ForEach-Object {
        $record = [ordered]@{}
        foreach ($property in $_.PSObject.Properties) {
            if ($property.Name -notin 'displayName','severity','description','recommendation','documentation','references') { $record[$property.Name] = $property.Value }
        }
        if ($categoryMap.Contains([string]$record.category)) { $record.category = $categoryMap[$record.category] }
        $record
    })
    $compact = @($History.snapshots | ForEach-Object {
        $source = $_
        [ordered]@{
            runId = $source.runId; timestamp = $source.timestamp; organization = $source.organization
            module = @{ version = $source.module.version }; rulesetHash = $source.configuration.rulesetHash
            configurationHash = $source.configurationHash
            configuration = @{ baseline = $source.configuration.baseline; rulesetHash = $source.configuration.rulesetHash }
            collection = $source.collection; evaluation = $source.evaluation
            evaluatedRules = @($source.evaluatedRules); evaluatedResourceCount = @($source.evaluatedResources).Count
            legacy = [bool]$source.legacy; coverage = $source.coverage
            identityIncomplete = @($source.results | Where-Object { $_.identityComplete -ne $true } | Select-Object -ExpandProperty fingerprint -Unique)
            results = @($source.results | ForEach-Object {
                $category = if ($categoryMap.Contains($_.category)) { $categoryMap[$_.category] } else { $_.category }
                ,@($_.fingerprint, $_.project, $category, $_.ruleName, $_.outcome)
            })
        }
    })
    $display.history = @{ schemaVersion = '2.0'; snapshots = $compact; limitations = @($History.limitations) }
    $display
}

function ConvertTo-ProjectHealthHtml {
    param($Value)
    [Net.WebUtility]::HtmlEncode([string]$Value)
}
function Get-ProjectHealthStaticHtml {
    param($Snapshot, $Display)
    $encode = { param($value) ConvertTo-ProjectHealthHtml $value }
    $rows = @($Snapshot.results | Where-Object project -ne '(organization)')
    $stats = Get-AssessmentStatistics $rows
    $compliance = if ($null -eq $stats.compliance) { 'Unavailable' } else { "$($stats.compliance)%" }
    $header = "<h1>Project Health &amp; Compliance</h1><p>$(& $encode $Snapshot.organization) · $(& $encode $Snapshot.runId) · $(& $encode $Snapshot.timestamp) · PSRule.Rules.AzureDevOps $(& $encode $Snapshot.module.version) · $(& $encode $Snapshot.configuration.baseline)</p>"
    $html = [Text.StringBuilder]::new()
    $confidence = 'Limited'
    $projectNames = @(@($rows.project) + @($Snapshot.collection.Projects.Project) | Where-Object { $_ -and $_ -ne '(organization)' } | Sort-Object -Unique)
    $missingScopes = 0
    foreach ($project in $projectNames) {
        $collectors = @(@($Snapshot.collection.Projects | Where-Object Project -eq $project).Collectors)
        foreach ($command in $Display.collectorCategoryMap.Keys) {
            $evidence = @($collectors | Where-Object Command -eq $command)
            if ($evidence.Count -ne 1 -or ($evidence[0].Status -ne 'Completed' -and -not ($evidence[0].Status -eq 'Empty' -and 'EmptyCollection' -in $evidence[0].ReasonCodes))) { $missingScopes++ }
        }
    }
    if ($projectNames.Count -and $missingScopes -eq 0 -and $Snapshot.collection.Status -eq 'Complete' -and $Snapshot.evaluation.Status -eq 'Completed' -and $stats.errors -eq 0) { $confidence = 'Complete' }
    $weakest = $Display.results | Where-Object project -ne '(organization)' | Group-Object category | ForEach-Object {
        $s = Get-AssessmentStatistics @($_.Group)
        if ($null -ne $s.compliance) { [pscustomobject]@{ Category=$_.Name; Compliance=$s.compliance } }
    } | Sort-Object Compliance | Select-Object -First 1
    $null = $html.Append('<h2>How are our Team Projects doing?</h2><div class="ph-kpis">')
    foreach ($item in @(@('Project compliance', $compliance), @('Projects assessed', @($rows.project | Sort-Object -Unique).Count), @('Weakest category', $(if ($weakest) { $weakest.Category } else { 'Unavailable' })), @('Assessment confidence', $confidence))) {
        $null = $html.Append("<article><h3>$(& $encode $item[0])</h3><strong>$(& $encode $item[1])</strong></article>")
    }
    $null = $html.Append("</div><p>$($stats.passed) pass · $($stats.failed) fail · $($stats.ignored) ignored · $($stats.errors) errors. Compliance = Pass ÷ (Pass + Fail). Other outcomes are excluded from the denominator.</p>")
    $categories = @(@('Repos','Pipelines','Service Connections','Environments','Variable Groups','Projects','Retention Settings') + @($Display.results.category | Where-Object { $_ -ne 'Organization' }) | Select-Object -Unique)
    $null = $html.Append('<section class="ph-panel"><h3>Team Project ranking × category</h3><div class="ph-scroll"><table><thead><tr><th>Team Project</th><th>Overall</th>')
    foreach ($category in $categories) { $null = $html.Append("<th>$(& $encode $category)</th>") }
    $null = $html.Append('</tr></thead><tbody>')
    $projects = @(@($rows.project) + @($Snapshot.collection.Projects.Project) | Where-Object { $_ -and $_ -ne '(organization)' } | Sort-Object -Unique)
    foreach ($project in $projects) {
        $projectRows = @($Display.results | Where-Object project -eq $project)
        $projectStats = Get-AssessmentStatistics $projectRows
        $value = if ($null -eq $projectStats.compliance) { 'Unavailable' } else { "$($projectStats.compliance)%" }
        $null = $html.Append("<tr><th>$(& $encode $project)</th><td>$value</td>")
        foreach ($category in $categories) {
            $commands = @($Display.collectorCategoryMap.Keys | Where-Object { $Display.collectorCategoryMap[$_] -eq $category })
            $projectEvidence = @($Snapshot.collection.Projects | Where-Object Project -eq $project)
            $collectors = @($projectEvidence.Collectors | Where-Object Command -in $commands)
            $valid = $commands.Count -gt 0 -and $collectors.Count -eq $commands.Count -and @($collectors | Where-Object { $_.Status -ne 'Completed' -and -not ($_.Status -eq 'Empty' -and 'EmptyCollection' -in $_.ReasonCodes) }).Count -eq 0
            $cellRows = @($projectRows | Where-Object category -eq $category)
            $cellStats = Get-AssessmentStatistics $cellRows
            $cell = 'n/c'; $class = 'ph-uncollected'
            if ($valid) {
                if (@($collectors | Where-Object { $_.Status -ne 'Empty' }).Count -eq 0 -and $cellRows.Count -eq 0) { $cell = 'n/a'; $class = '' }
                elseif (@($collectors | Where-Object { $_.Status -ne 'Empty' }).Count -eq 0) { $cell = 'n/c'; $class = 'ph-uncollected' }
                elseif ($null -ne $cellStats.compliance) { $cell = "$($cellStats.compliance)%"; $class = '' }
                else { $cell = '—'; $class = '' }
            }
            $null = $html.Append("<td class='$class'>$cell</td>")
        }
        $null = $html.Append('</tr>')
    }
    $null = $html.Append('</tbody></table></div><p>n/c: not collected or missing status. n/a: Empty with EmptyCollection; no resources. Neither means passing.</p></section>')
    $null = $html.Append('<section class="ph-panel"><h3>Organization-wide controls</h3><p>Not attributed to any Team Project.</p><ul>')
    foreach ($record in @($Snapshot.results | Where-Object project -eq '(organization)')) {
        $null = $html.Append("<li>$(& $encode $record.ruleName): $(& $encode $record.outcome)</li>")
    }
    $null = $html.Append('</ul></section><section class="ph-panel" id="ph-static-findings"><h3>Findings and all outcomes</h3>')
    foreach ($group in @($Snapshot.results | Group-Object ruleName)) {
        $rule = $Display.rules[$group.Name]
        $null = $html.Append("<details><summary>$(& $encode $group.Name) · $($group.Count) checkpoints</summary><p>$(& $encode $rule.description)</p><p>Recommendation: $(& $encode $rule.recommendation)</p>")
        if ($rule.documentation -match '^https?://') { $null = $html.Append("<a href='$(& $encode $rule.documentation)' target='_blank' rel='noopener'>Rule documentation</a>") }
        foreach ($record in $group.Group) {
            $null = $html.Append("<details><summary>$(& $encode $record.project) › $(& $encode $record.resourceName) · $(& $encode $record.outcome)</summary><p>$(& $encode $record.reason)</p></details>")
        }
        $null = $html.Append('</details>')
    }
    $null = $html.Append('</section>')
    @{ Header = $header; Health = $html.ToString() }
}
