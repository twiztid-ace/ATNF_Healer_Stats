# build_boss_analysis.ps1
#
# Reads a character's {ReportCode}_report_data.json (already produced by
# build_boss_report_data.ps1 - zero API calls, zero raw-event re-reads) and
# writes a companion {ReportCode}_analysis.json that pre-flags every
# SCRIPT-SAFE numeric judgment call the generate-healer-report skill's rules
# describe (deviation ratios vs. benchmark, cooldown over/undercast flags,
# self-death detection, nearest-cooldown-to-death lookups, gear enchant
# gaps) - so the one remaining LLM step (authoring {ReportCode}_findings.json)
# is verification/wording/prioritization, not raw arithmetic across 10 bosses.
#
# Every value this script produces is a fact or a small enum/boolean flag,
# never a sentence. Genuinely open-ended judgment calls (Rebirth's "was this
# death actually plausible to answer", death-vs-cooldown timing correlation
# with no defined time window, cross-boss spell-gap narrative consistency)
# are deliberately NOT resolved here - this script gathers the raw candidate
# facts for those and leaves the actual judgment to whoever authors
# findings.json, per generate-healer-report's own "this step cannot be
# mechanical" rule.
#
# Usage (run from repo root, same convention as every other script here):
#   powershell -ExecutionPolicy Bypass -File scripts\build_boss_analysis.ps1 -CharacterName "Crowns" -ReportCode "XJp8vAxzM4KtHYyb" -ClassName "Paladin"
#
# Output: data\Characters\{CharacterName}\{raidDate}\{ReportCode}_analysis.json
# (same folder as report_data.json - raidDate resolved by locating that file).

param(
    [Parameter(Mandatory=$true)][string]$CharacterName,
    [Parameter(Mandatory=$true)][string]$ReportCode,
    [Parameter(Mandatory=$true)][string]$ClassName,
    [string]$CharactersRoot = "data\Characters"
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "lib\ReportRenderLib.psm1") -Force

# ----- Locate report_data.json (same search pattern build_boss_report_data.ps1
# uses to locate fights_{ReportCode}.json - search rather than require a
# -DateFolder param). -----
$charRoot = Join-Path $CharactersRoot $CharacterName
if (-not (Test-Path $charRoot)) {
    Write-Host "ERROR: $charRoot not found."
    exit 1
}
$reportDataFile = Get-ChildItem -Path $charRoot -Recurse -Filter "$($ReportCode)_report_data.json" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $reportDataFile) {
    Write-Host "ERROR: no $($ReportCode)_report_data.json found under $charRoot - run build_boss_report_data.ps1 -CharacterName $CharacterName -ReportCode $ReportCode -ClassName $ClassName first."
    exit 1
}
$charDir = $reportDataFile.DirectoryName
Write-Host "Report data folder: $charDir"

$reportData = Get-Content $reportDataFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-DeviationFlag {
    param([double]$RatioToAvg)
    if ($RatioToAvg -lt 0.9) { return "below_avg" }
    if ($RatioToAvg -gt 1.1) { return "above_avg" }
    return "in_line"
}

function Get-GapFlag {
    param([double]$GapPoints)
    if ($GapPoints -lt -10) { return "below_avg" }
    if ($GapPoints -gt 10) { return "above_avg" }
    return "in_line"
}

function Get-OverhealFlag {
    param([double]$Value, [double]$Worst)
    if ($Value -gt $Worst) { return "exceeds_worst" }
    if ($Value -ge ($Worst - 5)) { return "near_worst" }
    return "in_line"
}

# Parses a BMSpells "Spell" string like "Chain Heal (guid 25423)" into
# {Name, Guid (nullable)} - guid annotation only appears when the benchmark
# script found a real same-name/different-guid ambiguity for that spell on
# that boss (see summarize_class_benchmarks.ps1's Add-GuidAggregate).
function Split-BMSpellString {
    param([string]$SpellString)
    if ($SpellString -match '^(.*)\s\(guid (\d+)\)$') {
        return [PSCustomObject]@{ Name = $Matches[1]; Guid = [int]$Matches[2] }
    }
    return [PSCustomObject]@{ Name = $SpellString; Guid = $null }
}

$bossResults = [ordered]@{}
$deathCountRows = @()
$overhealExceedsWorst = @()
$selfDeathBosses = @()
$lowestPercentile = @()
$cooldownDeviationsByAbility = [ordered]@{}

foreach ($bossProp in $reportData.Bosses.PSObject.Properties) {
    $slug = $bossProp.Name
    $boss = $bossProp.Value
    $bm = $boss.BM

    # ----- Deviations -----
    $deviations = [ordered]@{}

    if ($bm) {
        $hpsAvg = ConvertTo-BMNumber $bm.HPS_Top100Avg
        if ($null -ne $hpsAvg -and $hpsAvg -gt 0) {
            $ratio = [math]::Round($boss.HPS / $hpsAvg, 2)
            $deviations["HPS"] = [ordered]@{
                Value = $boss.HPS; Top1 = ConvertTo-BMNumber $bm.HPS_Top1; Top100Avg = $hpsAvg
                Median = ConvertTo-BMNumber $bm.HPS_Median; RatioToAvg = $ratio; Flag = Get-DeviationFlag $ratio
            }
        }
        $overhealWorst = ConvertTo-BMNumber $bm.Overheal_Worst
        if ($null -ne $overhealWorst) {
            $gapToWorst = [math]::Round($boss.OverhealPct - $overhealWorst, 1)
            $flag = Get-OverhealFlag $boss.OverhealPct $overhealWorst
            $deviations["Overheal"] = [ordered]@{
                Value = $boss.OverhealPct; Best = ConvertTo-BMNumber $bm.Overheal_Best; Median = ConvertTo-BMNumber $bm.Overheal_Median
                Worst = $overhealWorst; GapToWorst = $gapToWorst; Flag = $flag
            }
            if ($flag -eq "exceeds_worst") { $overhealExceedsWorst += $slug }
        }
        $atAvg = ConvertTo-BMNumber $bm.ActiveTime_Top100Avg
        if ($null -ne $atAvg -and $null -ne $boss.ActiveTimePct) {
            $gap = [math]::Round($boss.ActiveTimePct - $atAvg, 1)
            $deviations["ActiveTime"] = [ordered]@{
                Value = $boss.ActiveTimePct; Top1 = ConvertTo-BMNumber $bm.ActiveTime_Top1; Top100Avg = $atAvg
                Median = ConvertTo-BMNumber $bm.ActiveTime_Median; GapToAvg = $gap; Flag = Get-GapFlag $gap
            }
        }
        $hpmSampleUsed = ConvertTo-BMNumber $bm.HPM_SampleUsed
        $hpmAvg = ConvertTo-BMNumber $bm.HPM_Top100Avg
        $omitHpm = ($null -eq $hpmSampleUsed -or $hpmSampleUsed -eq 0)
        if (-not $omitHpm -and $null -ne $hpmAvg -and $hpmAvg -gt 0 -and $null -ne $boss.HPM) {
            $ratio = [math]::Round($boss.HPM / $hpmAvg, 2)
            $deviations["HPM"] = [ordered]@{
                Value = $boss.HPM; Top1 = ConvertTo-BMNumber $bm.HPM_Top1; Top100Avg = $hpmAvg
                Median = ConvertTo-BMNumber $bm.HPM_Median; RatioToAvg = $ratio; Flag = Get-DeviationFlag $ratio; Omit = $false
            }
        } elseif ($omitHpm) {
            $deviations["HPM"] = [ordered]@{ Omit = $true }
        }
        $tcAvg = ConvertTo-BMNumber $bm.Top100_TargetCoveragePct
        if ($null -ne $tcAvg) {
            $gap = [math]::Round($boss.CoveragePct - $tcAvg, 1)
            $deviations["TargetCoverage"] = [ordered]@{ Value = $boss.CoveragePct; Top100Avg = $tcAvg; GapPoints = $gap; Flag = Get-GapFlag $gap }
        }
        $topAvg = ConvertTo-BMNumber $bm.Top100_TargetTop1Pct
        if ($null -ne $topAvg) {
            $gap = [math]::Round($boss.Top1Pct - $topAvg, 1)
            $deviations["Top1Concentration"] = [ordered]@{ Value = $boss.Top1Pct; Top100Avg = $topAvg; GapPoints = $gap; Flag = Get-GapFlag $gap }
        }
    }

    # ----- Spell gaps (union of character SpellRows + BMSpells, guid-matched
    # where the benchmark string annotates one, name-matched otherwise) -----
    $charByGuid = @{}
    $charByName = [ordered]@{}
    foreach ($row in @($boss.SpellRows)) {
        $charByGuid[[int]$row.Guid] = $row
        if (-not $charByName.Contains($row.Name)) { $charByName[$row.Name] = New-Object System.Collections.Generic.List[object] }
        $charByName[$row.Name].Add($row)
    }
    $matchedGuids = @{}
    $spellGaps = @()
    foreach ($bmSpell in @($boss.BMSpells)) {
        $parsed = Split-BMSpellString $bmSpell.Spell
        $bmPct = ConvertTo-BMNumber $bmSpell.Top100Pct
        if ($null -eq $bmPct) { $bmPct = 0 }
        $charRow = $null
        if ($parsed.Guid) {
            if ($charByGuid.ContainsKey($parsed.Guid)) { $charRow = $charByGuid[$parsed.Guid] }
        } elseif ($charByName.Contains($parsed.Name)) {
            foreach ($candidate in $charByName[$parsed.Name]) {
                if (-not $matchedGuids.ContainsKey([int]$candidate.Guid)) { $charRow = $candidate; break }
            }
        }
        $charPct = 0.0
        $guidOut = $parsed.Guid
        if ($charRow) {
            $charPct = $charRow.Pct
            $guidOut = [int]$charRow.Guid
            $matchedGuids[[int]$charRow.Guid] = $true
        }
        $gap = [math]::Round($charPct - $bmPct, 1)
        $spellGaps += [PSCustomObject]@{
            Guid = $guidOut; Name = $parsed.Name; CharacterPct = $charPct; BenchmarkPct = $bmPct
            GapPoints = $gap; BenchmarkOnly = ($null -eq $charRow)
        }
    }
    # Character-only spells (never appear in the benchmark at all)
    foreach ($row in @($boss.SpellRows)) {
        if (-not $matchedGuids.ContainsKey([int]$row.Guid)) {
            $spellGaps += [PSCustomObject]@{
                Guid = [int]$row.Guid; Name = $row.Name; CharacterPct = $row.Pct; BenchmarkPct = 0.0
                GapPoints = [math]::Round($row.Pct, 1); BenchmarkOnly = $false; CharacterOnly = $true
            }
        }
    }
    $topSpellGap = $null
    if ($spellGaps.Count -gt 0) {
        $topSpellGap = $spellGaps | Sort-Object -Property { [math]::Abs($_.GapPoints) } -Descending | Select-Object -First 1
        $topSpellGap = [PSCustomObject]@{ Guid = $topSpellGap.Guid; Name = $topSpellGap.Name; GapPoints = $topSpellGap.GapPoints }
    }

    # ----- Spell RANKS: which real guid(s) of a same-named spell were in play
    # this kill, for the character and/or the Top 100 sample. WCL's API has no
    # "rank" field anywhere (confirmed live via schema introspection 2026-07-15
    # - GameAbility only has id/icon/name) - real per-guid mana cost (this
    # kill's own classResources data, see build_boss_report_data.ps1) is the
    # only available signal for which rank is "higher", and it's only ever
    # known for guids the character actually cast this kill. Reuses $spellGaps
    # (already union-matched by guid/name above) rather than re-deriving the
    # match - only surfaced when a name genuinely has 2+ distinct real guids in
    # play (a single-rank spell gets no row here at all, per the
    # generate-healer-report skill's "only show when it's actually relevant"
    # rule) - never invents a numbered "Rank N" label, since WCL doesn't
    # provide one and this project never guesses at real game data. -----
    $manaCostByGuid = if ($boss.PSObject.Properties.Name -contains "ManaCostByGuid") { $boss.ManaCostByGuid } else { $null }
    $gapsByName = [ordered]@{}
    foreach ($g in $spellGaps) {
        if (-not $gapsByName.Contains($g.Name)) { $gapsByName[$g.Name] = New-Object System.Collections.Generic.List[object] }
        $gapsByName[$g.Name].Add($g)
    }
    $spellRanks = @()
    foreach ($name in $gapsByName.Keys) {
        # .ToArray(), NOT @($gapsByName[$name]) - the value is a
        # System.Collections.Generic.List[object], and wrapping a List[object]
        # in @() throws "Argument types do not match" on Windows PowerShell
        # 5.1 (same gotcha documented in WclV2Api.psm1's Invoke-WclGraphQLPaged).
        $group = $gapsByName[$name].ToArray()
        if ($group.Count -lt 2) { continue }
        $rankRows = @()
        foreach ($g in $group) {
            $manaCost = $null
            if ($manaCostByGuid -and $g.Guid) {
                $key = [string]$g.Guid
                if ($manaCostByGuid.PSObject.Properties.Name -contains $key) { $manaCost = $manaCostByGuid.$key }
            }
            $rankRows += [PSCustomObject]@{
                Guid = $g.Guid; ManaCost = $manaCost; CharacterPct = $g.CharacterPct; BenchmarkPct = $g.BenchmarkPct
            }
        }
        $rankRows = @($rankRows | Sort-Object -Property @{Expression = { if ($null -ne $_.ManaCost) { $_.ManaCost } else { [double]::MaxValue } }})
        $spellRanks += [PSCustomObject]@{ Name = $name; Ranks = $rankRows }
    }

    # ----- Cooldown deviations -----
    $cooldowns = [ordered]@{}
    $bmCdByAbility = @{}
    foreach ($cd in @($boss.BMCooldowns)) { $bmCdByAbility[$cd.Ability] = $cd }
    foreach ($cdProp in $boss.CooldownRows.PSObject.Properties) {
        $abilityName = $cdProp.Name
        $cdRow = $cdProp.Value
        $mode = Get-CooldownTargetMode -ClassName $ClassName -AbilityName $abilityName
        $targetLabel = Format-CooldownTarget -TargetsArray $cdRow.Targets -Mode $mode
        $bmCd = $bmCdByAbility[$abilityName]
        $usedPct = if ($bmCd) { ConvertTo-BMNumber $bmCd.Top100UsedPct } else { $null }
        $avgCasts = if ($bmCd) { ConvertTo-BMNumber $bmCd.Top100AvgCasts } else { $null }
        $selfPct = if ($bmCd) { ConvertTo-BMNumber $bmCd.Top100SelfPct } else { $null }
        $deviates = Test-CooldownDeviates -Count $cdRow.Count -Top100UsedPct $usedPct
        $direction = if ($deviates) { if ($cdRow.Count -eq 0) { "undercast" } else { "overcast" } } else { $null }
        $cooldowns[$abilityName] = [ordered]@{
            Count = $cdRow.Count; SelfCount = $cdRow.SelfCount; TargetLabel = $targetLabel
            Top100AvgCasts = $avgCasts; Top100UsedPct = $usedPct; Top100SelfPct = $selfPct
            Deviates = $deviates; DeviationDirection = $direction
        }
        if ($deviates) {
            if (-not $cooldownDeviationsByAbility.Contains($abilityName)) {
                $cooldownDeviationsByAbility[$abilityName] = [ordered]@{ UndercastBosses = @(); OvercastBosses = @() }
            }
            if ($direction -eq "undercast") { $cooldownDeviationsByAbility[$abilityName]["UndercastBosses"] += $slug }
            else { $cooldownDeviationsByAbility[$abilityName]["OvercastBosses"] += $slug }
        }
    }

    $tranquilityInclude = $null
    $rebirthCandidates = $null
    if ($ClassName -eq "Druid") {
        if ($boss.CooldownRows.PSObject.Properties.Name -contains "Tranquility") {
            $tqRow = $boss.CooldownRows."Tranquility"
            $tqBm = $bmCdByAbility["Tranquility"]
            $tqUsedPct = if ($tqBm) { ConvertTo-BMNumber $tqBm.Top100UsedPct } else { $null }
            $tranquilityInclude = Test-TranquilityInclude -Count $tqRow.Count -Top100UsedPct $tqUsedPct
        }
        if ($boss.CooldownRows.PSObject.Properties.Name -contains "Rebirth") {
            $rbRow = $boss.CooldownRows."Rebirth"
            $rebirthCandidates = [ordered]@{ Deaths = $boss.DeathList; RebirthCasts = $rbRow.Targets }
        }
    }

    # ----- Self-deaths (mechanical string-match, no time-window judgment) -----
    $selfDeaths = @()
    foreach ($d in @($boss.DeathList)) {
        if ($d.Name -eq $CharacterName) { $selfDeaths += $d }
    }
    if ($selfDeaths.Count -gt 0) { $selfDeathBosses += $slug }

    # ----- Nearest cooldown to each death (any ability, either direction) -----
    $allCooldownCasts = @()
    foreach ($cdProp in $boss.CooldownRows.PSObject.Properties) {
        foreach ($t in @($cdProp.Value.Targets)) {
            if ($t.Timestamp) { $allCooldownCasts += [PSCustomObject]@{ Ability = $cdProp.Name; Timestamp = $t.Timestamp } }
        }
    }
    $deathsNearestCooldown = @()
    foreach ($d in @($boss.DeathList)) {
        if ($allCooldownCasts.Count -eq 0) { continue }
        $nearest = $allCooldownCasts | Sort-Object -Property { [math]::Abs($_.Timestamp - $d.Timestamp) } | Select-Object -First 1
        $deathsNearestCooldown += [PSCustomObject]@{
            DeathName = $d.Name; DeathTimestamp = $d.Timestamp
            NearestCooldown = $nearest.Ability; NearestCooldownTimestamp = $nearest.Timestamp
            DeltaMs = [math]::Abs($nearest.Timestamp - $d.Timestamp)
        }
    }

    $cannedCaveats = Get-CannedCaveats -ClassName $ClassName -CooldownRows $boss.CooldownRows -SpellRows $boss.SpellRows

    $bossResults[$slug] = [ordered]@{
        Deviations = $deviations
        SpellGaps = $spellGaps
        TopSpellGap = $topSpellGap
        SpellRanks = $spellRanks
        Cooldowns = $cooldowns
        TranquilityInclude = $tranquilityInclude
        RebirthCandidates = $rebirthCandidates
        SelfDeaths = $selfDeaths
        DeathsNearestCooldown = $deathsNearestCooldown
        CannedCaveats = $cannedCaveats
    }

    if ($null -ne $boss.DeathCount) { $deathCountRows += [PSCustomObject]@{ Slug = $slug; DeathCount = $boss.DeathCount } }
    if ($null -ne $boss.Percentile) { $lowestPercentile += [PSCustomObject]@{ Slug = $slug; Percentile = $boss.Percentile } }

    if (-not $bm) {
        Write-Host "  WARNING: $slug - no BM benchmark row, deviation flags will be sparse for this boss."
    }
}

# ----- Gear analysis (raid-wide, not per-boss - GearDiff is a top-level field) -----
$gearAnalysis = [ordered]@{ MissingEnchantFlags = @(); DifferingSlotsAnnotated = @() }
if ($reportData.GearDiff -and $reportData.GearDiff.BaselineGear) {
    $baseline = @($reportData.GearDiff.BaselineGear)
    for ($i = 0; $i -lt $baseline.Count; $i++) {
        $item = $baseline[$i]
        if (Test-SlotEnchantable -SlotIndex $i -GearItemAtSlot $item) {
            $hasEnchant = $item.PSObject.Properties.Name -contains "permanentEnchant" -and $null -ne $item.permanentEnchant
            if (-not $hasEnchant) {
                $gearAnalysis["MissingEnchantFlags"] += [PSCustomObject]@{
                    SlotIndex = $i; SlotName = Get-GearSlotName -SlotIndex $i; ItemId = $item.id
                }
            }
        }
    }
    foreach ($diff in @($reportData.GearDiff.DifferingSlots)) {
        $slotName = Get-GearSlotName -SlotIndex $diff.SlotIndex
        # Heuristic only - a real, specific finding still needs a human/LLM read.
        # Flags as "likely benign" when one variant is a clear minority (seen on
        # far fewer kills than the others) or is a dramatically lower item level
        # (the fishing-pole-swap pattern already confirmed real this session).
        $variants = @($diff.Variants)
        $totalSeen = ($variants | ForEach-Object { @($_.SeenOn).Count } | Measure-Object -Sum).Sum
        $minorityVariant = $variants | Sort-Object -Property { @($_.SeenOn).Count } | Select-Object -First 1
        $likelyBenign = $false
        $reason = "needs review"
        if ($variants.Count -gt 1 -and $totalSeen -gt 0) {
            $minorityShare = @($minorityVariant.SeenOn).Count / $totalSeen
            if ($minorityShare -le 0.2) { $likelyBenign = $true; $reason = "single/minority-kill variant" }
        }
        $gearAnalysis["DifferingSlotsAnnotated"] += [PSCustomObject]@{
            SlotIndex = $diff.SlotIndex; SlotName = $slotName; LikelyBenign = $likelyBenign; Reason = $reason
        }
    }
} else {
    Write-Host "  WARNING: no GearDiff.BaselineGear in report_data.json - gear analysis will be empty."
}

# ----- Raid-wide rollups -----
$deathCountRows = @($deathCountRows | Sort-Object -Property DeathCount -Descending)
$rank = 1
$deathCountByBoss = @()
foreach ($row in $deathCountRows) {
    $deathCountByBoss += [PSCustomObject]@{ Slug = $row.Slug; DeathCount = $row.DeathCount; Rank = $rank }
    $rank++
}
$lowestPercentileSorted = @($lowestPercentile | Sort-Object -Property Percentile | Select-Object -First 3)

$cooldownDeviations = [ordered]@{}
foreach ($key in $cooldownDeviationsByAbility.Keys) {
    $cooldownDeviations[$key] = $cooldownDeviationsByAbility[$key]
}

$analysis = [ordered]@{
    CharacterName = $CharacterName
    ReportCode    = $ReportCode
    ClassName     = $ClassName
    Bosses        = $bossResults
    RaidWideRollups = [ordered]@{
        DeathCountByBoss           = $deathCountByBoss
        OverhealExceedsWorstBosses = $overhealExceedsWorst
        CooldownDeviations         = $cooldownDeviations
        SelfDeathBosses            = $selfDeathBosses
        LowestPercentileBosses     = $lowestPercentileSorted
    }
    GearAnalysis  = $gearAnalysis
}

$outPath = Join-Path $charDir "$($ReportCode)_analysis.json"
$jsonText = $analysis | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($outPath, $jsonText, (New-Object System.Text.UTF8Encoding $false))

Write-Host ""
Write-Host "Wrote $outPath"
Write-Host "$($bossResults.Count) boss(es) analyzed."
