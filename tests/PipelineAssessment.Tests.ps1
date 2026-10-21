BeforeAll {
    $assessmentPath = (Resolve-Path "$PSScriptRoot/../src/scripts/Invoke-PSRuleWorkbookAssessment.ps1").Path
    function Invoke-TestAssessment {
        param([string]$Scenario, [string]$OutputDirectory)
        # Isolate collector/PSRule/Azure adapters while running the real orchestration and report writer.
        $runner = [powershell]::Create()
        $harness = {
            param($AssessmentPath, $Scenario, $OutputDirectory)
            $previousEnvironment = @{}
            foreach ($name in @('PIPELINE_WORKSPACE', 'BUILD_BUILDID', 'BUILD_ARTIFACTSTAGINGDIRECTORY')) {
                $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            try {
                $env:PIPELINE_WORKSPACE = $OutputDirectory
                $env:BUILD_BUILDID = '42'
                $env:BUILD_ARTIFACTSTAGINGDIRECTORY = $OutputDirectory
                New-Item $OutputDirectory -ItemType Directory -Force | Out-Null
                function Get-Module { [pscustomobject]@{ Version = [version]'2.9.0' } }
                function Import-Module { }
                function Connect-AzDevOps { }
                function Export-AzDevOpsOrganizationRuleData {
                    param($OutputPath, $CompletenessReportPath)
                    @{ Status = $(if ($Scenario -eq 'Partial') { 'Partial' } else { 'Complete' }); Projects = @() } | ConvertTo-Json | Set-Content $CompletenessReportPath
                    '{}' | Set-Content (Join-Path $OutputPath 'input.json')
                }
                function New-PSRuleOption { }
                function Assert-PSRule {
                    param($ResultVariable, $OutputPath)
                    $results = @('Pass', 'Fail' | ForEach-Object {
                        [pscustomobject]@{
                            RuleName = 'Test.Rule'; TargetName = 'test-resource'; TargetType = 'Azure.DevOps.Project'
                            Outcome = $_; Info = @{ DisplayName = 'Test rule'; Annotations = @{ severity = 'Critical' } }
                            Field = @{ id = '{"project":"test-project","resourceName":"test-resource"}' }
                        }
                    })
                    if ($Scenario -eq 'Empty') { $results = @() }
                    if ($Scenario -eq 'ExecutionError') { $results[1].Outcome = 'Error' }
                    Set-Variable -Name $ResultVariable -Scope 1 -Value $results
                    '{}' | Set-Content $OutputPath
                    if ($Scenario -eq 'TerminatingEvaluation') { throw 'Evaluation stopped after partial results.' }
                }
                function az {
                    $global:LASTEXITCODE = 0
                    if ($args[0] -eq 'deployment') {
                        return '{"ingestionEndpoint":{"value":"https://example.test"},"ingestionRuleImmutableId":{"value":"dcr-test"},"workspaceId":{"value":"workspace-test"}}'
                    }
                    return 'test-token'
                }
                function Invoke-WebRequest {
                    if ($Scenario -eq 'IngestionFailure') { throw 'Ingestion failed.' }
                }
                function Invoke-RestMethod { param($Uri); if ($Uri -like '*connectionData') { return @{instanceId='00000000-0000-0000-0000-000000000001'} }; return '{"tables":[{"rows":[[2,1,1]]}]}' | ConvertFrom-Json }
                try {
                    & $AssessmentPath -ModuleManifestPath 'test-module.psd1' -Organization test-org
                    [pscustomobject]@{ Error = $null }
                } catch { [pscustomobject]@{ Error = $_.Exception.Message } }
            } finally {
                foreach ($name in $previousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name]) }
            }
        }
        try {
            $null = $runner.AddScript($harness.ToString()).AddArgument($assessmentPath).AddArgument($Scenario).AddArgument($OutputDirectory)
            $result = $runner.Invoke()
            [pscustomobject]@{ Error = $result[-1].Error; Messages = $runner.Streams.Information.MessageData -join "`n" }
        } finally { $runner.Dispose() }
    }
}

Describe 'Assessment report integration' {
    It 'retains the HTML, Markdown, and SARIF and announces report readiness before ingestion fails' {
        $output = "$TestDrive/ingestion-failure"
        $assessment = Invoke-TestAssessment IngestionFailure $output
        $assessment.Error | Should -Be 'Ingestion failed.'
        Test-Path "$output/psrule-dashboard.html" | Should -BeTrue
        Test-Path "$output/psrule-summary.md" | Should -BeTrue
        Test-Path "$output/psrule-results.sarif" | Should -BeTrue
        $assessment.Messages | Should -Match '##vso\[task.uploadsummary\]'
        $assessment.Messages | Should -Match '##vso\[task.setvariable variable=PSRuleReportReady\]true'
    }

    It 'keeps rule violations as findings and verifies workbook publishing' {
        $assessment = Invoke-TestAssessment Success "$TestDrive/success"
        $assessment.Error | Should -BeNullOrEmpty
        $assessment.Messages | Should -Match 'total=2, failed=1, passed=1'
    }

    It 'does not publish a dashboard for zero evaluated results' {
        $output = "$TestDrive/empty"
        $assessment = Invoke-TestAssessment Empty $output
        $assessment.Error | Should -Match 'zero rule results'
        Test-Path "$output/psrule-dashboard.html" | Should -BeFalse
        $assessment.Messages | Should -Not -Match 'PSRuleReportReady'
    }

    It 'retains an error report and blocks workbook publishing when rule execution fails' {
        $output = "$TestDrive/execution-error"
        $assessment = Invoke-TestAssessment ExecutionError $output
        $assessment.Error | Should -Match 'rule execution errors'
        Test-Path "$output/psrule-dashboard.html" | Should -BeTrue
        Test-Path "$output/assessment-snapshot.json" | Should -BeTrue
        $assessment.Messages | Should -Match 'task.uploadsummary'
    }
}

Describe 'Assessment completeness integration' {
    It 'retains partial collection reports and blocks workbook publishing' {
        $output = "$TestDrive/partial"
        $assessment = Invoke-TestAssessment Partial $output
        $assessment.Error | Should -Match 'Collection is incomplete'
        (Get-Content "$output/assessment-snapshot.json" -Raw | ConvertFrom-Json).collection.Status | Should -Be Partial
        Test-Path "$output/psrule-dashboard.html" | Should -BeTrue
    }
}

Describe 'Terminating evaluation evidence' {
    It 'retains available results and marks evaluation failed when PSRule terminates' {
        $output = "$TestDrive/terminating"
        $assessment = Invoke-TestAssessment TerminatingEvaluation $output
        $assessment.Error | Should -Match 'rule execution errors'
        Test-Path "$output/psrule-dashboard.html" | Should -BeTrue
        $snapshot = Get-Content "$output/assessment-snapshot.json" -Raw | ConvertFrom-Json
        $snapshot.statistics.total | Should -Be 2
        $snapshot.evaluation.Status | Should -Be Failed
    }
}
