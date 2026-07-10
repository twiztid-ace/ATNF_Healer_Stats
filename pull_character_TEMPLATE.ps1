# pull_character_TEMPLATE.ps1
#
# Pulls one character's full raid-night data set for the ATNF Healer Analysis pipeline,
# steps 1-4 of WORKFLOW.md, fully automated - no manual JSON inspection or filled-in
# placeholders required.
#
# Given a report code (or full report URL) and a character name, this:
#   1. Fetches (or reuses a cached copy of) the report's fight list
#   2. Reads the raid date straight from the report title
#   3. Looks up the character's class/server/region from the report's own friendlies[]
#      list (no need to already know these - only pass -Server/-Region/-Class to
#      override, e.g. if the character isn't in this particular report for some reason)
#   4. Pulls the healing table for every boss kill (boss != 0 && kill == true)
#   5. Pulls the character's full parse history (for real per-fight WCL percentiles)
#
# Run this from your repo ROOT directory, which should contain:
#   - an apikey.txt file at the root, with just your WCL API key on a single line
#     (add apikey.txt to your .gitignore so it never gets committed)
#   - a data\Characters\ folder (created automatically if it doesn't exist yet)
#
# Result: data\Characters\{CharacterName}\{date}\
#           fights_{reportCode}.json
#           fight{fightID}_{bossSlug}.json     <- one per boss kill
#           {charactername}_all_parses.json
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File pull_character_TEMPLATE.ps1 -ReportCode "XJp8vAxzM4KtHYyb" -CharacterName "Crowns"
#
#   # or paste the full report URL directly:
#   powershell -ExecutionPolicy Bypass -File pull_character_TEMPLATE.ps1 -ReportCode "https://fresh.warcraftlogs.com/reports/XJp8vAxzM4KtHYyb" -CharacterName "Crowns"
#
#   # overrides, only needed if the character isn't found in this report's friendlies[]:
#   powershell -ExecutionPolicy Bypass -File pull_character_TEMPLATE.ps1 -ReportCode "XJp8vAxzM4KtHYyb" -CharacterName "Crowns" -Server "Dreamscythe" -Region "US" -Class "Paladin"

param(
    [Parameter(Mandatory=$true)][string]$ReportCode,
    [Parameter(Mandatory=$true)][string]$CharacterName,
    [string]$Server,        # optional override - only used if character not found in friendlies[]
    [string]$Region,        # optional override - only used if character not found in friendlies[]
    [string]$Class,         # optional override - only used if character not found in friendlies[]
    [string]$DateOverride   # optional override - only used if the date can't be parsed from the report title
)

$ErrorActionPreference = "Stop"
$apiKeyFile = "apikey.txt"
$baseUrl = "https://fresh.warcraftlogs.com/v1"
$charactersRoot = "data\Characters"

# ===== Resolve report code from a bare code or a full report URL =====
if ($ReportCode -match "warcraftlogs\.com/reports/([A-Za-z0-9]+)") {
    $ReportCode = $Matches[1]
}

# ===== API key =====
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

# ===== SSC/TK encounter ID -> boss-file slug (fixed reference, matches pull_top100_TEMPLATE.ps1) =====
$bossSlugs = @{
    100623 = "hydross"
    100624 = "lurker"
    100625 = "leotheras"
    100626 = "karathress"
    100627 = "morogrim"
    100628 = "vashj"
    100730 = "alar"
    100731 = "voidreaver"
    100732 = "solarian"
    100733 = "kaelthas"
}

function Get-BossSlug($bossID, $bossName) {
    if ($bossSlugs.ContainsKey($bossID)) {
        return $bossSlugs[$bossID]
    }
    # Defensive fallback for anything outside the known SSC/TK set:
    # lowercase the encounter name and strip everything but letters/digits.
    return ($bossName.ToLower() -replace '[^a-z0-9]', '')
}

# ===== STEP 1: Get the fight list - reuse a cached copy from ANY character's folder if one exists =====
Write-Host "=== Step 1: Fight list for report $ReportCode ==="

$cachedFightsFile = $null
if (Test-Path $charactersRoot) {
    $cachedFightsFile = Get-ChildItem -Path $charactersRoot -Recurse -Filter "fights_$ReportCode.json" -ErrorAction SilentlyContinue | Select-Object -First 1
}

if ($cachedFightsFile) {
    Write-Host "  Found cached fights file: $($cachedFightsFile.FullName) - reusing, not re-fetching."
    $fightsRaw = Get-Content $cachedFightsFile.FullName -Raw
} else {
    Write-Host "  Not cached anywhere yet - fetching from the API..."
    $fightsUrl = "$baseUrl/report/fights/$ReportCode`?api_key=$apiKey"
    $tempFightsFile = Join-Path $env:TEMP "fights_$ReportCode`_$([guid]::NewGuid()).json"
    try {
        Invoke-WebRequest -Uri $fightsUrl -OutFile $tempFightsFile
        $fightsRaw = Get-Content $tempFightsFile -Raw
    } catch {
        Write-Host "ERROR: failed to fetch fight list for $ReportCode - $_"
        exit 1
    }
}

$fightsData = $fightsRaw | ConvertFrom-Json
if ($fightsData.PSObject.Properties.Name -contains "error") {
    Write-Host "ERROR: API returned an error for report $ReportCode`: $($fightsData.error)"
    Write-Host "       (This usually means the report is private - the owner needs to make it public.)"
    exit 1
}

# ===== STEP 2: Determine the raid date from the report title =====
# Titles look like "SSC / TK 07.07.2026" -> MM.DD.YYYY
$raidDate = $null
if ($DateOverride) {
    $raidDate = $DateOverride
} elseif ($fightsData.title -match "(\d{1,2})\.(\d{1,2})\.(\d{4})") {
    $month = $Matches[1].PadLeft(2, '0')
    $day = $Matches[2].PadLeft(2, '0')
    $year = $Matches[3]
    $raidDate = "$year-$month-$day"
} elseif ($fightsData.start) {
    # Fallback: derive from the report's top-level start epoch (ms)
    $raidDate = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$fightsData.start).UtcDateTime.ToString("yyyy-MM-dd")
    Write-Host "  WARNING: couldn't parse a date out of the report title ('$($fightsData.title)') - derived $raidDate from the report's start timestamp instead. Pass -DateOverride if this is wrong."
} else {
    Write-Host "ERROR: could not determine the raid date from the report title or start time. Pass -DateOverride 'YYYY-MM-DD' explicitly."
    exit 1
}
Write-Host "  Raid date: $raidDate"

# ===== STEP 3: Resolve class/server/region from friendlies[] =====
$friendly = $fightsData.friendlies | Where-Object { $_.name -eq $CharacterName } | Select-Object -First 1

if ($friendly) {
    if (-not $Class)  { $Class  = $friendly.type }
    if (-not $Server) { $Server = $friendly.server }
    if (-not $Region) { $Region = $friendly.region }
    Write-Host "  Found '$CharacterName' in friendlies[]: $Class, $Server-$Region"
} else {
    if (-not $Class -or -not $Server -or -not $Region) {
        Write-Host "ERROR: '$CharacterName' was not found in this report's friendlies[] list."
        Write-Host "       Re-run with -Class, -Server, and -Region supplied explicitly if this character"
        Write-Host "       genuinely isn't in this report (e.g. resolving them from a different raid)."
        exit 1
    }
    Write-Host "  '$CharacterName' not in friendlies[] - using supplied overrides: $Class, $Server-$Region"
}

# ===== Set up output folder =====
$outDir = Join-Path (Join-Path $charactersRoot $CharacterName) $raidDate
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Write-Host "  Output folder: $outDir"
Write-Host ""

# Write/copy the fights file into this character's folder too (per WORKFLOW.md convention -
# every character folder gets its own copy, even though the underlying data is shared/reused)
$fightsOutFile = Join-Path $outDir "fights_$ReportCode.json"
if (-not (Test-Path $fightsOutFile)) {
    Set-Content -Path $fightsOutFile -Value $fightsRaw -NoNewline
}

# ===== STEP 4: Pull the healing table for every boss kill =====
Write-Host "=== Step 2: Healing tables per boss kill ==="
$bossFights = $fightsData.fights | Where-Object { $_.boss -ne 0 -and $_.kill -eq $true }

if (-not $bossFights -or $bossFights.Count -eq 0) {
    Write-Host "  No boss kills (boss != 0 && kill == true) found in this report - nothing to pull here."
} else {
    Write-Host "  $($bossFights.Count) boss kill(s) found."
}

$totalDone = 0
$totalFailed = 0

foreach ($fight in $bossFights) {
    $fightIDPadded = "{0:D2}" -f $fight.id
    $slug = Get-BossSlug $fight.boss $fight.name
    $outFile = Join-Path $outDir "fight$($fightIDPadded)_$($slug).json"

    if (Test-Path $outFile) {
        Write-Host "  fight$($fightIDPadded)_$($slug).json - already have it, skipping"
        $totalDone++
        continue
    }

    $tableUrl = "$baseUrl/report/tables/healing/$ReportCode`?start=$($fight.start_time)&end=$($fight.end_time)&sourceclass=$Class&api_key=$apiKey"
    try {
        Invoke-WebRequest -Uri $tableUrl -OutFile $outFile
        Write-Host "  fight$($fightIDPadded)_$($slug).json - OK ($($fight.name))"
        $totalDone++
    } catch {
        Write-Host "  fight$($fightIDPadded)_$($slug).json - FAILED: $_"
        $totalFailed++
    }
    Start-Sleep -Milliseconds 250
}
Write-Host ""

# ===== STEP 5: Pull the character's full parse history (real per-fight percentiles) =====
Write-Host "=== Step 3: Full parse history for $CharacterName ==="
$safeCharName = ($CharacterName.ToLower() -replace '[\\/:*?"<>|]', '_')
$parsesOutFile = Join-Path $outDir "$($safeCharName)_all_parses.json"

if (Test-Path $parsesOutFile) {
    Write-Host "  $($safeCharName)_all_parses.json - already have it, skipping"
} else {
    $parsesUrl = "$baseUrl/parses/character/$CharacterName/$Server/$Region`?zone=1056&metric=hps&api_key=$apiKey"
    try {
        Invoke-WebRequest -Uri $parsesUrl -OutFile $parsesOutFile
        Write-Host "  $($safeCharName)_all_parses.json - OK"
    } catch {
        Write-Host "  $($safeCharName)_all_parses.json - FAILED: $_"
        $totalFailed++
    }
}

Write-Host ""
Write-Host "=================================="
Write-Host "Done. Output: $outDir"
Write-Host "  Boss healing tables succeeded: $totalDone"
Write-Host "  Failed:                        $totalFailed"
