# ATNF Healer Analysis — Claude Code orientation

This is a WoW Classic (TBC/SSC-TK era) raid healer analysis pipeline: pull real combat
log data from Warcraft Logs, benchmark it against Top 100 parses, and generate
a static HTML site auditing each healer's performance per boss kill. Site name:
"All Thunder No Fury."

**This file is now the single source of truth for orientation.** `WORKFLOW.md`
used to hold the deeper API/methodology reference and told readers to read it
first — it was deleted 2026-07-18 because it had gone fully stale (zero
mentions of the Python migration below) and maintaining two overlapping docs
was worse than folding the durable parts of it into this one. If anything
still references `WORKFLOW.md`, that reference is itself stale — point it here
instead. **`README.md`** (repo root) remains the practical day-to-day
companion — setup steps and the exact command sequence for running the
pipeline, including entirely without Claude; read it when you actually need to
run something, not just to get oriented.

Supported classes/builds — four real WCL *classes* (Druid, Shaman, Priest,
Paladin), five real tracked *builds* (Druid-Restoration, Shaman-Restoration,
Priest-Holy, Paladin-Holy, Druid-Dreamstate). **Dreamstate is a SPEC of Druid,
not a sixth class** — its real WCL identity is `className: "Druid", specName:
"Dreamstate"`, a homebrew hybrid spec this custom "Fresh" realm invented (the
same realm invents specs like this per class — Paladin has "Justicar", etc.),
confirmed via `data\Classes\classes.json`. It gets its own pipeline-key
folder/config entry because a healer really can play it as a distinct build
with its own cooldown kit — see "Mid-raid spec switching" below for the real
case (Turkeykin) that drove this split.

## The pipeline runs on Python now — PowerShell is retired

The entire pipeline was rewritten from Windows PowerShell 5.1 to Python
(3.10+, developed on 3.12) across 2026-07-17/18, merged as PR #2
(`convert-to-python`, `0f20255a`) in seven sequential phase commits
(`27b861d0`→`3d88be81`, foundation → wcl_api → pure-computation →
Jinja2/render → pull_top100 → pull_character → hub redesign → cli.py →
skill/README docs), plus follow-up fixes (`97c60fb0`, `2e3a96d1` adding
`generate-all`, `42a2b324` addressing PR review comments). This was a full
port, not a rewrite-from-scratch: every real methodology fact this project
had already learned the hard way (guid-based grouping, gear-audit rules, the
active/archived data model, per-class cooldown kits, mid-raid spec
resolution) carried over unchanged — only the implementation language and,
in Phase 4, the templating engine (hand-rolled `@LOOP`/`@SLOT`/`@OPTIONAL`
HTML-comment primitives → Jinja2) changed.

**`scripts\*.ps1` and `templates\*.html` still exist on disk, untouched, as a
preserved reference/rollback copy — they are not the live implementation and
should not be run going forward.** Don't extend them, don't fix bugs in them,
don't use them as a template for a new feature. `pipeline\*.py` and
`templates_jinja\*.jinja` are the real, current implementation. If you're
orienting from a past version of this file (or from memory) that talks about
running a `.ps1` script to do real work, that's stale — translate it to the
matching `python -m pipeline.cli <subcommand>` call instead (see "Repo
structure" and README.md's "Running the pipeline in detail").

## Two independent axes — don't confuse them

**Axis 1 — report *methodology*: v1 (simple) vs. v2 (enhanced).** v1 was a
gear-check + basic spell-composition build on the old truncated
`/report/tables/` healing view. v2 is the events-based rewrite (no
truncation), with cooldown/utility tracking, self-vs-other targeting, and
Top 100 benchmarking. **Every currently-tracked healer's pages are v2** — v1
pages only survive as historical `-v1`-suffixed sibling folders for a few
already-superseded raid nights (see "Current state" below), never as anyone's
only page. This axis has nothing to do with the language/API migrations below
— it's about what the report *computes and shows*, not what pulled or
rendered it.

**Axis 2 — *authoring mechanism*: retired PowerShell hand-render vs. live
Python `render_report.py`.** Before 2026-07-14, every v2 page was Claude
hand-writing ~550 lines of HTML per boss page directly. `render_healer_report.ps1`
(then its Python successor, `pipeline\render_report.py`, since the language
migration) replaced that with a mechanical renderer: a script computes every
real number and pre-flags every script-safe judgment call
(`build_analysis.py`), Claude authors only a handful of genuinely
interpretive sentences (`{code}_findings.json`), and the renderer
deterministically produces the final HTML. **This is now the only live
authoring path** — the PowerShell-hand-render and PowerShell-script-render
mechanisms are both retired along with the rest of `scripts\`. A page's
`data\Characters\` folder having a `{code}_findings.json`/`{code}_analysis.json`
next to its `report_data.json` tells you it went through the script-rendered
pipeline. **Correction (found 2026-07-18 while fixing gendered pronouns
raid-wide): Danceswtrees's `Fm9XdWYtz8VCLnwg` was originally hand-written,
but a prior session backfilled real `report_data.json`/`analysis.json`/
`findings.json` for it — it now has the full trio and renders cleanly through
`python -m pipeline.cli render` like any other report.** Don't assume a page
predating 2026-07-14 is still hand-written-only without checking for these
three files first; the true test is file presence, not the report's age.
Vajomee's earliest raid night (`Mfz4kW6JpjFPArat`) has not been checked this
same way and may or may not still be hand-written-only.

These two axes are independent: a page's methodology (v1/v2) says nothing
about how its HTML got produced, and vice versa.

## Repo structure

```
CLAUDE.md                            <- this file (single source of truth for orientation)
README.md                            <- day-to-day setup + exact commands, all Python

pipeline\                            <- the live implementation (Python package)
  cli.py                             <- orchestrator CLI - one subcommand per stage,
                                         plus `generate`/`generate-all` which chain them
  bosses.py                          <- single source of truth for boss ID/slug/display
                                         metadata (BOSSES dict) - was 6 duplicated tables
                                         across 6 PowerShell files, now one file
  classes.py                         <- single source of truth for class/build config
                                         (CLASSES dict: WCL classID/specID, cooldown-guid
                                         table, target modes, boss-page template, active
                                         stat blocks) - was duplicated across 5+ places
                                         in the PowerShell pipeline (see the module's own
                                         docstring for the exact list)
  wcl_api.py                         <- OAuth2 + GraphQL client (port of WclV2Api.psm1)
  pull_character.py                  <- pulls one healer's full raid night, incl. real
                                         per-fight spec resolution (see "Mid-raid spec
                                         switching" below)
  pull_top100.py                     <- consolidated Top 100 benchmark puller, dispatched
                                         by --class-name (replaces 5 separate
                                         pull_top100_{class}.ps1 scripts)
  build_report_data.py               <- reads pulled data + benchmark CSVs, writes
                                         {code}_report_data.json - zero API calls
  build_analysis.py                  <- report_data.json -> {code}_analysis.json,
                                         pre-flags every script-safe judgment call -
                                         zero API calls, zero LLM
  placeholder_findings.py            <- stands in for Claude's findings.json authoring
                                         step so the pipeline can run with no LLM at all
  render_report.py                   <- report_data.json + analysis.json + findings.json
                                         + Jinja2 templates -> docs\ HTML - zero LLM
  render_lib.py                      <- shared gear/cooldown/caveat helpers (19-slot gear
                                         order, enchantable-slot allowlist, cooldown target
                                         formatting, Tranquility/deviation thresholds)
  hub_pages.py                       <- upserts the two hub pages from JSON source-of-truth
                                         (data\Characters\{Name}\index.json,
                                         data\site_index.json) - a redesign, not a port, of
                                         update_hub_pages.ps1's HTML-scraping approach
  summarize_benchmarks.py            <- reads data\Classes\{Class}\active\, writes
                                         benchmark_*.csv there too
  bootstrap_hub_index.py             <- one-time backfill: scraped the pre-existing live
                                         docs\*\index.html pages into the new
                                         index.json/site_index.json shape during the
                                         migration - not part of normal operation now that
                                         those JSON files are the real source of truth
  jsonio.py, csvio.py, numeric.py, paths.py  <- shared I/O/formatting helpers (BOM-less
                                         UTF-8 JSON, CSV matching PowerShell's
                                         Export-Csv -Encoding UTF8 BOM behavior, .NET-style
                                         rounding, report-code-vs-legacy-date path
                                         resolution)

templates_jinja\                     <- Jinja2 templates (the live template set)
  boss_page_{druid,shaman,priest,paladin,dreamstate}.html.jinja  <- per-build boss page
  raid_overview.html.jinja, healer_raidlist.html.jinja, site_index.html.jinja

scripts\                             <- PRESERVED PowerShell implementation. Reference/
                                         rollback only - do not run, do not extend.
templates\                           <- PRESERVED PowerShell-era HTML templates. Same.
scripts\archive\                     <- older-still PowerShell reference (pre-v2-API
                                         *_v1.ps1 scripts, one-off backfill scripts) -
                                         already historical even relative to scripts\.

reference\
  warcraftlogs_api.json              <- the v1 REST API's swagger spec - historical only,
                                         nothing on the live pipeline calls v1 anymore

examples\
  healer_audit_hydross.html          <- ONE old hand-filled example page, predates the
                                         events-based rewrite - visual reference only,
                                         not representative of current output shape

data\
  Classes\{Druid,Shaman,Priest,Paladin,Dreamstate}\   <- Top 100 benchmark pulls, see
                                         "Benchmark data model" below
  Characters\{Name}\{ReportCode}\      <- one pulled raid night's real data + generated
                                         report_data.json/analysis.json/findings.json
  Characters\{Name}\index.json         <- NEW in the Python era: this healer's raid-night
                                         list (report code, raid date/title, bosses
                                         killed/attempted, source) - the real source of
                                         truth for their hub page, replacing the old
                                         approach of re-scraping already-rendered HTML
                                         to figure out what raids existed
  site_index.json                      <- NEW in the Python era: the whole site's healer
                                         list (character_name, healer_slug, class_name
                                         [pipeline key], display_name) - the real source
                                         of truth for the homepage AND for which healers
                                         `generate-all`/the report-code-only skill
                                         invocation treats as "already tracked"
  zones.json                           <- local point-in-time WCL zone/encounter snapshot,
                                         quick lookup only, not auto-updated or referenced
                                         by any script
  Classes\classes.json                 <- local snapshot of this realm's real WCL
                                         class/spec ID table, incl. homebrew specs like
                                         Dreamstate/Justicar

docs\                                 <- the actual generated static site, served by
                                         GitHub Pages from master:/docs (see "Hosting")
  index.html                           <- site homepage, links every healer in
                                         site_index.json
  {healer}\index.html                  <- per-healer raid-night list
  {healer}\{ReportCode}\index.html     <- raid overview for that night
  {healer}\{ReportCode}\healer_audit_{boss}.html  <- one per boss kill
  {healer}\{ReportCode}-v1\...         <- a preserved v1-methodology sibling site, where
                                         one still exists (never overwritten)

.claude\skills\generate-healer-report\SKILL.md   <- the Claude Code skill that runs this
                                         pipeline end to end (fully Python, see its own
                                         "Pipeline" section for the exact command sequence)

.gitignore, apikey.txt (unused, kept only for the preserved *_v1.ps1 reference scripts),
v2_client_id.txt / v2_client_secret.txt / v2_access_token.txt (gitignored, live v2
GraphQL OAuth credentials used by pipeline\wcl_api.py)
```

## Benchmark data model — active/archived + manifest.json

`data\Classes\{Class}\manifest.json` tracks per-boss `lastPulledDate`/
`rankingsSnapshotDate` and per-parse `active`/`archived` status. `active\`
holds only what's currently in a boss's Top 100; `archived\` holds everything
that's ever dropped out, kept forever, never deleted. This replaced an older
"fresh date-stamped folder every pull" convention that re-fetched all ~1,000
Top 100 parses on every run even though the vast majority don't change
between runs and a completed log's data can never change once pulled — every
tracked class is on this model now, there's no remaining date-folder class.

**Per-boss diff, every run:** a parse with no manifest entry is genuinely
new (full per-parse fetch); a parse still in the fresh rankings AND still
`"active"` costs zero API calls (just refreshes rank/hps from the rankings
response already in hand); a parse that dropped out of the fresh rankings
moves `active\{Boss}\` → `archived\{Boss}\`, manifest flips to `"archived"`;
a parse that re-enters after previously dropping moves back, zero API calls,
same as the still-active case, with `firstSeenAt` left untouched. Rankings
files and the benchmark CSVs are only rewritten (old version archived first)
on a real membership/day change, not a pure re-run. Staleness is always a
plain `yyyy-MM-dd` date compared to today at read time, never a stored
boolean — see `pipeline\pull_top100.py`/`summarize_benchmarks.py` for the
exact comparison logic.

## Character/report data model — report code, not raid date

`data\Characters\{Name}\{ReportCode}\` and `docs\{healer}\{ReportCode}\` are
keyed by **WCL report code**, never raid date. Two different raids pulled for
the same character on the same calendar date is a real scenario (an
afternoon SSC clear and a separate night TK clear, say), and the per-boss-kill
files inside carry no report code of their own — a `{yyyy-MM-dd}\` folder
convention would silently let a same-day second pull corrupt the first's
files. The raid date is still tracked and shown on every page — it lives in
`report_data.json`'s own `raid_date` field and each healer's `index.json`
entry, just not as the folder name. A folder pulled before this convention
was introduced may still be a legacy `yyyy-MM-dd` name; `pipeline\paths.py`
resolves either shape, nothing needs retroactive renaming.

A healer's raid-list is always kept sorted by real raid date, descending,
regardless of the order raids happen to get *generated* in — folders being
report-code-keyed means generation order has no natural correlation to
chronology (backfilling an older raid after a newer one is real, not
hypothetical). `pipeline\hub_pages.py`'s `update-hub` command always
re-sorts the whole list from `index.json` after an insert (or via
`--resort-only` with no insert), rather than relying on append order.

**`-v1`-suffixed sibling folders are permanent, never overwritten.** Several
healers have an old v1-methodology site sitting alongside their v2 site for
the same raid night. `render_report.py` refuses to write into any output
folder whose name ends in `-v1`.

## Mid-raid spec switching — a character can play >1 real spec in one report

General, class-agnostic mechanism (not Dreamstate-specific, though
Dreamstate's own discovery pass is what surfaced the real case that required
it). `masterData.actors[].subType` has no spec field at all, and is one fixed
value per report regardless of which fight you look at — not enough to
resolve spec correctly. **Real, confirmed case**: Turkeykin, report
`XJp8vAxzM4KtHYyb` (also used by Crowns/Lippies/Danceswtrees/Shlicktree),
plays Balance (a DPS spec) on all 6 real SSC bosses and Dreamstate (a healer
spec) on all 4 real TK bosses in that SAME report — a genuine mid-raid respec.

- `pull_character.py` runs the report's own `rankings(fightIDs:[...])` call
  BEFORE the per-boss-kill dispatch (not just at the end for percentile
  display), since its per-fight `roles.{tanks,healers,dps}.characters[]`
  entries are the only real source of per-fight spec.
- Optional `--spec` flag. Every fight agreeing on one spec (true for most
  characters) — zero behavior change, just a real confirmation instead of a
  global guess. Fights disagreeing and `--spec` not supplied — hard-stops
  with the real per-fight breakdown rather than guessing. `--spec` supplied
  — only pulls fights matching that spec; the rest are logged as explicit
  `SKIP` lines, never silently treated as healer data.
- `{code}_spec_coverage.json` (per-character, next to `report_data.json`)
  records every boss in the report with its own resolved class/spec/role and
  whether it was included.
- `build_report_data.py` computes a `SpecCoverage` object for
  `report_data.json` from that file — absent when every fight agreed (the
  common case). When present, it also narrows the boss-processing loop to
  only the spec-matching fights.
- `render_report.py` surfaces a mechanical (no-LLM) sentence on the raid
  overview when `SpecCoverage` is present — omitted entirely (not an empty
  paragraph) for every healer without a real spec split.

## Current state — the 10 real tracked healers

`data\site_index.json` is the authoritative list — **check it directly**
rather than trusting a hardcoded table in this file, which has already gone
stale once (this rewrite found 5 undocumented healers and 2 undocumented
report-code folders that a previous version of this file didn't know about).
As of 2026-07-18:

| Healer | Class (pipeline key) | Display | Known report codes |
|---|---|---|---|
| Crowns | Paladin | Holy Paladin | `XJp8vAxzM4KtHYyb`, `rQpVkMjGnc4t9CqW` |
| Danceswtrees | Druid | Restoration Druid | `Fm9XdWYtz8VCLnwg`, `LKbVcNfRxyBkj2mg`, `XJp8vAxzM4KtHYyb` |
| Lippies | Priest | Holy Priest | `XJp8vAxzM4KtHYyb` |
| Vajomee | Shaman | Restoration Shaman | `Mfz4kW6JpjFPArat` (v1-only, earliest raid night), `Z4zNt28raQ6GLbkC`, `QTaWq74txvPF82AR`, `LKbVcNfRxyBkj2mg` |
| Turkeykin | Dreamstate | Dreamstate Druid | `XJp8vAxzM4KtHYyb` |
| Vinnyvozz | Druid | Restoration Druid | `rQpVkMjGnc4t9CqW`, `Mfz4kW6JpjFPArat`, `QTaWq74txvPF82AR` |
| Lasmur | Priest | Holy Priest | `Mfz4kW6JpjFPArat`, `QTaWq74txvPF82AR`, `rQpVkMjGnc4t9CqW`, `Z4zNt28raQ6GLbkC` |
| Shlicktree | Druid | Restoration Druid | `LKbVcNfRxyBkj2mg`, `XJp8vAxzM4KtHYyb` |
| Kilsby | Paladin | Holy Paladin | `LKbVcNfRxyBkj2mg`, `Mfz4kW6JpjFPArat` |
| Fuggler | Shaman | Restoration Shaman | `rQpVkMjGnc4t9CqW`, `Z4zNt28raQ6GLbkC` |

Several report codes are shared raid nights pulled for multiple tracked
healers at once (e.g. `rQpVkMjGnc4t9CqW` covers Fuggler/Lasmur/Vinnyvozz/
Crowns; `Mfz4kW6JpjFPArat` covers Kilsby/Lasmur/Vinnyvozz/Vajomee) —
`pull_character.py` resolves each character independently from the report's
own `actors[]`/`rankings()` data, so nothing about a pull assumes only one
healer is in a given log. `docs\index.html` links all 10 healers — **there is
no currently-hidden healer**; a previous version of this file claimed
Turkeykin was deliberately unlisted, which is no longer true (confirmed by
reading the live `docs\index.html` this session — it lists her with every
other healer). If a future session finds `.claude\skills\generate-healer-report\SKILL.md`
still describing her as unlisted, that's the same stale claim in a second
file, not a second real fact.

**`data\Classes\{Shaman,Priest,Paladin}\2026-07-10\`** (or similar dates)
may still exist as old pre-active/archived-model pulls, preserved untouched
— not the active data for their class, same preservation convention as the
PowerShell scripts.

## WCL v2 GraphQL API reference

**Auth**: OAuth2 client-credentials grant. Register a client at
`https://www.warcraftlogs.com/api/clients/`. Token endpoint
`https://www.warcraftlogs.com/oauth/token`; GraphQL endpoint
`https://www.warcraftlogs.com/api/v2/client`,
`Authorization: Bearer <token>`. Three gitignored files at repo root:
`v2_client_id.txt`, `v2_client_secret.txt`, `v2_access_token.txt` (the last
auto-created/refreshed by `pipeline\wcl_api.py` — real tokens observed to
last ~360 days). The old v1 REST API (`fresh.warcraftlogs.com/v1`,
query-param `api_key`) is fully retired — nothing in the live pipeline calls
it; `reference\warcraftlogs_api.json` (its swagger spec) is historical only.

**Rate limits**: points/hour (`rateLimitData{limitPerHour,
pointsSpentThisHour, pointsResetIn}`), cost scales with query complexity —
batching multiple fights into one query is genuinely cheaper than a 1:1
per-call approach, not just more convenient. Resets on a **rolling hourly
clock**, confirmed via a real full lockout after a heavy-pulling session
(even the lightweight `rateLimitData` diagnostic itself returned 429). Don't
keep retrying a burst of 429s hoping it clears in a minute — check
`pointsResetIn` or wait out the rest of the current hour. The live
`limitPerHour` value has drifted before (3600 → 18000 observed a day apart)
— check it live rather than trusting a remembered number.

**Key query shapes** (see `pipeline\wcl_api.py` for the exact GraphQL, this
is the conceptual map): `reportData.report(code).fights(...)` +
`masterData.actors(...)` for the fight list/roster;
`events(fightIDs, sourceID, dataType: Healing|Casts|Buffs|CombatantInfo|Debuffs,
includeResources: true)` for complete, paginated per-event data — this is
why healing/casts moved off the old table endpoint (see "Why events, not
tables" below); `table(dataType: Healing|Deaths|Casts, ...)` for aggregate
per-player stats including the one genuinely reliable field the table
approach still provides (`activeTime`); `worldData.encounter(id).characterRankings(
className, specName, metric, page)` for Top 100 rankings;
`reportData.report(code).rankings(fightIDs:[...], playerMetric: hps)` for a
character's exact real percentile on one specific report+fight (the reason
this project moved to v2 in the first place — the v1 REST API's
`parses/character` endpoint was structurally incomplete, real-tested at
matching only 1 of 9 real boss kills for one report).

**Why events, not tables, for healing/casts.** `table(dataType: Healing|Casts, ...)`
(and its v1 REST equivalent) silently caps each player's per-ability
breakdown at 5 entries — confirmed on real data (a real kill's `total` was
accurate but the 5 listed abilities summed to 5.4% less; a real Innervate
cast was missing entirely from a 5-entry casts table). `events(...)` returns
complete per-event records with no such cap and can be scoped to one player
via `sourceID`. `deaths` stays a `table()` call (no truncation evidence,
fight-wide not per-player, pull once per report+fight). `activeTime`/
`activeTimeReduced` are real, untruncated top-level scalars on the `table()`
response even though the same response's `abilities[]` IS truncated — the
bug is specifically in the nested breakdown arrays, not every field.

**Buff/consumable uptime — two different mechanisms, not one.** Flask/food
come from a `CombatantInfo` snapshot event queried with a 2-minute backward
buffer from the fight's start (picking whichever snapshot is closest,
preferring one before start) — reported as plain yes/no (a snapshot can't
say more), since these consumables last far longer than one fight. A snapshot
doesn't always exist even within that buffer (~0.1-1.1% of parses across
classes, likely late joiners) — reported as a real data gap for that one
player, never silently treated as "no flask." Tree of Life (Druid-only) and
Improved Faerie Fire uptime (Dreamstate-only) are different — they toggle
mid-fight, so a snapshot isn't enough:
- **Tree of Life** needs real interval reconstruction from
  `events(dataType: Buffs, sourceID:)` apply/remove pairs. Logs under two
  guids (33891, 34123) that co-fire on a real toggle, but 34123 also fires
  alone in patterns that don't match manual toggling — only guid 33891 is
  used. Only the FIRST orphan `removebuff` event (no matching prior apply) in
  a queried window is read as "was active since the window start"; every
  later orphan in the same report is a no-op (an early version treated every
  orphan this way and produced an impossible >100% uptime).
- **Improved Faerie Fire** genuinely does NOT appear as a discrete debuff
  event anywhere on this server (checked three ways: scoped to the caster,
  scoped to a second real Druid in the same raid, and the full unscoped
  per-fight debuff table — zero matches all three ways). The real mechanism:
  `table(dataType: Casts, ...)`'s own per-ability response entries carry a
  real `uptime` (ms) field for duration-based effects, and Faerie Fire gets
  the same internal classification as Lifebloom/Rejuvenation/Regrowth in
  that response — read directly, no interval reconstruction needed. Lesson
  worth remembering: the "obvious" analog to an already-working feature
  (event-based reconstruction, since that's how Tree of Life works) can be a
  real dead end even after a careful discovery pass — the fix was trying a
  structurally different query (`Casts`, not `Debuffs`), not trying harder
  at the same one.

**Gear audit** comes from the same `CombatantInfo` snapshot's `.gear`/
`.talents` fields (one call already being made for consumables, no second
round-trip) — saved per fight, then diffed across all of a character's kills
in `build_report_data.py` to confirm gear is genuinely identical across the
raid night before presenting one audit (flagging any slot that legitimately
changes mid-raid, e.g. a mainhand/offhand swap for a fishing pull, as a
separate note rather than silently taking the first fight's gear).

**SSC/TK/Gruul/Magtheridon boss IDs and class/spec IDs** — `pipeline\bosses.py`'s
`BOSSES` dict and `pipeline\classes.py`'s `CLASSES` dict are the executable
source of truth; don't hand-copy these into a new doc where they can drift.
Zone ID for SSC/TK is 1056. The full class/spec table (including this
realm's other homebrew specs like Paladin's "Justicar") is available live via
`GET /classes` or cached at `data\Classes\classes.json`.

## Per-build real cooldown/utility kits

Every kit below was confirmed via a real-data discovery pass against an
actual pulled report BEFORE any guid table was written — never assumed from
memory, and no "class X's kit works like class Y's" cross-inference. Full
per-guid table lives in `pipeline\classes.py`'s `CLASSES` dict; this is the
narrative summary.

- **Druid-Restoration**: Innervate, Nature's Swiftness, Swiftmend, Rebirth
  (conditional row — only shown when a real death this kill could plausibly
  have been answered by it, no fixed threshold, a genuine judgment call left
  to findings.json), Dark Rune, real Tree of Life buff uptime. Tranquility is
  conditional too, but on a fixed numeric rule (cast while ≤20% of the Top
  100 sample does, or didn't cast while ≥50% did) — omitted otherwise,
  including the common case where nobody casts it. **Tranquility's own guid
  is still unknown/unobserved** — `cooldown_guids["Tranquility"]` is an empty
  list and will silently show 0 forever until a real cast is seen in a pull.
- **Shaman-Restoration**: Earth Shield, Mana Tide Totem, Ancestral
  Swiftness, Dark Rune. No Rebirth-equivalent or self-buff-uptime concept —
  confirmed absent from real data, not assumed.
- **Priest-Holy**: Shadowfiend, Power Word: Shield, Chakra, Blessing of
  Life, Fear Ward, Dark Rune. Same no-Rebirth/no-uptime-concept confirmation.
  **Power Word: Shield's Top 100 benchmark usage is a real but misleading
  ~0%** (9 of 10 bosses, confirmed not an aggregation bug by grepping raw
  cast events directly) — the ranked ladder is systematically biased away
  from it because a shield's absorb likely doesn't count toward the
  HPS metric rankings are sorted by. A real Priest's own Shield usage will
  almost always look like a "huge deviation" from this benchmark — that is
  NOT itself a finding. `build_analysis.py` auto-tags this as the
  `priest_pws_benchmark_bias` canned caveat.
- **Paladin-Holy**: Holy Shock, Divine Favor (guid 20216 only — a second
  guid, 31842, also resolves to "Divine Favor" but is a free 0-mana
  proc/notification firing within ~3s of every real 20216 cast, excluded as
  non-independent), Divine Shield, Cleanse, Hand of Protection, Blessing of
  Freedom, Dark Rune. Same no-Rebirth/no-uptime-concept confirmation
  (Paladins do have Redemption, but it can't target an in-combat ally in
  this ruleset, so it structurally can't appear in boss-kill-window data
  regardless). **Holy Shock's cast and its resulting heal use two different
  real guids** — 33072 casts, 33074 heals, confirmed across the full Top 100
  sample (0.6-1.7% of healing on several bosses) even though one
  character's own 8 real casts in one raid might never happen to land a
  recorded heal. `build_analysis.py` auto-tags this as the
  `paladin_holy_shock_guid_split` canned caveat — never claim Holy Shock
  "doesn't heal" for a Paladin.
- **Druid-Dreamstate**: Innervate, Rebirth (guid 26994, same as
  Druid-Restoration's, kept even on reports with zero real casts), Dark
  Rune, plus a real Improved Faerie Fire uptime stat (see "WCL v2 GraphQL API
  reference" above for how this is actually sourced). **Confirmed absent,
  not assumed just because it shares a base class with Restoration**: Nature's
  Swiftness, Swiftmend, Tranquility — zero real casts across the discovery
  sample. A real, non-error finding worth remembering: this realm's
  Dreamstate kit genuinely borrows/renames spell effects across class
  boundaries in observed data (e.g. a cast literally named "Blessing of
  Life" sharing the SAME real guid, 38332, already in Priest's own table) —
  not incorporated into the cooldown table (single incidental casts, no
  repeatable pattern), but don't treat a repeat sighting as a data error.

## Ground rules (from real, previously-made mistakes)

- **Never fabricate or estimate a number that wasn't actually pulled.** If
  data is missing or a source is known-unreliable, say so explicitly rather
  than guessing or omitting silently.
- **No letter grades, ever** — percentile numbers only. An earlier version
  used A/B/C/D/F wax-seal badges; explicitly removed because letter grades
  read as punitive in a way a raw number doesn't. Don't reintroduce them.
- **Group by ability guid, never by display name.** Names are localized per
  client (the same spell can render as different strings depending on the
  caster's game-client language). But also: **don't merge different guids
  that happen to share a display name without checking first** — sometimes
  that's a real mechanical distinction, not noise (e.g. Lifebloom's HoT-tick
  guid 33763 vs. its bloom-burst guid 33778 are genuinely different effects;
  Holy Shock's cast/heal split above is the same pattern). A `(guid N)`
  suffix is only added to a display name when a real ambiguity exists —
  don't "clean up" by merging.
- **Spell composition must show the union of both spell lists**, not just
  the character's own top spells — a benchmark-only spell (something the
  Top 100 sample casts but the character never did) must render as a real
  0% row, never silently hidden.
- **Ring enchants are self-only in this era of the game** (only the
  character's own Enchanting profession can apply them) — never flag a
  missing ring enchant as a gear-audit deficiency. A caster off-hand "held"
  item (orb/tome/idol) similarly can never carry a permanent enchant and is
  excluded from the enchantable-slot allowlist for the same reason — this
  was a real, previously-shipped false-positive bug (OffHand wrongly
  included in the allowlist, flagging every tracked healer's held item as
  "missing an enchant" on every report ever rendered) fixed by removing it
  entirely, same treatment as the ring exclusion.
- **Verify a gem/enchant's real effect against its actual tooltip, don't
  infer from the name** — "Bracing Earthstorm Diamond" sounds purely
  defensive but actually gives +26 Healing.
- **Duplicate raid uploads can point rankings at a different report code**
  than the one being analyzed. When an exact reportID+fightID match fails,
  fall back to matching by startTime (~2000ms tolerance) and duration
  (~100ms tolerance) against the same encounter name — expected, not an
  error.
- **`deaths` is fight-wide, not per-player** — pull it once per report+fight,
  never once per player.
- **A file written by one script but read directly by another (not just via
  a shared in-memory object) needs its exact real shape double-checked** —
  a real bug class here (a cached-file re-read path once silently
  double-wrapped already-correctly-shaped JSON under the PowerShell
  implementation) — worth remembering as a shape to watch for, not assumed
  fixed forever just because the language changed.
- **Test one real API call before building a pull path around an
  assumption.** This single habit (ask for one small diagnostic, read the
  real response, then write code) caught almost every methodology bug this
  project has ever found, across both the v1→v2 API migration and the
  PowerShell→Python migration. Don't skip it just because the pipeline is
  mature now.
- **No gendered pronouns in any report/page prose** — refer to the healer by
  name or restructure the sentence. This applies to `findings.json`
  free-text authoring specifically; nothing else in the pipeline generates
  free text.
- **A discovery pass scoped to one character's report is a real starting
  point, but a claim about what a guid "never does" needs checking against
  the full Top 100 sample before it goes into permanent documentation** —
  the Holy Shock cast/heal split above is the concrete example: the first
  draft claim (scoped only to Crowns's 8 casts) was too broad and had to be
  corrected after checking the wider sample.

## Explicitly open, in priority-ish order

1. **Tranquility's guid is unknown/unobserved** — `CLASSES["Druid"].cooldown_guids["Tranquility"]`
   is an empty list and will silently show 0 forever until a real cast is
   seen in a pull. Add the real guid once observed, don't guess it.
2. **A narrow, accepted data gap**: no `CombatantInfo` snapshot even within
   the 2-minute backward buffer for a small fraction of parses across every
   class (~0.1% Druid, ~0.5% Shaman, ~1.1% Priest, ~1.1% Paladin), likely
   late-joining players — reported as a failure for that one player's
   consumables/gear data, not chased further.
3. **Power Word: Shield's Top 100 benchmark is a real but misleading ~0%**
   and **Holy Shock's cast/heal use two different real guids** — see
   "Per-build real cooldown/utility kits" above. Both are auto-tagged canned
   caveats in `build_analysis.py`; any findings.json prose must still name
   them explicitly, the tag alone doesn't write the sentence.
4. **This file's own healer/report-code table has already gone stale once**
   (5 healers and 2 report-code folders were undocumented before this
   rewrite) — a future session should re-verify against `data\site_index.json`
   and `docs\index.html` directly rather than trust this table indefinitely,
   the same caution this file now gives itself.
5. **Known, separate content-debt item, not fixed in this rewrite**: several
   already-published `docs\**\healer_audit_*.html` pages contain internal
   jargon leaked into public coverage-note prose — e.g. literal "(see
   WORKFLOW.md)" and "gotcha #2" text in
   `docs\crowns\XJp8vAxzM4KtHYyb\healer_audit_hydross.html`. Fixing this
   means regenerating already-published site content (a real content job,
   not a docs edit) — flagged here so it isn't lost, not attempted as part
   of this file's own rewrite.
6. Adding a new class/build to the pipeline: `pipeline\bosses.py` and
   `pipeline\classes.py` are the only two files with hardcoded
   boss/class tables now (the Python port's whole point was consolidating
   what used to be duplicated across 5+ PowerShell files into these two) —
   still do a real-data discovery pass against an actual pulled report
   before writing any new cooldown-guid entry, and still check the full Top
   100 sample before a "this ability never does X" claim goes into
   permanent documentation, same discipline as every prior port.

## Hosting — GitHub Pages

Repo: **`twiztid-ace/WC_log_analysis`** (public), default branch **`master`**.
Managed day-to-day through SourceTree, not the raw git CLI — SourceTree
bundles its own git at
`%LOCALAPPDATA%\Atlassian\SourceTree\git_local\bin\git.exe`, callable directly
with a full path (or `-C <repo-path>`) to inspect real repo state without
asking the person to paste `git` output:
```powershell
& "$env:LOCALAPPDATA\Atlassian\SourceTree\git_local\bin\git.exe" -C "C:\Users\raymo\wc_logs" status
```
`apikey.txt`/`v2_client_*.txt` are confirmed not tracked (`git ls-files`
doesn't list them) — safe as long as `.gitignore` isn't changed to drop those
lines.

**Served from `master:/docs`** (Settings → Pages → Source → Deploy from a
branch → `master` / `/docs`), not a dedicated `gh-pages` branch — avoids
juggling an orphan branch in SourceTree; a plain commit+push to `docs\` is
the entire publish step, no separate build process, since this has always
been static HTML/CSS with no bundler (Jinja2 rendering happens locally,
before commit, not as a CI step). Confirmed live at
`https://twiztid-ace.github.io/WC_log_analysis/` — a project site served from
a subpath, not domain root; the site's relative-link convention means this
has never caused an absolute-link problem.

**Every generated raid-night URL is report-code-keyed**, not date-keyed
(e.g. `.../crowns/XJp8vAxzM4KtHYyb/`, not `.../crowns/2026-07-07/`) — see
"Character/report data model" above. A bookmark to an old date-based URL from
before that convention would 404; this was a deliberate one-time fix for a
real data-corruption bug, not something to undo.

Any future doc-audit should re-check the live URL and `docs\index.html`
directly rather than trust a cached description indefinitely — hosting
config and the live healer list are both real, external state this file
can't observe automatically, and both have already drifted out of sync with
a prior version of this file at least once.
