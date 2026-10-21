BeforeAll {
    . "$PSScriptRoot/../src/scripts/AssessmentModel.ps1"
    function New-Checkpoint {
        param($Project = 'p', $Type = 'Repo', $Outcome = 'Fail', $Severity = 'warning')
        [pscustomobject]@{ RuleName = 'Rule.A'; TargetName = 'org.p.repo'; TargetType = $Type; Outcome = $Outcome; TargetObject = @{ id = @{ organization = 'org'; project = $Project; resourceName = 'repo' } }; Info = @{ Annotations = @{ severity = $Severity }; DisplayName = 'A' } }
    }
}
Describe 'Assessment snapshot contract' {
    It 'normalizes documented severity aliases without inventing unknown severity' {
        @( 'critical','Severe','ERROR','Warning','information','custom' | ForEach-Object { Get-AssessmentSeverity $_ }) | Should -Be @('Critical','High','High','Medium','Low','Unknown')
    }
    It 'keeps organization project resource type and target in stable checkpoint identities' {
        $rows = @((New-Checkpoint), (New-Checkpoint other), (New-Checkpoint p Pipeline))
        $snapshot = New-AssessmentSnapshot -Results $rows -Organization org -RunId org/1 -Timestamp ([datetime]'2026-01-01')
        @($snapshot.results.fingerprint | Sort-Object -Unique).Count | Should -Be 3
        $again = New-AssessmentSnapshot -Results $rows -Organization org -RunId org/2 -Timestamp ([datetime]'2026-02-01')
        $snapshot.results.fingerprint | Should -Be $again.results.fingerprint
        $snapshot.maturity.score | Should -BeNullOrEmpty
    }
    It 'preserves every outcome and defines compliance only on Pass and Fail' {
        $rows = @('Pass','Fail','Ignore','Error','None','Suppressed' | ForEach-Object { New-Checkpoint -Outcome $_ })
        $snapshot = New-AssessmentSnapshot -Results $rows -Organization org -RunId org/1 -Timestamp ([datetime]'2026-01-01')
        $snapshot.statistics.total | Should -Be 6
        $snapshot.statistics.applicable | Should -Be 2
        $snapshot.statistics.compliance | Should -Be 50
        $snapshot.results.outcome | Should -Be @('Pass','Fail','Ignore','Error','None','Suppressed')
    }
    It 'does not invent compliance for an inapplicable assessment' {
        (Get-AssessmentStatistics @((New-Checkpoint -Outcome Ignore))).compliance | Should -BeNullOrEmpty
    }
    It 'uses rule help as the metadata source and preserves recommendations and links' {
        @'
---
category: Repositories
severity: Severe
online version: https://example.test/rule
---
## DESCRIPTION
A description with prøject.
## RECOMMENDATION
Do this documented action.
## LINKS
- [Official reference](https://example.test/reference)
'@ | Set-Content "$TestDrive/Rule.A.md"
        $snapshot = New-AssessmentSnapshot -Results @((New-Checkpoint)) -Organization org -RunId org/1 -Timestamp ([datetime]'2026-01-01') -RuleHelpPath $TestDrive
        $snapshot.results[0].category | Should -Be Repositories
        $snapshot.results[0].severity | Should -Be High
        $snapshot.results[0].recommendation | Should -Be 'Do this documented action.'
        $snapshot.results[0].references[0].url | Should -Be 'https://example.test/reference'
    }
}

Describe 'Real PSRule offline evaluation and report output' {
    It 'retains Pass and Fail from detailed PSRule results while SARIF contains failures only' {
        Import-Module PSRule -RequiredVersion 2.9.0 -Force
        @'
Rule 'Synthetic.Policy' {
    $Assert.HasFieldValue($TargetObject, 'enabled', $true)
}
'@ | Set-Content "$TestDrive/Synthetic.Rule.ps1"
        $inputObjects = @(
            [pscustomobject]@{Name='repo-pass';enabled=$true;id=@{organization='org';project='p';resourceName='repo-pass'}}
            [pscustomobject]@{Name='repo-fail';enabled=$false;id=@{organization='org';project='p';resourceName='repo-fail'}}
        )
        $detail = $null
        $null = $inputObjects | Assert-PSRule -Path "$TestDrive/Synthetic.Rule.ps1" -As Detail -OutputPath "$TestDrive/results.sarif" -OutputFormat Sarif -ResultVariable detail -ErrorAction SilentlyContinue
        @($detail).Count | Should -Be 2
        & "$PSScriptRoot/../src/scripts/Export-PSRulePipelineReport.ps1" -Results @($detail) -Organization org -RunId org/test -OutputDirectory $TestDrive
        $snapshot = Get-Content "$TestDrive/assessment-snapshot.json" -Raw | ConvertFrom-Json
        $snapshot.statistics.passed | Should -Be 1
        $snapshot.statistics.failed | Should -Be 1
        $snapshot.statistics.compliance | Should -Be 50
        $sarif = Get-Content "$TestDrive/results.sarif" -Raw | ConvertFrom-Json
        @($sarif.runs[0].results).Count | Should -Be 1
    }
}
