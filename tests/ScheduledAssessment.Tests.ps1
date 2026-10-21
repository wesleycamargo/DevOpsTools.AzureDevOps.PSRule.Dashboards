BeforeAll {
    $scheduledScript = (Resolve-Path "$PSScriptRoot/../src/scripts/Invoke-AzDevOpsPSRuleAnalysis.ps1").Path
    function Invoke-ScheduledAssessmentFixture {
        param($Scenario, $Output)
        $runner = [powershell]::Create()
        $harness = {
            param($ScriptPath,$Scenario,$Output)
            New-Item $Output -ItemType Directory -Force | Out-Null
            '{}' | Set-Content "$Output/input.json"
            @{Status='Complete';Projects=@()} | ConvertTo-Json | Set-Content (Join-Path (Split-Path $Output) 'collection-status.json')
            function Import-Module { }
            function Get-Module { [pscustomobject]@{Version='1.0';ModuleBase=$Output} }
            function Assert-PSRule {
                param($InputPath,$As,$OutputPath,$OutputFormat,$ResultVariable)
                if ($As -ne 'Detail' -or $OutputFormat -ne 'Sarif') { throw 'Incorrect detailed evaluation contract.' }
                '{}' | Set-Content $OutputPath
                $records = @('Pass','Fail' | ForEach-Object { [pscustomobject]@{Outcome=$_;RuleName='R';TargetName='resource';TargetType='Repo';Field=@{id='{"organization":"org","project":"p","resourceName":"r"}'}} })
                Set-Variable -Scope 1 -Name $ResultVariable -Value $records
            }
            function Send-PSRuleMonitorRecord {
                param([Parameter(ValueFromPipeline)]$InputObject,$WorkspaceId,$SharedKey,$LogName)
                process { if ($Scenario -eq 'IngestionFailure') { throw 'Monitor unavailable.' } }
            }
            try { & $ScriptPath -ReportOutputPath $Output -Organization org -LogAnalyticsWorkspaceId test -LogAnalyticsSharedKey test; [pscustomobject]@{Error=$null} }
            catch { [pscustomobject]@{Error=$_.Exception.Message} }
        }
        try {
            $null = $runner.AddScript($harness.ToString()).AddArgument($scheduledScript).AddArgument($Scenario).AddArgument($Output)
            $value = $runner.Invoke()
            [pscustomobject]@{Error=$value[-1].Error; Output=($value -join "`n")}
        } finally { $runner.Dispose() }
    }
}
Describe 'Scheduled assessment reporting' {
    It 'preserves SARIF HTML Markdown and normalized snapshots before Monitor ingestion fails' {
        $output = "$TestDrive/failure/results"
        $run = Invoke-ScheduledAssessmentFixture IngestionFailure $output
        $run.Error | Should -BeNullOrEmpty
        $run.Output | Should -Match 'task.complete result=Failed'
        $run.Output | Should -Not -Match 'task.complete result=Succeeded'
        foreach ($name in @('psrule-results.sarif','psrule-dashboard.html','psrule-summary.md','assessment-snapshot.json')) { Test-Path "$output/$name" | Should -BeTrue }
        $snapshot = Get-Content "$output/assessment-snapshot.json" -Raw | ConvertFrom-Json
        $snapshot.statistics.total | Should -Be 2
        $snapshot.statistics.passed | Should -Be 1
        $snapshot.statistics.failed | Should -Be 1
    }
}
