# ATNF Healer Analysis — Master Workflow
 
This document is the single source of truth for how we analyze a healer's raid performance
using Warcraft Logs data. Read this first before starting any new healer analysis.
 
## Overview of the pipeline
 
1. Get the character's name + a WCL report link for the raid night to analyze.
2. Pull that report's fight list (confirms roster, class/spec, boss kill timestamps).
3. Pull the healer's healing and casts data via `/report/events/{healing,casts}/`
   scoped to that player's `sourceid`, plus the fight's `buffs` and `deaths` tables
   (see "Why healing/casts moved to events, not tables" below for why this isn't the
   `/report/tables/` view you'd reach for first). For Resto Druid this is fully
   automated via `pull_character_TEMPLATE.ps1` — see that script's own header comment
   for usage.
4. Pull the healer's real WCL percentile for each fight (via parses/character) — also
   handled by `pull_character_TEMPLATE.ps1`.
5. (Optional, for deeper analysis) Pull Top 100 benchmark data for the healer's
   class/spec on each boss via `pull_top100_druid.ps1` (or `pull_top100_TEMPLATE.ps1`
   for other classes), then run `summarize_class_benchmarks.ps1` to condense it into
   four benchmark CSVs (see "Data delivery convention" below) — this is what actually
   gets referenced for spell composition, target distribution, and (Druid only, as of
   2026-07-11) cooldown/consumable and self-buff comparisons, not the raw files. For
   Druid specifically, both scripts operate on an `active`/`archived` + `manifest.json`
   layout, not a fresh date folder per run — see "Active/archived data model" below
   before running either one.
6. Build the site pages (see "Site structure" below) using real data only — never
   fabricate or estimate numbers we haven't actually pulled.
## API basics
 
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

### Active/archived data model — replaces date-stamped folders (2026-07-12, Druid only)

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
    {Boss}\{reportID}_{fightID}_{playerName}_{healing_events,casts_events,consumables}.json
    {Boss}\{reportID}_{fightID}_deaths.json     <- never archived, see below
    benchmark_summary.csv, benchmark_spell_composition.csv, benchmark_cooldowns.csv, benchmark_buffs.csv
  archived\
    {Boss}\{reportID}_{fightID}_{playerName}_{...}.json   <- parses dropped from the Top 100, kept forever
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
currently-`active` parses for that boss:
- **In fresh, not in manifest-active** → genuinely new. Runs the full per-parse fetch
  (healing/casts/consumables/deaths, unchanged worker logic). Only added to the
  manifest once fully successful — a partial failure (e.g. healing succeeded, casts
  didn't) leaves the parse out of the manifest entirely, so the next run's diff sees
  it as "new" again and retries; the per-file `Test-Path` check already in the worker
  skips whatever piece already succeeded, only the missing piece is re-fetched.
- **In both** → still in the Top 100, **zero API calls** — `rank`/`hps`/
  `lastConfirmedInTop100At` are refreshed from the rankings response already in hand.
- **In manifest-active, not in fresh** → dropped out. Its `healing_events`/
  `casts_events`/`consumables` files move from `active\{Boss}\` to `archived\{Boss}\`
  (kept forever, never deleted), manifest status flips to `"archived"`.
- `deaths.json` is **never archived**, regardless of whether the parse(s) referencing
  it get archived — fight-wide (not per-parse), tiny, not worth refcounting.

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

**Regression to know about:** the old healing *table*'s per-player entry embedded
`gear` directly, which is what the raid overview page's gear audit (see "What goes on
each page" below) has been reading — no separate combatantInfo pull needed. Healing
*events* don't carry gear at all. This pipeline hasn't needed a gear audit since
switching to events yet, so it's undiscovered-but-expected breakage, not a confirmed
bug — if a raid overview page is needed for a character pulled with the new script,
budget for a `filter=type%3D%22combatantinfo%22` events pull (the one confirmed-working
flat-form `/report/events/` call, see above) to get gear back, rather than assuming
it's still sitting in a file that no longer contains it.
 
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
 
Workflow (Druid, v2 — active/archived model, see "Active/archived data model" above):
1. Run `pull_top100_druid.ps1` from the repo root. Reads/writes
   `data\Classes\Druid\manifest.json` and `data\Classes\Druid\active\` directly - no
   date folder to pick, there's only ever one current active set. Safe to re-run
   often; it only spends real API calls on parses that are genuinely new to a boss's
   Top 100.
2. Run `summarize_class_benchmarks.ps1 -ClassName Druid` from the repo root (no
   `-DateFolder` param anymore). Reads `data\Classes\Druid\active\*_healing_events.json`/
   `*_casts_events.json`/`*_consumables.json` (real per-event data, not the truncated
   tables — see "Why healing/casts moved to events, not tables") and computes, per
   boss: HPS top1/top10avg/median, overheal best/median/worst, Top 10 spell
   composition % (grouped by guid, never merged across different guids that share a
   name — gotcha #20), Top 10 target coverage/concentration %, and Top 10 average
   cooldown/consumable cast counts with a self-vs-other-target split, plus Top 10
   flask/food active-at-pull-start % and average real Tree of Life uptime % (see
   "Buff uptime — fixed" above).
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
   - `benchmark_spell_composition.csv` — one row per boss+spell-guid (Top 10 avg % of
     healing; spell name may have `(guid N)` appended when two different guids share a
     display name — see gotcha #20, don't "clean up" by merging them)
   - `benchmark_cooldowns.csv` — one row per boss+ability (Top 10 avg casts,
     `Top10UsedPct`, `Top10SelfPct` — Druid only)
   - `benchmark_buffs.csv` — one row per boss (Top 10 flask/food active %, Top 10 avg
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

**Two conventions coexist right now — see gotcha #25.** Druid is on the active/archived
+ manifest.json model (see "Active/archived data model" above); Paladin/Priest/Shaman
are still on the older date-stamped-folder convention below, since they haven't been
ported to the events-based pipeline (and, as part of that, the active/archived model)
yet.

```
{repo root}/
  apikey.txt              <- gitignored, just the raw key on one line
  .gitignore               <- must include "apikey.txt"
  pull_top100_druid.ps1    <- Resto Druid, healing/casts via events (sourceid-scoped),
                                buffs/deaths via tables alongside, active/archived +
                                manifest.json model (see "Active/archived data model")
  pull_top100_{class}.ps1  <- other classes, or use the generic TEMPLATE (healing table
                                only for now — no casts/buffs/deaths/events rewrite, and
                                no active/archived model, until extended per-class, same
                                as the boss page template split, see Site structure)
  data/
    Classes/
      Druid/                         <- active/archived + manifest.json, see
                                          "Active/archived data model" above for the
                                          full layout - NOT this date-folder shape
      {OtherClassName}/              <- Paladin, Priest, Shaman - old convention, below
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
distribution to 04. The Scorecard's 4th stat is "Raid deaths," not "Active time" (see
"Why healing/casts moved to events, not tables" for why that field is gone). Section
03 shows real flask/food/Tree of Life data as of 2026-07-11 (see "Buff uptime —
fixed" above) — it briefly showed a visible "unavailable" note instead, between the
table-based bug being found and the events-based fix landing later the same day. Use
the Druid variant for every Druid boss page; keep using the generic template for
classes that don't have a casts pull built yet. When another class gets the same
treatment (its own `pull_top100_{class}.ps1` extended to pull casts via events), give
it its own `boss_page_template_{class}.html` rather than overloading the generic one
with conditional class-specific sections — the whole point of the generic template is
that it stays simple for classes that don't have this data yet.
`healer_audit_hydross.html` (Danceswtrees, real Top 100 benchmark data) is a complete
real filled example built from this template — **it predates the buff-uptime fix**,
so it still shows the "unavailable" note and no active-time stat; regenerate it (or
build a fresh example) before treating it as fully representative of the current
template's Cooldowns & Consumables section.
 
## What goes on each page
 
**Boss page** (per kill):
1. Header: character name, class/spec, report+fight IDs, percentile badge (number
   only, NO letter grades — this was an explicit correction, keep it)
2. Scorecard: HPS, overheal, effective healing, raid deaths this kill (NOT "active
   time" — that field came from the healing table and has no events-based equivalent,
   dropped 2026-07-11, see "Why healing/casts moved to events, not tables") — each
   compared against real Top 100 benchmark numbers where available
3. Spell composition: character's cast mix vs. Top 10 average, grouped by ability
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
   consumables — Innervate/Nature's Swiftness/Swiftmend/Tranquility cast counts vs.
   Top 10 avg (from `*_casts_events.json`), **with a Target column showing who each
   cast went to** (self, or the real recipient's name) — this per-cast target is the
   entire reason this section moved off the old `casts` table, don't collapse it back
   into a bare count. Mana potion/Dark Rune usage also comes from casts events
   (consumables register as cast events, not resource gains). Flask/food (yes/no,
   active at pull start) and real Tree of Life uptime % come from `*_consumables.json`
   — see "Buff uptime — fixed" above. Omit the Tree of Life stat entirely for a build
   that isn't talented into it, rather than showing a permanent 0%. Cross-reference
   cooldown timing against `deaths` for this fight and note it in the coverage-note
   ONLY if there's an actual correlation — most kills won't have one (a 0-death kill
   trivially has none), and forcing a finding that isn't there is worse than saying
   plainly there's nothing notable.
5. Target distribution: top 5 healing recipients + coverage %, compared against real
   Top 10 average concentration/coverage for that specific boss (computed from complete
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
    the request didn't throw. **The actual required parameter, found later by reading
    the real swagger spec, is `abilityid`** (used as the resource-type filter for the
    `resources`/`resources-gains` views specifically) — `resourcetype=mana` and
    `resourcetype=0` were both wrong parameter *names*, not just wrong values, which is
    why both were rejected identically. Nobody's re-tested with `abilityid` yet.
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
    "Active/archived data model" above) on 2026-07-12; Paladin/Priest/Shaman are
    still on the older date-stamped-folder convention (`data\Classes\{Class}\
    {date}\`) AND still v1 (healing TABLE, not events) — two separate facts that
    happen to both be true for those three classes right now, don't conflate them
    when scoping future work (a class could in principle get ported to events
    without also getting the active/archived treatment, or vice versa, though in
    practice they've shipped together so far). `summarize_class_benchmarks.ps1`
    is shared across all classes and supports both: pass `-DateFolder {date}` for
    a class still on the old convention, omit it for Druid. Passing `-DateFolder`
    for Druid, or omitting it for a class that has no `active\` folder yet, both
    fail fast with an explicit error rather than silently doing the wrong thing -
    if a new class script is added, decide up front which convention it's on
    rather than assuming.

## Copyright / IP note
 
Wowhead item/enchant/gem lookups are done via web_search + web_fetch, one call per
item. This is slow (2 calls per unique item) but necessary since enchantment IDs
in the WCL data (`permanentEnchant` field) don't reliably resolve via search unless
the log version includes `permanentEnchantName` directly (some newer report versions
do include this — check for it first before doing manual Wowhead lookups, it saves
significant time).