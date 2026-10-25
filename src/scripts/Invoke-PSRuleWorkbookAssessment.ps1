[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$ModuleManifestPath,
    [string]$Organization = 'ai-experiments',
    [string]$OrganizationId,
    [string]$ResourceGroupName = 'rg-psrule-azuredevops-weu',
    [switch]$ReportOnly
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/AssessmentModel.ps1"
function Get-AssessmentModuleVersion {
    param([string]$ManifestPath)
    if (Test-Path -LiteralPath $ManifestPath) { return [string](Import-PowerShellDataFile -LiteralPath $ManifestPath).ModuleVersion }
    return 'Unknown'
}
if (-not (Get-Module -ListAvailable PSRule | Where-Object Version -eq ([version]'2.9.0'))) {
    Install-Module PSRule -RequiredVersion 2.9.0 -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module PSRule -RequiredVersion 2.9.0 -Force
Import-Module $ModuleManifestPath -Force
$accessToken = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $accessToken) { throw 'Could not acquire Azure DevOps authentication.' }
if (-not $OrganizationId) {
    $connectionData = Invoke-RestMethod -Uri "https://dev.azure.com/$([uri]::EscapeDataString($Organization))/_apis/connectionData" -Headers @{ Authorization = "Bearer $accessToken" }
    $OrganizationId = $connectionData.instanceId
    if (-not ($OrganizationId -as [guid])) { throw 'Could not resolve the Azure DevOps organization instance ID.' }
}
Connect-AzDevOps -Organization $Organization -OrganizationId $OrganizationId -AccessToken $accessToken
$exportPath = Join-Path $env:PIPELINE_WORKSPACE "psrule-export-$($env:BUILD_BUILDID)-$([guid]::NewGuid().ToString('N'))"
New-Item $exportPath -ItemType Directory -Force | Out-Null
$completenessReportPath = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'collection-status.json'
Export-AzDevOpsOrganizationRuleData -Organization $Organization -OrganizationId $OrganizationId -OutputPath $exportPath -CompletenessReportPath $completenessReportPath
$collection = if (Test-Path $completenessReportPath) { Get-Content $completenessReportPath -Raw | ConvertFrom-Json } else { @{ Status = 'Unknown'; Projects = @() } }
# Organization exports live in project subfolders; select actual files recursively.
$inputFiles = @(Get-ChildItem $exportPath -File -Recurse -Filter '*.json' | Select-Object -ExpandProperty FullName)
if ($inputFiles.Count -eq 0) { throw 'The organization export produced no JSON input files.' }
$reportPath = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'psrule-results.sarif'
# Capture expected assertion failures without interrupting PSRule's result writer.
$option = New-PSRuleOption -OutputStyle Plain -OutputAs Detail
$evaluationResults = $null
$evaluationErrors = @()
$terminatingEvaluationError = $null
try {
    $null = Assert-PSRule -InputPath $inputFiles -Module PSRule.Rules.AzureDevOps -Baseline Baseline.Default -Culture en -Style Plain -As Detail -Option $option -OutputPath $reportPath -OutputFormat Sarif -ResultVariable evaluationResults -ErrorAction SilentlyContinue -ErrorVariable evaluationErrors
} catch { $terminatingEvaluationError = $_ }
$fatalEvaluationErrors = @()
if ($terminatingEvaluationError) { $fatalEvaluationErrors += $terminatingEvaluationError }
foreach ($errorRecord in $evaluationErrors) {
    if ($errorRecord.FullyQualifiedErrorId -eq 'PSRule.Fail,Assert-PSRule') { continue }
    # PSRule 2.9 probes this optional preference; an unset value means default autoloading.
    if ($errorRecord.FullyQualifiedErrorId -eq 'VariableNotFound,Microsoft.PowerShell.Commands.GetVariableCommand' -and $errorRecord.TargetObject -eq 'PSModuleAutoLoadingPreference' -and $errorRecord.InvocationInfo.ScriptName -match '[/\\]PSRule\.psm1$') { continue }
    $fatalEvaluationErrors += $errorRecord
}
$results = @($evaluationResults | Where-Object { $null -ne $_ })
if ($results.Count -eq 0) { throw 'The assessment evaluated zero rule results; nothing was published.' }
$hasExecutionErrors = @($results | Where-Object Outcome -eq 'Error').Count -gt 0
$failedCount = @($results | Where-Object Outcome -eq 'Fail').Count
Write-Host "Assessment evaluated $($results.Count) results, including $failedCount failures."
$runId = "$Organization/$($env:BUILD_BUILDID)"
# Retain run reports even if Azure workbook publication fails afterwards.
$historyPath = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'assessment-history.json'
if ($env:SYSTEM_TEAMPROJECT -and $env:SYSTEM_DEFINITIONID) {
    $null = & "$PSScriptRoot/Get-AssessmentHistory.ps1" -Organization $Organization -Project $env:SYSTEM_TEAMPROJECT -DefinitionId ([int]$env:SYSTEM_DEFINITIONID) -Branch $env:BUILD_SOURCEBRANCH -CurrentBuildId ([int]$env:BUILD_BUILDID) -OutputPath $historyPath
}
$moduleVersion = Get-AssessmentModuleVersion -ManifestPath $ModuleManifestPath
$configuration = Get-AssessmentConfiguration -ModuleManifestPath $ModuleManifestPath -Baseline 'Baseline.Default' -Option $option -PSRuleVersion '2.9.0'
$evaluationStatus = @{ Status = $(if ($hasExecutionErrors -or $fatalEvaluationErrors.Count) { 'Failed' } else { 'Completed' }); ErrorCount = $fatalEvaluationErrors.Count + @($results | Where-Object Outcome -eq 'Error').Count }
& "$PSScriptRoot/Export-PSRulePipelineReport.ps1" -Evaluation $evaluationStatus -Results $results -Organization $Organization -RunId $runId -OutputDirectory $env:BUILD_ARTIFACTSTAGINGDIRECTORY -Collection $collection -Configuration $configuration -ModuleVersion $moduleVersion -RuleHelpPath (Join-Path (Split-Path ([IO.Path]::GetFullPath($ModuleManifestPath))) 'en') -HistoryPath $historyPath
Write-Host "##vso[task.uploadsummary]$(Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'psrule-summary.md')"
Write-Host '##vso[task.setvariable variable=PSRuleReportReady]true'
if ($hasExecutionErrors -or $fatalEvaluationErrors.Count) { throw 'The assessment encountered rule execution errors; inspect the retained assessment report.' }
if ($collection.Status -ne 'Complete') { throw 'Collection is incomplete or unknown; current evidence was retained and workbook publication was blocked.' }
if ($ReportOnly) { Write-Host 'Report-only assessment complete; workbook publishing was not requested.'; return }
$outputs = az deployment group show --resource-group $ResourceGroupName --name psrule-workbooks --query properties.outputs -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the dashboard ingestion configuration.' }
& "$PSScriptRoot/Publish-PSRuleWorkbookResults.ps1" -Results $results -RunId $runId -IngestionEndpoint $outputs.ingestionEndpoint.value -RuleImmutableId $outputs.ingestionRuleImmutableId.value
$queryToken = az account get-access-token --resource https://api.loganalytics.io --query accessToken -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Could not acquire query authentication.' }
$queryUri = "https://api.loganalytics.azure.com/v1/workspaces/$($outputs.workspaceId.value)/query"
$query = "PSRule_CL | where RunId_s == '$runId' | summarize Records=count(), Failed=countif(Outcome_s == 'Fail'), Passed=countif(Outcome_s == 'Pass')"
$verified = $false
for ($attempt = 0; $attempt -lt 45; $attempt++) {
    $response = Invoke-RestMethod -Method Post -Uri $queryUri -Headers @{Authorization = "Bearer $queryToken"} -ContentType 'application/json' -Body (@{query=$query} | ConvertTo-Json -Compress)
    $counts = $response.tables[0].rows[0]
    if ($counts[0] -eq $results.Count -and $counts[1] -eq $failedCount) {
        Write-Host "Verified published assessment $runId in Log Analytics: total=$($counts[0]), failed=$($counts[1]), passed=$($counts[2])."
        $verified = $true
        break
    }
    if ($counts[0] -gt $results.Count) { throw 'The published run contains unexpected duplicate records.' }
    Write-Host "Waiting for ingestion: $($counts[0])/$($results.Count) records visible."
    Start-Sleep -Seconds 20
}
if (-not $verified) { throw 'Ingestion verification timed out before all assessment results appeared.' }
