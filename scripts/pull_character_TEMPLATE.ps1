# pull_character_TEMPLATE.ps1
#
# v2 GraphQL pull (migrated from v1 REST 2026-07-12 - see the approved migration
# plan, C:\Users\raymo\.claude\plans\playful-baking-sunset.md, for the full
# rationale). The old v1 script is preserved as pull_character_TEMPLATE_v1.ps1 for
# reference/rollback - this one passed a full equivalence check against a real,
# already-pulled character+report (Danceswtrees, report Fm9XdWYtz8VCLnwg, all 9
# boss kills byte-for-byte matched on every event/consumables/gear/activetime/
# deaths field build_boss_report_data.ps1 actually reads) before taking over the
# production filename.
#
# WHY THIS MIGRATION (short version - see the plan file for the full writeup):
# v1's only percentile sources (/parses/character/, /rankings/character/) return
# either an incomplete "notable parses" list or a single personal-best entry -
# neither can answer "what was this exact report+fight's percentile," which is
# structurally why 8 of 9 kills in a real report came back with null percentile
# even after a fresh re-pull. v2's reportData.report(code).rankings(fightIDs:[...])
# answers that exactly, confirmed live against real data this session.
#
# Every other v1 call this script made also has a confirmed, live-tested v2
# equivalent (see WclV2Api.psm1 and the plan file's mapping table). All output
# FILE SHAPES are preserved exactly as v1 produced them, so build_boss_report_data.ps1
# needs no changes except where it reads percentile from (see step 5 below) -
# confirmed via grep that it only reads $fightsData.fights[].boss/.kill/.start_time/
# .end_time (not the old friendlies/enemies/pets split), so the flat v2 actors[]
# list is a safe, real simplification there, not a compatibility risk.
#
# Auth: v2_client_id.txt / v2_client_secret.txt / v2_access_token.txt at repo
# root (gitignored, same convention as apikey.txt) - see WclV2Api.psm1's header
# for how to register a client if these don't exist yet.
#
# Result (SAME shape as v1): data\Characters\{CharacterName}\{date}\
#           fights_{reportCode}.json          <- reshaped to v1's field names (see Step 1)
#           fight{fightID}_{bossSlug}_healing_events.json   <- one per boss kill
#           fight{fightID}_{bossSlug}_casts_events.json
#           fight{fightID}_{bossSlug}_consumables.json
#           fight{fightID}_{bossSlug}_gear.json
#           fight{fightID}_{bossSlug}_activetime.json
#           fight{fightID}_{bossSlug}_deaths.json
#           {reportCode}_v2_rankings.json     <- NEW: replaces {charactername}_all_parses.json
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File pull_character_TEMPLATE.ps1 -ReportCode "XJp8vAxzM4KtHYyb" -CharacterName "Crowns"
#   powershell -ExecutionPolicy Bypass -File pull_character_TEMPLATE.ps1 -ReportCode "XJp8vAxzM4KtHYyb" -CharacterName "Crowns" -MaxThreads 5

param(
    [Parameter(Mandatory=$true)][string]$ReportCode,
    [Parameter(Mandatory=$true)][string]$CharacterName,
    [string]$Server,        # optional override - only matters if the character isn't in this report
    [string]$Region,        # optional override - only matters if the character isn't in this report
    [string]$Class,         # optional override - only matters if the character isn't in this report
    [string]$DateOverride,  # optional override - only used if the date can't be parsed from the report title
    [int]$MaxThreads = 10,  # per-boss-kill pulls run concurrently, bounded by this
    [string]$CharactersRoot = "data\Characters"  # override for equivalence-testing into a scratch folder without
                                                  # relocating apikey/v2 credential files (which stay repo-root-relative)
)

$ErrorActionPreference = "Stop"
$charactersRoot = $CharactersRoot

Import-Module (Join-Path $PSScriptRoot "lib\WclV2Api.psm1") -Force

# ===== Resolve report code from a bare code or a full report URL =====
if ($ReportCode -match "warcraftlogs\.com/reports/([A-Za-z0-9]+)") {
    $ReportCode = $Matches[1]
}

Write-Host "Running with -MaxThreads $MaxThreads (default 10 - lower this if you see rate-limit failures)"
$token = Get-WclAccessToken
Write-Host ""

# ===== SSC/TK encounter ID -> boss-file slug (unchanged from v1) =====
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
    return ($bossName.ToLower() -replace '[^a-z0-9]', '')
}

# ===== STEP 1: Get the fight list - reuse a cached copy from ANY character's folder if one exists =====
# Same cross-character caching as v1. The saved file's shape is reshaped to v1's
# field names (fights[].boss/.kill/.start_time/.end_time, snake_case) since that's
# exactly and only what build_boss_report_data.ps1 reads (confirmed via grep) -
# the old friendlies/enemies/friendlyPets/enemyPets 4-way split is replaced by one
# flat `actors[]` list (v2's own model - ReportActor doesn't carry a
# friendly/hostile flag at all, and nothing downstream ever used that split
# either), used only to rebuild $actorNames on a cache-hit.
Write-Host "=== Step 1: Fight list for report $ReportCode ==="

$cachedFightsFile = $null
if (Test-Path $charactersRoot) {
    $cachedFightsFile = Get-ChildItem -Path $charactersRoot -Recurse -Filter "fights_$ReportCode.json" -ErrorAction SilentlyContinue | Select-Object -First 1
}

if ($cachedFightsFile) {
    Write-Host "  Found cached fights file: $($cachedFightsFile.FullName) - reusing, not re-fetching."
    $fightsData = Get-Content $cachedFightsFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    Write-Host "  Not cached anywhere yet - fetching from the API..."
    $reportQuery = @"
query {
  reportData {
    report(code: "$ReportCode") {
      title
      startTime
      endTime
      region { compactName }
      fights { id encounterID name kill startTime endTime }
      masterData { actors { id name type subType server } }
    }
  }
}
"@
    $reportResult = Invoke-WclGraphQL -Query $reportQuery -AccessToken $token
    if ($reportResult.Errors) {
        Write-Host "ERROR: failed to fetch fight list for $ReportCode`: $($reportResult.Errors | ConvertTo-Json -Compress)"
        Write-Host "       (This usually means the report is private - the owner needs to make it public.)"
        exit 1
    }
    $report = $reportResult.Data.reportData.report
    if (-not $report) {
        Write-Host "ERROR: report $ReportCode returned no data - check the code is correct and the report is public."
        exit 1
    }

    $reshapedFights = @($report.fights | ForEach-Object {
        [PSCustomObject]@{
            id         = $_.id
            boss       = $_.encounterID
            name       = $_.name
            kill       = $_.kill
            start_time = [int64]$_.startTime
            end_time   = [int64]$_.endTime
        }
    })
    $reshapedActors = @($report.masterData.actors | ForEach-Object {
        [PSCustomObject]@{
            id     = $_.id
            name   = $_.name
            type   = $_.type
            subType = $_.subType
            server = $_.server
        }
    })
    $fightsData = [PSCustomObject]@{
        title  = $report.title
        start  = [int64]$report.startTime
        end    = [int64]$report.endTime
        region = $report.region.compactName
        fights = $reshapedFights
        actors = $reshapedActors
    }
}

# Build a report-local actor ID -> name lookup, used to annotate raw sourceID/targetID
# fields on events with real names before saving. v2's actors[] list already
# covers players, NPCs, AND pets in one flat list (unlike v1's 4-way split) -
# events can target any of these (e.g. Innervate targets a player, a boss debuff-cast
# targets an NPC add, a pet heal targets a pet).
$actorNames = @{}
foreach ($actor in $fightsData.actors) {
    if ($actor.id -ne $null) { $actorNames[[int]$actor.id] = $actor.name }
}

function Resolve-ActorName($id) {
    if ($id -eq $null) { return $null }
    $key = [int]$id
    if ($actorNames.ContainsKey($key)) { return $actorNames[$key] }
    return "Unknown_$key"
}

# ===== STEP 2: Determine the raid date from the report title (unchanged from v1) =====
$raidDate = $null
if ($DateOverride) {
    $raidDate = $DateOverride
} elseif ($fightsData.title -match "(\d{1,2})\.(\d{1,2})\.(\d{4})") {
    $month = $Matches[1].PadLeft(2, '0')
    $day = $Matches[2].PadLeft(2, '0')
    $year = $Matches[3]
    $raidDate = "$year-$month-$day"
} elseif ($fightsData.start) {
    $raidDate = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$fightsData.start).UtcDateTime.ToString("yyyy-MM-dd")
    Write-Host "  WARNING: couldn't parse a date out of the report title ('$($fightsData.title)') - derived $raidDate from the report's start timestamp instead. Pass -DateOverride if this is wrong."
} else {
    Write-Host "ERROR: could not determine the raid date from the report title or start time. Pass -DateOverride 'YYYY-MM-DD' explicitly."
    exit 1
}
Write-Host "  Raid date: $raidDate"

# ===== STEP 3: Resolve class/server/region/ID from the actors list =====
# v2's ReportActor.subType is the class name (equivalent to v1 friendlies[].type);
# region isn't a per-actor field in v2's model (report-wide instead), so it comes
# from $fightsData.region (captured from report.region.compactName above).
$friendly = $fightsData.actors | Where-Object { $_.name -eq $CharacterName -and $_.type -eq "Player" } | Select-Object -First 1
$CharacterID = $null

if ($friendly) {
    if (-not $Class)  { $Class  = $friendly.subType }
    if (-not $Server) { $Server = $friendly.server }
    if (-not $Region) { $Region = $fightsData.region }
    $CharacterID = $friendly.id
    Write-Host "  Found '$CharacterName' in actors[]: $Class, $Server-$Region, report-local id=$CharacterID"
} else {
    if (-not $Class -or -not $Server -or -not $Region) {
        Write-Host "ERROR: '$CharacterName' was not found in this report's actors[] list."
        Write-Host "       Re-run with -Class, -Server, and -Region supplied explicitly if this character"
        Write-Host "       genuinely isn't in this report (e.g. resolving them from a different raid)."
        exit 1
    }
    Write-Host "  '$CharacterName' not in actors[] - using supplied overrides: $Class, $Server-$Region"
    Write-Host "  WARNING: no report-local actor ID available for '$CharacterName' - Step 4 (fight-level"
    Write-Host "           healing/casts/buffs/deaths pulls) will be SKIPPED. Only Step 5 (rankings) will run."
    Write-Host "           This is expected if the character truly isn't in this report."
}

# ===== Set up output folder =====
$outDir = Join-Path (Join-Path $charactersRoot $CharacterName) $raidDate
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Write-Host "  Output folder: $outDir"
Write-Host ""

$fightsOutFile = Join-Path $outDir "fights_$ReportCode.json"
if (-not (Test-Path $fightsOutFile)) {
    $jsonText = $fightsData | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($fightsOutFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
}

# Resolves an ability guid to its real display name, via gameData.ability(id) -
# cached so a re-seen guid within this run costs no extra API call. Ability NAME
# is genuinely load-bearing downstream (confirmed via grep of
# build_boss_report_data.ps1: populates the spell-composition table's Name field,
# AND matches Mana Potion casts by name rather than guid), so this isn't cosmetic -
# v2's events() only returns a flat abilityGameID by default, unlike v1's embedded
# ability{name,guid,type,abilityIcon} object, so this lookup is a required part of
# reconstructing the old shape, not an optional nicety.
$abilityNameCache = @{}
function Resolve-AbilityName($guid, $accessToken) {
    $key = [int]$guid
    if ($abilityNameCache.ContainsKey($key)) { return $abilityNameCache[$key] }
    $query = "query { gameData { ability(id: $key) { name icon } } }"
    $result = Invoke-WclGraphQL -Query $query -AccessToken $accessToken
    $name = $null
    $icon = $null
    if (-not $result.Errors -and $result.Data.gameData.ability) {
        $name = $result.Data.gameData.ability.name
        $icon = $result.Data.gameData.ability.icon
    }
    $entry = [PSCustomObject]@{ Name = $name; Icon = $icon }
    $abilityNameCache[$key] = $entry
    return $entry
}

# ===== Buff uptime redesign (unchanged rationale from v1 - see WORKFLOW.md) =====
# v2 equivalent of /report/events/buffs/{code}?sourceid=: same events() field,
# dataType: Buffs, scoped by startTime/endTime only (no fightIDs) - confirmed live
# this returns the full report-wide buff history (3504 total events, 55 of them
# Tree of Life guid 33891 for a real report - matches the v1 pull's own count
# exactly). Wrapped in the paginated helper for safety on longer raid nights, even
# though a single page covered every real case tested so far.
$treeOfLifeGuid = 33891
$treeOfLifeIntervals = @()

function Get-TreeOfLifeIntervals {
    Write-Host "  Fetching report-wide Tree of Life buff events (guid $treeOfLifeGuid)..."
    $reportEndOffset = $fightsData.end - $fightsData.start
    # .GetNewClosure() is required here: Invoke-WclGraphQLPaged invokes this
    # scriptblock via `& $QueryBuilder` from ITS OWN function scope (inside the
    # imported module) - PowerShell's dynamic scoping means a scriptblock invoked
    # from a different function's scope can't see the DEFINING function's own
    # local variables ($reportEndOffset here) unless they're bound at creation
    # time. $ReportCode/$CharacterID happen to be script-scope (visible from
    # anywhere), but $reportEndOffset is local to this function - without
    # GetNewClosure() it silently resolves to $null, producing a malformed query
    # that returns zero events with no visible error (confirmed the hard way).
    $queryBuilder = {
        param($startTime)
        "query { reportData { report(code: `"$ReportCode`") { events(sourceID: $CharacterID, dataType: Buffs, startTime: $startTime, endTime: $reportEndOffset) { data nextPageTimestamp } } } }"
    }.GetNewClosure()
    $extractPage = {
        param($data)
        [PSCustomObject]@{
            Items = @($data.reportData.report.events.data)
            NextPageTimestamp = $data.reportData.report.events.nextPageTimestamp
        }
    }
    $paged = Invoke-WclGraphQLPaged -QueryBuilder $queryBuilder -ExtractPage $extractPage -AccessToken $token
    if ($paged.Errors) {
        Write-Host "  FAILED fetching report-wide buffs events - $($paged.Errors | ConvertTo-Json -Compress)"
        return @()
    }

    $tolEvents = @($paged.Items | Where-Object { $_.abilityGameID -eq $treeOfLifeGuid } | Sort-Object timestamp)

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
        }
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

# Self-contained per-boss-kill worker (same isolated-runspace pattern as v1 -
# everything it needs is passed in as an argument, since a RunspacePool worker
# does NOT inherit the parent session's Import-Module - the module is
# re-imported by absolute path as the very first thing this scriptblock does).
$workerScript = {
    param(
        $fightID, $bossSlug, $startTime, $endTime, $reportCode,
        $characterID, $characterName, $actorNames, $treeOfLifeIntervals, $outDir,
        $accessToken, $moduleAbsolutePath, $abilityNameCacheShared
    )

    Import-Module $moduleAbsolutePath -Force

    $fightIDPadded = "{0:D2}" -f $fightID
    $label = "fight$($fightIDPadded)_$($bossSlug)"

    $result = [PSCustomObject]@{
        Ok = $true
        Messages = New-Object System.Collections.Generic.List[string]
    }

    function Resolve-ActorNameLocal($id) {
        if ($id -eq $null) { return $null }
        $key = [int]$id
        if ($actorNames.ContainsKey($key)) { return $actorNames[$key] }
        return "Unknown_$key"
    }

    # Local ability-name cache, NOT shared across worker threads (each runspace is
    # isolated) - some redundant gameData.ability lookups across workers for
    # spells common to every boss (e.g. Lifebloom) are expected and cheap (a
    # handful of extra tiny queries per full character pull), traded for not
    # needing cross-thread-safe shared state for something this low-cost.
    $localAbilityCache = @{}
    function Resolve-AbilityNameLocal($guid) {
        $key = [int]$guid
        if ($localAbilityCache.ContainsKey($key)) { return $localAbilityCache[$key] }
        $q = "query { gameData { ability(id: $key) { name icon } } }"
        $r = Invoke-WclGraphQL -Query $q -AccessToken $accessToken
        $entry = [PSCustomObject]@{ Name = $null; Icon = $null }
        if (-not $r.Errors -and $r.Data.gameData.ability) {
            $entry.Name = $r.Data.gameData.ability.name
            $entry.Icon = $r.Data.gameData.ability.icon
        }
        $localAbilityCache[$key] = $entry
        return $entry
    }

    # Fetches one events view (healing or casts) for this character for one fight,
    # reshaping each v2 event back into v1's shape (ability{guid,name,abilityIcon}
    # instead of a flat abilityGameID) before saving, so build_boss_report_data.ps1
    # needs zero changes to read these files.
    function Get-EventsLocal {
        param($DataType, $OutFile)
        if (Test-Path $OutFile) { return $true }

        # .GetNewClosure() required - see the identical note above
        # Get-TreeOfLifeIntervals's queryBuilder. Without it, $reportCode/
        # $fightID/$DataType/$endTime (all local to Get-EventsLocal/the worker
        # scriptblock, not script-scope) resolve to $null when this block is
        # invoked from inside Invoke-WclGraphQLPaged's own function scope -
        # confirmed live: every fight's healing/casts events came back as 0
        # with no error before this fix was applied.
        $queryBuilder = {
            param($pageStartTime)
            "query { reportData { report(code: `"$reportCode`") { events(fightIDs: [$fightID], sourceID: $characterID, dataType: $DataType, includeResources: true, startTime: $pageStartTime, endTime: $endTime) { data nextPageTimestamp } } } }"
        }.GetNewClosure()
        $extractPage = {
            param($data)
            [PSCustomObject]@{
                Items = @($data.reportData.report.events.data)
                NextPageTimestamp = $data.reportData.report.events.nextPageTimestamp
            }
        }
        $paged = Invoke-WclGraphQLPaged -QueryBuilder $queryBuilder -ExtractPage $extractPage -AccessToken $accessToken -InitialStartTime $startTime
        if ($paged.Errors) {
            $result.Messages.Add("  $label - FAILED ($DataType events): $($paged.Errors | ConvertTo-Json -Compress)")
            return $false
        }

        # $paged.Items is already a plain array (see WclV2Api.psm1's .ToArray()
        # note) - safe to wrap with @() here since it's no longer a List[object].
        $events = @($paged.Items)
        foreach ($ev in $events) {
            $srcName = Resolve-ActorNameLocal $ev.sourceID
            $tgtName = if ($ev.targetID -ne $null) { Resolve-ActorNameLocal $ev.targetID } else { $srcName }
            $abilityInfo = Resolve-AbilityNameLocal $ev.abilityGameID
            $ev | Add-Member -NotePropertyName "sourceName" -NotePropertyValue $srcName -Force
            $ev | Add-Member -NotePropertyName "targetName" -NotePropertyValue $tgtName -Force
            $ev | Add-Member -NotePropertyName "ability" -NotePropertyValue ([PSCustomObject]@{
                name        = $abilityInfo.Name
                guid        = $ev.abilityGameID
                abilityIcon = $abilityInfo.Icon
            }) -Force
        }

        $totalAmount = ($events | Measure-Object -Property amount -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $totalAmount) { $totalAmount = 0 }
        $totalOverheal = ($events | Measure-Object -Property overheal -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $totalOverheal) { $totalOverheal = 0 }

        $viewName = $DataType.ToLower()
        $out = [PSCustomObject]@{
            sourceID      = $characterID
            sourceName    = $characterName
            view          = $viewName
            eventCount    = $events.Count
            totalAmount   = $totalAmount
            totalOverheal = $totalOverheal
            events        = $events
        }
        $jsonText = $out | ConvertTo-Json -Depth 15
        [System.IO.File]::WriteAllText($OutFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
        if ($paged.PageCount -gt 1) {
            $result.Messages.Add("  $label - $viewName events: $($events.Count) across $($paged.PageCount) pages, total=$totalAmount, overheal=$totalOverheal")
        } else {
            $result.Messages.Add("  $label - $viewName events: $($events.Count), total=$totalAmount, overheal=$totalOverheal")
        }
        return $true
    }

    # combatantinfo snapshot - v2 equivalent of the filter=type%3D%22combatantinfo%22
    # events() call, dataType: CombatantInfo. Same 120s backward-buffer search as
    # v1 (combatantinfo can fire before a fight's official start_time).
    function Get-CombatantInfoSnapshotLocal {
        $bufferMs = 120000
        $queryStart = [Math]::Max(0, $startTime - $bufferMs)
        $q = "query { reportData { report(code: `"$reportCode`") { events(dataType: CombatantInfo, startTime: $queryStart, endTime: $endTime) { data } } } }"
        $r = Invoke-WclGraphQL -Query $q -AccessToken $accessToken
        if ($r.Errors) {
            $result.Messages.Add("  $label - combatantinfo request FAILED (network/API error) - $($r.Errors | ConvertTo-Json -Compress)")
            return $null
        }
        $allEvents = @($r.Data.reportData.report.events.data)
        $candidates = @($allEvents | Where-Object { $_.sourceID -eq $characterID })
        if ($candidates.Count -eq 0) {
            $result.Messages.Add("  $label - combatantinfo request OK but found $($allEvents.Count) total entries, NONE for sourceID=$characterID even with a $($bufferMs/1000)s backward buffer")
            return $null
        }
        $closest = $candidates | Sort-Object { [Math]::Abs($_.timestamp - $startTime) } | Select-Object -First 1
        $gapMs = $closest.timestamp - $startTime
        if ($gapMs -gt 2000) {
            $gapS = [math]::Round($gapMs / 1000, 1)
            $result.Messages.Add("  $label - WARNING: closest combatantinfo snapshot is ${gapS}s AFTER fight start - no earlier snapshot found even with the backward buffer (consumable/gear status may not reflect the true pull-start state)")
        } elseif ($gapMs -lt -1000) {
            $gapS = [math]::Round((-$gapMs) / 1000, 1)
            $result.Messages.Add("  $label - combatantinfo snapshot found ${gapS}s before official fight start (using it - this is expected, see script header)")
        }
        if (-not $closest.auras -and -not $closest.gear) {
            $result.Messages.Add("  $label - combatantinfo entry found for sourceID=$characterID but it has neither auras nor gear fields")
            return $null
        }
        return $closest
    }

    function Get-TreeOfLifeUptimePctLocal {
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

    $fightOk = $true

    $healingOutFile = Join-Path $outDir "$($label)_healing_events.json"
    if (-not (Get-EventsLocal -DataType "Healing" -OutFile $healingOutFile)) { $fightOk = $false }

    $castsOutFile = Join-Path $outDir "$($label)_casts_events.json"
    if (-not (Get-EventsLocal -DataType "Casts" -OutFile $castsOutFile)) { $fightOk = $false }

    $consumablesOutFile = Join-Path $outDir "$($label)_consumables.json"
    $gearOutFile = Join-Path $outDir "$($label)_gear.json"
    $needsConsumables = -not (Test-Path $consumablesOutFile)
    $needsGear = -not (Test-Path $gearOutFile)
    if ($needsConsumables -or $needsGear) {
        $snapshot = Get-CombatantInfoSnapshotLocal
        if ($null -eq $snapshot) {
            $result.Messages.Add("  $label - FAILED (combatantinfo snapshot unavailable for consumables/gear)")
            $fightOk = $false
        } else {
            if ($needsConsumables) {
                if (-not $snapshot.auras) {
                    $result.Messages.Add("  $($label)_consumables.json - FAILED (snapshot has no auras field)")
                    $fightOk = $false
                } else {
                    $flask = $snapshot.auras | Where-Object { $_.name -match 'Flask|Elixir' } | Select-Object -First 1
                    $food = $snapshot.auras | Where-Object { $_.name -eq 'Well Fed' } | Select-Object -First 1
                    $treeOfLifePct = Get-TreeOfLifeUptimePctLocal -Intervals $treeOfLifeIntervals -FightStart $startTime -FightEnd $endTime
                    $out = [PSCustomObject]@{
                        flaskActive        = [bool]$flask
                        flaskName          = if ($flask) { $flask.name } else { $null }
                        foodActive         = [bool]$food
                        foodName           = if ($food) { $food.name } else { $null }
                        treeOfLifeUptimePct = $treeOfLifePct
                    }
                    $jsonText = $out | ConvertTo-Json -Depth 5
                    [System.IO.File]::WriteAllText($consumablesOutFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
                    $result.Messages.Add("  $($label)_consumables.json - OK (flask=$([bool]$flask) food=$([bool]$food) treeOfLife=$treeOfLifePct%)")
                }
            }
            if ($needsGear) {
                if (-not $snapshot.gear) {
                    $result.Messages.Add("  $($label)_gear.json - FAILED (snapshot has no gear field)")
                    $fightOk = $false
                } else {
                    $gearOut = [PSCustomObject]@{
                        gear    = $snapshot.gear
                        talents = $snapshot.talents
                    }
                    $jsonText = $gearOut | ConvertTo-Json -Depth 8
                    [System.IO.File]::WriteAllText($gearOutFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
                    $filledCount = @($snapshot.gear | Where-Object { $_.id -and $_.id -ne 0 }).Count
                    $result.Messages.Add("  $($label)_gear.json - OK ($filledCount/$($snapshot.gear.Count) slots filled)")
                }
            }
        }
    }

    # active time - v2 table(dataType: Healing) - confirmed byte-identical field
    # names/values (activeTime, activeTimeReduced, total, overheal, itemLevel) to
    # v1's /report/tables/healing/ for the same real fight.
    $activeTimeOutFile = Join-Path $outDir "$($label)_activetime.json"
    if (-not (Test-Path $activeTimeOutFile)) {
        $atQuery = "query { reportData { report(code: `"$reportCode`") { table(fightIDs: [$fightID], dataType: Healing, startTime: $startTime, endTime: $endTime) } } }"
        $atResult = Invoke-WclGraphQL -Query $atQuery -AccessToken $accessToken
        if ($atResult.Errors) {
            $result.Messages.Add("  $($label)_activetime.json - FAILED: $($atResult.Errors | ConvertTo-Json -Compress)")
            $fightOk = $false
        } else {
            $atEntry = $atResult.Data.reportData.report.table.data.entries | Where-Object { $_.name -eq $characterName } | Select-Object -First 1
            if (-not $atEntry) {
                $result.Messages.Add("  $($label)_activetime.json - FAILED (no matching entry in healing table response)")
                $fightOk = $false
            } else {
                $duration = $endTime - $startTime
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
                $result.Messages.Add("  $($label)_activetime.json - OK (activeTime=$activeTimePct%)")
            }
        }
    }

    # deaths - v2 table(dataType: Deaths) - confirmed byte-identical entry shape
    # to v1's /report/tables/deaths/ (name,id,guid,type,timestamp,damage{},
    # healing{},deathWindow,overkill,events[],killingBlow) - saved as
    # .data straight from the response, no reshaping needed at all.
    $deathsOutFile = Join-Path $outDir "$($label)_deaths.json"
    if (-not (Test-Path $deathsOutFile)) {
        $deathsQuery = "query { reportData { report(code: `"$reportCode`") { table(fightIDs: [$fightID], dataType: Deaths, startTime: $startTime, endTime: $endTime) } } }"
        $deathsResult = Invoke-WclGraphQL -Query $deathsQuery -AccessToken $accessToken
        if ($deathsResult.Errors) {
            $result.Messages.Add("  $($label)_deaths.json - FAILED: $($deathsResult.Errors | ConvertTo-Json -Compress)")
        } else {
            $jsonText = $deathsResult.Data.reportData.report.table.data | ConvertTo-Json -Depth 12
            [System.IO.File]::WriteAllText($deathsOutFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
            $result.Messages.Add("  $($label)_deaths.json - OK")
        }
    }

    $result.Ok = $fightOk
    return $result
}

if ($bossFights -and $bossFights.Count -gt 0) {
    $moduleAbsolutePath = Join-Path $PSScriptRoot "lib\WclV2Api.psm1"
    Write-Host "  fetching $($bossFights.Count) boss kill(s) ($MaxThreads threads)..."
    $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $pool.Open()

    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($fight in $bossFights) {
        $slug = Get-BossSlug $fight.boss $fight.name
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($workerScript.ToString()).
            AddArgument($fight.id).
            AddArgument($slug).
            AddArgument($fight.start_time).
            AddArgument($fight.end_time).
            AddArgument($ReportCode).
            AddArgument($CharacterID).
            AddArgument($CharacterName).
            AddArgument($actorNames).
            AddArgument($treeOfLifeIntervals).
            AddArgument($outDir).
            AddArgument($token).
            AddArgument($moduleAbsolutePath).
            AddArgument($null)
        $handle = $ps.BeginInvoke()
        $jobs.Add([PSCustomObject]@{ Pipe = $ps; Handle = $handle })
    }

    foreach ($job in $jobs) {
        try {
            $result = $job.Pipe.EndInvoke($job.Handle)
            foreach ($msg in $result.Messages) { Write-Host $msg }
            if ($result.Ok) { $totalDone++ } else { $totalFailed++ }
        } catch {
            Write-Host "  Worker threw unexpectedly: $_"
            $totalFailed++
        } finally {
            $job.Pipe.Dispose()
        }
    }

    $pool.Close()
    $pool.Dispose()
}
Write-Host ""

# ===== STEP 5: Pull real per-fight rankings (REPLACES the old all_parses.json step) =====
# Old v1 approach pulled the character's ENTIRE parse history and fuzzy-matched by
# reportID+fightID - confirmed buggy/incomplete (only ~7 entries per encounter
# total, missing 8 of 9 kills in a real report even on a fresh re-pull with a
# stable connection). v2's report-scoped rankings(fightIDs:[...]) is exact by
# construction: every fight ID requested either has a healer entry in the
# response or it doesn't, no fuzzy matching against a separately-fetched blob at
# all. One call for the whole report, not one per boss kill.
Write-Host "=== Step 3: Real per-fight rankings for $CharacterName ==="
$rankingsOutFile = Join-Path $outDir "$($ReportCode)_v2_rankings.json"

if (Test-Path $rankingsOutFile) {
    Write-Host "  $($ReportCode)_v2_rankings.json - already have it, skipping"
} elseif (-not $bossFights -or $bossFights.Count -eq 0) {
    Write-Host "  No boss kills to look up rankings for - skipping."
} else {
    $fightIDList = ($bossFights | ForEach-Object { $_.id }) -join ','
    $rankingsQuery = "query { reportData { report(code: `"$ReportCode`") { rankings(fightIDs: [$fightIDList], playerMetric: hps) } } }"
    $rankingsResult = Invoke-WclGraphQL -Query $rankingsQuery -AccessToken $token
    if ($rankingsResult.Errors) {
        Write-Host "  $($ReportCode)_v2_rankings.json - FAILED: $($rankingsResult.Errors | ConvertTo-Json -Compress)"
        $totalFailed++
    } else {
        $jsonText = $rankingsResult.Data.reportData.report.rankings | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($rankingsOutFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "  $($ReportCode)_v2_rankings.json - OK ($($bossFights.Count) fight(s) looked up)"
    }
}

Write-Host ""
Write-Host "=================================="
Write-Host "Done. Output: $outDir"
Write-Host "  Boss kills fully pulled (healing+casts+consumables+deaths ok): $totalDone"
Write-Host "  Boss kills with at least one failed pull:                $totalFailed"
