
<#
.SYNOPSIS
    Analyzes Azure DevOps exported data with PSRule and sends results to Azure Log Analytics.

.DESCRIPTION
    This function loads required PSRule modules, prepares necessary variables, analyzes
    exported Azure DevOps JSON reports using PSRule rules, and sends the evaluation results
    to Azure Log Analytics.

.PARAMETER LogAnalyticsWorkspaceId
    The workspace ID for the Azure Log Analytics workspace.

.PARAMETER LogAnalyticsSharedKey
    The shared key for authenticating with the Azure Log Analytics workspace.

.PARAMETER ReportOutputPath
    The path where the exported JSON report files are stored.

.EXAMPLE
    $psRuleAnalysisParams = @{
        LogAnalyticsWorkspaceId = 'xxxxx'
        LogAnalyticsSharedKey   = 'yyyyy'
        ReportOutputPath        = '$(Build.ArtifactStagingDirectory)/export'
    }

    Invoke-AzDevOpsPSRuleAnalysis @psRuleAnalysisParams
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [System.String]$LogAnalyticsWorkspaceId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [System.String]$LogAnalyticsSharedKey,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [System.String]$ReportOutputPath,

    [string]$Organization = $env:PSRULE_ORGANIZATION
)

Begin {
    Write-Host "##[group]Importing PowerShell Modules"

    try {
        $importModuleParams = @{
            Name        = 'PSRule.Monitor'
            Force       = $true
            ErrorAction = 'Stop'
        }
        Import-Module @importModuleParams
        Write-Host "PSGallery modules imported."
    }
    catch {
        throw "Failed to import PSRule.Monitor module: $($_.Exception.Message)"
    }

    Write-Host "##[endgroup]"

    # Set up error handling preferences
    $ErrorActionPreference = 'Continue'
    $WarningPreference = 'Continue'
}

Process {
    Write-Host "##[group]Prepare variables"

    # Variables are already passed in from pipeline or task
    Write-Verbose "WorkspaceId and SharedKey retrieved from pipeline variables."
    Write-Verbose "Report output path is [$ReportOutputPath]."
    Write-Host "##[endgroup]"

    #region Analyze Azure DevOps Data
    Write-Host "##[group]Analyzing Azure DevOps Data"
    Write-Host "##[section]Starting PSRule Analysis Process"

    # Enable TLS 1.2
    Write-Verbose "Enforcing TLS 1.2 for secure connections."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Get all directories with JSON files
    Write-Host "Scanning for JSON files in: $ReportOutputPath"
    Write-Host "##[debug]Using path: $ReportOutputPath"

    if (-not (Test-Path -Path $ReportOutputPath)) {
        throw "Report output path does not exist: $ReportOutputPath"
    }

    $getChildItemParams = @{
        Path    = $ReportOutputPath
        Filter  = '*.json'
        File    = $true
        Recurse = $true
    }
    $jsonFiles = @(Get-ChildItem @getChildItemParams | Where-Object { $_.Name -notin 'assessment-snapshot.json', 'assessment-history.json', 'collection-status.json' })

    if ($jsonFiles.Count -eq 0) {
        Write-Output "##vso[task.logissue type=warning]No JSON files found in: $ReportOutputPath"
        Write-Host "##[warning]No data available for PSRule analysis."
        return
    }    Write-Host "Found $($jsonFiles.Count) JSON file(s) for analysis."
    Write-Output "##vso[task.setprogress value=25;]Found $($jsonFiles.Count) JSON files"

    # Validate JSON files and filter out problematic ones
    $validJsonFiles = @()
    foreach ($jsonFile in $jsonFiles) {
        try {
            $getContentParams = @{
                Path        = $jsonFile.FullName
                Raw         = $true
                ErrorAction = 'Stop'
            }
            $content = Get-Content @getContentParams

            if (-not [string]::IsNullOrWhiteSpace($content)) {
                # Try to parse the JSON to validate it
                $null = $content | ConvertFrom-Json -ErrorAction Stop
                $validJsonFiles += $jsonFile.FullName
            }
            else {
                Write-Output "##vso[task.logissue type=warning]Skipping empty JSON file: $($jsonFile.FullName)"
            }
        }
        catch {
            $fileName = $jsonFile.FullName
            $errorMessage = $_.Exception.Message
            Write-Output "##vso[task.logissue type=warning;sourcepath=$fileName]Invalid JSON file: $errorMessage"
        }
    }    if ($validJsonFiles.Count -eq 0) {
        Write-Output "##vso[task.logissue type=warning]No valid JSON files found for analysis."
        Write-Host "##[warning]All JSON files were invalid or empty."
        return
    }    Write-Host "Validated $($validJsonFiles.Count) JSON file(s) for PSRule analysis."
    Write-Output "##vso[task.setprogress value=40;]Validated $($validJsonFiles.Count) JSON files"

    # Run PSRule evaluation with error handling
    $evaluationFailed = $false
    try {
        $invokeParams = @{
            Module        = @('PSRule.Rules.AzureDevOps', 'PSRule.Monitor')
            InputPath     = $validJsonFiles
            As            = 'Detail'
            OutputPath    = (Join-Path $ReportOutputPath 'psrule-results.sarif')
            OutputFormat  = 'Sarif'
            ResultVariable = 'assessmentResults'
            Format        = 'Detect'
            Culture       = 'en'
            ErrorAction   = 'SilentlyContinue'
            ErrorVariable = 'assessmentErrors'
            WarningAction = 'Continue'
        }

        Write-Host "Running PSRule evaluation..."
        Write-Output "##vso[task.setprogress value=60;]Running PSRule evaluation"
        $null = Assert-PSRule @invokeParams
        $result = @($assessmentResults | Where-Object { $null -ne $_ })
        foreach ($record in $assessmentErrors) {
            if ($record.FullyQualifiedErrorId -eq 'PSRule.Fail,Assert-PSRule') { continue }
            if ($record.FullyQualifiedErrorId -eq 'VariableNotFound,Microsoft.PowerShell.Commands.GetVariableCommand' -and $record.TargetObject -eq 'PSModuleAutoLoadingPreference' -and $record.InvocationInfo.ScriptName -match '[/\\]PSRule\.psm1$') { continue }
            throw $record
        }

        if ($null -eq $result -or $result.Count -eq 0) {
            $warningMessage = "No PSRule results were generated. " + `
                "This might indicate issues with the input files or rules."
            Write-Output "##vso[task.logissue type=warning]$warningMessage"
            return
        }        Write-Host "PSRule evaluation completed successfully. Generated $($result.Count) result(s)."
        Write-Output "##vso[task.setprogress value=80;]Generated $($result.Count) PSRule results"
    }
    catch {
        $errorMessage = $_.Exception.Message
        $evaluationFailed = $true
        Write-Output "##vso[task.logissue type=error]PSRule evaluation failed with error: $errorMessage"
        Write-Host "##[warning]PSRule evaluation encountered errors. Some data may not be processed correctly."

        # Try to continue with any partial results
        if ($null -ne $result -and $result.Count -gt 0) {
            Write-Host "##[warning]Proceeding with $($result.Count) partial result(s)."
        }
        else {
            Write-Output "##vso[task.logissue type=error]No results available to send to Log Analytics."
            return
        }
    }

    # Save complete current-run evidence before attempting Monitor ingestion.
    $runOrganization = if ($Organization) { $Organization } else { 'Unknown' }
    $runId = "$runOrganization/$($env:BUILD_BUILDID)"
    $collectionPath = Join-Path (Split-Path $ReportOutputPath) 'collection-status.json'
    $collection = if (Test-Path $collectionPath) { Get-Content $collectionPath -Raw | ConvertFrom-Json } else { @{ Status = 'Unknown'; Projects = @() } }
    if ($validJsonFiles.Count -lt $jsonFiles.Count) { $collection.Status = 'Partial' }
    $historyPath = Join-Path $ReportOutputPath 'assessment-history.json'
    if ($env:SYSTEM_TEAMPROJECT -and $env:SYSTEM_DEFINITIONID) {
        $null = & "$PSScriptRoot/Get-AssessmentHistory.ps1" -Organization $runOrganization -Project $env:SYSTEM_TEAMPROJECT -DefinitionId ([int]$env:SYSTEM_DEFINITIONID) -Branch $env:BUILD_SOURCEBRANCH -CurrentBuildId ([int]$env:BUILD_BUILDID) -OutputPath $historyPath
    }
    $module = Get-Module PSRule.Rules.AzureDevOps | Select-Object -First 1
    $evaluationStatus = @{ Status = $(if ($evaluationFailed -or @($result | Where-Object Outcome -eq 'Error').Count) { 'Failed' } else { 'Completed' }) }
    & "$PSScriptRoot/Export-PSRulePipelineReport.ps1" -Evaluation $evaluationStatus -Results @($result) -Organization $runOrganization -RunId $runId -OutputDirectory $ReportOutputPath -Collection $collection -ModuleVersion ([string]$module.Version) -RuleHelpPath (Join-Path $module.ModuleBase 'en') -HistoryPath $historyPath
    Write-Host "##vso[task.uploadsummary]$(Join-Path $ReportOutputPath 'psrule-summary.md')"
    Write-Host '##vso[task.setvariable variable=PSRuleReportReady]true'
    if ($evaluationFailed -or @($result | Where-Object Outcome -eq 'Error').Count) { throw 'Assessment execution errors; reports retained.' }
    if ($collection.Status -ne 'Complete') { throw 'Collection is incomplete or unknown; reports retained and ingestion blocked.' }

    # Send results to Log Analytics with error handling
    try {
        Write-Host "Sending results to Log Analytics..."
        Write-Output "##vso[task.setprogress value=90;]Sending results to Log Analytics"

        $sendParams = @{
            WorkspaceId = $LogAnalyticsWorkspaceId
            SharedKey   = $LogAnalyticsSharedKey
            LogName     = 'PSRule'
        }

        $result | Send-PSRuleMonitorRecord @sendParams
        Write-Host "Results successfully sent to Log Analytics."
        Write-Output "##vso[task.setprogress value=100;]Results sent to Log Analytics"
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Output "##vso[task.logissue type=error]Failed to send results to Log Analytics: $errorMessage"
        Write-Output "##vso[task.complete result=Failed;]Failed to send PSRule results to Log Analytics"
    }

    Write-Host "##[endgroup]"
    #endregion
}

End {
    Write-Verbose 'PSRule analysis and export to Log Analytics completed.'

}
