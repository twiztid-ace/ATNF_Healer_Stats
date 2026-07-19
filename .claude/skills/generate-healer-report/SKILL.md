---
name: generate-healer-report
description: Generates a complete v2 healer report (per-boss audit pages + raid overview, real data only) for a given character name and Warcraft Logs report code. Pulls the character's raid data, refreshes that class's Top 100 benchmark, re-summarizes it, computes real per-boss stats, and builds/updates every affected docs/ page. Also supports a report-code-only invocation that runs this for every healer already tracked in data/site_index.json who appears in that report. Use when the user asks to build, generate, regenerate, or update a healer's report for a specific raid log, or to pull/refresh a whole raid log for everyone already tracked.
user-invocable: true
disable-model-invocation: true
tools: PowerShell, Read, Write, Edit, Glob, Grep
argument-hint: <CharacterName> <ReportCode-or-URL> | <ReportCode-or-URL>
---

# Generate a healer report

Invoked one of two ways:

- `/generate-healer-report <CharacterName> <ReportCode-or-URL>`, e.g.
  `/generate-healer-report Danceswtrees XJp8vAxzM4KtHYyb` — the single-healer flow,
  documented below in "Pipeline".
- `/generate-healer-report <ReportCode-or-URL>` (one argument only), e.g.
  `/generate-healer-report XJp8vAxzM4KtHYyb` — runs the same pipeline for **every
  healer already tracked in `data\site_index.json`** who actually appears in that
  report. See "Running for every already-tracked healer" below instead of the
  single-healer "Pipeline" section.

If `$ARGUMENTS` has two tokens, treat the first as the character name and the
second as the report code/URL. If it has exactly one token, treat it as the
report code/URL and use the batch flow. If it's ambiguous some other way (more
than two tokens, or a first token that isn't a plausible character name and
isn't a report code either), ask the user rather than guessing.

Turns `CharacterName` + `ReportCode` (or a full WCL report URL) into a complete,
real v2 report: one audit page per boss kill, a raid overview (gear audit + per-boss
summary), and every existing page that needs a new entry for it.

Run this from the repo root (`C:\Users\raymo\wc_logs`) — every script here assumes
that working directory, same as the rest of this pipeline.

**Read `CLAUDE.md` first if this is a fresh session with no other context on
this project** — this skill assumes familiarity with the active/archived data
model, the events-vs-tables history, and the v1/v2 split. This file is the
runbook for *this specific task*, not a replacement for that.

## Before starting: confirm the class AND spec are supported

Step 2 resolves the character's class (and, since 2026-07-16, spec — see
below). **Druid-Restoration, Shaman-Restoration, Priest-Holy, Paladin-Holy,
and Druid-Dreamstate are all on the pipeline today** — `pipeline\classes.py`
is the single source of truth for all five (WCL classID/specID, cooldown-guid
table, boss-page template, target-mode map), replacing what used to be five
separate `pull_top100_{class}.ps1` scripts' own hardcoded headers plus a
matching entry in `build_boss_report_data.ps1`. Priest added 2026-07-13,
Paladin added the same day right after, both ported the same way Shaman was;
Dreamstate added 2026-07-16 with one real wrinkle: it's a SPEC of the
already-tracked Druid class (WCL classID 2 / specID 6), not a new class of
its own — `--class-name "Dreamstate"` is still the correct pipeline value
end-to-end (own `data\Classes\Dreamstate\` folder/manifest, own cooldown
table), it just maps to the real WCL `className: "Druid", specName:
"Dreamstate"` internally (see `pipeline\classes.py`'s `ClassConfig` for the
full split — the original PowerShell discovery-writeup scripts this used to
point to, `scripts\pull_top100_*.ps1`, were deleted 2026-07-19 along with the
rest of the retired PowerShell implementation; git history still has them).
Real-data discovery pass against a real report before writing any guid table
for every one of these (Lippies for Priest, Crowns for Paladin, Turkeykin for
Dreamstate).

**If the resolved class/spec combination isn't one of the five above: stop and
tell the user clearly** — name the class and spec, say it isn't on the v2
pipeline yet, and don't proceed past step 2. Don't attempt a "best effort"
fallback (e.g. quietly reusing another class's cooldown list or template for
an unsupported class/spec, or assuming a Druid pulled here is Restoration just
because that's the only Druid build this pipeline used to track) — that would
produce a report with fabricated-looking numbers for abilities that build
doesn't even have.

**A character can play more than one spec across a single report's boss
kills** — confirmed real, not hypothetical (Turkeykin plays Balance DPS on 6
SSC bosses and Dreamstate healer on 4 TK bosses in the same real report,
`XJp8vAxzM4KtHYyb`). Step 2 below now resolves spec per real boss kill, not
once globally — if fights disagree, it asks for an explicit `--spec` and pulls
only the fights where the character was actually in that spec, never blending
a DPS off-spec fight into a healer report.

## Pipeline

### 1. Resolve inputs
Accept a character name and a report code or full WCL URL. If given a URL, extract
the code the same way `pipeline\pull_character.py` does:
`warcraftlogs\.com/reports/([A-Za-z0-9]+)`.

### 2. Pull character data
```
python -m pipeline.cli pull-character --report-code "<code>" --character-name "<name>"
```
This resolves class from the report's own `actors[]`, derives the raid date
from the report title, resolves real per-fight SPEC from the report's own
rankings data (added 2026-07-16 — see "Before starting" above), and pulls
healing/casts/consumables/gear/activetime/deaths per boss kill (only for
fights matching the resolved spec) plus the character's full parse history.
Read its output carefully:
- If it reports `0 boss kill(s) found` or the character wasn't found in
  `actors[]`, **stop here** — don't proceed to build pages from nothing. Tell
  the user what went wrong (wrong report code, character not in this report, etc.).
- **If it hard-stops with "plays more than one real spec across this report's
  boss kills"**, it will print the real per-fight breakdown (which spec on
  which boss). Re-run with `--spec "<the healing spec>"` added — don't guess
  which one to pick, ask the user if it's not obvious from the breakdown
  (e.g. which spec has the `healers` role vs. `dps`/`tanks`).
- The command prints `Resolved pipeline class: <Class> (WCL: <realClass>/<realSpec>)`
  at the end — this is the already-resolved pipeline class key to use for
  `--class-name` in steps 3-9 below, computed automatically from the real
  (WCL className, WCL specName) pair via `pipeline/classes.py` (e.g. real
  Druid/Dreamstate → pipeline key `"Dreamstate"`, never `"Druid"` for a
  Dreamstate healer — see that module for the full class/build table). You
  no longer need to infer this by hand from the class/spec-support gate
  above; just read it off this line.
- Note the resolved raid date (used only for display text later — the actual
  `data\Characters\{name}\{code}\` and `docs\{healer}\{code}\` folders are keyed
  by report code, not date, since two raids can happen on the same calendar day).

### 3. Update the matching class's Top 100 benchmark data
```
python -m pipeline.cli pull-top100 --class-name "<Class>"
```
One consolidated engine dispatched by `--class-name` (Druid, Shaman, Priest,
Paladin, or Dreamstate — using the resolved pipeline class from step 2's own
output line). This is diff-based against `manifest.json` — it only makes
real API calls for parses that are genuinely new or have re-entered the Top
100 since the last run, so running it here is cheap even if it was run
recently.

### 4. Run the summarization
```
python -m pipeline.cli summarize-benchmarks --class-name "<Class>"
```
Regenerates all four `data\Classes\<Class>\active\benchmark_*.csv` files from the
now-current Top 100 data. Always run this after step 3, even if step 3 found no new
parses — cheap, local, no API calls.

### 5. Compute report data
```
python -m pipeline.cli build-report-data --character-name "<name>" --report-code "<code>" --class-name "<Class>"
```
Writes `data\Characters\<name>\<code>\<code>_report_data.json` — one clean JSON with
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
python -m pipeline.cli build-analysis --character-name "<name>" --report-code "<code>" --class-name "<Class>"
```
Writes `<code>_analysis.json` next to `report_data.json` — pre-computes every
script-safe numeric judgment call so step 7 is verification and wording, not
arithmetic: per-boss HPS/overheal/HPM/active-time deviation flags vs. the Top 100
`BM` row, spell-composition gaps, per-cooldown `Deviates` flags (cast it while
≤20% of the sample does, or didn't cast it while ≥50% did — this generalizes the
Tranquility rule below to every tracked cooldown for every class),
`TranquilityInclude` (Druid-Restoration only, `null` otherwise —
Druid-Dreamstate has NOT been confirmed to have this ability, checked against
real data, so it's excluded here too), `RebirthCandidates` (raw death/cast
facts only, no include/omit decision — Druid-Restoration AND Druid-Dreamstate
both, since Dreamstate keeps Rebirth in its own cooldown table), `SelfDeaths`,
nearest-cooldown-to-each-death lookups, canned-caveat tags (see below), and a
gear analysis (missing-enchant flags, differing-slot annotations) built from the
same 19-slot/enchantable-slot tables `pipeline\render_lib.py` uses
everywhere else in this pipeline. Zero API calls, zero judgment calls of its own.

### 7. Author findings.json (the only step touching an LLM)
Read `<code>_report_data.json` **and** `<code>_analysis.json`. Write
`data\Characters\<name>\<code>\<code>_findings.json` containing only the
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
already generates from `GearAnalysis` on its own. Druid-Restoration AND
Druid-Dreamstate pages may also need `IncludeRebirthRow: true` on a boss slug
(omit or `false` otherwise) — this is the one include/omit call `analysis.json`
deliberately leaves to judgment, since no numeric threshold exists for "a real
death Rebirth could plausibly answer."

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
`RAID_SUMMARY_FINDING`) non-empty. `pipeline\render_report.py` in the next step
also checks this and refuses to write a page on any gap — don't rely on it
catching a typo'd boss slug for you, though; check the slug names match
`report_data.json` exactly.

### 8. Render boss pages + raid overview (script, no LLM)
```
python -m pipeline.cli render --character-name "<name>" --report-code "<code>" --class-name "<Class>" --raid-title "<title>"
```
Merges `report_data.json` + `analysis.json` + `findings.json` + the class's
Jinja2 boss template + `raid_overview.html.jinja` into
`docs\<healer>\<code>\healer_audit_<bossSlug>.html` (one per boss) and
`docs\<healer>\<code>\index.html` — the output folder always mirrors whatever
`data\Characters\<name>\` folder the input JSON was found in (a report code for
anything pulled after the ReportCode-keyed folder change, or a legacy
`yyyy-MM-dd` date for anything pulled before it), so this needs no `-date`
parameter of its own. Deterministic, safe to re-run any time benchmark data
shifts (new Top 100 parses, re-entries) since it always rebuilds from the
current JSON. **Refuses to write into any `-v1`-suffixed output folder** — that
guard is enforced in code, not just documented here. If it exits with an
"unfilled `{{TOKEN}}`" error, that means a required findings.json key is
missing or misspelled — fix `findings.json`, don't patch the rendered HTML by hand.

### 9. Update hub pages (script, no LLM)
```
python -m pipeline.cli update-hub --character-name "<name>" --raid-date "<date>" --report-code "<code>" --class-name "<Class>" --bosses-killed <N> --raid-title "<title>"
```
`--raid-date` is display text only (shown next to the raid title on the hub
page) — the inserted row's link always points at `<code>/index.html`, matching
step 8's report-code-named output folder exactly. This upserts the healer's
`data\Characters\<name>\index.json` (creating it if this is a brand-new healer)
and fully re-renders both `docs\<healer>\index.html` and, when this healer
isn't already registered, `docs\index.html` too — new-healer registration is
now automatic (no separate `-IsNewHealer` flag to remember) based on whether
the healer already appears in `data\site_index.json`. Every existing raid
night is preserved; re-running it for a report code that's already listed is
a safe no-op update rather than a duplicate insert. `--bosses-killed` is the
boss count actually killed this raid night (e.g. `9` for a raid that downed 9
of 10 bosses) — don't hardcode 10, though note the command prefers the real
count from `report_data.json` over whatever's passed here if that file exists.

**The healer's raid-list is always re-sorted by real raid date, descending,
after the insert** — never just appended to the top. Report-code-keyed
folders mean generation order no longer tracks raid-chronology order (a
backfilled older raid generated after a newer one is real, not hypothetical),
so relying on insertion order would silently produce a wrong-order list. If
you ever need to re-sort an existing healer's list without inserting anything
(e.g. after a manual edit), run the same command with just
`--character-name` and `--resort-only` — this is now just a full re-render
from the existing `index.json`, not a separate code path, so it can't drift
out of sync with the insert logic the way the old HTML-scrape approach could.

## Running for every already-tracked healer

Invoked as `/generate-healer-report <ReportCode-or-URL>` (one argument only).
Use when a raid log is shared by more than one already-tracked healer (a real,
confirmed scenario — see `CLAUDE.md`'s writeup of report `LKbVcNfRxyBkj2mg`,
pulled and rendered for both Danceswtrees and Vajomee the same day) and the
user wants the whole log processed in one pass instead of one
`/generate-healer-report <name> <code>` invocation per healer.

"Already-tracked" means every `character_name` in `data\site_index.json` —
**not** every folder under `data\Characters\`. A healer *can* have real
pulled data on disk while being deliberately excluded from `site_index.json`
(registration happens automatically on first render — see
`pipeline\hub_pages.py` — so this only happens if an entry is later removed
by hand). As of 2026-07-18, no healer is currently hidden this way —
`docs\index.html` links all 10 tracked healers, including Turkeykin. An
earlier version of this file (and of `CLAUDE.md`) claimed Turkeykin was kept
off the homepage on purpose; that claim is stale — see `CLAUDE.md`'s "Current
state" section. Still don't add `--character-names` to sweep in a healer who
isn't in `site_index.json` without checking with the user first — same
reasoning as not registering a new healer without checking, this command just
has a wider blast radius now that one invocation can touch several healers at
once.

### 1. Resolve the report code
Same as single-healer step 1 — extract the code from a full WCL URL if given
one.

### 2. First pass — pull + compute, stop before findings
```
python -m pipeline.cli generate-all --report-code "<code>"
```
This loops the single-healer pipeline's steps 2-6 (pull character data,
refresh + re-summarize the resolved class's Top 100 benchmark once per
distinct class, compute `report_data.json` + `analysis.json`) across every
healer in `site_index.json`, and prints a per-healer summary line at the end:
`done`, `skipped`, `needs-findings`, or `error`. Read it carefully:

- `skipped` with "was not found in this report's actors" or "plays more than
  one real spec" — expected and fine; that healer genuinely isn't a real hit
  in this report, or needs a `--spec` this batch command can't guess (re-run
  `pull-character` for that one name by hand with `--spec`, then re-run this
  same `generate-all` command — it reuses the cached pull).
- `skipped` with "unsupported class/spec" or "0 boss kills" — also expected
  and fine; nothing to do for that healer.
- `error` — the command already stopped the whole batch here rather than
  repeating the same failure for every remaining name (see its own output for
  why — almost always a bad or private report code). Fix that and re-run
  before doing anything else.
- `needs-findings` — this is the real output of this pass: one or more
  healers with real `report_data.json`/`analysis.json` on disk, ready for
  step 3 below. Note every `<code>_findings.json` path it printed.

### 3. Author a real findings.json for every healer that needs one
For each `needs-findings` healer from step 2, follow single-healer step 7
exactly — read that healer's own `<code>_report_data.json` **and**
`<code>_analysis.json`, write their own `<code>_findings.json` — using the
same schema, the same `CannedCaveats`/`RebirthCandidates`/etc. rules, and the
same validation ("every boss slug has all 4 required keys, `RaidOverview` has
its 3 required keys") described there. **Each healer's findings are their
own** — never reuse or copy prose across healers just because they share a
report code; the same kill can look very different from a Druid's cooldown
kit than from a Shaman's, and a coverage note is specific to the person it's
about.

### 4. Second pass — render + update hub for everyone now ready
```
python -m pipeline.cli generate-all --report-code "<code>"
```
The exact same command as step 2, run again. Any healer whose
`<code>_findings.json` now exists (written in step 3) proceeds straight to
render + hub-update this time — `generate-all` always checks for an existing
findings.json before deciding whether a healer still `needs-findings`, so
there's no separate "render-only" flag to remember. Healers who were
`skipped` in step 2 stay skipped (the underlying reason hasn't changed); this
is expected, not a bug.

## Rules that came from real bugs

Most of these are now enforced mechanically (in `pipeline\build_analysis.py`,
`pipeline\render_lib.py`, or `pipeline\render_report.py`) rather than
needing to be remembered while writing prose — noted below so you know where to
look if a rendered page looks wrong, rather than re-deriving the fix by hand.

- **Guid-based grouping only, never by display name** — enforced by
  `pipeline\build_report_data.py`'s already-guid-grouped `SpellRows`/`CooldownRows`
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
  **Druid-Dreamstate is the one non-"Druid"-named class that DOES keep this
  concept** (real guid 26994, same as Druid-Restoration's) — don't lump it in
  with Shaman/Priest/Paladin's "no such concept" treatment; `pipeline\build_analysis.py`
  computes real `RebirthCandidates` for Dreamstate too (fixed 2026-07-16 — this
  used to be gated on a single `$ClassName -eq "Druid"` check covering both
  Tranquility and Rebirth together, which would have silently left Dreamstate's
  `RebirthCandidates` permanently `$null`).
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

- `pipeline\render_report.py` already refuses to write a page with an unfilled
  `{{TOKEN}}` or a `-v1`-suffixed output folder — a clean run is a real signal,
  not just an absence of errors.
- Spot-check 2-3 numbers on one rendered page against the raw
  `<code>_report_data.json`/`<code>_analysis.json` — a copy/transcription mistake
  in `findings.json`'s prose (a stated number that doesn't match the real data)
  is the one class of error the scripts can't catch for you.
- Confirm no `-v1` folder was touched (`git status` should show only new files
  under the plain `\<code>\` folder, plus the two hub pages from step 9 if they
  changed).
- Confirm the raid-night count in `docs\<healer>\index.html` (bumped
  automatically by step 9) matches the number of real boss pages actually built.
- **For a batch run**: re-check the step 2/4 per-healer summary lines rather
  than assuming "no error" means "everyone got a page" — a healer can land on
  `skipped` legitimately (not in this report, unsupported class, 0 boss
  kills) and that's a correctly-finished run, not a partial failure. Confirm
  every healer you expected a real page for actually landed on `done`, not
  still sitting on `needs-findings` because step 3 was skipped for them.
