# ATNF Healer Analysis — Claude Code orientation

This is a WoW Classic (TBC/SSC-TK era) raid healer analysis pipeline: pull real combat
log data from Warcraft Logs, benchmark it against Top 100 parses, and generate
a static HTML site auditing each healer's performance per boss kill. The Druid,
Shaman, and Priest pipelines (`pull_character_TEMPLATE.ps1` — shared/class-agnostic —,
`pull_top100_druid.ps1`, `pull_top100_shaman.ps1`, `pull_top100_priest_holy.ps1`) pull
that data via WCL's **v2 GraphQL API** (Druid migrated 2026-07-12, Shaman ported the
same day as its own "Phase 3" pilot, Priest ported 2026-07-13 — see WORKFLOW.md's
"v2 GraphQL API" section) — Paladin still uses the original v1 REST API.

**Read `WORKFLOW.md` first, in full, before touching anything.** It is the single
source of truth for this project — API endpoints, file formats, known bugs, and 33
numbered "gotchas" documenting real mistakes already made and fixed. Assume anything
not in WORKFLOW.md is unverified. This file is just a map to get you oriented quickly;
WORKFLOW.md has the actual depth.

## You can do something I (this conversation's Claude) couldn't

This whole project was built through a text-based chat where I could never execute
PowerShell myself — every script had to be handed to the person to run, with results
pasted back as text before I could react. That was slow and error-prone (see gotcha
#19 in WORKFLOW.md for a bug that only got caught because of exactly this friction).

**You're running in an environment with real command execution.** Actually run the
`.ps1` scripts. Actually inspect the JSON output files directly instead of asking the
person to paste console output. This should make you meaningfully more effective at
catching bugs than I was — use that.

One catch: these scripts are Windows PowerShell 5.1-specific in places (see gotcha
#13 on `-UseBasicParsing`, gotcha #14 on BOM/encoding issues, gotcha #19 on the
`if/else` array-collapse bug). If you're not running on Windows, don't assume they'll
behave identically on PowerShell 7+/pwsh on Linux/Mac — test before trusting.

## Two generations of this pipeline — don't confuse them

This project has a **simple v1** (already shipped, live on 4 healer sites) and an
**enhanced v2** (in progress — Druid, Shaman as of 2026-07-12, and Priest as of
2026-07-13). Reading the repo cold, both look like "real output" — they're not at
the same maturity, and mixing them up is the main way to get confused here.

**Naming collision to watch for:** this "v1/v2" is about *methodology* (simple
gear-check vs. events-based enhanced pipeline) — a completely different axis from
the WCL "v1 REST API / v2 GraphQL API" distinction mentioned above. Druid, Shaman,
and Priest are all on methodology-v2 AND API-v2; Paladin is on methodology-v1 AND
API-v1. The two axes had NOT visibly diverged until Shaman's port — Shaman
went from v1/v1 straight to v2/v2 in one pass (the "Phase 3" pilot), same as
Druid's own history and Priest's port the next day, so this project still hasn't
seen a *partial* port (e.g. API-only migration without the events-based rewrite)
that would actually split the two axes apart for one class. Don't assume "v2"
means the same thing in every sentence of this file or WORKFLOW.md without
checking which axis it's on.

- **v1 (simple)**: gear check + basic spell composition + a couple of other checks,
  built on the old `/report/tables/` healing view (5-entry truncation bug and all —
  see WORKFLOW.md gotcha #4/#15). This is what produced the 4 fully-built healer
  sites currently sitting at the repo root (`crowns/`, `danceswtrees/`, `lippies/`,
  `vajomee/`, plus the root `index.html` homepage). Treat these as a finished
  snapshot of the *old* methodology, not a template for new output — regenerating
  them with the v2 pipeline is future work, not done.
- **v2 (enhanced)**: events-based healing/casts (no truncation), cooldown/utility
  tracking with self-vs-other targets (Druid: Innervate/Nature's Swiftness/
  Swiftmend/Rebirth/Dark Rune, real buff uptime via Tree of Life interval
  reconstruction; Shaman: Earth Shield/Mana Tide Totem/Ancestral Swiftness/Dark
  Rune; Priest: Shadowfiend/Power Word: Shield/Chakra/Blessing of Life/Fear Ward/
  Dark Rune — no Rebirth-equivalent or self-buff-uptime concept exists for Shaman
  OR Priest in this TBC ruleset, confirmed against real data for both, not
  assumed), Top 100 benchmarking, CSV summarization. **Resto Druid, Resto Shaman,
  and Holy Priest** all have this now (see "Current state" below). One full v2
  healer site has been generated for Druid and Shaman (Danceswtrees/Druid and
  Vajomee/Shaman) — Priest's Top 100 pipeline is wired up but a full Lippies site
  regen hasn't been done yet (see "Current state"). `examples/` has one older
  reference page but it's out of date (see below).

## Data model — active/archived + manifest.json (Druid, Shaman, and Priest only)

Replaced the old "fresh date-stamped folder every pull" convention for Druid on
2026-07-12, because that convention re-fetched all ~1,000 Top 100 parses from the
WCL API on every single run even though the vast majority don't change between
runs and a completed log's data can never change once pulled. Shaman was built
directly on this model from day one when it was ported the same day, and Priest
the same way again on 2026-07-13 (no old date-folder data existed worth migrating
forward for either — see WORKFLOW.md's "v2 GraphQL API" section for why). Full
design rationale, manifest schema, and the exact diff algorithm are in
WORKFLOW.md's "Active/archived data model" section — read that before touching
any pull script. The short version:
- `data\Classes\{Druid,Shaman,Priest}\manifest.json` tracks per-boss
  `lastPulledDate`/`rankingsSnapshotDate` and per-parse `active`/`archived` status.
- `active\` holds only what's currently in a boss's Top 100. `archived\` holds
  everything that's ever dropped out, kept forever, never deleted.
- Staleness is always a plain `yyyy-MM-dd` date compared to today at read time —
  never a stored boolean (see WORKFLOW.md for why that matters).
- Paladin is NOT on this model yet — it's still v1 AND still the old date-folder
  convention (two separate things that happen to both be old on that class right
  now, don't conflate "needs the events rewrite" with "needs the active/archived
  migration" when scoping future work on it).

## Repo structure

```
WORKFLOW.md                          <- read this first, full pipeline documentation
CLAUDE.md                            <- this file

scripts/
  pull_character_TEMPLATE.ps1        <- pulls one specific healer's full raid night (methodology-v2,
                                         events-based; migrated to the v2 GraphQL API 2026-07-12).
                                         Old v1-API version preserved as
                                         pull_character_TEMPLATE_v1.ps1.
  pull_top100_druid.ps1              <- Top 100 Resto Druid benchmark pull, methodology-v2,
                                         parallelized, diff-based against manifest.json
                                         (active/archived model, see "Data model" below) — only
                                         fetches genuinely new parses. Migrated to the v2 GraphQL
                                         API 2026-07-12; old version preserved as
                                         pull_top100_druid_v1.ps1.
  pull_top100_shaman.ps1             <- Top 100 Resto Shaman benchmark pull, methodology-v2,
                                         parallelized, diff-based against manifest.json (active/
                                         archived model) — ported to the v2 GraphQL API 2026-07-12
                                         as the Phase 3 pilot class (see the plan file at
                                         C:\Users\raymo\.claude\plans\playful-baking-sunset.md).
                                         Real cooldowns (Earth Shield/Mana Tide Totem/Ancestral
                                         Swiftness/Dark Rune) confirmed against a real Vajomee
                                         report before being wired up - no Rebirth-equivalent or
                                         Tree-of-Life-equivalent exists for Shaman, confirmed absent
                                         from real data, not assumed. Old v1-API version preserved as
                                         pull_top100_shaman_v1.ps1.
  pull_top100_paladin.ps1            <- Top 100 Paladin/Holy pull — methodology-v1/simple, healing
                                         TABLE only, still the old date-stamped-folder convention
                                         AND the v1 REST API
  pull_top100_priest_holy.ps1        <- Top 100 Holy Priest benchmark pull, methodology-v2,
                                         parallelized, diff-based against manifest.json (active/
                                         archived model) — ported to the v2 GraphQL API 2026-07-13,
                                         same playbook as the Shaman Phase 3 port. Real cooldowns
                                         (Shadowfiend/Power Word: Shield/Chakra/Blessing of Life/
                                         Fear Ward/Dark Rune) confirmed against a real Lippies report
                                         before being wired up - no Rebirth-equivalent or
                                         Tree-of-Life-equivalent exists for Priest, confirmed absent
                                         from real data, not assumed. Old v1-API version preserved as
                                         pull_top100_priest_holy_v1.ps1.
  pull_top100_TEMPLATE.ps1           <- generic template the still-v1 Paladin script was generated
                                         from; still the base for any new v1-style class pull
                                         (pull_top100_druid.ps1/pull_top100_shaman.ps1/
                                         pull_top100_priest_holy.ps1 are the better reference for a
                                         new v2-style class pull instead)
  migrate_class_to_active.ps1        <- ONE-TIME migration tool, date-folder -> active/archived +
                                         manifest.json. Already run for Druid (2026-07-12, migrated
                                         the 2026-07-10 pull). Has Shaman/Priest classID/specID
                                         entries too (housekeeping only - neither class's old
                                         date-folder data had anything events-shaped to migrate
                                         forward, so this tool was NOT actually run for either;
                                         pull_top100_shaman.ps1/pull_top100_priest_holy.ps1 each
                                         bootstrapped their own empty manifest from scratch instead)
                                         - only needed again when porting Paladin off the old
                                         convention.
  summarize_class_benchmarks.ps1     <- reads data\Classes\{Class}\active\, writes benchmark_*.csv
                                         there too. Cooldown-guid table and Tree-of-Life buff column
                                         are class-keyed (fixed 2026-07-12 while porting Shaman, extended
                                         2026-07-13 for Priest - see WORKFLOW.md gotcha #29/#30 area -
                                         this used to be a single flat, ungated Druid-only table that
                                         would have silently miscomputed cooldown numbers for any
                                         other class); archives the previous CSV set to
                                         archived\benchmark_history\{date}\ on a real day-over-day
                                         regen, see "Data model" below. Makes zero API calls itself,
                                         so unaffected by the v1/v2 API migration.
  lib/WclV2Api.psm1                  <- shared module for the v2 GraphQL API (OAuth token fetch/
                                         cache, generic query POST, paginated events() wrapper).
                                         Used by pull_character_TEMPLATE.ps1, pull_top100_druid.ps1,
                                         pull_top100_shaman.ps1, and pull_top100_priest_holy.ps1 — see
                                         WORKFLOW.md's "v2 GraphQL API" section for the full endpoint
                                         mapping and auth setup.

templates/
  design_tokens.md                   <- the site's design system (colors, type, layout rules)
  boss_page_template.html            <- generic per-boss-kill page (any class, v1-style data)
  boss_page_template_druid.html      <- Resto Druid variant (extra cooldowns/consumables section,
                                         needs v2-style events/consumables data to fill in)
  boss_page_template_shaman.html     <- Resto Shaman variant, added 2026-07-12 - same section shape
                                         as the Druid template, but with Shaman's real cooldowns
                                         (Earth Shield/Mana Tide Totem/Ancestral Swiftness) and no
                                         Rebirth row or Tree-of-Life-equivalent stat (neither concept
                                         exists for this class - see pull_top100_shaman.ps1's header)
  boss_page_template_priest.html     <- Holy Priest variant, added 2026-07-13 - same section shape
                                         as the Druid/Shaman templates, but with Priest's real
                                         cooldowns (Shadowfiend/Power Word: Shield/Chakra/Blessing of
                                         Life/Fear Ward) and no Rebirth row or Tree-of-Life-equivalent
                                         stat (neither concept exists for this class either - see
                                         pull_top100_priest_holy.ps1's header)
  raid_overview_template.html        <- per-raid-night page (gear audit + 10-boss summary)
  healer_raidlist_template.html      <- per-healer page (list of raid nights analyzed)
  site_index_template.html           <- site homepage (list of healers)

reference/
  warcraftlogs_api.json              <- the real v1 API swagger spec (this environment's fetch
                                         tool couldn't render the live JS docs page - see gotcha
                                         #17 - this static copy is what unblocked several fixes)

examples/
  healer_audit_hydross.html          <- ONE real filled v1-generation example page (Danceswtrees
                                         on Hydross). Predates the buff-uptime fix and the whole
                                         events-based rewrite — still shows the old "temporarily
                                         unavailable" note for flask/food/Tree of Life and uses
                                         the truncated healing table underneath. Useful only as a
                                         rough visual reference, not as ground truth for either
                                         generation's current data shape.

data/Classes/{Druid,Shaman,Priest}/  (v2 — active/archived + manifest.json, see "Data model" below)
  manifest.json                      <- per-boss lastPulledDate/rankingsSnapshotDate, per-parse
                                         active/archived status; class-level benchmarkGeneratedDate
  active/                            <- current Top 100 only
    rankings_{boss}.json, {Boss}/{reportID}_{fightID}_{playerName}_*.json, benchmark_*.csv
  archived/                          <- kept forever, never deleted
    {Boss}/{...}                     <- parses dropped from the Top 100
    rankings_history/{Boss}/{date}.json      <- only when membership actually changed
    benchmark_history/{date}/benchmark_*.csv <- only on a real day-over-day regen

data/Classes/Shaman/2026-07-10/     <- OLD v1 pull, preserved untouched (no *_healing_events.json
                                        files, so migrate_class_to_active.ps1 was never run against
                                        it - see "Data model" above) - not the active data anymore
data/Classes/Priest/2026-07-10/     <- OLD v1 pull, preserved untouched, same reasoning as Shaman's
                                        above - not the active data anymore

data/Classes/Paladin/  (v1 — still the old convention)
  {date}/rankings_{boss}.json, {BossName}/{reportID}_{fightID}_{playerName}.json, benchmark_*.csv

docs/  (already generated, not templates, actual pages. v1 output moved here 2026-07-12 for
        GitHub Pages, see "Hosting" below — this is now the real path for ALL generated output,
        v1 and v2 alike; a healer folder can contain BOTH generations in different date
        subfolders, e.g. docs\vajomee\2026-07-03\ is v1, docs\vajomee\2026-07-10\ is v2 - check
        the date folder, not just the healer name, before assuming which methodology a page uses)
  index.html                         <- site homepage, links to all healers below
  crowns/, danceswtrees/, lippies/, vajomee/
    index.html                       <- per-healer raid-night list
    {date}/index.html                <- raid overview for that night
    {date}/healer_audit_{boss}.html  <- one per boss kill (v1 or v2 methodology depending on
                                         which pipeline generated that specific date folder)
```

Not included here (repo-specific, never shared in the source conversation):
`apikey.txt` (gitignored, v1 REST API key, still used by the Paladin script),
`v2_client_id.txt`/`v2_client_secret.txt`/`v2_access_token.txt` (gitignored, v2
GraphQL OAuth credentials used by `WclV2Api.psm1`, now shared by
`pull_character_TEMPLATE.ps1`, `pull_top100_druid.ps1`, `pull_top100_shaman.ps1`,
and `pull_top100_priest_holy.ps1`), `.gitignore`.

## Current state — what's solid vs. what's open

**v1 (simple) — shipped:**
- 4 healer sites fully built and live under `docs/` (`crowns/`, `danceswtrees/`,
  `lippies/`, `vajomee/`), each with all 10 SSC/TK boss kills for one raid night.
  This is the old gear-check + basic-spell-composition methodology — not being
  extended further, only kept as-is until v2 replaces it per class.
- `pull_top100_paladin.ps1` (`pull_top100_priest_holy_v1.ps1` as of 2026-07-13,
  preserved for reference/rollback) have both been run — `data\Classes\Paladin\
  2026-07-10\` is populated for all 10 bosses, with `benchmark_summary.csv` and
  `benchmark_spell_composition.csv` already generated; `data\Classes\Priest\
  2026-07-10\` is the same vintage but is no longer the active data for that
  class (superseded by the v2 port below). This is v1-generation data (healing
  table, 5-entry truncation risk per gotcha #15) — do not treat it as equivalent
  to Druid's/Shaman's/Priest's v2 data. `data\Classes\Shaman\2026-07-10\` still
  exists too (the old v1 pull, preserved untouched on disk, same convention as
  keeping `*_v1.ps1` scripts around) but is no longer the active data for that
  class either — see below.

**v2 (enhanced) — Druid, Shaman, and Priest:**
- `pull_character_TEMPLATE.ps1` (shared/class-agnostic) and `pull_top100_druid.ps1`
  were migrated from the v1 REST API to the v2 GraphQL API on 2026-07-12 (this was
  originally just meant to fix a null-percentile bug — v1's percentile endpoints
  are structurally incapable of returning an exact report+fight match — but the
  fix was expanded to a full API migration once the root cause was understood).
  `pull_top100_shaman.ps1` was ported the same day, as the "Phase 3" pilot class
  for extending this same v2 architecture beyond Druid, and `pull_top100_priest_holy.ps1`
  followed the next day (2026-07-13) — both modeled directly on
  `pull_top100_druid.ps1` since neither old v1 script shared much structurally
  with it (sequential, single healing-TABLE-per-parse, no
  casts/consumables/activetime/deaths at all). All four scripts were
  equivalence/smoke tested against real data before the old v1-API versions were
  preserved as `*_v1.ps1` and the new versions promoted to the production
  filenames. Full mapping/rationale for all three ported classes in WORKFLOW.md's
  "v2 GraphQL API" section (the durable copy — plan files are session-scoped
  working documents, and the plan file at
  `C:\Users\raymo\.claude\plans\playful-baking-sunset.md` holds only the Shaman
  port's own plan, having been overwritten after the Druid migration's plan was
  already executed; the Priest port had no separate plan file). The Paladin pull
  script is explicitly NOT part of this — it still uses the v1 REST API and
  `apikey.txt`.
- Pipeline validated end to end on real data for all three classes: events-based
  healing/casts (no truncation), cooldown/utility tracking with self-vs-other
  targets (Druid: Innervate/Nature's Swiftness/Swiftmend/Rebirth/Dark Rune with
  real Tree of Life buff uptime; Shaman: Earth Shield/Mana Tide Totem/Ancestral
  Swiftness/Dark Rune, confirmed against a real Vajomee report; Priest:
  Shadowfiend/Power Word: Shield/Chakra/Blessing of Life/Fear Ward/Dark Rune,
  confirmed against a real Lippies report — no Rebirth-equivalent or
  self-buff-uptime concept exists for Shaman OR Priest in this TBC ruleset), each
  class's own boss page template.
- All **10 of 10 bosses** pulled and confirmed on disk for Druid
  (`data\Classes\Druid\active\`, 1,000 parses), Shaman
  (`data\Classes\Shaman\active\`, ~995/1,000 — a handful of parses hit the known
  ~0.5% combatantinfo-snapshot gap, see item 4 below), and Priest
  (`data\Classes\Priest\active\`, **989/1,000** — 11 failed, all the same
  combatantinfo-snapshot gap, ~1.1% here vs. Druid's/Shaman's ~0.5% baseline —
  same accepted category, not a new bug, see item 4 below). All three use the
  same RunspacePool + active/archived + `manifest.json` model — see "Data model"
  below. **Verify boss/parse counts against `manifest.json` or the actual folder
  before trusting a number someone recalls from memory** — this has drifted from
  reality before.
- `summarize_class_benchmarks.ps1` has been run against all three classes' full
  active sets — all four `benchmark_*.csv` files exist for each in their own
  `data\Classes\{Class}\active\`. Its cooldown-guid table and Tree-of-Life buff
  column were made class-keyed while porting Shaman and extended again for
  Priest (previously a single flat, ungated Druid-only table that would have
  silently miscomputed cooldown numbers for any other class — see WORKFLOW.md
  gotcha #29/#30 area). **Real finding from the Priest benchmark run**: Power
  Word: Shield's `Top100UsedPct` in `benchmark_cooldowns.csv` is ~0% on 9 of 10
  bosses (1% on Kael'thas) — verified not a bug (grepped raw
  `*_casts_events.json`, genuinely zero real occurrences of guid 10899 in
  Hydross's 100 files) despite Lippies herself casting it 8 times in her own raid
  night. Most likely explanation: shield absorb doesn't count toward the HPS
  metric this ladder ranks by, so the benchmark population is systematically
  biased away from this ability, not reflecting a real "norm." **Any future
  Priest boss page must not read a real character's Shield usage as "overusing"
  it relative to this benchmark** — see WORKFLOW.md's "v2 GraphQL API" section
  and `boss_page_template_priest.html`'s section 03 comment for the full caveat.
- Two full v2 healer sites have been generated end-to-end: Danceswtrees/Druid
  (`docs\danceswtrees\2026-06-30\`) and Vajomee/Shaman (`docs\vajomee\2026-07-10\`)
  — each a real raid overview + one page per boss kill, built from real
  `build_boss_report_data.ps1` output, not templated filler. **Priest's Top 100
  pipeline (pull + benchmark + template) is now wired up the same way, but a
  full Lippies v2 site regen has NOT been done yet** — Lippies' existing pages
  under `docs\lippies\2026-07-07\` are still the old v1-methodology pages; this
  is a real, separate next step (see "Explicitly open" below), not implied by
  the pull script being ready.

**Explicitly open, in priority-ish order:**
1. Tranquility's guid is unknown/unobserved (Druid-only concept) —
   `$cooldownGuids["Tranquility"]` is an empty array in both Druid-touching
   scripts and will silently show 0 forever until someone adds the real guid once
   it's actually seen in a pull.
2. **A full Lippies v2 site regen hasn't been done yet.** Priest's Top 100
   pipeline is fully ported and proven (pull + benchmark + template), but nobody
   has run `build_boss_report_data.ps1` + the generate-healer-report skill
   against Lippies' real report (`XJp8vAxzM4KtHYyb`) to produce a real v2 raid
   overview + 10 boss pages the way Danceswtrees/Vajomee already have. This is
   the natural next step now that the pipeline itself is ready.
3. Paladin is still on the v1/simple, truncation-prone table approach AND
   the old date-stamped-folder convention — none of the events-based/
   cooldown/buff-uptime work OR the active/archived data model has been ported to
   it yet. Porting it now has THREE real, proven references instead of one —
   `pull_top100_druid.ps1`, `pull_top100_shaman.ps1`, and
   `pull_top100_priest_holy.ps1` — plus a repeatable playbook confirmed twice now
   (Shaman, then Priest): (a) a real-data discovery pass BEFORE writing any
   class-specific guid table (never assume a class's cooldown kit or
   self-buff-uptime concept from memory), (b) build the new pull script as a
   separate file modeled on the existing v2 scripts, smoke-test on one boss into a
   scratch folder, then promote, (c) add the class's entries to
   `build_boss_report_data.ps1`'s and `summarize_class_benchmarks.ps1`'s
   class-keyed tables, (d) build `boss_page_template_{class}.html` from the
   existing templates' section *shape*, not their specific content, (e) extend
   the generate-healer-report skill's class gate once proven end-to-end.
4. One narrow, accepted gap, reconfirmed with real Shaman and Priest data at a
   broadly similar (if somewhat noisier for Priest) rate: no `combatantinfo`
   snapshot even within the 2-minute backward buffer, likely a late-joining
   player — 1 case for Druid (~0.1%), ~5 for Shaman (~0.5%), 11 for Priest
   (~1.1%, see the "Current state" bullet above) — currently just reported as a
   failure for that one player's consumables data, not chased further.
5. **Power Word: Shield's Top 100 benchmark is a real but misleading ~0%** (9 of
   10 bosses) — see the "Current state" bullet above. Any coverage-note on a
   Priest boss page must name this caveat rather than reading it as a norm.

## Ground rules (condensed from WORKFLOW.md — read the real thing for why)

- **Never fabricate or estimate a number that wasn't actually pulled.** If data is
  missing or a source is known-unreliable, say so explicitly rather than guessing or
  omitting silently.
- **No letter grades, ever** — percentile numbers only (gotcha #9). This was an
  explicit, deliberate design correction; don't reintroduce it.
- **Group by ability guid, never by display name** (gotcha #2) — names are localized
  per client. But also: **don't merge different guids that share a display name**
  without checking first (gotcha #20) — sometimes that's a real mechanical
  distinction (Lifebloom's HoT-tick vs. bloom-burst are different guids), not noise.
- **Test one real API call before building a pull script around an assumption** —
  this pattern (ask for one small diagnostic, read the real response, THEN write
  code) caught almost every bug in WORKFLOW.md's gotcha list. Don't skip it just
  because you can now run things yourself.
- **No gendered pronouns in any report/page prose** (added 2026-07-12) — refer to
  the healer by name (e.g. "Danceswtrees") or restructure the sentence, don't use
  "she/her/he/him". This crept in through free-form coverage-note writing (not the
  templates themselves, which never had this problem) on the first two real v2
  boss pages and had to be swept out after the fact — write clean the first time.
- **The v2 GraphQL API's rate limit resets on a rolling hourly clock, confirmed
  live 2026-07-12** — hit a real full lockout mid-session (a day of heavy pulling:
  a Danceswtrees re-pull, a Vajomee pull, a full Druid Top 100 pull, and two Shaman
  Top 100 pull attempts all in the same session) where even the lightweight
  `rateLimitData { pointsSpentThisHour pointsResetIn }` diagnostic query itself
  returned 429. Don't keep retrying a burst of 429s hoping it clears in a minute —
  check `rateLimitData.pointsResetIn` (when it isn't itself rate-limited) or just
  wait out the rest of the current clock hour before retrying a big pull. **Note:**
  a live check on 2026-07-13 (before the Priest Top 100 pull) showed
  `limitPerHour: 18000`, not the 3600 documented the day before — check the live
  value rather than trusting either number from memory, see WORKFLOW.md's "v2
  GraphQL API" section.

## Hosting — GitHub Pages

The repo is already on GitHub: **`twiztid-ace/WC_log_analysis`** (public), default
branch **`master`** (not `main` — worth noting since that's the more common default
name now). The person manages it day-to-day through **SourceTree**, not the raw git
CLI.

**Git CLI is available even though it's not on PATH.** SourceTree bundles its own
git at `%LOCALAPPDATA%\Atlassian\SourceTree\git_local\bin\git.exe`. Call it with a
full path (or `-C <repo-path>`) to inspect real repo state directly — confirmed
working:
```powershell
& "$env:LOCALAPPDATA\Atlassian\SourceTree\git_local\bin\git.exe" -C "C:\Users\raymo\wc_logs" status
```
Prefer this over asking the person to run/paste git output, same reasoning as the
"you can do something I couldn't" section above. `apikey.txt` is confirmed **not**
tracked (`git ls-files` doesn't list it) — safe as long as `.gitignore` isn't
changed to drop that line.

**Chosen approach: separate code from the served static site using a `docs/`
folder**, not a dedicated `gh-pages` branch. GitHub Pages supports serving from
`/docs` on a normal branch (Settings → Pages → Source → Deploy from a branch →
`master` / `/docs`), which avoids juggling an orphan branch in a GUI client like
SourceTree — a plain commit+push to `docs/` is enough to publish, no branch
switching required.

**Migration done (2026-07-12).** The live v1 site output (`index.html`, `crowns/`,
`danceswtrees/`, `lippies/`, `vajomee/`) now lives under `docs/` at repo root,
moved as one whole tree (not piecemeal) specifically so the pages' relative links
(`../index.html`, etc.) kept resolving correctly — spot-checked after the move:
`docs/index.html`'s healer links, `docs/danceswtrees/index.html`'s `../index.html`
back-link, and its raid-date subfolder link all still resolve. `scripts/`, `data/`,
`templates/`, `reference/`, `examples/`, `WORKFLOW.md`, `CLAUDE.md`, `TODO.md` stay
at repo root — Pages only serves what's inside `docs/`, so keeping them at root
just means they're not web-served (still visible in the repo browser itself, since
the repo is public — Pages scoping doesn't hide them, it just keeps them out of
the served site). This was a working-tree-only change — nothing staged/committed,
that's still the person's to do via SourceTree.

**Still open — one-time setup on github.com (not doable via git/API from here):**
1. Confirm repo visibility: Settings → General → Danger Zone → should already say
   Public.
2. Once the `docs/` migration is committed/pushed to `master`: Settings → Pages →
   Source → "Deploy from a branch" → Branch: `master`, folder: `/docs` → Save.
   **Not done yet** — the folder move is real, but the GitHub Pages toggle itself
   hasn't been flipped, so nothing is actually being served yet.
3. Resulting URL: `https://twiztid-ace.github.io/WC_log_analysis/` — a **project
   site**, served from a subpath, not domain root. Smoke-test the first deploy
   specifically for any accidentally-absolute (`/index.html`-style) links; the
   site already uses relative links throughout per WORKFLOW.md's zip-delivery
   convention, so this should already be fine, but hasn't been verified live.

**Ongoing publish workflow once set up:** regenerate/edit the static pages under
`docs/`, commit, push via SourceTree — GitHub rebuilds Pages automatically
(typically under a minute), no separate build step, since this has always been
plain static HTML/CSS with no bundler.

**Status: folder migration done, Pages toggle still not flipped.** The GitHub
Pages setting itself is a real, visible change (exposes a public URL) — confirm
before flipping it on github.com rather than assuming this documentation update
means it's live.
