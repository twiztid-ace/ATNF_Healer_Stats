# ATNF Healer Analysis — Master Workflow
 
This document is the single source of truth for how we analyze a healer's raid performance
using Warcraft Logs data. Read this first before starting any new healer analysis.
 
## Overview of the pipeline
 
1. Get the character's name + a WCL report link for the raid night to analyze.
2. Pull that report's fight list (confirms roster, class/spec, boss kill timestamps).
3. Pull the healer's healing and casts data — complete per-event breakdowns, not
   the truncated table view (see "Why healing/casts moved to events, not tables"
   below), plus flask/food/Tree-of-Life and deaths. For Resto Druid this is fully
   automated via `pull_character_TEMPLATE.ps1`, migrated to the **v2 GraphQL API**
   2026-07-12 (see "v2 GraphQL API (Druid + Shaman pipelines)" below) — see that script's
   own header comment for usage. Other classes' manual/scripted pulls still use
   v1 REST (`/report/events/{healing,casts}/` with `sourceid=`).
4. Pull the healer's real WCL percentile for each fight — for Druid, a single
   exact per-fight rankings call as part of step 3 above (v2); for other classes,
   the v1 `parses/character` endpoint, which is fuzzy-matched and confirmed
   structurally incomplete (see the v2 section's "why this migration happened").
5. (Optional, for deeper analysis) Pull Top 100 benchmark data for the healer's
   class/spec on each boss via `pull_top100_druid.ps1`/`pull_top100_shaman.ps1` (v2
   GraphQL, migrated/ported 2026-07-12) or `pull_top100_TEMPLATE.ps1`/other classes'
   scripts (still v1 REST), then run `summarize_class_benchmarks.ps1` to condense it
   into four benchmark CSVs (see "Data delivery convention" below) — this is what
   actually gets referenced for spell composition, target distribution, and (Druid
   and Shaman only, as of 2026-07-11/2026-07-12 respectively) cooldown/consumable
   comparisons, not the raw files. Self-buff-uptime comparison (Tree of Life) is
   Druid-only — no equivalent concept exists for Shaman, confirmed against real
   data. For Druid and Shaman specifically, both scripts operate on an
   `active`/`archived` + `manifest.json` layout, not a fresh date folder per run —
   see "Active/archived data model" below before running either one.
6. Build the site pages (see "Site structure" below) using real data only — never
   fabricate or estimate numbers we haven't actually pulled.
## API basics

**Two API versions coexist now — don't conflate them.** This section (and "Key
endpoints", and the manual curl walkthrough further down) documents the **v1 REST
API**, still the live mechanics for `pull_top100_paladin.ps1`/
`pull_top100_priest_holy.ps1`/`pull_top100_shaman.ps1` and their manual-pull
fallback. `pull_character_TEMPLATE.ps1` and `pull_top100_druid.ps1` were migrated
to the **v2 GraphQL API** on 2026-07-12 — see "v2 GraphQL API (Druid + Shaman pipelines)"
right after "Key endpoints" below for that API's own auth model, endpoint
mapping, and the real bugs its migration surfaced. The v1 content below remains
accurate for the three classes still on it, and the underlying data
model/methodology lessons (guid-based grouping, no letter grades, gear audit
design, etc.) apply identically regardless of which API version pulled the data.
 
- **Base URL**: `https://fresh.warcraftlogs.com/v1`
- **Auth**: query param `api_key=...` (read from `apikey.txt` at repo root — never
  hardcode the key in scripts or commit it to git)
- This is the **V1 API** (deprecated but still functional on the Fresh realm cluster).
  Some endpoints behave unexpectedly — see "Gotchas" below.
- Reports can be **private**. If a report code returns `{"status":400,"error":"This
  report does not exist or is private."}`, that's not a typo issue — the report owner
  needs to make it public, or someone with access needs to share the raw data another way.
## Key endpoints
 
| Purpose | Endpoint |
|---|---|
| Fight list + roster for a report | `GET /report/fights/{reportCode}?api_key=...` |
| Complete per-event healing/casts/etc for ONE player | `GET /report/events/{view}/{reportCode}?start=X&end=Y&sourceid={playerID}&api_key=...` |
| A table view (healing/casts/buffs/deaths/etc) for ALL players of a class in a fight | `GET /report/tables/{view}/{reportCode}?start=X&end=Y&sourceclass={Class}&api_key=...` — **truncates per-player breakdowns at 5 entries, see below; prefer `/report/events/` for anything needing completeness** |
| Combatant gear/talent snapshot | `GET /report/events/{reportCode}?start=X&end=Y&filter=type%3D%22combatantinfo%22&api_key=...` (the one confirmed case where the flat, no-`{view}` form of `/report/events/` is the right call, not `/report/events/{view}/{code}`) |
| Zone list (get encounter IDs) | `GET /zones?api_key=...` |
| Class/spec ID lookup | `GET /classes?api_key=...` |
| Top 100 rankings for one boss | `GET /rankings/encounter/{encounterID}?metric=hps&spec={specID}&class={classID}&api_key=...` |
| A character's real percentile per boss (best parse only) | `GET /rankings/character/{name}/{server}/{region}?zone=1056&metric=hps&api_key=...` |
| ALL of a character's parses (not just best) | `GET /parses/character/{name}/{server}/{region}?zone=1056&metric=hps&api_key=...` |
 
Use `parses/character` (not `rankings/character`) when you need the percentile for a
*specific* fight rather than the character's all-time best on that boss.

## v2 GraphQL API (Druid + Shaman pipelines, migrated/ported 2026-07-12)

**Why this migration happened.** `parses/character` above (v1's "get every parse"
endpoint) turned out to be structurally incomplete — real-tested against
Danceswtrees's report `Fm9XdWYtz8VCLnwg`, it returned a match for only 1 of 9 real
boss kills, even after deleting the cached file and re-pulling fresh (ruling out a
stale-cache or bad-connection explanation). `rankings/character` (the "best parse
only" endpoint) can't help either — by design it only has one entry per
character+encounter. Neither v1 endpoint can answer "what was this exact
report+fight's percentile," which turns out to be exactly what WCL's own site
uses internally to show a percentile on the Healing tab of a specific pull.
v2's `reportData.report(code).rankings(fightIDs:[...], playerMetric: hps)`
answers that directly and exactly — confirmed live, matched Danceswtrees's own
computed HPS on all 9 real kills.

**Original scope: `pull_character_TEMPLATE.ps1` and `pull_top100_druid.ps1`.** Both
were fully migrated and passed real equivalence testing (byte-for-byte matching
field values against known-good v1 output) before taking over their production
filenames — the old v1 versions are preserved as `pull_character_TEMPLATE_v1.ps1`
/ `pull_top100_druid_v1.ps1` for reference/rollback, untouched otherwise.

**Extended to Shaman 2026-07-12 (Phase 3 pilot):** `pull_top100_shaman.ps1` was
ported to this same v2 GraphQL + active/archived model the same day, using
`pull_top100_druid.ps1` as the structural reference (the old v1 Shaman script
shared almost nothing with it — sequential, single healing-TABLE-per-parse, no
casts/consumables/activetime/deaths). `pull_character_TEMPLATE.ps1` needed zero
changes for this — it's already fully class-agnostic. See this file's "v2 GraphQL
API" section further down for the full Shaman-specific writeup (real cooldown
guids, the confirmed absence of a Rebirth- or Tree-of-Life-equivalent for this
class). Paladin/Priest remain on v1 REST — migrating their auth/endpoints to v2 is
a separate future decision, deliberately not bundled with their still-open
events-based methodology modernization (see gotcha #25) so the two don't get
conflated.

**Auth**: OAuth2 client-credentials grant, not a query-string API key.
- Register a client at `https://www.warcraftlogs.com/api/clients/` (Name: anything;
  Redirect URL: a placeholder like `http://localhost` — required by the form, unused
  by this grant type).
- Token endpoint: `https://www.warcraftlogs.com/oauth/token`,
  `curl -u {client_id}:{client_secret} -d grant_type=client_credentials ...`.
- GraphQL endpoint: `https://www.warcraftlogs.com/api/v2/client`,
  `Authorization: Bearer <token>` header.
- Three files at repo root, gitignored like `apikey.txt`: `v2_client_id.txt`,
  `v2_client_secret.txt`, `v2_access_token.txt` (the last one auto-created/
  refreshed — real tokens observed to last ~360 days).
- All of this is wrapped in **`scripts\lib\WclV2Api.psm1`** — `Get-WclAccessToken`,
  `Invoke-WclGraphQL`, `Invoke-WclGraphQLPaged`. Any new v2 script should
  `Import-Module` this rather than reimplementing auth/query plumbing.

**Confirmed v1 → v2 endpoint mapping** (every row tested live against real data,
not assumed from docs):

| v1 REST | v2 GraphQL | Real difference to know about |
|---|---|---|
| `/report/fights/{code}` | `reportData.report(code).fights(...)` + `masterData.actors(...)` | v2's unified `actors[]` replaces v1's friendlies/enemies/friendlyPets/enemyPets 4-way split — confirmed nothing downstream ever needed that split |
| `/report/events/{healing,casts}/{code}?sourceid=` | `events(fightIDs, sourceID, dataType: Healing\|Casts, includeResources: true)` | **Now genuinely paginated** (`{data, nextPageTimestamp}`) — v1's completeness was an unverified assumption (see gotcha #15's own header); event shape is leaner by default (`abilityGameID` flat int instead of `ability{name,guid,type,abilityIcon}`) — ability name reconstructed via `gameData.ability(id)`, cached per unique guid |
| `/report/events/buffs/{code}?sourceid=` | `events(dataType: Buffs, ...)` | same |
| `combatantinfo` filter | `events(dataType: CombatantInfo, ...)` | same |
| `/report/tables/healing/{code}` (activeTime only) | `table(dataType: Healing, ...)` | confirmed byte-identical field values |
| `/report/tables/deaths/{code}` | `table(dataType: Deaths, ...)` | confirmed byte-identical entry shape, no reshaping needed |
| `/rankings/encounter/{id}?metric=hps&spec=&class=` | `worldData.encounter(id).characterRankings(className, specName, metric, page)` | page 1 = same 100 entries, still rank-ordered by array position (v2 entries don't carry a populated per-entry `rank` field either) — but `report.code`/`report.fightID`/`amount` are NESTED, replacing v1's flat `reportID`/`fightID`/`total` — **must be reshaped back to v1's flat names before ever touching disk**, see gotcha #28 |
| `/parses/character/...` (the broken one) | `reportData.report(code).rankings(fightIDs:[...], playerMetric: hps)`, called once per report | replaces the whole endpoint — exact by construction, no fuzzy matching |

**Output file shapes are unchanged from v1** — every migrated pull script
reconstructs v1's exact field names before writing to disk, so
`build_boss_report_data.ps1`/`summarize_class_benchmarks.ps1` needed no changes
to their own logic, with two narrow, deliberate exceptions: (1)
`build_boss_report_data.ps1`'s percentile lookup now reads a new
`{reportCode}_v2_rankings.json` (exact per-fight match) instead of fuzzy-matching
against `{name}_all_parses.json`; (2) `rankings_{boss}.json` gets explicitly
reshaped before being written (see gotcha #28) since
`summarize_class_benchmarks.ps1` reads that file directly.

**Rate limits**: v1 was 800 calls/hour flat. v2 is 3600 **points**/hour
(`rateLimitData{limitPerHour, pointsSpentThisHour, pointsResetIn}`), cost scales
with query complexity rather than 1-call-1-unit — batching multiple fights into
one query (e.g. all of one report's boss kills' rankings in a single call) is
cheaper than a 1:1 REST-style translation, not just more convenient.

**Confirmed live 2026-07-12 (Shaman Phase 3 port)**: this resets on a rolling
hourly clock, not a fixed clock-hour boundary. Hit a real full lockout after a
day of heavy pulling (a Danceswtrees re-pull, a Vajomee pull, a full Druid Top
100 pull, and two Shaman Top 100 pull attempts, all in the same session) —
every request started returning HTTP 429, including the lightweight
`rateLimitData` diagnostic query itself. Don't keep retrying a burst of 429s
expecting it to clear in a minute or two; either check `pointsResetIn` (when
that query isn't itself rate-limited) or just wait out the rest of the current
hour before retrying a large pull.

The original Druid migration's full phased rollout and verification steps were
recorded in a now-superseded plan file — that file has since been overwritten with
the Shaman Phase 3 port's own plan (plan files are session-scoped working
documents, not permanent project records; this section of WORKFLOW.md is the
durable copy of the Druid migration's rationale). For the Shaman port's own
rationale/phasing, `C:\Users\raymo\.claude\plans\playful-baking-sunset.md` is
still current as of 2026-07-12.

### Why healing/casts moved to events, not tables (2026-07-11)

The obvious way to pull a player's healing or cast data is `/report/tables/{healing,
casts}/{code}?sourceclass=X` — that's what this pipeline used from the start, and it's
still the right call for `buffs` and `deaths`. It turned out to be wrong for `healing`
and `casts` specifically, discovered mid-session while chasing down why a confirmed
real Innervate cast wasn't showing up anywhere:

**The bug.** `/report/tables/{view}/{code}` silently caps each player's per-ability
`abilities[]` breakdown at 5 entries. The entry-level `total` stays accurate; only the
list of *which* spells made up that total gets cut off, with no error, no warning, no
signal at all. Confirmed on two independent real cases in the same pull:
- Danceswtrees's Leotheras kill: the healing table's `total` said 176,374, but the 5
  listed abilities only summed to 166,830 — 9,544 points of healing (5.4%) missing.
- Turkeykin's Hydross kill: the casts table listed exactly 5 abilities (Starfire,
  Moonfire, Faerie Fire, Force of Nature, Spell Power) with no Innervate at all, despite
  Innervate definitely being cast that fight — confirmed via a real target (Turkeykin →
  Churbert) once we started reading events instead.

This is the same undocumented cap already known for `targets[]` (gotcha #4) — it turns
out `abilities[]` has it too, and it's worse in practice, since spell composition
(the flagship comparison on every boss page) depends on it, and most fights involve
casting well more than 5 distinct spells.

**The fix.** `/report/events/{view}/{code}` returns complete, per-event records with no
cap, and — once the right query parameters were found — can be scoped to exactly one
player. Getting there took several wrong turns worth knowing about so they don't get
repeated:
- `filter=type%3D%22heal%22` (URL-encoded `type="heal"`) works as a *type* filter, but
  `source.id=`, `sourceID=`, and a bare `source=` inside that same filter string were
  all silently ignored rather than erroring — each one just returned the full unfiltered
  event list for the fight (thousands of events) instead of one player's.
- Pulling the actual v1 swagger spec (not just the JS-rendered docs page, which this
  environment's fetch tool can't execute — see the person's browser dev tools if this
  ever needs re-checking) settled it: the real path is `/report/events/{view}/{code}`
  with `view` as a required path segment (`healing`, `casts`, etc. — same enum as the
  tables endpoint), and `sourceid` is a real, documented, **standalone query parameter**
  — never valid inside the `filter=` expression string. `abilityid` works the same way
  for filtering to one ability, and (per the same spec) is also the correct parameter
  name for the `resources`/`resources-gains` views' resource-type filter — `resourcetype`
  (tried earlier, see the dead gotcha it used to be under) was simply the wrong name.
  Nobody's re-tested `resources` with `abilityid` yet; worth one manual call before
  building it into a script.
- Confirmed via `sourceid=` on real data: goes from thousands of events (a whole fight,
  every class) down to exactly one player's — this is the mechanism both
  `pull_character_TEMPLATE.ps1` and `pull_top100_druid.ps1` now use for `healing` and
  `casts`. No documented pagination/limit exists for this endpoint; a real 3,983-event
  unfiltered pull for one fight came back complete (last event landed within 90ms of
  the fight's true end) — reassuring but not a guarantee for busier fights, which is
  why both pull scripts log a warning if any single player's event count looks
  suspiciously high (≥2,900) rather than trusting silently.

**What this means for existing data.** Every `_healing.json`/`_casts.json` (or
`benchmark_spell_composition.csv`/`benchmark_cooldowns.csv`) produced before this fix —
for any class, not just Druid — should be treated as unverified, not just "possibly a
little off." The new output files are named `_healing_events.json`/`_casts_events.json`
specifically so old and new data can never look identical in a folder listing.

**Active time — re-discovered, not gone (2026-07-12).** When healing/casts moved off
the table endpoint, "Active time" (`activeTime`/`activeTimeReduced`) was dropped from
the Scorecard on the stated premise that no event carries an equivalent field, and
"Raid deaths" took its place as the 4th stat. That premise was never actually tested —
it was just abandoned along with the rest of the table endpoint. Re-checked later
(same "test before assuming it's gone" instinct that resurrected HPM — see the HPM
section below): the truncation bug is specifically in the table response's nested
`abilities[]`/`targets[]` breakdown arrays, not in every field on the response. The
top-level per-player `activeTime`/`activeTimeReduced` scalars are untouched by it.
Verified for real: pulled `/report/tables/healing/{code}?start=X&end=Y&api_key=...`
for Danceswtrees's real Hydross kill and got `activeTime=138449`, fight
duration=143007ms → 96.8%, exactly matching the number already recorded on the
pre-events-rewrite v1 page. `total`/`overheal` on that same entry also matched the
events-based numbers exactly (further cross-validation), and the response's
`abilities[]` array WAS confirmed still truncated at 5 entries in this same test —
so the truncation bug is real and reproducible, it just doesn't reach this field.
Both pull scripts now fetch this via one extra table call per parse/fight (same shape
as the existing `deaths` call, matched by player name in the response) and save it as
`*_activetime.json`. The Scorecard is back to 5 stats: HPS, Overheal, Effective
healing, Active time, Raid deaths.

**Consumables note (unchanged by this fix):** mana potions/Dark Runes still show up
fine as cast events (e.g. `"Restore Mana"` for a mana potion's proc) — that part of the
original ask was never affected by the truncation bug, since the character-level total
cast count for a *specific single ability* rarely exceeds whatever was cutting off the
5-entry list in the first place. It's the *breadth* of distinct spells in a fight that
triggers the truncation, which consumable tracking doesn't depend on.

`deaths` stays as a `/report/tables/` call — no truncation evidence found. `buffs` no
longer uses a table call at all — it had its own, separate, more serious problem (see
"Buff uptime — fixed" below) that the table approach couldn't be patched around.

### Buff uptime — fixed, replaced the broken table-based approach (2026-07-11)

`/report/tables/buffs/{code}?sourceclass=Druid&hostility=0` (no `by=` parameter) does
**not** return one player's buffs — it merges every Druid in the fight into one flat
`auras[]` list with no per-player attribution at all. Confirmed on real data: a single
file simultaneously listed Moonkin Form, Dire Bear Form, and Tree of Life (three
different Druid specs' forms — impossible for one character), plus duplicate "Well
Fed" and duplicate "Tree of Life" entries. Any flask/food/Tree-of-Life uptime number
produced by this pipeline before 2026-07-11 was never actually scoped to the player it
claimed to represent — this is a correctness bug, not just an unverified number.

The fix uses two different mechanisms, not one, because flask/food and Tree of Life
have genuinely different uptime characteristics:

**Flask/Elixir + food** — pulled from the `combatantinfo` snapshot event (the flat,
no-`{view}`-segment form of `/report/events/`, `filter=type%3D%22combatantinfo%22`).
Its `auras[]` list includes whatever buffs were already active the moment the
snapshot was taken. These consumables last 1-2 hours, far longer than any single
fight, so "was it active when the pull started" reliably stands in for "was it active
the whole fight" — reported as a plain **yes/no**, not a computed percentage, since a
snapshot genuinely can't tell you more than that. This also solves a problem no
apply/remove event reconstruction ever could: a flask drunk before the log started
recording has no `applybuff` event anywhere in the data, but it still shows up in the
snapshot's `auras[]` list.

**The snapshot doesn't always fall inside the fight's own `[start_time, end_time]`
window.** Confirmed on a real Kael'thas kill: zero `combatantinfo` events existed
inside the fight's own window for any player, but a real snapshot for the analyzed
character existed 33.6 seconds *before* `start_time` — logged when the raid engaged
trash/positioned near the encounter, before WCL's recorded pull began. The fix
queries a 2-minute backward buffer (`start_time - 120000` through `end_time`) and
picks whichever snapshot is closest to `start_time`, preferring one before start over
one after. On real data across 200 Top 100 parses, one case (a likely late-joiner)
had no snapshot even within that buffer — this is reported as a failure for that
one player's consumables data specifically, not treated as "no flask" (a real
absence and a missing snapshot are different things, and conflating them would
silently fabricate a false negative).

**Tree of Life** is different — it visibly toggles mid-raid (confirmed on real data:
a character dropped out of Tree Form mid-fight specifically to combo Nature's
Swiftness with Healing Touch, a real TBC-era mechanic interaction), so a pull-start
snapshot isn't enough. This one needs real interval reconstruction from
`/report/events/buffs/{code}?sourceid=` apply/remove events. Two things had to be
worked out against real data before this was reliable:
- **Tree of Life logs under two guids** (33891, 34123) that always show 33891 paired
  with 34123 at the same timestamp, but 34123 *also* fires on its own in rapid apply/
  remove/refresh cycles within a single fight that don't match manual form-toggling
  at all. Only guid 33891 is used for uptime — empirically the trustworthy signal.
  34123's exact meaning was never verified and it's excluded rather than guessed at
  (same principle as gotcha #20's guid-disambiguation rule).
- **Orphan `removebuff` events (no matching prior `applybuff`) occur more than once
  per report, not just at the very start.** The first version of this reconstruction
  treated every orphan as "buff was active since the window's start" — wrong,
  produced an impossible >100% uptime when tested against real data, because later
  orphans in the same report aren't the same situation as the very first event. Only
  the FIRST event in the queried window can be safely read that way; every later
  orphan is a no-op (the state simply doesn't change — she's already not in the
  buff, and a redundant remove event doesn't tell you anything new).

**Scope differs between the two pull scripts.** `pull_character_TEMPLATE.ps1` pulls
Tree of Life events **once per report** (`start=0` to the report's end) since one
character's whole raid night is being analyzed — reused across all 10 of their boss
kills, then intersected with each fight's own window for per-fight %.
`pull_top100_druid.ps1` scopes the same query to **just the one fight each parse
represents** instead — there's no report-wide amortization benefit there, since every
Top 100 parse is (almost always) a different player from a different report, so
there's nothing to reuse across fights the way there is for one person's raid night.

Output changed from `*_buffs.json` (table format, broken) to `*_consumables.json`
(new format: `{flaskActive, flaskName, foodActive, foodName, treeOfLifeUptimePct}`),
`benchmark_buffs.csv` is produced again by `summarize_class_benchmarks.ps1`, and
`boss_page_template_druid.html`'s Cooldowns & Consumables section shows real
flask/food/Tree of Life data again instead of the "temporarily unavailable" note.

### Active/archived data model — replaces date-stamped folders (2026-07-12, Druid; extended to Shaman same day)

Every Top 100 pull used to create a fresh `data\Classes\{Class}\{date}\` folder and
re-fetch all ~1,000 parses from scratch, even though the vast majority of a boss's
Top 100 doesn't change between runs, and a completed log's healing/casts/consumables
data can never change once pulled — that's pure wasted API budget against WCL's
800-calls/hour cap. `pull_top100_druid.ps1` and `summarize_class_benchmarks.ps1` were
both rewritten to fix this. `pull_top100_paladin.ps1`/`pull_top100_priest_holy.ps1`/
`pull_top100_shaman.ps1` are NOT on this model — they're still both v1 (table-based)
AND the old date-folder convention, two separate things that happen to coincide on
those three classes today.

**Layout:**
```
data\Classes\{Class}\
  manifest.json
  active\
    rankings_{boss}.json           <- current snapshot only, one per boss
    {Boss}\{reportID}_{fightID}_{playerName}_{healing_events,casts_events,consumables,activetime}.json
    {Boss}\{reportID}_{fightID}_deaths.json     <- never archived, see below
    benchmark_summary.csv, benchmark_spell_composition.csv, benchmark_cooldowns.csv, benchmark_buffs.csv
  archived\
    {Boss}\{reportID}_{fightID}_{playerName}_{...}.json   <- parses dropped from the Top 100, kept forever (moves back to active\ if the parse re-enters, see below)
    rankings_history\{Boss}\{date}.json                    <- only written when membership actually changed
    benchmark_history\{date}\benchmark_*.csv               <- only written on a real day-over-day regen
```

**manifest.json schema:**
```json
{
  "schemaVersion": 2,
  "className": "Druid",
  "classID": 2,
  "specID": 4,
  "benchmarkGeneratedDate": "2026-07-12",
  "bosses": {
    "Hydross": {
      "encounterID": 100623,
      "lastPulledDate": "2026-07-12",
      "rankingsSnapshotDate": "2026-07-10",
      "parses": {
        "1QMqcBHgTZV3WALD_4_Ceeta": {
          "reportID": "1QMqcBHgTZV3WALD", "fightID": 4, "playerName": "Ceeta", "safeName": "Ceeta",
          "status": "active", "rank": 80, "hps": 1173.7,
          "firstSeenAt": "2026-07-10T00:00:00Z",
          "lastConfirmedInTop100At": "2026-07-12T07:48:32Z",
          "archivedAt": null
        }
      }
    }
  }
}
```
Parse keys are `{reportID}_{fightID}_{playerName}` — the same identity already used
in filenames, matching how `summarize_class_benchmarks.ps1` has always cross-referenced
a healing-events file against its rankings entry.

**Per-boss diff algorithm, every run:** fetch fresh rankings (1 call, unchanged),
build the fresh `{reportID}_{fightID}_{name}` key set, diff against the manifest's
parses for that boss (all four cases below, not just three — see the fix note after):
- **In fresh, no manifest entry at all** → genuinely new. Runs the full per-parse fetch
  (healing/casts/consumables/activetime/deaths, unchanged worker logic). Only added to
  the manifest once fully successful — a partial failure (e.g. healing succeeded,
  casts didn't) leaves the parse out of the manifest entirely, so the next run's diff
  sees it as "new" again and retries; the per-file `Test-Path` check already in the
  worker skips whatever piece already succeeded, only the missing piece is re-fetched.
- **In both, manifest status `"active"`** → still in the Top 100, **zero API calls** —
  `rank`/`hps`/`lastConfirmedInTop100At` are refreshed from the rankings response
  already in hand.
- **In manifest-active, not in fresh** → dropped out. Its `healing_events`/
  `casts_events`/`consumables`/`activetime` files move from `active\{Boss}\` to
  `archived\{Boss}\` (kept forever, never deleted), manifest status flips to
  `"archived"`.
- **In fresh, manifest status `"archived"`** → **re-entered** the Top 100 after
  previously dropping out. Also **zero API calls** — the exact reverse of the drop
  case: files move back from `archived\{Boss}\` to `active\{Boss}\`, manifest status
  flips back to `"active"`, `archivedAt` clears, `rank`/`hps`/
  `lastConfirmedInTop100At` refresh from the rankings response already in hand — but
  `firstSeenAt` is deliberately left untouched, since it should reflect the parse's
  real first appearance, not this re-entry.
- `deaths.json` is **never archived**, regardless of whether the parse(s) referencing
  it get archived — fight-wide (not per-parse), tiny, not worth refcounting.

**Bug fixed 2026-07-12: re-entry used to be silently mishandled.** The original diff
only computed three cases (new/still-active/dropped), and defined "new" as "fresh AND
not currently active" — that doesn't distinguish a genuinely new parse from a
re-entering one, so a re-entering parse fell into the "new" bucket: wastefully
re-fetched from the API even though its completed-log data can never change, its
manifest entry fully overwritten (losing the real `firstSeenAt`), and its stale
archived copy never cleaned up — leaving the same parse's files in both `active\` and
`archived\` at once. Fixed by adding the real 4th case above. While fixing this, also
found and fixed a related gap: the drop/restore suffix list never included
`activetime` (added to the pipeline later than the other three file types and never
wired into archiving) — parses archived before this fix left an orphaned
`activetime.json` behind in `active\{Boss}\`, harmless (archived parses don't feed the
benchmark aggregate) but real. Verified via two isolated tests (mock manifest diff +
scratch-directory file-move), not yet exercised against a real re-entry in production.

**Rankings file is only rewritten (and the old version archived) on a real membership
change** — defined as at least one add or drop from the diff above, not a pure
rank/HPS reshuffle among the same 100 people (which shouldn't happen anyway, since a
completed log's HPS for a fixed report+fight+player is a fixed fact — the only way the
list moves is someone new entering or someone dropping off, which the membership diff
already catches). The old snapshot is archived to
`archived\rankings_history\{Boss}\{the date it was captured}.json` before being
overwritten — named for when it was valid, not when it got replaced.

**Staleness is always a plain `yyyy-MM-dd` date, compared to today at read time — never
a stored boolean.** A stored `isStale: true/false` flag would silently go wrong the
instant the date rolls over past midnight with nothing having re-checked it. Two such
date fields exist: `bosses.{Boss}.lastPulledDate` (advances every successful check,
even a no-op one — "we confirmed this is current as of today") and
`bosses.{Boss}.rankingsSnapshotDate` (only advances when content actually changed —
so "Hydross's Top 100 hasn't moved since 2026-07-09" is a readable fact straight out
of the manifest). `benchmarkGeneratedDate` is the same idea at the class level (the
four CSVs bundle every boss into one file each, so there's no per-boss version of it).
`summarize_class_benchmarks.ps1` always regenerates all four CSVs regardless of this
comparison — recomputation is local/free, no API calls — the date comparison is purely
informational (and drives whether the previous CSV set gets archived, see below), not
a gate on whether to run.

**CSV history:** before `summarize_class_benchmarks.ps1` overwrites `active\
benchmark_*.csv`, if a previous set exists AND `manifest.benchmarkGeneratedDate` is an
earlier calendar date than today (i.e. this is a real new day's regen, not a same-day
re-run), the existing four CSVs are copied to
`archived\benchmark_history\{that old date}\` first. Re-running twice on the same
calendar date just overwrites `active\` in place — one folder per day the numbers
actually changed, not one per run.

**Migration:** `scripts\migrate_class_to_active.ps1 -ClassName {Class} -DateFolder
{date}` converts an existing date-folder pull into this layout — everything on disk
becomes the first `active\` snapshot (nothing to diff against yet, so every parse
currently present is recorded `"active"` with `firstSeenAt`/`lastConfirmedInTop100At`
both set to the given date). Already run once, for Druid, against the 2026-07-10 pull.
Only needs to run again when a v1 class gets ported to this model — not something that
runs repeatedly.

**Real validation (2026-07-12):** live-tested against the actual WCL API twice.
First: single-boss run (Hydross) where rankings were genuinely unchanged — correctly
skipped all 100 per-parse fetches and the rankings rewrite, only `lastPulledDate`
advanced. Second: full 10-boss run — 8 bosses unchanged (0 API calls beyond the
rankings check each), Leotheras and Karathress both had real churn (2 new + 2 dropped
each), correctly archived the 2 dropped parses' files and the old rankings snapshot,
correctly fetched the 2 new parses (4 total, 0 failed). Total API usage for that
10-boss run: ~10 rankings calls + ~16-20 calls for the 4 new parses, versus roughly
4,000+ calls the old date-folder approach would have burned re-fetching all 1,000
parses from scratch every time.
 
## SSC/TK reference IDs
 
Zone ID: **1056**
 
| Boss | Encounter ID |
|---|---|
| Hydross the Unstable | 100623 |
| The Lurker Below | 100624 |
| Leotheras the Blind | 100625 |
| Fathom-Lord Karathress | 100626 |
| Morogrim Tidewalker | 100627 |
| Lady Vashj | 100628 |
| Al'ar | 100730 |
| Void Reaver | 100731 |
| High Astromancer Solarian | 100732 |
| Kael'thas Sunstrider | 100733 |
 
| Class | ID | Restoration/Holy spec ID |
|---|---|---|
| Druid | 2 | 4 (Restoration) |
| Paladin | 6 | 1 (Holy) |
| Priest | 7 | 1 (Discipline) or 2 (Holy) |
| Shaman | 9 | 3 (Restoration) |
 
Full class/spec table available via `GET /classes` if a new class comes up.
 
## Pulling a specific character's raid data — exact commands

**Prefer `pull_character_TEMPLATE.ps1` over doing this by hand.** It automates all of
steps 1-4 below (fight list, healing/casts/buffs/deaths per boss kill, full parse
history) including resolving class/server/region from the report itself. The manual
walkthrough below is kept as a reference for understanding what the script is doing,
and as a fallback if the script doesn't fit a specific case (e.g. a character who
needs to be resolved from a different report than the one being analyzed).

**Note: the curl commands below document v1 REST mechanics.**
`pull_character_TEMPLATE.ps1` itself was migrated to the v2 GraphQL API on
2026-07-12 (see "v2 GraphQL API (Druid + Shaman pipelines)" above) — its real, current
mechanics are GraphQL queries via `WclV2Api.psm1`, not the v1 curl calls below.
This walkthrough remains accurate as the conceptual data model (what gets
pulled, in what shape, and why) and is still the literal mechanics for any
manual pull or for a class whose script hasn't been migrated yet.

This is the step-by-step recipe for step 1-4 of the pipeline above, generalized from
how we did it for Danceswtrees, Crowns, and Vajomee. Replace `{REPORT_CODE}`,
`{CHARACTER_NAME}`, `{SERVER}`, `{REGION}`, and the boss time ranges with the real
values for the character/raid being pulled.
 
**Step 1 — Get the report's fight list** (confirms roster, class/spec, boss timestamps):
```bash
curl -s "https://fresh.warcraftlogs.com/v1/report/fights/{REPORT_CODE}?api_key={API_KEY}" -o fights_{REPORT_CODE}.json
```
From the response, find the character in `friendlies[]` to confirm their `type` (class)
and check `fights[]` (top-level, filter to `boss != 0` and `kill == true`) for each
boss's `id`, `start_time`, and `end_time`. **If the report code has already been pulled
for a different character in this project** (e.g. two healers logged the same raid
night), reuse that same fights file instead of re-fetching — this happened with
Danceswtrees and Crowns both being in report `XJp8vAxzM4KtHYyb`.
 
**Step 1 — Get the report's fight list** (confirms roster, class/spec, boss timestamps):
```bash
curl -s "https://fresh.warcraftlogs.com/v1/report/fights/{REPORT_CODE}?api_key={API_KEY}" -o fights_{REPORT_CODE}.json
```
From the response, find the character in `friendlies[]` to confirm their `type` (class),
`server`, `region`, and — as of the 2026-07-11 events-based rewrite — their **`id`**,
the report-local numeric actor ID needed to scope the healing/casts pulls below to just
this player. Check `fights[]` (top-level, filter to `boss != 0` and `kill == true`) for
each boss's `id`, `start_time`, and `end_time`. **If the report code has already been
pulled for a different character in this project** (e.g. two healers logged the same
raid night), reuse that same fights file instead of re-fetching — this happened with
Danceswtrees and Crowns both being in report `XJp8vAxzM4KtHYyb`.
 
**Step 2 — Pull healing and casts for each boss kill**, scoped to this player's `id`
from Step 1 (`{PLAYER_ID}` below) via `/report/events/`, NOT `/report/tables/` — see
"Why healing/casts moved to events, not tables" above for why:
```bash
curl -s "https://fresh.warcraftlogs.com/v1/report/events/healing/{REPORT_CODE}?start={START}&end={END}&sourceid={PLAYER_ID}&api_key={API_KEY}" -o fight{FIGHT_ID}_{bossname}_healing_events.json
curl -s "https://fresh.warcraftlogs.com/v1/report/events/casts/{REPORT_CODE}?start={START}&end={END}&sourceid={PLAYER_ID}&api_key={API_KEY}" -o fight{FIGHT_ID}_{bossname}_casts_events.json
```
Each event's `sourceID`/`targetID` are raw numeric actor IDs — resolve them to real
names using the SAME `friendlies[]`/`enemies[]`/pet lists from Step 1's fights response
(build an id→name lookup once per report, reuse it). Aggregate per-ability by `guid`,
not by the event's `ability.name` (gotcha #2) — and don't merge different guids that
happen to share a resolved name without checking first (gotcha #20).

Pull `deaths` as a `/report/tables/` call, unchanged — no truncation evidence found.
It has no `sourceclass` param and isn't per-player — pull it once per report+fight,
not once per player (gotcha #12). `buffs` no longer uses a table call at all (see
"Buff uptime — fixed" above) — pull a `combatantinfo` snapshot (flask/food, searching
a 2-minute backward buffer from the fight's `start_time` and taking whichever
snapshot is closest) plus a `sourceid`-scoped `/report/events/buffs/` pull for Tree of
Life (guid 33891 only, reconstructed into intervals):
```bash
curl -s "https://fresh.warcraftlogs.com/v1/report/events/{REPORT_CODE}?start={START_MINUS_120000}&end={END}&filter=type%3D%22combatantinfo%22&api_key={API_KEY}"
curl -s "https://fresh.warcraftlogs.com/v1/report/events/buffs/{REPORT_CODE}?start={START}&end={END}&sourceid={PLAYER_ID}&api_key={API_KEY}"
curl -s "https://fresh.warcraftlogs.com/v1/report/tables/deaths/{REPORT_CODE}?start={START}&end={END}&api_key={API_KEY}" -o fight{FIGHT_ID}_{bossname}_deaths.json
```
Combine the combatantinfo `auras[]` check and the reconstructed Tree of Life % into
one `fight{FIGHT_ID}_{bossname}_consumables.json` file per fight — see the pull
scripts themselves for the exact reconstruction logic, it's too much to usefully
inline here.

**Gear audit — real pipeline step, not a one-off (fixed 2026-07-12).** The old healing
*table*'s per-player entry embedded `gear` directly; healing *events* don't carry gear
at all, so this broke silently when the pipeline moved to events. It went undiscovered
for a while because nothing exercised a gear audit under the new script until the raid
overview's gear-audit section actually needed one — and even then, the first fix only
pulled ONE fight's combatantinfo snapshot (Hydross) and presented it as if it covered
the whole raid night, without the "confirm gear is identical across all kills" check
this same doc already called for. Fixed properly: `pull_character_TEMPLATE.ps1`'s
`Get-CombatantInfoSnapshot` (generalized from the old flask/food-only
`Get-ConsumablesSnapshot`) returns the full raw combatantinfo entry — `.auras` feeds
consumables same as before, `.gear`/`.talents` now get saved to a new
`fight{FIGHT_ID}_{bossname}_gear.json` per fight, both from the ONE combatantinfo call
already being made (not a second round-trip). Both output files are independently
`Test-Path`-guarded, so re-running the script against an already-pulled report
backfills whichever one is missing without re-deriving the other. Verified for real on
Danceswtrees's full 10-kill 2026-07-07 night: every non-weapon slot (item ID,
permanent enchant, temporary enchant, gems) is byte-identical across all 10 real
snapshots — the only real difference is a mainhand/offhand swap on The Lurker Below
specifically (mace → Fishing Pole, offhand orb unequipped), which is expected, benign
behavior (some raiders fish during that pull) rather than a gearing problem. This also
resolved two loose ends from the single-snapshot version: the gem count (13 non-meta +
1 meta) is now confirmed stable rather than a one-off read, and the previously
unidentified "empty" gear slot is now precisely the shirt slot (raw array index 3, id
0 on every kill) — cosmetic, no stat impact, not a real gap.
 
**Step 3 — Pull the character's full parse history** (for real WCL percentiles per
fight, not just their all-time best):
```bash
curl -s "https://fresh.warcraftlogs.com/v1/parses/character/{CHARACTER_NAME}/{SERVER}/{REGION}?zone=1056&metric=hps&api_key={API_KEY}" -o {charactername}_all_parses.json
```
 
**Step 4 — Match each boss fight to its real percentile.** Try an exact match first
(`reportID == {REPORT_CODE}` AND `fightID` == that boss's fight ID from Step 1). If no
exact match exists, fall back to matching by `startTime` (within ~2000ms of the
report's absolute start + that fight's `start_time` offset) and `duration` (within
~100ms) against the same `encounterName` — this is gotcha #5 (duplicate raid uploads),
which has come up multiple times and is expected, not an error.
 
Organize all of Step 1-3's output files under `data\Characters\{CharacterName}\{date}\`
per the folder convention below, or zip them as `{CharacterName}_{date}.zip` for
per-request chat upload per the "Data delivery convention" below.
 
## Data delivery convention
 
Two distinct data types, with two different delivery methods — don't conflate them.
 
**Class benchmark data — summarized CSVs, uploaded to project knowledge (persists)**
 
Project knowledge does **not** support `.zip` files (it extracts text from supported
document types directly: PDF, DOCX, CSV, TXT, HTML, ODT, RTF, EPUB — no unzip step).
The raw Top 100 dataset (rankings + 1000 fight files per class) is also too large and
too granular to be useful there even if zip were supported — what the analysis actually
needs is the *derived* benchmark numbers, not the raw files.
 
Workflow (Druid, v2 — active/archived model, see "Active/archived data model" above.
NOTE: this "v2" refers to the manifest's `schemaVersion`/data-layout, a different
"v2" from the v2 GraphQL API the script itself now calls — see "v2 GraphQL API
(Druid pipeline)" above, they're unrelated version numbers that happen to coincide):
1. Run `pull_top100_druid.ps1` from the repo root. Reads/writes
   `data\Classes\Druid\manifest.json` and `data\Classes\Druid\active\` directly - no
   date folder to pick, there's only ever one current active set. Safe to re-run
   often; it only spends real API calls on parses that are genuinely new to a boss's
   Top 100.
2. Run `summarize_class_benchmarks.ps1 -ClassName Druid` from the repo root (no
   `-DateFolder` param anymore). Reads `data\Classes\Druid\active\*_healing_events.json`/
   `*_casts_events.json`/`*_consumables.json` (real per-event data, not the truncated
   tables — see "Why healing/casts moved to events, not tables") and computes, per
   boss: HPS top1/Top100avg/median, overheal best/median/worst, Top 100 spell
   composition % (grouped by guid, never merged across different guids that share a
   name — gotcha #20), Top 100 target coverage/concentration %, and Top 100 average
   cooldown/consumable cast counts with a self-vs-other-target split, plus Top 100
   flask/food active-at-pull-start % and average real Tree of Life uptime % (see
   "Buff uptime — fixed" above). **Averaged over the full real sample actually pulled
   for that boss (up to 100), not just the best 10** — changed 2026-07-12, see
   `summarize_class_benchmarks.ps1`'s own header for why (100 real data points beat
   throwing away 90 of them for a noisier 10-person average).
3. This writes small CSVs into `data\Classes\Druid\active\` (the previous set gets
   archived to `archived\benchmark_history\{date}\` first, on a real day-over-day
   regen):

Workflow (other classes, v1 — still the old date-folder convention, see gotcha #25):
1. Pull the raw data locally with `pull_top100_{class}.ps1` (or
   `pull_top100_TEMPLATE.ps1` for a class that doesn't have one yet) into
   `data\Classes\{Class}\{date}\`.
2. Run `summarize_class_benchmarks.ps1 -ClassName {Class} -DateFolder {date}` from the
   repo root — the `-DateFolder` param still exists for this path.
3. This writes small CSVs into that same date folder:
   - `benchmark_summary.csv` — one row per boss (HPS, overheal, target stats)
   - `benchmark_spell_composition.csv` — one row per boss+spell-guid (Top 100 avg % of
     healing; spell name may have `(guid N)` appended when two different guids share a
     display name — see gotcha #20, don't "clean up" by merging them)
   - `benchmark_cooldowns.csv` — one row per boss+ability (Top 100 avg casts,
     `Top100UsedPct`, `Top100SelfPct` — Druid only)
   - `benchmark_buffs.csv` — one row per boss (Top 100 flask/food active %, Top 100 avg
     Tree of Life uptime % — Druid only)
4. Upload **all the CSVs** to project knowledge. Small, text-based, no zip needed, and
   this is what future chats in this project should reference for benchmark comparisons —
   not the raw per-parse dataset, which never needs to be uploaded anywhere.
The raw per-fight JSON files stay local (or in whatever local backup you keep) — they're
just the intermediate step used to produce the CSVs, not something the project or any
chat needs direct access to going forward.
 
**Character-specific raid data — zip, uploaded directly in chat (per-request, not
project knowledge)**: `{CharacterName}_{date}.zip`
```
fights_{reportCode}.json                    <- fight list for that raid night
fight{fightID}_{bossname}_healing_events.json  <- one per boss kill, COMPLETE per-event
                                                   healing (not the truncated table -
                                                   see "Why healing/casts moved to
                                                   events, not tables" above)
fight{fightID}_{bossname}_casts_events.json    <- cooldown/utility/consumable casts,
                                                   each with a real target (self vs.
                                                   another player - this is what the
                                                   whole redesign was for)
fight{fightID}_{bossname}_consumables.json     <- flask/food active-at-pull-start +
                                                   real Tree of Life uptime %, see
                                                   "Buff uptime — fixed" above
fight{fightID}_{bossname}_deaths.json          <- fight-wide raid death list
{charactername}_all_parses.json             <- from parses/character, for real WCL percentiles
```
This is what's needed to build one specific healer's site pages (raid overview + all
boss pages) for one raid night. Uploaded directly into the chat/request when generating
that character's HTML output — a one-time input for that generation, not a standing
project file. Zip works fine here because it's a normal chat upload processed with the
code execution/bash tool (unzip + parse), unlike project knowledge which has no such
tool available. `pull_character_TEMPLATE.ps1` produces exactly this layout. Confirmed
complete/sufficient as of the Danceswtrees Hydross events-based re-pull (2026-07-11,
post healing/casts→events rewrite) — validated by hand: her real total healing summed
from events matched the (previously truncated) table's `total` field exactly, her real
Innervate cast showed up with a real target, and zero UTF-8/BOM/JSON issues across all
42 files. See `healer_audit_hydross.html` for the resulting real filled boss page.

Generated site output (HTML pages) — zip, never individual file shares: once the healer/raid/boss HTML pages are built (see "Site structure" below), deliver them as a single {healername}_site.zip preserving the real folder structure:
{healername}/
  index.html
  {date}/
    index.html
    healer_audit_{boss}.html   <- one per kill
Do not share the generated pages one-by-one as individual files (e.g. via a present-files-style tool). Sharing them individually flattens the directory structure — there is no folder in the delivered output, so ../index.html- and healer_audit_{boss}.html-style relative links between pages break, and same-named files at different levels (the healer's raid-list index.html vs. a given raid's overview index.html) collide/overwrite each other once flattened. Always zip the whole {healername}/ folder from the repo root and share that single archive instead, so the person can unzip it locally with the hierarchy — and therefore the relative links — intact.
 
## Folder structure convention (local, before summarizing)

**Two conventions coexist right now — see gotcha #25.** Druid and Shaman are both on
the active/archived + manifest.json model (see "Active/archived data model" above);
Paladin/Priest are still on the older date-stamped-folder convention below, since they haven't been
ported to the events-based pipeline (and, as part of that, the active/archived model)
yet.

```
{repo root}/
  apikey.txt              <- gitignored, just the raw key on one line (v1 REST auth,
                                still used by the Paladin/Priest pull_top100_* scripts)
  v2_client_id.txt         <- gitignored, v2 GraphQL auth (Druid + Shaman pipelines) - see
  v2_client_secret.txt        "v2 GraphQL API (Druid + Shaman pipelines)" above for setup
  v2_access_token.txt      <- gitignored, auto-created/refreshed by WclV2Api.psm1
  .gitignore               <- must include all of the above
  scripts\lib\WclV2Api.psm1 <- shared v2 GraphQL auth + query helpers, see "v2 GraphQL
                                API (Druid + Shaman pipelines)" above
  pull_top100_druid.ps1    <- Resto Druid, v2 GraphQL (migrated 2026-07-12 - see "v2
                                GraphQL API" above), healing/casts via paginated events,
                                buffs/deaths via table(), active/archived +
                                manifest.json model (see "Active/archived data model").
                                Old v1 version preserved as pull_top100_druid_v1.ps1.
  pull_top100_shaman.ps1   <- Resto Shaman, v2 GraphQL (ported 2026-07-12 as the Phase 3
                                pilot - see "v2 GraphQL API" above), same architecture as
                                pull_top100_druid.ps1. Old v1 version preserved as
                                pull_top100_shaman_v1.ps1.
  pull_top100_{class}.ps1  <- Paladin/Priest, still v1 REST, or use the generic TEMPLATE
                                (healing table only for now — no casts/buffs/deaths/
                                events rewrite, and no active/archived model, until
                                extended per-class, same as the boss page template
                                split, see Site structure)
  data/
    Classes/
      {Druid,Shaman}/                <- active/archived + manifest.json, see
                                          "Active/archived data model" above for the
                                          full layout - NOT this date-folder shape
      {OtherClassName}/              <- Paladin, Priest - old convention, below
        {date}/
          rankings_hydross.json       <- Top 100 rankings, one file per boss
          rankings_lurker.json
          ... (10 total)
          {BossFolderName}/           <- e.g. "Hydross", "VoidReaver" (no spaces)
            {reportID}_{fightID}_{playerName}.json  <- healing TABLE (v1, truncation-
                                                          prone, see gotcha #15)
```
 
Individual character report pulls (for the specific healer being analyzed, not the
Top 100 benchmark) get organized separately:
 
```
  data/
    Characters/
      {CharacterName}/
        {raidDate}/
          fights_{reportCode}.json
          fight{N}_{bossname}_healing_events.json  <- COMPLETE per-event healing
          fight{N}_{bossname}_casts_events.json    <- COMPLETE per-event casts w/ real targets
          fight{N}_{bossname}_consumables.json      <- flask/food + real Tree of Life uptime
          fight{N}_{bossname}_deaths.json          <- fight-wide raid death list
          {charactername}_all_parses.json          <- from parses/character
```
 
## Site structure (the actual HTML output)
 
Three-level hierarchy:
 
```
/index.html                              <- Healer picker (site homepage)
/{healername}/index.html                 <- List of raid nights for this healer
/{healername}/{date}/index.html          <- Raid overview: gear audit + 10-boss summary table
/{healername}/{date}/healer_audit_{boss}.html   <- Individual boss deep-dive (one per kill)
```
 
Each level links back up (`← All healers`, `← All raids`) and the boss pages link back
to the raid overview and forward via the boss-name links in its summary table.
 
**Design system**: see `design_tokens.md` in this same knowledge base. Ledger/ink-teal-
and-parchment theme, Cormorant Garamond + Inter + IBM Plex Mono. Reuse these exact
tokens for every new healer/raid — don't reinvent the palette each time.

**Boss page templates are per-class, not universal.** `boss_page_template.html` is the
generic base (Scorecard → Spell composition → Target distribution). `boss_page_template_druid.html`
is the Resto Druid variant — same base plus a "Cooldowns & consumables" section (see
below) inserted as section 03 with a Target column for cooldown casts, pushing Target
distribution to 04. The Scorecard is 5 stats (`.stat-grid-5`): HPS, Overheal,
Effective healing, Active time, Raid deaths — Active time was re-discovered as a real,
exact field on 2026-07-12 (see "Active time — re-discovered, not gone" above), not an
estimate. Section 03 shows real flask/food/Tree of Life data as of 2026-07-11 (see
"Buff uptime —
fixed" above) — it briefly showed a visible "unavailable" note instead, between the
table-based bug being found and the events-based fix landing later the same day. Use
the Druid variant for every Druid boss page; keep using the generic template for
classes that don't have a casts pull built yet.

`boss_page_template_shaman.html` (added 2026-07-12, Phase 3) is the second real
example of "give a class its own template rather than overloading the generic one" —
same overall section shape as the Druid variant (5-stat scorecard, guid-grouped spell
composition, a cooldowns & consumables section with self/other-target tracking,
target distribution), but with Shaman's own real cooldowns (Earth Shield/Mana Tide
Totem/Ancestral Swiftness/Dark Rune) instead of Druid's, and with the Rebirth row and
the Tree-of-Life-style self-buff-uptime stat both dropped entirely rather than shown
as permanent zeros — confirmed against real data that neither concept exists for this
class (see "v2 GraphQL API" above). When Paladin/Priest get the same treatment (their
own `pull_top100_{class}.ps1` on this same model), give each its own
`boss_page_template_{class}.html` the same way, built from a real-data discovery pass
for that class's actual cooldown kit — don't copy Druid's or Shaman's cooldown list
as a starting guess.
`examples\healer_audit_hydross.html` (Danceswtrees, real Top 100 benchmark data) is a
complete real filled example built from this template — **it predates the
buff-uptime fix**, so it still shows the "unavailable" note and no active-time stat;
treat it as a rough visual reference only, per CLAUDE.md. For a fully current,
representative real example instead, use the actual generated sites:
`docs\danceswtrees\2026-06-30\` (Druid, `boss_page_template_druid.html`) and
`docs\vajomee\2026-07-10\` (Shaman, `boss_page_template_shaman.html`) — both real,
complete raid nights built end to end from real data, not the stale `examples/` copy.
 
## What goes on each page
 
**Boss page** (per kill):
1. Header: character name, class/spec, report+fight IDs, percentile badge (number
   only, NO letter grades — this was an explicit correction, keep it)
2. Scorecard: HPS, overheal, effective healing, active time, raid deaths this kill —
   active time is a real field from the healing table's top-level per-player
   `activeTime`/`activeTimeReduced` scalars (re-discovered 2026-07-12, see "Active
   time — re-discovered, not gone" — NOT the truncation-affected `abilities[]` array
   from that same endpoint) — each compared against real Top 100 benchmark numbers
   where available
3. Spell composition: character's cast mix vs. Top 100 average, grouped by ability
   guid, never by name (gotcha #2), and never merged across different guids that share
   a name without checking first (gotcha #20 — e.g. Lifebloom's HoT-tick and
   bloom-burst effects are different guids with the same display name, and are
   genuinely different things, not duplicates). **Must show the union of both spell
   lists**, not just the character's own top spells — otherwise benchmark-only spells
   (things the character never cast) get silently hidden from the comparison. This was
   a real bug we caught and fixed. Healing-throughput spells only (Rejuvenation,
   Regrowth, Lifebloom, Tranquility, Swiftmend, etc. as % of total healing) — utility
   casts belong in section 4, not here.
4. **Druid pages only, for now (`boss_page_template_druid.html`):** Cooldowns &
   consumables — Innervate/Nature's Swiftness/Swiftmend cast counts vs. Top 100 avg
   (from `*_casts_events.json`), **with a Target column showing who each
   cast went to** (self, or the real recipient's name) — this per-cast target is the
   entire reason this section moved off the old `casts` table, don't collapse it back
   into a bare count. **Tranquility is conditional, not always shown** (rule added
   2026-07-12): only include its row when the character's usage is a real deviation
   from `benchmark_cooldowns.csv`'s `Top100UsedPct` for that boss — cast it while the
   sample rarely does (`Top100UsedPct` ≤20%), or didn't cast it while most of the
   sample did (`Top100UsedPct` ≥50%). Otherwise omit the row entirely, including the
   common case where nobody in the sample casts it and the character didn't either —
   that's matching the norm, not a finding, and doesn't earn a permanent row on every
   page. Mana potion/Dark Rune usage also comes from casts events
   (consumables register as cast events, not resource gains). Flask/food (yes/no,
   active at pull start) and real Tree of Life uptime % come from `*_consumables.json`
   — see "Buff uptime — fixed" above. Omit the Tree of Life stat entirely for a build
   that isn't talented into it, rather than showing a permanent 0%. **HPM (healing per
   mana), added 2026-07-12**: effective healing / total real mana cost summed from
   `*_casts_events.json`'s `classResources[0].max` field on every cast that carries
   one — see gotcha #11 for the full writeup on why `resources`/`resources-gains`
   turned out unnecessary for this. Same "effective, not raw" healing definition HPS
   already uses. Compared against
   `benchmark_summary.csv`'s `HPM_Top1`/`HPM_Top100Avg`/`HPM_Median` — omit the whole
   stat if `HPM_SampleUsed` is 0 for that boss (no benchmark to compare against),
   same principle as omitting Tree of Life for a non-Tree build. Cross-reference
   cooldown timing against `deaths` for this fight and note it in the coverage-note
   ONLY if there's an actual correlation — most kills won't have one (a 0-death kill
   trivially has none), and forcing a finding that isn't there is worse than saying
   plainly there's nothing notable.
5. Target distribution: top 5 healing recipients + coverage %, compared against real
   Top 100 average concentration/coverage for that specific boss (computed from complete
   per-event target data, not the healing table's truncated `targets[]` array — same
   underlying fix as spell composition)
**Raid overview page** (one per raid night):
1. Gear audit — lives HERE ONLY, not repeated on every boss page. Confirm gear is
   identical across all kills that night before presenting one audit (check gem IDs,
   enchant IDs, item IDs per slot across all fights) — flag any slot that changes
   mid-raid as a separate note, don't just silently take the first fight's gear.
2. Per-boss summary table: HPS, overheal, percentile, link to each boss's full page.
3. Any raid-wide pattern findings that only made sense in aggregate (e.g. we found one
   healer cast zero Healing Stream Totem across all 10 kills — that's raid-level context, not a single-boss finding).
**Healer's raid list page**: just a list of raid nights analyzed, links to each raid
overview. Extensible — new raid nights get added as new dated entries.
 
**Site homepage**: list of healers analyzed, links to each healer's raid list.
 
## Gotchas / lessons learned (read before repeating mistakes)
 
1. **Unicode player names get hex-escaped in filenames.** When PowerShell writes
   `Invoke-WebRequest -OutFile` for a player with non-ASCII characters in their name
   (Korean, Chinese, accented Latin), the filename gets encoded like `#Uc5ec#Uc220`.
   Decode with regex `#U([0-9a-fA-F]{4})` → `chr(int(match, 16))` before matching
   against the `name` field inside the JSON.
2. **Ability names are localized per player's game client.** The same spell (e.g.
   Chain Heal) can appear as different strings depending on what language client cast
   it — Korean, Chinese, etc. Aggregate by the `guid` field (spell ID), NOT by name.
   Build a canonical name lookup by preferring ASCII names when voting across all
   instances of a guid.
3. **Healing table entries are per-fight, multi-player.** A `GET /report/tables/healing`
   response with `sourceclass=X` returns ALL players of that class/spec in that fight,
   not just the one you want. Match by exact `name` field.
4. **Fight-level `targets` array in the healing table is truncated to top 5.** It is
   NOT the complete target list. Always check `sum(targets) / total * 100` to see
   actual coverage — don't assume it's 100%. **This turned out to be one instance of a
   more general problem** — `/report/tables/{view}/{code}` caps `abilities[]` at 5
   entries too, for both `healing` and `casts` — see "Why healing/casts moved to
   events, not tables" and gotcha #15. Both of those views are now pulled via
   `/report/events/` instead specifically to route around this; `targets[]` isn't
   needed anymore either, since target breakdown is now computed from complete events.
5. **Duplicate raid uploads mean rankings sometimes point to a different report code.**
   If multiple raiders log the same pull, WCL may attribute the canonical ranking to
   someone else's upload. When an exact reportID+fightID match fails in
   `parses/character`, fall back to matching by `startTime` (within ~2000ms) and
   `duration` (within ~100ms) against the same encounterName. This has happened
   multiple times and is expected behavior, not an error.
6. **Ring enchants are self-only in this era of the game.** Only the character's own
   Enchanting profession can apply them — they can't be given by a guildmate like
   every other enchant type. NEVER flag missing ring enchants as a gear audit
   deficiency; it unfairly penalizes non-enchanters. All other enchant slots
   (weapon, head, shoulder, chest, legs, feet, wrist, hands, back) are fair game.
7. **Meta gems: verify the actual tooltip, don't infer from the name.** We initially
   assumed "Bracing Earthstorm Diamond" was purely defensive based on its name — it
   actually gives +26 Healing. Always fetch the real Wowhead tooltip via
   `web_search` + `web_fetch` before characterizing a gem/enchant's effect.
8. **V1 rankings/encounter endpoint wants numeric class/spec IDs**, not string names.
   `class=Shaman&spec=Restoration` fails with `"Invalid class and spec specified."`
   Use the numeric IDs from the reference table above (or `GET /classes` to confirm).
9. **No letter grades, ever.** An earlier version of the report used A/B/C/D/F grades
   on a wax-seal badge. This was explicitly removed in favor of showing just the raw
   percentile number — letter grades read as punitive/hurtful in a way a number
   doesn't. Keep it numeric-only across all future pages.
10. **`Invoke-WebRequest -OutFile` in PowerShell can silently error mid-batch.** Always
    wrap in try/catch and log failures rather than letting the whole script die. The
    pull scripts already do this — preserve that pattern in any new script.
11. **Some v1 API error responses come back as a 200 OK with the error text embedded
    literally in the body, not as a real HTTP error status.** Hit this on
    `/report/tables/resources/{code}` and `/report/tables/resources-gains/{code}` — the
    body was `HTTP/1.0 400 Bad Request\r\n...{"status":400,"error":"No valid resource
    type specified."}`, wrapped inside an actual 200 response, so `try/catch` around
    `Invoke-WebRequest` did NOT catch it and happily saved a 293-byte "success" file.
    Any new table-view addition should sanity-check the saved content (e.g. does it
    start with `HTTP/`, or contain a JSON `"error"` field) rather than trusting that
    the request didn't throw. The real swagger spec (`reference\warcraftlogs_api.json`)
    documents `abilityid` as the resource-type filter for the `resources`/
    `resources-gains` views specifically — `resourcetype=mana` and `resourcetype=0`
    were both wrong parameter *names*, not just wrong values, which is why both were
    rejected identically. **Tested for real on 2026-07-12, and the endpoint itself
    does NOT work**: 5 real calls against Danceswtrees's Hydross fight (report
    `XJp8vAxzM4KtHYyb`, fight 6) — `/report/events/resources/` and
    `/report/tables/resources/`, with and without `sourceid`, `abilityid=0`,
    `abilityid=1`, and no `abilityid` at all — all five returned the identical
    `"No valid resource type specified."` error, the same 200-OK-with-embedded-400
    shape described above. `/report/events/resources-gains/` without `abilityid`
    returned a different, more fundamental rejection instead (`<p>Invalid command
    specified.</p>`, not even JSON) — suggesting `resources-gains` may not be a
    recognized view at all on this endpoint as actually deployed, regardless of
    params. The documented `abilityid` parameter genuinely doesn't work against the
    real Fresh Classic realm cluster - a real mismatch between the swagger spec and
    live API behavior, not a param-value guessing problem.

    **This turned out not to matter — we already have the mana data, from a
    completely different place.** Every `*_casts_events.json` file (both
    `pull_character_TEMPLATE.ps1` and `pull_top100_druid.ps1` output — already
    pulled, for every character and all 1,000 Top 100 parses) carries a
    `classResources[0]` object on each cast event with three fields whose names
    are generic/misleading but whose real meaning was confirmed by tracing 72
    consecutive events across one full real kill (Danceswtrees/Hydross) and
    checking the values against known real TBC spell costs:
      - `amount` — the character's max mana pool. Constant across the whole fight
        (10175 for Danceswtrees; 10805 for a different Top 100 parse checked as a
        cross-sample sanity check).
      - `max` — the mana COST of the specific spell in that event. Matched real
        known TBC Druid costs closely: Lifebloom 220, Rejuvenation 415, Regrowth
        675, Swiftmend 379, Innervate 94, Healing Touch 935, and 0 for free
        procs/trinkets (Essence of the Martyr, Power of Prayer) and Nature's
        Swiftness (the buff itself is free, it just removes the cost from the
        next cast).
      - `type` — the character's CURRENT mana at the moment of that cast. Traced
        across the whole Hydross kill: monotonically decreases from 10175 to
        2781 over the fight with small upward bumps (regen ticks between casts),
        exactly the shape a real mana-over-time trace should have - not a
        "resource type ID" (which would be a small constant enum value) despite
        the field's name.
    This means HPM (healing per mana) and a real mana-over-time trace are both
    computable directly from data already on disk, for every character pull and
    every Top 100 parse ever collected - no new API call, no re-pull, and no
    dependency on the broken `resources`/`resources-gains` views at all. Not
    built into the pipeline yet as of this writing - confirmed the data exists
    and decoded its real meaning, stopped there pending a decision on whether/how
    to surface it (new benchmark CSV columns, a boss-page stat, etc).
12. **`deaths` is fight-wide, not class/player-scoped — don't pull it once per player.**
    Unlike `healing`/`casts`/`buffs` (which take `sourceclass` and return every player
    of that class in the fight), `deaths` returns the whole raid's death list for the
    time range regardless of class. Pull it once per unique report+fight and reuse it,
    the same way the fight list itself gets cached across characters — both current
    pull scripts already do this.
13. **Windows PowerShell's `Invoke-WebRequest` may prompt "Script Execution Risk" and
    block on user input** unless `-UseBasicParsing` is passed, because it otherwise
    tries to use IE's parsing engine to inspect the response as a web page. This will
    silently stall an unattended 1000-parse pull waiting for a keypress. Always pass
    `-UseBasicParsing` on every `Invoke-WebRequest`/`Invoke-RestMethod` call — both
    pull scripts do this as of the 2026-07-10 update.
14. **Never round-trip an API response through a PowerShell string just to write it
    back to disk unchanged — it can silently corrupt non-ASCII bytes.** The first
    version of `pull_top100_druid.ps1`'s report+fight+view cache (added to avoid
    re-fetching `casts`/`buffs` for duplicate ranking entries) read the response via
    `$resp.Content` and wrote it out with `Set-Content`. `.Content` decodes the raw
    bytes into a string, and `Set-Content`'s default encoding on this system is not
    UTF-8 — the round trip turned proper UTF-8 multi-byte sequences (accented Latin
    characters, non-English localized ability names — see gotcha #2) into single
    mangled bytes, breaking the JSON as far as any UTF-8-strict parser is concerned.
    Confirmed against the real 2026-07-10 Hydross/Lurker pull: **52% of Hydross's and
    29% of Lurker's `_casts.json` files, plus 10%/6% of `_buffs.json` files, failed to
    parse as UTF-8.** `healing`/`deaths` were never affected because they write
    straight from `Invoke-WebRequest -OutFile`, which never touches a string. The fix,
    now in both pull scripts: cache the *file path* of the first successful write and
    `Copy-Item` (byte-safe) for duplicates, rather than caching decoded string content.
    The same trap applies to `Get-Content`/`Set-Content` on any file that's just being
    copied, not transformed — `pull_character_TEMPLATE.ps1`'s fights-file copy had the
    identical bug and got the identical fix (`Copy-Item` instead of
    `Get-Content -Raw` + `Set-Content`). If corrupted files already exist from before
    this fix, deleting and re-pulling is the only real remedy — the original bytes are
    gone once they've been through the bad round-trip once.
15. **`/report/tables/{healing,casts}/{code}` silently caps `abilities[]` at 5 entries
    per player, and the `total` field doesn't warn you it happened.** Discovered via
    two real cases in the same pull: Danceswtrees's Leotheras healing table said
    `total=176374` but the 5 listed abilities summed to 166830 (9544 missing, 5.4%);
    Turkeykin's Hydross casts table listed exactly 5 abilities with no Innervate at
    all, despite a confirmed real Innervate cast that fight. This generalizes gotcha
    #4 (`targets[]` truncation) — the whole `/report/tables/` family appears to cap
    per-player array breakdowns at 5, silently. The fix, used for `healing`/`casts` as
    of 2026-07-11: pull `/report/events/{view}/{code}?sourceid={playerID}` instead and
    aggregate client-side — complete, no cap. See "Why healing/casts moved to events,
    not tables" for the full writeup. `buffs`/`deaths` haven't shown this specific
    symptom, but treat any new `/report/tables/` view with the same suspicion until
    it's been checked the same way (compare `total`/aggregate field against a manual
    sum of the listed breakdown - if they don't match, it's truncating).
16. **`/report/events/{code}` (no `view` segment) is an undocumented flat fallback -
    the real, documented path is `/report/events/{view}/{code}`, with `view` as a
    required path segment** (`healing`, `casts`, `buffs`, etc — same enum as the
    tables endpoint). The flat form happened to work for some queries and was used
    for a while before the real swagger spec was found, but isn't the form to build
    new pulls against. On the real path, `sourceid` and `abilityid` are genuine,
    documented, standalone query parameters — never valid embedded inside the
    `filter=` expression string. Confirmed the hard way: `source.id=`, `sourceID=`,
    and a bare `source=` inside `filter=` were all silently ignored (returned the
    full unfiltered event list, thousands of events, not an error) before `sourceid=`
    as its own parameter was tried and worked immediately.
17. **This environment's fetch tool cannot execute JavaScript, and the v1 API docs
    page is a client-side-rendered Swagger UI** — every fetch of
    `.../v1/docs` or `.../v1/docs/#!/...` returns an empty pre-JS shell
    (`[swagger](http://swagger.io) [Explore](#)`), not the actual parameter tables,
    no matter how the URL is phrased. If the real parameter list for an endpoint is
    ever needed again, ask the person to open the docs page in their own browser (or
    pull the underlying swagger JSON via browser dev tools' Network tab) rather than
    re-attempting a fetch that's already failed the same way multiple times.
18. **`/report/tables/buffs/{code}?sourceclass=X&hostility=0` (no `by=` parameter)
    merges every player of that class in the fight into one flat `auras[]` list — it
    is NOT scoped to one player**, even though the response is saved under one
    specific ranked player's filename. Confirmed on real data: a single file
    simultaneously listed Moonkin Form, Dire Bear Form, and Tree of Life (three
    different Druid specs' forms — impossible for one character) plus duplicate
    "Well Fed" and duplicate "Tree of Life" entries. Any buff-uptime number produced
    by this pipeline before 2026-07-11 was never actually measuring the player it
    claimed to — this is a correctness bug, not just an unverified number. Fixed the
    same day via `combatantinfo` (flask/food) + `/report/events/buffs/` with
    `sourceid=` and real interval reconstruction (Tree of Life) — see "Buff uptime —
    fixed" above, and gotchas #22-24 for what that fix itself ran into.
19. **PowerShell's `$x = if (cond) { @(pipeline) } else { @() }` does not reliably
    preserve array-ness** — wrapping `@()` *inside* the branches of an if/else is not
    the same as wrapping the whole if/else expression, and a zero-match pipeline
    result can still collapse to `$null` once the outer if/else captures it, silently
    turning `$x.Count` into blank/nothing instead of `0`. This cost real debugging
    time: `benchmark_cooldowns.csv` showed `0` for Innervate/Nature's Swiftness/
    Rebirth/Dark Rune across an entire real pull, while Swiftmend (identical code,
    different guid) worked — the difference was incidental, not structural
    (Swiftmend's matches happened to be non-empty for the specific players checked
    early on, never exercising the empty-collection collapse). The fix: wrap the
    *entire* conditional, `$x = @(if (cond) { pipeline })`, not its branches. Applies
    anywhere a `Where-Object` (or similar filtering pipeline) result inside an
    if/else gets assigned and its `.Count` is later trusted — audit for this pattern
    specifically, don't assume `@()` anywhere in an expression makes the whole thing
    safe.
20. **Two different ability guids sharing a display name are not necessarily the same
    spell or even the same kind of thing — don't merge them in aggregation without
    checking first.** Tried merging spell-composition rows across guids that resolved
    to the same name (to fix an apparent "Lifebloom listed twice" duplicate) — wrong.
    Empirically, Lifebloom's two guids (33763, 33778) are genuinely different
    mechanics: 33763 is 100% `tick=true`, ~310 average amount (the HoT); 33778 is
    100% `tick=false`, ~515 average amount (the "bloom" burst heal on expiry).
    Collapsing them into one row hides a real mechanical split. Checked whether the
    same pattern held for Regrowth/Rejuvenation's own dual guids — it didn't (both
    showed *mixed* tick/non-tick behavior with similar amounts, just very different
    cast frequency — more consistent with rank variance than a distinct mechanic).
    The general rule adopted: never merge across guids automatically; when two guids
    share a resolved name, disambiguate by appending the guid number
    (`"Lifebloom (guid 33778)"`) rather than asserting what each one specifically
    means — that assertion is only safe for spells someone has actually checked
    (like Lifebloom, now), and guessing wrong for an uninspected spell is worse than
    an ugly-but-honest guid suffix.
21. **`Export-Csv`'s default encoding on Windows PowerShell 5.1 is not UTF-8** and
    silently substitutes `?` for any character it can't represent — confirmed on real
    output, where two Lurker spell-composition rows whose only observed cast was from
    a non-English client came out as literal `"??"` instead of the real Korean/Chinese
    spell names. Always pass `-Encoding UTF8` explicitly on every `Export-Csv` call
    (this does still add a BOM on Windows PowerShell 5.1, unlike the no-BOM fix used
    for `.json` output in gotcha #14 — acceptable for CSVs, which are commonly
    BOM-prefixed for Excel compatibility anyway).
22. **`combatantinfo` events can fire before a fight's recorded `start_time`, not
    just inside its window.** Confirmed on a real Kael'thas kill: zero combatantinfo
    events existed inside the fight's own `[start_time, end_time]` for ANY player,
    but a real snapshot for the analyzed character existed 33.6 seconds earlier -
    likely logged when the raid engaged trash/positioned near the encounter, before
    WCL's recorded pull began. There were no earlier wipes on this specific
    encounter that raid night, ruling out "logged during an earlier attempt" as the
    explanation. Query a backward buffer (2 minutes used here) and pick whichever
    snapshot is closest to `start_time` rather than assuming one exists inside the
    fight's own window. Even with a 2-minute buffer, one real case (out of 200 Top
    100 parses tested) still had no snapshot at all, likely a late-joining player -
    report this as a failure for that one player's consumables data specifically,
    don't fall back to assuming "no flask/food," since a missing snapshot and a
    genuine absence are different things and conflating them fabricates a false
    negative.
23. **When picking the closest timestamp to a target, use a real tolerance instead
    of a strict before/after split.** An early version of the combatantinfo lookup
    (gotcha #22) preferred any snapshot at or before `start_time`, falling back to
    "the earliest one after" only if none existed before - and printed a WARNING
    whenever that fallback triggered. In practice this fired constantly with "0s
    AFTER start" messages that were just sub-second event-ordering noise (a
    snapshot logged 20-90ms after start, rounding to "0.0s" at one decimal place),
    not a real gap. Fixed by picking whichever candidate has the smallest absolute
    time difference from the target (before OR after), and only warning when that
    closest candidate is more than ~2 seconds away - small timing noise shouldn't
    be flagged the same way as a genuinely late or missing snapshot.
24. **A `ConcurrentDictionary.TryAdd` used as a claim/mutex eliminates a race
    condition instead of just tolerating it.** `pull_top100_druid.ps1` originally
    kept `deaths` in a separate sequential pass specifically to avoid two parallel
    threads racing to write the same report+fight's death-list file at the same
    moment (real data showed ~0% report+fight overlap between parses, so the race
    window was already rare, but not impossible). Moving `deaths` into the same
    parallel worker as everything else (done to remove it as a bottleneck once
    `-MaxThreads` was raised) reintroduced that race - fixed with a shared
    `$deathsClaimed = [System.Collections.Concurrent.ConcurrentDictionary[string,
    bool]]::new()` passed into every worker: each thread calls
    `$deathsClaimed.TryAdd("$reportID|$fightID", $true)` before fetching, which is
    atomic - only the thread that gets `$true` back proceeds, every other thread
    racing for the same key gets `$false` and skips. If the claiming thread's own
    fetch then fails, no other thread retries it within that run (a full script
    re-run picks it up fresh, same as any other failed call). This same claim
    pattern generalizes to any per-report+fight (not per-player) resource that
    needs to move into a parallel worker in the future.
25. **Two Top 100 data conventions coexist — don't assume every class is on the
    newer one.** Druid moved to the active/archived + manifest.json model (see
    "Active/archived data model" above) on 2026-07-12; at the time this gotcha was
    written, Paladin/Priest/Shaman were all still on the older date-stamped-folder
    convention (`data\Classes\{Class}\{date}\`) AND still v1 (healing TABLE, not
    events). **Update, same day:** Shaman was ported to both the events-based
    methodology AND the active/archived model together (the Phase 3 pilot) —
    Paladin/Priest are the only two still on the old convention now. The underlying
    point stands regardless of which classes currently match it: these are two
    separate facts that happen to co-occur per class right now, don't conflate them
    when scoping future work (a class could in principle get ported to events
    without also getting the active/archived treatment, or vice versa, though in
    practice every class ported so far has shipped both together).
    `summarize_class_benchmarks.ps1`
    is shared across all classes and supports both: pass `-DateFolder {date}` for
    a class still on the old convention, omit it for Druid or Shaman. Passing
    `-DateFolder` for a class already on the active/archived model, or omitting it
    for a class that has no `active\` folder yet, both fail fast with an explicit
    error rather than silently doing the wrong thing - if a new class script is
    added, decide up front which convention it's on rather than assuming.
26. **A PowerShell scriptblock stored in a variable and invoked via `&` from a
    DIFFERENT function's scope cannot see the ORIGINAL function's local
    variables — they silently resolve to `$null`, not an error.** Hit this
    migrating `pull_character_TEMPLATE.ps1` to v2: `Invoke-WclGraphQLPaged` (in
    `WclV2Api.psm1`) takes a `$QueryBuilder` scriptblock and invokes it via
    `& $QueryBuilder $startTime` from its OWN function scope. The scriptblock was
    defined inside `Get-EventsLocal`, referencing that function's own locals
    (`$reportCode`, `$fightID`, `$DataType`, `$endTime`) — none of which are
    visible from `Invoke-WclGraphQLPaged`'s scope, since PowerShell's dynamic
    scoping only walks up through the SCRIPT/global scope, not a sibling
    function's locals. Every one of these resolved to `$null`, producing a
    syntactically-valid but semantically-empty GraphQL query
    (`report(code: "")`, `fightIDs: []`, etc) that came back with ZERO events and
    NO error anywhere in the chain — every fight's healing/casts events silently
    returned 0 before this was traced. (A sibling scriptblock in the SAME bug
    session, `Get-TreeOfLifeIntervals`'s own queryBuilder, worked by pure luck —
    it only referenced script-scope variables like `$ReportCode`/`$CharacterID`,
    which ARE visible from anywhere in the same script's call stack.) **Fix:
    call `.GetNewClosure()` on any scriptblock passed to a helper that invokes it
    via `&`/`.Invoke()`, if that scriptblock references anything other than
    genuine script-scope variables** — this snapshots the referenced variables'
    current values at creation time regardless of where it's later invoked from.
27. **Windows PowerShell 5.1: wrapping a `System.Collections.Generic.List[object]`
    of `PSCustomObject` elements in `@()` throws "Argument types do not match" —
    as a NON-terminating error, not a crash.** Confirmed via an isolated repro:
    `@($list)` on a 3-item `List[object]` of `[PSCustomObject]` threw that exact
    error while `$list.Count` (checked immediately before) still correctly
    reported 3. Because it's non-terminating and the affected runspace's
    `$ErrorActionPreference` was the PowerShell default (`Continue`, not
    `Stop`), the assignment silently completed anyway — with an EMPTY array,
    not an exception that would have surfaced the problem. This is exactly how
    gotcha #26 first presented before its real cause was isolated: `paged.Items`
    (returned as a `List[object]` from `Invoke-WclGraphQLPaged`) reported
    `.Count = 478` correctly, but `$events = @($paged.Items)` immediately after
    produced `$events.Count = 0`, with nothing in between the two lines except
    that one wrapping expression. **Fix: never wrap a `List[T]` with `@()` in
    PS5.1 — call the list's own `.ToArray()` method instead**, a plain .NET
    method that doesn't go through PowerShell's array-coercion machinery at all.
    `Invoke-WclGraphQLPaged` now returns `.Items` as an already-`.ToArray()`'d
    plain array specifically so callers never have to remember this themselves.
    (Wrapping the RESULT of piping a `List[T]` through `Where-Object`/
    `Sort-Object` etc. in `@()` is NOT affected — the pipeline already unrolls it
    into individual objects before `@()` ever sees a `List[T]` directly; only a
    bare, unpiped `@($someListVariable)` hits this.)
28. **A file written by one script but read DIRECTLY (not just via a shared
    manifest) by a different script has an implicit shape contract that's easy
    to miss when migrating just the writer.** `pull_top100_druid.ps1`'s v2
    migration initially saved `active\rankings_{boss}.json` with v2's own nested
    shape (`rankings[].report.code`/`.report.fightID`/`.amount`) since that's
    what the API naturally returns. This silently broke
    `summarize_class_benchmarks.ps1`, which reads that file DIRECTLY (not just
    the manifest) and matches each parse by flat `.reportID`/`.fightID`/`.name`,
    plus reads `.duration` for HPS — confirmed via grep before assuming, and
    confirmed live that skipping the reshape produces "no rankings entry
    matched" for every single parse of every boss. Fixed by explicitly
    reshaping each ranking entry back to v1's flat field names before the
    `ConvertTo-Json`/`WriteAllText` call, never persisting v2's nested shape to
    disk at all. General lesson: before migrating a script that WRITES a file,
    grep the whole repo for every other script that READS that file's specific
    filename, not just the ones that call the migrated script directly — a
    shared manifest can hide the fact that a second consumer reads the raw
    output file too.
29. **A per-worker cache reset on every RunspacePool invocation defeats the
    whole point of caching, once the workload scales up enough.** Found while
    porting Shaman (Phase 3): `gameData.ability()` name resolution used a
    `$localAbilityCache = @{}` declared INSIDE the worker scriptblock, so it
    reset to empty for every single parse (each parse runs in its own isolated
    PowerShell instance). At `pull_character_TEMPLATE.ps1`'s scale (~9-10
    workers per character pull) this is genuinely negligible and was a
    deliberate, documented tradeoff — but `pull_top100_druid.ps1` and
    `pull_top100_shaman.ps1` run at ~100 workers per boss × 10 bosses, where
    the same handful of common ability guids (Lifebloom, Chain Heal, etc.) get
    re-resolved via their own API call on effectively every parse — tens of
    thousands of redundant calls per full run, a real and significant
    contributor to v2 feeling slower than v1 (which never needed this call at
    all, since the REST response already embedded `ability{name,guid,icon}`
    directly in every event). Fixed by promoting the cache to a
    `ConcurrentDictionary[int,object]` created once at the top of the script
    and passed into every worker as an argument, same pattern already used for
    `$fightsCache`/`$actorNamesCache`. Lesson: a cache's placement (per-worker
    vs. shared) is a real design decision that depends on the actual workload
    scale, not a detail to copy uncritically from a smaller script onto a much
    larger one — recheck it explicitly when reusing a pattern at a different scale.
30. **Every sub-fetch inside a per-parse worker must gate the parse's overall
    success, including ones with tricky do-only-one-worker cross-thread
    claiming logic.** Found the same day as #29, while investigating whether
    real rate-limit-forced restarts of the Shaman Top 100 pull left any files
    missing. The `deaths` fetch (fight-wide, claimed via `$deathsClaimed.TryAdd`
    so only one worker per report+fight attempts it) had its own
    `if ($deathsResult.Errors)` branch that only logged a message — unlike
    every other sub-fetch (healing/casts/consumables/activetime), it never set
    `$parseOk = $false`. In the Top 100 scripts, a parse that's marked "Ok"
    gets written into `manifest.json` as `status: "active"`, and manifest
    membership is exactly what future runs check to decide whether to
    re-dispatch a worker at all — so a deaths-only 429 could silently and
    PERMANENTLY leave that report+fight's `_deaths.json` missing, since the
    parse would never be revisited again. Didn't actually manifest as observed
    data loss in the real run that prompted this check (real 429 bursts tended
    to cascade across several call types together, so the affected parses
    already had a disqualifying failure elsewhere too) — found by code
    inspection and confirmed as a real latent gap, not by reproducing actual
    missing files. Fixed by re-checking `Test-Path $deathsOutFile` AFTER the
    claim-and-attempt block (regardless of whether THIS worker was the one that
    attempted the fetch) and setting `$parseOk = $false` if it's still absent —
    this also correctly covers the non-claiming worker's case, since it never
    attempted the fetch itself and has no other way to know whether the
    claimer actually succeeded. Applied to `pull_top100_druid.ps1` and
    `pull_top100_shaman.ps1` (both manifest-gated, where this was a real
    permanent-gap risk) and to `pull_character_TEMPLATE.ps1` (no manifest
    gating there — every boss kill gets re-dispatched on every full re-run
    regardless — so the bug there only ever inflated the "fully pulled" summary
    count rather than causing a real gap, but was fixed for honest reporting).
    Restores the behavior gotcha #24 already documented as the intent ("a full
    script re-run picks it up fresh") for exactly this kind of shared,
    claimed-fetch failure.
31. **WCL's combatantinfo `gear[]` array has NO slot-name field at all — the slot
    is implied purely by array POSITION, following WoW's fixed 19-slot equipment
    order** (Head, Neck, Shoulder, Shirt, Chest, Waist, Legs, Feet, Wrist, Hands,
    Finger1, Finger2, Trinket1, Trinket2, Back, MainHand, OffHand, Ranged/Relic,
    Tabard). Miscounting that order is easy and produces a confidently-wrong,
    plausible-sounding claim rather than an obvious error. Found on Vajomee's real
    gear audit (raid overview, 2026-07-10): index 3 (Shirt — genuinely empty,
    `id: 0`, completely normal, nobody equips a shirt in raid) was mis-read as if
    it were the OffHand slot, producing a page that claimed "no offhand equipped"
    — while index 16, the REAL OffHand slot, actually had a real, epic-quality
    equipped item (`id: 29274`, ilvl 110) that went completely unmentioned. Caught
    only because the person reviewing the generated page happened to know their
    own character's gear and flagged it — this class of error would NOT be caught
    by any automated check already in this pipeline (`ConsistentAcrossAllKills`
    only diffs a kill against itself, it can't tell you the array's own position
    mapping is wrong). Same root cause nearly produced a second miss on the same
    page: a naive check for "which slots lack `permanentEnchant`" without knowing
    which slots are even enchant-ELIGIBLE in this era (rings are self-only per
    gotcha #6; neck/waist/trinkets/shirt/tabard/relic/non-weapon-offhand were
    never enchantable at all in TBC) would either over-flag ineligible slots or,
    worse, under-flag by assuming an empty-looking array position meant "slot
    doesn't apply here." **Fix/discipline going forward: always map the full
    `gear[]` array against the real 19-slot order explicitly (e.g. zip against a
    literal slot-name array in a throwaway script) before writing ANY gear-audit
    prose that names a specific slot** — never eyeball array position by counting
    entries in raw JSON output, the exact mistake made here.

## Copyright / IP note
 
Wowhead item/enchant/gem lookups are done via web_search + web_fetch, one call per
item. This is slow (2 calls per unique item) but necessary since enchantment IDs
in the WCL data (`permanentEnchant` field) don't reliably resolve via search unless
the log version includes `permanentEnchantName` directly (some newer report versions
do include this — check for it first before doing manual Wowhead lookups, it saves
significant time).