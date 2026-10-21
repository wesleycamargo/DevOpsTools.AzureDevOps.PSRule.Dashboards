BeforeAll {
    $bundleScript = "$PSScriptRoot/../src/scripts/New-ProjectHealthPipelineBundle.ps1"
    $repo = (Resolve-Path "$PSScriptRoot/..").Path
}
Describe 'Classic Project Health task packaging' {
    It 'preserves every source byte and the repository layout in the compressed archive' {
        $bootstrap = & $bundleScript
        $encoded = [regex]::Match($bootstrap, "FromBase64String\('([^']+)'\)").Groups[1].Value
        $stream = [IO.MemoryStream]::new([Convert]::FromBase64String($encoded))
        $archive = [IO.Compression.ZipArchive]::new($stream)
        try {
            $archive.Entries.Count | Should -Be 10
            foreach ($entry in $archive.Entries) {
                $sourceBytes = [IO.File]::ReadAllBytes((Join-Path $repo $entry.FullName))
                $copy = [IO.MemoryStream]::new()
                $inputStream = $entry.Open()
                try {
                    $inputStream.CopyTo($copy)
                    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($copy.ToArray())) | Should -Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sourceBytes)))
                } finally { $inputStream.Dispose(); $copy.Dispose() }
            }
        } finally { $archive.Dispose(); $stream.Dispose() }
    }
    It 'fits in a task environment input and allows the Node worker to start' {
        $bootstrap = & $bundleScript
        [Text.Encoding]::UTF8.GetByteCount($bootstrap) | Should -BeLessThan 64KB
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Command node -CommandType Application | Select-Object -First 1).Source)
        $start.ArgumentList.Add('--version')
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.Environment['INPUT_INLINESCRIPT'] = $bootstrap
        $process = [Diagnostics.Process]::Start($start)
        try {
            $process.StandardOutput.ReadToEnd() | Should -Match '^v\d+'
            $process.WaitForExit(10000) | Should -BeTrue
            $process.ExitCode | Should -Be 0
        } finally { $process.Dispose() }
    }
    It 'extracts and invokes the reporter with report-only mode intact' {
        $source = Join-Path $TestDrive 'source'
        $bootstrap = & $bundleScript
        $encoded = [regex]::Match($bootstrap, "FromBase64String\('([^']+)'\)").Groups[1].Value
        $zip = Join-Path $TestDrive 'source.zip'
        [IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($encoded))
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $source)
        @'
param($ModuleManifestPath, [switch]$ReportOnly)
[pscustomobject]@{ ReportOnly = [bool]$ReportOnly; ModulePath = $ModuleManifestPath }
'@ | Set-Content (Join-Path $source 'src/scripts/Invoke-PSRuleWorkbookAssessment.ps1')
        $bootstrap = & $bundleScript -SourceRoot $source
        $previous = @{}
        try {
            foreach ($name in 'AGENT_TEMPDIRECTORY','BUILD_BUILDID','BUILD_SOURCESDIRECTORY','PSRULE_REPORT_ONLY') { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
            $env:AGENT_TEMPDIRECTORY = Join-Path $TestDrive 'agent'
            $env:BUILD_BUILDID = '42'
            $env:BUILD_SOURCESDIRECTORY = Join-Path $TestDrive 'checkout'
            $env:PSRULE_REPORT_ONLY = 'true'
            $result = & ([scriptblock]::Create($bootstrap))
            $result.ReportOnly | Should -BeTrue
            $result.ModulePath | Should -Be (Join-Path $env:BUILD_SOURCESDIRECTORY 'src/PSRule.Rules.AzureDevOps/PSRule.Rules.AzureDevOps.psd1')
            Test-Path (Join-Path $env:AGENT_TEMPDIRECTORY 'psrule-project-health-42/config/effort.json') | Should -BeTrue
        } finally {
            foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        }
    }
}
