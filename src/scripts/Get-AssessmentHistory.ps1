[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][int]$DefinitionId,
    [string]$Branch = 'refs/heads/main',
    [int]$CurrentBuildId,
    [ValidateRange(1,1000)][int]$MaxRuns = 50,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$Token = $env:SYSTEM_ACCESSTOKEN,
    [ValidateSet('Bearer','Basic')][string]$Authentication = 'Bearer',
    [string[]]$SnapshotPaths = @()
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/AssessmentModel.ps1"
$snapshots = [Collections.Generic.List[object]]::new()
$limitations = [Collections.Generic.List[string]]::new()
$limitations.Add('History is limited by pipeline artifact retention; missing runs are not evidence of improvement.')
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
function Add-HistorySnapshot {
    param($Snapshot)
    Assert-AssessmentSnapshot -Snapshot $Snapshot -Organization $Organization
    $key = "$($Snapshot.organization)/$($Snapshot.runId)"
    if ($seen.Add($key)) { $snapshots.Add($Snapshot) }
}
foreach ($path in $SnapshotPaths) {
    try { Add-HistorySnapshot (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable) }
    catch { $limitations.Add("Local snapshot excluded: $([IO.Path]::GetFileName($path)). $($_.Exception.Message)") }
}
if ($Token) {
    $org = [uri]::EscapeDataString($Organization)
    $proj = [uri]::EscapeDataString($Project)
    $base = "https://dev.azure.com/$org/$proj/_apis/build"
    $credential = if ($Authentication -eq 'Basic') { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$Token")) } else { $Token }
    $headers = @{ Authorization = "$Authentication $credential" }
    $continuation = ''
    $count = 0
    $buildIds = [Collections.Generic.HashSet[int]]::new()
    $pages = [Collections.Generic.HashSet[string]]::new()
    try {
        do {
            $uri = "$base/builds?definitions=$DefinitionId&branchName=$([uri]::EscapeDataString($Branch))&statusFilter=completed&queryOrder=finishTimeDescending&`$top=100&api-version=7.1"
            if ($continuation) { $uri += "&continuationToken=$([uri]::EscapeDataString($continuation))" }
            $page = Invoke-WebRequest -Uri $uri -Headers $headers
            $builds = ($page.Content | ConvertFrom-Json).value
            foreach ($build in $builds) {
                if ($count -ge $MaxRuns) { break }
                if ($build.id -eq $CurrentBuildId -or $build.sourceBranch -ne $Branch -or $build.definition.id -ne $DefinitionId) { continue }
                if (-not $buildIds.Add([int]$build.id)) { continue }
                $count++
                $temp = Join-Path ([IO.Path]::GetTempPath()) "assessment-history-$([guid]::NewGuid().ToString('N'))"
                try {
                    $artifact = Invoke-RestMethod -Uri "$base/builds/$($build.id)/artifacts?artifactName=psrule-results&api-version=7.1" -Headers $headers
                    $download = [uri]$artifact.resource.downloadUrl
                    # Bearer credentials are sent only to the configured Azure DevOps organization.
                    if ($download.Scheme -ne 'https' -or $download.Host -ne 'dev.azure.com' -or -not $download.AbsolutePath.StartsWith("/$org/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Artifact download URL is outside the configured organization.' }
                    New-Item $temp -ItemType Directory | Out-Null
                    $zip = Join-Path $temp 'artifact.zip'
                    Invoke-WebRequest -Uri $download.AbsoluteUri -Headers $headers -OutFile $zip | Out-Null
                    # Read only named evidence entries; never extract arbitrary archive paths.
                    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
                    try {
                        $entries = @($archive.Entries | Where-Object { $_.Name -eq 'assessment-snapshot.json' })
                        if ($entries.Count -gt 1) { throw 'Artifact contains multiple snapshots.' }
                        if ($entries.Count -eq 1) {
                            if ($entries[0].Length -gt 100MB) { throw 'Snapshot exceeds the supported size.' }
                            $reader = [IO.StreamReader]::new($entries[0].Open())
                            try { $snapshot = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $reader.Dispose() }
                        } else {
                            $sarifEntries = @($archive.Entries | Where-Object { $_.Name -eq 'psrule-results.sarif' })
                            if ($sarifEntries.Count -ne 1) { throw 'No unique assessment snapshot or legacy SARIF evidence.' }
                            if ($sarifEntries[0].Length -gt 100MB) { throw 'SARIF exceeds the supported size.' }
                            $reader = [IO.StreamReader]::new($sarifEntries[0].Open())
                            try { $sarif = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                            $legacy = @($sarif.runs | ForEach-Object {
                                $run = $_
                                foreach ($result in $run.results) {
                                    $ruleId = if ($result.ruleId) { $result.ruleId } else { $result.rule.id }
                                    $descriptors = @($run.tool.driver.rules) + @($run.tool.extensions | ForEach-Object { $_.rules })
                                    $rule = $descriptors | Where-Object id -eq $ruleId | Select-Object -First 1
                                    $outcome = switch ($result.kind) { 'pass' { 'Pass' }; 'fail' { 'Fail' }; 'notApplicable' { 'None' }; default { $(if ($run.tool.driver.name -eq 'PSRule') { 'Fail' } else { 'Unknown' }) } }
                                    [pscustomobject]@{ RuleName = $(if ($rule.name) { $rule.name } else { $ruleId }); TargetName = $result.locations[0].logicalLocations[0].fullyQualifiedName; TargetType = 'Unknown'; Outcome = $outcome; Reason = $result.message.text; Info = @{ DisplayName = $rule.shortDescription.text; Description = $rule.fullDescription.text; Recommendation = $rule.messageStrings.recommendation.text; HelpUri = $rule.helpUri; Annotations = @{ severity = $result.level } } }
                                }
                            })
                            if (-not $legacy.Count) { throw 'Legacy SARIF contains no checkpoints.' }
                            $snapshot = New-AssessmentSnapshot -Results $legacy -Organization $Organization -RunId "$Organization/$($build.id)" -Timestamp ([datetime]$build.finishTime)
                            $snapshot.legacy = $true
                            $snapshot.statistics.compliance = $null
                            $snapshot.coverage = 'Legacy SARIF; total assessment denominator unavailable'
                            $limitations.Add("Run $($build.id): legacy SARIF may contain failures only and has unverified identity, coverage and configuration; compliance and lifecycle comparisons are unavailable.")
                        }
                        if ($snapshot.runId -ne "$Organization/$($build.id)") { throw 'Snapshot run identity does not match its build.' }
                        Add-HistorySnapshot $snapshot
                    } finally { $archive.Dispose() }
                } catch { $limitations.Add("Run $($build.id): artifact unavailable or invalid; excluded from history.") }
                finally { if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Recurse -Force } }
            }
            $continuation = [string](@($page.Headers['x-ms-continuationtoken'])[0])
            if ($continuation -and -not $pages.Add($continuation)) { throw 'Repeated build continuation token.' }
        } while ($continuation -and $count -lt $MaxRuns)
        if ($count -ge $MaxRuns) { $limitations.Add("History discovery capped at $MaxRuns candidate runs.") }
    } catch { $limitations.Add('Historical API discovery failed. Check Build Read permission and pipeline token access; current assessment evidence is retained.') }
} elseif (-not $SnapshotPaths.Count) { $limitations.Add('Historical authentication unavailable. Supply the pipeline System.AccessToken with Build Read permission.') }
$history = [ordered]@{ schemaVersion = '1.0'; snapshots = @($snapshots | Sort-Object { [datetime]$_.timestamp }); limitations = @($limitations) }
$history | ConvertTo-Json -Depth 40 -EscapeHandling EscapeHtml | Set-Content -LiteralPath $OutputPath -Encoding utf8
$history
