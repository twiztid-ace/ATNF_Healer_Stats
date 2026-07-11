# ATNF Healer Analysis — Claude Code orientation

This is a WoW Classic (TBC/SSC-TK era) raid healer analysis pipeline: pull real combat
log data from Warcraft Logs' v1 API, benchmark it against Top 100 parses, and generate
a static HTML site auditing each healer's performance per boss kill.

**Read `WORKFLOW.md` first, in full, before touching anything.** It is the single
source of truth for this project — API endpoints, file formats, known bugs, and 24
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

## Repo structure

```
WORKFLOW.md                          <- read this first, full pipeline documentation
CLAUDE.md                            <- this file

scripts/
  pull_character_TEMPLATE.ps1        <- pulls one specific healer's full raid night
  pull_top100_druid.ps1              <- pulls Top 100 Resto Druid benchmark data (parallelized)
  pull_top100_TEMPLATE.ps1           <- generic version for other classes (healing table only,
                                         NOT yet updated to the events-based approach - see below)
  summarize_class_benchmarks.ps1     <- condenses raw Top 100 pulls into benchmark_*.csv files

templates/
  design_tokens.md                   <- the site's design system (colors, type, layout rules)
  boss_page_template.html            <- generic per-boss-kill page (any class)
  boss_page_template_druid.html      <- Resto Druid variant (extra cooldowns/consumables section)
  raid_overview_template.html        <- per-raid-night page (gear audit + 10-boss summary)
  healer_raidlist_template.html      <- per-healer page (list of raid nights analyzed)
  site_index_template.html           <- site homepage (list of healers)

reference/
  warcraftlogs_api.json              <- the real v1 API swagger spec (this environment's fetch
                                         tool couldn't render the live JS docs page - see gotcha
                                         #17 - this static copy is what unblocked several fixes)

examples/
  healer_audit_hydross.html          <- ONE real filled example page, built from real pulled
                                         data (Danceswtrees on Hydross) - NOT a template, an
                                         actual output. Useful as a reference for what a finished
                                         page should look like. NOTE: this predates the buff-
                                         uptime fix (see WORKFLOW.md) and still shows the old
                                         "temporarily unavailable" note for flask/food/Tree of
                                         Life - regenerate it before treating it as fully
                                         representative of the current templates.
```

Not included here (repo-specific, never shared in the source conversation):
`apikey.txt` (gitignored, WCL API key), `.gitignore`, and the actual `data/` output
folders from prior pulls. You'll need a real WCL API key to do anything live.

## Current state — what's solid vs. what's open

**Solid, validated against real API data repeatedly:**
- Resto Druid pipeline end to end: healing/casts (events-based, not the truncated
  tables), cooldown/utility tracking with self-vs-other targets, buff uptime
  (flask/food snapshot + real Tree of Life interval reconstruction), Top 100
  benchmarking, CSV summarization, the Druid boss page template.
- The parallelized `pull_top100_druid.ps1` (RunspacePool, `-MaxThreads 10` default,
  thread-safe via `ConcurrentDictionary` + a `TryAdd`-based claim mechanism for
  `deaths`) — validated on 2 of 10 bosses with clean data (199-200/200 successful
  parses), not yet run against all 10.

**Explicitly open, in priority-ish order:**
1. Only 2 of 10 bosses have been run through the full parallel Top 100 pipeline.
   Worth running the remaining 8 before trusting a complete benchmark dataset.
2. `healer_audit_hydross.html` needs regenerating post-buff-fix (see above).
3. Gear audit has an undiscovered-but-expected regression: the old healing *table*
   embedded `gear` per player for free; healing *events* don't carry it at all.
   Nobody's built a raid overview page since the events-based rewrite, so this
   hasn't been hit yet, but it will be — see WORKFLOW.md's "Regression to know
   about" note for the fix (a `combatantinfo` events pull).
4. `resources`/`resources-gains` (HPM, mana-over-time) were abandoned after
   `resourcetype=mana`/`resourcetype=0` both failed — but the real swagger spec
   later revealed the correct param name is `abilityid`, and **nobody's gone back
   and actually tested it**. Cheap, real opportunity if you want it.
5. Tranquility's guid is unknown/unobserved — `$cooldownGuids["Tranquility"]` is an
   empty array in both pull scripts and will silently show 0 forever until someone
   adds the real guid once it's actually seen in a pull.
6. `pull_top100_TEMPLATE.ps1` (generic, non-Druid classes) still uses the OLD
   truncation-prone table approach for healing — none of this session's fixes have
   been ported to it. Same for `boss_page_template.html` (generic template).
7. One narrow, accepted gap: ~0.5% of Top 100 parses (1 real case observed) have no
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
