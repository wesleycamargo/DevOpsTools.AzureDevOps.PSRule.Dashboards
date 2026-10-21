param([Parameter(Mandatory)][string]$OutputDirectory, [int]$RunCount = 3)
$ErrorActionPreference='Stop'
$generator="$PSScriptRoot/../src/scripts/Export-PSRulePipelineReport.ps1"
$projects=@('Atlas','Beacon','Cedar','Delta')
$commands=@('Export-AzDevOpsProject','Export-AzDevOpsReposAndBranchPolicies','Export-AzDevOpsEnvironmentChecks','Export-AzDevOpsServiceConnections','Export-AzDevOpsPipelines','Export-AzDevOpsPipelinesSettings','Export-AzDevOpsReleaseDefinitions','Export-AzDevOpsGroups','Export-AzDevOpsVariableGroups','Export-AzDevOpsRetentionSettings')
$collection=@{Status='Complete';Projects=@($projects | ForEach-Object {@{Project=$_;Status='Complete';Collectors=@($commands | ForEach-Object {@{Command=$_;Status='Completed';ReasonCodes=@()}})}});OrganizationCollection=@{Status='Completed'}}
$history=@{schemaVersion='1.0';snapshots=@();limitations=@('Synthetic fixture: no production data. Artifact retention applies.')}
New-Item $OutputDirectory -ItemType Directory -Force | Out-Null
'{"categoryDefaults":{"Repos":"Low","Pipelines":"Medium"},"ruleOverrides":{}}' | Set-Content "$OutputDirectory/effort.json"
for($run=0;$run -lt $RunCount;$run++) {
    $results=@(foreach($project in $projects) {
        foreach($category in @('Repos','Pipelines')) {
            $outcome='Pass'
            if($project -eq 'Atlas' -and $category -eq 'Repos' -and $run -ne 1){$outcome='Fail'}
            if($project -eq 'Beacon' -and $category -eq 'Repos'){$outcome='Fail'}
            if($project -eq 'Cedar' -and $category -eq 'Repos' -and $run -eq 2){$outcome='Fail'}
            if($project -eq 'Delta' -and ($category -eq 'Repos' -or $run -lt 2)){$outcome='Fail'}
            if($project -eq 'Beacon' -and $category -eq 'Repos' -and $run -eq 2){continue}
            foreach($resource in 1..3) {
                $checkpointOutcome = if($project -in 'Atlas','Cedar' -and $resource -gt 1) { 'Pass' } else { $outcome }
                [pscustomobject]@{RuleName="Fixture.$category.Protection";Outcome=$checkpointOutcome;TargetName="$project.$category.$resource";TargetType="Fixture.$category"
                    TargetObject=@{id=@{organization='fixture-org';project=$project;resourceName="resource-$resource"}}
                    Info=@{DisplayName="$category protection";Description='Assessment fixture description';Recommendation='Configure the documented protection';HelpUri='https://example.invalid/rule';Annotations=@{category=$category;severity='High'}}
                    Reason="Fixture: protection outcome $checkpointOutcome"}
            }
        }
    })
    $results+= [pscustomobject]@{RuleName='Fixture.Organization.Audit';Outcome='Pass';TargetType='Azure.DevOps.Organization';TargetName='fixture-org';TargetObject=@{id=@{organization='fixture-org';resourceName='settings'}};Info=@{DisplayName='Organization audit';Annotations=@{category='Organization';severity='Low'}}}
    $attack='</script><img src=x onerror=alert(1)> prøject __DASHBOARD_JS__'
    $results+= [pscustomobject]@{RuleName='Fixture.UnknownMetadata';Outcome='Ignore';TargetType='Fixture.Pipelines';TargetName='unicode';TargetObject=@{id=@{project='Atlas';resourceName=$attack}};Info=@{Annotations=@{category='Pipelines'}};Reason=$attack}
    $history | ConvertTo-Json -Depth 30 | Set-Content "$OutputDirectory/history.json"
    & $generator -Results $results -Organization fixture-org -RunId "fixture-org/$run" -Timestamp ([datetime]"2026-06-0$($run+1)") -ModuleVersion 1 -Configuration @{baseline='Fixture.Default';rulesetHash='fixed'} -Evaluation @{Status='Completed'} -Collection $collection -HistoryPath "$OutputDirectory/history.json" -EffortConfigPath "$OutputDirectory/effort.json" -OutputDirectory $OutputDirectory
    $history.snapshots+= Get-Content "$OutputDirectory/assessment-snapshot.json" -Raw | ConvertFrom-Json
}
