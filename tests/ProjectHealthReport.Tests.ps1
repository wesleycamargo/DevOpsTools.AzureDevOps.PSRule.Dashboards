BeforeAll {
    $generator = "$PSScriptRoot/../src/scripts/Export-PSRulePipelineReport.ps1"
    function New-HealthRecord {
        param($Name = 'repo', $Outcome = 'Fail')
        [pscustomobject]@{ RuleName='Fixture.Repo.Policy'; TargetName=$Name; TargetType='Azure.DevOps.Repo'; Outcome=$Outcome
            TargetObject=@{id=@{organization='fixture';project='Atlas';resourceName=$Name}}
            Info=@{DisplayName='Protect repository';Description='Deduplicated rule description';Recommendation='Enable protection';Annotations=@{category='Microsoft Azure DevOps Repos';severity='High'}};Reason='Protection was absent' }
    }
    function Read-HealthPayload($Output) {
        $html = Get-Content "$Output/psrule-dashboard.html" -Raw
        ([regex]::Match($html,'<script id="report-data" type="application/json">(.*?)</script>','Singleline')).Groups[1].Value | ConvertFrom-Json -AsHashtable
    }
}
Describe 'Project Health display projection' {
    It 'deduplicates rule text in display schema 2 while preserving persisted schema 1 and Markdown' {
        & $generator -Results @((New-HealthRecord), (New-HealthRecord other Pass)) -Organization fixture -RunId fixture/1 -OutputDirectory $TestDrive
        $payload = Read-HealthPayload $TestDrive
        $payload.schemaVersion | Should -Be '2.0'
        $payload.rules.Count | Should -Be 1
        $payload.rules['Fixture.Repo.Policy'].description | Should -Be 'Deduplicated rule description'
        $payload.results[0].ContainsKey('description') | Should -BeFalse
        $payload.results[0].category | Should -Be 'Repos'
        $payload.collectorCategoryMap['Export-AzDevOpsReposAndBranchPolicies'] | Should -Be 'Repos'
        $payload.effort.ruleOverrides.Count | Should -Be 0
        (Get-Content "$TestDrive/assessment-snapshot.json" -Raw | ConvertFrom-Json).schemaVersion | Should -Be '1.0'
        Get-Content "$TestDrive/psrule-summary.md" -Raw | Should -Match '\| Total checkpoints \| 2 \|'
    }
    It 'loads an explicit effort config and rejects invalid estimates' {
        '{"categoryDefaults":{"Repos":"Low"},"ruleOverrides":{"Fixture.Repo.Policy":"High"}}' | Set-Content "$TestDrive/effort.json"
        & $generator -Results @((New-HealthRecord)) -Organization fixture -RunId fixture/1 -OutputDirectory $TestDrive -EffortConfigPath "$TestDrive/effort.json"
        (Read-HealthPayload $TestDrive).effort.ruleOverrides['Fixture.Repo.Policy'] | Should -Be High
        '{"categoryDefaults":{"Repos":"2 hours"},"ruleOverrides":{}}' | Set-Content "$TestDrive/effort.json"
        { & $generator -Results @((New-HealthRecord)) -Organization fixture -RunId fixture/1 -OutputDirectory $TestDrive -EffortConfigPath "$TestDrive/effort.json" } | Should -Throw '*Effort values*'
    }
    It 'slims embedded history to tuples and preserves evidence guards without changing stored snapshots' {
        & $generator -Results @((New-HealthRecord)) -Organization fixture -RunId fixture/0 -OutputDirectory "$TestDrive/old"
        $old=Get-Content "$TestDrive/old/assessment-snapshot.json" -Raw | ConvertFrom-Json
        @{schemaVersion='1.0';snapshots=@($old);limitations=@('Retention applies')} | ConvertTo-Json -Depth 30 | Set-Content "$TestDrive/history.json"
        & $generator -Results @((New-HealthRecord)) -Organization fixture -RunId fixture/1 -OutputDirectory $TestDrive -HistoryPath "$TestDrive/history.json"
        $payload=Read-HealthPayload $TestDrive
        $h=$payload.history.snapshots[0]
        $h.results[0].Count | Should -Be 5
        $h.results[0][3] | Should -Be 'Fixture.Repo.Policy'
        $h.evaluatedRules.Count | Should -Be 1
        $h.ContainsKey('configurationHash') | Should -BeTrue
        $h.ContainsKey('evaluation') | Should -BeTrue
        $h.ContainsKey('identityIncomplete') | Should -BeTrue
        $h.ContainsKey('rules') | Should -BeFalse
        $h.ContainsKey('history') | Should -BeFalse
        $old.results[0].description | Should -Be 'Deduplicated rule description'
    }
    It 'renders essential static HTML and embeds all assets in one file' {
        & $generator -Results @((New-HealthRecord)) -Organization fixture -RunId fixture/1 -OutputDirectory $TestDrive
        $html=Get-Content "$TestDrive/psrule-dashboard.html" -Raw
        $html | Should -Match 'id="psr-dashboard"'
        $html | Should -Match '<details><summary>Fixture.Repo.Policy'
        $html | Should -Match 'Team Project ranking × category'
        $html | Should -Match 'Organization-wide controls'
        $html | Should -Match '<h3>Assessment confidence</h3><strong>Limited</strong>'
        $html | Should -Not -Match '<(?:script|link)[^>]+(?:src|href)='
        $html | Should -Not -Match 'requires JavaScript'
        (Get-ChildItem $TestDrive -Filter '*.html').Count | Should -Be 1
    }
}
