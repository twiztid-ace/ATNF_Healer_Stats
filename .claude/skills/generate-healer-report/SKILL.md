---
name: generate-healer-report
description: Generates a complete v2 healer report (per-boss audit pages + raid overview, real data only) for a given character name and Warcraft Logs report code. Pulls the character's raid data, refreshes that class's Top 100 benchmark, re-summarizes it, computes real per-boss stats, and builds/updates every affected docs/ page. Use when the user asks to build, generate, regenerate, or update a healer's report for a specific raid log.
user-invocable: true
disable-model-invocation: true
tools: PowerShell, Read, Write, Edit, Glob, Grep
argument-hint: <CharacterName> <ReportCode-or-URL>
---

# Generate a healer report

Invoked as `/generate-healer-report <CharacterName> <ReportCode-or-URL>`, e.g.
`/generate-healer-report Danceswtrees XJp8vAxzM4KtHYyb`. The two values in
`$ARGUMENTS` are the character name and a report code or full WCL report URL, in
that order — if either is missing or ambiguous, ask the user rather than guessing.

Turns `CharacterName` + `ReportCode` (or a full WCL report URL) into a complete,
real v2 report: one audit page per boss kill, a raid overview (gear audit + per-boss
summary), and every existing page that needs a new entry for it.

Run this from the repo root (`C:\Users\raymo\wc_logs`) — every script here assumes
that working directory, same as the rest of this pipeline.

**Read `WORKFLOW.md` and `CLAUDE.md` first if this is a fresh session with no other
context on this project** — this skill assumes familiarity with the active/archived
data model, the events-vs-tables history, and the v1/v2 split. This file is the
runbook for *this specific task*, not a replacement for those.

## Before starting: confirm the class is supported

Step 2 resolves the character's class. **Druid, Shaman, and Priest (Holy) are on
the real v2 pipeline today** (`pull_top100_druid.ps1`/`pull_top100_shaman.ps1`/
`pull_top100_priest_holy.ps1`,
`boss_page_template_druid.html`/`boss_page_template_shaman.html`/
`boss_page_template_priest.html`, and the cooldown-guid tables in
`build_boss_report_data.ps1` cover all three — Priest added 2026-07-13, ported the
same way Shaman was: real-data discovery pass against a real Lippies report
before writing any guid table, see `pull_top100_priest_holy.ps1`'s header).
Paladin is still v1 (truncation-prone healing TABLE, old date-stamped-folder
convention) — running this pipeline against it will produce wrong or missing
data, not just incomplete data.

**If the resolved class isn't Druid, Shaman, or Priest: stop and tell the user
clearly** — name the class, say it isn't on the v2 pipeline yet, and don't
proceed past step 2. Don't attempt a "best effort" fallback (e.g. quietly reusing
another class's cooldown list or template for an unsupported class) — that would
produce a report with fabricated-looking numbers for abilities that class doesn't
even have.

## Pipeline

### 1. Resolve inputs
Accept a character name and a report code or full WCL URL. If given a URL, extract
the code the same way `pull_character_TEMPLATE.ps1` does:
`warcraftlogs\.com/reports/([A-Za-z0-9]+)`.

### 2. Pull character data
```
powershell -ExecutionPolicy Bypass -File scripts\pull_character_TEMPLATE.ps1 -ReportCode "<code>" -CharacterName "<name>"
```
This resolves class/server/region from the report's own `friendlies[]`, derives the
raid date from the report title, and pulls healing/casts/consumables/gear/
activetime/deaths per boss kill plus the character's full parse history. Read its
output carefully:
- If it reports `0 boss kill(s) found` or the character wasn't found in
  `friendlies[]`, **stop here** — don't proceed to build pages from nothing. Tell
  the user what went wrong (wrong report code, character not in this report, etc.).
- Note the resolved class from the "Found '<name>' in friendlies[]: <Class>, ..."
  line — this drives every step after this one. Check it against the class-support
  gate above before continuing.
- Note the resolved raid date (used to construct `docs\{healer}\{date}\` paths
  later).

### 3. Update the matching class's Top 100 benchmark data
```
powershell -ExecutionPolicy Bypass -File scripts\pull_top100_druid.ps1
powershell -ExecutionPolicy Bypass -File scripts\pull_top100_shaman.ps1
powershell -ExecutionPolicy Bypass -File scripts\pull_top100_priest_holy.ps1
```
Dispatch to whichever script matches the resolved class from step 2 (Druid,
Shaman, or Priest today — see the gate above; if/when Paladin gets its own
`pull_top100_{class}.ps1` on this same model, dispatch to that instead, same
invocation shape). This is diff-based against `manifest.json` — it only makes real
API calls for parses that are genuinely new or have re-entered the Top 100 since
the last run, so running it here is cheap even if it was run recently.

### 4. Run the summarization
```
powershell -ExecutionPolicy Bypass -File scripts\summarize_class_benchmarks.ps1 -ClassName "<Class>"
```
Regenerates all four `data\Classes\<Class>\active\benchmark_*.csv` files from the
now-current Top 100 data. Always run this after step 3, even if step 3 found no new
parses — cheap, local, no API calls.

### 5. Compute report data
```
powershell -ExecutionPolicy Bypass -File scripts\build_boss_report_data.ps1 -CharacterName "<name>" -ReportCode "<code>" -ClassName "<Class>"
```
Writes `data\Characters\<name>\<date>\<code>_report_data.json` — one clean JSON with
every real number needed for every boss page and the raid overview: HPS/overheal,
spell composition (guid-grouped, ready to union against the benchmark), cooldown
counts/self%/real per-cast targets, HPM, active time, target distribution,
percentile/rank matched by exact reportID+fightID, and a cross-kill gear diff (which
slots vary, and what's equipped on each kill where they do — purely factual, no
interpretation baked in). **Read the script's own Warning output** — a missing
benchmark row or missing gear files will be called out there, not silently absent
from the JSON.

**This step makes zero API calls.** Everything after this point is read-only against
files already on disk — steps 6-7 should never need to touch the network.

### 6. Build the report pages
Read `<code>_report_data.json` from step 5. For every boss present in its `Bosses`
object, build `docs\<healer>\<date>\healer_audit_<bossSlug>.html` from
`templates\boss_page_template_<class>.html` (lowercase the class name for the
filename — `boss_page_template_druid.html`). Then build
`docs\<healer>\<date>\index.html` from `templates\raid_overview_template.html`,
using the same JSON's per-boss summary rows and the `GearDiff` object for the gear
audit section.

**If `docs\<healer>\<date>\` already has real v2 pages from a prior run, rebuild
them from the current data — don't skip.** Benchmark data can shift between runs
(new Top 100 parses, re-entries), so a stale page is a real correctness problem, not
just a missed optimization. **Never write into a `\<date>-v1\` folder** — that's the
frozen, git-tracked original v1 output; if a `-v1` sibling exists for this
healer+date, leave it untouched.

**This is the one step that genuinely needs real judgment — it cannot be
mechanical.** The JSON from step 5 gives you exact numbers; the template gives you
structure; but every coverage-note needs a real finding, not templated boilerplate.
Concretely, before writing a page:
- Compare this boss's HPS/overheal/HPM/active-time against its own `BM` row (Top 1,
  average, median) — state the real gap, not just the numbers.
- Check `DeathList` timestamps against `CooldownRows` timestamps for the same
  fight — a death shortly after a cooldown was already spent, or a cooldown used
  shortly before a death, is a real, checkable correlation worth naming. Most kills
  won't show one; say so plainly rather than reaching for a connection that isn't
  there.
- Compare this boss's `BMSpells` against the character's own `SpellRows` — is the
  gap consistent with what you've seen on other bosses in this same run, or is it
  boss-specific (e.g. a boss whose own Top 100 average leans toward a different
  spell than every other boss does)? Say which.
- Look at `GearDiff.DifferingSlots` — if a slot varies only on this boss, that's
  worth a real, specific note (a weapon swap, a missing enchant that only shows up
  here). Don't just report "consistent" if it isn't.

### 7. Update existing pages
- **`docs\<healer>\index.html`** (healer's raid-night list): add a new
  `<a class="raid-row">` entry for this raid night if the report code isn't already
  listed there. If this file doesn't exist yet (brand-new healer), create it
  following the pattern in an existing one (e.g. `docs\danceswtrees\index.html`).
- **`docs\index.html`** (site homepage): only touched for a genuinely new healer —
  add one `<a class="healer-row">` entry, following the existing pattern. An
  existing healer's new raid night does **not** need a change here; v1/v2 and
  raid-night listing both live inside the healer's own hub page.

## Rules that came from real bugs — apply these while authoring pages

- **Guid-based grouping only, never by display name.** Two guids can share a
  display name and mean genuinely different things (e.g. Lifebloom's HoT-tick vs.
  bloom-burst) — `build_boss_report_data.ps1`'s `SpellRows`/`CooldownRows` are
  already guid-grouped; don't re-merge by name when writing prose.
- **Union of both spell lists.** A benchmark-only spell (in `BMSpells` but not in
  the character's `SpellRows`) still gets a real row showing 0%, never omitted —
  that's the actual point of the comparison.
- **Tranquility's cooldown-table row is conditional** (Druid only — Shaman has no
  equivalent concept, see below), not always-shown and not always-omitted: only
  include it when the character's usage is a real deviation from `Top100UsedPct` —
  cast it when ≤20% of the sample does, or didn't cast it when ≥50% of the sample
  did. Anything else (including the common case where nobody in the sample casts
  it at all) — omit the row.
- **Rebirth only gets a row if it's actually relevant to this kill** (a real death
  it could plausibly answer) — don't pad every page with a permanent 0 row. This
  concept doesn't exist for Shaman or Priest at all — confirmed no battle-rez
  equivalent in this TBC ruleset for either class (see `pull_top100_shaman.ps1`'s
  and `pull_top100_priest_holy.ps1`'s headers) — so Shaman and Priest pages never
  have this row, not even a permanent 0.
- **No letter grades, ever** — percentile numbers only.
- **No gendered pronouns anywhere in generated prose** — use the character's name
  or restructure the sentence.
- **Never fabricate or estimate a number that wasn't actually computed by
  `build_boss_report_data.ps1` or pulled by the earlier scripts.** If something's
  missing (the script's Warning output will say so), say so explicitly in the page
  rather than guessing or silently omitting.
- **`.check-note` (in the raid overview's gear-audit check-list) is a short data
  tag only** — an item id, an enchant id, a number — never a sentence. It's a
  narrow, right-aligned, small monospace column; real prose there wraps badly. Use
  `.check-detail` (full-width, left-aligned, normal wrapping — see
  `templates\raid_overview_template.html`'s CSS) for a check-item that genuinely
  needs more explanation than its one-line label.
- **Coverage-notes state a real finding, or say plainly there isn't one** — never
  pad with restated numbers already visible in the stat grid above them.

## Verification before calling this done

- Spot-check 2-3 of the numbers actually written into each generated page against
  the raw `<code>_report_data.json` — a copy/transcription mistake here is exactly
  the kind of thing that's easy to make and easy to catch.
- Confirm no `-v1` folder was touched (`git status` should show only new files
  under the plain `\<date>\` folder, plus the two index pages from step 7 if they
  changed).
- Confirm the raid-night count in `docs\<healer>\index.html` matches the number of
  real boss pages actually built.
