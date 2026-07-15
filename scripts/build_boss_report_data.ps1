# build_boss_report_data.ps1
#
# Generalizes two one-off computation scripts written by hand in an earlier session
# (compute_danceswtrees_remaining_bosses.ps1, and the ad hoc gear-diff logic used to
# build the raid overview's gear audit) into one reusable, per-character tool. Makes
# ZERO API calls and touches nothing but files already pulled to disk by
# pull_character_TEMPLATE.ps1 / pull_top100_{class}.ps1 / summarize_class_benchmarks.ps1
# - this script's only job is turning those raw files into one clean JSON with every
# real number needed to author a healer's boss pages + raid overview, so nothing
# downstream (the generate-healer-report skill, or a person) has to re-read
# multi-thousand-event raw JSON or hand-compute a percentage.
#
# Usage (run from repo root, same convention as every other script here):
#   powershell -ExecutionPolicy Bypass -File scripts\build_boss_report_data.ps1 -CharacterName "Danceswtrees" -ReportCode "XJp8vAxzM4KtHYyb" -ClassName "Druid"
#
# Output: data\Characters\{CharacterName}\{ReportCode}\{ReportCode}_report_data.json
# (the folder isn't a parameter - it's resolved by finding the real
# fights_{ReportCode}.json pull_character_TEMPLATE.ps1 already wrote, wherever
# under that character's folder it landed, same lookup pattern that script itself
# uses for cache reuse - this also means it still works unmodified against older,
# date-named folders from before the ReportCode-keyed folder change).

param(
    [Parameter(Mandatory=$true)][string]$CharacterName,
    [Parameter(Mandatory=$true)][string]$ReportCode,
    [Parameter(Mandatory=$true)][string]$ClassName,
    [string]$CharactersRoot = "data\Characters"  # override for equivalence-testing against a scratch pull
)

$ErrorActionPreference = "Stop"

# ===== Class-specific cooldown/utility watch list, matched by real GUID - only Druid
# and Shaman are populated today (same real, verified guids already used in
# summarize_class_benchmarks.ps1 and each class's pull_top100_{class}.ps1, not
# re-derived - Shaman's were confirmed against a real Vajomee report, see below). Every
# other class hard-stops below rather than guessing at guids or silently producing an
# empty cooldowns section - see the generate-healer-report skill's class-generality
# caveat for why. Add a real, verified entry here (and confirm the matching
# pull_top100_{class}.ps1 + boss_page_template_{class}.html actually exist) before
# trusting this script for another class. =====
$cooldownGuidsByClass = @{
    "Druid" = [ordered]@{
        "Innervate"          = @(29166)
        "Nature's Swiftness" = @(17116)
        "Swiftmend"          = @(18562)
        "Tranquility"        = @()
        "Rebirth"            = @(26994)
        "Dark Rune"          = @(27869)
    }
    # Confirmed against a real Vajomee report (Z4zNt28raQ6GLbkC, 9 real boss
    # kills) before this entry was added - see pull_top100_shaman.ps1's header
    # for the full discovery writeup. No Rebirth-equivalent exists for Shaman
    # in this TBC ruleset - confirmed absent across all 9 real kills despite
    # real deaths occurring in them, so it's omitted here rather than
    # force-mapped or left as a permanent zero row.
    "Shaman" = [ordered]@{
        "Earth Shield"        = @(32594)
        "Mana Tide Totem"     = @(16190)
        "Ancestral Swiftness" = @(16188)
        "Dark Rune"           = @(27869)
    }
    # Confirmed against a real Lippies report (XJp8vAxzM4KtHYyb, 10 real boss
    # kills, 1,959 real cast events) before this entry was added - see
    # pull_top100_priest_holy.ps1's header for the full discovery writeup.
    # Shadowfiend is the mana-cooldown analog to Innervate/Mana Tide Totem
    # (self-only, ~once/fight, real mana cost 157). Power Word: Shield is
    # tracked with self-vs-other targeting like Swiftmend/Earth Shield (100%
    # other-targeted in the real sample). Chakra and Blessing of Life are both
    # self-only, ~once/fight, free. Fear Ward is other-targeted but rare (~once
    # per 3 fights) - still always shown, same treatment as every other
    # tracked cooldown here (real usage, including zero, is itself the
    # finding). No Rebirth-equivalent exists for Priest in this TBC ruleset -
    # confirmed absent across all 1,959 real cast events despite real deaths
    # occurring, so it's omitted here rather than force-mapped or left as a
    # permanent zero row.
    "Priest" = [ordered]@{
        "Shadowfiend"        = @(34433)
        "Power Word: Shield" = @(10899)
        "Chakra"             = @(14751)
        "Blessing of Life"   = @(38332)
        "Fear Ward"          = @(6346)
        "Dark Rune"          = @(27869)
    }
    # Confirmed against a real Crowns report (XJp8vAxzM4KtHYyb, 10 real boss
    # kills, 2,253 real cast events) before this entry was added - see
    # pull_top100_paladin.ps1's header for the full discovery writeup. Holy
    # Shock's CAST (guid 33072) is tracked here with self-vs-other targeting
    # like Swiftmend/Earth Shield/Power Word: Shield (mixed real targeting, 3
    # self / 5 other) - real finding, confirmed against the full Top 100
    # sample (not just Crowns): the resulting HEAL lands under a genuinely
    # DIFFERENT guid (33074, also named "Holy Shock"), so it flows into
    # SpellRows/BMSpells automatically via the existing guid-grouping logic
    # below, not this table. Crowns's own 8 real casts never happened to land
    # a recorded heal this raid (guid 33074 doesn't appear in her own
    # healing_events.json), which is a real fact about her specific raid
    # night, not a claim that Holy Shock can't heal. Divine Favor and Divine
    # Shield are both
    # self-only (no real other-actor target). Cleanse, Hand of Protection, and
    # Blessing of Freedom are all genuinely other-targeted utility/dispel
    # casts (the latter two rare - ~once per 10 fights each). No
    # Rebirth-equivalent exists for Paladin in this TBC ruleset's in-combat
    # cast data - confirmed absent across all 2,253 real cast events despite
    # real deaths occurring (Paladins do have Redemption, their own
    # resurrection spell, but it cannot be cast on an in-combat target in this
    # ruleset, so it was never going to appear in a boss-kill-window pull
    # regardless) - omitted here rather than force-mapped or left as a
    # permanent zero row.
    "Paladin" = [ordered]@{
        "Holy Shock"          = @(33072)
        "Divine Favor"        = @(20216)
        "Divine Shield"       = @(1020)
        "Cleanse"             = @(4987)
        "Hand of Protection"  = @(10278)
        "Blessing of Freedom" = @(1044)
        "Dark Rune"           = @(27869)
    }
}
$manaPotionNameByClass = @{
    "Druid"   = "Restore Mana"
    "Shaman"  = "Restore Mana"
    "Priest"  = "Restore Mana"
    "Paladin" = "Restore Mana"
}

if (-not $cooldownGuidsByClass.ContainsKey($ClassName)) {
    Write-Host "ERROR: '$ClassName' has no real cooldown-guid table in this script yet - only Druid, Shaman, Priest, and Paladin are wired up today."
    Write-Host "       Add a real, VERIFIED guid table for '$ClassName' (never guess at guids) before running this for that class."
    exit 1
}
$cooldownGuids = $cooldownGuidsByClass[$ClassName]
$manaPotionName = $manaPotionNameByClass[$ClassName]

# ===== Boss metadata - shared across every class, SSC/TK bosses are class-independent.
# encounterID -> slug (matches pull_character_TEMPLATE.ps1's filename convention),
# FolderName (matches data\Classes\{Class}\active\{FolderName}\), Display (matches the
# "Boss" column in every benchmark_*.csv, from summarize_class_benchmarks.ps1).
# Deliberately a PLAIN hashtable, not [ordered] - order doesn't matter here (lookup
# only, never iterated for display order) and [ordered]@{} with bare INTEGER keys has
# a real, silent .NET gotcha: System.Collections.Specialized.OrderedDictionary has a
# positional `this[int index]` indexer that Int32 keys resolve to INSTEAD OF the
# key-based `this[object key]` overload, so `$orderedDict[100623]` silently returns
# $null (no error) even though `.Contains(100623)` correctly returns $true - hit this
# for real while building this script (bossMeta.Contains() said true, every lookup
# still returned null). Confirmed via isolated repro against a plain @{} (works) vs.
# [ordered]@{} (silently broken) with the identical integer key. Matches
# pull_character_TEMPLATE.ps1's own $bossSlugs table, which already uses a plain
# hashtable for exactly this key shape - never change this one to [ordered]@{}. =====
$bossMeta = @{
    50649 = @{ Slug = "maulgar";     FolderName = "Maulgar";     Display = "High King Maulgar" }
    50650 = @{ Slug = "gruul";       FolderName = "Gruul";       Display = "Gruul the Dragonkiller" }
    50651 = @{ Slug = "magtheridon"; FolderName = "Magtheridon"; Display = "Magtheridon" }
    100623 = @{ Slug = "hydross";    FolderName = "Hydross";    Display = "Hydross the Unstable" }
    100624 = @{ Slug = "lurker";     FolderName = "Lurker";     Display = "The Lurker Below" }
    100625 = @{ Slug = "leotheras";  FolderName = "Leotheras";  Display = "Leotheras the Blind" }
    100626 = @{ Slug = "karathress"; FolderName = "Karathress"; Display = "Fathom-Lord Karathress" }
    100627 = @{ Slug = "morogrim";   FolderName = "Morogrim";   Display = "Morogrim Tidewalker" }
    100628 = @{ Slug = "vashj";      FolderName = "Vashj";      Display = "Lady Vashj" }
    100730 = @{ Slug = "alar";       FolderName = "Alar";       Display = "Al'ar" }
    100731 = @{ Slug = "voidreaver"; FolderName = "VoidReaver"; Display = "Void Reaver" }
    100732 = @{ Slug = "solarian";   FolderName = "Solarian";   Display = "High Astromancer Solarian" }
    100733 = @{ Slug = "kaelthas";   FolderName = "Kaelthas";   Display = "Kael'thas Sunstrider" }
}

# ===== Locate this character's data folder for this exact report - search rather than
# require a -DateFolder param, since pull_character_TEMPLATE.ps1 derives the raid date
# from the report title, not from anything this script would otherwise know. =====
$charRoot = Join-Path $CharactersRoot $CharacterName
if (-not (Test-Path $charRoot)) {
    Write-Host "ERROR: $charRoot not found - run pull_character_TEMPLATE.ps1 for '$CharacterName' first."
    exit 1
}
$fightsFile = Get-ChildItem -Path $charRoot -Recurse -Filter "fights_$ReportCode.json" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $fightsFile) {
    Write-Host "ERROR: no fights_$ReportCode.json found anywhere under $charRoot - run pull_character_TEMPLATE.ps1 -ReportCode $ReportCode -CharacterName $CharacterName first."
    exit 1
}
$charDir = $fightsFile.DirectoryName
Write-Host "Character data folder: $charDir"

$fightsData = Get-Content $fightsFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

# Present on every fights_*.json written since the ReportCode-keyed folder change
# (see pull_character_TEMPLATE.ps1) - absent on older pre-existing pulls, where the
# raid date instead has to come from the (old-convention) date-named folder itself.
# Propagated into report_data.json below so nothing downstream needs to re-derive
# it from a folder name that may no longer even be a date.
$raidDate = if ($fightsData.PSObject.Properties.Name -contains "raidDate") { $fightsData.raidDate } else { $null }

# ===== Percentile/rank source (v2 migration, see the approved migration plan) =====
# Was: {name}_all_parses.json (v1 /parses/character/), fuzzy-matched by
# reportID+fightID against the character's WHOLE parse history - confirmed live
# to be structurally incomplete (only returns a capped "notable parses" list, not
# every real kill - 8 of 9 kills in a real report came back unmatched even after
# a fresh re-pull with a stable connection, ruling out a connection/timing issue).
# Now: {ReportCode}_v2_rankings.json (v2 reportData.report(code).rankings(
# fightIDs:[...])), pulled once per report by pull_character_v2.ps1/
# pull_character_TEMPLATE.ps1 (once the migration lands) - exact by construction,
# every fight ID requested either has a real healer entry or it doesn't, no fuzzy
# matching against a separately-fetched blob at all.
$rankingsPath = Join-Path $charDir "$($ReportCode)_v2_rankings.json"
$rankingsData = if (Test-Path $rankingsPath) { Get-Content $rankingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } else {
    Write-Host "  WARNING: $rankingsPath not found - percentile/rank will be blank for every boss."
    $null
}

$benchDir = Join-Path (Join-Path "data\Classes" $ClassName) "active"
if (-not (Test-Path $benchDir)) {
    Write-Host "ERROR: $benchDir not found - run pull_top100_$($ClassName.ToLower()).ps1 then summarize_class_benchmarks.ps1 -ClassName $ClassName first."
    exit 1
}
$bmSummary = Import-Csv (Join-Path $benchDir "benchmark_summary.csv")
$bmSpells = Import-Csv (Join-Path $benchDir "benchmark_spell_composition.csv")
$bmCooldowns = Import-Csv (Join-Path $benchDir "benchmark_cooldowns.csv")
$bmBuffs = Import-Csv (Join-Path $benchDir "benchmark_buffs.csv")

$bossFights = @($fightsData.fights | Where-Object { $_.boss -ne 0 -and $_.kill -eq $true })
Write-Host "$($bossFights.Count) boss kill(s) found for $CharacterName in report $ReportCode."

$results = [ordered]@{}
$gearByBoss = [ordered]@{}

foreach ($fight in $bossFights) {
    $bossID = $fight.boss
    if (-not $bossMeta.Contains($bossID)) {
        Write-Host "  WARNING: boss id $bossID ('$($fight.name)') has no known slug/display mapping - skipping. Add it to `$bossMeta` in this script if it's a real boss this pipeline should cover."
        continue
    }
    $meta = $bossMeta[$bossID]
    $fightIDPadded = "{0:D2}" -f $fight.id
    $label = "fight$($fightIDPadded)_$($meta.Slug)"
    $start = $fight.start_time
    $end = $fight.end_time
    $duration = $end - $start

    $healingPath = Join-Path $charDir "$($label)_healing_events.json"
    $castsPath = Join-Path $charDir "$($label)_casts_events.json"
    $consumablesPath = Join-Path $charDir "$($label)_consumables.json"
    $activeTimePath = Join-Path $charDir "$($label)_activetime.json"
    $deathsPath = Join-Path $charDir "$($label)_deaths.json"
    $gearPath = Join-Path $charDir "$($label)_gear.json"

    if (-not (Test-Path $healingPath) -or -not (Test-Path $castsPath)) {
        Write-Host "  WARNING: $label - missing healing_events or casts_events, skipping this boss entirely."
        continue
    }

    $healingData = Get-Content $healingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $castsData = Get-Content $castsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $consumablesData = if (Test-Path $consumablesPath) { Get-Content $consumablesPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $activeTimeData = if (Test-Path $activeTimePath) { Get-Content $activeTimePath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $deathsData = if (Test-Path $deathsPath) { Get-Content $deathsPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $gearData = if (Test-Path $gearPath) { Get-Content $gearPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

    $total = $healingData.totalAmount
    $overheal = $healingData.totalOverheal
    $rawHealing = $total + $overheal
    $overhealPct = if ($rawHealing -gt 0) { [math]::Round(($overheal / $rawHealing) * 100, 1) } else { 0 }
    $hps = if ($duration -gt 0) { [math]::Round($total / ($duration / 1000), 0) } else { 0 }

    # ----- Spell composition, strictly by guid (never by display name - two guids can
    # share a display name and mean genuinely different things, see WORKFLOW.md) -----
    $abilities = @{}
    foreach ($ev in $healingData.events) {
        if ($ev.ability -and $ev.amount) {
            $guid = $ev.ability.guid
            if (-not $abilities.ContainsKey($guid)) { $abilities[$guid] = [PSCustomObject]@{ Name = $ev.ability.name; Total = 0.0 } }
            $abilities[$guid].Total += $ev.amount
        }
    }
    $spellRows = @()
    foreach ($guid in $abilities.Keys) {
        $pct = if ($total -gt 0) { [math]::Round(($abilities[$guid].Total / $total) * 100, 1) } else { 0 }
        $spellRows += [PSCustomObject]@{ Guid = $guid; Name = $abilities[$guid].Name; Total = [math]::Round($abilities[$guid].Total, 0); Pct = $pct }
    }
    $spellRows = @($spellRows | Sort-Object -Property Total -Descending)

    # ----- Real mana cost per guid, from classResources on this fight's own cast
    # events - used to distinguish spell RANKS (WCL's API has no rank field at all;
    # different real guids sharing a display name are the only signal it gives us,
    # see WORKFLOW.md gotcha #20/#32 - mana cost is the best available proxy for
    # which rank is "higher", confirmed real per-cast, not looked up from a static
    # table). Only ever known for guids THIS character actually cast THIS kill -
    # left unresolved (not guessed) for benchmark-only ranks never cast here. -----
    $manaCostByGuid = @{}
    foreach ($ev in $castsData.events) {
        if ($ev.ability -and $ev.classResources -and $ev.classResources.Count -gt 0) {
            $g = [string]$ev.ability.guid
            if (-not $manaCostByGuid.ContainsKey($g)) {
                $manaCostByGuid[$g] = [math]::Round($ev.classResources[0].max, 0)
            }
        }
    }

    # ----- Target distribution -----
    $targets = @{}
    foreach ($ev in $healingData.events) {
        if ($ev.targetName -and $ev.amount) {
            if (-not $targets.ContainsKey($ev.targetName)) { $targets[$ev.targetName] = 0.0 }
            $targets[$ev.targetName] += $ev.amount
        }
    }
    $sortedTargets = @($targets.GetEnumerator() | Sort-Object -Property Value -Descending)
    $top5 = @($sortedTargets | Select-Object -First 5)
    $top5Sum = ($top5 | Measure-Object -Property Value -Sum).Sum
    if ($null -eq $top5Sum) { $top5Sum = 0 }
    $coveragePct = if ($total -gt 0) { [math]::Round(($top5Sum / $total) * 100, 1) } else { 0 }
    $top1Pct = if ($sortedTargets.Count -gt 0 -and $total -gt 0) { [math]::Round(($sortedTargets[0].Value / $total) * 100, 1) } else { 0 }
    $topAmount = if ($top5.Count -gt 0) { $top5[0].Value } else { 1 }
    $targetRows = @()
    foreach ($t in $top5) {
        $pct = if ($total -gt 0) { [math]::Round(($t.Value / $total) * 100, 1) } else { 0 }
        $barWidth = if ($topAmount -gt 0) { [math]::Round(($t.Value / $topAmount) * 100, 1) } else { 0 }
        $targetRows += [PSCustomObject]@{ Name = $t.Name; Pct = $pct; BarWidth = $barWidth; Amount = [math]::Round($t.Value, 0) }
    }

    # ----- Cooldowns/utility, excluding begincast (real bug fixed earlier this
    # project: a begincast phantom-event double-counts a cast-time cooldown and
    # falsely marks it self - see WORKFLOW.md). Real per-cast target names included,
    # not just a count - the whole point of the events-based redesign. -----
    $cooldownRows = [ordered]@{}
    foreach ($cdName in $cooldownGuids.Keys) {
        $guidList = $cooldownGuids[$cdName]
        $matched = @(if ($guidList.Count -gt 0) { $castsData.events | Where-Object { ($guidList -contains $_.ability.guid) -and ($_.type -ne "begincast") } })
        # A self-only-castable spell has no real other-actor target at all - WCL logs
        # this as targetID=-1, which the pull scripts' actor-name lookup resolves to
        # the literal string "Environment" whenever the report's own masterData.actors[]
        # happens to include that special id=-1 entry (real, confirmed live on Lippies'
        # report XJp8vAxzM4KtHYyb - Shadowfiend/Chakra/Blessing of Life ALL showed
        # Target="Environment" instead of "self" here before this fix), or "Unknown_-1"
        # when it doesn't. Neither is null/empty, so the original check
        # (sourceName -eq targetName, or IsNullOrEmpty) missed both - confirmed this was
        # ALREADY a small real inaccuracy in already-shipped Druid data too (a real
        # Nature's Swiftness cast on Hydross showed targetName="Environment", not null;
        # Top100SelfPct read 99% instead of the mechanically-required ~100%). Fixed by
        # also treating a literal "Environment" targetName as self - a spell logged
        # against the Environment pseudo-actor mechanically cannot have gone to a real
        # other player.
        $targetList = @()
        foreach ($m in $matched) {
            $isSelf = ($m.sourceName -eq $m.targetName) -or [string]::IsNullOrEmpty($m.targetName) -or ($m.targetName -eq "Environment")
            $targetList += [PSCustomObject]@{ Target = $(if ($isSelf) { "self" } else { $m.targetName }); Timestamp = $m.timestamp }
        }
        $selfCount = @($targetList | Where-Object { $_.Target -eq "self" }).Count
        $cooldownRows[$cdName] = [PSCustomObject]@{ Count = $matched.Count; SelfCount = $selfCount; Targets = $targetList }
    }
    if ($manaPotionName) {
        $manaMatched = @($castsData.events | Where-Object { $_.ability.name -eq $manaPotionName })
        # Mana Potion is always self-only (a consumable can't be used on someone else), but
        # Targets still needs one real "self" entry per cast - a hardcoded empty array here
        # silently broke Format-CooldownTarget's "self" mode (which checks Targets.Count, not
        # Count directly), always rendering "-" instead of "self" even when Count > 0.
        $manaTargets = @($manaMatched | ForEach-Object { [PSCustomObject]@{ Target = "self"; Timestamp = $_.timestamp } })
        $cooldownRows["Mana Potion"] = [PSCustomObject]@{ Count = $manaMatched.Count; SelfCount = $manaMatched.Count; Targets = $manaTargets }
    }

    # ----- HPM, from classResources[0].max on every cast event that carries one -----
    $manaSpent = 0.0
    foreach ($ev in $castsData.events) {
        if ($ev.classResources -and $ev.classResources.Count -gt 0) {
            $manaSpent += $ev.classResources[0].max
        }
    }
    $hpm = if ($manaSpent -gt 0) { [math]::Round($total / $manaSpent, 2) } else { $null }

    $activeTimePct = if ($activeTimeData) { $activeTimeData.activeTimePct } else { $null }

    $deathCount = if ($deathsData) { @($deathsData.entries).Count } else { $null }
    $deathList = @()
    if ($deathsData) {
        foreach ($d in $deathsData.entries) { $deathList += [PSCustomObject]@{ Name = $d.name; Timestamp = $d.timestamp } }
    }

    # ----- Percentile/rank, matched by EXACT fightID within this report's own
    # v2 rankings pull - see the loading comment above for why this replaced the
    # old all_parses.json fuzzy match. -----
    $rankingFight = if ($rankingsData) { $rankingsData.data | Where-Object { $_.fightID -eq $fight.id } | Select-Object -First 1 } else { $null }
    $healerMatch = if ($rankingFight) { $rankingFight.roles.healers.characters | Where-Object { $_.name -eq $CharacterName } | Select-Object -First 1 } else { $null }
    $percentile = if ($healerMatch) { [math]::Round($healerMatch.rankPercent, 0) } else { $null }
    $rank = if ($healerMatch) { $healerMatch.rank } else { $null }
    $outOf = if ($healerMatch) { $healerMatch.totalParses } else { $null }
    if (-not $healerMatch) {
        Write-Host "  WARNING: $label - no matching healer entry in $($ReportCode)_v2_rankings.json for fightID=$($fight.id) - percentile/rank will be blank."
    }

    # ----- Benchmark comparisons -----
    $bmRow = $bmSummary | Where-Object { $_.Boss -eq $meta.Display } | Select-Object -First 1
    $bmSpellRows = @($bmSpells | Where-Object { $_.Boss -eq $meta.Display })
    $bmCdRows = @($bmCooldowns | Where-Object { $_.Boss -eq $meta.Display })
    $bmBuffRow = $bmBuffs | Where-Object { $_.Boss -eq $meta.Display } | Select-Object -First 1
    if (-not $bmRow) {
        Write-Host "  WARNING: $label - no benchmark_summary.csv row for '$($meta.Display)' - Top 100 comparisons will be blank. Re-run summarize_class_benchmarks.ps1 -ClassName $ClassName if this boss should have data."
    }

    $results[$meta.Slug] = [PSCustomObject]@{
        Display             = $meta.Display
        FightID             = $fight.id
        Duration            = $duration
        Total               = [math]::Round($total, 0)
        Overheal            = [math]::Round($overheal, 0)
        OverhealPct         = $overhealPct
        HPS                 = $hps
        SpellRows           = $spellRows
        ManaCostByGuid      = $manaCostByGuid
        TargetRows          = $targetRows
        CoveragePct         = $coveragePct
        Top1Pct             = $top1Pct
        DistinctTargetCount = $sortedTargets.Count
        CooldownRows        = $cooldownRows
        ManaSpent           = [math]::Round($manaSpent, 0)
        HPM                 = $hpm
        ActiveTimePct       = $activeTimePct
        DeathCount          = $deathCount
        DeathList           = $deathList
        Percentile          = $percentile
        Rank                = $rank
        OutOf               = $outOf
        FlaskActive         = if ($consumablesData) { [bool]$consumablesData.flaskActive } else { $null }
        FlaskName           = if ($consumablesData) { $consumablesData.flaskName } else { $null }
        FoodActive          = if ($consumablesData) { [bool]$consumablesData.foodActive } else { $null }
        FoodName            = if ($consumablesData) { $consumablesData.foodName } else { $null }
        TreeOfLifePct       = if ($consumablesData) { $consumablesData.treeOfLifeUptimePct } else { $null }
        BM                  = $bmRow
        BMSpells            = $bmSpellRows
        BMCooldowns         = $bmCdRows
        BMBuffs             = $bmBuffRow
    }

    if ($gearData -and $gearData.gear) {
        $gearByBoss[$meta.Slug] = $gearData.gear
    }
}

# ----- Gear diff across every kill with a real gear.json - purely factual (which
# slots vary, and what's equipped on each kill where they do). No interpretation
# baked in here - e.g. whether a mainhand swap is a benign fishing-pole moment or a
# real gearing gap is a judgment call for whoever reads this, not this script. -----
$gearDiff = $null
if ($gearByBoss.Count -gt 0) {
    $bossSlugsWithGear = @($gearByBoss.Keys)
    $firstSlug = $bossSlugsWithGear[0]
    $slotCount = $gearByBoss[$firstSlug].Count
    $slotDiffs = @()
    for ($i = 0; $i -lt $slotCount; $i++) {
        $variants = [ordered]@{}
        foreach ($slug in $bossSlugsWithGear) {
            $g = $gearByBoss[$slug][$i]
            $gemIds = if ($g.gems) { ($g.gems | ForEach-Object { $_.id }) -join "," } else { "" }
            $sig = "$($g.id)|$($g.permanentEnchant)|$($g.temporaryEnchant)|$gemIds"
            if (-not $variants.Contains($sig)) {
                $variants[$sig] = [PSCustomObject]@{ Item = $g; Bosses = New-Object System.Collections.Generic.List[string] }
            }
            $variants[$sig].Bosses.Add($slug)
        }
        if ($variants.Count -gt 1) {
            $variantList = @()
            foreach ($v in $variants.Values) {
                $variantList += [PSCustomObject]@{
                    ItemId            = $v.Item.id
                    PermanentEnchant  = $v.Item.permanentEnchant
                    TemporaryEnchant  = $v.Item.temporaryEnchant
                    Icon              = $v.Item.icon
                    SeenOn            = @($v.Bosses)
                }
            }
            $slotDiffs += [PSCustomObject]@{ SlotIndex = $i; Icon = $gearByBoss[$firstSlug][$i].icon; Variants = $variantList }
        }
    }
    $gearDiff = [PSCustomObject]@{
        BossesCompared           = $bossSlugsWithGear
        SlotCount                = $slotCount
        DifferingSlots           = $slotDiffs
        ConsistentAcrossAllKills = ($slotDiffs.Count -eq 0)
        BaselineGear             = $gearByBoss[$firstSlug]
    }
} else {
    Write-Host "  WARNING: no *_gear.json files found for any boss - gear audit section will have no real data. Run the updated pull_character_TEMPLATE.ps1 (adds gear.json alongside consumables.json) if this character's data predates that."
}

$output = [PSCustomObject]@{
    CharacterName = $CharacterName
    ClassName     = $ClassName
    ReportCode    = $ReportCode
    RaidDate      = $raidDate
    Bosses        = $results
    GearDiff      = $gearDiff
}

$outPath = Join-Path $charDir "$($ReportCode)_report_data.json"
$jsonText = $output | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($outPath, $jsonText, (New-Object System.Text.UTF8Encoding $false))

Write-Host ""
Write-Host "Wrote $outPath"
Write-Host "$($results.Count) boss kill(s) processed."
