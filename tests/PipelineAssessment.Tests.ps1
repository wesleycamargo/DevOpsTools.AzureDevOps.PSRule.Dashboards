BeforeAll {
    $assessmentPath = (Resolve-Path "$PSScriptRoot/../src/scripts/Invoke-PSRuleAssessment.ps1").Path
    function Invoke-TestAssessment {
        param([string]$Scenario, [string]$OutputDirectory, [string]$ModuleVersion = '0.2.0')
        # Isolate collector/PSRule/Azure adapters while running the real orchestration and report writer.
        $runner = [powershell]::Create()
        $harness = {
            param($AssessmentPath, $Scenario, $OutputDirectory, $ModuleVersion)
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
                $moduleCalls = [System.Collections.Generic.List[object]]::new()
                function Install-Module {
                    param($Name, $RequiredVersion, $Repository, $Scope, [switch]$Force, [switch]$AllowClobber)
                    $moduleCalls.Add([pscustomobject]@{ Operation = 'Install'; Name = $Name; RequiredVersion = $RequiredVersion; Repository = $Repository; Scope = $Scope; AllowClobber = $AllowClobber.IsPresent })
                    if ($Scenario -eq 'ModuleInstallError') { throw 'Gallery installation failed.' }
                }
                function Import-Module {
                    param($Name, $RequiredVersion, [switch]$Force)
                    $moduleCalls.Add([pscustomobject]@{ Operation = 'Import'; Name = $Name; RequiredVersion = $RequiredVersion })
                    if ($Name -eq 'DevOpsTools.AzureDevOps.PSRule' -and $Scenario -eq 'ModuleImportError') { throw 'Module import failed.' }
                }
                function Connect-AzDevOps { if ($Scenario -eq 'AuthenticationError') { throw 'Authentication failed.' } }
                function Export-AzDevOpsOrganizationRuleData {
                    [CmdletBinding()]
                    param($OutputPath, $CompletenessReportPath, $Organization, $OrganizationId, [switch]$Strict)
                    if ($Strict) { throw 'Strict collection was requested.' }
                    if ($CompletenessReportPath.StartsWith($OutputPath)) { throw 'Completeness metadata is inside rule inputs.' }
                    '{"SchemaVersion":1,"Status":"Complete","Projects":[]}' | Set-Content $CompletenessReportPath
                    if ($Scenario -eq 'NoInputs') { return }
                    if ($Scenario -eq 'CollectionError') { throw 'Unexpected collection failure.' }
                    $project = New-Item (Join-Path $OutputPath 'test-project') -ItemType Directory -Force
                    '{}' | Set-Content (Join-Path $project.FullName 'input.json')
                    if ($Scenario -eq 'Incomplete') {
                        @{
                            SchemaVersion = 1; Status = 'Partial'; Projects = @(@{
                                Project = 'test-project'; Status = 'Partial'; Collectors = @(
                                    @{ Command = 'Export-AdoOrganizationGeneralBillingSettings'; Status = 'Failed'; ReasonCodes = @('CollectorFailed') }
                                    @{ Command = 'Export-AdoOrganizationSecurityPolicies'; Status = 'Partial'; ReasonCodes = @('MissingRequiredData') }
                                )
                            })
                        } | ConvertTo-Json -Depth 8 | Set-Content $CompletenessReportPath
                        Write-Error "Billing 50% failed`n##vso[task.complete result=Failed;]" -ErrorAction Continue
                    }
                }
                function New-PSRuleOption { }
                function Assert-PSRule {
                    param($ResultVariable, $OutputPath, $InputPath, $Module)
                    if ($Module -ne 'DevOpsTools.AzureDevOps.PSRule') { throw "Unexpected assessment module: $Module" }
                    if ($Scenario -eq 'NoInputs') { throw 'Empty inputs reached evaluation.' }
                    if ($Scenario -eq 'ReportError') { New-Item (Join-Path (Split-Path $OutputPath) 'psrule-dashboard.html') -ItemType Directory | Out-Null }
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
                    & $AssessmentPath -ModuleVersion $ModuleVersion -Organization test-org
                    [pscustomobject]@{ Error = $null; ModuleCalls = $moduleCalls.ToArray() }
                } catch { [pscustomobject]@{ Error = $_.Exception.Message; ModuleCalls = $moduleCalls.ToArray() } }
            } finally {
                foreach ($name in $previousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name]) }
            }
        }
        try {
            $null = $runner.AddScript($harness.ToString()).AddArgument($assessmentPath).AddArgument($Scenario).AddArgument($OutputDirectory).AddArgument($ModuleVersion)
            $result = $runner.Invoke()
            [pscustomobject]@{ Error = $result[-1].Error; ModuleCalls = $result[-1].ModuleCalls; Messages = $runner.Streams.Information.MessageData -join "`n" }
        } finally { $runner.Dispose() }
    }
}

Describe 'Assessment report integration' {
    It 'generates pipeline reports without Azure publishing and retains raw project exports' {
        $output = "$TestDrive/success"
        $assessment = Invoke-TestAssessment Success $output
        $assessment.Error | Should -BeNullOrEmpty
        $installation = @($assessment.ModuleCalls | Where-Object Operation -EQ 'Install')
        $installation.Count | Should -Be 1
        $installation[0].Name | Should -Be 'DevOpsTools.AzureDevOps.PSRule'
        $installation[0].RequiredVersion | Should -Be '0.2.0'
        $installation[0].Repository | Should -Be 'PSGallery'
        $installation[0].Scope | Should -Be 'CurrentUser'
        $installation[0].AllowClobber | Should -BeTrue
        @($assessment.ModuleCalls | Where-Object Operation -EQ 'Import').Name | Should -Be @('PSRule', 'DevOpsTools.AzureDevOps.PSRule')
        ($assessment.ModuleCalls | Where-Object { $_.Operation -eq 'Import' -and $_.Name -eq 'DevOpsTools.AzureDevOps.PSRule' }).RequiredVersion | Should -Be '0.2.0'
        foreach ($file in @('psrule-dashboard.html', 'psrule-summary.md', 'psrule-results.sarif', 'collection-status.json')) {
            Test-Path "$output/reports/$file" | Should -BeTrue
        }
        Test-Path "$output/raw-export/test-project/input.json" | Should -BeTrue
        Test-Path "$output/raw-export/collection-status.json" | Should -BeFalse
        $assessment.Messages | Should -Match 'task.uploadsummary'
        $assessment.Messages | Should -Match 'PSRuleReportReady.*true'
        $assessment.Messages | Should -Not -Match 'SucceededWithIssues'
    }

    It 'installs and imports the explicitly requested package version' {
        $assessment = Invoke-TestAssessment Success "$TestDrive/version" -ModuleVersion '0.3.0'
        $assessment.Error | Should -BeNullOrEmpty
        $calls = @($assessment.ModuleCalls | Where-Object Name -EQ 'DevOpsTools.AzureDevOps.PSRule')
        $calls.Count | Should -Be 2
        $calls.RequiredVersion | Should -Be @('0.3.0', '0.3.0')
    }

    It 'evaluates partial exports with billing and security gaps and publishes a yellow dashboard' {
        $output = "$TestDrive/incomplete"
        $assessment = Invoke-TestAssessment Incomplete $output
        $assessment.Error | Should -BeNullOrEmpty
        foreach ($file in @('psrule-dashboard.html', 'psrule-summary.md', 'psrule-results.sarif', 'collection-status.json')) {
            Test-Path "$output/reports/$file" | Should -BeTrue
        }
        Test-Path "$output/raw-export/test-project/input.json" | Should -BeTrue
        $assessment.Messages | Should -Match 'PSRuleReportReady.*true'
        $assessment.Messages | Should -Match 'task.complete result=SucceededWithIssues'
        $assessment.Messages | Should -Match 'Billing 50%AZP25 failed%0A##vso'
        $assessment.Messages | Should -Not -Match '(?m)^##vso\[task.complete result=Failed'
        Get-Content "$output/reports/psrule-summary.md" -Raw | Should -Match 'MissingRequiredData'
    }

    It 'clears stale files and publishes diagnostics for <Scenario>' -ForEach @(@{ Scenario = 'NoInputs' }, @{ Scenario = 'Empty' }) {
        $output = "$TestDrive/retry-$Scenario"
        $null = Invoke-TestAssessment Success $output
        '{}' | Set-Content "$output/raw-export/stale.json"
        $assessment = Invoke-TestAssessment $Scenario $output
        $assessment.Error | Should -BeNullOrEmpty
        Test-Path "$output/raw-export/stale.json" | Should -BeFalse
        Test-Path "$output/reports/psrule-results.sarif" | Should -BeFalse
        Get-Content "$output/reports/psrule-summary.md" -Raw | Should -Match 'No assessment results available'
        $assessment.Messages | Should -Match 'PSRuleReportReady.*true'
        $assessment.Messages | Should -Match 'SucceededWithIssues'
    }

    It 'keeps <Scenario> failures red' -ForEach @(@{ Scenario = 'ModuleInstallError' }, @{ Scenario = 'ModuleImportError' }, @{ Scenario = 'AuthenticationError' }, @{ Scenario = 'CollectionError' }, @{ Scenario = 'ReportError' }) {
        $assessment = Invoke-TestAssessment $Scenario "$TestDrive/$Scenario"
        $assessment.Error | Should -Not -BeNullOrEmpty
        $assessment.Messages | Should -Not -Match 'SucceededWithIssues|PSRuleReportReady.*true'
    }

    It 'does not publish a success-looking dashboard when rule execution fails' {
        $output = "$TestDrive/execution-error"
        $assessment = Invoke-TestAssessment ExecutionError $output
        $assessment.Error | Should -Match 'rule execution errors'
        Test-Path "$output/reports/psrule-dashboard.html" | Should -BeFalse
        $assessment.Messages | Should -Not -Match 'task.uploadsummary'
    }
}
