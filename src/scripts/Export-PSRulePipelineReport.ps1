[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [object[]]$Results,
    [Parameter(Mandatory)]
    [string]$Organization,
    [Parameter(Mandatory)]
    [string]$RunId,
    [object]$CollectionStatus,
    [datetime]$Timestamp = [datetime]::UtcNow,
    [Parameter(Mandatory)]
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
function Get-ReportText {
    param($Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return 'Unknown' }
    return [string]$Value
}
function ConvertTo-SummaryText {
    param([string]$Value)
    $text = [Net.WebUtility]::HtmlEncode(($Value -replace '[\r\n]+', ' '))
    return $text -replace '[\\`*_{}\[\]()|]', '\$0'
}
$records = @($Results | ForEach-Object {
    $id = $_.TargetObject.id
    if ($id -isnot [pscustomobject] -and $id -isnot [Collections.IDictionary]) { $id = $_.Field.id }
    if ($id -is [string]) {
        try { $id = $id | ConvertFrom-Json -ErrorAction Stop } catch { $id = $null }
    }
    [pscustomobject][ordered]@{
        ruleName = Get-ReportText $_.RuleName
        displayName = Get-ReportText $_.Info.DisplayName
        targetName = Get-ReportText $_.TargetName
        targetType = Get-ReportText $_.TargetType
        outcome = Get-ReportText $_.Outcome
        severity = Get-ReportText $_.Info.Annotations.severity
        project = Get-ReportText $id.project
        resourceName = Get-ReportText $id.resourceName
    }
})
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
$counts = [ordered]@{
    'Total checkpoints' = $records.Count
    'Passed checkpoints' = @($records | Where-Object outcome -eq 'Pass').Count
    'Failed checkpoints' = @($records | Where-Object outcome -eq 'Fail').Count
    'Rules checked' = @($records.ruleName | Sort-Object -Unique).Count
    'Resources checked' = @($records | Select-Object project, targetType, targetName -Unique).Count
}
$timestampText = $Timestamp.ToUniversalTime().ToString('o')
$report = [ordered]@{ organization = $Organization; runId = $RunId; timestamp = $timestampText; collectionIncomplete = [bool]$collectionIncomplete; collectionIssues = $collectionIssues; results = $records }
# Escape HTML-sensitive characters so result text cannot terminate the JSON script element.
$json = ConvertTo-Json -InputObject $report -Depth 8 -Compress -EscapeHandling EscapeHtml
$template = Get-Content "$PSScriptRoot/../templates/psrule-dashboard.html" -Raw
$html = $template.Replace('__REPORT_DATA__', $json)
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
