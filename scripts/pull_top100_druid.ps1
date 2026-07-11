# pull_top100_druid.ps1
#
# Fully self-contained: pulls the Top 100 Restoration Druid rankings for every SSC/TK boss,
# then pulls the FULL set of per-parse data for every one of those 1000 parses:
#   - healing events   (COMPLETE per-spell + per-target healing breakdown, via
#                        /report/events/healing/ with sourceid= - see below for why this
#                        replaced the healing TABLE)
#   - casts events     (COMPLETE cooldown/utility/consumable casts, each with a real
#                        target, via /report/events/casts/ with sourceid= - replaced the
#                        casts TABLE for the same reason. Consumables like mana potions/
#                        Dark Runes still show up here as cast events too.)
#   - buffs            (flask/food active-at-pull-start + real Tree of Life uptime %,
#                        replaces the old buffs TABLE, which was found to merge every
#                        Druid's buffs in a fight into one flat list - see "Buff uptime
#                        redesign" below)
#   - deaths           (fight-wide, NOT class-scoped - table view, UNCHANGED, pulled once
#                        per unique report+fight, not once per parse)
#
# ============================================================================
# PARALLELIZED (2026-07-11): per-parse work runs across multiple threads via a
# RunspacePool, since Windows PowerShell 5.1 doesn't have ForEach-Object -Parallel
# (that's PS7+ only). Read this before changing -MaxThreads:
#
# THE RATE LIMIT IS LIKELY THE REAL BOTTLENECK, NOT SEQUENTIAL EXECUTION. WCL's API
# caps at 800 calls/hour (from the X-Ratelimit-Limit response header). The OLD
# sequential script's 250ms delay already runs at ~4 calls/sec (~14,400/hour
# theoretical), far above that cap. Adding concurrency on top of an already-over-budget
# rate makes 429s more likely, not less. -MaxThreads defaults to 10 (raised from an
# initial default of 5 once real runs showed the sequential `deaths` pass - since
# folded into this same pool, see the THREAD SAFETY note below - as the actual
# bottleneck at lower thread counts, not the rate limit). If you see repeated "FAILED"
# lines mentioning 429 or rate limit, lower -MaxThreads back down.
#
# THREAD SAFETY: the sequential version shared plain PowerShell hashtables
# ($fightsCache, $tableCache, $deathsPulled) across the whole run - those are NOT safe
# for concurrent writes from multiple threads. This version uses
# [System.Collections.Concurrent.ConcurrentDictionary] instead for all of them,
# including a `$deathsClaimed` registry (2026-07-11) that runs `deaths` INSIDE the
# parallel worker too, gated by an atomic TryAdd claim: only the first thread to
# successfully claim a given "reportID|fightID" key fetches it, every other thread
# that races for the same claim gets $false back from TryAdd and skips - a real
# mutex, not just tolerating the occasional collision. (An earlier version of this
# script kept deaths in a separate sequential pass specifically to avoid this race;
# real pulled data showed ~0% report+fight sharing between parses anyway, so the
# race window was already rare in practice, but the claim-based fix removes it
# entirely rather than just relying on that low probability.) If the claiming
# thread's own fetch fails, no other thread retries it within this run - a full
# script re-run will pick it up fresh, same as any other failed call here.
#
# ============================================================================
# BUFF UPTIME REDESIGN (2026-07-11, same day as the healing/casts events rewrite)
# ============================================================================
# The old `/report/tables/buffs/{code}?sourceclass=Druid&hostility=0` call was found
# to merge every Druid in the fight into one flat list, not scoped to the one specific
# ranked player the file was named after - confirmed on real data (a single file
# showed Moonkin Form + Dire Bear Form + Tree of Life simultaneously, three different
# specs' forms, impossible for one character). Replaced with two pieces, both
# validated against real character-pull data before being adapted here:
#   - Flask/Elixir + food: pulled from the `combatantinfo` snapshot (the flat, no-
#     `{view}`-segment form of /report/events/) - these buffs last 1-2 hours, far
#     longer than a fight, so "active when the pull started" stands in for "active
#     the whole fight." combatantinfo can fire BEFORE a fight's recorded start_time
#     (confirmed: 33.6s early on a real Kael'thas pull) - the query searches a 2-
#     minute backward buffer and picks whichever snapshot is closest to start.
#   - Tree of Life: reconstructed from real apply/remove events (guid 33891 only -
#     its paired guid 34123 fires far more often in ways that don't match manual
#     form-toggling, empirically untrustworthy, excluded). Unlike the character-pull
#     script, this is scoped to just the ONE fight each parse represents, not
#     report-wide - there's no whole-raid-night amortization benefit here since every
#     parse is a different player, and we only ever need this one fight's uptime.
# See WORKFLOW.md and pull_character_TEMPLATE.ps1's header for the full validation
# writeup (including why a naive "every orphan removebuff = active since window
# start" rule was wrong and had to be restricted to only the first such event).
#
# UNTESTED: this environment cannot run PowerShell to verify this script directly (no
# PowerShell available here) - it's built carefully against documented RunspacePool/
# ConcurrentDictionary APIs and mirrors the already-validated sequential logic as
# closely as possible, but has NOT been run against the real API before being handed
# over. Test on ONE boss first (comment out the other 9 in $bosses below, or just
# delete all but one boss's rankings file before running) and watch the console output
# for FAILED lines before trusting a full 10-boss run.
# ============================================================================
#
# WHY HEALING/CASTS MOVED FROM TABLES TO EVENTS (2026-07-11 redesign)
# ============================================================================
# The /report/tables/{healing,casts}/{code} views silently cap their per-player
# "abilities" array at 5 entries - confirmed on Danceswtrees's real Leotheras kill
# (healing table said total=176374 but the 5 listed abilities only summed to 166830 -
# 9544 points of healing missing, no error, no warning) and on Turkeykin's real Hydross
# kill (the casts table showed 5 abilities with NO Innervate, despite Innervate
# definitely being cast that fight - confirmed via a targeted events pull with a real
# target: Turkeykin -> Churbert). /report/events/{view}/{code} with `sourceid` (a real,
# documented, standalone query param) returns complete, untruncated per-event records.
#
# DROPPED: resources / resources-gains (mana-over-time, HPM). Confirmed the real param
# name is `abilityid` (not `resourcetype`, an earlier wrong guess), untested against
# this specific endpoint as of this writing.
#
# Run this from your repo ROOT directory (e.g. C:\Users\raymo\wc_logs\), which should contain:
#   - an apikey.txt file at the root, with just your WCL API key on a single line
#     (add apikey.txt to your .gitignore so it never gets committed)
#   - a data\Classes\ folder (created automatically if it doesn't exist yet)
#
# Creates:  data\Classes\Druid\{date}\rankings_hydross.json  (etc.) - if not already present
# Writes, per parse:
#   data\Classes\Druid\{date}\{BossName}\{reportID}_{fightID}_{playerName}_healing_events.json
#   data\Classes\Druid\{date}\{BossName}\{reportID}_{fightID}_{playerName}_casts_events.json
#   data\Classes\Druid\{date}\{BossName}\{reportID}_{fightID}_{playerName}_consumables.json
# Writes, once per unique report+fight:
#   data\Classes\Druid\{date}\{BossName}\{reportID}_{fightID}_deaths.json
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File pull_top100_druid.ps1
#   powershell -ExecutionPolicy Bypass -File pull_top100_druid.ps1 -MaxThreads 5    # gentler
#   powershell -ExecutionPolicy Bypass -File pull_top100_druid.ps1 -MaxThreads 15   # faster, riskier

param(
    [int]$MaxThreads = 10
)

$apiKeyFile = "apikey.txt"
$baseUrl = "https://fresh.warcraftlogs.com/v1"
$classesRoot = "data\Classes"
$className = "Druid"
$classID = 2
$specID = 4          # Restoration
$dateFolder = "2026-07-10"
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

Write-Host "Running with -MaxThreads $MaxThreads (default 10 - lower this if you see rate-limit failures)"
Write-Host ""

# boss name -> (rankings filename, SSC/TK encounter ID)
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

# ===== STEP 1: Pull Top 100 rankings per boss (skip any already present) - sequential,
#               only 10 calls total, not worth parallelizing =====
Write-Host "=== Step 1: Fetching Top 100 rankings ==="
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
        Invoke-WebRequest -Uri $rankingsUrl -OutFile $rankingsFile -UseBasicParsing -ErrorAction Stop
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

# ===== STEP 2: Pull all per-parse data (healing events + casts events + buffs), in
#               parallel via a bounded RunspacePool =====
Write-Host "=== Step 2: Fetching fight data (healing events, casts events, consumables) - $MaxThreads threads ==="

# Thread-safe caches, shared across all worker threads for one boss's pool.
# ConcurrentDictionary, not a plain hashtable - see the PARALLELIZED note above for why.
$fightsCache = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$actorNamesCache = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()

# Claim registry for deaths: TryAdd is atomic, so only the first thread to attempt a
# given "reportID|fightID" key actually proceeds to fetch it - every other thread
# calling TryAdd for the same key gets $false back and skips. This is a real mutex,
# not just "tolerate the occasional race" - see the note above the deaths block below.
$deathsClaimed = [System.Collections.Concurrent.ConcurrentDictionary[string,bool]]::new()

# The self-contained per-parse worker. Runs in an isolated runspace with NO access to
# the outer script's functions or variables - everything it needs is passed in as an
# argument. Mirrors the sequential version's Get-PlayerEvents logic inline, since a
# separate function isn't visible inside the runspace without extra plumbing.
$workerScript = {
    param(
        $reportID, $fightID, $playerName, $i, $baseUrl, $apiKey, $className,
        $outDir, $fightsCache, $actorNamesCache, $deathsClaimed
    )

    $result = [PSCustomObject]@{
        Ok = $true
        Messages = New-Object System.Collections.Generic.List[string]
        ReportID = $reportID
    }

    function Get-EventsLocal {
        param($View, $OutFile, $StartTime, $EndTime, $SourceID, $SourceName, $ActorNames)
        if (Test-Path $OutFile) { return $true }
        $url = "$baseUrl/report/events/$View/$reportID`?start=$StartTime&end=$EndTime&sourceid=$SourceID&api_key=$apiKey"
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
            $data = $resp.Content | ConvertFrom-Json
        } catch {
            $result.Messages.Add("[$i] FAILED $View events for $reportID/$fightID ($playerName) - $_")
            return $false
        }
        $events = @($data.events)
        foreach ($ev in $events) {
            $srcName = if ($ActorNames.ContainsKey([int]$ev.sourceID)) { $ActorNames[[int]$ev.sourceID] } else { "Unknown_$($ev.sourceID)" }
            $tgtName = if ($ev.targetID -ne $null -and $ActorNames.ContainsKey([int]$ev.targetID)) { $ActorNames[[int]$ev.targetID] } else { if ($ev.targetID -ne $null) { "Unknown_$($ev.targetID)" } else { $null } }
            $ev | Add-Member -NotePropertyName "sourceName" -NotePropertyValue $srcName -Force
            $ev | Add-Member -NotePropertyName "targetName" -NotePropertyValue $tgtName -Force
        }
        $totalAmount = ($events | Measure-Object -Property amount -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $totalAmount) { $totalAmount = 0 }
        $totalOverheal = ($events | Measure-Object -Property overheal -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $totalOverheal) { $totalOverheal = 0 }
        $out = [PSCustomObject]@{
            sourceID = $SourceID; sourceName = $SourceName; view = $View
            eventCount = $events.Count; totalAmount = $totalAmount; totalOverheal = $totalOverheal
            events = $events
        }
        $jsonText = $out | ConvertTo-Json -Depth 15
        [System.IO.File]::WriteAllText($OutFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
        if ($events.Count -ge 2900) {
            $result.Messages.Add("[$i] $reportID/$fightID ($playerName) - $View events: $($events.Count) (HIGH - verify not silently capped)")
        }
        return $true
    }

    # --- fetch (or reuse) this report's fight list + actor-name lookup ---
    if (-not $fightsCache.ContainsKey($reportID)) {
        try {
            $fightsUrl = "$baseUrl/report/fights/$reportID`?api_key=$apiKey"
            $fd = Invoke-RestMethod -Uri $fightsUrl -UseBasicParsing -ErrorAction Stop
            [void]$fightsCache.TryAdd($reportID, $fd)

            $names = @{}
            foreach ($group in @('friendlies','enemies','friendlyPets','enemyPets')) {
                if ($fd.PSObject.Properties.Name -contains $group) {
                    foreach ($actor in $fd.$group) {
                        if ($actor.id -ne $null) { $names[[int]$actor.id] = $actor.name }
                    }
                }
            }
            [void]$actorNamesCache.TryAdd($reportID, $names)
        } catch {
            $result.Ok = $false
            $result.Messages.Add("[$i] FAILED fetching report $reportID (fights list) - $_")
            return $result
        }
    }

    $fightsData = $fightsCache[$reportID]
    $fight = $fightsData.fights | Where-Object { $_.id -eq $fightID }
    if (-not $fight) {
        $result.Ok = $false
        $result.Messages.Add("[$i] SKIP: fight $fightID not found in report $reportID")
        return $result
    }

    $playerActor = $fightsData.friendlies | Where-Object { $_.name -eq $playerName } | Select-Object -First 1
    if (-not $playerActor) {
        $result.Ok = $false
        $result.Messages.Add("[$i] SKIP: '$playerName' not found in report $reportID friendlies[] (can't scope sourceid)")
        return $result
    }
    $playerID = $playerActor.id
    $actorNames = $actorNamesCache[$reportID]
    $start = $fight.start_time
    $end = $fight.end_time
    $safeName = ($playerName -replace '[\\/:*?"<>|]', '_')

    $parseOk = $true

    $healingOutFile = Join-Path $outDir "$($reportID)_$($fightID)_$($safeName)_healing_events.json"
    if (-not (Get-EventsLocal -View "healing" -OutFile $healingOutFile -StartTime $start -EndTime $end -SourceID $playerID -SourceName $playerName -ActorNames $actorNames)) {
        $parseOk = $false
    }

    $castsOutFile = Join-Path $outDir "$($reportID)_$($fightID)_$($safeName)_casts_events.json"
    if (-not (Get-EventsLocal -View "casts" -OutFile $castsOutFile -StartTime $start -EndTime $end -SourceID $playerID -SourceName $playerName -ActorNames $actorNames)) {
        $parseOk = $false
    }

    function Get-ConsumablesSnapshotLocal {
        param($StartTime, $EndTime, $SourceID)
        # combatantinfo can fire BEFORE a fight's official start_time - confirmed on
        # real character-pull data (Kael'thas: snapshot was 33.6s before start_time,
        # zero events inside the fight's own window). Search backward with a buffer
        # and take whichever snapshot is closest to start, rather than assuming it
        # falls inside the fight's own window.
        $bufferMs = 120000
        $queryStart = [Math]::Max(0, $StartTime - $bufferMs)
        $url = "$baseUrl/report/events/$reportID`?start=$queryStart&end=$EndTime&filter=type%3D%22combatantinfo%22&api_key=$apiKey"
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
            $data = $resp.Content | ConvertFrom-Json
        } catch {
            $result.Messages.Add("[$i] FAILED combatantinfo for $reportID/$fightID ($playerName) - $_")
            return $null
        }
        $candidates = @($data.events | Where-Object { $_.sourceID -eq $SourceID })
        if ($candidates.Count -eq 0) {
            $result.Messages.Add("[$i] combatantinfo OK but no entry for sourceID=$SourceID even with backward buffer ($reportID/$fightID, $playerName)")
            return $null
        }
        $closest = $candidates | Sort-Object { [Math]::Abs($_.timestamp - $StartTime) } | Select-Object -First 1
        if (-not $closest.auras) { return $null }
        $flask = $closest.auras | Where-Object { $_.name -match 'Flask|Elixir' } | Select-Object -First 1
        $food = $closest.auras | Where-Object { $_.name -eq 'Well Fed' } | Select-Object -First 1
        return [PSCustomObject]@{
            flaskActive = [bool]$flask
            flaskName   = if ($flask) { $flask.name } else { $null }
            foodActive  = [bool]$food
            foodName    = if ($food) { $food.name } else { $null }
        }
    }

    function Get-TreeOfLifeUptimeLocal {
        param($StartTime, $EndTime, $SourceID)
        # Scoped to just this ONE fight's window, unlike the character-pull script's
        # report-wide version - each Top 100 parse is a different player, so there's
        # no whole-raid-night amortization benefit here, and we only ever need this
        # one fight's uptime anyway. Same validated state machine (guid 33891 only,
        # first-orphan-only "active since window start" rule) - see WORKFLOW.md.
        $treeOfLifeGuid = 33891
        $url = "$baseUrl/report/events/buffs/$reportID`?start=$StartTime&end=$EndTime&sourceid=$SourceID&api_key=$apiKey"
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
            $data = $resp.Content | ConvertFrom-Json
        } catch {
            $result.Messages.Add("[$i] FAILED tree-of-life buffs events for $reportID/$fightID ($playerName) - $_")
            return $null
        }
        $tolEvents = @($data.events | Where-Object { $_.ability.guid -eq $treeOfLifeGuid } | Sort-Object timestamp)
        $intervals = New-Object System.Collections.Generic.List[object]
        $active = $false
        $intervalStart = $null
        $isFirstEvent = $true
        foreach ($ev in $tolEvents) {
            if ($ev.type -eq "applybuff") {
                if (-not $active) { $intervalStart = $ev.timestamp; $active = $true }
            } elseif ($ev.type -eq "removebuff") {
                if ($active) {
                    $intervals.Add([PSCustomObject]@{ Start = $intervalStart; End = $ev.timestamp })
                    $active = $false
                } elseif ($isFirstEvent) {
                    $intervals.Add([PSCustomObject]@{ Start = $StartTime; End = $ev.timestamp })
                }
            }
            $isFirstEvent = $false
        }
        if ($active) {
            $intervals.Add([PSCustomObject]@{ Start = $intervalStart; End = $EndTime })
        }
        $overlap = 0
        foreach ($iv in $intervals) {
            $ovStart = [Math]::Max($iv.Start, $StartTime)
            $ovEnd = [Math]::Min($iv.End, $EndTime)
            if ($ovEnd -gt $ovStart) { $overlap += ($ovEnd - $ovStart) }
        }
        $duration = $EndTime - $StartTime
        if ($duration -le 0) { return 0 }
        return [math]::Round(($overlap / $duration) * 100, 1)
    }

    $consumablesOutFile = Join-Path $outDir "$($reportID)_$($fightID)_$($safeName)_consumables.json"
    if (-not (Test-Path $consumablesOutFile)) {
        $snapshot = Get-ConsumablesSnapshotLocal -StartTime $start -EndTime $end -SourceID $playerID
        if ($null -eq $snapshot) {
            $parseOk = $false
        } else {
            $treeOfLifePct = Get-TreeOfLifeUptimeLocal -StartTime $start -EndTime $end -SourceID $playerID
            if ($null -eq $treeOfLifePct) {
                $treeOfLifePct = 0
                $parseOk = $false
            }
            $out = [PSCustomObject]@{
                flaskActive         = $snapshot.flaskActive
                flaskName           = $snapshot.flaskName
                foodActive          = $snapshot.foodActive
                foodName            = $snapshot.foodName
                treeOfLifeUptimePct = $treeOfLifePct
            }
            $jsonText = $out | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText($consumablesOutFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
        }
    }

    # --- deaths (fight-wide, once per report+fight - claim via TryAdd so only ONE
    #     thread across the whole pool ever fetches a given report+fight's deaths,
    #     eliminating the two-threads-race-on-one-file risk instead of just tolerating
    #     it. If the claiming thread's own fetch fails, no other thread retries it
    #     THIS run - a re-run of the whole script will pick it up fresh next time,
    #     same as any other failed call here.) ---
    $deathsOutFile = Join-Path $outDir "$($reportID)_$($fightID)_deaths.json"
    if (-not (Test-Path $deathsOutFile)) {
        $deathsKey = "$reportID|$fightID"
        if ($deathsClaimed.TryAdd($deathsKey, $true)) {
            try {
                $deathsUrl = "$baseUrl/report/tables/deaths/$reportID`?start=$start&end=$end&api_key=$apiKey"
                Invoke-WebRequest -Uri $deathsUrl -OutFile $deathsOutFile -UseBasicParsing -ErrorAction Stop
            } catch {
                $result.Messages.Add("[$i] FAILED deaths table for $reportID/$fightID - $_")
                # not counted against $parseOk - deaths isn't a per-player data point
            }
        }
        # else: another thread already claimed this report+fight's deaths pull -
        # skip, it's either already done or in progress
    }

    $result.Ok = $parseOk
    return $result
}

$totalDone = 0
$totalFailed = 0

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

    Write-Host "=== $boss ($($rankings.Count) parses, $MaxThreads threads) ==="

    $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $pool.Open()

    $jobs = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($r in $rankings) {
        $i++
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($workerScript.ToString()).AddArgument($r.reportID).AddArgument($r.fightID).AddArgument($r.name).AddArgument($i).AddArgument($baseUrl).AddArgument($apiKey).AddArgument($className).AddArgument($outDir).AddArgument($fightsCache).AddArgument($actorNamesCache).AddArgument($deathsClaimed)
        $handle = $ps.BeginInvoke()
        $jobs.Add([PSCustomObject]@{ Pipe = $ps; Handle = $handle })
    }

    $bossDone = 0
    $bossFailed = 0
    foreach ($job in $jobs) {
        try {
            $result = $job.Pipe.EndInvoke($job.Handle)
            foreach ($msg in $result.Messages) { Write-Host "  $msg" }
            if ($result.Ok) { $bossDone++ } else { $bossFailed++ }
        } catch {
            Write-Host "  Worker threw unexpectedly: $_"
            $bossFailed++
        } finally {
            $job.Pipe.Dispose()
        }
    }

    $pool.Close()
    $pool.Dispose()

    Write-Host "  $boss done: $bossDone ok, $bossFailed failed"
    $totalDone += $bossDone
    $totalFailed += $bossFailed

    Write-Host ""
}

Write-Host "=================================="
Write-Host "Done."
Write-Host "  Succeeded (all pulls ok):     $totalDone"
Write-Host "  Failed (one or more pulls):   $totalFailed"
Write-Host "  Unique reports fetched:       $($fightsCache.Count)"
