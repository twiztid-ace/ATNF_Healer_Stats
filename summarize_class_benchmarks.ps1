# summarize_class_benchmarks.ps1
#
# Reads the raw Top 100 data pulled by pull_top100_TEMPLATE.ps1 (rankings + 1000 fight
# files per class) and computes the derived benchmark stats our analysis actually uses:
# HPS percentiles, overheal percentiles, Top 10 spell composition, and Top 10 target
# concentration - PER BOSS. Outputs one compact CSV per class, small enough to upload
# to Claude Project knowledge (project knowledge does not support .zip files, and the
# raw 1000-file dataset is too large/granular to be useful there anyway).
#
# Run this from your repo ROOT directory (same place you ran the pull script from).
#
# Usage: powershell -ExecutionPolicy Bypass -File summarize_class_benchmarks.ps1 -ClassName Druid -DateFolder 2026-07-10

param(
    [Parameter(Mandatory=$true)][string]$ClassName,
    [Parameter(Mandatory=$true)][string]$DateFolder
)

# Decode #Uxxxx hex-escaped unicode characters that appear in filenames
function Decode-UnicodeFilename {
    param([string]$Name)
    return [regex]::Replace($Name, '#U([0-9a-fA-F]{4})', {
        param($m) [char]([Convert]::ToInt32($m.Groups[1].Value, 16))
    })
}

$classesRoot = "data\Classes"
$classDateDir = Join-Path (Join-Path $classesRoot $ClassName) $DateFolder

if (-not (Test-Path $classDateDir)) {
    Write-Host "ERROR: $classDateDir not found."
    exit 1
}

$bosses = [ordered]@{
    "Hydross"    = "Hydross the Unstable"
    "Lurker"     = "The Lurker Below"
    "Leotheras"  = "Leotheras the Blind"
    "Karathress" = "Fathom-Lord Karathress"
    "Morogrim"   = "Morogrim Tidewalker"
    "Vashj"      = "Lady Vashj"
    "Alar"       = "Al'ar"
    "VoidReaver" = "Void Reaver"
    "Solarian"   = "High Astromancer Solarian"
    "Kaelthas"   = "Kael'thas Sunstrider"
}

$summaryRows = @()
$spellCompRows = @()

foreach ($bossFolder in $bosses.Keys) {
    $bossName = $bosses[$bossFolder]
    $bossDir = Join-Path $classDateDir $bossFolder

    if (-not (Test-Path $bossDir)) {
        Write-Host "SKIP: $bossDir not found."
        continue
    }

    $files = Get-ChildItem -Path $bossDir -Filter "*.json"
    Write-Host "Processing $bossName ($($files.Count) files)..."

    $records = @()
    foreach ($file in $files) {
        # filename format: {reportID}_{fightID}_{playerName}.json
        $parts = $file.BaseName -split '_', 3
        if ($parts.Count -ne 3) { continue }
        $playerNameRaw = $parts[2]
        $playerName = Decode-UnicodeFilename $playerNameRaw

        try {
            $data = Get-Content $file.FullName -Raw | ConvertFrom-Json
        } catch {
            continue
        }
        if (-not $data.entries) { continue }

        $match = $data.entries | Where-Object { $_.name -eq $playerName } | Select-Object -First 1
        if (-not $match) { continue }

        $totalTime = $data.totalTime
        $total = $match.total
        $overheal = $match.overheal
        $raw = $total + $overheal
        $overhealPct = if ($raw -gt 0) { ($overheal / $raw) * 100 } else { 0 }
        $hps = if ($totalTime -gt 0) { $total / ($totalTime / 1000) } else { 0 }

        $targets = $match.targets
        $targetSum = ($targets | Measure-Object -Property total -Sum).Sum
        $coveragePct = if ($total -gt 0) { ($targetSum / $total) * 100 } else { 0 }
        $top1Pct = if ($targets -and $targets.Count -gt 0 -and $total -gt 0) { ($targets[0].total / $total) * 100 } else { 0 }

        $abilities = @{}
        foreach ($a in $match.abilities) {
            if (-not $abilities.ContainsKey($a.name)) { $abilities[$a.name] = 0 }
            $abilities[$a.name] += $a.total
        }

        $records += [PSCustomObject]@{
            HPS = $hps
            OverhealPct = $overhealPct
            CoveragePct = $coveragePct
            Top1Pct = $top1Pct
            Abilities = $abilities
            AbilityTotal = ($abilities.Values | Measure-Object -Sum).Sum
        }
    }

    if ($records.Count -eq 0) { continue }

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

    # Aggregate spell composition across the Top 10 for this boss
    $spellAgg = @{}
    $spellTotal = 0
    foreach ($r in $top10) {
        foreach ($key in $r.Abilities.Keys) {
            if (-not $spellAgg.ContainsKey($key)) { $spellAgg[$key] = 0 }
            $spellAgg[$key] += $r.Abilities[$key]
            $spellTotal += $r.Abilities[$key]
        }
    }
    foreach ($spell in $spellAgg.Keys) {
        $pct = if ($spellTotal -gt 0) { ($spellAgg[$spell] / $spellTotal) * 100 } else { 0 }
        if ($pct -ge 0.5) {
            $spellCompRows += [PSCustomObject]@{
                Boss = $bossName
                Spell = $spell
                Top10Pct = [math]::Round($pct, 1)
            }
        }
    }
}

$outSummary = Join-Path $classDateDir "benchmark_summary.csv"
$outSpells = Join-Path $classDateDir "benchmark_spell_composition.csv"

$summaryRows | Export-Csv -Path $outSummary -NoTypeInformation
$spellCompRows | Sort-Object Boss, @{Expression="Top10Pct";Descending=$true} | Export-Csv -Path $outSpells -NoTypeInformation

Write-Host ""
Write-Host "Done. Wrote:"
Write-Host "  $outSummary"
Write-Host "  $outSpells"
Write-Host ""
Write-Host "Upload both CSVs to project knowledge - small, text-based, no zip needed."
