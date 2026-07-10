# pull_top100_paladin.ps1
#
# Generated from pull_top100_TEMPLATE.ps1 - only the CLASS CONFIG block below was edited.
#
# Fully self-contained: pulls the Top 100 rankings (for Paladin/Holy) for every
# SSC/TK boss, then pulls the healing table for every one of those 1000 parses.
#
# Run this from your repo ROOT directory, which should contain:
#   - an apikey.txt file at the root, with just your WCL API key on a single line
#     (add apikey.txt to your .gitignore so it never gets committed)
#   - a data\Classes\ folder (created automatically if it doesn't exist yet)
#
# Creates:  data\Classes\Paladin\{date}\rankings_hydross.json  (etc.) - if not already present
# Writes:   data\Classes\Paladin\{date}\{BossName}\{reportID}_{fightID}_{playerName}.json
#
# Usage: powershell -ExecutionPolicy Bypass -File pull_top100_paladin.ps1

# ============ CLASS CONFIG - EDIT THESE FOUR LINES FOR A NEW CLASS ============
$className = "Paladin"     # Must match the WCL sourceclass name exactly (Druid, Shaman, Priest, Paladin, ...)
$classID = 6                # From GET /classes - e.g. Druid=2, Paladin=6, Priest=7, Shaman=9
$specID = 1                 # Healing spec ID within that class - Paladin Holy=1
$dateFolder = "2026-07-10"  # The date this rankings pull represents
# ================================================================================

$apiKeyFile = "apikey.txt"
$baseUrl = "https://fresh.warcraftlogs.com/v1"
$classesRoot = "data\Classes"
$classDateDir = Join-Path (Join-Path $classesRoot $className) $dateFolder

if (-not (Test-Path $apiKeyFile)) {
    Write-Host "ERROR: $apiKeyFile not found in the current directory."
    Write-Host "       Create a file named apikey.txt at your repo root containing just your WCL API key"
    Write-Host "       on one line, and add 'apikey.txt' to your .gitignore so it never gets committed."
    exit 1
}
$apiKey = (Get-Content $apiKeyFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Host "ERROR: $apiKeyFile is empty."
    exit 1
}

# SSC/TK boss name -> (rankings filename, encounter ID) - these are fixed, no need to edit
$bosses = [ordered]@{
    "Hydross"    = @{ file = "rankings_hydross.json";    encounterID = 100623 }
    "Lurker"     = @{ file = "rankings_lurker.json";     encounterID = 100624 }
    "Leotheras"  = @{ file = "rankings_leotheras.json";  encounterID = 100625 }
    "Karathress" = @{ file = "rankings_karathress.json"; encounterID = 100626 }
    "Morogrim"   = @{ file = "rankings_morogrim.json";   encounterID = 100627 }
    "Vashj"      = @{ file = "rankings_vashj.json";      encounterID = 100628 }
    "Alar"       = @{ file = "rankings_alar.json";       encounterID = 100730 }
    "VoidReaver" = @{ file = "rankings_voidreaver.json"; encounterID = 100731 }
    "Solarian"   = @{ file = "rankings_solarian.json";   encounterID = 100732 }
    "Kaelthas"   = @{ file = "rankings_kaelthas.json";   encounterID = 100733 }
}

New-Item -ItemType Directory -Force -Path $classDateDir | Out-Null

# ===== STEP 1: Pull Top 100 rankings per boss (skip any already present) =====
Write-Host "=== Step 1: Fetching Top 100 rankings for $className (spec $specID) ==="
Write-Host "Target directory: $classDateDir"
foreach ($boss in $bosses.Keys) {
    $rankingsFile = Join-Path $classDateDir $bosses[$boss].file
    $encounterID = $bosses[$boss].encounterID

    if (Test-Path $rankingsFile) {
        Write-Host "  $boss - already have $rankingsFile, skipping"
        continue
    }

    $rankingsUrl = "$baseUrl/rankings/encounter/$encounterID`?metric=hps&spec=$specID&class=$classID&api_key=$apiKey"
    try {
        Invoke-WebRequest -Uri $rankingsUrl -OutFile $rankingsFile -ErrorAction Stop
        $check = Get-Content $rankingsFile -Raw | ConvertFrom-Json
        if ($check.PSObject.Properties.Name -contains "error") {
            Write-Host "  $boss - API ERROR: $($check.error)"
        } else {
            Write-Host "  $boss - got $($check.rankings.Count) rankings"
        }
    } catch {
        Write-Host "  $boss - FAILED: $_"
    }
    Start-Sleep -Milliseconds 250
}
Write-Host ""

# ===== STEP 2: Pull healing table for every parse in every rankings file =====
Write-Host "=== Step 2: Fetching fight healing tables ==="

# Cache of reportID -> parsed fights JSON, so we never fetch the same report twice
$fightsCache = @{}

$totalDone = 0
$totalFailed = 0
$totalSkippedNoFight = 0

foreach ($boss in $bosses.Keys) {
    $rankingsFile = Join-Path $classDateDir $bosses[$boss].file

    if (-not (Test-Path $rankingsFile)) {
        Write-Host "SKIP: $rankingsFile not found (rankings pull may have failed above)."
        continue
    }

    $outDir = Join-Path $classDateDir $boss
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $rankingsData = Get-Content $rankingsFile -Raw | ConvertFrom-Json
    if ($rankingsData.PSObject.Properties.Name -contains "error") {
        Write-Host "SKIP: $boss rankings file contains an API error, not a rankings list."
        continue
    }
    $rankings = $rankingsData.rankings

    Write-Host "=== $boss ($($rankings.Count) parses) ==="

    $i = 0
    foreach ($r in $rankings) {
        $i++
        $reportID = $r.reportID
        $fightID = $r.fightID
        $playerName = $r.name

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
        $outFile = Join-Path $outDir "$($reportID)_$($fightID)_$safeName.json"

        if (Test-Path $outFile) {
            $totalDone++
            continue
        }

        $tableUrl = "$baseUrl/report/tables/healing/$reportID`?start=$start&end=$end&sourceclass=$className&api_key=$apiKey"

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
