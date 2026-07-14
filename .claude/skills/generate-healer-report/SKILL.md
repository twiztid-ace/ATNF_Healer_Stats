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

Step 2 resolves the character's class. **Druid, Shaman, Priest (Holy), and
Paladin (Holy) are all on the real v2 pipeline today**
(`pull_top100_druid.ps1`/`pull_top100_shaman.ps1`/`pull_top100_priest_holy.ps1`/
`pull_top100_paladin.ps1`,
`boss_page_template_druid.html`/`boss_page_template_shaman.html`/
`boss_page_template_priest.html`/`boss_page_template_paladin.html`, and the
cooldown-guid tables in `build_boss_report_data.ps1` cover all four — Priest
added 2026-07-13, Paladin added the same day right after, both ported the same
way Shaman was: real-data discovery pass against a real report (Lippies for
Priest, Crowns for Paladin) before writing any guid table, see
`pull_top100_priest_holy.ps1`'s and `pull_top100_paladin.ps1`'s headers). Every
Fresh SSC/TK healer class is now on the v2 pipeline.

**If the resolved class isn't Druid, Shaman, Priest, or Paladin: stop and tell
the user clearly** — name the class, say it isn't on the v2 pipeline yet, and
don't proceed past step 2. Don't attempt a "best effort" fallback (e.g. quietly
reusing another class's cooldown list or template for an unsupported class) —
that would produce a report with fabricated-looking numbers for abilities that
class doesn't even have.

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
powershell -ExecutionPolicy Bypass -File scripts\pull_top100_paladin.ps1
```
Dispatch to whichever script matches the resolved class from step 2 (Druid,
Shaman, Priest, or Paladin today — see the gate above). This is diff-based
against `manifest.json` — it only makes real API calls for parses that are
genuinely new or have re-entered the Top 100 since the last run, so running it
here is cheap even if it was run recently.

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
files already on disk — steps 6-9 should never need to touch the network.

### 6. Compute analysis flags (script, no LLM)
```
powershell -ExecutionPolicy Bypass -File scripts\build_boss_analysis.ps1 -CharacterName "<name>" -ReportCode "<code>" -ClassName "<Class>"
```
Writes `<code>_analysis.json` next to `report_data.json` — pre-computes every
script-safe numeric judgment call so step 7 is verification and wording, not
arithmetic: per-boss HPS/overheal/HPM/active-time deviation flags vs. the Top 100
`BM` row, spell-composition gaps, per-cooldown `Deviates` flags (cast it while
≤20% of the sample does, or didn't cast it while ≥50% did — this generalizes the
Tranquility rule below to every tracked cooldown for every class),
`TranquilityInclude` (Druid only, `null` otherwise), `RebirthCandidates` (raw
death/cast facts only, no include/omit decision — Druid only), `SelfDeaths`,
nearest-cooldown-to-each-death lookups, canned-caveat tags (see below), and a
gear analysis (missing-enchant flags, differing-slot annotations) built from the
same 19-slot/enchantable-slot tables `scripts\lib\ReportRenderLib.psm1` uses
everywhere else in this pipeline. Zero API calls, zero judgment calls of its own.

### 7. Author findings.json (the only step touching an LLM)
Read `<code>_report_data.json` **and** `<code>_analysis.json`. Write
`data\Characters\<name>\<date>\<code>_findings.json` containing only the
free-text strings the analysis script can't produce on its own — per boss slug,
`SCORECARD_FINDING`, `SPELL_COMPOSITION_FINDING`, `COOLDOWN_FINDING`, and
`TARGET_FINDING` (each 1-2 plain-text sentences, no markup), plus a
`RaidOverview` object with `GEAR_CONSISTENCY_FINDING`, `GEAR_FINDING_NOTE`,
`RAID_SUMMARY_FINDING`, an optional `RAID_WARNING_BANNER` (may contain `<strong>`
tags — this is the one field the renderer doesn't escape), and an optional
`GearCheckItems[]` array of `{Icon: "ok"|"bad"|"note", Description, Detail,
LongDetail?}` for **interpretive** gear notes only (a deliberate weapon/trinket
swap, a positive "all consumables active every kill" confirmation) — never
duplicate the mechanical slot-fill-count or missing-enchant rows the renderer
already generates from `GearAnalysis` on its own. Druid pages may also need
`IncludeRebirthRow: true` on a boss slug (omit or `false` otherwise) — this is
the one include/omit call `analysis.json` deliberately leaves to judgment, since
no numeric threshold exists for "a real death Rebirth could plausibly answer."

The analysis file's `Flag`/`GapPoints`/`Deviates` fields tell you *where* to look
and *whether* something is a real deviation; you still decide what's worth
saying and how to phrase it. Concretely, before writing each boss's findings:
- Use `Deviations.*.Flag` and the real Top 1/avg/median numbers to state the
  real gap, not just repeat the numbers already visible in the stat grid.
- Use `DeathsNearestCooldown` to judge whether a death-to-cooldown timing is a
  real, checkable correlation or coincidence — most kills won't show one; say so
  plainly rather than reaching for a connection that isn't there.
- Use `SpellGaps`/`TopSpellGap` to say whether this boss's composition gap is
  consistent with the rest of the run or boss-specific, and why.
- Use `GearAnalysis.DifferingSlotsAnnotated` to write a real, specific note for
  any slot that varies only on this boss — don't just say "consistent" if the
  mechanical checklist already shows otherwise.
- **`CannedCaveats`** flags two fixed, already-documented facts — write the
  actual sentence yourself (the analysis file only tells you *when* it applies):
  `priest_pws_benchmark_bias` (Power Word: Shield's ~0% Top100UsedPct is a real
  ranking-metric bias, not a norm — don't read a Priest's own Shield usage as
  "overusing" it relative to this benchmark) and `paladin_holy_shock_guid_split`
  (Holy Shock's cast is guid 33072, its heal lands under a *different* real guid,
  33074 — don't claim Holy Shock "doesn't heal" for a Paladin).

**Validate before moving on**: every boss slug in `report_data.json.Bosses` has
all 4 required keys non-empty in `BossFindings`, and `RaidOverview` has its 3
required keys (`GEAR_CONSISTENCY_FINDING`, `GEAR_FINDING_NOTE`,
`RAID_SUMMARY_FINDING`) non-empty. `render_healer_report.ps1` in the next step
also checks this and refuses to write a page on any gap — don't rely on it
catching a typo'd boss slug for you, though; check the slug names match
`report_data.json` exactly.

### 8. Render boss pages + raid overview (script, no LLM)
```
powershell -ExecutionPolicy Bypass -File scripts\render_healer_report.ps1 -CharacterName "<name>" -ReportCode "<code>" -ClassName "<Class>" -RaidTitle "<title>"
```
Merges `report_data.json` + `analysis.json` + `findings.json` + the class's boss
template + `raid_overview_template.html` into
`docs\<healer>\<date>\healer_audit_<bossSlug>.html` (one per boss) and
`docs\<healer>\<date>\index.html` — deterministic, safe to re-run any time
benchmark data shifts (new Top 100 parses, re-entries) since it always rebuilds
from the current JSON. **Refuses to write into any `\<date>-v1\`-suffixed output
folder** — that guard is enforced in code, not just documented here. If it exits
with an "unfilled `{{TOKEN}}`" error, that means a required findings.json key is
missing or misspelled — fix `findings.json`, don't patch the rendered HTML by hand.

### 9. Update hub pages (script, no LLM)
```
powershell -ExecutionPolicy Bypass -File scripts\update_hub_pages.ps1 -CharacterName "<name>" -RaidDate "<date>" -ReportCode "<code>" -ClassName "<Class>" -BossesKilled <N> -RaidTitle "<title>" [-IsNewHealer]
```
Surgical upsert only — inserts one new raid-row into `docs\<healer>\index.html`
(creating the file from `healer_raidlist_template.html` if this is a brand-new
healer) and, only with `-IsNewHealer`, one new healer-row into `docs\index.html`.
Every existing row in both files is left byte-for-byte untouched; re-running it
for a report code that's already listed is a safe no-op (it detects the
duplicate and skips). `-BossesKilled` is the boss count actually killed this
raid night (e.g. `9` for a raid that downed 9 of 10 bosses) — don't hardcode 10.

## Rules that came from real bugs

Most of these are now enforced mechanically (in `build_boss_analysis.ps1`,
`scripts\lib\ReportRenderLib.psm1`, or `render_healer_report.ps1`) rather than
needing to be remembered while writing prose — noted below so you know where to
look if a rendered page looks wrong, rather than re-deriving the fix by hand.

- **Guid-based grouping only, never by display name** — enforced by
  `build_boss_report_data.ps1`'s already-guid-grouped `SpellRows`/`CooldownRows`
  and by the renderer's own spell-name collision logic (a `(guid N)` suffix is
  only added when a display name is genuinely ambiguous). Two guids can share a
  display name and mean genuinely different things (e.g. Lifebloom's HoT-tick vs.
  bloom-burst) — never re-merge by name when writing findings.json prose.
- **Union of both spell lists** — the renderer always includes a benchmark-only
  spell (in `BMSpells` but not the character's `SpellRows`) as a real 0% row,
  never omitted. Nothing to do here except reference the real gap in prose.
- **Tranquility's row is conditional** (Druid only) — `analysis.json`'s
  `TranquilityInclude` already applies the exact rule (cast it while ≤20% of the
  sample does, or didn't cast it while ≥50% did) and the renderer honors it
  automatically; you never decide this by hand anymore.
- **Rebirth only gets a row if it's actually relevant to this kill** — this is
  the one row the renderer can't decide on its own (no numeric threshold exists
  for "a real death it could plausibly answer"). Set `IncludeRebirthRow: true`
  in `findings.json` for a boss slug when `analysis.json`'s `RebirthCandidates`
  shows a real, plausible case; omit it (or `false`) otherwise. This concept
  doesn't exist for Shaman, Priest, or Paladin at all (no battle-rez equivalent
  in this TBC ruleset's in-combat cast data — Paladin's Redemption exists but
  can't target an in-combat ally) — the renderer already skips this row entirely
  for those three classes regardless of what `findings.json` says.
- **No letter grades, ever** — percentile numbers only. Nothing in the template
  or renderer produces a letter grade, so this only matters for findings.json prose.
- **No gendered pronouns anywhere in generated prose** — use the character's name
  or restructure the sentence. This only applies to what you write in
  `findings.json`; nothing else in the pipeline generates free text.
- **Never fabricate or estimate a number** — every number on a rendered page now
  comes mechanically from `report_data.json`/`analysis.json`/the benchmark CSVs,
  so this mostly matters for the findings.json prose itself: don't state a number
  you haven't verified against those files. If something's genuinely missing, the
  script's own Warning output already says so — reflect that plainly rather than
  guessing.
- **`.check-note` is a short data tag only** — the mechanical gear-checklist items
  the renderer generates already follow this; if you add an interpretive
  `GearCheckItems` entry, keep its `Detail` field just as short (an item id, a
  number) and put any real explanation in `LongDetail` instead.
- **Findings state a real finding, or say plainly there isn't one** — never pad
  with restated numbers already visible in the stat grid above them.

## Verification before calling this done

- `render_healer_report.ps1` already refuses to write a page with an unfilled
  `{{TOKEN}}` or a `-v1`-suffixed output folder — a clean run is a real signal,
  not just an absence of errors.
- Spot-check 2-3 numbers on one rendered page against the raw
  `<code>_report_data.json`/`<code>_analysis.json` — a copy/transcription mistake
  in `findings.json`'s prose (a stated number that doesn't match the real data)
  is the one class of error the scripts can't catch for you.
- Confirm no `-v1` folder was touched (`git status` should show only new files
  under the plain `\<date>\` folder, plus the two hub pages from step 9 if they
  changed).
- Confirm the raid-night count in `docs\<healer>\index.html` (bumped
  automatically by step 9) matches the number of real boss pages actually built.
