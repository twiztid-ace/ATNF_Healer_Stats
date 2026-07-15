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
# The raid overview's "bosses killed" line is derived from real fight data,
# not a hardcoded tier-size constant - report_data.json's BossesAttempted
# field (written by build_boss_report_data.ps1 from the report's own real
# boss pulls, kill:true or not) is compared against the real kill count
# ($bossSlugs.Count). If they match (no wipes recorded), the line reads
# "<N> bosses killed" with no denominator. Only when a real wipe shows up in
# this report's own data does it read "<kills>/<attempted> bosses killed".
# This replaced an earlier hardcoded "-TotalBosses" (default 10) parameter
# that assumed every raid targeted the same fixed-size tier - that broke the
# day Gruul's Lair bosses were added alongside SSC/TK in the same report
# (a report_data.json with 12 real kills against a hardcoded "10" denominator
# rendered as a nonsensical "12/10 bosses killed").
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

# $ShowSelfPct is false for any cooldown whose real target mode is "self" or
# "party" (Get-CooldownTargetMode) - an ability that can never actually reach
# a different target has no real "self%" to report; every real cast of it IS
# self/party by definition, so a "(100% self)" parenthetical is trivially true
# rather than a real behavioral signal, and gets dropped entirely rather than
# shown as if it were meaningful. Only "other"-mode cooldowns (Innervate,
# Swiftmend, Power Word: Shield, Holy Shock, etc. - genuinely can land on a
# different real target) keep the self% comparison.
function Format-CooldownBenchmark {
    param($AvgCasts, $UsedPct, $SelfPct, [bool]$ShowSelfPct = $true)
    if ($null -eq $UsedPct -or [double]$UsedPct -eq 0) { return "0 avg (never used)" }
    if (-not $ShowSelfPct) { return "$AvgCasts avg" }
    $selfDisplay = if ($null -ne $SelfPct) { [math]::Round([double]$SelfPct) } else { 0 }
    return "$AvgCasts avg ($selfDisplay% self)"
}

function Format-Thousands {
    param([double]$Value)
    return "{0:N0}" -f $Value
}

# Interpolates the site's own percentile-bar gradient (rust #B5503A at 0% ->
# gold #D9B25C at 60% -> moss #5F7A52 at 100%, see .pctl-track's CSS) into a
# single real hex color for a given 0-100 value - used to color-code the
# header seals server-side, since this is a plain static site with no JS and
# no way to make an SVG circle's stroke follow a live CSS gradient at a
# dynamic percentage otherwise.
function Get-PercentileColor {
    param([double]$Pct)
    $Pct = [Math]::Max(0, [Math]::Min(100, $Pct))
    $rust = @(0xB5, 0x50, 0x3A); $gold = @(0xD9, 0xB2, 0x5C); $moss = @(0x5F, 0x7A, 0x52)
    if ($Pct -le 60) { $t = $Pct / 60.0; $from = $rust; $to = $gold }
    else { $t = ($Pct - 60) / 40.0; $from = $gold; $to = $moss }
    $r = [Math]::Round($from[0] + ($to[0] - $from[0]) * $t)
    $g = [Math]::Round($from[1] + ($to[1] - $from[1]) * $t)
    $b = [Math]::Round($from[2] + ($to[2] - $from[2]) * $t)
    return "#{0:X2}{1:X2}{2:X2}" -f [int]$r, [int]$g, [int]$b
}

# Converts an ordinal rank ("1st of 5") to the same 0-100 scale Get-PercentileColor
# expects - 1st place = 100 (best/green), last place = 0 (worst/red), evenly
# spaced in between. A single-healer comparison (Count 1, though this can't
# actually reach the seal since both rank seals require Count > 1) is treated
# as 100 rather than dividing by zero.
function Get-RankAsPct {
    param([int]$Rank, [int]$Count)
    if ($Count -le 1) { return 100 }
    return (($Count - $Rank) / ($Count - 1.0)) * 100
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

function Get-OrdinalLabel {
    param([int]$N)
    switch ($N) { 1 { "1st" } 2 { "2nd" } 3 { "3rd" } default { "${N}th" } }
}

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
    $page = Set-TemplateToken $page "PERCENTILE_COLOR" (Get-PercentileColor $percentile)
    $rank = if ($boss.Rank) { $boss.Rank } else { "?" }
    $page = Set-TemplateToken $page "RANK" $rank
    $outOf = if ($boss.OutOf) { $boss.OutOf } else { "?" }
    $page = Set-TemplateToken $page "OUT_OF" $outOf

    # ----- iLvl Healing Rank seal (see ILVL_HEALING_RANK_SEAL comment in the
    # template) - only shown when a real comparison against at least one
    # other tracked-spec healer was possible this specific kill. Native
    # title="" tooltip (no JS on this site) explains the metric on hover,
    # same convention as the raid overview's .th-help columns. -----
    $ilvlHealingRankTooltip = "Rank among the other healers in this same raid on this same fight, using WCL's own real HPS Performance Comparison (By Item Level) percentile per healer - not the Top 100 sample."
    $rawHealingRankTooltip = "Rank among the same healers in this same raid on this same fight, using real raw total healing done instead of an item-level-adjusted percentile - a genuinely independent ranking from iLvl Healing Rank, not the same number relabeled."
    $ilvlHealingRankSealHtml = ""
    if ($boss.ItemLevelHealingRank -and $boss.ItemLevelHealingRankCount -gt 1) {
        $ordinal = Get-OrdinalLabel $boss.ItemLevelHealingRank
        $ilvlBracket = if ($boss.ItemLevelBracket) { $boss.ItemLevelBracket } else { "?" }
        $ilvlRankColor = Get-PercentileColor (Get-RankAsPct $boss.ItemLevelHealingRank $boss.ItemLevelHealingRankCount)
        $ilvlHealingRankSealHtml = @"
<div class="seal-wrap" style="cursor:help;" title="$ilvlHealingRankTooltip">
        <svg class="seal" viewBox="0 0 120 120">
          <circle cx="60" cy="60" r="56" fill="none" stroke="$ilvlRankColor" stroke-width="2"/>
          <circle cx="60" cy="60" r="48" fill="none" stroke="$ilvlRankColor" stroke-width="1" stroke-dasharray="2 4"/>
          <text x="60" y="60" text-anchor="middle" font-family="Cormorant Garamond, serif" font-weight="700" font-size="22" fill="$ilvlRankColor">$ordinal of $($boss.ItemLevelHealingRankCount)</text>
          <text x="60" y="78" text-anchor="middle" font-family="IBM Plex Mono, monospace" font-size="8" letter-spacing="0.05em" fill="#132A2C" opacity="0.6">ILVL HEALING RANK</text>
        </svg>
        <div class="seal-label">$percentile% by ilvl $ilvlBracket</div>
      </div>
"@
    }
    $page = Set-TemplateOptional -TemplateText $page -OptionalName "ILVL_HEALING_RANK_SEAL" -SlotName "ILVL_HEALING_RANK_SEAL" -Value $ilvlHealingRankSealHtml

    # ----- Raw Healing Rank seal (see RAW_HEALING_RANK_SEAL comment in the
    # template) - independent ranking by real raw total healing done, same
    # healer population where the two endpoints agree. -----
    $rawHealingRankSealHtml = ""
    if ($boss.RawHealingRank -and $boss.RawHealingRankCount -gt 1) {
        $ordinal = Get-OrdinalLabel $boss.RawHealingRank
        $rawRankColor = Get-PercentileColor (Get-RankAsPct $boss.RawHealingRank $boss.RawHealingRankCount)
        $rawHealingRankSealHtml = @"
<div class="seal-wrap" style="cursor:help;" title="$rawHealingRankTooltip">
        <svg class="seal" viewBox="0 0 120 120">
          <circle cx="60" cy="60" r="56" fill="none" stroke="$rawRankColor" stroke-width="2"/>
          <circle cx="60" cy="60" r="48" fill="none" stroke="$rawRankColor" stroke-width="1" stroke-dasharray="2 4"/>
          <text x="60" y="60" text-anchor="middle" font-family="Cormorant Garamond, serif" font-weight="700" font-size="22" fill="$rawRankColor">$ordinal of $($boss.RawHealingRankCount)</text>
          <text x="60" y="78" text-anchor="middle" font-family="IBM Plex Mono, monospace" font-size="8" letter-spacing="0.05em" fill="#132A2C" opacity="0.6">RAW HEALING RANK</text>
        </svg>
        <div class="seal-label">$(Format-Thousands $boss.Total) healing</div>
      </div>
"@
    }
    $page = Set-TemplateOptional -TemplateText $page -OptionalName "RAW_HEALING_RANK_SEAL" -SlotName "RAW_HEALING_RANK_SEAL" -Value $rawHealingRankSealHtml

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
        # Get-KnownSpellRankLabel (ReportRenderLib.psm1) gives Lifebloom's two
        # confirmed guids a real "HoT"/"Bloom" label instead of a bare guid
        # suffix - same shared lookup the Spell Ranks section below uses, so
        # the two sections never disagree on what to call the same guid.
        # Every other multi-guid spell keeps the generic "(guid N)" fallback.
        $knownLabel = Get-KnownSpellRankLabel -Guid ([int]$row.Guid)
        $displayName = if ($knownLabel) { "$($row.Name) ($knownLabel)" }
            elseif ($nameCounts[$row.Name] -gt 1) { "$($row.Name) (guid $($row.Guid))" }
            else { $row.Name }
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
            # RankLabel (e.g. "HoT"/"Bloom" for Lifebloom's two confirmed guids -
            # see build_boss_analysis.ps1's $knownRankLabels) gives every row its
            # own real, distinct name instead of the generic "show once, blank on
            # repeat" convention below - only applied where which-is-which has
            # actually been confirmed, not guessed for every multi-guid spell.
            $displayName = if ($r.PSObject.Properties.Name -contains "RankLabel" -and $r.RankLabel) {
                "$($group.Name) ($($r.RankLabel))"
            } elseif ($isFirst) { $group.Name } else { "" }
            # A "benchmark" ManaCostSource means the character never cast this
            # specific rank this kill, so there's no real cast-time
            # classResources data for it - the number shown instead is a real
            # observed cost from elsewhere in the Top 100 sample (see
            # build_boss_analysis.ps1's $bmManaCostByGuid), marked with a
            # dagger so it's never confused with this kill's own cast data.
            $manaCostText = if ($null -eq $r.ManaCost) { "?" }
                elseif ($r.PSObject.Properties.Name -contains "ManaCostSource" -and $r.ManaCostSource -eq "benchmark") { "$($r.ManaCost) mana " + [char]0x2020 }
                else { "$($r.ManaCost) mana" }
            $rankRows += [PSCustomObject]@{
                Name = $displayName
                ManaCost = $manaCostText
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
    # Rebirth (Druid-only) is real "other" mode - it genuinely can land on
    # different real targets (who gets battle-rezzed) so the Target column
    # still shows real per-cast names - but self% is a separate question:
    # you cannot Rebirth yourself (you'd have to already be dead to be a
    # valid target), so it's not just "rare", it's mechanically impossible.
    # Any self% the Top 100 sample shows for it is measurement noise, not a
    # real signal, and gets dropped the same way self/party-mode abilities
    # already drop theirs above - for a different underlying reason (target
    # variety exists, self specifically doesn't), so this can't just reuse
    # the "other" mode check alone.
    $neverSelfAbilities = @("Rebirth")
    $page = Expand-TemplateLoop -TemplateText $page -LoopName "CD_ROW" -Rows $cdRows -RowTokenBuilder {
        param($entry)
        $canHaveDifferentTarget = (Get-CooldownTargetMode -ClassName $ClassName -AbilityName $entry.Name) -eq "other"
        $showSelfPct = $canHaveDifferentTarget -and ($neverSelfAbilities -notcontains $entry.Name)
        @{
            COOLDOWN_NAME = $entry.Name
            COOLDOWN_CASTS = $entry.Row.Count
            COOLDOWN_TARGET = if ($canHaveDifferentTarget) { $entry.Row.TargetLabel } else { [string][char]0x2014 }
            COOLDOWN_BENCHMARK = (Format-CooldownBenchmark $entry.Row.Top100AvgCasts $entry.Row.Top100UsedPct $entry.Row.Top100SelfPct -ShowSelfPct:$showSelfPct)
        }
    }

    $bmBuffs = $boss.BMBuffs
    # Real Flask / Battle Elixir / Guardian Elixir are mutually exclusive per
    # the actual TBC rule (a flask occupies both elixir slots at once) - never
    # more than one of these three is ever real/true at the same time, so
    # showing whichever one is actually true (if any) is a complete, honest
    # summary, not a lossy simplification. Older report_data.json files
    # generated before 2026-07-15 have no BattleElixir/GuardianElixir fields
    # at all (both read as $null, not $false) - treated the same as "none
    # detected" rather than erroring.
    $flaskLabel = if ($boss.FlaskActive) { "Yes" }
        elseif ($boss.BattleElixirActive -or $boss.GuardianElixirActive) { "Elixirs" }
        else { "No" }
    $flaskNameParts = @()
    if ($boss.FlaskActive -and $boss.FlaskName) { $flaskNameParts += $boss.FlaskName }
    if ($boss.BattleElixirActive -and $boss.BattleElixirName) { $flaskNameParts += "$($boss.BattleElixirName) (Battle)" }
    if ($boss.GuardianElixirActive -and $boss.GuardianElixirName) { $flaskNameParts += "$($boss.GuardianElixirName) (Guardian)" }
    $flaskNameText = if ($flaskNameParts.Count -gt 0) { $flaskNameParts -join " + " } else { "none" }
    $page = Set-TemplateToken $page "FLASK_ACTIVE" $flaskLabel
    $page = Set-TemplateToken $page "FLASK_NAME" $flaskNameText
    $flaskBenchmarkText = "?"
    if ($bmBuffs) {
        $benchmarkParts = @("$($bmBuffs.Top100FlaskActivePct)% flask")
        if ($bmBuffs.Top100BattleElixirActivePct -ne "") { $benchmarkParts += "$($bmBuffs.Top100BattleElixirActivePct)% Battle Elixir" }
        if ($bmBuffs.Top100GuardianElixirActivePct -ne "") { $benchmarkParts += "$($bmBuffs.Top100GuardianElixirActivePct)% Guardian Elixir" }
        $flaskBenchmarkText = $benchmarkParts -join ", "
    }
    $page = Set-TemplateToken $page "FLASK_BENCHMARK_PCT" $flaskBenchmarkText
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

    # ----- Healer ranking (mechanical, no LLM) - see HEALER_RANKING_SECTION
    # comment in the template. Omitted entirely (whole section, not just the
    # loop) when HealerRanking has 0 rows - can't happen in practice (the
    # audited character always has at least their own row) but matches the
    # SPELL_RANKS_SECTION precedent of never rendering an empty section shell. -----
    $healerRankingBounds = Get-OptionalSectionBounds -TemplateText $page -OptionalName "HEALER_RANKING_SECTION"
    $healerRankingRows = @($boss.HealerRanking)
    if ($healerRankingRows.Count -eq 0) {
        $page = $healerRankingBounds.Before + $healerRankingBounds.After
    } else {
        $healerRankingInner = Expand-TemplateLoop -TemplateText $healerRankingBounds.Inner -LoopName "HEALER_RANK_ROW" -Rows $healerRankingRows -RowTokenBuilder {
            param($row)
            @{
                HEALER_ROW_NAME = $row.Name
                HEALER_ROW_CHAR_CLASS = $(if ($row.IsCharacter) { "is-character" } else { "" })
                HEALER_ROW_BAR_WIDTH = $(if ($null -ne $row.BarWidth) { $row.BarWidth } else { 0 })
                HEALER_ROW_TOTAL_PCT = $(if ($null -ne $row.TotalPct) { "$($row.TotalPct)%" } else { [string][char]0x2014 })
                HEALER_ROW_TOTAL_TOOLTIP = $(if ($null -ne $row.RawHealingTotal) { "$(Format-Thousands $row.RawHealingTotal) total healing" } else { "No raw healing data available for $($row.Name) on this kill" })
                HEALER_ROW_ILVL_PCT = $(
                    $pctText = if ($null -ne $row.RankPercent) { "$($row.RankPercent)%" } else { [string][char]0x2014 }
                    if ($null -ne $row.ItemLevel) { "$pctText (ilvl $($row.ItemLevel))" } else { $pctText }
                )
            }
        }
        $page = $healerRankingBounds.Before + $healerRankingInner + $healerRankingBounds.After
    }

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
    $ilvlHealingRankLabel = if ($boss.ItemLevelHealingRank -and $boss.ItemLevelHealingRankCount -gt 1) {
        "$(Get-OrdinalLabel $boss.ItemLevelHealingRank)/$($boss.ItemLevelHealingRankCount)"
    } else { [char]0x2014 }
    $rawHealingRankLabel = if ($boss.RawHealingRank -and $boss.RawHealingRankCount -gt 1) {
        "$(Get-OrdinalLabel $boss.RawHealingRank)/$($boss.RawHealingRankCount)"
    } else { [char]0x2014 }
    $bossSummaryRows += [PSCustomObject]@{
        Slug = $slug; Display = $boss.Display; HPS = $boss.HPS; OverhealPct = $boss.OverhealPct
        OverhealHighClass = $overhealHighClass; Percentile = $percentile
        IlvlHealingRankLabel = $ilvlHealingRankLabel; RawHealingRankLabel = $rawHealingRankLabel
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
$bossesAttempted = if ($reportData.PSObject.Properties.Name -contains "BossesAttempted" -and $reportData.BossesAttempted) { $reportData.BossesAttempted } else { $bossSlugs.Count }
$bossesKilledLabel = if ($bossesAttempted -gt $bossSlugs.Count) { "$($bossSlugs.Count)/$bossesAttempted bosses killed" } else { "$($bossSlugs.Count) bosses killed" }
$overview = Set-TemplateToken $overview "BOSSES_KILLED_LABEL" $bossesKilledLabel

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
if ($analysis.GearAnalysis.PSObject.Properties.Name -contains "EnchantableSlotCount" -and $analysis.GearAnalysis.EnchantableSlotCount -gt 0) {
    $enchantedCount = $analysis.GearAnalysis.EnchantedSlotCount
    $enchantableCount = $analysis.GearAnalysis.EnchantableSlotCount
    $gearItems += [PSCustomObject]@{
        Icon = $(if ($enchantedCount -eq $enchantableCount) { "ok" } else { "note" }); Glyph = $(if ($enchantedCount -eq $enchantableCount) { [char]0x2713 } else { "i" })
        Description = "$enchantedCount of $enchantableCount enchantable slots carry a permanent enchant"
        Detail = ""; LongDetail = ""
    }
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
        ILVL_HEALING_RANK_LABEL = $row.IlvlHealingRankLabel; RAW_HEALING_RANK_LABEL = $row.RawHealingRankLabel
    }
}
$overview = Set-TemplateSlot $overview "RAID_SUMMARY_FINDING" $findings.RaidOverview.RAID_SUMMARY_FINDING

# ----- Raid-wide iLvl Healing Rank + Raw Healing Rank summaries (mechanical,
# no LLM) - see RaidWideIlvlHealingRankSummary/RaidWideRawHealingRankSummary in
# report_data.json (build_boss_report_data.ps1). Each omitted independently
# when no kill this raid had another real tracked-spec healer present for
# that specific metric. -----
$ilvlHealingRankSummaryText = ""
if ($reportData.RaidWideIlvlHealingRankSummary) {
    $rws = $reportData.RaidWideIlvlHealingRankSummary
    $ilvlHealingRankSummaryText = "iLvl Healing Rank: across the $($rws.BossesCompared) kill(s) with another tracked-spec healer present, $CharacterName ranked #1 (by WCL's own HPS Performance Comparison by Item Level) on $($rws.BossesRankedFirst) of them, averaging the $($rws.AvgRankPercent)th percentile by item level across those kills."
}
$overview = Set-TemplateOptional -TemplateText $overview -OptionalName "ILVL_HEALING_RANK_SUMMARY" -SlotName "ILVL_HEALING_RANK_SUMMARY" -Value $ilvlHealingRankSummaryText

$rawHealingRankSummaryText = ""
if ($reportData.RaidWideRawHealingRankSummary) {
    $rws = $reportData.RaidWideRawHealingRankSummary
    $rawHealingRankSummaryText = "Raw Healing Rank: across the $($rws.BossesCompared) kill(s) with another tracked-spec healer present, $CharacterName ranked #1 by real raw total healing done on $($rws.BossesRankedFirst) of them."
}
$overview = Set-TemplateOptional -TemplateText $overview -OptionalName "RAW_HEALING_RANK_SUMMARY" -SlotName "RAW_HEALING_RANK_SUMMARY" -Value $rawHealingRankSummaryText

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
