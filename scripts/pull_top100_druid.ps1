# pull_top100_druid.ps1
#
# v2 GraphQL pull (migrated from v1 REST 2026-07-12 - see the approved migration
# plan, C:\Users\raymo\.claude\plans\playful-baking-sunset.md, for the full
# rationale, and pull_character_TEMPLATE.ps1's header for the Phase 1 writeup
# this reuses). The old v1 script is preserved as pull_top100_druid_v1.ps1 for
# reference/rollback - this one passed equivalence testing (a real 24-parse fetch
# for Hydross, 24/24 ok, byte-for-byte matching field values against v1's known-
# good output) before taking over the production filename.
#
# 2026-07-12 PERFORMANCE FIX (found while porting Shaman, Phase 3): the
# gameData.ability() name-resolution cache used to be a per-worker LOCAL
# hashtable, reset to empty every single parse (each parse runs in its own
# isolated RunspacePool worker). At this script's real scale (~100 parses per
# boss x 10 bosses) that meant every parse re-resolved the same handful of
# common ability guids via its own API call - up to tens of thousands of
# redundant gameData.ability() calls per full run, a real and significant
# contributor to v2 feeling slower than v1 despite v1 never needing this call
# at all (v1's raw REST response already embedded ability name/guid/icon
# directly in every event). Fixed by promoting it to a ConcurrentDictionary
# shared across the whole run, same pattern as $fightsCache/$actorNamesCache
# below. This same per-worker pattern is intentionally left alone in
# pull_character_TEMPLATE.ps1, where only ~9-10 workers run per character pull
# and the redundant-call cost is genuinely negligible at that scale.
#
# The active/archived diff model, manifest.json schema, and per-parse output file
# set are ALL UNCHANGED from v1 - only the API mechanics (auth + endpoint calls)
# are migrated. Every per-parse output file keeps its v1 shape exactly (confirmed
# field-by-field in Phase 1 against real data), so summarize_class_benchmarks.ps1
# needs zero changes to ITS OWN code - but see the rankings_{boss}.json note
# below for a real, non-obvious compatibility trap this migration had to avoid.
#
# WHAT ACTUALLY CHANGED FROM v1 (see WclV2Api.psm1 + the plan file for the full
# mapping table, all confirmed live against real data in Phase 1):
#   - /rankings/encounter/{id}?metric=hps&spec=&class= -> worldData.encounter(id)
#     .characterRankings(className, specName, metric, page). Page 1 returns the
#     same 100 entries, still pre-sorted by rank (array position = rank, same as
#     v1 - v2's list-level entries don't carry a populated per-entry rank field
#     either, confirmed live). v2's entries nest report code/fightID/hps under
#     `report.code`/`report.fightID`/`amount` instead of v1's flat
#     `reportID`/`fightID`/`total` - handled in-memory for the diff-key logic,
#     AND explicitly reshaped back to v1's flat field names before EVER being
#     written to `active\rankings_{boss}.json` (see the $reshapedForDisk comment
#     below). This second part is not optional: summarize_class_benchmarks.ps1
#     reads that file DIRECTLY (not just the manifest) and matches entries by
#     flat `.reportID`/`.fightID`/`.name` plus reads `.duration` for HPS -
#     confirmed by grep, and confirmed live that skipping this reshape produces
#     "no rankings entry matched" for every single parse.
#   - /report/fights/{code} -> reportData.report(code).fights(...) +
#     masterData.actors(...) (replaces the old friendlies/enemies/pets split -
#     nothing downstream ever used that split, confirmed via grep in Phase 1).
#   - /report/events/{healing,casts}/{code}?sourceid= -> paginated events(
#     dataType: Healing|Casts, includeResources: true) - ability name
#     reconstructed via gameData.ability(id) (cached per-parse), classResources
#     recovered via includeResources: true.
#   - /report/events/buffs/{code}?sourceid= -> events(dataType: Buffs), scoped to
#     just this one fight's window (unchanged from v1 - no report-wide
#     amortization benefit here, every parse is a different player).
#   - combatantinfo filter -> events(dataType: CombatantInfo).
#   - /report/tables/healing/{code}?sourceclass=Druid (activeTime only) ->
#     table(dataType: Healing, sourceClass: "Druid") - confirmed table() accepts
#     the same sourceClass filter arg as the v1 REST endpoint.
#   - /report/tables/deaths/{code} -> table(dataType: Deaths) - confirmed
#     byte-identical entry shape to v1, no reshaping needed.
#
# Auth: v2_client_id.txt / v2_client_secret.txt / v2_access_token.txt at repo
# root (gitignored) - see WclV2Api.psm1's header for setup if these don't exist.
#
# Usage (identical to v1):
#   powershell -ExecutionPolicy Bypass -File pull_top100_druid.ps1
#   powershell -ExecutionPolicy Bypass -File pull_top100_druid.ps1 -MaxThreads 5

param(
    [int]$MaxThreads = 10,
    [string]$ClassesRoot = "data\Classes"  # override for equivalence-testing into a scratch folder
)

Import-Module (Join-Path $PSScriptRoot "lib\WclV2Api.psm1") -Force

$classesRoot = $ClassesRoot
$className = "Druid"
$classID = 2
$specID = 4          # Restoration
$classDir = Join-Path $classesRoot $className
$activeDir = Join-Path $classDir "active"
$archivedDir = Join-Path $classDir "archived"
$manifestPath = Join-Path $classDir "manifest.json"
$today = Get-Date -Format "yyyy-MM-dd"
$nowIso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$token = Get-WclAccessToken
Write-Host "Running with -MaxThreads $MaxThreads (default 10 - lower this if you see rate-limit failures)"
Write-Host "Today: $today"
Write-Host ""

# boss name -> (rankings filename, encounter ID). Gruul's Lair/Magtheridon's
# Lair bosses added 2026-07-15 (a separate, earlier raid tier from SSC/TK,
# zone 1048 vs. 1056 - see WORKFLOW.md's "v2 GraphQL API" section).
$bosses = [ordered]@{
    "Maulgar"     = @{ file = "rankings_maulgar.json";     encounterID = 50649 }
    "Gruul"       = @{ file = "rankings_gruul.json";       encounterID = 50650 }
    "Magtheridon" = @{ file = "rankings_magtheridon.json"; encounterID = 50651 }
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

# ===== Manifest load/save - unchanged from v1 ===== =====
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

# ===== Self-contained per-parse worker - v2 GraphQL version of the v1 worker.
# Same isolated-runspace pattern: everything it needs is passed in as an
# argument, including the module's absolute path (a RunspacePool worker does
# NOT inherit the parent session's Import-Module). =====
$workerScript = {
    param(
        $reportID, $fightID, $playerName, $i, $className,
        $outDir, $fightsCache, $actorNamesCache, $deathsClaimed, $abilityCache,
        $accessToken, $moduleAbsolutePath
    )

    Import-Module $moduleAbsolutePath -Force

    $result = [PSCustomObject]@{
        Ok = $true
        Messages = New-Object System.Collections.Generic.List[string]
        ReportID = $reportID
        FightID = $fightID
        PlayerName = $playerName
        SafeName = $null
    }

    # Shared ConcurrentDictionary across every parse in this run, NOT a
    # per-worker local hashtable (2026-07-12 fix - see this file's header dated
    # note). At Top-100 scale (~1000 parses/run) a per-worker cache meant every
    # single parse re-resolved the same handful of common ability guids
    # (Lifebloom, Regrowth, etc.) via its own gameData.ability() call - up to
    # tens of thousands of redundant API calls per full run, a real and
    # significant chunk of why a full pull was slower than expected. This same
    # per-worker pattern is still correct and intentionally left alone in
    # pull_character_TEMPLATE.ps1, where only ~9-10 workers run per character
    # pull and the redundant-call cost is genuinely negligible - only the
    # Top-100 scripts run at a scale where sharing this cache actually matters.
    function Resolve-AbilityNameLocal($guid) {
        $key = [int]$guid
        $cached = $null
        if ($abilityCache.TryGetValue($key, [ref]$cached)) { return $cached }
        $q = "query { gameData { ability(id: $key) { name icon } } }"
        $r = Invoke-WclGraphQL -Query $q -AccessToken $accessToken
        $entry = [PSCustomObject]@{ Name = $null; Icon = $null }
        if (-not $r.Errors -and $r.Data.gameData.ability) {
            $entry.Name = $r.Data.gameData.ability.name
            $entry.Icon = $r.Data.gameData.ability.icon
        }
        [void]$abilityCache.TryAdd($key, $entry)
        return $entry
    }

    # Fetches one events view (healing or casts) for this parse, reshaping each
    # v2 event back into v1's shape (ability{guid,name,abilityIcon} instead of a
    # flat abilityGameID) so summarize_class_benchmarks.ps1 needs zero changes.
    function Get-EventsLocal {
        param($View, $OutFile, $StartTime, $EndTime, $SourceID, $SourceName, $ActorNames)
        if (Test-Path $OutFile) { return $true }

        $dataType = if ($View -eq "healing") { "Healing" } else { "Casts" }
        # .GetNewClosure() required - see WclV2Api.psm1's Invoke-WclGraphQLPaged
        # header note (a scriptblock invoked via `&` from a DIFFERENT function's
        # scope can't see this function's own local variables otherwise - cost
        # real debugging time to trace in Phase 1, confirmed the fix here too).
        $queryBuilder = {
            param($pageStartTime)
            "query { reportData { report(code: `"$reportID`") { events(fightIDs: [$fightID], sourceID: $SourceID, dataType: $dataType, includeResources: true, startTime: $pageStartTime, endTime: $EndTime) { data nextPageTimestamp } } } }"
        }.GetNewClosure()
        $extractPage = {
            param($data)
            [PSCustomObject]@{
                Items = @($data.reportData.report.events.data)
                NextPageTimestamp = $data.reportData.report.events.nextPageTimestamp
            }
        }
        $paged = Invoke-WclGraphQLPaged -QueryBuilder $queryBuilder -ExtractPage $extractPage -AccessToken $accessToken -InitialStartTime $StartTime
        if ($paged.Errors) {
            $result.Messages.Add("[$i] FAILED $View events for $reportID/$fightID ($playerName) - $($paged.Errors | ConvertTo-Json -Compress)")
            return $false
        }

        $events = @($paged.Items)
        foreach ($ev in $events) {
            $srcName = if ($ActorNames.ContainsKey([int]$ev.sourceID)) { $ActorNames[[int]$ev.sourceID] } else { "Unknown_$($ev.sourceID)" }
            $tgtName = if ($ev.targetID -ne $null -and $ActorNames.ContainsKey([int]$ev.targetID)) { $ActorNames[[int]$ev.targetID] } else { if ($ev.targetID -ne $null) { "Unknown_$($ev.targetID)" } else { $srcName } }
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
        $reportQuery = "query { reportData { report(code: `"$reportID`") { fights { id startTime endTime } masterData { actors { id name } } } } }"
        $r = Invoke-WclGraphQL -Query $reportQuery -AccessToken $accessToken
        if ($r.Errors -or -not $r.Data.reportData.report) {
            $result.Ok = $false
            $result.Messages.Add("[$i] FAILED fetching report $reportID (fights list) - $($r.Errors | ConvertTo-Json -Compress)")
            return $result
        }
        $report = $r.Data.reportData.report
        $fd = [PSCustomObject]@{
            fights = @($report.fights | ForEach-Object { [PSCustomObject]@{ id = $_.id; start_time = [int64]$_.startTime; end_time = [int64]$_.endTime } })
        }
        [void]$fightsCache.TryAdd($reportID, $fd)

        $names = @{}
        foreach ($actor in $report.masterData.actors) {
            if ($actor.id -ne $null) { $names[[int]$actor.id] = $actor.name }
        }
        [void]$actorNamesCache.TryAdd($reportID, $names)

        # actors[] only carries id/name (no per-actor server/subType needed here,
        # unlike the character-pull script) - just enough to resolve the ranked
        # player's report-local ID and to annotate event source/target names.
        $actorLookupByName = @{}
        foreach ($actor in $report.masterData.actors) {
            if ($actor.name) { $actorLookupByName[$actor.name] = $actor.id }
        }
        [void]$fightsCache.TryAdd("$reportID|actorsByName", $actorLookupByName)
    }

    $fightsData = $fightsCache[$reportID]
    $fight = $fightsData.fights | Where-Object { $_.id -eq $fightID }
    if (-not $fight) {
        $result.Ok = $false
        $result.Messages.Add("[$i] SKIP: fight $fightID not found in report $reportID")
        return $result
    }

    $actorLookupByName = $fightsCache["$reportID|actorsByName"]
    if (-not $actorLookupByName.ContainsKey($playerName)) {
        $result.Ok = $false
        $result.Messages.Add("[$i] SKIP: '$playerName' not found in report $reportID actors[] (can't scope sourceID)")
        return $result
    }
    $playerID = $actorLookupByName[$playerName]
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
        $bufferMs = 120000
        $queryStart = [Math]::Max(0, $StartTime - $bufferMs)
        $q = "query { reportData { report(code: `"$reportID`") { events(dataType: CombatantInfo, startTime: $queryStart, endTime: $EndTime) { data } } } }"
        $r = Invoke-WclGraphQL -Query $q -AccessToken $accessToken
        if ($r.Errors) {
            $result.Messages.Add("[$i] FAILED combatantinfo for $reportID/$fightID ($playerName) - $($r.Errors | ConvertTo-Json -Compress)")
            return $null
        }
        $allEvents = @($r.Data.reportData.report.events.data)
        $candidates = @($allEvents | Where-Object { $_.sourceID -eq $SourceID })
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
        $treeOfLifeGuid = 33891
        $q = "query { reportData { report(code: `"$reportID`") { events(fightIDs: [$fightID], sourceID: $SourceID, dataType: Buffs, startTime: $StartTime, endTime: $EndTime) { data } } } }"
        $r = Invoke-WclGraphQL -Query $q -AccessToken $accessToken
        if ($r.Errors) {
            $result.Messages.Add("[$i] FAILED tree-of-life buffs events for $reportID/$fightID ($playerName) - $($r.Errors | ConvertTo-Json -Compress)")
            return $null
        }
        $tolEvents = @($r.Data.reportData.report.events.data | Where-Object { $_.abilityGameID -eq $treeOfLifeGuid } | Sort-Object timestamp)
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

    # active time - v2 table(dataType: Healing, sourceClass: Druid) - confirmed
    # byte-identical field names/values to v1's /report/tables/healing/ table.
    $activeTimeOutFile = Join-Path $outDir "$($reportID)_$($fightID)_$($safeName)_activetime.json"
    if (-not (Test-Path $activeTimeOutFile)) {
        $atQuery = "query { reportData { report(code: `"$reportID`") { table(fightIDs: [$fightID], dataType: Healing, sourceClass: `"$className`", startTime: $start, endTime: $end) } } }"
        $atResult = Invoke-WclGraphQL -Query $atQuery -AccessToken $accessToken
        if ($atResult.Errors) {
            $result.Messages.Add("[$i] FAILED activetime healing-table call for $reportID/$fightID ($playerName) - $($atResult.Errors | ConvertTo-Json -Compress)")
            $parseOk = $false
        } else {
            $atEntry = $atResult.Data.reportData.report.table.data.entries | Where-Object { $_.name -eq $playerName } | Select-Object -First 1
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
        }
    }

    # --- deaths (fight-wide, once per report+fight, NEVER archived - see v1 header note) ---
    $deathsOutFile = Join-Path $outDir "$($reportID)_$($fightID)_deaths.json"
    if (-not (Test-Path $deathsOutFile)) {
        $deathsKey = "$reportID|$fightID"
        if ($deathsClaimed.TryAdd($deathsKey, $true)) {
            $deathsQuery = "query { reportData { report(code: `"$reportID`") { table(fightIDs: [$fightID], dataType: Deaths, startTime: $start, endTime: $end) } } }"
            $deathsResult = Invoke-WclGraphQL -Query $deathsQuery -AccessToken $accessToken
            if ($deathsResult.Errors) {
                $result.Messages.Add("[$i] FAILED deaths table for $reportID/$fightID - $($deathsResult.Errors | ConvertTo-Json -Compress)")
            } else {
                $jsonText = $deathsResult.Data.reportData.report.table.data | ConvertTo-Json -Depth 12
                [System.IO.File]::WriteAllText($deathsOutFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
            }
        }
        # 2026-07-12 fix (found while porting Shaman, real rate-limit restarts):
        # re-check the file after the attempt (or after losing the claim race to
        # a different worker for the same report+fight) - if it's still missing
        # for ANY reason, this parse must NOT be marked complete below, or a
        # deaths-only 429 would silently leave a permanently-missing file (this
        # was the one sub-fetch here that didn't already gate $parseOk on its
        # own success - healing/casts/consumables/activetime all did). Checking
        # actual file existence rather than "did I personally fail" also
        # correctly covers the non-claiming worker's case, since it never
        # attempted the fetch at all and wouldn't otherwise know whether the
        # claimer succeeded. Restores the "a full re-run picks it up fresh"
        # behavior WORKFLOW.md gotcha #24 already describes as the intent.
        if (-not (Test-Path $deathsOutFile)) {
            $parseOk = $false
        }
    }

    $result.Ok = $parseOk
    return $result
}

$fightsCache = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$actorNamesCache = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
$deathsClaimed = [System.Collections.Concurrent.ConcurrentDictionary[string,bool]]::new()
# Shared across the WHOLE run (every boss, every parse) - see the worker
# scriptblock's comment above for why this replaces a per-worker local cache.
$abilityCache = [System.Collections.Concurrent.ConcurrentDictionary[int,object]]::new()

$totalNew = 0
$totalConfirmed = 0
$totalArchived = 0
$totalReentered = 0
$totalFailed = 0

foreach ($bossName in $bosses.Keys) {
    $encounterID = $bosses[$bossName].encounterID
    $rankingsFileName = $bosses[$bossName].file
    $activeRankingsPath = Join-Path $activeDir $rankingsFileName
    $bossActiveDir = Join-Path $activeDir $bossName
    $bossArchivedDir = Join-Path $archivedDir $bossName
    New-Item -ItemType Directory -Force -Path $bossActiveDir | Out-Null

    Write-Host "=== $bossName ==="

    # ----- Step 1: fetch fresh rankings into memory - v2 worldData.encounter(id)
    # .characterRankings(...), page 1 = same 100 entries as v1, still pre-sorted
    # by rank (array position = rank - confirmed live, list-level entries don't
    # carry a populated per-entry rank field). NOT written to disk yet - need to
    # diff first to decide whether this counts as a real change worth archiving. -----
    $rankingsQuery = "query { worldData { encounter(id: $encounterID) { characterRankings(className: `"$className`", specName: `"Restoration`", metric: hps, page: 1) } } }"
    $rankingsResult = Invoke-WclGraphQL -Query $rankingsQuery -AccessToken $token
    if ($rankingsResult.Errors -or -not $rankingsResult.Data.worldData.encounter.characterRankings) {
        Write-Host "  FAILED fetching rankings - $($rankingsResult.Errors | ConvertTo-Json -Compress) - skipping this boss entirely this run."
        Write-Host ""
        continue
    }
    $freshRankingsData = $rankingsResult.Data.worldData.encounter.characterRankings
    $freshRankings = @($freshRankingsData.rankings)

    # v2's entries nest report code/fightID under a `report` object and use
    # `amount` instead of v1's `total` - reshape to v1's exact FLAT field names
    # before this ever reaches disk. Confirmed via grep that
    # summarize_class_benchmarks.ps1 reads rankings_{boss}.json DIRECTLY (not
    # just the manifest) and matches by flat `.reportID`/`.fightID`/`.name`,
    # plus reads `.duration` for HPS - all four preserved here exactly.
    $reshapedForDisk = @($freshRankings | ForEach-Object {
        [PSCustomObject]@{
            name     = $_.name
            reportID = $_.report.code
            fightID  = $_.report.fightID
            duration = $_.duration
            total    = $_.amount
        }
    })
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

    # ----- Build the fresh key set and diff against manifest-active parses.
    # report.code/report.fightID (nested, v2 shape) replace v1's flat
    # reportID/fightID - the only real difference in this whole diff block. -----
    $freshByKey = [ordered]@{}
    for ($k = 0; $k -lt $freshRankings.Count; $k++) {
        $r = $freshRankings[$k]
        $key = "$($r.report.code)_$($r.report.fightID)_$($r.name)"
        $freshByKey[$key] = [ordered]@{ rank = $k + 1; hps = $r.amount; reportID = $r.report.code; fightID = $r.report.fightID; name = $r.name }
    }

    $activeManifestKeys = @($bossEntry.parses.Keys | Where-Object { $bossEntry.parses[$_].status -eq "active" })
    $archivedManifestKeys = @($bossEntry.parses.Keys | Where-Object { $bossEntry.parses[$_].status -eq "archived" })
    $newKeys = @($freshByKey.Keys | Where-Object { -not $bossEntry.parses.Contains($_) })
    $reenteredKeys = @($freshByKey.Keys | Where-Object { $archivedManifestKeys -contains $_ })
    $droppedKeys = @($activeManifestKeys | Where-Object { -not $freshByKey.Contains($_) })
    $stillActiveKeys = @($activeManifestKeys | Where-Object { $freshByKey.Contains($_) })

    foreach ($key in $stillActiveKeys) {
        $bossEntry.parses[$key].rank = $freshByKey[$key].rank
        $bossEntry.parses[$key].hps = [math]::Round($freshByKey[$key].hps, 1)
        $bossEntry.parses[$key].lastConfirmedInTop100At = $nowIso
    }
    $totalConfirmed += $stillActiveKeys.Count

    if ($droppedKeys.Count -gt 0) {
        New-Item -ItemType Directory -Force -Path $bossArchivedDir | Out-Null
    }
    foreach ($key in $droppedKeys) {
        $p = $bossEntry.parses[$key]
        $stem = "$($p.reportID)_$($p.fightID)_$($p.safeName)"
        foreach ($suffix in @("healing_events", "casts_events", "consumables", "activetime")) {
            $srcPath = Join-Path $bossActiveDir "$($stem)_$($suffix).json"
            if (Test-Path $srcPath) {
                Move-Item -Path $srcPath -Destination $bossArchivedDir -Force
            } elseif ($suffix -ne "activetime") {
                Write-Host "  WARNING: expected $srcPath to archive for dropped parse $key, not found."
            }
        }
        $p.status = "archived"
        $p.archivedAt = $nowIso
    }
    $totalArchived += $droppedKeys.Count

    foreach ($key in $reenteredKeys) {
        $p = $bossEntry.parses[$key]
        $stem = "$($p.reportID)_$($p.fightID)_$($p.safeName)"
        foreach ($suffix in @("healing_events", "casts_events", "consumables", "activetime")) {
            $srcPath = Join-Path $bossArchivedDir "$($stem)_$($suffix).json"
            if (Test-Path $srcPath) {
                Move-Item -Path $srcPath -Destination $bossActiveDir -Force
            } elseif ($suffix -ne "activetime") {
                Write-Host "  WARNING: expected $srcPath to restore for re-entered parse $key, not found in archived\$bossName."
            }
        }
        $p.status = "active"
        $p.archivedAt = $null
        $p.rank = $freshByKey[$key].rank
        $p.hps = [math]::Round($freshByKey[$key].hps, 1)
        $p.lastConfirmedInTop100At = $nowIso
    }
    if ($reenteredKeys.Count -gt 0) {
        $totalReentered += $reenteredKeys.Count
        Write-Host "  $($reenteredKeys.Count) parse(s) RE-ENTERED the Top 100 (restored from archived\, zero API calls): $($reenteredKeys -join ', ')"
    }

    $changed = ($newKeys.Count -gt 0) -or ($droppedKeys.Count -gt 0) -or ($reenteredKeys.Count -gt 0)
    if ($changed) {
        if (Test-Path $activeRankingsPath) {
            $oldSnapshotDate = $bossEntry.rankingsSnapshotDate
            if (-not $oldSnapshotDate) { $oldSnapshotDate = "unknown-date" }
            $rankingsHistoryDir = Join-Path (Join-Path $archivedDir "rankings_history") $bossName
            New-Item -ItemType Directory -Force -Path $rankingsHistoryDir | Out-Null
            $archivedRankingsPath = Join-Path $rankingsHistoryDir "$oldSnapshotDate.json"
            Move-Item -Path $activeRankingsPath -Destination $archivedRankingsPath -Force
        }
        # $reshapedForDisk (v1's flat shape), not $freshRankingsData (v2's nested
        # shape) - see the reshaping comment above where $reshapedForDisk is built.
        $rankingsOut = [PSCustomObject]@{ rankings = $reshapedForDisk }
        $rankingsJsonText = $rankingsOut | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($activeRankingsPath, $rankingsJsonText, (New-Object System.Text.UTF8Encoding $false))
        $bossEntry.rankingsSnapshotDate = $today
        Write-Host "  rankings CHANGED ($($newKeys.Count) new, $($droppedKeys.Count) dropped, $($reenteredKeys.Count) re-entered) - snapshot updated"
    } else {
        Write-Host "  rankings unchanged since $($bossEntry.rankingsSnapshotDate) - not rewriting active\$rankingsFileName"
    }
    $bossEntry.lastPulledDate = $today

    if ($newKeys.Count -eq 0) {
        Write-Host "  no new parses to fetch"
        Save-ManifestLocal -Manifest $manifest -Path $manifestPath
        Write-Host ""
        continue
    }

    Write-Host "  fetching $($newKeys.Count) new parses ($MaxThreads threads)..."
    $moduleAbsolutePath = Join-Path $PSScriptRoot "lib\WclV2Api.psm1"
    $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $pool.Open()

    $jobs = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($key in $newKeys) {
        $i++
        $entry = $freshByKey[$key]
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($workerScript.ToString()).
            AddArgument($entry.reportID).
            AddArgument($entry.fightID).
            AddArgument($entry.name).
            AddArgument($i).
            AddArgument($className).
            AddArgument($bossActiveDir).
            AddArgument($fightsCache).
            AddArgument($actorNamesCache).
            AddArgument($deathsClaimed).
            AddArgument($abilityCache).
            AddArgument($token).
            AddArgument($moduleAbsolutePath)
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
Write-Host "  Re-entered (restored, no refetch): $totalReentered"
Write-Host "  Unique reports fetched:         $($fightsCache.Count)"
Write-Host "  manifest.json:                  $manifestPath"
