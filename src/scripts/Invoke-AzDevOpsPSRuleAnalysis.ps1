
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
    [System.String]$ReportOutputPath
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
    Write-Verbose "Report output path is [$ReportOutputPath]."    Write-Host "##[endgroup]"

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
    $jsonFiles = Get-ChildItem @getChildItemParams

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

    # Create input path array for PSRule
    $jsonFilesGlob = $validJsonFiles | ForEach-Object {
        Split-Path -Path $_ -Parent | Join-Path -ChildPath "*.json"
    } | Select-Object -Unique

    # Run PSRule assertions silently (no output)
    try {
        $assertParams = @{
            Module      = 'DevOpsTools.AzureDevOps.PSRule'
            InputPath   = $jsonFilesGlob
            ErrorAction = 'SilentlyContinue'
        }
        Assert-PSRule @assertParams
        Write-Verbose "PSRule assertions completed successfully."
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Output "##vso[task.logissue type=warning]PSRule assertions encountered issues: $errorMessage"
    }

    # Run PSRule evaluation with error handling
    try {
        $invokeParams = @{
            Module        = @('DevOpsTools.AzureDevOps.PSRule', 'PSRule.Monitor')
            InputPath     = $jsonFilesGlob
            Format        = 'Detect'
            Culture       = 'en'
            ErrorAction   = 'Continue'
            WarningAction = 'Continue'
        }

        Write-Host "Running PSRule evaluation..."
        Write-Output "##vso[task.setprogress value=60;]Running PSRule evaluation"
        $result = Invoke-PSRule @invokeParams

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
    Write-Output "##vso[task.complete result=Succeeded;]PSRule analysis completed successfully"
}
