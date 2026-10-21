BeforeAll {
    $assessmentPath = (Resolve-Path "$PSScriptRoot/../src/scripts/Invoke-PSRuleAssessment.ps1").Path
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
                    param($OutputPath, $CompletenessReportPath, [switch]$Strict)
                    if (-not $Strict) { throw 'Strict collection was not requested.' }
                    if ($CompletenessReportPath.StartsWith($OutputPath)) { throw 'Completeness metadata is inside rule inputs.' }
                    '{"complete":true}' | Set-Content $CompletenessReportPath
                    $project = New-Item (Join-Path $OutputPath 'test-project') -ItemType Directory -Force
                    '{}' | Set-Content (Join-Path $project.FullName 'input.json')
                    if ($Scenario -eq 'Incomplete') {
                        '{"complete":false}' | Set-Content $CompletenessReportPath
                        throw 'Collection incomplete.'
                    }
                }
                function New-PSRuleOption { }
                function Assert-PSRule {
                    param($ResultVariable, $OutputPath, $InputPath)
                    if ($Scenario -eq 'Incomplete') { throw 'Incomplete data reached evaluation.' }
                    if (@($InputPath).Count -ne 1 -or $InputPath[0] -notmatch 'input.json$') { throw 'Unexpected assessment inputs.' }
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
                }
                function az {
                    $global:LASTEXITCODE = 0
                    if (($args -join ' ') -ne 'account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv') {
                        throw "Unexpected Azure operation: $args"
                    }
                    return 'test-token'
                }
                function Invoke-WebRequest { throw 'Unexpected external publication.' }
                function Invoke-RestMethod { throw 'Unexpected Log Analytics request.' }
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
    It 'generates pipeline reports without Azure publishing and retains raw project exports' {
        $output = "$TestDrive/success"
        $assessment = Invoke-TestAssessment Success $output
        $assessment.Error | Should -BeNullOrEmpty
        foreach ($file in @('psrule-dashboard.html', 'psrule-summary.md', 'psrule-results.sarif', 'collection-status.json')) {
            Test-Path "$output/reports/$file" | Should -BeTrue
        }
        Test-Path "$output/raw-export/test-project/input.json" | Should -BeTrue
        Test-Path "$output/raw-export/collection-status.json" | Should -BeFalse
        $assessment.Messages | Should -Match 'task.uploadsummary'
        $assessment.Messages | Should -Match 'PSRuleReportReady.*true'
    }

    It 'retains partial raw exports and diagnostics when strict collection fails' {
        $output = "$TestDrive/incomplete"
        $assessment = Invoke-TestAssessment Incomplete $output
        $assessment.Error | Should -Be 'Collection incomplete.'
        Test-Path "$output/raw-export/test-project/input.json" | Should -BeTrue
        Test-Path "$output/reports/collection-status.json" | Should -BeTrue
        Test-Path "$output/reports/psrule-results.sarif" | Should -BeFalse
        $assessment.Messages | Should -Not -Match 'PSRuleReportReady'
    }

    It 'clears stale exports and reports before a repeated attempt' {
        $output = "$TestDrive/retry"
        $null = Invoke-TestAssessment Success $output
        '{}' | Set-Content "$output/raw-export/stale.json"
        $assessment = Invoke-TestAssessment Incomplete $output
        $assessment.Error | Should -Be 'Collection incomplete.'
        Test-Path "$output/raw-export/stale.json" | Should -BeFalse
        Test-Path "$output/reports/psrule-dashboard.html" | Should -BeFalse
    }

    It 'does not publish a dashboard for zero evaluated results' {
        $output = "$TestDrive/empty"
        $assessment = Invoke-TestAssessment Empty $output
        $assessment.Error | Should -Match 'zero rule results'
        Test-Path "$output/reports/psrule-dashboard.html" | Should -BeFalse
        $assessment.Messages | Should -Not -Match 'PSRuleReportReady'
    }

    It 'does not publish a success-looking dashboard when rule execution fails' {
        $output = "$TestDrive/execution-error"
        $assessment = Invoke-TestAssessment ExecutionError $output
        $assessment.Error | Should -Match 'rule execution errors'
        Test-Path "$output/reports/psrule-dashboard.html" | Should -BeFalse
        $assessment.Messages | Should -Not -Match 'task.uploadsummary'
    }
}
