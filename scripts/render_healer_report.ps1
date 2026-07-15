# render_healer_report.ps1
#
# Deterministic renderer: report_data.json + {code}_analysis.json +
# {code}_findings.json + the class's boss template + raid_overview_template
# -> docs\{healer}\{outputFolder}\healer_audit_*.html (one per boss) + index.html
# (raid overview). {outputFolder} always mirrors whatever the input data folder
# under data\Characters\{healer}\ is named - a ReportCode for anything pulled
# after the ReportCode-keyed folder change (see pull_character_TEMPLATE.ps1),
# or a legacy yyyy-MM-dd date for anything pulled before it. Zero LLM involvement
# - every mechanical value (stat grids,
# spell-composition bars, cooldown tables, target-distribution bars, gear
# checklist) is derived straight from data; the ONLY free-text content comes
# from findings.json, which an LLM authors separately (see
# build_boss_analysis.ps1 and the generate-healer-report skill).
#
# Usage (run from repo root, same convention as every other script here):
#   powershell -ExecutionPolicy Bypass -File scripts\render_healer_report.ps1 -CharacterName "Crowns" -ReportCode "XJp8vAxzM4KtHYyb" -ClassName "Paladin" -RaidTitle "SSC / TK"
#
# -TotalBosses (default 10) is the raid overview's "N_BOSSES" denominator (the
# raid overview's own "<N_KILLS>/<N_BOSSES> bosses killed" line, NOT the hub
# page's separate -TotalBosses on update_hub_pages.ps1 - both currently default
# to 10 and must be kept in sync by hand, there is no shared source of truth).
# It is intentionally independent of $bossSlugs.Count (the boss count actually
# present in this report's own data) - a raid night that killed fewer than the
# full tier (e.g. 9 of 10) should show "9/10", not "9/9". Override this once a
# new boss is added to the tracked tier (see README.md's "Adding a new boss").
#
# findings.json schema notes (see the generate-healer-report skill for the
# full authoring guide):
#   BossFindings.{slug}.SCORECARD_FINDING / SPELL_COMPOSITION_FINDING /
#     COOLDOWN_FINDING / TARGET_FINDING - required, plain strings.
#   BossFindings.{slug}.IncludeRebirthRow - optional bool, Druid only. The
#     ONE cooldown-row inclusion decision analysis.json deliberately leaves
#     unresolved (no numeric threshold exists for "was this death actually
#     plausible for Rebirth to answer" - see RebirthCandidates in the
#     analysis file). Defaults to $false if absent.
#   RaidOverview.GEAR_CONSISTENCY_FINDING / GEAR_FINDING_NOTE /
#     RAID_SUMMARY_FINDING - required, plain strings.
#   RaidOverview.RAID_WARNING_BANNER - optional string. Real hand-built pages
#     show a prominent raid-wide rust banner above the per-boss table when
#     there's a genuine raid-wide finding (e.g. "Overheal exceeds the Top 100
#     sample's single worst parse on 7 of 10 kills") - omit this key entirely
#     if there's no finding that strong; the banner is dropped, not shown empty.
#     May contain inline <strong> tags for selective emphasis, matching the
#     established convention (only the opening clause is normally bolded).
#   RaidOverview.GearCheckItems[] - optional array of interpretive gear notes
#     BEYOND the mechanical ones this script auto-generates (slot-filled count,
#     missing-enchant flags). Each: { Icon: "ok"|"bad"|"note", Description,
#     Detail (short data tag only), LongDetail (optional .check-detail prose) }.

param(
    [Parameter(Mandatory=$true)][string]$CharacterName,
    [Parameter(Mandatory=$true)][string]$ReportCode,
    [Parameter(Mandatory=$true)][string]$ClassName,
    [string]$HealerSlug,
    [string]$RaidTitle = "SSC / TK",
    [int]$TotalBosses = 10,
    [string]$CharactersRoot = "data\Characters",
    [string]$TemplatesRoot = "templates",
    [string]$OutputRoot = "docs"
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "lib\ReportRenderLib.psm1") -Force

$classSpecByClass = @{
    "Druid"   = "Restoration Druid"
    "Shaman"  = "Restoration Shaman"
    "Priest"  = "Holy Priest"
    "Paladin" = "Holy Paladin"
}
if (-not $classSpecByClass.ContainsKey($ClassName)) {
    Write-Host "ERROR: '$ClassName' is not a supported class (Druid, Shaman, Priest, Paladin only)."
    exit 1
}
$classSpec = $classSpecByClass[$ClassName]
if (-not $HealerSlug) { $HealerSlug = $CharacterName.ToLower() }

# ----- Locate the three input JSON files -----
$charRoot = Join-Path $CharactersRoot $CharacterName
$reportDataFile = Get-ChildItem -Path $charRoot -Recurse -Filter "$($ReportCode)_report_data.json" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $reportDataFile) {
    Write-Host "ERROR: no $($ReportCode)_report_data.json found under $charRoot - run build_boss_report_data.ps1 first."
    exit 1
}
$charDir = $reportDataFile.DirectoryName
$analysisPath = Join-Path $charDir "$($ReportCode)_analysis.json"
$findingsPath = Join-Path $charDir "$($ReportCode)_findings.json"
if (-not (Test-Path $analysisPath)) {
    Write-Host "ERROR: $analysisPath not found - run build_boss_analysis.ps1 first."
    exit 1
}
if (-not (Test-Path $findingsPath)) {
    Write-Host "ERROR: $findingsPath not found - author it first (the one step that needs real judgment - see the generate-healer-report skill)."
    exit 1
}

$reportData = Get-Content $reportDataFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
$analysis = Get-Content $analysisPath -Raw -Encoding UTF8 | ConvertFrom-Json
$findings = Get-Content $findingsPath -Raw -Encoding UTF8 | ConvertFrom-Json

# ----- Output folder name always mirrors the input data folder's own name,
# whatever that happens to be - a ReportCode for anything pulled after the
# ReportCode-keyed folder change, or a legacy yyyy-MM-dd date for anything
# pulled before it. This is what lets an old, already-published date-named
# docs\ folder keep getting refreshed in place rather than a re-run suddenly
# forking off a second, report-code-named copy of the same report. -----
$folderName = Split-Path $charDir -Leaf
$raidDateFolder = $folderName

# ----- Resolve the DISPLAY date. Prefer report_data.json's own RaidDate field
# (present on everything built from a ReportCode-keyed pull); fall back to
# parsing the folder name as a date for older report_data.json files that
# predate that field, where the folder name IS the date. -----
$raidDateDisplay = $null
$rawRaidDate = if ($reportData.PSObject.Properties.Name -contains "RaidDate") { $reportData.RaidDate } else { $null }
if ($rawRaidDate) {
    try { $raidDateDisplay = ([datetime]::ParseExact($rawRaidDate, "yyyy-MM-dd", $null)).ToString("MMMM d, yyyy") }
    catch { $raidDateDisplay = $rawRaidDate }
} else {
    try { $raidDateDisplay = ([datetime]::ParseExact($folderName, "yyyy-MM-dd", $null)).ToString("MMMM d, yyyy") }
    catch { $raidDateDisplay = $folderName }
}

# Never write into a preserved v1 folder.
if ($raidDateFolder.ToLower().EndsWith("-v1")) {
    Write-Host "ERROR: refusing to render into '$raidDateFolder' - this looks like a preserved v1 folder. Never overwrite v1 output."
    exit 1
}

# ----- Validate findings.json completeness before writing anything -----
$bossSlugs = @($reportData.Bosses.PSObject.Properties.Name)
$requiredBossKeys = @("SCORECARD_FINDING", "SPELL_COMPOSITION_FINDING", "COOLDOWN_FINDING", "TARGET_FINDING")
$missing = @()
foreach ($slug in $bossSlugs) {
    if (-not ($findings.BossFindings.PSObject.Properties.Name -contains $slug)) {
        $missing += "BossFindings.$slug (entire boss missing)"
        continue
    }
    $bf = $findings.BossFindings.$slug
    foreach ($key in $requiredBossKeys) {
        $val = $bf.$key
        if ([string]::IsNullOrWhiteSpace($val)) { $missing += "BossFindings.$slug.$key" }
    }
}
foreach ($key in @("GEAR_CONSISTENCY_FINDING", "GEAR_FINDING_NOTE", "RAID_SUMMARY_FINDING")) {
    $val = $findings.RaidOverview.$key
    if ([string]::IsNullOrWhiteSpace($val)) { $missing += "RaidOverview.$key" }
}
if ($missing.Count -gt 0) {
    Write-Host "ERROR: findings.json is incomplete - refusing to render a page with a placeholder or empty finding."
    foreach ($m in $missing) { Write-Host "  missing: $m" }
    exit 1
}

# ----- Item level (average across real, non-empty BaselineGear items) -----
$itemLevel = "?"
if ($reportData.GearDiff -and $reportData.GearDiff.BaselineGear) {
    $realItems = @($reportData.GearDiff.BaselineGear | Where-Object { [int]$_.id -ne 0 })
    if ($realItems.Count -gt 0) {
        $itemLevel = [math]::Round((($realItems | Measure-Object -Property itemLevel -Sum).Sum) / $realItems.Count)
    }
}

$outDir = Join-Path $OutputRoot (Join-Path $HealerSlug $raidDateFolder)
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

function Format-CooldownBenchmark {
    param($AvgCasts, $UsedPct, $SelfPct)
    if ($null -eq $UsedPct -or [double]$UsedPct -eq 0) { return "0 avg (never used)" }
    $selfDisplay = if ($null -ne $SelfPct) { [math]::Round([double]$SelfPct) } else { 0 }
    return "$AvgCasts avg ($selfDisplay% self)"
}

function Format-Thousands {
    param([double]$Value)
    return "{0:N0}" -f $Value
}

# ===== Boss pages =====
$bossTemplatePath = Join-Path $TemplatesRoot "boss_page_template_$($ClassName.ToLower()).html"
if (-not (Test-Path $bossTemplatePath)) {
    Write-Host "ERROR: $bossTemplatePath not found."
    exit 1
}
$bossTemplateRaw = Get-Content $bossTemplatePath -Raw -Encoding UTF8

$fullRaidTitleForBossPages = "$RaidTitle " + [char]0x2014 + " $raidDateDisplay"

$bossSummaryRows = @()

foreach ($slug in $bossSlugs) {
    $boss = $reportData.Bosses.$slug
    $bossAnalysis = $analysis.Bosses.$slug
    $bf = $findings.BossFindings.$slug

    $page = $bossTemplateRaw

    # ----- Once-per-page tokens -----
    $page = Set-TemplateToken $page "RAID_TITLE" $fullRaidTitleForBossPages
    $page = Set-TemplateToken $page "BOSS_NAME" $boss.Display
    $page = Set-TemplateToken $page "HEALER_NAME" $CharacterName
    $page = Set-TemplateToken $page "HEALER_CLASS_SPEC" $classSpec
    $page = Set-TemplateToken $page "ITEM_LEVEL" $itemLevel
    $page = Set-TemplateToken $page "REPORT_CODE" $ReportCode
    $page = Set-TemplateToken $page "FIGHT_ID" $boss.FightID
    $durationS = [math]::Round($boss.Duration / 1000)
    $page = Set-TemplateToken $page "DURATION_S" $durationS
    $percentile = if ($null -ne $boss.Percentile) { $boss.Percentile } else { 0 }
    $page = Set-TemplateToken $page "PERCENTILE" $percentile
    $rank = if ($boss.Rank) { $boss.Rank } else { "?" }
    $page = Set-TemplateToken $page "RANK" $rank
    $outOf = if ($boss.OutOf) { $boss.OutOf } else { "?" }
    $page = Set-TemplateToken $page "OUT_OF" $outOf

    # ----- Scorecard -----
    $page = Set-TemplateToken $page "HPS" $boss.HPS
    $bm = $boss.BM
    $page = Set-TemplateToken $page "HPS_TOP1" $(if ($bm) { $bm.HPS_Top1 } else { "?" })
    $page = Set-TemplateToken $page "HPS_TOP100AVG" $(if ($bm) { $bm.HPS_Top100Avg } else { "?" })
    $page = Set-TemplateToken $page "HPS_MEDIAN" $(if ($bm) { $bm.HPS_Median } else { "?" })
    $page = Set-TemplateToken $page "OVERHEAL_PCT" $boss.OverhealPct
    $page = Set-TemplateToken $page "OVERHEAL_BEST" $(if ($bm) { $bm.Overheal_Best } else { "?" })
    $page = Set-TemplateToken $page "OVERHEAL_MEDIAN" $(if ($bm) { $bm.Overheal_Median } else { "?" })
    $page = Set-TemplateToken $page "OVERHEAL_WORST" $(if ($bm) { $bm.Overheal_Worst } else { "?" })
    $page = Set-TemplateToken $page "TOTAL_HEALING" (Format-Thousands $boss.Total)
    $page = Set-TemplateToken $page "ACTIVE_TIME_PCT" $(if ($null -ne $boss.ActiveTimePct) { $boss.ActiveTimePct } else { "?" })
    $page = Set-TemplateToken $page "ACTIVE_TIME_TOP1" $(if ($bm) { $bm.ActiveTime_Top1 } else { "?" })
    $page = Set-TemplateToken $page "ACTIVE_TIME_TOP100AVG" $(if ($bm) { $bm.ActiveTime_Top100Avg } else { "?" })
    $page = Set-TemplateToken $page "ACTIVE_TIME_MEDIAN" $(if ($bm) { $bm.ActiveTime_Median } else { "?" })
    $page = Set-TemplateToken $page "DEATH_COUNT" $(if ($null -ne $boss.DeathCount) { $boss.DeathCount } else { 0 })
    $page = Set-TemplateSlot $page "SCORECARD_FINDING" $bf.SCORECARD_FINDING

    # ----- Spell composition (from analysis.json's already-computed SpellGaps
    # union - single source of truth for the guid-matching logic, not
    # recomputed here). Sorted by character% desc, ties by benchmark% desc,
    # matching the established hand-authored convention. Same-name-different-
    # guid rows get a "(guid N)" suffix, matching the real disambiguation
    # convention already used across every hand-built page this session. -----
    $spellGaps = @($bossAnalysis.SpellGaps | Sort-Object -Property CharacterPct, BenchmarkPct -Descending)
    $nameCounts = @{}
    foreach ($g in $spellGaps) {
        if (-not $nameCounts.ContainsKey($g.Name)) { $nameCounts[$g.Name] = 0 }
        $nameCounts[$g.Name] += 1
    }
    $page = Expand-TemplateLoop -TemplateText $page -LoopName "SPELL_ROW" -Rows $spellGaps -RowTokenBuilder {
        param($row)
        $displayName = if ($nameCounts[$row.Name] -gt 1) { "$($row.Name) (guid $($row.Guid))" } else { $row.Name }
        @{
            SPELL_NAME = $displayName
            SPELL_PCT_CHARACTER = $row.CharacterPct
            SPELL_PCT_BENCHMARK = $row.BenchmarkPct
        }
    }
    $page = Set-TemplateSlot $page "SPELL_COMPOSITION_FINDING" $bf.SPELL_COMPOSITION_FINDING

    # ----- Spell ranks (mechanical, no LLM - analysis.json's SpellRanks already
    # only contains spell names with 2+ distinct real guids in play; a boss with
    # none gets the whole section removed rather than shown empty, matching the
    # skill's "only show when it's actually relevant" rule). Flattens each
    # group's rows with the name shown once (blank on repeats), same convention
    # already used for the spell-composition compare-rows above. -----
    $rankRows = @()
    foreach ($group in @($bossAnalysis.SpellRanks)) {
        $isFirst = $true
        foreach ($r in @($group.Ranks)) {
            $rankRows += [PSCustomObject]@{
                Name = $(if ($isFirst) { $group.Name } else { "" })
                ManaCost = $(if ($null -ne $r.ManaCost) { "$($r.ManaCost) mana" } else { "?" })
                CharacterPct = $r.CharacterPct
                BenchmarkPct = $r.BenchmarkPct
            }
            $isFirst = $false
        }
    }
    $rankBounds = Get-OptionalSectionBounds -TemplateText $page -OptionalName "SPELL_RANKS_SECTION"
    if ($rankRows.Count -eq 0) {
        $page = $rankBounds.Before + $rankBounds.After
    } else {
        $rankInner = Expand-TemplateLoop -TemplateText $rankBounds.Inner -LoopName "RANK_ROW" -Rows $rankRows -RowTokenBuilder {
            param($row)
            @{
                RANK_SPELL_NAME = $row.Name; RANK_MANA_COST = $row.ManaCost
                RANK_CHARACTER_PCT = $row.CharacterPct; RANK_BENCHMARK_PCT = $row.BenchmarkPct
            }
        }
        $page = $rankBounds.Before + $rankInner + $rankBounds.After
    }

    # ----- Cooldowns & consumables -----
    $cdRows = @()
    foreach ($cdProp in $bossAnalysis.Cooldowns.PSObject.Properties) {
        $abilityName = $cdProp.Name
        if ($abilityName -eq "Tranquility" -and $bossAnalysis.TranquilityInclude -ne $true) { continue }
        if ($abilityName -eq "Rebirth") {
            $includeRebirth = ($bf.PSObject.Properties.Name -contains "IncludeRebirthRow") -and ($bf.IncludeRebirthRow -eq $true)
            if (-not $includeRebirth) { continue }
        }
        $cdRows += [PSCustomObject]@{ Name = $abilityName; Row = $cdProp.Value }
    }
    $page = Expand-TemplateLoop -TemplateText $page -LoopName "CD_ROW" -Rows $cdRows -RowTokenBuilder {
        param($entry)
        @{
            COOLDOWN_NAME = $entry.Name
            COOLDOWN_CASTS = $entry.Row.Count
            COOLDOWN_TARGET = $entry.Row.TargetLabel
            COOLDOWN_BENCHMARK = (Format-CooldownBenchmark $entry.Row.Top100AvgCasts $entry.Row.Top100UsedPct $entry.Row.Top100SelfPct)
        }
    }

    $bmBuffs = $boss.BMBuffs
    $page = Set-TemplateToken $page "FLASK_ACTIVE" $(if ($boss.FlaskActive) { "Yes" } else { "No" })
    $page = Set-TemplateToken $page "FLASK_NAME" $(if ($boss.FlaskName) { $boss.FlaskName } else { "none" })
    $page = Set-TemplateToken $page "FLASK_BENCHMARK_PCT" $(if ($bmBuffs) { $bmBuffs.Top100FlaskActivePct } else { "?" })
    $page = Set-TemplateToken $page "FOOD_ACTIVE" $(if ($boss.FoodActive) { "Yes" } else { "No" })
    $page = Set-TemplateToken $page "FOOD_NAME" $(if ($boss.FoodName) { $boss.FoodName } else { "none" })
    $page = Set-TemplateToken $page "FOOD_BENCHMARK_PCT" $(if ($bmBuffs) { $bmBuffs.Top100FoodActivePct } else { "?" })

    if ($ClassName -eq "Druid") {
        $treeOfLifePct = if ($null -ne $boss.TreeOfLifePct) { $boss.TreeOfLifePct } else { 0 }
        $page = Set-TemplateToken $page "TREE_OF_LIFE_PCT" $treeOfLifePct
        $treeBm = if ($bmBuffs -and ($bmBuffs.PSObject.Properties.Name -contains "Top100TreeOfLifeAvgUptimePct")) { $bmBuffs.Top100TreeOfLifeAvgUptimePct } else { "?" }
        $page = Set-TemplateToken $page "TREE_OF_LIFE_BENCHMARK_PCT" $treeBm
    }

    $manaPotionCount = 0
    if ($bossAnalysis.Cooldowns.PSObject.Properties.Name -contains "Mana Potion") {
        $manaPotionCount = $bossAnalysis.Cooldowns."Mana Potion".Count
    }
    $manaDetail = if ($manaPotionCount -eq 0) { "none used this kill" } elseif ($manaPotionCount -eq 1) { "1x Mana Potion" } else { "$($manaPotionCount)x Mana Potion" }
    $page = Set-TemplateToken $page "MANA_CONSUMABLE_COUNT" $manaPotionCount
    $page = Set-TemplateToken $page "MANA_CONSUMABLE_DETAIL" $manaDetail

    $hpmDev = $bossAnalysis.Deviations.HPM
    if ($hpmDev -and $hpmDev.Omit -eq $true) {
        $page = Set-TemplateToken $page "HPM" "N/A"
        $page = Set-TemplateToken $page "HPM_TOP1" "N/A"
        $page = Set-TemplateToken $page "HPM_TOP100AVG" "N/A"
        $page = Set-TemplateToken $page "HPM_MEDIAN" "N/A"
    } else {
        $page = Set-TemplateToken $page "HPM" $(if ($null -ne $boss.HPM) { $boss.HPM } else { "N/A" })
        $page = Set-TemplateToken $page "HPM_TOP1" $(if ($bm) { $bm.HPM_Top1 } else { "?" })
        $page = Set-TemplateToken $page "HPM_TOP100AVG" $(if ($bm) { $bm.HPM_Top100Avg } else { "?" })
        $page = Set-TemplateToken $page "HPM_MEDIAN" $(if ($bm) { $bm.HPM_Median } else { "?" })
    }
    $page = Set-TemplateSlot $page "COOLDOWN_FINDING" $bf.COOLDOWN_FINDING

    # ----- Target distribution (report_data.json's TargetRows already has
    # BarWidth precomputed - straight pass-through, no recomputation) -----
    $page = Set-TemplateToken $page "COVERAGE_PCT" $boss.CoveragePct
    $page = Set-TemplateToken $page "BENCHMARK_COVERAGE_PCT" $(if ($bm) { $bm.Top100_TargetCoveragePct } else { "?" })
    $page = Set-TemplateToken $page "BENCHMARK_TOP1_PCT" $(if ($bm) { $bm.Top100_TargetTop1Pct } else { "?" })
    $page = Expand-TemplateLoop -TemplateText $page -LoopName "TARGET_ROW" -Rows @($boss.TargetRows) -RowTokenBuilder {
        param($row)
        @{ TARGET_NAME = $row.Name; TARGET_BAR_WIDTH = $row.BarWidth; TARGET_PCT = $row.Pct }
    }
    $page = Set-TemplateSlot $page "TARGET_FINDING" $bf.TARGET_FINDING

    # ----- Footer -----
    $sampleN = if ($bm -and $bm.SampleSize) { $bm.SampleSize } else { "100" }
    $page = Set-TemplateToken $page "BENCHMARK_N" $sampleN

    $page = Remove-HtmlComments -TemplateText $page
    if ($page.Contains("{{")) {
        Write-Host "ERROR: $slug page still has an unfilled {{TOKEN}} after rendering - refusing to write a broken page."
        $page -split "`n" | Select-String -Pattern '\{\{' | ForEach-Object { Write-Host "  $_" }
        exit 1
    }

    $outPath = Join-Path $outDir "healer_audit_$slug.html"
    [System.IO.File]::WriteAllText($outPath, $page, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Wrote $outPath"

    $overhealHighClass = if ($bossAnalysis.Deviations.Overheal -and $bossAnalysis.Deviations.Overheal.Flag -eq "exceeds_worst") { " overheal-cell high" } else { "" }
    $bossSummaryRows += [PSCustomObject]@{
        Slug = $slug; Display = $boss.Display; HPS = $boss.HPS; OverhealPct = $boss.OverhealPct
        OverhealHighClass = $overhealHighClass; Percentile = $percentile
    }
}

# ===== Raid overview =====
$overviewTemplatePath = Join-Path $TemplatesRoot "raid_overview_template.html"
$overview = Get-Content $overviewTemplatePath -Raw -Encoding UTF8

$overview = Set-TemplateToken $overview "RAID_TITLE" $RaidTitle
$overview = Set-TemplateToken $overview "RAID_DATE_DISPLAY" $raidDateDisplay
$overview = Set-TemplateToken $overview "HEALER_NAME" $CharacterName
$overview = Set-TemplateToken $overview "HEALER_CLASS_SPEC" $classSpec
$overview = Set-TemplateToken $overview "ITEM_LEVEL" $itemLevel
$overview = Set-TemplateToken $overview "REPORT_CODE" $ReportCode
$overview = Set-TemplateToken $overview "N_KILLS" $bossSlugs.Count
$overview = Set-TemplateToken $overview "N_BOSSES" $TotalBosses

$overview = Set-TemplateSlot $overview "GEAR_CONSISTENCY_FINDING" $findings.RaidOverview.GEAR_CONSISTENCY_FINDING

# ----- Gear checklist: mechanical items first (slot-fill count, then one
# "bad" row per auto-detected missing enchant), then Claude's interpretive
# additions from findings.json, in the order given. -----
$gearItems = @()
$totalSlots = 19
$filledCount = $totalSlots
if ($reportData.GearDiff -and $reportData.GearDiff.BaselineGear) {
    $filledCount = @($reportData.GearDiff.BaselineGear | Where-Object { [int]$_.id -ne 0 }).Count
}
$gearItems += [PSCustomObject]@{
    Icon = "ok"; Glyph = [char]0x2713
    Description = "$filledCount of $totalSlots real equipment slots filled in the baseline loadout (shirt and tabard are typically the two genuinely empty cosmetic slots, no stat impact)"
    Detail = "avg ilvl $itemLevel"; LongDetail = ""
}
foreach ($flag in @($analysis.GearAnalysis.MissingEnchantFlags)) {
    $gearItems += [PSCustomObject]@{
        Icon = "bad"; Glyph = [char]0x2717
        Description = "$($flag.SlotName) carries no permanent enchant"
        Detail = "item $($flag.ItemId)"; LongDetail = ""
    }
}
$gearCheckItemsRaw = $findings.RaidOverview.GearCheckItems
foreach ($extra in @($gearCheckItemsRaw | Where-Object { $_ })) {
    $glyph = switch ($extra.Icon) { "ok" { [char]0x2713 }; "bad" { [char]0x2717 }; "note" { "i" }; default { throw "Invalid GearCheckItems Icon '$($extra.Icon)' - must be ok|bad|note." } }
    $gearItems += [PSCustomObject]@{
        Icon = $extra.Icon; Glyph = $glyph; Description = $extra.Description
        Detail = $(if ($extra.Detail) { $extra.Detail } else { "" })
        LongDetail = $(if ($extra.LongDetail) { $extra.LongDetail } else { "" })
    }
}
$overview = Expand-TemplateLoop -TemplateText $overview -LoopName "GEAR_CHECK_ITEM" -Rows $gearItems -RowTokenBuilder {
    param($item)
    @{
        CHECK_ICON_CLASS = $item.Icon; CHECK_ICON_GLYPH = $item.Glyph
        CHECK_DESCRIPTION = $item.Description; CHECK_DETAIL = $item.Detail; CHECK_LONG_DETAIL = $item.LongDetail
    }
}
$overview = Set-TemplateSlot $overview "GEAR_FINDING_NOTE" $findings.RaidOverview.GEAR_FINDING_NOTE

$warningBanner = if ($findings.RaidOverview.PSObject.Properties.Name -contains "RAID_WARNING_BANNER") { $findings.RaidOverview.RAID_WARNING_BANNER } else { "" }
$overview = Set-TemplateOptional -TemplateText $overview -OptionalName "RAID_WARNING_BANNER" -SlotName "RAID_WARNING_BANNER" -Value $warningBanner

$overview = Expand-TemplateLoop -TemplateText $overview -LoopName "BOSS_SUMMARY_ROW" -Rows $bossSummaryRows -RowTokenBuilder {
    param($row)
    @{
        BOSS_SLUG = $row.Slug; BOSS_NAME = $row.Display; HPS = $row.HPS
        OVERHEAL_HIGH_CLASS = $row.OverhealHighClass; OVERHEAL_PCT = $row.OverhealPct; PERCENTILE = $row.Percentile
    }
}
$overview = Set-TemplateSlot $overview "RAID_SUMMARY_FINDING" $findings.RaidOverview.RAID_SUMMARY_FINDING

$overview = Remove-HtmlComments -TemplateText $overview
if ($overview.Contains("{{")) {
    Write-Host "ERROR: raid overview still has an unfilled {{TOKEN}} after rendering - refusing to write a broken page."
    $overview -split "`n" | Select-String -Pattern '\{\{' | ForEach-Object { Write-Host "  $_" }
    exit 1
}

$overviewOutPath = Join-Path $outDir "index.html"
[System.IO.File]::WriteAllText($overviewOutPath, $overview, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Wrote $overviewOutPath"

Write-Host ""
Write-Host "Done. Rendered $($bossSlugs.Count) boss page(s) + raid overview to $outDir"
