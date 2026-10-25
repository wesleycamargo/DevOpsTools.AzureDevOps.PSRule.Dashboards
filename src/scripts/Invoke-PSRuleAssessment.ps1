[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$ModuleVersion,
    [string]$Organization = 'ai-experiments',
    [string]$OrganizationId = '3b022c28-683d-4d7e-87a5-bd8198332011'
)
$ErrorActionPreference = 'Stop'
$exportPath = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'raw-export'
$reportDirectory = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'reports'
# Self-hosted agents may reuse their workspace; never assess files from an earlier attempt.
foreach ($directory in @($exportPath, $reportDirectory)) {
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    New-Item $directory -ItemType Directory -Force | Out-Null
}
if (-not (Get-Module -ListAvailable PSRule | Where-Object Version -eq ([version]'2.9.0'))) {
    Install-Module PSRule -RequiredVersion 2.9.0 -Repository PSGallery -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module PSRule -RequiredVersion 2.9.0 -Force
Install-Module DevOpsTools.AzureDevOps.Assessment -RequiredVersion $ModuleVersion -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
Import-Module DevOpsTools.AzureDevOps.Assessment -RequiredVersion $ModuleVersion -Force
Write-Host "Assessment module: DevOpsTools.AzureDevOps.Assessment $ModuleVersion (PSGallery)."
$accessToken = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $accessToken) { throw 'Could not acquire Azure DevOps authentication.' }
Connect-AzDevOps -Organization $Organization -OrganizationId $OrganizationId -AccessToken $accessToken
function Write-CollectionWarning {
    param([string]$Message)
    $escaped = $Message.Replace('%', '%AZP25').Replace("`r", '%0D').Replace("`n", '%0A')
    Write-Host "##vso[task.logissue type=warning;]$escaped"
}
$collectionStatusPath = Join-Path $reportDirectory 'collection-status.json'
# Only collection's non-terminating errors become warnings; terminating failures still propagate.
Export-AzDevOpsOrganizationRuleData -Organization $Organization -OrganizationId $OrganizationId -OutputPath $exportPath -CompletenessReportPath $collectionStatusPath 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-CollectionWarning ([string]$_) }
}
$collectionStatus = Get-Content -LiteralPath $collectionStatusPath -Raw | ConvertFrom-Json
if ($collectionStatus.SchemaVersion -ne 1 -or $collectionStatus.Status -notin @('Complete', 'Partial', 'Unavailable')) {
    throw 'Invalid collection completeness report.'
}
$collectionIncomplete = $collectionStatus.Status -ne 'Complete'
# Organization exports live in project subfolders; select actual files recursively.
$inputFiles = @(Get-ChildItem $exportPath -File -Recurse -Filter '*.json' | Select-Object -ExpandProperty FullName)

$reportPath = Join-Path $reportDirectory 'psrule-results.sarif'
# Capture expected assertion failures without interrupting PSRule's result writer.
$option = New-PSRuleOption -OutputStyle Plain -OutputAs Detail
$evaluationResults = $null
$evaluationErrors = @()
if ($inputFiles.Count) {
    $null = Assert-PSRule -InputPath $inputFiles -Module DevOpsTools.AzureDevOps.Assessment -Baseline Baseline.Default -Culture en -Style Plain -As Detail -Option $option -OutputPath $reportPath -OutputFormat Sarif -ResultVariable evaluationResults -ErrorAction SilentlyContinue -ErrorVariable evaluationErrors
    foreach ($errorRecord in $evaluationErrors) {
        if ($errorRecord.FullyQualifiedErrorId -eq 'PSRule.Fail,Assert-PSRule') { continue }
        # PSRule 2.9 probes this optional preference; an unset value means default autoloading.
        if ($errorRecord.FullyQualifiedErrorId -eq 'VariableNotFound,Microsoft.PowerShell.Commands.GetVariableCommand' -and $errorRecord.TargetObject -eq 'PSModuleAutoLoadingPreference' -and $errorRecord.InvocationInfo.ScriptName -match '[/\\]PSRule\.psm1$') { continue }
        throw $errorRecord
    }
}
$results = @($evaluationResults | Where-Object { $null -ne $_ })
if ($results.Count -eq 0 -and (Test-Path -LiteralPath $reportPath)) { Remove-Item -LiteralPath $reportPath -Force }
if (@($results | Where-Object Outcome -eq 'Error').Count) { throw 'The assessment encountered rule execution errors.' }
$failedCount = @($results | Where-Object Outcome -eq 'Fail').Count
Write-Host "Assessment evaluated $($results.Count) results, including $failedCount failures."
$runId = "$Organization/$($env:BUILD_BUILDID)"
# Generate the dashboard entirely within this pipeline run.
& "$PSScriptRoot/Export-PSRulePipelineReport.ps1" -Results $results -Organization $Organization -RunId $runId -OutputDirectory $reportDirectory -CollectionStatus $collectionStatus
Write-Host "##vso[task.uploadsummary]$(Join-Path $reportDirectory 'psrule-summary.md')"
Write-Host '##vso[task.setvariable variable=PSRuleReportReady]true'

if ($collectionIncomplete -or $results.Count -eq 0) {
    Write-CollectionWarning 'Assessment coverage is incomplete or no assessment results are available. Review the dashboard and collection-status.json.'
    Write-Host '##vso[task.complete result=SucceededWithIssues;]'
}
