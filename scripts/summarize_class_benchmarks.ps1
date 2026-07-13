# summarize_class_benchmarks.ps1
#
# Reads the raw Top 100 data pulled by pull_top100_druid.ps1 and computes the derived
# benchmark stats our analysis actually uses - PER BOSS:
#   - HPS / HPM / overheal percentiles     (from rankings.json + *_healing_events.json +
#                                            *_casts_events.json - see the HPM note below)
#   - Top 100 spell composition            (from *_healing_events.json, grouped by guid)
#   - Top 100 target concentration         (from *_healing_events.json, grouped by target)
#   - Top 100 cooldown/utility/consumable cast counts, with self-vs-other target split
#                                           (from *_casts_events.json)
#   - Top 100 self-buff stats: % with flask/food active at pull start, average real
#     Tree of Life uptime %                (from *_consumables.json)
#
# Outputs compact CSVs, small enough to upload to Claude Project knowledge:
#   benchmark_summary.csv               <- one row per boss (HPS, HPM, overheal, target stats)
#   benchmark_spell_composition.csv     <- one row per boss+spell (Top 100 avg % of healing)
#   benchmark_cooldowns.csv             <- one row per boss+ability (Top 100 avg casts, self%)
#   benchmark_buffs.csv                 <- one row per boss (Top 100 flask/food/Tree of Life)
#
# ============================================================================
# 2026-07-12: ADDED HPM (HEALING PER MANA) - resources/resources-gains API confirmed
# dead, used classResources on *_casts_events.json instead (already had the data)
# ============================================================================
# The resources/resources-gains WCL views were confirmed genuinely broken against the
# real Fresh Classic API this session (5 real test calls, every documented param
# variant - see WORKFLOW.md gotcha #11) - but it turned out not to matter. Every
# *_casts_events.json file already pulled carries a `classResources[0]` object per cast
# event with real mana data under misleadingly-generic field names: `amount` = the
# character's max mana pool (constant, unused here), `max` = that spell's real mana
# cost (this is what gets summed into HPM's denominator), `type` = current mana at that
# moment (unused here, would feed a mana-over-time trace if ever built). Verified
# against real known TBC spell costs (Lifebloom 220, Rejuvenation 415, Regrowth 675,
# Healing Touch 935, etc - all matched exactly) and a real kill's cast sequence (`type`
# traced smoothly 10175->2781 over one fight, confirming it's really current mana, not
# a resource-type ID). HPM = effective healing / total mana cost summed across every
# cast event that carries a classResources entry - same `$total` numerator already used
# for HPS, so HPM and HPS share the same "effective, not raw" healing definition.
# `HPM_SampleUsed` can be smaller than `SampleSize` for the same reason
# `benchmark_cooldowns.csv`'s SampleUsed can - excludes any parse whose casts file was
# missing/unparseable, not silently zero-filled.
# ============================================================================
#
# ============================================================================
# 2026-07-12: SWITCHED FROM TOP-10-AVG TO TOP-100-AVG (SAME DAY AS THE ACTIVE/ARCHIVED
# REWRITE BELOW, LATER PASS)
# ============================================================================
# Every aggregate here (spell composition, target coverage, cooldown/utility casts,
# flask/food/Tree of Life) used to be computed over only the best 10 of however many
# parses were actually pulled (usually ~100), discarding the other ~90 real, already-
# fetched data points. Since we already pay the API cost to pull the full Top 100, and
# a 100-person sample is a meaningfully less noisy average than 10, every "Top10*"
# column below is now a "Top100*" column computed over the FULL real sample for that
# boss (however many parses actually parsed successfully - usually close to 100, never
# assumed to be exactly 100, see SampleSize/SampleUsed on every row). HPS_Top1 (the
# single best parse) and HPS_Median (median of the full sample) were already
# whole-sample stats and are unchanged by this - only the "-Avg" style aggregates moved
# off the top-10-only slice.
# ============================================================================
#
# ============================================================================
# 2026-07-12: FIXED - SELF-ONLY SPELLS WERE MISCOUNTED AS "NOT SELF"
# ============================================================================
# Found while switching to Top100-avg (above) surfaced Nature's Swiftness at 0% self
# across a full 100-person sample on Hydross - implausible, since NS can only ever be
# cast on the caster. Root cause: WCL logs a self-only-castable spell's cast event with
# `target: {"name":"Environment","id":-1,...}` instead of a real actor, since there's
# no real other-actor target to report - the pull scripts' target-name annotation
# leaves `targetName` as `null` in this case (no targetID to resolve), and the old
# self-check (`sourceName -eq targetName`) treated that null as "not self" instead of
# recognizing it as "no real target exists, so it can only have been self." Fixed by
# also counting a null/empty targetName as self - a spell logged with no real
# other-actor target mechanically cannot have gone to anyone else. Only affects the
# self%/SelfCount aggregate in this script; the pull scripts' own target-name
# annotation was also fixed the same day so future pulls store a real name instead of
# null for these events (see their own header notes) - this script's fix handles both
# old (null) and new (self-name) data correctly either way, so no re-pull or bulk
# re-processing of already-pulled files was needed.
# ============================================================================
#
# ============================================================================
# 2026-07-12: ACTIVE/ARCHIVED + MANIFEST AWARE, DUAL-MODE
# ============================================================================
# pull_top100_druid.ps1 no longer writes into a fresh data\Classes\{Class}\{date}\ folder
# every run - it maintains one persistent data\Classes\{Class}\active\ folder (only
# currently-in-the-Top-100 parses) plus data\Classes\{Class}\archived\ (parses that have
# dropped out, kept forever) and a manifest.json tracking per-boss pull dates and
# per-parse status. Paladin/Priest/Shaman are NOT on this model yet - they're still
# both v1 (healing TABLE, not events) AND the old date-stamped-folder convention, pulled
# by pull_top100_paladin.ps1/pull_top100_priest_holy.ps1/pull_top100_shaman.ps1.
#
# This script supports BOTH conventions, chosen by whether -DateFolder is passed:
#   - -DateFolder omitted -> active/archived model: reads/writes
#     data\Classes\{Class}\active\, tracks benchmarkGeneratedDate in manifest.json,
#     archives the previous CSV set to archived\benchmark_history\{date}\ on a real
#     day-over-day regen. This is the only mode Druid supports (it has no date folder
#     to point at anymore - migrate_class_to_active.ps1 already converted it).
#   - -DateFolder {date} passed -> old mode, unchanged from before this rewrite: reads/
#     writes data\Classes\{Class}\{date}\ directly, no manifest, no staleness tracking,
#     no CSV history. This is what Paladin/Priest/Shaman still need until they're
#     ported to the active/archived model (see WORKFLOW.md gotcha #25).
#
# STALENESS: manifest.json's top-level `benchmarkGeneratedDate` is a plain "yyyy-MM-dd"
# string, never a boolean flag (a stored true/false would silently go wrong the instant
# the date rolls over - see pull_top100_druid.ps1's header for the same reasoning applied
# to lastPulledDate/rankingsSnapshotDate). Staleness is always computed fresh by comparing
# to today's date: generated today = fresh, generated any earlier day = stale. This script
# prints that comparison at the start for visibility, but ALWAYS regenerates all four CSVs
# regardless - recomputation is local/free (no API calls), so there's no reason to skip
# it, only a reason to tell the person whether the numbers they're about to get were
# already fresh or not.
#
# CSV HISTORY: previously, re-running this script silently overwrote the four CSVs with
# no history kept. Now, before writing, if active\benchmark_summary.csv already exists
# AND manifest.benchmarkGeneratedDate is an earlier date than today (i.e. this is a real
# new day's regeneration, not a same-day re-run), the existing four CSVs are copied to
# archived\benchmark_history\{that old date}\ before being overwritten - one folder per
# calendar day the numbers actually changed, no duplicate entries for same-day re-runs.
#
# ============================================================================
# ORIGINAL 2026-07-11 REWRITE NOTES (still accurate, unrelated to the above): reads
# events, not tables, for healing/casts. Two real bugs fixed in the process, both
# confirmed against actual pulled data before this rewrite:
# ============================================================================
# 1. TRUNCATION: the old healing/casts TABLE views silently capped their per-player
#    "abilities" array at 5 entries (see WORKFLOW.md gotcha list). This script now reads
#    *_healing_events.json / *_casts_events.json instead - complete, per-event records,
#    no cap. Spell composition and cooldown counts from any run of the old script should
#    be treated as unverified.
# 2. LOCALIZATION SPLIT: the old script grouped spell composition by ability NAME. Real
#    data check on this exact Hydross/Lurker pull found Lifebloom alone logged under 7
#    different localized names (Korean/Portuguese/German/French/Chinese/Spanish/English)
#    across the Top 100 sample - the old script would have silently split one spell into
#    seven separate rows instead of aggregating them. This script groups by ability GUID
#    instead (guid is locale-independent), and picks a display name preferring ASCII
#    when multiple names are seen for the same guid (mirrors the existing player-name
#    convention from gotcha #2 in the pull scripts).
# 3. DIFFERENT GUIDS SHARING A NAME ARE NOT MERGED. An earlier version of this rewrite
#    tried a second pass merging by the resolved display name (to combine what looked
#    like duplicate "Lifebloom" rows from different guids) - real data proved that wrong.
#    Lifebloom's two guids (33763, 33778) both display as "Lifebloom" in every language,
#    but are empirically different: 33763 is 100% tick=true, ~310 avg amount (the HoT
#    component); 33778 is 100% tick=false, ~515 avg amount (the "bloom" burst heal on
#    expiry) - two real mechanics, not a duplicate. Regrowth/Rejuvenation's dual guids
#    looked different again on inspection (mixed tick/non-tick, similar amounts, very
#    different frequency - more consistent with rank variance). Rather than assert what
#    each guid "means" per spell (which only covers spells someone has actually checked
#    and risks being wrong), every guid stays its own row always; when two guids share a
#    display name the guid is appended to disambiguate instead of guessing at a label.
# 4. BUFF UPTIME, ADDED BACK LATER THE SAME DAY. The original *_buffs.json (a table
#    view, sourceclass=Druid&hostility=0, no `by=` param) was found to merge every
#    Druid's buffs in a fight into one flat list, not scoped to the ranked player the
#    file was named after - confirmed on real data showing Moonkin Form + Dire Bear
#    Form + Tree of Life simultaneously (three different specs' forms, impossible for
#    one character). benchmark_buffs.csv was dropped entirely for a while as a result.
#    It's back now, reading *_consumables.json instead: flask/food are booleans (active
#    at the pull-start combatantinfo snapshot, since those buffs outlast any single
#    fight and a snapshot is enough), Tree of Life is a real reconstructed uptime %
#    (apply/remove event interval reconstruction, guid 33891 only - its paired guid
#    34123 shares the display name but toggles far more often in ways that don't match
#    manual form-toggling, empirically untrustworthy, excluded). See
#    pull_top100_druid.ps1's header for the full validation writeup.
#
# Target coverage/top1% are also now computed from the complete per-event target
# breakdown instead of the healing table's `targets[]` array, which had the exact same
# undocumented top-5 truncation as `abilities[]` - "coverage" still means "top 5
# recipients as % of total", same definition the templates already use, just accurate.
#
# Run this from your repo ROOT directory (same place you ran the pull script from).
#
# Usage: powershell -ExecutionPolicy Bypass -File summarize_class_benchmarks.ps1 -ClassName Druid
#        powershell -ExecutionPolicy Bypass -File summarize_class_benchmarks.ps1 -ClassName Paladin -DateFolder 2026-07-10

param(
    [Parameter(Mandatory=$true)][string]$ClassName,
    [string]$ClassesRootOverride,  # equivalence-testing only, e.g. against a scratch pull
    [string]$DateFolder = $null
)

$classesRoot = if ($ClassesRootOverride) { $ClassesRootOverride } else { "data\Classes" }
$classDir = Join-Path $classesRoot $ClassName
$today = Get-Date -Format "yyyy-MM-dd"
$usingActiveModel = [string]::IsNullOrWhiteSpace($DateFolder)

# ===== Manifest load/save - see pull_top100_druid.ps1 for why PSCustomObject gets
# converted to plain ordered hashtables before mutation. No arrays appear anywhere in
# this schema, so a straightforward recursive walk is all that's needed. Only used in
# the active-model branch below - the old date-folder mode has no manifest. =====
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
function Save-ManifestLocal {
    param($Manifest, $Path)
    $jsonText = $Manifest | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $jsonText, (New-Object System.Text.UTF8Encoding $false))
}

$manifest = $null
$priorGeneratedDate = $null

if ($usingActiveModel) {
    $workDir = Join-Path $classDir "active"
    $archivedDir = Join-Path $classDir "archived"
    $manifestPath = Join-Path $classDir "manifest.json"

    if (-not (Test-Path $workDir)) {
        Write-Host "ERROR: $workDir not found. Either run pull_top100_druid.ps1 first (it"
        Write-Host "       creates active\/manifest.json), or pass -DateFolder {date} if this"
        Write-Host "       class is still on the old date-stamped-folder convention."
        exit 1
    }
    if (-not (Test-Path $manifestPath)) {
        Write-Host "ERROR: $manifestPath not found - needed for staleness tracking under the"
        Write-Host "       active/archived model. Run pull_top100_druid.ps1 first."
        exit 1
    }

    $manifest = ConvertTo-OrderedHashtableLocal (Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    $priorGeneratedDate = $manifest.benchmarkGeneratedDate
    if ($priorGeneratedDate -eq $today) {
        Write-Host "Benchmark already generated today ($today) - regenerating anyway (recomputation is free), same-day re-run won't create a new history snapshot."
    } elseif ($null -eq $priorGeneratedDate) {
        Write-Host "No prior benchmark generation recorded - this will be the first."
    } else {
        Write-Host "Benchmark last generated $priorGeneratedDate - STALE relative to today ($today), regenerating."
    }
} else {
    $workDir = Join-Path $classDir $DateFolder
    if (-not (Test-Path $workDir)) {
        Write-Host "ERROR: $workDir not found."
        exit 1
    }
    Write-Host "Using the old date-folder convention ($DateFolder) - no manifest/staleness tracking or CSV history for this class yet (see WORKFLOW.md gotcha #25)."
}
Write-Host ""

# boss folder name -> (rankings filename, display name) - matches pull_top100_druid.ps1
$bosses = [ordered]@{
    "Hydross"    = @{ file = "rankings_hydross.json";    display = "Hydross the Unstable" }
    "Lurker"     = @{ file = "rankings_lurker.json";     display = "The Lurker Below" }
    "Leotheras"  = @{ file = "rankings_leotheras.json";  display = "Leotheras the Blind" }
    "Karathress" = @{ file = "rankings_karathress.json"; display = "Fathom-Lord Karathress" }
    "Morogrim"   = @{ file = "rankings_morogrim.json";   display = "Morogrim Tidewalker" }
    "Vashj"      = @{ file = "rankings_vashj.json";      display = "Lady Vashj" }
    "Alar"       = @{ file = "rankings_alar.json";       display = "Al'ar" }
    "VoidReaver" = @{ file = "rankings_voidreaver.json"; display = "Void Reaver" }
    "Solarian"   = @{ file = "rankings_solarian.json";   display = "High Astromancer Solarian" }
    "Kaelthas"   = @{ file = "rankings_kaelthas.json";   display = "Kael'thas Sunstrider" }
}

# ===== Cooldown/utility watch list (Druid-specific), matched by GUID - real guids
# extracted from actual pulled data, not guessed. Tranquility still empty; add its guid
# here once it's actually observed in a pull (see WORKFLOW.md). =====
$cooldownGuids = [ordered]@{
    "Innervate"          = @(29166)
    "Nature's Swiftness" = @(17116)
    "Swiftmend"          = @(18562)
    "Tranquility"        = @()
    "Rebirth"            = @(26994)
    "Dark Rune"          = @(27869)
}
# Matched by NAME instead of guid - real data shows 3+ different guids for this single
# effect (different mana potion tiers/items), so name is the more stable match here.
$manaPotionName = "Restore Mana"

# ===== Self-buff uptime: no watch-list constants needed here - flask/elixir/food
# matching and Tree of Life guid selection already happened at pull time (see
# pull_top100_druid.ps1's Get-ConsumablesSnapshotLocal / Get-TreeOfLifeUptimeLocal).
# This script just reads the already-computed flaskActive/foodActive/
# treeOfLifeUptimePct fields straight out of each *_consumables.json. =====

function Test-IsAscii($s) {
    if ($null -eq $s) { return $false }
    return ($s -match '^[\x00-\x7F]*$')
}

# Adds/updates a guid-keyed aggregate hashtable, preferring an ASCII display name when
# multiple locales are seen for the same guid (Lifebloom was seen under 7 different
# names in real data - see header comment).
function Add-GuidAggregate {
    param([hashtable]$Agg, [int]$Guid, [string]$Name, [double]$Amount)
    if (-not $Agg.ContainsKey($Guid)) {
        $Agg[$Guid] = [PSCustomObject]@{ Name = $Name; Total = 0.0 }
    } else {
        if (-not (Test-IsAscii $Agg[$Guid].Name) -and (Test-IsAscii $Name)) {
            $Agg[$Guid].Name = $Name
        }
    }
    $Agg[$Guid].Total += $Amount
}

$summaryRows = @()
$spellCompRows = @()
$cooldownRows = @()
$buffRows = @()

foreach ($bossFolder in $bosses.Keys) {
    $bossInfo = $bosses[$bossFolder]
    $bossName = $bossInfo.display
    $bossDir = Join-Path $workDir $bossFolder
    $rankingsFile = Join-Path $workDir $bossInfo.file

    if (-not (Test-Path $bossDir)) {
        Write-Host "SKIP: $bossDir not found."
        continue
    }
    if (-not (Test-Path $rankingsFile)) {
        Write-Host "SKIP: $rankingsFile not found (needed for duration/HPS) - rankings pull may have failed."
        continue
    }

    $rankingsData = Get-Content $rankingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($rankingsData.PSObject.Properties.Name -contains "error") {
        Write-Host "SKIP: $bossFolder rankings file contains an API error, not a rankings list."
        continue
    }
    $rankings = $rankingsData.rankings

    $healingFiles = Get-ChildItem -Path $bossDir -Filter "*_healing_events.json"
    Write-Host "Processing $bossName ($($healingFiles.Count) healing event files)..."

    $castsFailCount = 0
    $consumablesFailCount = 0

    $records = @()
    foreach ($file in $healingFiles) {
        try {
            $healingData = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            continue
        }
        $playerName = $healingData.sourceName
        if (-not $playerName) { continue }

        # reportID and fightID are the first two underscore-separated segments of the
        # filename and are always plain ASCII (report codes, numeric fight IDs) - safe
        # to split even though the player-name portion later in the filename may be
        # Windows-hex-escaped for non-ASCII characters (gotcha #1). We don't need to
        # decode that here at all, since the real player name comes from the file's own
        # sourceName field instead - much more robust than re-deriving it from the path.
        $nameParts = $file.BaseName -split '_', 3
        $reportID = $nameParts[0]
        $fightID = [int]$nameParts[1]

        $rankMatch = $rankings | Where-Object { $_.reportID -eq $reportID -and $_.fightID -eq $fightID -and $_.name -eq $playerName } | Select-Object -First 1
        if (-not $rankMatch) {
            Write-Host "  WARNING: no rankings entry matched for $playerName ($reportID/$fightID) - skipping (can't get duration/HPS)."
            continue
        }

        $total = $healingData.totalAmount
        $overheal = $healingData.totalOverheal
        $raw = $total + $overheal
        $overhealPct = if ($raw -gt 0) { ($overheal / $raw) * 100 } else { 0 }
        $hps = if ($rankMatch.duration -gt 0) { $total / ($rankMatch.duration / 1000) } else { 0 }

        # ----- Spell composition: group by ability guid, not name (see header) -----
        $abilities = @{}
        $targets = @{}
        foreach ($ev in $healingData.events) {
            if ($ev.ability -and $ev.amount) {
                Add-GuidAggregate -Agg $abilities -Guid $ev.ability.guid -Name $ev.ability.name -Amount $ev.amount
            }
            if ($ev.targetName -and $ev.amount) {
                if (-not $targets.ContainsKey($ev.targetName)) { $targets[$ev.targetName] = 0.0 }
                $targets[$ev.targetName] += $ev.amount
            }
        }
        $sortedTargets = $targets.GetEnumerator() | Sort-Object -Property Value -Descending
        $top5Sum = ($sortedTargets | Select-Object -First 5 | Measure-Object -Property Value -Sum).Sum
        if ($null -eq $top5Sum) { $top5Sum = 0 }
        $coveragePct = if ($total -gt 0) { ($top5Sum / $total) * 100 } else { 0 }
        $top1Pct = if ($sortedTargets.Count -gt 0 -and $total -gt 0) { ($sortedTargets[0].Value / $total) * 100 } else { 0 }

        # ----- Cooldowns/utility/consumables, from the sibling *_casts_events.json -----
        $cooldownCounts = $null
        $castsFile = $file.FullName -replace '_healing_events\.json$', '_casts_events.json'
        $manaSpent = $null
        if (Test-Path $castsFile) {
            try {
                $castsData = Get-Content $castsFile -Raw -Encoding UTF8 | ConvertFrom-Json

                # ----- HPM (healing per mana), from the same *_casts_events.json - added
                # 2026-07-12 after the resources/resources-gains API endpoint was confirmed
                # dead (5 real test calls, every documented param variant, all failed - see
                # WORKFLOW.md gotcha #11). Turned out not to matter: every cast event here
                # already carries a classResources[0] object with real mana data under
                # misleadingly-generic field names - `amount` is the character's max mana
                # pool (constant, unused here), `max` is that spell's real mana cost, `type`
                # is current mana at that moment (unused here, would feed a mana-over-time
                # trace if ever built). Verified against real known TBC spell costs (Lifebloom
                # 220, Rejuvenation 415, Regrowth 675, Healing Touch 935, etc - all matched
                # exactly) and a real kill's cast sequence (type traced smoothly 10175->2781
                # over one fight). Summing `max` across every event that has a classResources
                # entry gives total real mana spent; some cast events (begincast placeholders,
                # a few proc/utility casts) carry no classResources at all and are skipped,
                # same as they'd contribute 0 cost either way.
                $manaSpent = 0.0
                foreach ($ev in $castsData.events) {
                    if ($ev.classResources -and $ev.classResources.Count -gt 0) {
                        $manaSpent += $ev.classResources[0].max
                    }
                }

                $cooldownCounts = @{}
                foreach ($cdName in $cooldownGuids.Keys) {
                    $guidList = $cooldownGuids[$cdName]
                    # @() wraps the WHOLE if/else, not its individual branches - wrapping
                    # only inside the branches (the previous version of this line) does
                    # NOT reliably survive assignment through the if/else-as-expression
                    # mechanism: a zero-match Where-Object result flowing through that
                    # inner @() can still collapse back to $null once the outer if/else
                    # captures it, silently turning "$matched.Count" into a blank instead
                    # of 0. Confirmed on real execution: Innervate showed a blank matched
                    # count for a player file confirmed (by three independent checks) to
                    # contain a real Innervate event, while Swiftmend's identical-shaped
                    # code worked - the only difference was incidental (Swiftmend's
                    # matches happened to be non-empty for the specific players tested,
                    # never exercising the empty-collection collapse). This outer-wrap
                    # form is the same safe idiom already used two lines below for
                    # $selfCount and $manaMatched, which never showed this bug.
                    # Excludes "begincast" events (2026-07-12 fix) - WCL logs a separate
                    # begincast event for any ability with a real cast time (Rebirth,
                    # Tranquility - NOT Innervate/Swiftmend/NS/Dark Rune, which are all
                    # instant and never generate one), BEFORE the target resolves, so it
                    # always carries target={"name":"Environment",...} same as the
                    # self-only-spell case below. Without this exclusion, a single real
                    # Rebirth cast on someone else produced TWO matched events (the
                    # begincast, phantom-self due to the null target, plus the real "cast"
                    # with the correct target) - confirmed on real data: Danceswtrees's one
                    # real Rebirth cast on Leotheras (target=Captinspanky) was being counted
                    # as 2 events, one incorrectly "self." This double-counted the ability's
                    # total cast count AND inflated its self% for every player who had a
                    # real cast-time cooldown cast logged, not just this one case.
                    $matched = @(if ($guidList.Count -gt 0) { $castsData.events | Where-Object { ($guidList -contains $_.ability.guid) -and ($_.type -ne "begincast") } })
                    # A null/empty targetName means the raw event carried no real targetID
                    # at all (WCL logs self-only-castable spells like Nature's Swiftness
                    # with target={"name":"Environment","id":-1,...} instead of a real
                    # actor - see 2026-07-12 fix note below) - counted as self, not "not
                    # self", since a spell with no real other-actor target can only have
                    # affected the caster. Before this fix, every self-cast of a spell
                    # shaped like this was silently miscounted as non-self (confirmed on
                    # real data: Nature's Swiftness showed 0% self across the full
                    # 100-person Hydross sample, implausible for a spell that mechanically
                    # can't be cast on anyone else).
                    $selfCount = @($matched | Where-Object { $_.sourceName -eq $_.targetName -or [string]::IsNullOrEmpty($_.targetName) }).Count
                    $cooldownCounts[$cdName] = [PSCustomObject]@{ Count = $matched.Count; SelfCount = $selfCount }
                }
                $manaMatched = @($castsData.events | Where-Object { $_.ability.name -eq $manaPotionName })
                $cooldownCounts["Mana Potion"] = [PSCustomObject]@{ Count = $manaMatched.Count; SelfCount = $manaMatched.Count }
            } catch {
                $castsFailCount++
            }
        }

        # ----- Self-buff uptime, from the sibling *_consumables.json (2026-07-11
        # redesign - replaces the old *_buffs.json table, which was found to merge
        # every Druid's buffs in a fight into one flat list, not scoped to this
        # player. See header comment for the full writeup. Flask/food are read as
        # simple booleans ("active at pull start", not a computed uptime %, since
        # that's all a snapshot can tell us) - Tree of Life is a real reconstructed
        # uptime % (see pull_top100_druid.ps1's Get-TreeOfLifeUptimeLocal). -----
        $buffUptimes = $null
        $consumablesFile = $file.FullName -replace '_healing_events\.json$', '_consumables.json'
        if (Test-Path $consumablesFile) {
            try {
                $consumablesData = Get-Content $consumablesFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $buffUptimes = [PSCustomObject]@{
                    FlaskActive   = [bool]$consumablesData.flaskActive
                    FoodActive    = [bool]$consumablesData.foodActive
                    TreeOfLifePct = $consumablesData.treeOfLifeUptimePct
                }
            } catch {
                $consumablesFailCount++
            }
        }

        # $manaSpent is $null if the casts file was missing/unparseable (excluded from
        # the HPM aggregate entirely, same treatment as Cooldowns/BuffUptimes above) or
        # a real 0.0+ accumulator otherwise. A real 0 (no mana-costing casts at all -
        # not expected for a healer over a real fight, but not impossible) also can't
        # produce a meaningful HPM, so both cases fall through to $null here.
        $hpm = if ($manaSpent -and $manaSpent -gt 0) { $total / $manaSpent } else { $null }

        # ----- Active Time, from the sibling *_activetime.json (2026-07-12 addition) -
        # real activeTimePct field pulled from the healing TABLE's top-level per-player
        # activeTime/activeTimeReduced scalars (see pull_top100_druid.ps1's header note
        # by the fetch itself for why this is a real re-discovered field, not an
        # estimate - same pattern as the HPM/classResources discovery). $null here if
        # the file is missing (parses pulled before 2026-07-12, not yet backfilled) or
        # unparseable - excluded from the aggregate entirely, same treatment as HPM. -----
        $activeTimePct = $null
        $activeTimeFile = $file.FullName -replace '_healing_events\.json$', '_activetime.json'
        if (Test-Path $activeTimeFile) {
            try {
                $activeTimeData = Get-Content $activeTimeFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $activeTimePct = $activeTimeData.activeTimePct
            } catch {
                $activeTimePct = $null
            }
        }

        $records += [PSCustomObject]@{
            PlayerName    = $playerName
            HPS           = $hps
            HPM           = $hpm
            OverhealPct   = $overhealPct
            CoveragePct   = $coveragePct
            Top1Pct       = $top1Pct
            ActiveTimePct = $activeTimePct
            Abilities     = $abilities
            Cooldowns     = $cooldownCounts
            BuffUptimes   = $buffUptimes
        }
    }

    if ($records.Count -eq 0) { continue }
    if ($castsFailCount -gt 0) {
        Write-Host "  WARNING: $castsFailCount casts_events files for $bossName failed to parse - those players excluded from the cooldown aggregate only."
    }
    if ($consumablesFailCount -gt 0) {
        Write-Host "  WARNING: $consumablesFailCount consumables files for $bossName failed to parse - those players excluded from the buff aggregate only."
    }

    $sorted = $records | Sort-Object -Property HPS -Descending
    $n = $sorted.Count
    $top1 = $sorted[0].HPS
    $top100Avg = ($sorted | Measure-Object -Property HPS -Average).Average
    $median = $sorted[[int]($n/2)].HPS

    $ohSorted = $records | Sort-Object -Property OverhealPct
    $ohBest = $ohSorted[0].OverhealPct
    $ohMedian = $ohSorted[[int]($n/2)].OverhealPct
    $ohWorst = $ohSorted[$n-1].OverhealPct

    $covAvg = ($sorted | Measure-Object -Property CoveragePct -Average).Average
    $top1PctAvg = ($sorted | Measure-Object -Property Top1Pct -Average).Average

    # ----- HPM (healing per mana) across the sample that has it - excludes any parse
    # whose casts file was missing/unparseable, so this sample size can be smaller than
    # SampleSize (see HPM_SampleUsed below), same pattern as the cooldown/buff samples. -----
    $sampleWithHpm = @($sorted | Where-Object { $_.HPM -ne $null })
    $hpmSampleUsed = $sampleWithHpm.Count
    $hpmTop1 = $null; $hpmTop100Avg = $null; $hpmMedian = $null
    if ($hpmSampleUsed -gt 0) {
        $hpmSorted = $sampleWithHpm | Sort-Object -Property HPM -Descending
        $hpmTop1 = $hpmSorted[0].HPM
        $hpmTop100Avg = ($sampleWithHpm | Measure-Object -Property HPM -Average).Average
        $hpmMedian = $hpmSorted[[int]($hpmSampleUsed/2)].HPM
    }

    # ----- Active Time across the sample that has it - excludes any parse whose
    # *_activetime.json is missing (not yet backfilled) or unparseable, same pattern
    # as HPM above. -----
    $sampleWithActiveTime = @($sorted | Where-Object { $_.ActiveTimePct -ne $null })
    $activeTimeSampleUsed = $sampleWithActiveTime.Count
    $activeTimeTop1 = $null; $activeTimeTop100Avg = $null; $activeTimeMedian = $null
    if ($activeTimeSampleUsed -gt 0) {
        $activeTimeSorted = $sampleWithActiveTime | Sort-Object -Property ActiveTimePct -Descending
        $activeTimeTop1 = $activeTimeSorted[0].ActiveTimePct
        $activeTimeTop100Avg = ($sampleWithActiveTime | Measure-Object -Property ActiveTimePct -Average).Average
        $activeTimeMedian = $activeTimeSorted[[int]($activeTimeSampleUsed/2)].ActiveTimePct
    }

    $summaryRows += [PSCustomObject]@{
        Boss = $bossName
        HPS_Top1 = [math]::Round($top1, 0)
        HPS_Top100Avg = [math]::Round($top100Avg, 0)
        HPS_Median = [math]::Round($median, 0)
        HPM_Top1 = if ($null -ne $hpmTop1) { [math]::Round($hpmTop1, 2) } else { "" }
        HPM_Top100Avg = if ($null -ne $hpmTop100Avg) { [math]::Round($hpmTop100Avg, 2) } else { "" }
        HPM_Median = if ($null -ne $hpmMedian) { [math]::Round($hpmMedian, 2) } else { "" }
        ActiveTime_Top1 = if ($null -ne $activeTimeTop1) { [math]::Round($activeTimeTop1, 1) } else { "" }
        ActiveTime_Top100Avg = if ($null -ne $activeTimeTop100Avg) { [math]::Round($activeTimeTop100Avg, 1) } else { "" }
        ActiveTime_Median = if ($null -ne $activeTimeMedian) { [math]::Round($activeTimeMedian, 1) } else { "" }
        Overheal_Best = [math]::Round($ohBest, 1)
        Overheal_Median = [math]::Round($ohMedian, 1)
        Overheal_Worst = [math]::Round($ohWorst, 1)
        Top100_TargetCoveragePct = [math]::Round($covAvg, 1)
        Top100_TargetTop1Pct = [math]::Round($top1PctAvg, 1)
        SampleSize = $n
        HPM_SampleUsed = $hpmSampleUsed
        ActiveTime_SampleUsed = $activeTimeSampleUsed
    }

    # ----- Aggregate spell composition across the full Top 100 sample, strictly by guid -----
    # NOT merged by name across different guids - confirmed on real data that two guids
    # sharing a display name can mean genuinely different things, not just localization
    # noise. Lifebloom's two guids (33763, 33778) both display as "Lifebloom" in every
    # language, but empirically: 33763 is 100% tick=true, small amount (~310) - the HoT
    # component; 33778 is 100% tick=false, larger amount (~515) - the "bloom" burst heal
    # on expiry. Collapsing those into one "Lifebloom" row would hide a real mechanical
    # split. Regrowth/Rejuvenation's dual guids look different again on inspection (both
    # show MIXED tick/non-tick behavior, similar amounts, just very different cast
    # frequency - consistent with rank variance, not a distinct mechanic) - but rather
    # than assert per-spell what each guid "means" (which only covers spells someone has
    # actually checked, and risks being wrong), every guid stays its own row, always.
    # When two guids share a resolved display name, the guid is appended to disambiguate
    # rather than guessing at a semantic label.
    $spellAgg = @{}
    $spellTotal = 0.0
    foreach ($r in $sorted) {
        foreach ($guid in $r.Abilities.Keys) {
            Add-GuidAggregate -Agg $spellAgg -Guid $guid -Name $r.Abilities[$guid].Name -Amount $r.Abilities[$guid].Total
            $spellTotal += $r.Abilities[$guid].Total
        }
    }
    $nameCounts = @{}
    foreach ($guid in $spellAgg.Keys) {
        $n = $spellAgg[$guid].Name
        if (-not $nameCounts.ContainsKey($n)) { $nameCounts[$n] = 0 }
        $nameCounts[$n]++
    }
    foreach ($guid in $spellAgg.Keys) {
        $pct = if ($spellTotal -gt 0) { ($spellAgg[$guid].Total / $spellTotal) * 100 } else { 0 }
        if ($pct -ge 0.5) {
            $displayName = $spellAgg[$guid].Name
            if ($nameCounts[$displayName] -gt 1) { $displayName = "$displayName (guid $guid)" }
            $spellCompRows += [PSCustomObject]@{
                Boss = $bossName
                Spell = $displayName
                Top100Pct = [math]::Round($pct, 1)
            }
        }
    }

    # ----- Aggregate cooldowns/utility/consumables across the full Top 100 sample -----
    $cdNames = @($cooldownGuids.Keys) + @("Mana Potion")
    $sampleWithCooldowns = @($sorted | Where-Object { $_.Cooldowns -ne $null })
    $cdSampleUsed = $sampleWithCooldowns.Count
    foreach ($cdName in $cdNames) {
        if ($cdSampleUsed -eq 0) { continue }
        $counts = $sampleWithCooldowns | ForEach-Object { $_.Cooldowns[$cdName].Count }
        $selfCounts = $sampleWithCooldowns | ForEach-Object { $_.Cooldowns[$cdName].SelfCount }
        $avgCasts = ($counts | Measure-Object -Average).Average
        $usedCount = @($counts | Where-Object { $_ -gt 0 }).Count
        $usedPct = ($usedCount / $cdSampleUsed) * 100
        $totalCasts = ($counts | Measure-Object -Sum).Sum
        $totalSelf = ($selfCounts | Measure-Object -Sum).Sum
        $selfPct = if ($totalCasts -gt 0) { ($totalSelf / $totalCasts) * 100 } else { $null }
        $cooldownRows += [PSCustomObject]@{
            Boss = $bossName
            Ability = $cdName
            Top100AvgCasts = [math]::Round($avgCasts, 1)
            Top100UsedPct = [math]::Round($usedPct, 0)
            Top100SelfPct = if ($null -ne $selfPct) { [math]::Round($selfPct, 0) } else { "" }
            SampleUsed = $cdSampleUsed
        }
    }

    # ----- Aggregate self-buff uptime across the full Top 100 sample -----
    # Flask/food are booleans (active at pull start or not) - aggregated as "% of
    # the sample that had it active", the same style as Top100UsedPct for cooldowns.
    # Tree of Life is a real reconstructed uptime % - averaged directly.
    $sampleWithBuffs = @($sorted | Where-Object { $_.BuffUptimes -ne $null })
    $buffSampleUsed = $sampleWithBuffs.Count
    if ($buffSampleUsed -gt 0) {
        $flaskCount = @($sampleWithBuffs | Where-Object { $_.BuffUptimes.FlaskActive }).Count
        $foodCount = @($sampleWithBuffs | Where-Object { $_.BuffUptimes.FoodActive }).Count
        $treeAvg = ($sampleWithBuffs | ForEach-Object { $_.BuffUptimes.TreeOfLifePct } | Measure-Object -Average).Average

        $buffRows += [PSCustomObject]@{
            Boss = $bossName
            Top100FlaskActivePct = [math]::Round(($flaskCount / $buffSampleUsed) * 100, 0)
            Top100FoodActivePct  = [math]::Round(($foodCount / $buffSampleUsed) * 100, 0)
            Top100TreeOfLifeAvgUptimePct = [math]::Round($treeAvg, 1)
            SampleUsed = $buffSampleUsed
        }
    } else {
        Write-Host "  NOTE: no buff data aggregated for $bossName (no players had a parseable consumables file)."
    }
}

$outSummary = Join-Path $workDir "benchmark_summary.csv"
$outSpells = Join-Path $workDir "benchmark_spell_composition.csv"
$outCooldowns = Join-Path $workDir "benchmark_cooldowns.csv"
$outBuffs = Join-Path $workDir "benchmark_buffs.csv"

# ===== Archive the previous CSV set before overwriting - active-model only (the old
# date-folder mode has no archived\ to put history in, and each date folder is already
# its own implicit snapshot). Only archives if a previous set actually exists AND it
# was generated on an earlier calendar day than today (a same-day re-run just overwrites
# in place, no duplicate history entry for the same day). Archived under the date the
# OLD set was valid for (manifest's prior benchmarkGeneratedDate), not today's date -
# see header comment. =====
if ($usingActiveModel -and (Test-Path $outSummary) -and $priorGeneratedDate -and ($priorGeneratedDate -ne $today)) {
    $historyDir = Join-Path (Join-Path $archivedDir "benchmark_history") $priorGeneratedDate
    New-Item -ItemType Directory -Force -Path $historyDir | Out-Null
    foreach ($f in @($outSummary, $outSpells, $outCooldowns, $outBuffs)) {
        if (Test-Path $f) {
            Copy-Item -Path $f -Destination $historyDir -Force
        }
    }
    Write-Host "Archived previous ($priorGeneratedDate) benchmark CSVs to $historyDir"
}

# -Encoding UTF8 is required here - Export-Csv's default encoding on Windows PowerShell
# 5.1 is NOT UTF-8 (varies, but can't represent characters outside its codepage), and
# silently substitutes "?" for anything it can't encode. Confirmed on real output: a
# real run without this produced "??" as literal spell names for two Lurker rows where
# the only ability name observed in that Top 10 sample was non-English (Korean/Chinese -
# see the "different guids sharing a name" note above for why those rows exist standalone
# rather than merged with an English-named row). This -Encoding UTF8 does still add a BOM
# on Windows PowerShell 5.1 (unlike the no-BOM fix used for the *_events.json files) -
# acceptable here since CSVs are commonly BOM-prefixed for Excel compatibility anyway,
# and project-knowledge upload / any reasonable CSV reader tolerates it.
$summaryRows | Export-Csv -Path $outSummary -NoTypeInformation -Encoding UTF8
$spellCompRows | Sort-Object Boss, @{Expression="Top100Pct";Descending=$true} | Export-Csv -Path $outSpells -NoTypeInformation -Encoding UTF8
$cooldownRows | Sort-Object Boss, Ability | Export-Csv -Path $outCooldowns -NoTypeInformation -Encoding UTF8
$buffRows | Sort-Object Boss | Export-Csv -Path $outBuffs -NoTypeInformation -Encoding UTF8

if ($usingActiveModel) {
    $manifest.benchmarkGeneratedDate = $today
    Save-ManifestLocal -Manifest $manifest -Path $manifestPath
}

Write-Host ""
Write-Host "Done. Wrote:"
Write-Host "  $outSummary"
Write-Host "  $outSpells"
Write-Host "  $outCooldowns"
Write-Host "  $outBuffs"
if ($usingActiveModel) {
    Write-Host "Updated manifest.json benchmarkGeneratedDate -> $today"
}
Write-Host ""
Write-Host "Upload all four CSVs to project knowledge - small, text-based, no zip needed."
