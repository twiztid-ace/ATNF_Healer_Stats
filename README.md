# ATNF Healer Analysis

A WoW Classic (TBC/SSC-TK era) raid healer analysis pipeline. It pulls real combat
log data from Warcraft Logs, benchmarks it against Top 100 parses for the same
boss, and generates a static HTML site auditing each healer's performance per
boss kill.

This file covers day-to-day setup and running the pipeline. For the full design
(API details, file formats, known gotchas) see `WORKFLOW.md`. For orientation on
the codebase's history and current state, see `CLAUDE.md`.

Supported classes: **Resto Druid, Resto Shaman, Holy Priest, Holy Paladin.**

## Requirements

- Windows PowerShell 5.1 (scripts are not verified on PowerShell 7+/pwsh, Linux,
  or macOS — see `WORKFLOW.md` gotchas #13/#14/#19 for encoding/parsing traps
  that are specific to Windows PowerShell 5.1's default codepage).
- A Warcraft Logs v2 GraphQL API client ID/secret (see "Setup" below).

## Setup

The pipeline pulls data through WCL's v2 GraphQL API. Create these three files
at the repo root (all gitignored — never commit them):

- `v2_client_id.txt` — your WCL API client ID
- `v2_client_secret.txt` — your WCL API client secret
- `v2_access_token.txt` — created/refreshed automatically by
  `scripts\lib\WclV2Api.psm1` on first run; you don't need to create this one
  by hand

Get a client ID/secret from your Warcraft Logs account's API Clients page
(client type: "Client"). No other setup is required — all scripts assume the
repo root as the working directory.

## Repo layout (short version)

```
scripts\                     PowerShell pipeline scripts (see below)
scripts\lib\                 Shared modules (WCL API client, template renderer)
templates\                   HTML templates (per-class boss pages, raid overview, hub pages)
data\Classes\{Class}\        Top 100 benchmark pulls (active/archived + manifest.json)
data\Characters\{Name}\{ReportCode}\   Per-character pulled data + generated report_data.json/analysis.json/findings.json
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

## Running the pipeline normally (with Claude Code)

The intended way to generate a report is the `generate-healer-report` Claude
Code skill:

```
/generate-healer-report <CharacterName> <ReportCode-or-URL>
```

e.g. `/generate-healer-report Crowns XJp8vAxzM4KtHYyb`. This runs every step
below in order, including the one step that genuinely needs an LLM (writing
`findings.json`'s free-text analysis). See
`.claude\skills\generate-healer-report\SKILL.md` for the full step-by-step
runbook.

## Running the pipeline manually, without Claude

Every step except one is a deterministic PowerShell script with no LLM
involvement at all. You can run the whole pipeline by hand from a plain
PowerShell prompt. **One script only exists to make this possible without
Claude**: `build_placeholder_findings.ps1` stands in for the "Claude writes
findings.json" step by filling every required finding with an obvious
placeholder string, so the renderer has something to consume. Pages built this
way clearly read as unfinished — every finding says:

> [CLAUDE PLACEHOLDER - no real finding was generated for this page. Run the
> generate-healer-report skill in Claude Code, or hand-author a real
> findings.json, before treating this as a real audit.]

This is intentional: the renderer deliberately refuses to run at all without a
`findings.json` (and refuses to treat a blank/missing finding as "fine, just
skip it"), specifically so nobody can accidentally publish a page that looks
real but isn't. Do not push placeholder pages to the live site — they exist
only to prove the mechanical half of the pipeline works, or as a scaffold you
fill in by hand afterward.

Full manual sequence, run from the repo root:

```powershell
# 1. Pull the character's raid data for this report
powershell -ExecutionPolicy Bypass -File scripts\pull_character_TEMPLATE.ps1 `
    -ReportCode "<code>" -CharacterName "<name>"
# Note the resolved class and raid date printed in its output - the class is
# needed for every step below; the raid date is only ever used for display text
# (output folders are keyed by report code, not date, since two raids can
# happen on the same calendar day).

# 2. Refresh that class's Top 100 benchmark (diff-based, cheap to re-run)
powershell -ExecutionPolicy Bypass -File scripts\pull_top100_druid.ps1
powershell -ExecutionPolicy Bypass -File scripts\pull_top100_shaman.ps1
powershell -ExecutionPolicy Bypass -File scripts\pull_top100_priest_holy.ps1
powershell -ExecutionPolicy Bypass -File scripts\pull_top100_paladin.ps1
# (run only the one matching the resolved class)

# 3. Re-summarize the benchmark CSVs
powershell -ExecutionPolicy Bypass -File scripts\summarize_class_benchmarks.ps1 -ClassName "<Class>"

# 4. Compute the report's real numbers (zero API calls from here on)
powershell -ExecutionPolicy Bypass -File scripts\build_boss_report_data.ps1 `
    -CharacterName "<name>" -ReportCode "<code>" -ClassName "<Class>"

# 5. Pre-flag every script-safe judgment call (deviations, cooldown over/undercast, etc.)
powershell -ExecutionPolicy Bypass -File scripts\build_boss_analysis.ps1 `
    -CharacterName "<name>" -ReportCode "<code>" -ClassName "<Class>"

# 6. Stand in for Claude's findings.json with placeholder text
powershell -ExecutionPolicy Bypass -File scripts\build_placeholder_findings.ps1 `
    -CharacterName "<name>" -ReportCode "<code>"
# Add -Force if a findings.json already exists and you specifically want to
# replace it with placeholder text (this will not happen by accident - the
# script refuses to overwrite an existing file otherwise).

# 7. Render every boss page + the raid overview
powershell -ExecutionPolicy Bypass -File scripts\render_healer_report.ps1 `
    -CharacterName "<name>" -ReportCode "<code>" -ClassName "<Class>" -RaidTitle "<title>"

# 8. Insert this raid night into the hub pages
powershell -ExecutionPolicy Bypass -File scripts\update_hub_pages.ps1 `
    -CharacterName "<name>" -RaidDate "<yyyy-MM-dd>" -ReportCode "<code>" `
    -ClassName "<Class>" -BossesKilled <N> -RaidTitle "<title>" [-IsNewHealer]
# -RaidDate here is display text only - the inserted link always points at
# <code>/index.html, matching step 7's report-code-named output folder. The
# healer's raid-list is always re-sorted by real raid date (descending) after
# the insert, so generating an older report after a newer one (a backfill)
# still lands the new row in the correct chronological position, not just at
# the top - see the next section.
```

### Keeping a healer's raid-list ordered by date

`update_hub_pages.ps1` always re-sorts a healer's entire raid-list by raid date,
descending, after inserting a new row — never just prepends it. This matters
because folders are keyed by report code (see above), so the order raids
happen to get *generated* in no longer has any natural correlation with the
order they actually happened in — backfilling an older raid after a newer one
is a real, expected scenario, not just a hypothetical.

To re-sort an existing healer's raid-list without inserting anything (e.g.
after a manual edit, or just to double-check ordering), run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\update_hub_pages.ps1 -CharacterName "<name>" -ResortOnly
```

This only requires `-CharacterName` — every other row is parsed straight out of
the existing page and re-sorted in place, with a `WARNING` printed (and that row
sorted last, never dropped) if a row's date text can't be parsed.

After step 8, `docs\<name-lowercase>\<code>\` has a full set of boss pages and a
raid overview — but every coverage-note on every page is the placeholder text
from step 6, not a real finding. To turn this into a real, publishable report,
either:
- re-run `/generate-healer-report <name> <code>` in Claude Code (it will detect
  the existing `report_data.json`/`analysis.json` and just needs a real
  `findings.json` written and the render/hub steps re-run), or
- hand-author a real `data\Characters\<name>\<code>\<code>_findings.json`
  yourself, following the schema documented in `render_healer_report.ps1`'s own
  header comment and in `SKILL.md`, then re-run steps 7-8 above.

## Adding a new boss

There is no single source of truth for the boss list — it's duplicated across
**6 hardcoded tables in 6 files**, plus **2 numeric defaults** that track total
tier size separately. All of these must be kept consistent by hand. Everything
else in the pipeline (`render_healer_report.ps1`'s per-boss rendering,
`build_boss_analysis.ps1`, `build_boss_report_data.ps1`'s downstream logic, and
every HTML template) iterates dynamically over whatever bosses are present in
the data — none of it needs to change for a new boss.

### 1. Find the real encounter ID first

Don't guess — confirm the boss's real WCL encounter ID with one real lookup
before touching any of the tables below (same "test one real call before
building around an assumption" discipline as everywhere else in this
pipeline). Two options:

- Check `data\zones.json` first — it's a local, point-in-time snapshot of real
  WCL zone/encounter data (`{id, name, encounters:[{id,name}], ...}`) that may
  already have the new zone. It is **not** kept up to date automatically and
  is not referenced by any script — treat it as a quick lookup only, and don't
  assume it has a genuinely new content tier just because it exists.
- If the new zone isn't there yet, run a live GraphQL query through
  `scripts\lib\WclV2Api.psm1`'s `Invoke-WclGraphQL`:
  `query { worldData { zones { id name encounters { id name } } } }` (or
  `worldData { encounter(id: N) { name } }` if you already suspect an ID).

### 2. Add the boss to all 6 tables

Every table is keyed/cross-referenced by the same real encounter ID from step
1. Field shapes differ slightly per file — match them exactly:

| # | File | Table | Shape |
|---|------|-------|-------|
| 1-4 | `scripts\pull_top100_druid.ps1`, `pull_top100_shaman.ps1`, `pull_top100_priest_holy.ps1`, `pull_top100_paladin.ps1` | `$bosses` | `"BossName" = @{ file = "rankings_bossname.json"; encounterID = 100XXX }` |
| 5 | `scripts\pull_character_TEMPLATE.ps1` | `$bossSlugs` | `100XXX = "bossslug"` |
| 6 | `scripts\build_boss_report_data.ps1` | `$bossMeta` | `100XXX = @{ Slug = "bossslug"; FolderName = "BossName"; Display = "Boss Full Name" }` |

- `"BossName"`/`FolderName` must be the exact same string across tables 1-4
  and 6 — it's used as a literal subfolder name under
  `data\Classes\{Class}\active\`/`archived\`.
- `bossslug` must match across tables 5 and 6 — it's used both as the
  per-boss-kill filename slug (`fight14_bossslug_healing_events.json`) and as
  the `Bosses` object's property name in `report_data.json`/`analysis.json`.
- `$bossMeta` in `build_boss_report_data.ps1` is deliberately a **plain**
  hashtable (`@{...}`), not `[ordered]@{...}` — its keys are bare integers,
  and `[ordered]@{}` (`OrderedDictionary`) silently resolves an integer key
  through its positional `this[int index]` indexer instead of a real
  key lookup, so `$orderedDict[100623]` would silently return `$null` even
  though the key is really present. **Don't "fix" this to `[ordered]@{}`.**
- `pull_character_TEMPLATE.ps1`'s `Get-BossSlug` falls back to auto-deriving a
  slug from the boss's display name if the encounter ID isn't in
  `$bossSlugs` — meaning a missing table 5 entry won't hard-fail, just risk a
  slug that silently doesn't match `build_boss_report_data.ps1`'s canonical
  one. Don't rely on this fallback; add the explicit entry.
- There's a 7th, separate table in the same shape in
  `scripts\summarize_class_benchmarks.ps1` (`$bosses`, keyed the same way as
  tables 1-4 but with a `display` field instead of `encounterID`) that also
  needs the new boss added, so 6 files in total once you count it.

If a boss ID ever turns up in real data with no `$bossMeta` entry,
`build_boss_report_data.ps1` already prints an explicit warning naming exactly
this fix (`WARNING: boss id $bossID ('$($fight.name)') has no known
slug/display mapping - skipping. Add it to $bossMeta...`) rather than failing
silently — a good sanity check that you didn't miss table 6.

### 3. Bump the two total-tier-size defaults

Two scripts track "how many bosses are in the full tier" as a separate,
plain `-TotalBosses` parameter (default `10`) — neither derives it from the
tables above, so both need updating (or overriding per-call) once the tier
grows:

- `scripts\render_healer_report.ps1 -TotalBosses <N>` — feeds the raid
  overview's own "`<kills>`/`<N>` bosses killed" line.
- `scripts\update_hub_pages.ps1 -TotalBosses <N>` — feeds the same "X/Y
  bosses" text on the healer's hub-page raid-row.

There is no shared source of truth between these two — keep them in sync by
hand, or pass `-TotalBosses` explicitly on every call until you update both
defaults.

### 4. What you don't need to touch

- `manifest.json` — auto-populated by each `pull_top100_{class}.ps1` the next
  time it runs; no manual edit needed.
- `render_healer_report.ps1`'s per-boss rendering, `build_boss_analysis.ps1`,
  `build_boss_report_data.ps1`'s fight-processing loop, and every HTML
  template — all iterate dynamically over whatever boss keys are present in
  the data, not a fixed list.
- `scripts\migrate_class_to_active.ps1` has its own boss table too, but it's a
  one-time, already-used migration tool for converting a *class* off the old
  date-folder convention — irrelevant to adding a boss to an already-migrated
  class.

### 5. New cooldowns

If the new content tier's boss encourages different cooldown usage, or the
class gains new relevant abilities, treat that as its own real-data discovery
pass (confirm the guid against an actual pull before adding it) — the same
rule this project already applies to every class's cooldown-guid table, see
`WORKFLOW.md`'s "v2 GraphQL API" section for the established playbook (and
its cautionary tale about the Holy Shock cast/heal guid split, where a
finding scoped to one character's report turned out to be wrong once checked
against the full Top 100 sample).

## Hosting

The generated site lives under `docs\` and is served by GitHub Pages
(`master` branch, `/docs` folder — see `CLAUDE.md`'s "Hosting" section for the
full setup). Regenerating a report and pushing `docs\` is the entire publish
step; there is no separate build process.
