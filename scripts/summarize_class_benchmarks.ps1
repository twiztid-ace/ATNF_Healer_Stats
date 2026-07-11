# summarize_class_benchmarks.ps1
#
# Reads the raw Top 100 data pulled by pull_top100_druid.ps1 and computes the derived
# benchmark stats our analysis actually uses - PER BOSS:
#   - HPS / overheal percentiles           (from rankings.json + *_healing_events.json)
#   - Top 10 spell composition             (from *_healing_events.json, grouped by guid)
#   - Top 10 target concentration          (from *_healing_events.json, grouped by target)
#   - Top 10 cooldown/utility/consumable cast counts, with self-vs-other target split
#                                           (from *_casts_events.json)
#   - Top 10 self-buff stats: % with flask/food active at pull start, average real
#     Tree of Life uptime %                (from *_consumables.json)
#
# Outputs compact CSVs, small enough to upload to Claude Project knowledge:
#   benchmark_summary.csv               <- one row per boss (HPS, overheal, target stats)
#   benchmark_spell_composition.csv     <- one row per boss+spell (Top 10 avg % of healing)
#   benchmark_cooldowns.csv             <- one row per boss+ability (Top 10 avg casts, self%)
#   benchmark_buffs.csv                 <- one row per boss (Top 10 flask/food/Tree of Life)
#
# ============================================================================
# 2026-07-11 REWRITE: reads events, not tables, for healing/casts. Two real bugs fixed
# in the process, both confirmed against actual pulled data before this rewrite:
# ============================================================================
# 1. TRUNCATION: the old healing/casts TABLE views silently capped their per-player
#    "abilities" array at 5 entries (see WORKFLOW.md gotcha list). This script now reads
#    *_healing_events.json / *_casts_events.json instead - complete, per-event records,
#    no cap. Spell composition and cooldown counts from any run of the old script should
#    be treated as unverified.
# 2. LOCALIZATION SPLIT: the old script grouped spell composition by ability NAME. Real
#    data check on this exact Hydross/Lurker pull found Lifebloom alone logged under 7
#    different localized names (Korean/Portuguese/German/French/Chinese/Spanish/English)
#    across the Top 100 sample - the old script would have silently split one spell into
#    seven separate rows instead of aggregating them. This script groups by ability GUID
#    instead (guid is locale-independent), and picks a display name preferring ASCII
#    when multiple names are seen for the same guid (mirrors the existing player-name
#    convention from gotcha #2 in the pull scripts).
# 3. DIFFERENT GUIDS SHARING A NAME ARE NOT MERGED. An earlier version of this rewrite
#    tried a second pass merging by the resolved display name (to combine what looked
#    like duplicate "Lifebloom" rows from different guids) - real data proved that wrong.
#    Lifebloom's two guids (33763, 33778) both display as "Lifebloom" in every language,
#    but are empirically different: 33763 is 100% tick=true, ~310 avg amount (the HoT
#    component); 33778 is 100% tick=false, ~515 avg amount (the "bloom" burst heal on
#    expiry) - two real mechanics, not a duplicate. Regrowth/Rejuvenation's dual guids
#    looked different again on inspection (mixed tick/non-tick, similar amounts, very
#    different frequency - more consistent with rank variance). Rather than assert what
#    each guid "means" per spell (which only covers spells someone has actually checked
#    and risks being wrong), every guid stays its own row always; when two guids share a
#    display name the guid is appended to disambiguate instead of guessing at a label.
# 4. BUFF UPTIME, ADDED BACK LATER THE SAME DAY. The original *_buffs.json (a table
#    view, sourceclass=Druid&hostility=0, no `by=` param) was found to merge every
#    Druid's buffs in a fight into one flat list, not scoped to the ranked player the
#    file was named after - confirmed on real data showing Moonkin Form + Dire Bear
#    Form + Tree of Life simultaneously (three different specs' forms, impossible for
#    one character). benchmark_buffs.csv was dropped entirely for a while as a result.
#    It's back now, reading *_consumables.json instead: flask/food are booleans (active
#    at the pull-start combatantinfo snapshot, since those buffs outlast any single
#    fight and a snapshot is enough), Tree of Life is a real reconstructed uptime %
#    (apply/remove event interval reconstruction, guid 33891 only - its paired guid
#    34123 shares the display name but toggles far more often in ways that don't match
#    manual form-toggling, empirically untrustworthy, excluded). See
#    pull_top100_druid.ps1's header for the full validation writeup.
#
# Target coverage/top1% are also now computed from the complete per-event target
# breakdown instead of the healing table's `targets[]` array, which had the exact same
# undocumented top-5 truncation as `abilities[]` - "coverage" still means "top 5
# recipients as % of total", same definition the templates already use, just accurate.
#
# Run this from your repo ROOT directory (same place you ran the pull script from).
#
# Usage: powershell -ExecutionPolicy Bypass -File summarize_class_benchmarks.ps1 -ClassName Druid -DateFolder 2026-07-10

param(
    [Parameter(Mandatory=$true)][string]$ClassName,
    [Parameter(Mandatory=$true)][string]$DateFolder
)

$classesRoot = "data\Classes"
$classDateDir = Join-Path (Join-Path $classesRoot $ClassName) $DateFolder

if (-not (Test-Path $classDateDir)) {
    Write-Host "ERROR: $classDateDir not found."
    exit 1
}

# boss folder name -> (rankings filename, display name) - matches pull_top100_druid.ps1
$bosses = [ordered]@{
    "Hydross"    = @{ file = "rankings_hydross.json";    display = "Hydross the Unstable" }
    "Lurker"     = @{ file = "rankings_lurker.json";     display = "The Lurker Below" }
    "Leotheras"  = @{ file = "rankings_leotheras.json";  display = "Leotheras the Blind" }
    "Karathress" = @{ file = "rankings_karathress.json"; display = "Fathom-Lord Karathress" }
    "Morogrim"   = @{ file = "rankings_morogrim.json";   display = "Morogrim Tidewalker" }
    "Vashj"      = @{ file = "rankings_vashj.json";      display = "Lady Vashj" }
    "Alar"       = @{ file = "rankings_alar.json";       display = "Al'ar" }
    "VoidReaver" = @{ file = "rankings_voidreaver.json"; display = "Void Reaver" }
    "Solarian"   = @{ file = "rankings_solarian.json";   display = "High Astromancer Solarian" }
    "Kaelthas"   = @{ file = "rankings_kaelthas.json";   display = "Kael'thas Sunstrider" }
}

# ===== Cooldown/utility watch list (Druid-specific), matched by GUID - real guids
# extracted from actual pulled data, not guessed. Tranquility still empty; add its guid
# here once it's actually observed in a pull (see WORKFLOW.md). =====
$cooldownGuids = [ordered]@{
    "Innervate"          = @(29166)
    "Nature's Swiftness" = @(17116)
    "Swiftmend"          = @(18562)
    "Tranquility"        = @()
    "Rebirth"            = @(26994)
    "Dark Rune"          = @(27869)
}
# Matched by NAME instead of guid - real data shows 3+ different guids for this single
# effect (different mana potion tiers/items), so name is the more stable match here.
$manaPotionName = "Restore Mana"

# ===== Self-buff uptime: no watch-list constants needed here - flask/elixir/food
# matching and Tree of Life guid selection already happened at pull time (see
# pull_top100_druid.ps1's Get-ConsumablesSnapshotLocal / Get-TreeOfLifeUptimeLocal).
# This script just reads the already-computed flaskActive/foodActive/
# treeOfLifeUptimePct fields straight out of each *_consumables.json. =====

function Test-IsAscii($s) {
    if ($null -eq $s) { return $false }
    return ($s -match '^[\x00-\x7F]*$')
}

# Adds/updates a guid-keyed aggregate hashtable, preferring an ASCII display name when
# multiple locales are seen for the same guid (Lifebloom was seen under 7 different
# names in real data - see header comment).
function Add-GuidAggregate {
    param([hashtable]$Agg, [int]$Guid, [string]$Name, [double]$Amount)
    if (-not $Agg.ContainsKey($Guid)) {
        $Agg[$Guid] = [PSCustomObject]@{ Name = $Name; Total = 0.0 }
    } else {
        if (-not (Test-IsAscii $Agg[$Guid].Name) -and (Test-IsAscii $Name)) {
            $Agg[$Guid].Name = $Name
        }
    }
    $Agg[$Guid].Total += $Amount
}

$summaryRows = @()
$spellCompRows = @()
$cooldownRows = @()
$buffRows = @()

foreach ($bossFolder in $bosses.Keys) {
    $bossInfo = $bosses[$bossFolder]
    $bossName = $bossInfo.display
    $bossDir = Join-Path $classDateDir $bossFolder
    $rankingsFile = Join-Path $classDateDir $bossInfo.file

    if (-not (Test-Path $bossDir)) {
        Write-Host "SKIP: $bossDir not found."
        continue
    }
    if (-not (Test-Path $rankingsFile)) {
        Write-Host "SKIP: $rankingsFile not found (needed for duration/HPS) - rankings pull may have failed."
        continue
    }

    $rankingsData = Get-Content $rankingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($rankingsData.PSObject.Properties.Name -contains "error") {
        Write-Host "SKIP: $bossFolder rankings file contains an API error, not a rankings list."
        continue
    }
    $rankings = $rankingsData.rankings

    $healingFiles = Get-ChildItem -Path $bossDir -Filter "*_healing_events.json"
    Write-Host "Processing $bossName ($($healingFiles.Count) healing event files)..."

    $castsFailCount = 0
    $consumablesFailCount = 0

    $records = @()
    foreach ($file in $healingFiles) {
        try {
            $healingData = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            continue
        }
        $playerName = $healingData.sourceName
        if (-not $playerName) { continue }

        # reportID and fightID are the first two underscore-separated segments of the
        # filename and are always plain ASCII (report codes, numeric fight IDs) - safe
        # to split even though the player-name portion later in the filename may be
        # Windows-hex-escaped for non-ASCII characters (gotcha #1). We don't need to
        # decode that here at all, since the real player name comes from the file's own
        # sourceName field instead - much more robust than re-deriving it from the path.
        $nameParts = $file.BaseName -split '_', 3
        $reportID = $nameParts[0]
        $fightID = [int]$nameParts[1]

        $rankMatch = $rankings | Where-Object { $_.reportID -eq $reportID -and $_.fightID -eq $fightID -and $_.name -eq $playerName } | Select-Object -First 1
        if (-not $rankMatch) {
            Write-Host "  WARNING: no rankings entry matched for $playerName ($reportID/$fightID) - skipping (can't get duration/HPS)."
            continue
        }

        $total = $healingData.totalAmount
        $overheal = $healingData.totalOverheal
        $raw = $total + $overheal
        $overhealPct = if ($raw -gt 0) { ($overheal / $raw) * 100 } else { 0 }
        $hps = if ($rankMatch.duration -gt 0) { $total / ($rankMatch.duration / 1000) } else { 0 }

        # ----- Spell composition: group by ability guid, not name (see header) -----
        $abilities = @{}
        $targets = @{}
        foreach ($ev in $healingData.events) {
            if ($ev.ability -and $ev.amount) {
                Add-GuidAggregate -Agg $abilities -Guid $ev.ability.guid -Name $ev.ability.name -Amount $ev.amount
            }
            if ($ev.targetName -and $ev.amount) {
                if (-not $targets.ContainsKey($ev.targetName)) { $targets[$ev.targetName] = 0.0 }
                $targets[$ev.targetName] += $ev.amount
            }
        }
        $sortedTargets = $targets.GetEnumerator() | Sort-Object -Property Value -Descending
        $top5Sum = ($sortedTargets | Select-Object -First 5 | Measure-Object -Property Value -Sum).Sum
        if ($null -eq $top5Sum) { $top5Sum = 0 }
        $coveragePct = if ($total -gt 0) { ($top5Sum / $total) * 100 } else { 0 }
        $top1Pct = if ($sortedTargets.Count -gt 0 -and $total -gt 0) { ($sortedTargets[0].Value / $total) * 100 } else { 0 }

        # ----- Cooldowns/utility/consumables, from the sibling *_casts_events.json -----
        $cooldownCounts = $null
        $castsFile = $file.FullName -replace '_healing_events\.json$', '_casts_events.json'
        if (Test-Path $castsFile) {
            try {
                $castsData = Get-Content $castsFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $cooldownCounts = @{}
                foreach ($cdName in $cooldownGuids.Keys) {
                    $guidList = $cooldownGuids[$cdName]
                    # @() wraps the WHOLE if/else, not its individual branches - wrapping
                    # only inside the branches (the previous version of this line) does
                    # NOT reliably survive assignment through the if/else-as-expression
                    # mechanism: a zero-match Where-Object result flowing through that
                    # inner @() can still collapse back to $null once the outer if/else
                    # captures it, silently turning "$matched.Count" into a blank instead
                    # of 0. Confirmed on real execution: Innervate showed a blank matched
                    # count for a player file confirmed (by three independent checks) to
                    # contain a real Innervate event, while Swiftmend's identical-shaped
                    # code worked - the only difference was incidental (Swiftmend's
                    # matches happened to be non-empty for the specific players tested,
                    # never exercising the empty-collection collapse). This outer-wrap
                    # form is the same safe idiom already used two lines below for
                    # $selfCount and $manaMatched, which never showed this bug.
                    $matched = @(if ($guidList.Count -gt 0) { $castsData.events | Where-Object { $guidList -contains $_.ability.guid } })
                    $selfCount = @($matched | Where-Object { $_.sourceName -eq $_.targetName }).Count
                    $cooldownCounts[$cdName] = [PSCustomObject]@{ Count = $matched.Count; SelfCount = $selfCount }
                }
                $manaMatched = @($castsData.events | Where-Object { $_.ability.name -eq $manaPotionName })
                $cooldownCounts["Mana Potion"] = [PSCustomObject]@{ Count = $manaMatched.Count; SelfCount = $manaMatched.Count }
            } catch {
                $castsFailCount++
            }
        }

        # ----- Self-buff uptime, from the sibling *_consumables.json (2026-07-11
        # redesign - replaces the old *_buffs.json table, which was found to merge
        # every Druid's buffs in a fight into one flat list, not scoped to this
        # player. See header comment for the full writeup. Flask/food are read as
        # simple booleans ("active at pull start", not a computed uptime %, since
        # that's all a snapshot can tell us) - Tree of Life is a real reconstructed
        # uptime % (see pull_top100_druid.ps1's Get-TreeOfLifeUptimeLocal). -----
        $buffUptimes = $null
        $consumablesFile = $file.FullName -replace '_healing_events\.json$', '_consumables.json'
        if (Test-Path $consumablesFile) {
            try {
                $consumablesData = Get-Content $consumablesFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $buffUptimes = [PSCustomObject]@{
                    FlaskActive   = [bool]$consumablesData.flaskActive
                    FoodActive    = [bool]$consumablesData.foodActive
                    TreeOfLifePct = $consumablesData.treeOfLifeUptimePct
                }
            } catch {
                $consumablesFailCount++
            }
        }

        $records += [PSCustomObject]@{
            PlayerName    = $playerName
            HPS           = $hps
            OverhealPct   = $overhealPct
            CoveragePct   = $coveragePct
            Top1Pct       = $top1Pct
            Abilities     = $abilities
            Cooldowns     = $cooldownCounts
            BuffUptimes   = $buffUptimes
        }
    }

    if ($records.Count -eq 0) { continue }
    if ($castsFailCount -gt 0) {
        Write-Host "  WARNING: $castsFailCount casts_events files for $bossName failed to parse - those players excluded from the cooldown aggregate only."
    }
    if ($consumablesFailCount -gt 0) {
        Write-Host "  WARNING: $consumablesFailCount consumables files for $bossName failed to parse - those players excluded from the buff aggregate only."
    }

    $sorted = $records | Sort-Object -Property HPS -Descending
    $n = $sorted.Count
    $top1 = $sorted[0].HPS
    $top10 = $sorted | Select-Object -First 10
    $top10Avg = ($top10 | Measure-Object -Property HPS -Average).Average
    $median = $sorted[[int]($n/2)].HPS

    $ohSorted = $records | Sort-Object -Property OverhealPct
    $ohBest = $ohSorted[0].OverhealPct
    $ohMedian = $ohSorted[[int]($n/2)].OverhealPct
    $ohWorst = $ohSorted[$n-1].OverhealPct

    $covAvg = ($top10 | Measure-Object -Property CoveragePct -Average).Average
    $top1PctAvg = ($top10 | Measure-Object -Property Top1Pct -Average).Average

    $summaryRows += [PSCustomObject]@{
        Boss = $bossName
        HPS_Top1 = [math]::Round($top1, 0)
        HPS_Top10Avg = [math]::Round($top10Avg, 0)
        HPS_Median = [math]::Round($median, 0)
        Overheal_Best = [math]::Round($ohBest, 1)
        Overheal_Median = [math]::Round($ohMedian, 1)
        Overheal_Worst = [math]::Round($ohWorst, 1)
        Top10_TargetCoveragePct = [math]::Round($covAvg, 1)
        Top10_TargetTop1Pct = [math]::Round($top1PctAvg, 1)
        SampleSize = $n
    }

    # ----- Aggregate spell composition across the Top 10, strictly by guid -----
    # NOT merged by name across different guids - confirmed on real data that two guids
    # sharing a display name can mean genuinely different things, not just localization
    # noise. Lifebloom's two guids (33763, 33778) both display as "Lifebloom" in every
    # language, but empirically: 33763 is 100% tick=true, small amount (~310) - the HoT
    # component; 33778 is 100% tick=false, larger amount (~515) - the "bloom" burst heal
    # on expiry. Collapsing those into one "Lifebloom" row would hide a real mechanical
    # split. Regrowth/Rejuvenation's dual guids look different again on inspection (both
    # show MIXED tick/non-tick behavior, similar amounts, just very different cast
    # frequency - consistent with rank variance, not a distinct mechanic) - but rather
    # than assert per-spell what each guid "means" (which only covers spells someone has
    # actually checked, and risks being wrong), every guid stays its own row, always.
    # When two guids share a resolved display name, the guid is appended to disambiguate
    # rather than guessing at a semantic label.
    $spellAgg = @{}
    $spellTotal = 0.0
    foreach ($r in $top10) {
        foreach ($guid in $r.Abilities.Keys) {
            Add-GuidAggregate -Agg $spellAgg -Guid $guid -Name $r.Abilities[$guid].Name -Amount $r.Abilities[$guid].Total
            $spellTotal += $r.Abilities[$guid].Total
        }
    }
    $nameCounts = @{}
    foreach ($guid in $spellAgg.Keys) { 
        $n = $spellAgg[$guid].Name
        if (-not $nameCounts.ContainsKey($n)) { $nameCounts[$n] = 0 }
        $nameCounts[$n]++
    }
    foreach ($guid in $spellAgg.Keys) {
        $pct = if ($spellTotal -gt 0) { ($spellAgg[$guid].Total / $spellTotal) * 100 } else { 0 }
        if ($pct -ge 0.5) {
            $displayName = $spellAgg[$guid].Name
            if ($nameCounts[$displayName] -gt 1) { $displayName = "$displayName (guid $guid)" }
            $spellCompRows += [PSCustomObject]@{
                Boss = $bossName
                Spell = $displayName
                Top10Pct = [math]::Round($pct, 1)
            }
        }
    }

    # ----- Aggregate cooldowns/utility/consumables across the Top 10 -----
    $cdNames = @($cooldownGuids.Keys) + @("Mana Potion")
    $top10WithCooldowns = @($top10 | Where-Object { $_.Cooldowns -ne $null })
    $cdSampleUsed = $top10WithCooldowns.Count
    foreach ($cdName in $cdNames) {
        if ($cdSampleUsed -eq 0) { continue }
        $counts = $top10WithCooldowns | ForEach-Object { $_.Cooldowns[$cdName].Count }
        $selfCounts = $top10WithCooldowns | ForEach-Object { $_.Cooldowns[$cdName].SelfCount }
        $avgCasts = ($counts | Measure-Object -Average).Average
        $usedCount = @($counts | Where-Object { $_ -gt 0 }).Count
        $usedPct = ($usedCount / $cdSampleUsed) * 100
        $totalCasts = ($counts | Measure-Object -Sum).Sum
        $totalSelf = ($selfCounts | Measure-Object -Sum).Sum
        $selfPct = if ($totalCasts -gt 0) { ($totalSelf / $totalCasts) * 100 } else { $null }
        $cooldownRows += [PSCustomObject]@{
            Boss = $bossName
            Ability = $cdName
            Top10AvgCasts = [math]::Round($avgCasts, 1)
            Top10UsedPct = [math]::Round($usedPct, 0)
            Top10SelfPct = if ($null -ne $selfPct) { [math]::Round($selfPct, 0) } else { "" }
            SampleUsed = $cdSampleUsed
        }
    }

    # ----- Aggregate self-buff uptime across the Top 10 -----
    # Flask/food are booleans (active at pull start or not) - aggregated as "% of
    # Top 10 that had it active", the same style as Top10UsedPct for cooldowns.
    # Tree of Life is a real reconstructed uptime % - averaged directly.
    $top10WithBuffs = @($top10 | Where-Object { $_.BuffUptimes -ne $null })
    $buffSampleUsed = $top10WithBuffs.Count
    if ($buffSampleUsed -gt 0) {
        $flaskCount = @($top10WithBuffs | Where-Object { $_.BuffUptimes.FlaskActive }).Count
        $foodCount = @($top10WithBuffs | Where-Object { $_.BuffUptimes.FoodActive }).Count
        $treeAvg = ($top10WithBuffs | ForEach-Object { $_.BuffUptimes.TreeOfLifePct } | Measure-Object -Average).Average

        $buffRows += [PSCustomObject]@{
            Boss = $bossName
            Top10FlaskActivePct = [math]::Round(($flaskCount / $buffSampleUsed) * 100, 0)
            Top10FoodActivePct  = [math]::Round(($foodCount / $buffSampleUsed) * 100, 0)
            Top10TreeOfLifeAvgUptimePct = [math]::Round($treeAvg, 1)
            SampleUsed = $buffSampleUsed
        }
    } else {
        Write-Host "  NOTE: no buff data aggregated for $bossName (no players had a parseable consumables file)."
    }
}

$outSummary = Join-Path $classDateDir "benchmark_summary.csv"
$outSpells = Join-Path $classDateDir "benchmark_spell_composition.csv"
$outCooldowns = Join-Path $classDateDir "benchmark_cooldowns.csv"
$outBuffs = Join-Path $classDateDir "benchmark_buffs.csv"

# -Encoding UTF8 is required here - Export-Csv's default encoding on Windows PowerShell
# 5.1 is NOT UTF-8 (varies, but can't represent characters outside its codepage), and
# silently substitutes "?" for anything it can't encode. Confirmed on real output: a
# real run without this produced "??" as literal spell names for two Lurker rows where
# the only ability name observed in that Top 10 sample was non-English (Korean/Chinese -
# see the "different guids sharing a name" note above for why those rows exist standalone
# rather than merged with an English-named row). This -Encoding UTF8 does still add a BOM
# on Windows PowerShell 5.1 (unlike the no-BOM fix used for the *_events.json files) -
# acceptable here since CSVs are commonly BOM-prefixed for Excel compatibility anyway,
# and project-knowledge upload / any reasonable CSV reader tolerates it.
$summaryRows | Export-Csv -Path $outSummary -NoTypeInformation -Encoding UTF8
$spellCompRows | Sort-Object Boss, @{Expression="Top10Pct";Descending=$true} | Export-Csv -Path $outSpells -NoTypeInformation -Encoding UTF8
$cooldownRows | Sort-Object Boss, Ability | Export-Csv -Path $outCooldowns -NoTypeInformation -Encoding UTF8
$buffRows | Sort-Object Boss | Export-Csv -Path $outBuffs -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Done. Wrote:"
Write-Host "  $outSummary"
Write-Host "  $outSpells"
Write-Host "  $outCooldowns"
Write-Host "  $outBuffs"
Write-Host ""
Write-Host "Upload all four CSVs to project knowledge - small, text-based, no zip needed."
