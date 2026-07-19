# ATNF Healer Analysis

A WoW Classic (TBC/SSC-TK era) raid healer analysis pipeline. It pulls real combat
log data from Warcraft Logs, benchmarks it against Top 100 parses for the same
boss, and generates a static HTML site auditing each healer's performance per
boss kill.

This file covers day-to-day setup and running the pipeline. For the full design
(API details, file formats, known gotchas, current state) see `CLAUDE.md` — it
is the single source of truth for orientation (the former `WORKFLOW.md` was
retired 2026-07-18 and folded into it).

Supported classes/builds: **Resto Druid, Resto Shaman, Holy Priest, Holy
Paladin, Dreamstate Druid.**

**The pipeline runs on Python now** (migrated from a Windows PowerShell 5.1
implementation — see `CLAUDE.md` for the migration's own history). The
original PowerShell scripts (`scripts\*.ps1`, `templates\*.html`) were kept
as a preserved reference/rollback copy through the migration, then deleted
2026-07-19 once the Python pipeline was verified stable (git history still
has them if ever needed).

## Running the pipeline (two ways)

**With Claude-authored findings** (the intended way — produces a real,
publishable report):

```
/generate-healer-report <CharacterName> <ReportCode-or-URL>
```

**Data only, no LLM** (proves the mechanical pipeline works end to end; every
finding reads as an obvious placeholder — do not publish this output):

```
python -m pipeline.cli generate --character-name "<CharacterName>" --report-code "<ReportCode>" --placeholder-findings
```

Both run the exact same underlying steps (pull the character's raid data,
refresh and re-summarize that class's Top 100 benchmark, compute the report's
real numbers, render every page, update both hub pages) — the only
difference is whether `findings.json`'s free-text analysis comes from Claude
or from an obvious placeholder string. See "Running the pipeline in detail"
below for the full breakdown, including running individual stages one at a
time.

## Requirements

- Python 3.10+ (developed and tested on 3.12). Install dependencies with
  `pip install -r requirements.txt` (`requests`, `jinja2` — kept deliberately
  minimal).
- A Warcraft Logs v2 GraphQL API client ID/secret (see "Setup" below).
- Tested on Windows; the pipeline has no Windows-specific code paths left
  (the PowerShell 5.1 encoding/parsing traps the old PowerShell implementation
  had don't apply to the Python implementation), but it hasn't yet been run
  end-to-end on macOS/Linux — the underlying WCL API calls and file I/O are
  platform-agnostic, so it's expected to work, just not yet confirmed on a
  real non-Windows box.

## Setup

The pipeline pulls data through WCL's v2 GraphQL API. Create these three files
at the repo root (all gitignored — never commit them):

- `v2_client_id.txt` — your WCL API client ID
- `v2_client_secret.txt` — your WCL API client secret
- `v2_access_token.txt` — created/refreshed automatically by
  `pipeline\wcl_api.py` on first run; you don't need to create this one
  by hand

Get a client ID/secret from your Warcraft Logs account's API Clients page
(client type: "Client"). No other setup is required — all commands assume the
repo root as the working directory.

## Repo layout (short version)

```
pipeline\                    Python pipeline package (see below)
templates_jinja\              Jinja2 HTML templates (per-class boss pages, raid overview, hub pages)
tools\                        Live, non-pipeline tooling (statusline.ps1 + its WCL API helper)
data\Classes\{Class}\        Top 100 benchmark pulls (active/archived + manifest.json)
data\Characters\{Name}\{ReportCode}\   Per-character pulled data + generated report_data.json/analysis.json/findings.json
data\Characters\{Name}\index.json      This healer's raid-night list (source of truth for their hub page)
data\site_index.json          The site-wide healer list (source of truth for the homepage)
docs\{healer}\{ReportCode}\  The generated static site (served via GitHub Pages from /docs)
.claude\skills\generate-healer-report\   The Claude Code skill that runs this pipeline end to end
```

Both per-report folders are keyed by **report code**, not raid date — two raids
can happen on the same calendar date, and the per-boss-kill files inside
(`fight14_lurker_healing_events.json`, etc.) carry no report code of their own,
so a shared date folder would risk one report's data silently overwriting
another's. The raid date is still tracked (as `report_data.json`'s own
`RaidDate` field) purely for display text on the generated pages. Folders
pulled before this convention was introduced are still named with a
`yyyy-MM-dd` date instead — the pipeline recognizes and keeps working with
either, so nothing needs to be renamed retroactively.

See `CLAUDE.md` for the full annotated tree.

## Running the pipeline in detail

### With Claude Code (produces a real, publishable report)

```
/generate-healer-report <CharacterName> <ReportCode-or-URL>
```

e.g. `/generate-healer-report Crowns XJp8vAxzM4KtHYyb`. This runs every stage
below in order, including the one stage that genuinely needs an LLM (writing
`findings.json`'s free-text analysis) — Claude shells out to
`python -m pipeline.cli` for every other stage. See
`.claude\skills\generate-healer-report\SKILL.md` for the full step-by-step
runbook.

### Without Claude (data only, no LLM)

Every stage except one is a deterministic Python function with no LLM
involvement at all — `pipeline\cli.py generate` chains them all into one
command. **One stage only exists to make this possible without Claude**:
`--placeholder-findings` stands in for the "Claude writes findings.json" step
by filling every required finding with an obvious placeholder string, so the
renderer has something to consume. Pages built this way clearly read as
unfinished — every finding says:

> [CLAUDE PLACEHOLDER - no real finding was generated for this page. Run the
> generate-healer-report skill in Claude Code, or hand-author a real
> findings.json, before treating this as a real audit.]

This is intentional: the renderer deliberately refuses to run at all without a
`findings.json` (and refuses to treat a blank/missing finding as "fine, just
skip it"), specifically so nobody can accidentally publish a page that looks
real but isn't. Do not push placeholder pages to the live site — they exist
only to prove the mechanical half of the pipeline works, or as a scaffold you
fill in by hand afterward.

One-line version:

```
python -m pipeline.cli generate --character-name "<name>" --report-code "<code>" --placeholder-findings
```

This auto-resolves the character's real class/spec from the report itself (no
need to know it up front), refreshes and re-summarizes that class's Top 100
benchmark, computes the report's real numbers, writes the placeholder
findings, renders every page, and updates both hub pages — printing the
resolved pipeline class as it goes. If a real `findings.json` already exists
for this report, it's used as-is and never overwritten by the placeholder,
even with this flag passed.

### Running individual stages

Each stage `generate` chains is also its own subcommand, useful for
re-running just one step (e.g. after editing `findings.json` by hand) without
repeating the whole pipeline:

```
# 1. Pull the character's raid data for this report
python -m pipeline.cli pull-character --report-code "<code>" --character-name "<name>"
# Prints the resolved pipeline class at the end - needed for every step below.
# The raid date is only ever used for display text (output folders are keyed
# by report code, not date, since two raids can happen on the same calendar day).

# 2. Refresh that class's Top 100 benchmark (diff-based, cheap to re-run)
python -m pipeline.cli pull-top100 --class-name "<Class>"

# 3. Re-summarize the benchmark CSVs
python -m pipeline.cli summarize-benchmarks --class-name "<Class>"

# 4. Compute the report's real numbers (zero API calls from here on)
python -m pipeline.cli build-report-data --character-name "<name>" --report-code "<code>" --class-name "<Class>"

# 5. Pre-flag every script-safe judgment call (deviations, cooldown over/undercast, etc.)
python -m pipeline.cli build-analysis --character-name "<name>" --report-code "<code>" --class-name "<Class>"

# 6. Stand in for Claude's findings.json with placeholder text
python -m pipeline.cli placeholder-findings --character-name "<name>" --report-code "<code>"
# Add --force if a findings.json already exists and you specifically want to
# replace it with placeholder text (this will not happen by accident - the
# command refuses to overwrite an existing file otherwise).

# 7. Render every boss page + the raid overview
python -m pipeline.cli render --character-name "<name>" --report-code "<code>" --class-name "<Class>" --raid-title "<title>"

# 8. Insert this raid night into the hub pages
python -m pipeline.cli update-hub --character-name "<name>" --raid-date "<yyyy-MM-dd>" --report-code "<code>" --class-name "<Class>" --bosses-killed <N> --raid-title "<title>"
# --raid-date here is display text only - the inserted link always points at
# <code>/index.html, matching step 7's report-code-named output folder. The
# healer's raid-list is always re-sorted by real raid date (descending) after
# the insert, so generating an older report after a newer one (a backfill)
# still lands the new row in the correct chronological position, not just at
# the top - see the next section. New-healer registration on the site
# homepage is automatic - no separate flag to remember.
```

### Keeping a healer's raid-list ordered by date

`update-hub` always re-sorts a healer's entire raid-list by raid date,
descending, after inserting a new row — never just appends it. This matters
because folders are keyed by report code (see above), so the order raids
happen to get *generated* in no longer has any natural correlation with the
order they actually happened in — backfilling an older raid after a newer one
is a real, expected scenario, not just a hypothetical.

To re-sort an existing healer's raid-list without inserting anything (e.g.
after a manual edit, or just to double-check ordering), run:

```
python -m pipeline.cli update-hub --character-name "<name>" --resort-only
```

This only requires `--character-name` — it fully re-renders the hub page from
the healer's existing `data\Characters\<name>\index.json`, sorted, with no
data mutation.

After step 8 (or the one-line data-only `generate` command), `docs\<name-lowercase>\<code>\`
has a full set of boss pages and a raid overview — but if you used
placeholder findings, every coverage-note on every page is the placeholder
text, not a real finding. To turn this into a real, publishable report,
either:
- re-run `/generate-healer-report <name> <code>` in Claude Code (it will detect
  the existing `report_data.json`/`analysis.json` and just needs a real
  `findings.json` written and the render/hub steps re-run), or
- hand-author a real `data\Characters\<name>\<code>\<code>_findings.json`
  yourself, following the schema documented in `pipeline\render_report.py`'s own
  module docstring and in `SKILL.md`, then re-run steps 7-8 above.

## Running the pipeline for every already-tracked healer against one report

A raid log is often shared by more than one tracked healer (e.g. a Druid and
a Shaman healing the same raid night) — `pipeline\pull_character.py` already
resolves each character independently from the report's own `actors[]`/
`rankings()` data, so nothing about a single pull assumes there's only one
healer in the log. `generate-all` is a thin loop around the same per-stage
functions `generate` uses, run once per healer already registered in
`data\site_index.json`, instead of requiring one `/generate-healer-report`
invocation per name:

```
python -m pipeline.cli generate-all --report-code "<ReportCode>" --placeholder-findings
```

For each already-tracked healer (default: everyone in `data\site_index.json`
— **not** every folder under `data\Characters\`, since a healer can be
pulled once and deliberately kept unlisted from the site homepage, see
`CLAUDE.md`'s Turkeykin note; pass `--character-names "A,B,C"` to include
someone not in `site_index.json`, or to scope the run to fewer names), it:

- Pulls that character's data for this report code, same as `pull-character`.
- **Skips that one healer, and only that healer**, and keeps going, when the
  character genuinely isn't in this report (not found in `actors[]`), or
  when they play more than one real spec across this report's boss kills and
  need an explicit `--spec` (re-run `pull-character` for that one name by
  hand with `--spec` if this happens, then re-run `generate-all` — it will
  find the cached pull and pick up from there).
- **Stops the whole batch immediately** on any other failure (bad/private
  report code, an API error) — that kind of failure is report-level, not
  per-healer, so retrying it once per remaining name would just repeat the
  same failure and burn API calls for nothing.
- Skips a healer whose resolved class/spec isn't on the pipeline yet, or who
  has 0 boss kills in this report (benched, or off-spec the whole night).
- Refreshes and re-summarizes each *distinct* resolved class's Top 100
  benchmark once per run, not once per healer sharing that class.
- Computes `report_data.json`/`analysis.json` for every healer that made it
  this far, same as `build-report-data`/`build-analysis`.
- Renders pages and upserts the hub pages for any healer whose
  `findings.json` already exists (or gets a placeholder one, with
  `--placeholder-findings`) — otherwise it prints exactly which
  `..._findings.json` path still needs authoring and moves on to the next
  healer, without blocking the rest of the batch.

Prints a per-healer summary line (`done`, `skipped`, `needs-findings`, or
`error`) at the end either way.

**With Claude-authored findings**, the same `/generate-healer-report` skill
handles this too — pass it just a report code (no character name) and it
runs `generate-all` twice: once to pull every already-tracked healer and
stop right before findings, once more (after authoring a real
`<code>_findings.json` for each healer that needed one) to render and update
every affected hub page. See `.claude\skills\generate-healer-report\SKILL.md`'s
"Running for every already-tracked healer" section for the exact steps.

## Adding a new boss

`pipeline\bosses.py` is the single source of truth for the boss list — one
dict, one entry per boss. Everything else in the pipeline (`render_report.py`'s
per-boss rendering, `build_analysis.py`, `build_report_data.py`'s downstream
logic, and every Jinja2 template) iterates dynamically over whatever bosses
are present in the data — none of it needs to change for a new boss.

### 1. Find the real encounter ID first

Don't guess — confirm the boss's real WCL encounter ID with one real lookup
before adding the entry below (same "test one real call before
building around an assumption" discipline as everywhere else in this
pipeline). Two options:

- Check `data\zones.json` first — it's a local, point-in-time snapshot of real
  WCL zone/encounter data (`{id, name, encounters:[{id,name}], ...}`) that may
  already have the new zone. It is **not** kept up to date automatically and
  is not referenced by any script — treat it as a quick lookup only, and don't
  assume it has a genuinely new content tier just because it exists.
- If the new zone isn't there yet, run a live GraphQL query through
  `pipeline\wcl_api.py`'s `invoke_wcl_graphql`:
  `query { worldData { zones { id name encounters { id name } } } }` (or
  `worldData { encounter(id: N) { name } }` if you already suspect an ID).

### 2. Add the boss to `pipeline\bosses.py`

One file, one dict entry — this used to be "6 hardcoded tables in 6 files"
under the PowerShell implementation (see `CLAUDE.md` for that history); the
Python port consolidated all of them into `pipeline\bosses.py`'s single
`BOSSES` dict, keyed by the real encounter ID from step 1:

```python
100XXX: BossMeta(100XXX, "bossslug", "BossName", "Boss Full Name", "rankings_bossname.json"),
```

- `"BossName"` (the `folder_name` field) is used as a literal subfolder name
  under `data\Classes\{Class}\active\`/`archived\`.
- `"bossslug"` is used both as the per-boss-kill filename slug
  (`fight14_bossslug_healing_events.json`) and as the `Bosses` object's
  property name in `report_data.json`/`analysis.json`.
- `pull_character.py`'s `_get_boss_slug` falls back to auto-deriving a slug
  from the boss's display name if the encounter ID isn't in `BOSSES` —
  meaning a missing entry won't hard-fail, just risk a slug that silently
  doesn't match the canonical one. Don't rely on this fallback; add the
  explicit entry.

If a boss ID ever turns up in real data with no `BOSSES` entry,
`build_report_data.py` already prints an explicit warning naming exactly
this fix (`WARNING: boss id $bossID (...) has no known slug/display mapping
- skipping. Add it to bosses.py...`) rather than failing silently — a good
sanity check that you didn't miss the entry.

### 3. Nothing to bump — the "bosses killed" denominator is derived, not configured

`build_report_data.py` writes a real `BossesAttempted` count to
`report_data.json` (every real boss pull this report has, kill or wipe — not
just the kills already captured in `Bosses`); `render_report.py` compares it
against the real kill count and only shows a "`<kills>`/`<attempted>`"
denominator when a real wipe is present in this report's own data. Nothing to
bump when a new boss is added to the tracked tier — this is a per-report
fact, not a per-tier constant (a real, already-fixed bug in the PowerShell
predecessor — see `CLAUDE.md` for the "12/10 bosses killed" incident this
design replaced).

### 4. What you don't need to touch

- `manifest.json` — auto-populated by `pipeline\pull_top100.py` the next time
  it runs; no manual edit needed.
- `render_report.py`'s per-boss rendering, `build_analysis.py`,
  `build_report_data.py`'s fight-processing loop, and every Jinja2 template —
  all iterate dynamically over whatever boss keys are present in the data,
  not a fixed list.

### 5. New cooldowns

If the new content tier's boss encourages different cooldown usage, or the
class gains new relevant abilities, treat that as its own real-data discovery
pass (confirm the guid against an actual pull before adding it) — the same
rule this project already applies to every class's cooldown-guid table, see
`CLAUDE.md`'s "Per-build real cooldown/utility kits" section for the
established playbook (and its cautionary tale about the Holy Shock cast/heal
guid split, where a finding scoped to one character's report turned out to be
wrong once checked against the full Top 100 sample).

## Hosting

The generated site lives under `docs\` and is served by GitHub Pages
(`master` branch, `/docs` folder — see `CLAUDE.md`'s "Hosting" section for the
full setup). Regenerating a report and pushing `docs\` is the entire publish
step; there is no separate build process.
