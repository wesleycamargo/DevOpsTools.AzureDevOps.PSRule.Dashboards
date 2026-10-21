# Shared snapshot contract and aggregation. No credentials or target objects are serialized.
function Get-AssessmentText {
    param($Value, [string]$Default = 'Unknown')
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
    return [string]$Value
}
function Get-AssessmentSeverity {
    param($Value)
    switch -Regex (([string]$Value).Trim()) {
        '^(critical)$' { 'Critical'; break }
        '^(severe|important|error|high)$' { 'High'; break }
        '^(warning|warn|moderate|medium)$' { 'Medium'; break }
        '^(information|informational|info|low)$' { 'Low'; break }
        default { 'Unknown' }
    }
}
function ConvertTo-AssessmentCanonicalValue {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        $keys = [string[]]@($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $ordered[$key] = ConvertTo-AssessmentCanonicalValue $Value[$key] }
        return $ordered
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-AssessmentCanonicalValue $item)) }
        return ,$items.ToArray()
    }
    if ($null -ne $Value -and $Value -isnot [ValueType] -and $Value -isnot [string]) {
        $properties = @{}
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.IsGettable) { $properties[$property.Name] = $property.Value }
        }
        return ConvertTo-AssessmentCanonicalValue $properties
    }
    return $Value
}
function Get-AssessmentHash {
    param($Value)
    $json = ConvertTo-Json -InputObject (ConvertTo-AssessmentCanonicalValue $Value) -Depth 30 -Compress
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}
function Get-AssessmentConfiguration {
    param([string]$ModuleManifestPath, [string]$Baseline, $Option, [string]$PSRuleVersion)
    $sourceFiles = @()
    if (Test-Path -LiteralPath $ModuleManifestPath) {
        $moduleDirectory = Split-Path ([IO.Path]::GetFullPath($ModuleManifestPath))
        $sourceFiles = @(Get-ChildItem -LiteralPath $moduleDirectory -File -Recurse | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.yaml', '.yml', '.md' } | Sort-Object FullName)
    }
    $rulesetHash = if ($sourceFiles.Count) {
        Get-AssessmentHash @($sourceFiles | ForEach-Object { [ordered]@{ path = [IO.Path]::GetRelativePath($moduleDirectory, $_.FullName); hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } })
    } else { 'Unknown' }
    [ordered]@{
        baseline = $Baseline; ruleset = 'PSRule.Rules.AzureDevOps'; rulesetHash = $rulesetHash
        optionHash = Get-AssessmentHash $Option; psruleVersion = $PSRuleVersion; culture = 'en'
    }
}
function Get-AssessmentStatistics {
    param([object[]]$Records)
    $passed = @($Records | Where-Object outcome -eq Pass).Count
    $failed = @($Records | Where-Object outcome -eq Fail).Count
    $applicable = $passed + $failed
    [ordered]@{
        total = $Records.Count; passed = $passed; failed = $failed
        ignored = @($Records | Where-Object outcome -eq Ignore).Count
        errors = @($Records | Where-Object outcome -eq Error).Count
        applicable = $applicable
        compliance = $(if ($applicable) { [math]::Round(100 * $passed / $applicable, 1) } else { $null })
        outcomes = @($Records | Group-Object outcome | ForEach-Object { @{ outcome = $_.Name; count = $_.Count } })
        rules = @($Records.ruleName | Sort-Object -Unique).Count
        resources = @($Records.resourceKey | Sort-Object -Unique).Count
    }
}
function Assert-AssessmentSnapshot {
    param($Snapshot, [string]$Organization)
    if ($Snapshot.schemaVersion -ne '1.0') { throw 'Unsupported snapshot version; this run was excluded.' }
    if (-not $Snapshot.module -or -not $Snapshot.configurationHash -or -not $Snapshot.collection -or -not $Snapshot.configuration -or -not $Snapshot.evaluation) { throw 'Snapshot comparison metadata is missing.' }
    if (-not $Snapshot.runId -or -not $Snapshot.timestamp -or $Snapshot.results -isnot [array] -or -not $Snapshot.results.Count) { throw 'Snapshot has no valid assessment evidence.' }
    $null = [datetime]::Parse($Snapshot.timestamp)
    if ($Snapshot.organization -ne $Organization) { throw 'Snapshot belongs to another organization.' }
    foreach ($record in $Snapshot.results) {
        if ($record.identityComplete -isnot [bool]) { throw 'Checkpoint identity completeness is missing or invalid.' }
        foreach ($field in 'fingerprint', 'resourceKey', 'ruleName', 'project', 'category', 'targetType', 'targetName', 'resourceName', 'displayName', 'severity', 'outcome') {
            if ($record.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($record.$field)) { throw 'Snapshot contains an invalid checkpoint.' }
        }
        if ($record.fingerprint -cnotmatch '^[a-f0-9]{64}$' -or $record.resourceKey -cnotmatch '^[a-f0-9]{64}$') { throw 'Snapshot checkpoint fingerprints are invalid.' }
    }
}
function New-AssessmentSnapshot {
    param([object[]]$Results, [string]$Organization, [string]$RunId, [datetime]$Timestamp,
        $Collection, $Configuration, $Evaluation, [string]$ModuleVersion = 'Unknown', [string]$RuleHelpPath)
    $records = @($Results | ForEach-Object {
        $result = $_
        $id = $result.TargetObject.id
        if ($id -isnot [pscustomobject] -and $id -isnot [Collections.IDictionary]) { $id = $result.Field.id }
        if ($id -is [string]) { try { $id = $id | ConvertFrom-Json -ErrorAction Stop } catch { $id = $null } }
        $rule = Get-AssessmentText $result.RuleName
        $project = Get-AssessmentText $id.project
        $type = Get-AssessmentText $result.TargetType
        if ($project -eq 'Unknown' -and $type -like 'Azure.DevOps.Organization*') { $project = '(organization)' }
        $target = Get-AssessmentText $result.TargetName
        $org = Get-AssessmentText $id.organization $Organization
        $resource = Get-AssessmentText $id.resourceId (Get-AssessmentText $id.resourceName $target)
        $resourceKey = Get-AssessmentHash @($org, $project, $type, $resource, $target)
        $metadata = $result.Info.Annotations
        $description = Get-AssessmentText $result.Info.Description ''
        $recommendation = Get-AssessmentText $result.Info.Recommendation ''
        $documentation = Get-AssessmentText $result.Info.HelpUri ''
        $references = @()
        $category = Get-AssessmentText $metadata.category
        $severity = Get-AssessmentSeverity $metadata.severity
        if ($RuleHelpPath -and $rule -notmatch '[/\\]' -and (Test-Path -LiteralPath (Join-Path $RuleHelpPath "$rule.md"))) {
            $help = Get-Content -LiteralPath (Join-Path $RuleHelpPath "$rule.md") -Raw
            $frontMatter = if ($help -match '(?s)\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)') { $Matches[1] } else { '' }
            if ($frontMatter -match '(?m)^category:[ \t]*(.+)$') { $category = $Matches[1].Trim() }
            if ($frontMatter -match '(?m)^severity:[ \t]*(.+)$') { $severity = Get-AssessmentSeverity $Matches[1].Trim() }
            if ($frontMatter -match '(?m)^online version:[ \t]*(.+)$') { $documentation = $Matches[1].Trim() }
            if ($help -match '(?s)## DESCRIPTION\s*(.*?)(?=\r?\n## |\z)') { $description = $Matches[1].Trim() }
            if ($help -match '(?s)## RECOMMENDATION\s*(.*?)(?=\r?\n## |\z)') { $recommendation = $Matches[1].Trim() }
            $references = @([regex]::Matches($help, '\[([^\]]+)\]\((https://[^)]+)\)') | ForEach-Object { @{ title = $_.Groups[1].Value; url = $_.Groups[2].Value } })
        }
        [pscustomobject][ordered]@{
            fingerprint = Get-AssessmentHash @($org, $project, $type, $resource, $target, $rule)
            identityComplete = ($rule -ne 'Unknown' -and $org -ne 'Unknown' -and $project -ne 'Unknown' -and $type -ne 'Unknown' -and $target -ne 'Unknown' -and $resource -ne 'Unknown')
            resourceKey = $resourceKey; organization = $org; project = $project
            ruleName = $rule; displayName = Get-AssessmentText $result.Info.DisplayName
            targetName = $target; targetType = $type; resourceName = Get-AssessmentText $id.resourceName $target
            outcome = Get-AssessmentText $result.Outcome; severity = $severity; category = $category
            description = $description; recommendation = $recommendation; documentation = $documentation
            references = $references; reason = (@($result.Reason) -join '; ')
        }
    })
    if (-not $Collection) { $Collection = @{ Status = 'Unknown'; Projects = @() } }
    if (-not $Evaluation) { $Evaluation = @{ Status = 'Unknown'; ErrorCount = @($records | Where-Object outcome -eq Error).Count } }
    if (-not $Configuration) { $Configuration = @{ baseline = 'Unknown'; ruleset = 'Unknown' } }
    [ordered]@{
        schemaVersion = '1.0'; organization = $Organization; runId = $RunId; timestamp = $Timestamp.ToUniversalTime().ToString('o')
        module = @{ name = 'PSRule.Rules.AzureDevOps'; version = $ModuleVersion }
        configuration = $Configuration; configurationHash = Get-AssessmentHash $Configuration
        collection = $Collection; evaluation = $Evaluation; projects = @($records.project | Sort-Object -Unique)
        evaluatedRules = @($records.ruleName | Sort-Object -Unique); evaluatedResources = @($records.resourceKey | Sort-Object -Unique)
        statistics = Get-AssessmentStatistics $records; results = $records
        maturity = @{ schemaVersion = '1.0'; scale = @(0,1,2,3,4); dimensions = @('People','Process','Technology'); evidence = @(); score = $null }
    }
}
