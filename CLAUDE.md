# ATNF Healer Analysis — Claude Code orientation

This is a WoW Classic (TBC/SSC-TK era) raid healer analysis pipeline: pull real combat
log data from Warcraft Logs' v1 API, benchmark it against Top 100 parses, and generate
a static HTML site auditing each healer's performance per boss kill.

**Read `WORKFLOW.md` first, in full, before touching anything.** It is the single
source of truth for this project — API endpoints, file formats, known bugs, and 25
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
**enhanced v2** (in progress, Druid-only so far). Reading the repo cold, both look
like "real output" — they're not at the same maturity, and mixing them up is the
main way to get confused here.

- **v1 (simple)**: gear check + basic spell composition + a couple of other checks,
  built on the old `/report/tables/` healing view (5-entry truncation bug and all —
  see WORKFLOW.md gotcha #4/#15). This is what produced the 4 fully-built healer
  sites currently sitting at the repo root (`crowns/`, `danceswtrees/`, `lippies/`,
  `vajomee/`, plus the root `index.html` homepage). Treat these as a finished
  snapshot of the *old* methodology, not a template for new output — regenerating
  them with the v2 pipeline is future work, not done.
- **v2 (enhanced)**: events-based healing/casts (no truncation), cooldown/utility
  tracking with self-vs-other targets, real buff uptime (flask/food snapshot + Tree
  of Life interval reconstruction), Top 100 benchmarking, CSV summarization. Only
  **Resto Druid** has this so far, and it's mid-pull, not complete (see "Current
  state" below). No v2 healer site has been generated yet — `examples/` has one
  reference page but it's out of date (see below).

## Data model — active/archived + manifest.json (Druid/v2 only)

Replaced the old "fresh date-stamped folder every pull" convention for Druid on
2026-07-12, because that convention re-fetched all ~1,000 Top 100 parses from the
WCL API on every single run even though the vast majority don't change between
runs and a completed log's data can never change once pulled. Full design
rationale, manifest schema, and the exact diff algorithm are in WORKFLOW.md's
"Active/archived data model" section — read that before touching either pull
script. The short version:
- `data\Classes\Druid\manifest.json` tracks per-boss `lastPulledDate`/
  `rankingsSnapshotDate` and per-parse `active`/`archived` status.
- `active\` holds only what's currently in a boss's Top 100. `archived\` holds
  everything that's ever dropped out, kept forever, never deleted.
- Staleness is always a plain `yyyy-MM-dd` date compared to today at read time —
  never a stored boolean (see WORKFLOW.md for why that matters).
- Paladin/Priest/Shaman are NOT on this model yet — they're still v1 AND still the
  old date-folder convention (two separate things that happen to both be old on
  those three classes right now, don't conflate "needs the events rewrite" with
  "needs the active/archived migration" when scoping future work on them).

## Repo structure

```
WORKFLOW.md                          <- read this first, full pipeline documentation
CLAUDE.md                            <- this file

scripts/
  pull_character_TEMPLATE.ps1        <- pulls one specific healer's full raid night (v2, events-based)
  pull_top100_druid.ps1              <- Top 100 Resto Druid benchmark pull, v2/enhanced, parallelized,
                                         diff-based against manifest.json (active/archived model, see
                                         "Data model" below) — only fetches genuinely new parses
  pull_top100_paladin.ps1            <- Top 100 Paladin/Holy pull — v1/simple, healing TABLE only,
                                         still the old date-stamped-folder convention
  pull_top100_priest_holy.ps1        <- Top 100 Priest/Holy pull — v1/simple, healing TABLE only,
                                         still the old date-stamped-folder convention
  pull_top100_shaman.ps1             <- Top 100 Resto Shaman pull — v1/simple, healing TABLE only,
                                         still the old date-stamped-folder convention
  pull_top100_TEMPLATE.ps1           <- generic template these three v1 scripts were generated
                                         from; still the base for any new v1-style class pull
  migrate_class_to_active.ps1        <- ONE-TIME migration tool, date-folder -> active/archived +
                                         manifest.json. Already run for Druid (2026-07-12, migrated
                                         the 2026-07-10 pull) - only needed again when porting
                                         another class off the v1 date-folder convention
  summarize_class_benchmarks.ps1     <- reads data\Classes\{Class}\active\, writes benchmark_*.csv
                                         there too (Druid-specific cooldown/buff columns only apply
                                         once run against v2-style Druid data); archives the previous
                                         CSV set to archived\benchmark_history\{date}\ on a real
                                         day-over-day regen, see "Data model" below

templates/
  design_tokens.md                   <- the site's design system (colors, type, layout rules)
  boss_page_template.html            <- generic per-boss-kill page (any class, v1-style data)
  boss_page_template_druid.html      <- Resto Druid variant (extra cooldowns/consumables section,
                                         needs v2-style events/consumables data to fill in)
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

data/Classes/Druid/  (v2 — active/archived + manifest.json, see "Data model" below)
  manifest.json                      <- per-boss lastPulledDate/rankingsSnapshotDate, per-parse
                                         active/archived status; class-level benchmarkGeneratedDate
  active/                            <- current Top 100 only
    rankings_{boss}.json, {Boss}/{reportID}_{fightID}_{playerName}_*.json, benchmark_*.csv
  archived/                          <- kept forever, never deleted
    {Boss}/{...}                     <- parses dropped from the Top 100
    rankings_history/{Boss}/{date}.json      <- only when membership actually changed
    benchmark_history/{date}/benchmark_*.csv <- only on a real day-over-day regen

data/Classes/{Paladin,Priest,Shaman}/  (v1 — still the old convention)
  {date}/rankings_{boss}.json, {BossName}/{reportID}_{fightID}_{playerName}.json, benchmark_*.csv

docs/  (v1 site output — already generated, not templates, actual pages. Moved here
        2026-07-12 for GitHub Pages, see "Hosting" below — this is now the real path)
  index.html                         <- site homepage, links to all 4 healers below
  crowns/, danceswtrees/, lippies/, vajomee/
    index.html                       <- per-healer raid-night list
    {date}/index.html                <- raid overview for that night
    {date}/healer_audit_{boss}.html  <- one per boss kill (v1 methodology)
```

Not included here (repo-specific, never shared in the source conversation):
`apikey.txt` (gitignored, WCL API key), `.gitignore`.

## Current state — what's solid vs. what's open

**v1 (simple) — shipped:**
- 4 healer sites fully built and live at repo root (`crowns/`, `danceswtrees/`,
  `lippies/`, `vajomee/`), each with all 10 SSC/TK boss kills for one raid night.
  This is the old gear-check + basic-spell-composition methodology — not being
  extended further, only kept as-is until v2 replaces it per class.
- `pull_top100_paladin.ps1`, `pull_top100_priest_holy.ps1`, `pull_top100_shaman.ps1`
  have all been run — `data\Classes\{Paladin,Priest,Shaman}\2026-07-10\` is
  populated for all 10 bosses, with `benchmark_summary.csv` and
  `benchmark_spell_composition.csv` already generated for at least Paladin and
  Priest. This is v1-generation data (healing table, 5-entry truncation risk per
  gotcha #15) — do not treat it as equivalent to Druid's v2 data.

**v2 (enhanced) — in progress, Druid only:**
- Pipeline validated end to end on real data: events-based healing/casts (no
  truncation), cooldown/utility tracking with self-vs-other targets, buff uptime
  (flask/food snapshot + real Tree of Life interval reconstruction), the Druid boss
  page template.
- All **10 of 10 bosses** pulled and confirmed on disk under
  `data\Classes\Druid\active\` (1,000 parses as of the 2026-07-12 migration).
  `pull_top100_druid.ps1` (RunspacePool, `-MaxThreads 10` default) now reads/writes
  the active/archived + `manifest.json` model instead of a fresh date folder per
  run — see "Data model" below for the full design. Live-tested twice on real API
  data: once with only rankings unchanged (0 new, 8/8 bosses skipped correctly),
  once with real churn (Leotheras/Karathress: 2 new + 2 dropped each, archived and
  re-fetched correctly). **Verify boss/parse counts against `manifest.json` or the
  actual folder before trusting a number someone recalls from memory** — this has
  drifted from reality before.
- `summarize_class_benchmarks.ps1` has been run against the full active Druid set —
  all four `benchmark_*.csv` files exist in `data\Classes\Druid\active\`, generated
  2026-07-12. Also updated to the active/archived model (no more `-DateFolder`,
  reads `active\` directly, archives the previous CSV set to
  `archived\benchmark_history\{date}\` on a real day-over-day regen).
- No v2 healer site (raid overview + boss pages built from real Druid events data)
  has been generated yet for any healer.

**Explicitly open, in priority-ish order:**
1. Generate an actual v2 healer site (at least one full raid night) to prove the
   enhanced pipeline end-to-end, including a raid overview page — see gear-audit
   regression note below, this hasn't been exercised since the events-based rewrite.
2. Gear audit has an undiscovered-but-expected regression: the old healing *table*
   embedded `gear` per player for free; healing *events* don't carry it at all.
   Nobody's built a raid overview page since the events-based rewrite, so this
   hasn't been hit yet, but it will be — see WORKFLOW.md's "Regression to know
   about" note for the fix (a `combatantinfo` events pull).
3. `resources`/`resources-gains` (HPM, mana-over-time) — **the API endpoint is
   confirmed dead (2026-07-12, 5 real test calls, every variant of `abilityid`
   tried, all identical failure), but it doesn't matter: we already have real
   mana data from a different source.** Every `*_casts_events.json` file already
   pulled (character AND Top 100 benchmark data alike) carries a
   `classResources[0]` object per cast event — `amount` = max mana pool
   (constant), `max` = that spell's real mana cost, `type` = current mana at
   that moment (despite the misleading field name). Verified by tracing a full
   real kill's cast sequence: `type` decreases smoothly from 10175 to 2781 over
   the fight, and `max` matches known real TBC spell costs exactly (Lifebloom
   220, Regrowth 675, Healing Touch 935, etc). HPM and a real mana-over-time
   trace are both computable right now, from data already on disk, no new pull
   needed — just not built into `summarize_class_benchmarks.ps1` or the boss
   page template yet. See WORKFLOW.md gotcha #11 for the full writeup.
4. Tranquility's guid is unknown/unobserved — `$cooldownGuids["Tranquility"]` is an
   empty array in both pull scripts and will silently show 0 forever until someone
   adds the real guid once it's actually seen in a pull.
5. Paladin/Priest/Shaman are still on the v1/simple, truncation-prone table
   approach AND the old date-stamped-folder convention — none of the events-based/
   cooldown/buff-uptime work OR the active/archived data model has been ported to
   them yet. Porting a class means: writing its own `pull_top100_{class}.ps1` on
   the Druid model (not the TEMPLATE model, which includes the active/archived
   diff logic for free), running `migrate_class_to_active.ps1` once against its
   existing date-folder pull, and its own `boss_page_template_{class}.html` per
   WORKFLOW.md's "Site structure" section.
6. One narrow, accepted gap: ~0.5% of Top 100 parses (1 real case observed) have no
   `combatantinfo` snapshot even within the 2-minute backward buffer, likely a
   late-joining player — currently just reported as a failure for that one player's
   consumables data, not chased further.

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
