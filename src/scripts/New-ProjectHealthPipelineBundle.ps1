[CmdletBinding()]
param([string]$SourceRoot = "$PSScriptRoot/../..")
$ErrorActionPreference = 'Stop'
# Classic task inputs become environment variables; keep the bootstrap small.
$files = @(
    'src/scripts/AssessmentModel.ps1', 'src/scripts/ProjectHealthReport.ps1',
    'src/scripts/Export-PSRulePipelineReport.ps1', 'src/scripts/Get-AssessmentHistory.ps1',
    'src/scripts/Invoke-PSRuleWorkbookAssessment.ps1', 'src/scripts/Publish-PSRuleWorkbookResults.ps1',
    'src/templates/psrule-dashboard.html', 'src/templates/assessment.css',
    'src/templates/assessment.js', 'config/effort.json'
)
$stream = [IO.MemoryStream]::new()
try {
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($file in $files) {
            $entry = $archive.CreateEntry($file, [IO.Compression.CompressionLevel]::Optimal)
            $output = $entry.Open()
            try {
                $bytes = [IO.File]::ReadAllBytes((Join-Path $SourceRoot $file))
                $output.Write($bytes, 0, $bytes.Length)
            } finally { $output.Dispose() }
        }
    } finally { $archive.Dispose() }
    $encoded = [Convert]::ToBase64String($stream.ToArray())
} finally { $stream.Dispose() }
$bootstrap = @'
$ErrorActionPreference = 'Stop'
$reportRoot = Join-Path $env:AGENT_TEMPDIRECTORY "psrule-project-health-$($env:BUILD_BUILDID)"
New-Item $reportRoot -ItemType Directory -Force | Out-Null
$bundle = Join-Path $reportRoot 'report-bundle.zip'
[IO.File]::WriteAllBytes($bundle, [Convert]::FromBase64String('__BUNDLE__'))
[IO.Compression.ZipFile]::ExtractToDirectory($bundle, $reportRoot, $true)
Remove-Item -LiteralPath $bundle
$modulePath = Join-Path $env:BUILD_SOURCESDIRECTORY 'src/PSRule.Rules.AzureDevOps/PSRule.Rules.AzureDevOps.psd1'
& (Join-Path $reportRoot 'src/scripts/Invoke-PSRuleWorkbookAssessment.ps1') -ModuleManifestPath $modulePath -ReportOnly:($env:PSRULE_REPORT_ONLY -eq 'true')
'@
$bootstrap = $bootstrap.Replace('__BUNDLE__', $encoded)
if ([Text.Encoding]::UTF8.GetByteCount($bootstrap) -ge 64KB) { throw 'The compressed report bundle exceeds the safe classic task input size.' }
$bootstrap
