[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [object[]]$Results,
    [Parameter(Mandatory)]
    [string]$Organization,
    [Parameter(Mandatory)]
    [string]$RunId,
    [datetime]$Timestamp = [datetime]::UtcNow,
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    [Alias('CollectionStatus')]$Collection,
    $Configuration,
    $Evaluation,
    [string]$ModuleVersion = 'Unknown',
    [string]$ModuleName = 'PSRule.Rules.AzureDevOps',
    [string]$RuleHelpPath,
    [string]$HistoryPath,
    [string]$EffortConfigPath = "$PSScriptRoot/../../config/effort.json",
    [ValidateRange(1,1000)][int]$SharedOpportunityMinimum = 3,
    [ValidateRange(0,100)][double]$QuickWinThreshold = 70
)
$ErrorActionPreference = 'Stop'
function ConvertTo-SummaryText {
    param([string]$Value)
    $text = [Net.WebUtility]::HtmlEncode(($Value -replace '[\r\n]+', ' '))
    return $text -replace '[\\`*_{}\[\]()|]', '\$0'
}
. "$PSScriptRoot/AssessmentModel.ps1"
. "$PSScriptRoot/ProjectHealthReport.ps1"
$CollectionStatus = $Collection
$collectionIssues = @(
    if ($CollectionStatus.ProjectDiscovery -and $CollectionStatus.ProjectDiscovery.Status -notin @('Completed', 'Empty')) {
        [pscustomobject]@{ project = '(organization)'; collector = $CollectionStatus.ProjectDiscovery.Command; status = $CollectionStatus.ProjectDiscovery.Status; reasonCodes = @($CollectionStatus.ProjectDiscovery.ReasonCodes) }
    }
    foreach ($collector in $CollectionStatus.OrganizationCollection.Collectors) {
        if ($collector.Status -notin @('Completed', 'Empty')) {
            [pscustomobject]@{ project = '(organization)'; collector = $collector.Command; status = $collector.Status; reasonCodes = @($collector.ReasonCodes) }
        }
    }
    foreach ($project in $CollectionStatus.Projects) {
        if ($project.Status -ne 'Complete') {
            [pscustomobject]@{ project = $project.Project; collector = '(project)'; status = $project.Status; reasonCodes = @() }
        }
        foreach ($collector in $project.Collectors) {
            if ($collector.Status -notin @('Completed', 'Empty')) {
                [pscustomobject]@{ project = $project.Project; collector = $collector.Command; status = $collector.Status; reasonCodes = @($collector.ReasonCodes) }
            }
        }
    }
)
$collectionIncomplete = ($CollectionStatus -and $CollectionStatus.Status -ne 'Complete') -or $collectionIssues.Count -gt 0
$report = New-AssessmentSnapshot -Results $Results -Organization $Organization -RunId $RunId -Timestamp $Timestamp -Collection $Collection -Configuration $Configuration -Evaluation $Evaluation -ModuleVersion $ModuleVersion -ModuleName $ModuleName -RuleHelpPath $RuleHelpPath
$report.collectionIncomplete = [bool]$collectionIncomplete
$report.collectionIssues = $collectionIssues
$records = $report.results
$counts = [ordered]@{
    'Total checkpoints' = $records.Count
    'Passed checkpoints' = @($records | Where-Object outcome -eq 'Pass').Count
    'Failed checkpoints' = @($records | Where-Object outcome -eq 'Fail').Count
    'Ignored checkpoints' = $report.statistics.ignored
    'Error checkpoints' = $report.statistics.errors
    'Applicable checkpoints' = $report.statistics.applicable
    'Compliance (%)' = $(if ($null -eq $report.statistics.compliance) { 'Unavailable' } else { $report.statistics.compliance })
    'Rules checked' = $report.statistics.rules
    'Resources checked' = $report.statistics.resources
}
$timestampText = $Timestamp.ToUniversalTime().ToString('o')
$history = @{ schemaVersion = '1.0'; snapshots = @(); limitations = @('History is limited by pipeline artifact retention.') }
if ($HistoryPath -and (Test-Path -LiteralPath $HistoryPath)) {
    try {
        $candidate = Get-Content -LiteralPath $HistoryPath -Raw | ConvertFrom-Json -AsHashtable
        if ($candidate.schemaVersion -ne '1.0' -or -not $candidate.ContainsKey('snapshots')) { throw 'Unsupported history envelope.' }
        $history.limitations += @($candidate.limitations)
        $seenRuns = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($snapshot in $candidate.snapshots) {
            try {
                Assert-AssessmentSnapshot -Snapshot $snapshot -Organization $Organization
                if ($seenRuns.Add([string]$snapshot.runId)) { $history.snapshots += $snapshot }
            } catch { $history.limitations += "Historical snapshot excluded: $($_.Exception.Message)" }
        }
    } catch { $history.limitations += 'Historical dataset is unreadable or unsupported; current-run evidence is retained.' }
}
$display = Get-ProjectHealthDisplayData -Snapshot $report -History $history -EffortConfigPath $EffortConfigPath -SharedOpportunityMinimum $SharedOpportunityMinimum -QuickWinThreshold $QuickWinThreshold
$static = Get-ProjectHealthStaticHtml -Snapshot $report -Display $display
$diagnostics = @(
    if ($collectionIncomplete) {
        '<section class="ph-panel" id="ph-collection-diagnostics"><h2>Incomplete collection</h2><p>Missing collection data is not evidence of passing controls. Totals cover only the available evaluated data.</p><div class="ph-scroll"><table><thead><tr><th>Project</th><th>Collector</th><th>Status</th><th>Reason codes</th></tr></thead><tbody>'
        foreach ($issue in $collectionIssues) {
            "<tr><td>$(ConvertTo-ProjectHealthHtml $issue.project)</td><td>$(ConvertTo-ProjectHealthHtml $issue.collector)</td><td>$(ConvertTo-ProjectHealthHtml $issue.status)</td><td>$(ConvertTo-ProjectHealthHtml ($issue.reasonCodes -join ', '))</td></tr>"
        }
        '</tbody></table></div></section>'
    }
    if ($records.Count -eq 0) {
        '<section class="ph-panel" id="ph-no-results"><h2>No assessment results available</h2><p>Zero evaluated checkpoints. No compliance conclusion is available.</p></section>'
    }
) -join "`n"
# Escape HTML-sensitive characters so result text cannot terminate the JSON script element.
$json = ConvertTo-Json -InputObject $display -Depth 30 -Compress -EscapeHandling EscapeHtml
$template = Get-Content "$PSScriptRoot/../templates/psrule-dashboard.html" -Raw
# Replace template tokens once; tokens inside assessment text remain literal.
$parts = @{
    '__DASHBOARD_CSS__' = Get-Content "$PSScriptRoot/../templates/assessment.css" -Raw
    '__DASHBOARD_JS__' = Get-Content "$PSScriptRoot/../templates/assessment.js" -Raw
    '__COLLECTION_DIAGNOSTICS__' = $diagnostics
    '__STATIC_HEADER__' = $static.Header; '__STATIC_HEALTH__' = $static.Health; '__REPORT_DATA__' = $json
}
$html = [regex]::Replace($template, '__(?:DASHBOARD_CSS|DASHBOARD_JS|STATIC_HEADER|STATIC_HEALTH|COLLECTION_DIAGNOSTICS|REPORT_DATA)__', [Text.RegularExpressions.MatchEvaluator]{ param($match) [string]$parts[$match.Value] })
$summary = @(
    '# PSRule Dashboard'
    ''
    "Organization: $(ConvertTo-SummaryText $Organization)"
    ''
    "Run: $(ConvertTo-SummaryText $RunId) | Assessed: $timestampText"
    ''
    if ($collectionIncomplete) {
        '## Incomplete collection'
        ''
        'Missing collection data is not evidence of passing controls.'
        ''
        '| Project | Collector | Status | Reason codes |'
        '| --- | --- | --- | --- |'
        foreach ($issue in $collectionIssues) {
            "| $(ConvertTo-SummaryText $issue.project) | $(ConvertTo-SummaryText $issue.collector) | $(ConvertTo-SummaryText $issue.status) | $(ConvertTo-SummaryText ($issue.reasonCodes -join ', ')) |"
        }
        ''
    }
    if ($records.Count -eq 0) {
        '## No assessment results available'
        ''
        'Zero evaluated checkpoints. No compliance conclusion is available.'
        ''
    }
    'Totals cover only the available evaluated data.'
    ''
    '| Metric | Count |'
    '| --- | ---: |'
    $counts.GetEnumerator() | ForEach-Object { "| $($_.Key) | $($_.Value) |" }
    ''
    '## Failures by rule'
    ''
    '| Rule | Failed checkpoints |'
    '| --- | ---: |'
    $failedRules = @($records | Where-Object outcome -eq 'Fail' | Group-Object ruleName | Sort-Object -Property @{Expression = 'Count'; Descending = $true}, Name)
    if ($failedRules.Count) {
        $failedRules | Select-Object -First 10 | ForEach-Object { "| $(ConvertTo-SummaryText $_.Name) | $($_.Count) |" }
    } elseif ($records.Count) { '| No failures | 0 |' } else { '| No assessment results available | 0 |' }
    ''
    'Showing up to 10 rules. The HTML dashboard contains all assessed checkpoints.'
    ''
    'Open the PSRule Dashboard report on this run, or download psrule-dashboard.html from the psrule-results artifact.'
    ''
    'This report describes the assessment only. Check the pipeline status for report or artifact publication errors.'
) -join "`n"
New-Item $OutputDirectory -ItemType Directory -Force | Out-Null
Set-Content (Join-Path $OutputDirectory 'psrule-dashboard.html') -Value $html -Encoding utf8
Set-Content (Join-Path $OutputDirectory 'psrule-summary.md') -Value $summary -Encoding utf8

# The persisted snapshot excludes the aggregated history to avoid recursive growth.
$report | ConvertTo-Json -Depth 30 -EscapeHandling EscapeHtml | Set-Content (Join-Path $OutputDirectory 'assessment-snapshot.json') -Encoding utf8
