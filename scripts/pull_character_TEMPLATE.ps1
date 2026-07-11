# pull_character_TEMPLATE.ps1
#
# Pulls one character's full raid-night data set for the ATNF Healer Analysis pipeline,
# steps 1-4 of WORKFLOW.md, fully automated - no manual JSON inspection or filled-in
# placeholders required.
#
# Given a report code (or full report URL) and a character name, this:
#   1. Fetches (or reuses a cached copy of) the report's fight list
#   2. Reads the raid date straight from the report title
#   3. Looks up the character's class/server/region AND report-local numeric actor ID
#      from the report's own friendlies[] list (no need to already know these - only
#      pass -Server/-Region/-Class to override, e.g. if the character isn't in this
#      particular report for some reason - see the note on that below, since it now
#      limits what Step 4 can do)
#   4. Pulls, per boss kill (boss != 0 && kill == true):
#        - healing events   (COMPLETE per-spell + per-target healing breakdown, via
#                             /report/events/healing/ with sourceid= - see below for why
#                             this replaced the healing TABLE)
#        - casts events     (COMPLETE cooldown/utility/consumable casts, each with a
#                             real target, via /report/events/casts/ with sourceid= -
#                             replaced the casts TABLE for the same reason)
#        - consumables       (flask/food active-at-pull-start + real Tree of Life uptime
#                              %, replaces the buffs table - see "Buff uptime redesign"
#                              below for why the table version was actually wrong, not
#                              just unverified)
#        - deaths table     (fight-wide raid death list, not class-scoped - unchanged)
#   5. Pulls the character's full parse history (for real per-fight WCL percentiles)
#
# ============================================================================
# WHY THIS PULLS EVENTS INSTEAD OF TABLES FOR HEALING/CASTS (2026-07-11 redesign)
# ============================================================================
# The /report/tables/{healing,casts}/{code} views silently cap their per-player
# "abilities" array at 5 entries - confirmed by cross-checking against real
# /report/events data during a live debugging session. The table's entry-level
# `total` stays accurate; only the per-spell breakdown gets truncated, with NO
# error and NO visible signal. This was caught two ways on the same real report:
#   - Danceswtrees's Leotheras kill: healing table said total=176374 but the 5
#     listed abilities only summed to 166830 (9544 missing). The equivalent
#     /report/events/healing/ pull (sourceid-scoped) summed to exactly 176374 -
#     a perfect match, confirming events are complete and the table wasn't.
#   - Turkeykin's Hydross kill: the casts table showed 5 abilities (Starfire,
#     Moonfire, Faerie Fire, Force of Nature, Spell Power) with NO Innervate,
#     despite Innervate definitely being cast that fight (confirmed via a
#     targeted /report/events pull with a real target: Turkeykin -> Churbert).
# This affects EVERY previously-pulled healing/casts table file - both spell
# composition and cooldown/utility counts built on those files should be treated
# as unverified until re-pulled with this script.
#
# The correct endpoint is /report/events/{view}/{code} with `sourceid` as a real,
# documented, standalone query parameter (confirmed against the actual v1 swagger
# spec - NOT `source.id`, `sourceID`, or a bare `source=` param, all of which were
# tried first and silently ignored rather than erroring, which cost real time to
# track down). There is no documented pagination/limit override for this endpoint;
# a real 3983-event unfiltered pull for one fight came back complete (last event
# landed within 90ms of the fight's actual end), which is reassuring but not a
# guarantee for busier/longer fights - this script logs the event count returned
# for every pull so unusually round or suspiciously large counts are visible in
# the console output rather than silently trusted.
#
# CONSEQUENCE FOR CHARACTERS NOT IN THIS REPORT'S friendlies[]: sourceid is a
# report-local numeric actor ID, only resolvable from friendlies[]. If -Class/
# -Server/-Region overrides are used because the character genuinely isn't in
# this report, Step 4 (fight-level pulls) is skipped entirely - there is no
# sourceid to scope the events calls to, and if the character wasn't in this
# report they have no events in it anyway. Step 5 (parse history) still runs
# since it only needs name/server/region, not a report-local ID.
#
# NOT included: resources / resources-gains (mana-over-time, HPM) - see
# WORKFLOW.md, this needs a fresh test with the now-confirmed `abilityid`
# parameter (not `resourcetype`, which was an earlier wrong guess) before it's
# worth adding here.
#
# Run this from your repo ROOT directory, which should contain:
#   - an apikey.txt file at the root, with just your WCL API key on a single line
#     (add apikey.txt to your .gitignore so it never gets committed)
#   - a data\Characters\ folder (created automatically if it doesn't exist yet)
#
# Result: data\Characters\{CharacterName}\{date}\
#           fights_{reportCode}.json
#           fight{fightID}_{bossSlug}_healing_events.json   <- one per boss kill
#           fight{fightID}_{bossSlug}_casts_events.json
#           fight{fightID}_{bossSlug}_consumables.json      <- flask/food snapshot + real Tree of Life %
#           fight{fightID}_{bossSlug}_deaths.json
#           {charactername}_all_parses.json
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File pull_character_TEMPLATE.ps1 -ReportCode "XJp8vAxzM4KtHYyb" -CharacterName "Crowns"
#
#   # or paste the full report URL directly:
#   powershell -ExecutionPolicy Bypass -File pull_character_TEMPLATE.ps1 -ReportCode "https://fresh.warcraftlogs.com/reports/XJp8vAxzM4KtHYyb" -CharacterName "Crowns"
#
#   # overrides - NOTE: these now only support Step 5 (parse history). Step 4 needs a
#   # real report-local actor ID and is skipped if the character isn't in friendlies[]:
#   powershell -ExecutionPolicy Bypass -File pull_character_TEMPLATE.ps1 -ReportCode "XJp8vAxzM4KtHYyb" -CharacterName "Crowns" -Server "Dreamscythe" -Region "US" -Class "Paladin"

param(
    [Parameter(Mandatory=$true)][string]$ReportCode,
    [Parameter(Mandatory=$true)][string]$CharacterName,
    [string]$Server,        # optional override - Step 5 only, see note above
    [string]$Region,        # optional override - Step 5 only, see note above
    [string]$Class,         # optional override - Step 5 only, see note above
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

# $fightsSourcePath tracks a byte-correct file on disk (never a string that's been
# round-tripped through Get-Content/Set-Content's default encoding, which is not
# reliably UTF-8 on Windows PowerShell 5.1 - see WORKFLOW.md gotcha #14). It gets
# Copy-Item'd into this character's folder further down, not re-serialized. It's only
# read AS a string (with -Encoding UTF8 forced explicitly) for JSON parsing below,
# never written back out from that string.
if ($cachedFightsFile) {
    Write-Host "  Found cached fights file: $($cachedFightsFile.FullName) - reusing, not re-fetching."
    $fightsSourcePath = $cachedFightsFile.FullName
} else {
    Write-Host "  Not cached anywhere yet - fetching from the API..."
    $fightsUrl = "$baseUrl/report/fights/$ReportCode`?api_key=$apiKey"
    $tempFightsFile = Join-Path $env:TEMP "fights_$ReportCode`_$([guid]::NewGuid()).json"
    try {
        Invoke-WebRequest -Uri $fightsUrl -OutFile $tempFightsFile -UseBasicParsing
        $fightsSourcePath = $tempFightsFile
    } catch {
        Write-Host "ERROR: failed to fetch fight list for $ReportCode - $_"
        exit 1
    }
}

$fightsRaw = Get-Content $fightsSourcePath -Raw -Encoding UTF8
$fightsData = $fightsRaw | ConvertFrom-Json
if ($fightsData.PSObject.Properties.Name -contains "error") {
    Write-Host "ERROR: API returned an error for report $ReportCode`: $($fightsData.error)"
    Write-Host "       (This usually means the report is private - the owner needs to make it public.)"
    exit 1
}

# Build a report-local actor ID -> name lookup, used to annotate raw sourceID/targetID
# fields on events with real names before saving. Covers players, NPCs, and pets -
# events can target any of these (e.g. Innervate targets a player, a boss debuff-cast
# targets an NPC add, a pet heal targets a pet).
$actorNames = @{}
foreach ($group in @('friendlies','enemies','friendlyPets','enemyPets')) {
    if ($fightsData.PSObject.Properties.Name -contains $group) {
        foreach ($actor in $fightsData.$group) {
            if ($actor.id -ne $null) { $actorNames[[int]$actor.id] = $actor.name }
        }
    }
}

function Resolve-ActorName($id) {
    if ($id -eq $null) { return $null }
    $key = [int]$id
    if ($actorNames.ContainsKey($key)) { return $actorNames[$key] }
    return "Unknown_$key"
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

# ===== STEP 3: Resolve class/server/region/ID from friendlies[] =====
$friendly = $fightsData.friendlies | Where-Object { $_.name -eq $CharacterName } | Select-Object -First 1
$CharacterID = $null

if ($friendly) {
    if (-not $Class)  { $Class  = $friendly.type }
    if (-not $Server) { $Server = $friendly.server }
    if (-not $Region) { $Region = $friendly.region }
    $CharacterID = $friendly.id
    Write-Host "  Found '$CharacterName' in friendlies[]: $Class, $Server-$Region, report-local id=$CharacterID"
} else {
    if (-not $Class -or -not $Server -or -not $Region) {
        Write-Host "ERROR: '$CharacterName' was not found in this report's friendlies[] list."
        Write-Host "       Re-run with -Class, -Server, and -Region supplied explicitly if this character"
        Write-Host "       genuinely isn't in this report (e.g. resolving them from a different raid)."
        exit 1
    }
    Write-Host "  '$CharacterName' not in friendlies[] - using supplied overrides: $Class, $Server-$Region"
    Write-Host "  WARNING: no report-local actor ID available for '$CharacterName' - Step 4 (fight-level"
    Write-Host "           healing/casts/buffs/deaths pulls) will be SKIPPED. Only Step 5 (parse history)"
    Write-Host "           will run. This is expected if the character truly isn't in this report."
}

# ===== Set up output folder =====
$outDir = Join-Path (Join-Path $charactersRoot $CharacterName) $raidDate
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Write-Host "  Output folder: $outDir"
Write-Host ""

# Write/copy the fights file into this character's folder too (per WORKFLOW.md convention -
# every character folder gets its own copy, even though the underlying data is shared/reused).
# Copy-Item, not Set-Content($fightsRaw) - see the $fightsSourcePath comment above for why.
$fightsOutFile = Join-Path $outDir "fights_$ReportCode.json"
if (-not (Test-Path $fightsOutFile)) {
    Copy-Item -Path $fightsSourcePath -Destination $fightsOutFile
}

# Fetches one events view (healing or casts) for this character for one fight, annotates
# each event with resolved source/target names, and saves it with a small summary header.
# Returns $true on success, $false on failure (network/parse error - NOT "zero events",
# which is a legitimate result, e.g. a fight where the character cast nothing of that type).
function Get-CharacterEvents {
    param(
        [string]$View,        # "healing" or "casts"
        [string]$OutFile,
        [int]$StartTime,
        [int]$EndTime,
        [string]$FightLabel   # for console messages only
    )
    if (Test-Path $OutFile) { return $true }

    $url = "$baseUrl/report/events/$View/$ReportCode`?start=$StartTime&end=$EndTime&sourceid=$CharacterID&api_key=$apiKey"
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
        $data = $resp.Content | ConvertFrom-Json
    } catch {
        Write-Host "  $FightLabel - FAILED ($View events): $_"
        return $false
    }

    $events = @($data.events)
    foreach ($ev in $events) {
        $ev | Add-Member -NotePropertyName "sourceName" -NotePropertyValue (Resolve-ActorName $ev.sourceID) -Force
        $ev | Add-Member -NotePropertyName "targetName" -NotePropertyValue (Resolve-ActorName $ev.targetID) -Force
    }

    # -ErrorAction SilentlyContinue on these two: Measure-Object throws a hard error
    # (not just an empty result) when NONE of the input objects have the requested
    # property at all - which is exactly the case for "casts" events, since cast-type
    # events don't carry amount/overheal the way heal-type events do. SilentlyContinue
    # here means "no such property anywhere" resolves to $null -> falls through to the
    # 0 default below, instead of killing the whole script (this script sets
    # $ErrorActionPreference = "Stop" globally, which otherwise promotes even this into
    # a terminating error).
    $totalAmount = ($events | Measure-Object -Property amount -Sum -ErrorAction SilentlyContinue).Sum
    if ($null -eq $totalAmount) { $totalAmount = 0 }
    $totalOverheal = ($events | Measure-Object -Property overheal -Sum -ErrorAction SilentlyContinue).Sum
    if ($null -eq $totalOverheal) { $totalOverheal = 0 }

    $out = [PSCustomObject]@{
        sourceID      = $CharacterID
        sourceName    = $CharacterName
        view          = $View
        eventCount    = $events.Count
        totalAmount   = $totalAmount
        totalOverheal = $totalOverheal
        events        = $events
    }

    # [System.IO.File]::WriteAllText with an explicit UTF8Encoding($false), not
    # Set-Content -Encoding UTF8 - on Windows PowerShell 5.1, -Encoding UTF8 always
    # prepends a byte-order-mark (BOM), unlike every other file this script writes
    # (which go through Invoke-WebRequest -OutFile and are BOM-free, matching the raw
    # API response). The BOM doesn't corrupt the character data itself, but it's
    # inconsistent with the rest of the pipeline and breaks strict JSON parsers that
    # don't expect one (caught by cross-checking the real output with a plain
    # json.load() - PowerShell's own ConvertFrom-Json tolerates a BOM silently, so this
    # was invisible from inside PowerShell itself).
    $jsonText = $out | ConvertTo-Json -Depth 15
    [System.IO.File]::WriteAllText($OutFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))

    # No documented pagination for this endpoint (confirmed against the real v1 swagger
    # spec), and a real 3983-event unfiltered test came back complete with no cutoff -
    # but that's not a guarantee for every fight. Flag anything suspiciously large so it
    # gets a manual look rather than silently trusted.
    if ($events.Count -ge 2900) {
        Write-Host "  $FightLabel - $View events: $($events.Count) (HIGH - verify this wasn't silently capped, see script header)"
    } else {
        Write-Host "  $FightLabel - $View events: $($events.Count), total=$totalAmount, overheal=$totalOverheal"
    }
    return $true
}

# ===== Buff uptime redesign (2026-07-11) =====
# The old `/report/tables/buffs/{code}?sourceclass=X&hostility=0` call was found to
# merge every player of that class in the fight into one flat list - not scoped to
# this character at all (confirmed on real data: a single file showed Moonkin Form +
# Dire Bear Form + Tree of Life simultaneously, three different specs' forms,
# impossible for one character). Replaced with two independently-validated pieces:
#
# 1. FLASK/ELIXIR + FOOD: these last ~1-2 hours, far longer than any single fight, so
#    "was it active when this pull started" is a reliable stand-in for "active the
#    whole fight." Pulled from the `combatantinfo` snapshot event (the one confirmed-
#    working flat, no-`{view}`-segment form of /report/events/) - its `auras` list
#    includes whatever buffs were already active at that moment, which covers
#    consumables drunk/eaten before the pull even started (something no apply/remove
#    event reconstruction could ever see, since the log has no record of anything
#    before it starts recording).
#
# 2. TREE OF LIFE: unlike flask/food, this visibly toggles mid-raid (confirmed on
#    real data: Danceswtrees dropped out of it during a kill to combo Nature's
#    Swiftness + Healing Touch), so a pull-start snapshot isn't enough - this one
#    needs real interval reconstruction from apply/remove events, pulled ONCE per
#    report (not per fight - cheaper, and the events naturally span fight boundaries
#    anyway) via /report/events/buffs/ with sourceid=, then intersected with each
#    fight's own time window. Two real findings shaped this:
#    - Tree of Life logs under TWO guids (33891, 34123) that always show 33891
#      paired with 34123, but 34123 ALSO fires constantly on its own in patterns that
#      don't match manual form-toggling (rapid apply/remove/refresh cycles within a
#      single fight). Only 33891 is used - empirically the trustworthy signal,
#      34123's exact meaning is unverified and it's excluded rather than guessed at.
#    - Real data has orphan `removebuff` events (no matching prior `applybuff`) more
#      than once in a report, not just at the very start. Only the FIRST event in the
#      whole report can be safely read as "was already active since report start" -
#      treating every later orphan the same way produced an impossible >100% uptime
#      when first tested. Later orphans are treated as a no-op instead.

$treeOfLifeGuid = 33891
$treeOfLifeIntervals = @()

function Get-TreeOfLifeIntervals {
    Write-Host "  Fetching report-wide Tree of Life buff events (guid $treeOfLifeGuid)..."
    $reportEndOffset = $fightsData.end - $fightsData.start
    $url = "$baseUrl/report/events/buffs/$ReportCode`?start=0&end=$reportEndOffset&sourceid=$CharacterID&api_key=$apiKey"
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
        $data = $resp.Content | ConvertFrom-Json
    } catch {
        Write-Host "  FAILED fetching report-wide buffs events - $_"
        return @()
    }

    $tolEvents = @($data.events | Where-Object { $_.ability.guid -eq $treeOfLifeGuid } | Sort-Object timestamp)

    $intervals = New-Object System.Collections.Generic.List[object]
    $active = $false
    $intervalStart = $null
    $isFirstEvent = $true
    foreach ($ev in $tolEvents) {
        if ($ev.type -eq "applybuff") {
            if (-not $active) {
                $intervalStart = $ev.timestamp
                $active = $true
            }
        } elseif ($ev.type -eq "removebuff") {
            if ($active) {
                $intervals.Add([PSCustomObject]@{ Start = $intervalStart; End = $ev.timestamp })
                $active = $false
            } elseif ($isFirstEvent) {
                $intervals.Add([PSCustomObject]@{ Start = 0; End = $ev.timestamp })
            }
            # else: later orphan remove - ignore, no reliable interpretation (see note above)
        }
        # refreshbuff: no-op, buff remains continuously active through a refresh
        $isFirstEvent = $false
    }
    if ($active) {
        $intervals.Add([PSCustomObject]@{ Start = $intervalStart; End = $reportEndOffset })
    }

    Write-Host "  Reconstructed $($intervals.Count) Tree of Life interval(s) from $($tolEvents.Count) raw events"
    return $intervals
}

function Get-TreeOfLifeUptimePct {
    param($Intervals, $FightStart, $FightEnd)
    $overlap = 0
    foreach ($iv in $Intervals) {
        $ovStart = [Math]::Max($iv.Start, $FightStart)
        $ovEnd = [Math]::Min($iv.End, $FightEnd)
        if ($ovEnd -gt $ovStart) { $overlap += ($ovEnd - $ovStart) }
    }
    $duration = $FightEnd - $FightStart
    if ($duration -le 0) { return 0 }
    return [math]::Round(($overlap / $duration) * 100, 1)
}

# Pulls the pull-start combatant snapshot for one fight and checks its auras list for
# an active flask/elixir and food buff. Returns $null on failure (not "no consumables"
# - that's a legitimate result with real flaskActive=$false/foodActive=$false).
function Get-ConsumablesSnapshot {
    param($StartTime, $EndTime, $FightLabel)
    # combatantinfo can fire BEFORE a fight's official start_time - confirmed on real
    # data: Kael'thas (fight 81, start_time=12858991) had zero combatantinfo events
    # inside its own window, but a real snapshot for this exact character existed at
    # timestamp=12825402, 33.6s earlier - likely logged when the raid engaged trash/
    # positioned near the encounter, before WCL's recorded pull began. Querying only
    # the fight's own [start,end] window missed it entirely. Search backward with a
    # generous buffer instead of assuming the snapshot falls inside the fight window.
    $bufferMs = 120000   # 2 minutes - comfortably covers the observed 33.6s real gap
    $queryStart = [Math]::Max(0, $StartTime - $bufferMs)
    $url = "$baseUrl/report/events/$ReportCode`?start=$queryStart&end=$EndTime&filter=type%3D%22combatantinfo%22&api_key=$apiKey"
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
        $data = $resp.Content | ConvertFrom-Json
    } catch {
        Write-Host "  $FightLabel - combatantinfo request FAILED (network/API error) - $_"
        return $null
    }
    $candidates = @($data.events | Where-Object { $_.sourceID -eq $CharacterID })
    if ($candidates.Count -eq 0) {
        Write-Host "  $FightLabel - combatantinfo request OK but found $($data.events.Count) total entries, NONE for sourceID=$CharacterID even with a $($bufferMs/1000)s backward buffer"
        return $null
    }

    # Pick whichever candidate is CLOSEST to the fight's actual start (before or
    # after), not just "the latest one before start" - sub-second timing noise (a
    # snapshot logged a few ms after start_time due to event-ordering, not a real
    # data gap) shouldn't be treated the same as a snapshot that's genuinely late.
    # Only warn when the closest candidate is more than 2s after start; anything
    # closer (before OR slightly after) is treated as a normal, expected match.
    $closest = $candidates | Sort-Object { [Math]::Abs($_.timestamp - $StartTime) } | Select-Object -First 1
    $gapMs = $closest.timestamp - $StartTime
    if ($gapMs -gt 2000) {
        $gapS = [math]::Round($gapMs / 1000, 1)
        Write-Host "  $FightLabel - WARNING: closest combatantinfo snapshot is ${gapS}s AFTER fight start - no earlier snapshot found even with the backward buffer (consumable status may not reflect the true pull-start state)"
    } elseif ($gapMs -lt -1000) {
        $gapS = [math]::Round((-$gapMs) / 1000, 1)
        Write-Host "  $FightLabel - combatantinfo snapshot found ${gapS}s before official fight start (using it - this is expected, see script header)"
    }
    # else: within +/-1s of fight start - close enough to be unremarkable, no log line
    $entry = $closest

    if (-not $entry.auras) {
        Write-Host "  $FightLabel - combatantinfo entry found for sourceID=$CharacterID but it has no auras field"
        return $null
    }

    $flask = $entry.auras | Where-Object { $_.name -match 'Flask|Elixir' } | Select-Object -First 1
    $food = $entry.auras | Where-Object { $_.name -eq 'Well Fed' } | Select-Object -First 1

    return [PSCustomObject]@{
        flaskActive = [bool]$flask
        flaskName   = if ($flask) { $flask.name } else { $null }
        foodActive  = [bool]$food
        foodName    = if ($food) { $food.name } else { $null }
    }
}



# ===== STEP 4: Pull healing/casts events, consumables snapshot, deaths per boss kill =====
Write-Host "=== Step 2: Fight data per boss kill (healing events, casts events, consumables, deaths) ==="

if ($CharacterID) {
    $treeOfLifeIntervals = Get-TreeOfLifeIntervals
}

if (-not $CharacterID) {
    Write-Host "  SKIPPED - no report-local actor ID for '$CharacterName' (see warning above)."
    $bossFights = @()
} else {
    $bossFights = $fightsData.fights | Where-Object { $_.boss -ne 0 -and $_.kill -eq $true }
}

if ($CharacterID -and (-not $bossFights -or $bossFights.Count -eq 0)) {
    Write-Host "  No boss kills (boss != 0 && kill == true) found in this report - nothing to pull here."
} elseif ($CharacterID) {
    Write-Host "  $($bossFights.Count) boss kill(s) found."
}

$totalDone = 0
$totalFailed = 0

foreach ($fight in $bossFights) {
    $fightIDPadded = "{0:D2}" -f $fight.id
    $slug = Get-BossSlug $fight.boss $fight.name
    $label = "fight$($fightIDPadded)_$($slug)"
    $fightOk = $true

    # --- healing events (replaces the truncated healing TABLE) ---
    $healingOutFile = Join-Path $outDir "$($label)_healing_events.json"
    if (-not (Get-CharacterEvents -View "healing" -OutFile $healingOutFile -StartTime $fight.start_time -EndTime $fight.end_time -FightLabel $label)) {
        $fightOk = $false
    }
    Start-Sleep -Milliseconds 250

    # --- casts events (replaces the truncated casts TABLE, now with real targets) ---
    $castsOutFile = Join-Path $outDir "$($label)_casts_events.json"
    if (-not (Get-CharacterEvents -View "casts" -OutFile $castsOutFile -StartTime $fight.start_time -EndTime $fight.end_time -FightLabel $label)) {
        $fightOk = $false
    }
    Start-Sleep -Milliseconds 250

    # --- consumables (flask/food snapshot + Tree of Life uptime, replaces the broken
    #     buffs table - see the redesign note above Get-TreeOfLifeIntervals for why) ---
    $consumablesOutFile = Join-Path $outDir "$($label)_consumables.json"
    if (-not (Test-Path $consumablesOutFile)) {
        $snapshot = Get-ConsumablesSnapshot -StartTime $fight.start_time -EndTime $fight.end_time -FightLabel $label
        if ($null -eq $snapshot) {
            Write-Host "  $($label)_consumables.json - FAILED (combatantinfo snapshot)"
            $fightOk = $false
        } else {
            $treeOfLifePct = Get-TreeOfLifeUptimePct -Intervals $treeOfLifeIntervals -FightStart $fight.start_time -FightEnd $fight.end_time
            $out = [PSCustomObject]@{
                flaskActive        = $snapshot.flaskActive
                flaskName          = $snapshot.flaskName
                foodActive         = $snapshot.foodActive
                foodName           = $snapshot.foodName
                treeOfLifeUptimePct = $treeOfLifePct
            }
            $jsonText = $out | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText($consumablesOutFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
            Write-Host "  $($label)_consumables.json - OK (flask=$($snapshot.flaskActive) food=$($snapshot.foodActive) treeOfLife=$treeOfLifePct%)"
        }
        Start-Sleep -Milliseconds 250
    }

    # --- deaths (table view, fight-wide, not class-scoped - unchanged) ---
    $deathsOutFile = Join-Path $outDir "$($label)_deaths.json"
    if (-not (Test-Path $deathsOutFile)) {
        $deathsUrl = "$baseUrl/report/tables/deaths/$ReportCode`?start=$($fight.start_time)&end=$($fight.end_time)&api_key=$apiKey"
        try {
            Invoke-WebRequest -Uri $deathsUrl -OutFile $deathsOutFile -UseBasicParsing
            Write-Host "  $($label)_deaths.json - OK"
        } catch {
            Write-Host "  $($label)_deaths.json - FAILED: $_"
            # not counted against $fightOk - deaths isn't a per-healer data point
        }
        Start-Sleep -Milliseconds 250
    }

    if ($fightOk) { $totalDone++ } else { $totalFailed++ }
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
        Invoke-WebRequest -Uri $parsesUrl -OutFile $parsesOutFile -UseBasicParsing
        Write-Host "  $($safeCharName)_all_parses.json - OK"
    } catch {
        Write-Host "  $($safeCharName)_all_parses.json - FAILED: $_"
        $totalFailed++
    }
}

Write-Host ""
Write-Host "=================================="
Write-Host "Done. Output: $outDir"
Write-Host "  Boss kills fully pulled (healing+casts+consumables+deaths ok): $totalDone"
Write-Host "  Boss kills with at least one failed pull:                $totalFailed"
