# One-off analysis script (not part of the recurring pipeline): computes every raw
# number needed to fill boss_page_template_druid.html for Danceswtrees's remaining 8
# boss kills from the 2026-07-07 raid night, mirroring summarize_class_benchmarks.ps1's
# per-record logic (guid-based spell aggregation, cooldown self/target tracking, HPM,
# active time) plus real percentile lookup and benchmark CSV cross-reference. Output is
# one big JSON dump, read by hand afterward to write each page's real prose - the
# coverage-note interpretation itself isn't automated, only the raw numbers are.
$ErrorActionPreference = "Stop"
Set-Location "C:\Users\raymo\wc_logs"

$charDir = "data\Characters\Danceswtrees\2026-07-07"
$benchDir = "data\Classes\Druid\active"
$reportID = "XJp8vAxzM4KtHYyb"

$bosses = @(
    @{ Slug = "lurker";     Label = "fight14_lurker";     Display = "The Lurker Below";           FightID = 14 },
    @{ Slug = "karathress"; Label = "fight33_karathress";  Display = "Fathom-Lord Karathress";     FightID = 33 },
    @{ Slug = "morogrim";   Label = "fight41_morogrim";    Display = "Morogrim Tidewalker";        FightID = 41 },
    @{ Slug = "vashj";      Label = "fight46_vashj";       Display = "Lady Vashj";                 FightID = 46 },
    @{ Slug = "alar";       Label = "fight55_alar";        Display = "Al'ar";                      FightID = 55 },
    @{ Slug = "voidreaver"; Label = "fight65_voidreaver";  Display = "Void Reaver";                FightID = 65 },
    @{ Slug = "solarian";   Label = "fight73_solarian";    Display = "High Astromancer Solarian";  FightID = 73 },
    @{ Slug = "kaelthas";   Label = "fight81_kaelthas";    Display = "Kael'thas Sunstrider";       FightID = 81 }
)

$cooldownGuids = [ordered]@{
    "Innervate"          = @(29166)
    "Nature's Swiftness" = @(17116)
    "Swiftmend"          = @(18562)
    "Rebirth"            = @(26994)
    "Dark Rune"          = @(27869)
}
$manaPotionName = "Restore Mana"

$fightsData = Get-Content (Join-Path $charDir "fights_$reportID.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$allParses = Get-Content (Join-Path $charDir "danceswtrees_all_parses.json") -Raw -Encoding UTF8 | ConvertFrom-Json

$bmSummary = Import-Csv (Join-Path $benchDir "benchmark_summary.csv")
$bmSpells = Import-Csv (Join-Path $benchDir "benchmark_spell_composition.csv")
$bmCooldowns = Import-Csv (Join-Path $benchDir "benchmark_cooldowns.csv")
$bmBuffs = Import-Csv (Join-Path $benchDir "benchmark_buffs.csv")

$results = @{}

foreach ($b in $bosses) {
    $label = $b.Label
    $fight = $fightsData.fights | Where-Object { $_.id -eq $b.FightID } | Select-Object -First 1
    $start = $fight.start_time
    $end = $fight.end_time
    $duration = $end - $start

    $healingData = Get-Content (Join-Path $charDir "$($label)_healing_events.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $castsData = Get-Content (Join-Path $charDir "$($label)_casts_events.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $consumablesData = Get-Content (Join-Path $charDir "$($label)_consumables.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $activeTimeData = Get-Content (Join-Path $charDir "$($label)_activetime.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $deathsData = Get-Content (Join-Path $charDir "$($label)_deaths.json") -Raw -Encoding UTF8 | ConvertFrom-Json

    $total = $healingData.totalAmount
    $overheal = $healingData.totalOverheal
    $raw = $total + $overheal
    $overhealPct = if ($raw -gt 0) { [math]::Round(($overheal / $raw) * 100, 1) } else { 0 }
    $hps = if ($duration -gt 0) { [math]::Round($total / ($duration / 1000), 0) } else { 0 }

    # ----- Spell composition, by guid -----
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
        $spellRows += [PSCustomObject]@{ Guid = $guid; Name = $abilities[$guid].Name; Total = [math]::Round($abilities[$guid].Total,0); Pct = $pct }
    }
    $spellRows = $spellRows | Sort-Object -Property Total -Descending

    # ----- Target distribution -----
    $targets = @{}
    foreach ($ev in $healingData.events) {
        if ($ev.targetName -and $ev.amount) {
            if (-not $targets.ContainsKey($ev.targetName)) { $targets[$ev.targetName] = 0.0 }
            $targets[$ev.targetName] += $ev.amount
        }
    }
    $sortedTargets = $targets.GetEnumerator() | Sort-Object -Property Value -Descending
    $top5 = $sortedTargets | Select-Object -First 5
    $top5Sum = ($top5 | Measure-Object -Property Value -Sum).Sum
    if ($null -eq $top5Sum) { $top5Sum = 0 }
    $coveragePct = if ($total -gt 0) { [math]::Round(($top5Sum / $total) * 100, 1) } else { 0 }
    $top1Pct = if ($sortedTargets.Count -gt 0 -and $total -gt 0) { [math]::Round(($sortedTargets[0].Value / $total) * 100, 1) } else { 0 }
    $distinctTargetCount = $sortedTargets.Count
    $targetRows = @()
    $topAmount = if ($top5.Count -gt 0) { $top5[0].Value } else { 1 }
    foreach ($t in $top5) {
        $pct = if ($total -gt 0) { [math]::Round(($t.Value / $total) * 100, 1) } else { 0 }
        $barWidth = if ($topAmount -gt 0) { [math]::Round(($t.Value / $topAmount) * 100, 1) } else { 0 }
        $targetRows += [PSCustomObject]@{ Name = $t.Name; Pct = $pct; BarWidth = $barWidth; Amount = [math]::Round($t.Value,0) }
    }

    # ----- Cooldowns/utility, excluding begincast -----
    $cooldownRows = @{}
    foreach ($cdName in $cooldownGuids.Keys) {
        $guidList = $cooldownGuids[$cdName]
        $matched = @($castsData.events | Where-Object { ($guidList -contains $_.ability.guid) -and ($_.type -ne "begincast") })
        $targetList = @()
        foreach ($m in $matched) {
            $isSelf = ($m.sourceName -eq $m.targetName) -or [string]::IsNullOrEmpty($m.targetName)
            $targetList += [PSCustomObject]@{ Target = $(if ($isSelf) { "self" } else { $m.targetName }); Timestamp = $m.timestamp }
        }
        $selfCount = @($targetList | Where-Object { $_.Target -eq "self" }).Count
        $cooldownRows[$cdName] = [PSCustomObject]@{ Count = $matched.Count; SelfCount = $selfCount; Targets = $targetList }
    }
    $manaMatched = @($castsData.events | Where-Object { $_.ability.name -eq $manaPotionName })
    $cooldownRows["Mana Potion"] = [PSCustomObject]@{ Count = $manaMatched.Count; SelfCount = $manaMatched.Count; Targets = @() }

    # Tranquility (guid unobserved - always empty list, included for the conditional-display check)
    $cooldownRows["Tranquility"] = [PSCustomObject]@{ Count = 0; SelfCount = 0; Targets = @() }

    # ----- HPM -----
    $manaSpent = 0.0
    foreach ($ev in $castsData.events) {
        if ($ev.classResources -and $ev.classResources.Count -gt 0) {
            $manaSpent += $ev.classResources[0].max
        }
    }
    $hpm = if ($manaSpent -gt 0) { [math]::Round($total / $manaSpent, 2) } else { $null }

    # ----- Active time -----
    $activeTimePct = $activeTimeData.activeTimePct

    # ----- Deaths -----
    $deathCount = @($deathsData.entries).Count
    $deathList = @()
    foreach ($d in $deathsData.entries) {
        $deathList += [PSCustomObject]@{ Name = $d.name; Timestamp = $d.timestamp }
    }

    # ----- Percentile/rank, matched by exact reportID+fightID -----
    $parseMatch = $allParses | Where-Object { $_.reportID -eq $reportID -and $_.fightID -eq $b.FightID } | Select-Object -First 1
    $percentile = if ($parseMatch) { [math]::Round($parseMatch.percentile, 0) } else { $null }
    $rank = if ($parseMatch) { $parseMatch.rank } else { $null }
    $outOf = if ($parseMatch) { $parseMatch.outOf } else { $null }

    # ----- Benchmark comparisons -----
    $bmRow = $bmSummary | Where-Object { $_.Boss -eq $b.Display } | Select-Object -First 1
    $bmSpellRows = $bmSpells | Where-Object { $_.Boss -eq $b.Display }
    $bmCdRows = $bmCooldowns | Where-Object { $_.Boss -eq $b.Display }
    $bmBuffRow = $bmBuffs | Where-Object { $_.Boss -eq $b.Display } | Select-Object -First 1

    $results[$b.Slug] = [PSCustomObject]@{
        Display = $b.Display
        FightID = $b.FightID
        Duration = $duration
        Total = [math]::Round($total,0)
        Overheal = [math]::Round($overheal,0)
        OverhealPct = $overhealPct
        HPS = $hps
        SpellRows = $spellRows
        TargetRows = $targetRows
        CoveragePct = $coveragePct
        Top1Pct = $top1Pct
        DistinctTargetCount = $distinctTargetCount
        CooldownRows = $cooldownRows
        ManaSpent = [math]::Round($manaSpent,0)
        HPM = $hpm
        ActiveTimePct = $activeTimePct
        DeathCount = $deathCount
        DeathList = $deathList
        Percentile = $percentile
        Rank = $rank
        OutOf = $outOf
        FlaskActive = $consumablesData.flaskActive
        FlaskName = $consumablesData.flaskName
        FoodActive = $consumablesData.foodActive
        FoodName = $consumablesData.foodName
        TreeOfLifePct = $consumablesData.treeOfLifeUptimePct
        BM = $bmRow
        BMSpells = $bmSpellRows
        BMCooldowns = $bmCdRows
        BMBuffs = $bmBuffRow
    }
}

$outPath = "scripts\_danceswtrees_remaining_bosses_data.json"
$results | ConvertTo-Json -Depth 10 | Out-File -FilePath $outPath -Encoding utf8
Write-Host "Wrote $outPath"
