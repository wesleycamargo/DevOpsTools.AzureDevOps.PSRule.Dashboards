BeforeAll {
    $historyScript = "$PSScriptRoot/../src/scripts/Get-AssessmentHistory.ps1"
    . "$PSScriptRoot/../src/scripts/AssessmentModel.ps1"
    function New-HistorySnapshot {
        param($RunId = 'org/10')
        New-AssessmentSnapshot -Results @([pscustomobject]@{ RuleName = 'R'; TargetName = 'resource'; TargetType = 'Repo'; Outcome = 'Fail' }) -Organization org -RunId $RunId -Timestamp ([datetime]'2026-01-01')
    }
}
Describe 'Historical artifact acquisition' {
    BeforeEach {
        $script:fixtureZip = Join-Path $TestDrive 'artifact.zip'
        $directory = Join-Path $TestDrive 'evidence'
        New-Item $directory -ItemType Directory -Force | Out-Null
        New-HistorySnapshot | ConvertTo-Json -Depth 30 | Set-Content "$directory/assessment-snapshot.json"
        if (Test-Path $script:fixtureZip) { Remove-Item $script:fixtureZip }
        [IO.Compression.ZipFile]::CreateFromDirectory($directory,$script:fixtureZip)
        Mock Invoke-RestMethod { @{ resource = @{ downloadUrl = 'https://dev.azure.com/org/project/_apis/build/builds/10/artifacts?format=zip' } } }
        Mock Invoke-WebRequest {
            param($Uri,$OutFile)
            if ($OutFile) { Copy-Item (Join-Path $TestDrive 'artifact.zip') $OutFile; return }
            if ($Uri -match 'continuationToken=next') { return @{ Content = '{"value":[{"id":10,"definition":{"id":17},"sourceBranch":"refs/heads/main"}]}'; Headers = @{} } }
            @{ Content = '{"value":[{"id":10,"definition":{"id":17},"sourceBranch":"refs/heads/main"},{"id":20,"definition":{"id":99},"sourceBranch":"refs/heads/other"}]}'; Headers = @{ 'x-ms-continuationtoken' = @('next') } }
        }
    }
    It 'paginates build history filters scope and deduplicates assessment runs' {
        $null = & $historyScript -Organization org -Project project -DefinitionId 17 -Token fake -OutputPath "$TestDrive/history.json"
        $history = Get-Content "$TestDrive/history.json" -Raw | ConvertFrom-Json
        $history.snapshots.Count | Should -Be 1
        $history.snapshots[0].runId | Should -Be 'org/10'
        Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $Uri -match 'continuationToken=next' }
    }
    It 'excludes unavailable artifacts without destroying the dataset' {
        Mock Invoke-RestMethod { throw '404' }
        $null = & $historyScript -Organization org -Project project -DefinitionId 17 -Token fake -OutputPath "$TestDrive/history.json"
        $history = Get-Content "$TestDrive/history.json" -Raw | ConvertFrom-Json
        $history.snapshots.Count | Should -Be 0
        $history.limitations -join ' ' | Should -Match 'unavailable or invalid'
    }
    It 'excludes corrupt archives and does not serialize authentication tokens' {
        'not a zip' | Set-Content $script:fixtureZip
        $null = & $historyScript -Organization org -Project project -DefinitionId 17 -Token secret-test-token -OutputPath "$TestDrive/history.json"
        Get-Content "$TestDrive/history.json" -Raw | Should -Not -Match secret-test-token
        (Get-Content "$TestDrive/history.json" -Raw | ConvertFrom-Json).snapshots.Count | Should -Be 0
    }
    It 'refuses to forward credentials to artifact URLs outside the configured organization' {
        Mock Invoke-RestMethod { @{ resource = @{ downloadUrl = 'https://example.test/artifact.zip' } } }
        $null = & $historyScript -Organization org -Project project -DefinitionId 17 -Token fake -OutputPath "$TestDrive/history.json"
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $OutFile }
    }
    It 'explains API permission failures and retains locally supplied snapshots' {
        New-HistorySnapshot | ConvertTo-Json -Depth 30 | Set-Content "$TestDrive/local.json"
        Mock Invoke-WebRequest { throw '403' }
        $null = & $historyScript -Organization org -Project project -DefinitionId 17 -Token fake -SnapshotPaths "$TestDrive/local.json" -OutputPath "$TestDrive/history.json"
        $history = Get-Content "$TestDrive/history.json" -Raw | ConvertFrom-Json
        $history.snapshots.Count | Should -Be 1
        $history.limitations -join ' ' | Should -Match 'Build Read'
    }
    It 'skips unsupported future versions and sorts local snapshots chronologically' {
        $future = New-HistorySnapshot org/2
        $future.schemaVersion = '2.0'
        $future | ConvertTo-Json -Depth 30 | Set-Content "$TestDrive/future.json"
        $new = New-HistorySnapshot org/11
        $new.timestamp = '2026-02-01T00:00:00Z'
        $new | ConvertTo-Json -Depth 30 | Set-Content "$TestDrive/new.json"
        New-HistorySnapshot | ConvertTo-Json -Depth 30 | Set-Content "$TestDrive/old.json"
        $null = & $historyScript -Organization org -Project project -DefinitionId 17 -SnapshotPaths @("$TestDrive/new.json","$TestDrive/future.json","$TestDrive/old.json") -OutputPath "$TestDrive/history.json" -Token ''
        $history = Get-Content "$TestDrive/history.json" -Raw | ConvertFrom-Json
        $history.snapshots.runId | Should -Be @('org/10','org/11')
        $history.limitations -join ' ' | Should -Match 'Unsupported snapshot'
    }
}

Describe 'Legacy and ambiguous artifact evidence' {
    It 'normalizes PSRule SARIF extension rules without inventing a compliance denominator' {
        $directory = Join-Path $TestDrive 'legacy'
        New-Item $directory -ItemType Directory | Out-Null
        @{
            runs = @(@{
                tool = @{driver=@{name='PSRule'};extensions=@(@{rules=@(@{id='R-001';name='Rule.Actual';shortDescription=@{text='Actual rule'}})})}
                results = @(@{rule=@{id='R-001'};level='error';message=@{text='Reason'};locations=@(@{logicalLocations=@(@{fullyQualifiedName='Repo/org.p.repo'})})})
            })
        } | ConvertTo-Json -Depth 15 | Set-Content "$directory/psrule-results.sarif"
        $zipPath = Join-Path $TestDrive 'legacy.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($directory,$zipPath)
        Mock Invoke-RestMethod { @{resource=@{downloadUrl='https://dev.azure.com/org/project/artifacts'}} }
        Mock Invoke-WebRequest {
            param($Uri,$OutFile)
            if ($OutFile) { Copy-Item (Join-Path $TestDrive 'legacy.zip') $OutFile; return }
            @{Content='{"value":[{"id":10,"definition":{"id":17},"sourceBranch":"refs/heads/main","finishTime":"2026-01-01T00:00:00Z"}]}';Headers=@{}}
        }
        $null = & $historyScript -Organization org -Project project -DefinitionId 17 -Token fake -OutputPath "$TestDrive/history.json"
        $history = Get-Content "$TestDrive/history.json" -Raw | ConvertFrom-Json
        $history.snapshots.Count | Should -Be 1
        $history.snapshots[0].results[0].ruleName | Should -Be 'Rule.Actual'
        $history.snapshots[0].statistics.failed | Should -Be 1
        $history.snapshots[0].statistics.compliance | Should -BeNullOrEmpty
        $history.snapshots[0].legacy | Should -BeTrue
    }
}
