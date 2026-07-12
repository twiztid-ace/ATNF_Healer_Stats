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
# ACTIVE/ARCHIVED DIFF MODEL (2026-07-12) - replaces the old date-stamped-folder approach
# ============================================================================
# Every run used to create a brand new data\Classes\Druid\{date}\ folder and re-fetch all
# ~1000 parses from scratch, even though the vast majority of a boss's Top 100 doesn't
# change between runs and a completed log's healing/casts/consumables data can never
# change once pulled. That's pure wasted API budget (WCL caps at 800 calls/hour - see the
# PARALLELIZED note below). This version instead:
#   1. Reads data\Classes\Druid\manifest.json (per-boss lastPulledDate/rankingsSnapshotDate,
#      per-parse status "active"/"archived" keyed by "{reportID}_{fightID}_{playerName}").
#   2. Fetches fresh rankings for a boss (1 call, same as before) and diffs the fresh
#      reportID+fightID+name set against the manifest's currently-active parses for that
#      boss:
#        - present in fresh, NOT in manifest-active -> genuinely new, fetch its full data
#          (this is the only case that costs real per-parse API calls)
#        - present in BOTH -> still in the Top 100, zero API calls - just refresh its
#          rank/hps in the manifest from the response we already have in memory
#        - in manifest-active, NOT in fresh -> dropped out of the Top 100 - move its
#          healing/casts/consumables files from active\{Boss}\ to archived\{Boss}\ (kept
#          forever, not deleted) and flip its manifest status to "archived"
#   3. The on-disk rankings_{boss}.json under active\ only gets overwritten - and the
#      PREVIOUS version archived to archived\rankings_history\{Boss}\{old date}.json -
#      when that diff found at least one add or drop. A pure rank/HPS reshuffle among the
#      same 100 people (which shouldn't really happen for completed logs, but just in
#      case) does NOT trigger a rewrite/archive - only real membership changes do. This
#      means the on-disk rankings_{boss}.json can very slightly lag the manifest's
#      per-parse rank/hps fields in that edge case - the manifest is always the source of
#      truth for those, the JSON file is a periodic snapshot, not a live mirror.
#   4. `deaths.json` files are NEVER archived, regardless of whether the parse(s) that
#      reference them get archived - they're tiny, fight-wide (not per-parse), and
#      cheap to just leave in active\{Boss}\ forever.
#   5. lastPulledDate/rankingsSnapshotDate are plain "yyyy-MM-dd" calendar-date strings,
#      not timestamps - staleness is ALWAYS computed by comparing to today's date, never
#      stored as a boolean (a stored true/false flag would silently go wrong the instant
#      the date rolls over). summarize_class_benchmarks.ps1 is expected to apply the same
#      rule against `benchmarkGeneratedDate` at the top of the manifest.
# Creates data\Classes\Druid\manifest.json fresh (empty bosses) if it doesn't exist yet -
# for Druid specifically, it was created once by scripts\migrate_class_to_active.ps1
# migrating the last date-folder pull (2026-07-10) into this layout; that migration
# script does NOT need to run again for Druid.
# ============================================================================
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
# lines mentioning 429 or rate limit, lower -MaxThreads back down. The active/archived
# diff model above should make this a smaller concern in practice anyway, since most
# runs now only fetch a handful of genuinely new parses per boss instead of all 100.
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
# DROPPED (and no longer needed): resources / resources-gains (mana-over-time, HPM)
# as a separate API pull. The real swagger spec documents `abilityid` as the
# resource-type param (not `resourcetype`, an earlier wrong guess) - tested for real
# 2026-07-12 (5 real calls, every abilityid variant tried) and the endpoint itself
# does NOT work against the real Fresh Classic API. Doesn't matter though: every
# casts event this script already saves carries a `classResources[0]` object with
# real mana data under misleadingly-generic field names - `amount` = max mana pool
# (constant), `max` = that spell's real mana cost, `type` = current mana at that
# moment. Verified against a full real kill's cast sequence (type decreases smoothly
# 10175->2781 over the fight; max matches known real TBC spell costs exactly). HPM
# is computable from data this script already writes, no new pull needed - just not
# summarized/surfaced yet. See WORKFLOW.md gotcha #11 for the full writeup.
#
# Run this from your repo ROOT directory (e.g. C:\Users\raymo\wc_logs\), which should contain:
#   - an apikey.txt file at the root, with just your WCL API key on a single line
#     (add apikey.txt to your .gitignore so it never gets committed)
#   - a data\Classes\ folder (created automatically if it doesn't exist yet)
#
# Creates/updates: data\Classes\Druid\manifest.json
# Writes, per NEW parse only:
#   data\Classes\Druid\active\{BossName}\{reportID}_{fightID}_{playerName}_healing_events.json
#   data\Classes\Druid\active\{BossName}\{reportID}_{fightID}_{playerName}_casts_events.json
#   data\Classes\Druid\active\{BossName}\{reportID}_{fightID}_{playerName}_consumables.json
# Writes, once per unique report+fight (never archived):
#   data\Classes\Druid\active\{BossName}\{reportID}_{fightID}_deaths.json
# Moves, per DROPPED parse (no longer in the Top 100):
#   active\{BossName}\{...} -> archived\{BossName}\{...} (healing/casts/consumables only)
# Conditionally (only when a boss's Top 100 membership actually changed):
#   active\rankings_{boss}.json overwritten; previous version moved to
#   archived\rankings_history\{BossName}\{previous rankingsSnapshotDate}.json
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
$classDir = Join-Path $classesRoot $className
$activeDir = Join-Path $classDir "active"
$archivedDir = Join-Path $classDir "archived"
$manifestPath = Join-Path $classDir "manifest.json"
$today = Get-Date -Format "yyyy-MM-dd"
$nowIso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

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
Write-Host "Today: $today"
Write-Host ""

# boss name -> (rankings filename, SSC/TK encounter ID) - matches WORKFLOW.md's SSC/TK
# reference ID table exactly.
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

New-Item -ItemType Directory -Force -Path $activeDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $archivedDir "rankings_history") | Out-Null

# ===== Manifest load/save - PSCustomObject (from ConvertFrom-Json) is awkward to mutate
# with dynamically-named keys (Add-Member for every new parse), so it's converted to
# plain ordered hashtables on load and converted back to JSON on save. No arrays appear
# anywhere in this schema (bosses/parses are both object-keyed dictionaries), so a
# straightforward recursive PSCustomObject->hashtable walk is all that's needed. =====
function ConvertTo-OrderedHashtableLocal {
    param($InputObject)
    if ($InputObject -is [System.Array]) {
        return @($InputObject | ForEach-Object { ConvertTo-OrderedHashtableLocal $_ })
    } elseif ($InputObject -is [PSCustomObject]) {
        $hash = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-OrderedHashtableLocal $prop.Value
        }
        return $hash
    } else {
        return $InputObject
    }
}

if (Test-Path $manifestPath) {
    $manifest = ConvertTo-OrderedHashtableLocal (Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
} else {
    Write-Host "No manifest.json found - creating a fresh one for $className."
    $manifest = [ordered]@{
        schemaVersion = 2
        className = $className
        classID = $classID
        specID = $specID
        benchmarkGeneratedDate = $null
        bosses = [ordered]@{}
    }
}

function Save-ManifestLocal {
    param($Manifest, $Path)
    $jsonText = $Manifest | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $jsonText, (New-Object System.Text.UTF8Encoding $false))
}

# ===== The self-contained per-parse worker (unchanged from the previous version except
# for taking its output directory directly - it always writes into active\{Boss}\, since
# it's only ever invoked for genuinely NEW parses now). Runs in an isolated runspace with
# NO access to the outer script's functions or variables - everything it needs is passed
# in as an argument. =====
$workerScript = {
    param(
        $reportID, $fightID, $playerName, $i, $baseUrl, $apiKey, $className,
        $outDir, $fightsCache, $actorNamesCache, $deathsClaimed
    )

    $result = [PSCustomObject]@{
        Ok = $true
        Messages = New-Object System.Collections.Generic.List[string]
        ReportID = $reportID
        FightID = $fightID
        PlayerName = $playerName
        SafeName = $null
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
            # A missing targetID means WCL logged no real other-actor target for this
            # event at all (self-only-castable spells like Nature's Swiftness come back
            # as target={"name":"Environment","id":-1,...} instead of a real actor ID) -
            # fixed 2026-07-12 to fall back to the caster's own name, not $null, since a
            # spell with no real other-actor target can only have affected the caster.
            # Before this fix, every downstream self-vs-other classification (see
            # summarize_class_benchmarks.ps1) silently miscounted these as "not self" -
            # confirmed on real data: Nature's Swiftness showed 0% self across a full
            # 100-person sample, implausible for a spell that can't target anyone else.
            $tgtName = if ($ev.targetID -ne $null -and $ActorNames.ContainsKey([int]$ev.targetID)) { $ActorNames[[int]$ev.targetID] } else { if ($ev.targetID -ne $null) { "Unknown_$($ev.targetID)" } else { $srcName } }
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
    $result.SafeName = $safeName

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

    # --- active time (2026-07-12 addition) - real activeTime/activeTimeReduced fields
    # from the healing TABLE, NOT a reconstruction. This project moved off the healing
    # TABLE entirely for spell composition because its nested abilities[] array
    # silently truncates at 5 entries (see WORKFLOW.md gotcha #15) - but that
    # truncation is specific to the nested array. The top-level activeTime/
    # activeTimeReduced scalar fields on each player's entry are NOT part of that
    # truncated array and were never actually confirmed broken - just abandoned
    # along with the whole endpoint. Verified for real: pulled this exact call for
    # Danceswtrees's Hydross kill and got activeTime=138449ms/143007ms=96.8%,
    # matching the number already recorded in the pre-events-rewrite v1 page exactly.
    # sourceclass=Druid returns every Druid in that report+fight in one response (like
    # `deaths` does for the whole raid) - matched by real player name, same pattern
    # `deaths`/old-era pulls already used for this exact table. ---
    $activeTimeOutFile = Join-Path $outDir "$($reportID)_$($fightID)_$($safeName)_activetime.json"
    if (-not (Test-Path $activeTimeOutFile)) {
        $atUrl = "$baseUrl/report/tables/healing/$reportID`?start=$start&end=$end&sourceclass=$className&api_key=$apiKey"
        try {
            $atResp = Invoke-WebRequest -Uri $atUrl -UseBasicParsing -ErrorAction Stop
            $atData = $atResp.Content | ConvertFrom-Json
            $atEntry = $atData.entries | Where-Object { $_.name -eq $playerName } | Select-Object -First 1
            if (-not $atEntry) {
                $result.Messages.Add("[$i] FAILED activetime for $reportID/$fightID ($playerName) - no matching entry in healing table response")
                $parseOk = $false
            } else {
                $duration = $end - $start
                $activeTimePct = if ($duration -gt 0) { [math]::Round(($atEntry.activeTime / $duration) * 100, 1) } else { 0 }
                $activeTimeReducedPct = if ($duration -gt 0) { [math]::Round(($atEntry.activeTimeReduced / $duration) * 100, 1) } else { 0 }
                $atOut = [PSCustomObject]@{
                    activeTime = $atEntry.activeTime
                    activeTimeReduced = $atEntry.activeTimeReduced
                    activeTimePct = $activeTimePct
                    activeTimeReducedPct = $activeTimeReducedPct
                }
                $jsonText = $atOut | ConvertTo-Json -Depth 5
                [System.IO.File]::WriteAllText($activeTimeOutFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
            }
        } catch {
            $result.Messages.Add("[$i] FAILED activetime healing-table call for $reportID/$fightID ($playerName) - $_")
            $parseOk = $false
        }
    }

    # --- deaths (fight-wide, once per report+fight, NEVER archived - see header note) ---
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

$fightsCache = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$actorNamesCache = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$deathsClaimed = [System.Collections.Concurrent.ConcurrentDictionary[string,bool]]::new()

$totalNew = 0
$totalConfirmed = 0
$totalArchived = 0
$totalFailed = 0

foreach ($bossName in $bosses.Keys) {
    $encounterID = $bosses[$bossName].encounterID
    $rankingsFileName = $bosses[$bossName].file
    $activeRankingsPath = Join-Path $activeDir $rankingsFileName
    $bossActiveDir = Join-Path $activeDir $bossName
    $bossArchivedDir = Join-Path $archivedDir $bossName
    New-Item -ItemType Directory -Force -Path $bossActiveDir | Out-Null

    Write-Host "=== $bossName ==="

    # ----- Step 1: fetch fresh rankings into memory (NOT written to disk yet - we need
    # to diff first to decide whether this counts as a real change worth archiving) -----
    $rankingsUrl = "$baseUrl/rankings/encounter/$encounterID`?metric=hps&spec=$specID&class=$classID&api_key=$apiKey"
    try {
        $rankingsResp = Invoke-WebRequest -Uri $rankingsUrl -UseBasicParsing -ErrorAction Stop
        $freshRankingsData = $rankingsResp.Content | ConvertFrom-Json
    } catch {
        Write-Host "  FAILED fetching rankings - $_ - skipping this boss entirely this run."
        Write-Host ""
        continue
    }
    if ($freshRankingsData.PSObject.Properties.Name -contains "error") {
        Write-Host "  API ERROR: $($freshRankingsData.error) - skipping this boss entirely this run."
        Write-Host ""
        continue
    }
    $freshRankings = @($freshRankingsData.rankings)
    Write-Host "  got $($freshRankings.Count) fresh rankings"

    if (-not $manifest.bosses.Contains($bossName)) {
        $manifest.bosses[$bossName] = [ordered]@{
            encounterID = $encounterID
            lastPulledDate = $null
            rankingsSnapshotDate = $null
            parses = [ordered]@{}
        }
    }
    $bossEntry = $manifest.bosses[$bossName]

    # ----- Build the fresh key set and diff against manifest-active parses -----
    $freshByKey = [ordered]@{}
    for ($k = 0; $k -lt $freshRankings.Count; $k++) {
        $r = $freshRankings[$k]
        $key = "$($r.reportID)_$($r.fightID)_$($r.name)"
        $freshByKey[$key] = [ordered]@{ rank = $k + 1; hps = $r.total; reportID = $r.reportID; fightID = $r.fightID; name = $r.name }
    }

    $activeManifestKeys = @($bossEntry.parses.Keys | Where-Object { $bossEntry.parses[$_].status -eq "active" })
    $newKeys = @($freshByKey.Keys | Where-Object { $activeManifestKeys -notcontains $_ })
    $droppedKeys = @($activeManifestKeys | Where-Object { -not $freshByKey.Contains($_) })
    $stillActiveKeys = @($activeManifestKeys | Where-Object { $freshByKey.Contains($_) })

    # ----- Refresh rank/hps for parses still in the Top 100 - free, already in memory -----
    foreach ($key in $stillActiveKeys) {
        $bossEntry.parses[$key].rank = $freshByKey[$key].rank
        $bossEntry.parses[$key].hps = [math]::Round($freshByKey[$key].hps, 1)
        $bossEntry.parses[$key].lastConfirmedInTop100At = $nowIso
    }
    $totalConfirmed += $stillActiveKeys.Count

    # ----- Archive parses that dropped out of the Top 100 -----
    if ($droppedKeys.Count -gt 0) {
        New-Item -ItemType Directory -Force -Path $bossArchivedDir | Out-Null
    }
    foreach ($key in $droppedKeys) {
        $p = $bossEntry.parses[$key]
        $stem = "$($p.reportID)_$($p.fightID)_$($p.safeName)"
        foreach ($suffix in @("healing_events", "casts_events", "consumables")) {
            $srcPath = Join-Path $bossActiveDir "$($stem)_$($suffix).json"
            if (Test-Path $srcPath) {
                Move-Item -Path $srcPath -Destination $bossArchivedDir -Force
            } else {
                Write-Host "  WARNING: expected $srcPath to archive for dropped parse $key, not found."
            }
        }
        $p.status = "archived"
        $p.archivedAt = $nowIso
    }
    $totalArchived += $droppedKeys.Count

    # ----- Conditionally archive+overwrite the rankings snapshot - only on a real
    # membership change (add or drop), never for a pure rank/HPS reshuffle -----
    $changed = ($newKeys.Count -gt 0) -or ($droppedKeys.Count -gt 0)
    if ($changed) {
        if (Test-Path $activeRankingsPath) {
            $oldSnapshotDate = $bossEntry.rankingsSnapshotDate
            if (-not $oldSnapshotDate) { $oldSnapshotDate = "unknown-date" }
            $rankingsHistoryDir = Join-Path (Join-Path $archivedDir "rankings_history") $bossName
            New-Item -ItemType Directory -Force -Path $rankingsHistoryDir | Out-Null
            $archivedRankingsPath = Join-Path $rankingsHistoryDir "$oldSnapshotDate.json"
            Move-Item -Path $activeRankingsPath -Destination $archivedRankingsPath -Force
        }
        [System.IO.File]::WriteAllText($activeRankingsPath, $rankingsResp.Content, (New-Object System.Text.UTF8Encoding $false))
        $bossEntry.rankingsSnapshotDate = $today
        Write-Host "  rankings CHANGED ($($newKeys.Count) new, $($droppedKeys.Count) dropped) - snapshot updated"
    } else {
        Write-Host "  rankings unchanged since $($bossEntry.rankingsSnapshotDate) - not rewriting active\$rankingsFileName"
    }
    $bossEntry.lastPulledDate = $today

    # ----- Step 2: fetch full per-parse data for genuinely NEW parses only, in parallel -----
    if ($newKeys.Count -eq 0) {
        Write-Host "  no new parses to fetch"
        Save-ManifestLocal -Manifest $manifest -Path $manifestPath
        Write-Host ""
        continue
    }

    Write-Host "  fetching $($newKeys.Count) new parses ($MaxThreads threads)..."
    $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $pool.Open()

    $jobs = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($key in $newKeys) {
        $i++
        $entry = $freshByKey[$key]
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($workerScript.ToString()).AddArgument($entry.reportID).AddArgument($entry.fightID).AddArgument($entry.name).AddArgument($i).AddArgument($baseUrl).AddArgument($apiKey).AddArgument($className).AddArgument($bossActiveDir).AddArgument($fightsCache).AddArgument($actorNamesCache).AddArgument($deathsClaimed)
        $handle = $ps.BeginInvoke()
        $jobs.Add([PSCustomObject]@{ Pipe = $ps; Handle = $handle; Key = $key })
    }

    $bossNewOk = 0
    $bossNewFailed = 0
    foreach ($job in $jobs) {
        try {
            $result = $job.Pipe.EndInvoke($job.Handle)
            foreach ($msg in $result.Messages) { Write-Host "  $msg" }
            if ($result.Ok) {
                $entry = $freshByKey[$job.Key]
                $bossEntry.parses[$job.Key] = [ordered]@{
                    reportID = $result.ReportID
                    fightID = $result.FightID
                    playerName = $result.PlayerName
                    safeName = $result.SafeName
                    status = "active"
                    rank = $entry.rank
                    hps = [math]::Round($entry.hps, 1)
                    firstSeenAt = $nowIso
                    lastConfirmedInTop100At = $nowIso
                    archivedAt = $null
                }
                $bossNewOk++
            } else {
                # Not added to the manifest - stays absent from manifest-active, so
                # next run's diff sees it as "new" again and retries. Any files that
                # DID succeed before the failure are still on disk and get skipped
                # (Test-Path) on that retry - only the missing piece is re-fetched.
                $bossNewFailed++
            }
        } catch {
            Write-Host "  Worker threw unexpectedly for $($job.Key): $_"
            $bossNewFailed++
        } finally {
            $job.Pipe.Dispose()
        }
    }

    $pool.Close()
    $pool.Dispose()

    Write-Host "  $bossName new parses done: $bossNewOk ok, $bossNewFailed failed"
    $totalNew += $bossNewOk
    $totalFailed += $bossNewFailed

    Save-ManifestLocal -Manifest $manifest -Path $manifestPath
    Write-Host ""
}

Write-Host "=================================="
Write-Host "Done."
Write-Host "  New parses fetched (ok):        $totalNew"
Write-Host "  New parses failed:              $totalFailed"
Write-Host "  Still-active (no refetch):      $totalConfirmed"
Write-Host "  Archived (dropped from Top 100): $totalArchived"
Write-Host "  Unique reports fetched:         $($fightsCache.Count)"
Write-Host "  manifest.json:                  $manifestPath"
