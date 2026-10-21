[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [object[]]$Results,
    [Parameter(Mandatory)]
    [string]$Organization,
    [Parameter(Mandatory)]
    [string]$RunId,
    [datetime]$Timestamp = [datetime]::UtcNow,
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    $Collection,
    $Configuration,
    $Evaluation,
    [string]$ModuleVersion = 'Unknown',
    [string]$RuleHelpPath,
    [string]$HistoryPath
)
$ErrorActionPreference = 'Stop'
function ConvertTo-SummaryText {
    param([string]$Value)
    $text = [Net.WebUtility]::HtmlEncode(($Value -replace '[\r\n]+', ' '))
    return $text -replace '[\\`*_{}\[\]()|]', '\$0'
}
. "$PSScriptRoot/AssessmentModel.ps1"
$report = New-AssessmentSnapshot -Results $Results -Organization $Organization -RunId $RunId -Timestamp $Timestamp -Collection $Collection -Configuration $Configuration -Evaluation $Evaluation -ModuleVersion $ModuleVersion -RuleHelpPath $RuleHelpPath
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
$report.history = $history
# Escape HTML-sensitive characters so result text cannot terminate the JSON script element.
$json = ConvertTo-Json -InputObject $report -Depth 30 -Compress -EscapeHandling EscapeHtml
$template = Get-Content "$PSScriptRoot/../templates/psrule-dashboard.html" -Raw
# Insert data last so assessment text that resembles a template marker stays literal.
$html = $template.Replace('__DASHBOARD_CSS__', (Get-Content "$PSScriptRoot/../templates/assessment.css" -Raw)).Replace('__DASHBOARD_JS__', (Get-Content "$PSScriptRoot/../templates/assessment.js" -Raw)).Replace('__REPORT_DATA__', $json)
$summary = @(
    '# PSRule Dashboard'
    ''
    "Organization: $(ConvertTo-SummaryText $Organization)"
    ''
    "Run: $(ConvertTo-SummaryText $RunId) | Assessed: $timestampText"
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
    } else { '| No failures | 0 |' }
    ''
    'Showing up to 10 rules. The HTML dashboard contains all assessed checkpoints.'
    ''
    'Open the PSRule Dashboard report on this run, or download psrule-dashboard.html from the psrule-results artifact.'
    ''
    'This report describes the assessment only. Check the pipeline status for workbook publication errors.'
) -join "`n"
New-Item $OutputDirectory -ItemType Directory -Force | Out-Null
Set-Content (Join-Path $OutputDirectory 'psrule-dashboard.html') -Value $html -Encoding utf8
Set-Content (Join-Path $OutputDirectory 'psrule-summary.md') -Value $summary -Encoding utf8

# The persisted snapshot excludes the aggregated history to avoid recursive growth.
$report.Remove('history')
$report | ConvertTo-Json -Depth 30 -EscapeHandling EscapeHtml | Set-Content (Join-Path $OutputDirectory 'assessment-snapshot.json') -Encoding utf8
