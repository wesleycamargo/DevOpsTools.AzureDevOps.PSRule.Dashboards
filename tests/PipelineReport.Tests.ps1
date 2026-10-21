BeforeAll {
    $scriptPath = "$PSScriptRoot/../src/scripts/Export-PSRulePipelineReport.ps1"
    function New-ReportResult {
        param([string]$Outcome = 'Pass', [string]$RuleName = 'Azure.DevOps.Project.Visibility', [string]$TargetName = 'organization.prøject')
        [pscustomobject]@{
            RuleName = $RuleName
            Info = [pscustomobject]@{ DisplayName = 'Project visibility'; Annotations = @{ severity = 'Critical' } }
            TargetName = $TargetName
            TargetType = 'Azure.DevOps.Project'
            Outcome = $Outcome
            Field = @{ id = '{"organization":"organization","project":"prøject","resourceName":"resource"}' }
        }
    }
}

Describe 'Pipeline assessment report' {
    It 'writes matching HTML and Markdown totals for the assessed run' {
        $results = @((New-ReportResult), (New-ReportResult Fail), (New-ReportResult Fail 'Other.Rule' 'other-resource'))
        & $scriptPath -Results $results -Organization organization -RunId organization/42 -Timestamp ([datetime]'2026-10-09T12:00:00Z') -OutputDirectory $TestDrive
        $html = Get-Content "$TestDrive/psrule-dashboard.html" -Raw
        $summary = Get-Content "$TestDrive/psrule-summary.md" -Raw
        $html | Should -Match 'PSRule Dashboard'
        $html | Should -Match 'organization/42'
        $summary | Should -Match '\| Total checkpoints \| 3 \|'
        $summary | Should -Match '\| Passed checkpoints \| 1 \|'
        $summary | Should -Match '\| Failed checkpoints \| 2 \|'
        $summary | Should -Match '\| Rules checked \| 2 \|'
        $summary | Should -Match '\| Resources checked \| 2 \|'
        $match = [regex]::Match($html, '<script id="report-data" type="application/json">(.*?)</script>', 'Singleline')
        $data = $match.Groups[1].Value | ConvertFrom-Json
        $data.results.Count | Should -Be 3
        @($data.results | Where-Object outcome -eq 'Fail').Count | Should -Be 2
        ([datetime]$data.timestamp).ToUniversalTime().ToString('o') | Should -Be '2026-10-09T12:00:00.0000000Z'
    }

    It 'preserves structured resource metadata and single-result arrays' {
        $result = New-ReportResult Fail
        $result.Field.id = 'System.Collections.Hashtable'
        $result | Add-Member TargetObject ([pscustomobject]@{ id = @{ organization = 'organization'; project = 'prøject'; resourceName = 'brånch' } })
        & $scriptPath -Results @($result) -Organization organization -RunId organization/42 -OutputDirectory $TestDrive
        $html = Get-Content "$TestDrive/psrule-dashboard.html" -Raw
        $data = ([regex]::Match($html, '<script id="report-data" type="application/json">(.*?)</script>', 'Singleline')).Groups[1].Value | ConvertFrom-Json
        $data.results.GetType().IsArray | Should -BeTrue
        $data.results.Count | Should -Be 1
        $data.results[0].project | Should -Be 'prøject'
        $data.results[0].resourceName | Should -Be 'brånch'
    }

    It 'reads serialized resource IDs and displays absent or invalid metadata as Unknown' {
        $known = New-ReportResult
        $missing = New-ReportResult
        $missing.Field.id = 'not-json'
        $missing.Info = $null
        & $scriptPath -Results @($known, $missing) -Organization organization -RunId organization/42 -OutputDirectory $TestDrive
        $html = Get-Content "$TestDrive/psrule-dashboard.html" -Raw
        $data = ([regex]::Match($html, '<script id="report-data" type="application/json">(.*?)</script>', 'Singleline')).Groups[1].Value | ConvertFrom-Json
        $data.results[0].project | Should -Be 'prøject'
        $data.results[1].project | Should -Be 'Unknown'
        $data.results[1].severity | Should -Be 'Unknown'
        $data.results[1].displayName | Should -Be 'Unknown'
    }

    It 'keeps HTML and script-like text as data without losing Unicode' {
        $attack = '</script><script>window.reportInjected=true</script><img src=x onerror=alert(1)> & prøject'
        $result = New-ReportResult Fail $attack
        & $scriptPath -Results @($result) -Organization $attack -RunId $attack -OutputDirectory $TestDrive
        $html = Get-Content "$TestDrive/psrule-dashboard.html" -Raw
        $html | Should -Not -Match ([regex]::Escape($attack))
        $data = ([regex]::Match($html, '<script id="report-data" type="application/json">(.*?)</script>', 'Singleline')).Groups[1].Value | ConvertFrom-Json
        $data.results[0].ruleName | Should -Be $attack
        $data.organization | Should -Be $attack
        $summary = Get-Content "$TestDrive/psrule-summary.md" -Raw
        $summary | Should -Not -Match '<script>'
        [Net.WebUtility]::HtmlDecode($summary) | Should -Match 'prøject'
    }

    It 'includes failed rule counts in the Markdown summary and escapes table delimiters' {
        $result = New-ReportResult Fail "Rule|with`nnewline"
        & $scriptPath -Results @($result, $result, (New-ReportResult)) -Organization organization -RunId organization/42 -OutputDirectory $TestDrive
        $summary = Get-Content "$TestDrive/psrule-summary.md" -Raw
        $summary | Should -Match 'Failures by rule'
        $summary | Should -Match '\| Rule\\\|with newline \| 2 \|'
    }

    It 'rejects an empty assessment instead of producing success-looking reports' {
        { & $scriptPath -Results @() -Organization organization -RunId organization/42 -OutputDirectory "$TestDrive/empty" } | Should -Throw
        Test-Path "$TestDrive/empty/psrule-dashboard.html" | Should -BeFalse
    }
}

Describe 'Report contract and history resilience' {
    It 'validates the emitted snapshot against the documented JSON schema' {
        & $scriptPath -Results @((New-ReportResult)) -Organization org -RunId org/1 -OutputDirectory $TestDrive
        Get-Content "$TestDrive/assessment-snapshot.json" -Raw | Test-Json -SchemaFile "$PSScriptRoot/../docs/assessment-snapshot.schema.json" | Should -BeTrue
    }
    It 'keeps current evidence when an imported historical dataset is corrupt' {
        'invalid json' | Set-Content "$TestDrive/corrupt.json"
        & $scriptPath -Results @((New-ReportResult)) -Organization org -RunId org/1 -OutputDirectory $TestDrive -HistoryPath "$TestDrive/corrupt.json"
        Get-Content "$TestDrive/psrule-dashboard.html" -Raw | Should -Match 'Historical dataset is unreadable'
        Test-Path "$TestDrive/assessment-snapshot.json" | Should -BeTrue
    }
}

Describe 'Historical dataset evidence validation' {
    It 'excludes a structurally invalid historical snapshot without breaking the current dashboard' {
        @{schemaVersion='1.0';snapshots=@(@{schemaVersion='1.0';runId='org/bad';results=@(@{outcome='Fail'})});limitations=@()} | ConvertTo-Json -Depth 10 | Set-Content "$TestDrive/invalid-history.json"
        & $scriptPath -Results @((New-ReportResult)) -Organization org -RunId org/1 -OutputDirectory $TestDrive -HistoryPath "$TestDrive/invalid-history.json"
        $html = Get-Content "$TestDrive/psrule-dashboard.html" -Raw
        $data = ([regex]::Match($html, '<script id="report-data" type="application/json">(.*?)</script>', 'Singleline')).Groups[1].Value | ConvertFrom-Json
        $data.history.snapshots.Count | Should -Be 0
        $data.history.limitations -join ' ' | Should -Match 'comparison metadata is missing'
        Test-Path "$TestDrive/assessment-snapshot.json" | Should -BeTrue
    }
}

Describe 'Template-looking finding text' {
    It 'preserves template placeholders inside assessment data as literal strings' {
        $literal = '__DASHBOARD_JS__ __DASHBOARD_CSS__ __REPORT_DATA__'
        $result = New-ReportResult Fail $literal
        & $scriptPath -Results @($result) -Organization org -RunId org/1 -OutputDirectory $TestDrive
        $html = Get-Content "$TestDrive/psrule-dashboard.html" -Raw
        $data = ([regex]::Match($html, '<script id="report-data" type="application/json">(.*?)</script>', 'Singleline')).Groups[1].Value | ConvertFrom-Json
        $data.results[0].ruleName | Should -Be $literal
    }
}
