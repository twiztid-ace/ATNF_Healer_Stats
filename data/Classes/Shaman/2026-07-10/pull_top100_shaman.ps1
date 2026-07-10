# pull_top100_shaman.ps1
# Pulls healing tables for all Top 100 Restoration Shaman parses per SSC/TK boss.
# Organizes output into Shaman\2026-07-10\{BossName}\{reportID}_{fightID}_{playerName}.json
#
# Requires: rankings_*.json files (from the earlier rankings pulls) in the same folder as this script.
# Usage: powershell -ExecutionPolicy Bypass -File pull_top100_shaman.ps1

$apiKey = "b24cfa190380faafd0708a2c0588207e"
$baseUrl = "https://fresh.warcraftlogs.com/v1"
$dateFolder = "2026-07-10"

$bosses = [ordered]@{
    "Hydross"    = "rankings_hydross.json"
    "Lurker"     = "rankings_lurker.json"
    "Leotheras"  = "rankings_leotheras.json"
    "Karathress" = "rankings_karathress.json"
    "Morogrim"   = "rankings_morogrim.json"
    "Vashj"      = "rankings_vashj.json"
    "Alar"       = "rankings_alar.json"
    "VoidReaver" = "rankings_voidreaver.json"
    "Solarian"   = "rankings_solarian.json"
    "Kaelthas"   = "rankings_kaelthas.json"
}

# Cache of reportID -> parsed fights JSON, so we never fetch the same report twice
$fightsCache = @{}

$totalRankings = 0
$totalDone = 0
$totalFailed = 0
$totalSkippedNoFight = 0

foreach ($boss in $bosses.Keys) { $totalRankings += 100 }
Write-Host "Starting pull: up to $totalRankings fights across $($bosses.Count) bosses (report calls are cached/deduped)."
Write-Host ""

foreach ($boss in $bosses.Keys) {
    $rankingsFile = $bosses[$boss]

    if (-not (Test-Path $rankingsFile)) {
        Write-Host "SKIP: $rankingsFile not found in current directory."
        continue
    }

    $outDir = "Shaman\$dateFolder\$boss"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $rankingsData = Get-Content $rankingsFile -Raw | ConvertFrom-Json
    $rankings = $rankingsData.rankings

    Write-Host "=== $boss ($($rankings.Count) parses) ==="

    $i = 0
    foreach ($r in $rankings) {
        $i++
        $reportID = $r.reportID
        $fightID = $r.fightID
        $playerName = $r.name

        # Fetch (and cache) this report's fight list if we haven't already
        if (-not $fightsCache.ContainsKey($reportID)) {
            $fightsUrl = "$baseUrl/report/fights/$reportID`?api_key=$apiKey"
            try {
                $fightsData = Invoke-RestMethod -Uri $fightsUrl -ErrorAction Stop
                $fightsCache[$reportID] = $fightsData
            } catch {
                Write-Host "  [$i/100] FAILED fetching report $reportID (fights list) - $_"
                $fightsCache[$reportID] = $null
                $totalFailed++
                continue
            }
            Start-Sleep -Milliseconds 250
        }

        $fightsData = $fightsCache[$reportID]
        if ($null -eq $fightsData) {
            $totalFailed++
            continue
        }

        $fight = $fightsData.fights | Where-Object { $_.id -eq $fightID }
        if (-not $fight) {
            Write-Host "  [$i/100] SKIP: fight $fightID not found in report $reportID"
            $totalSkippedNoFight++
            continue
        }

        $start = $fight.start_time
        $end = $fight.end_time

        $safeName = ($playerName -replace '[\\/:*?"<>|]', '_')
        $outFile = "$outDir\$($reportID)_$($fightID)_$safeName.json"

        if (Test-Path $outFile) {
            # Already pulled this one (e.g. re-running after an interruption) - skip
            $totalDone++
            continue
        }

        $tableUrl = "$baseUrl/report/tables/healing/$reportID`?start=$start&end=$end&sourceclass=Shaman&api_key=$apiKey"

        try {
            Invoke-WebRequest -Uri $tableUrl -OutFile $outFile -ErrorAction Stop
            $totalDone++
        } catch {
            Write-Host "  [$i/100] FAILED table fetch for $reportID fight $fightID ($playerName) - $_"
            $totalFailed++
        }

        Start-Sleep -Milliseconds 250
    }

    Write-Host ""
}

Write-Host "=================================="
Write-Host "Done."
Write-Host "  Succeeded:        $totalDone"
Write-Host "  Failed:           $totalFailed"
Write-Host "  Skipped (no fight match): $totalSkippedNoFight"
Write-Host "  Unique reports fetched:   $($fightsCache.Count)"
