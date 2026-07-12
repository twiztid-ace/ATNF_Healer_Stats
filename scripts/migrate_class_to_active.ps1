# migrate_class_to_active.ps1
#
# One-time migration: converts a class's old date-stamped Top 100 pull folder
# (data\Classes\{Class}\{DateFolder}\) into the new active\/archived\ + manifest.json
# layout (see CLAUDE.md "active/archived data model" and the conversation that designed
# it - manifest tracks per-boss lastPulledDate/rankingsSnapshotDate and per-parse
# active/archived status, replacing the old approach of a fresh dated folder per pull).
#
# Everything under {DateFolder}\ becomes the FIRST active\ snapshot - there is no prior
# state to diff against yet, so every parse currently on disk is recorded as "active",
# and both lastPulledDate and rankingsSnapshotDate are set to the given date for every
# boss that has data. Boss folders that don't exist yet (not pulled) still get an entry
# in the manifest (encounterID only, no dates, empty parses) so pull_top100_druid.ps1
# can treat "no lastPulledDate" as "first pull, fetch everything."
#
# Does NOT touch git - purely a working-tree reorganization. Review/stage/commit via
# SourceTree afterward, same as any other change in this repo.
#
# Usage: powershell -ExecutionPolicy Bypass -File scripts\migrate_class_to_active.ps1 -ClassName Druid -DateFolder 2026-07-10

param(
    [Parameter(Mandatory=$true)][string]$ClassName,
    [Parameter(Mandatory=$true)][string]$DateFolder
)

# Only Druid is wired up as of this migration - extend this table before running against
# another class (matches the classID/specID values already hardcoded per-class across
# the pull_top100_*.ps1 scripts and WORKFLOW.md's class/spec reference table).
$classInfo = @{
    "Druid" = @{ classID = 2; specID = 4 }
}
if (-not $classInfo.ContainsKey($ClassName)) {
    Write-Host "ERROR: no classID/specID entry for '$ClassName' in this script's `$classInfo table - add one first."
    exit 1
}

# boss folder name -> (SSC/TK encounter ID, rankings filename) - matches
# pull_top100_druid.ps1 and WORKFLOW.md's SSC/TK reference ID table exactly.
$bosses = [ordered]@{
    "Hydross"    = @{ encounterID = 100623; rankingsFile = "rankings_hydross.json" }
    "Lurker"     = @{ encounterID = 100624; rankingsFile = "rankings_lurker.json" }
    "Leotheras"  = @{ encounterID = 100625; rankingsFile = "rankings_leotheras.json" }
    "Karathress" = @{ encounterID = 100626; rankingsFile = "rankings_karathress.json" }
    "Morogrim"   = @{ encounterID = 100627; rankingsFile = "rankings_morogrim.json" }
    "Vashj"      = @{ encounterID = 100628; rankingsFile = "rankings_vashj.json" }
    "Alar"       = @{ encounterID = 100730; rankingsFile = "rankings_alar.json" }
    "VoidReaver" = @{ encounterID = 100731; rankingsFile = "rankings_voidreaver.json" }
    "Solarian"   = @{ encounterID = 100732; rankingsFile = "rankings_solarian.json" }
    "Kaelthas"   = @{ encounterID = 100733; rankingsFile = "rankings_kaelthas.json" }
}

$classesRoot = "data\Classes"
$classDir = Join-Path $classesRoot $ClassName
$oldDateDir = Join-Path $classDir $DateFolder
$activeDir = Join-Path $classDir "active"
$archivedDir = Join-Path $classDir "archived"
$manifestPath = Join-Path $classDir "manifest.json"

if (-not (Test-Path $oldDateDir)) {
    Write-Host "ERROR: $oldDateDir not found."
    exit 1
}
if (Test-Path $activeDir) {
    Write-Host "ERROR: $activeDir already exists - this class looks already migrated. Aborting to avoid clobbering it."
    exit 1
}
if (Test-Path $manifestPath) {
    Write-Host "ERROR: $manifestPath already exists. Aborting to avoid clobbering it."
    exit 1
}

Write-Host "=== Migrating $ClassName ($DateFolder) to active/archived layout ==="

New-Item -ItemType Directory -Force -Path $activeDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $archivedDir "rankings_history") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $archivedDir "benchmark_history") | Out-Null

# Move everything currently in the date folder into active\ as whole directories/files -
# not file-by-file - so git's rename detection has the best chance of recognizing these
# as moves (not delete+add) once the person stages/commits via SourceTree.
Get-ChildItem -Path $oldDateDir | ForEach-Object {
    Write-Host "  moving $($_.Name) -> active\"
    Move-Item -Path $_.FullName -Destination $activeDir
}
Remove-Item -Path $oldDateDir -Force
Write-Host "  removed now-empty $oldDateDir"
Write-Host ""

# ===== Build manifest.json from what's now actually in active\ =====
Write-Host "=== Building manifest.json ==="

$manifest = [ordered]@{
    schemaVersion          = 2
    className               = $ClassName
    classID                 = $classInfo[$ClassName].classID
    specID                  = $classInfo[$ClassName].specID
    benchmarkGeneratedDate  = $null
    bosses                  = [ordered]@{}
}

foreach ($bossName in $bosses.Keys) {
    $info = $bosses[$bossName]
    $bossActiveDir = Join-Path $activeDir $bossName
    $rankingsPath = Join-Path $activeDir $info.rankingsFile

    $bossEntry = [ordered]@{
        encounterID          = $info.encounterID
        lastPulledDate        = $null
        rankingsSnapshotDate  = $null
        parses                = [ordered]@{}
    }

    if (-not (Test-Path $bossActiveDir) -or -not (Test-Path $rankingsPath)) {
        Write-Host "  $bossName - not pulled yet, recording boss with empty parses (no dates)"
        $manifest.bosses[$bossName] = $bossEntry
        continue
    }

    $rankingsData = Get-Content $rankingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rankings = @($rankingsData.rankings)

    $healingFiles = Get-ChildItem -Path $bossActiveDir -Filter "*_healing_events.json"
    $count = 0
    $unmatched = 0
    foreach ($file in $healingFiles) {
        try {
            $healingData = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Host "  WARNING: could not parse $($file.Name) - skipping in manifest"
            continue
        }
        $playerName = $healingData.sourceName
        if (-not $playerName) { continue }

        # reportID/fightID are always the first two underscore-separated segments and
        # always plain ASCII (report codes, numeric fight IDs) - safe to split even
        # though the player-name segment that follows may contain real Unicode (these
        # files were written via [System.IO.File]::WriteAllText, not -OutFile, so no
        # hex-escaping applies - see gotcha #1 for the OutFile-specific version of this
        # problem, which doesn't apply here). The real player name comes from the JSON's
        # own sourceName field regardless, same convention as summarize_class_benchmarks.ps1.
        $nameParts = $file.BaseName -split '_', 3
        $reportID = $nameParts[0]
        $fightID = [int]$nameParts[1]
        $safeName = $nameParts[2] -replace '_healing_events$', ''

        $rankIndex = $null
        $hps = $null
        for ($k = 0; $k -lt $rankings.Count; $k++) {
            if ($rankings[$k].reportID -eq $reportID -and $rankings[$k].fightID -eq $fightID -and $rankings[$k].name -eq $playerName) {
                $rankIndex = $k + 1
                $hps = [math]::Round($rankings[$k].total, 1)
                break
            }
        }
        if ($null -eq $rankIndex) {
            $unmatched++
        }

        $key = "$($reportID)_$($fightID)_$($playerName)"
        $bossEntry.parses[$key] = [ordered]@{
            reportID                 = $reportID
            fightID                   = $fightID
            playerName                = $playerName
            safeName                  = $safeName
            status                     = "active"
            rank                       = $rankIndex
            hps                        = $hps
            firstSeenAt                = "$DateFolder`T00:00:00Z"
            lastConfirmedInTop100At    = "$DateFolder`T00:00:00Z"
            archivedAt                 = $null
        }
        $count++
    }

    $bossEntry.lastPulledDate = $DateFolder
    $bossEntry.rankingsSnapshotDate = $DateFolder
    $manifest.bosses[$bossName] = $bossEntry

    $msg = "  $bossName - $count parses recorded as active"
    if ($unmatched -gt 0) { $msg += " ($unmatched had no matching rankings entry - rank/hps left null)" }
    Write-Host $msg
}

$jsonText = $manifest | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($manifestPath, $jsonText, (New-Object System.Text.UTF8Encoding $false))
Write-Host ""
Write-Host "Wrote $manifestPath"
Write-Host "Done."
