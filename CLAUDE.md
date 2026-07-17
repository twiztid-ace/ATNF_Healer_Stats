# ATNF Healer Analysis — Claude Code orientation

This is a WoW Classic (TBC/SSC-TK era) raid healer analysis pipeline: pull real combat
log data from Warcraft Logs, benchmark it against Top 100 parses, and generate
a static HTML site auditing each healer's performance per boss kill. All five Fresh
SSC/TK healer builds' pipelines (`pull_character_TEMPLATE.ps1` — shared/class-agnostic —,
`pull_top100_druid.ps1`, `pull_top100_shaman.ps1`, `pull_top100_priest_holy.ps1`,
`pull_top100_paladin.ps1`, `pull_top100_dreamstate.ps1`) now pull that data via WCL's
**v2 GraphQL API** (Druid migrated 2026-07-12, Shaman ported the same day as its own
"Phase 3" pilot, Priest ported 2026-07-13, Paladin ported the same day right after
Priest, Dreamstate ported 2026-07-16 — see WORKFLOW.md's "v2 GraphQL API" section).
No build remains on the original v1 REST API.

**Dreamstate is a SPEC of Druid, not a sixth class** — worth flagging immediately
since it's easy to misread "five" above as "five classes." This project tracks four
real WCL *classes* (Druid, Shaman, Priest, Paladin) and five real tracked *builds*
(Druid-Restoration, Shaman-Restoration, Priest-Holy, Paladin-Holy, Druid-Dreamstate)
— Dreamstate is a second, distinct spec under the same Druid class, a genuinely new
axis this project hadn't needed before (see "Current state" below for the real,
non-hypothetical case — a healer who plays a DIFFERENT spec on part of a raid —
that drove this).

**Read `WORKFLOW.md` first, in full, before touching anything.** It is the single
source of truth for this project — API endpoints, file formats, known bugs, and 33
numbered "gotchas" documenting real mistakes already made and fixed. Assume anything
not in WORKFLOW.md is unverified. This file is just a map to get you oriented quickly;
WORKFLOW.md has the actual depth. **`README.md`** (repo root) is the practical
day-to-day companion to this file — setup steps and the exact command sequence for
running the pipeline, including entirely without Claude (see "Local-scripting
pipeline" below); read it when you actually need to run something, not just to
get oriented.

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
**enhanced v2** (Druid and Shaman as of 2026-07-12, Priest and Paladin as of
2026-07-13 — every class this project tracks is now on the v2 methodology).
Reading the repo cold, both look like "real output" — they're not at the same
maturity, and mixing them up is the main way to get confused here.

**Naming collision to watch for:** this "v1/v2" is about *methodology* (simple
gear-check vs. events-based enhanced pipeline) — a completely different axis from
the WCL "v1 REST API / v2 GraphQL API" distinction mentioned above. All four
classes are now on methodology-v2 AND API-v2 — the two axes never actually
diverged for any class ported so far (Shaman, Priest, and Paladin all went from
v1/v1 straight to v2/v2 in one pass, same as Druid's own history), so this
project still hasn't seen a *partial* port (e.g. API-only migration without the
events-based rewrite) that would actually split the two axes apart for one
class. Don't assume "v2" means the same thing in every sentence of this file or
WORKFLOW.md without checking which axis it's on.

**A third, independent axis exists now too: *authoring method*** — how the final
HTML for a methodology-v2 report actually gets produced, separate from both axes
above. Added 2026-07-14 (see "Local-scripting pipeline" below): Claude hand-writing
every page's HTML directly (how all 4 existing real v2 sites were built), vs.
`render_healer_report.ps1` mechanically rendering it from JSON + a small
Claude-authored `findings.json` (the new default going forward, see below). A page
being "v2" says nothing about which authoring method produced it — check whether
its raid folder has a `{code}_findings.json`/`{code}_analysis.json` next to its
`report_data.json` (script-rendered) or not (hand-written) if it matters.

- **v1 (simple)**: gear check + basic spell composition + a couple of other checks,
  built on the old `/report/tables/` healing view (5-entry truncation bug and all —
  see WORKFLOW.md gotcha #4/#15). This is what originally produced the 4
  fully-built healer sites, moved to `docs/` on 2026-07-12 (see "Hosting" below —
  they're no longer at the repo root). Treat these as a finished snapshot of the
  *old* methodology, not a template for new output. As of 2026-07-13 every one of
  the 4 healers also has a real v2 site for at least one raid night (see "Current
  state") — the v1 pages remain only as historical reference, moved aside to
  `-v1`/`_v1`-suffixed sibling folders rather than deleted where superseded.
  **Exception, 2026-07-16: Crowns's and Lippies's `-v1` folders were deleted**
  at explicit user instruction as part of a full from-scratch site rebuild —
  see "Current state" for the full story. This is a one-time deviation for
  those two healers specifically, not a change to the general rule above.
- **v2 (enhanced)**: events-based healing/casts (no truncation), cooldown/utility
  tracking with self-vs-other targets (Druid-Restoration: Innervate/Nature's
  Swiftness/Swiftmend/Rebirth/Dark Rune, real buff uptime via Tree of Life
  interval reconstruction; Shaman: Earth Shield/Mana Tide Totem/Ancestral
  Swiftness/Dark Rune; Priest: Shadowfiend/Power Word: Shield/Chakra/Blessing of
  Life/Fear Ward/Dark Rune; Paladin: Holy Shock/Divine Favor/Divine Shield/
  Cleanse/Hand of Protection/Blessing of Freedom/Dark Rune — no Rebirth-
  equivalent or self-buff-uptime concept exists for Shaman, Priest, OR Paladin in
  this TBC ruleset, confirmed against real data for all three, not assumed;
  Druid-Dreamstate, added 2026-07-16: Innervate/Rebirth/Dark Rune carried over
  from Druid-Restoration, plus a real Improved Faerie Fire uptime stat unique to
  this build — confirmed real absence of Nature's Swiftness/Swiftmend/
  Tranquility, not assumed just because it shares a base class with
  Restoration — see "Current state" below for the full discovery writeup), Top
  100 benchmarking, CSV summarization. **Resto Druid, Resto Shaman, Holy Priest,
  Holy Paladin, and Dreamstate Druid** all have this now (see "Current state"
  below). All four ORIGINAL v2 healer sites have been generated end-to-end
  (Danceswtrees/Druid, Vajomee/Shaman, Lippies/Priest, and Crowns/Paladin as of
  2026-07-13), plus a fifth, Turkeykin/Dreamstate, added 2026-07-16 — see
  "Current state" for why Turkeykin's site is deliberately NOT linked from the
  main site index yet. `examples/` has one older reference page but it's out of
  date (see below).

## Data model — active/archived + manifest.json (all five builds now)

Replaced the old "fresh date-stamped folder every pull" convention for Druid on
2026-07-12, because that convention re-fetched all ~1,000 Top 100 parses from the
WCL API on every single run even though the vast majority don't change between
runs and a completed log's data can never change once pulled. Shaman was built
directly on this model from day one when it was ported the same day, Priest the
same way again on 2026-07-13, Paladin the same way again right after Priest, and
Dreamstate the same way again on 2026-07-16 (no old date-folder data existed
worth migrating forward for any of the four — see WORKFLOW.md's "v2 GraphQL API"
section for why). Full design rationale, manifest schema, and the exact diff
algorithm are in WORKFLOW.md's "Active/archived data model" section — read that
before touching any pull script. The short version:
- `data\Classes\{Druid,Shaman,Priest,Paladin,Dreamstate}\manifest.json` tracks
  per-boss `lastPulledDate`/`rankingsSnapshotDate` and per-parse
  `active`/`archived` status. **`Dreamstate` is a pipeline-key folder name, not
  a real WCL class** — its real WCL identity is `className: "Druid", specName:
  "Dreamstate"`; keeping it in a folder separate from `data\Classes\Druid\`
  (Restoration) is deliberate, not an inconsistency — see WORKFLOW.md's
  Dreamstate writeup for the real-vs-pipeline class/spec split this required.
- `active\` holds only what's currently in a boss's Top 100. `archived\` holds
  everything that's ever dropped out, kept forever, never deleted.
- Staleness is always a plain `yyyy-MM-dd` date compared to today at read time —
  never a stored boolean (see WORKFLOW.md for why that matters).
- **No class remains on the old date-folder convention as of Paladin's port.**
  The old convention is documented in WORKFLOW.md purely as reference for a
  hypothetical future new class.

## `data\Characters\` and `docs\` folders — report code, not raid date (2026-07-14)

Separate from the `data\Classes\` model above: every per-character raid-night
folder (`data\Characters\{Name}\{X}\` and `docs\{healer}\{X}\`) is now keyed by
**WCL report code**, not raid date — e.g. `data\Characters\Crowns\XJp8vAxzM4KtHYyb\`,
`docs\crowns\XJp8vAxzM4KtHYyb\`. This replaced a real, confirmed bug: the old
`{yyyy-MM-dd}` folder keying meant two different raids pulled for the same
character on the same calendar date (a real, expected scenario — an afternoon
SSC clear and a separate night TK clear, say) would land in the *same* folder,
and the per-boss-kill files inside (`fight14_lurker_healing_events.json`, etc.)
carry no report code of their own — so the second pull would silently overwrite
or corrupt the first's files. The report date is still tracked and shown on every
page — just not as the folder name anymore. It lives as `report_data.json`'s own
`RaidDate` field (and `fights_{code}.json`'s `raidDate` field one level below
that) instead.

**Existing v1-preserved sibling folders are now `{code}-v1`, not `{date}-v1`.**
Several healers have an old v1-methodology site sitting alongside their v2 site
for the same raid night (see "Two generations" above) — e.g.
`docs\crowns\XJp8vAxzM4KtHYyb-v1\` next to `docs\crowns\XJp8vAxzM4KtHYyb\`, both
built from the exact same real report. `render_healer_report.ps1` refuses to
write into any output folder whose name ends in `-v1`, regardless of what
precedes the suffix.

**All 4 healers' existing real folders were renamed to this convention on
2026-07-14** (both `data\Characters\` and `docs\`, via `git mv` to preserve
history) — this was a one-time migration of already-published data, not just a
go-forward convention change, so **GitHub Pages URLs for every existing raid
night changed** (e.g. `docs/crowns/2026-07-07/` → `docs/crowns/XJp8vAxzM4KtHYyb/`)
— any external bookmark/link to an old date-based URL now 404s. Every healer's
hub page (`docs\{healer}\index.html`) raid-row link was updated to match; a
genuinely pre-existing broken link was also found and fixed in the process
(Lippies' raid overview referenced a `_v1` (underscore) folder that never
existed — the real folder was always `-v1` (hyphen); now points at the correct,
renamed `XJp8vAxzM4KtHYyb-v1`).

**A healer's raid-list must always read newest-first, and can no longer rely on
insertion order to guarantee that** (fixed the same day) — since folders are
report-code-keyed, the order raids get *generated* in no longer has any natural
relationship to the order they actually happened in (backfilling an older raid
after a newer one is real, not hypothetical). `update_hub_pages.ps1` now always
re-parses every existing row's own date text and rewrites the whole list stably
sorted by date descending on every insert, rather than just prepending — see
that script's own header comment, and its `-ResortOnly` mode (re-sorts an
existing healer's list without inserting anything, e.g. after a manual edit).

## Mid-raid spec switching — a character can play >1 real spec in one report (2026-07-16)

New, general, class-agnostic mechanism — not Dreamstate-specific, though
Dreamstate's own discovery pass is what surfaced the real case that required
it. `pull_character_TEMPLATE.ps1` used to resolve a character's class ONCE,
globally, from `masterData.actors[].subType` — which has no spec field at
all, and is one fixed value per report regardless of which fight you look at.
**Real, confirmed case, not hypothetical**: Turkeykin (report
`XJp8vAxzM4KtHYyb`, the same report already used for Crowns/Lippies) plays
Balance (a DPS spec) on all 6 real SSC bosses and Dreamstate (a healer spec)
on all 4 real TK bosses in that SAME report — a genuine mid-raid respec.

- The report's own `rankings(fightIDs:[...])` call (previously the LAST step,
  only for percentile display) now runs BEFORE the per-boss-kill dispatch,
  since its per-fight `roles.{tanks,healers,dps}.characters[]` entries are the
  only real source of per-fight spec (see WORKFLOW.md's "Per-fight spec
  resolution" writeup in the v2 GraphQL API section for the full mechanism).
- New optional `-Spec` parameter on `pull_character_TEMPLATE.ps1`. Every fight
  agreeing on one spec (true for every character pulled before Dreamstate) —
  zero behavior change, just a real confirmation instead of a global guess.
  Fights disagreeing and `-Spec` not supplied — hard-stops with the real
  per-fight breakdown rather than guessing which spec to analyze. `-Spec`
  supplied — only pulls fights matching that spec; the rest are logged as
  explicit `SKIP` lines, never silently treated as healer data.
- New `{code}_spec_coverage.json` (per-character, next to `report_data.json`)
  records every boss in the report with its own real resolved class/spec/role
  and whether it was included — lets `build_boss_report_data.ps1` reconstruct
  the full picture without re-querying the API.
- `build_boss_report_data.ps1` computes a `SpecCoverage` object for
  `report_data.json` from that file — `$null`/absent when every fight agreed
  (the common case, zero effect on Danceswtrees/Vajomee/Lippies/Crowns).  When
  present, it also narrows `BossesAttempted`/the boss-processing loop itself
  to only the spec-matching fights — NOT left to the graceful missing-file
  skip that already exists for other reasons.
- `render_healer_report.ps1` surfaces a real, fully mechanical (no LLM)
  sentence on the raid overview when `SpecCoverage` is present — new
  `SPEC_COVERAGE_NOTE` token, wrapped in `raid_overview_template.html`'s new
  `<!--@OPTIONAL:SPEC_COVERAGE_NOTE-->` block, omitted entirely (not an empty
  paragraph) for every healer without a real spec split.

## Local-scripting pipeline (2026-07-14) — replaces Claude hand-writing HTML

Generating a report used to mean Claude hand-writing ~550 lines of HTML per
boss page, 11 times per report (10 boss pages + 1 raid overview), re-emitting
near-identical CSS/structure every time — this is how all 4 existing real v2
sites (Danceswtrees, Vajomee, Lippies, Crowns) were actually built, and it burns
a lot of tokens for output that's almost entirely mechanical. Built to fix that:
a 3-stage pipeline where a script computes every real number and pre-flags
every script-safe judgment call, Claude authors only the handful of genuinely
interpretive sentences, and a second script deterministically renders the final
HTML. **No existing site was regenerated through this new pipeline at first**
— the original decision when this was built (2026-07-14) was to leave the 4
existing hand-written sites untouched and apply the new pipeline to future
report generations only. That held until 2026-07-16, when Crowns's and
Lippies's sites were deliberately deleted and rebuilt from scratch through
this pipeline for the same report code they already had — see "Recently
closed" below. Danceswtrees's and Vajomee's original hand-written pages
(`Fm9XdWYtz8VCLnwg`, `Z4zNt28raQ6GLbkC`) are still untouched by the pipeline.

- `scripts\build_boss_analysis.ps1` — reads `{code}_report_data.json`, writes
  `{code}_analysis.json` next to it: per-boss deviation flags vs. the Top 100
  benchmark, cooldown over/undercast flags, self-death detection,
  nearest-cooldown-to-death lookups, gear enchant gaps, canned-caveat tags
  (Priest PWS benchmark bias, Paladin Holy Shock guid split — see "Current
  state" below), and (added 2026-07-15) `SpellRanks` — mechanical, no-LLM
  detection of a spell name with 2+ distinct real guids in play this kill
  (character and/or Top 100), reusing `SpellGaps`' own union-matching. **WCL's
  v2 API has no "rank" field anywhere** (confirmed live via `__schema`
  introspection on `GameAbility`/`ReportAbility` — both only have
  id/icon/name/type) and `gameData.abilities` is a flat, unfiltered, 456,806-row
  pagination with no name/class filter, so pulling "all abilities" isn't a
  viable way to get rank data either. Real per-cast mana cost (this kill's own
  `classResources` data, captured per-guid in `build_boss_report_data.ps1` as
  `ManaCostByGuid`) is the only available signal for which rank is "higher" —
  known only for guids the character actually cast this kill, `null`
  (rendered `?`, never guessed) otherwise. Rendered as a new, always-mechanical
  "Spell ranks in play" block in section 02 of every boss template, wrapped in
  `<!--@OPTIONAL:SPELL_RANKS_SECTION-->` — a boss where no spell has 2+ ranks
  gets the whole block removed, not shown empty. Verified against Vajomee's
  real Vashj kill (Chain Heal: 5 real guids, 260-540 mana; Lesser Healing Wave:
  3 real guids) matching the exact numbers already found by hand earlier this
  session. Zero API calls, zero LLM involvement for any of this.
- `{code}_findings.json` — the ONE file an LLM authors: ~4 free-text
  coverage-note strings per boss (`SCORECARD_FINDING`/`SPELL_COMPOSITION_FINDING`/
  `COOLDOWN_FINDING`/`TARGET_FINDING`) plus a `RaidOverview` object, following the
  schema documented in `render_healer_report.ps1`'s own header comment and in
  the `generate-healer-report` skill.
- `scripts\render_healer_report.ps1` — merges `report_data.json` +
  `{code}_analysis.json` + `{code}_findings.json` + the class's boss template +
  `raid_overview_template.html` into the final HTML pages. Zero LLM involvement;
  refuses to run with an incomplete `findings.json` or write into a `-v1`-suffixed
  output folder.
- `scripts\update_hub_pages.ps1` — surgical upsert of the two hub pages (see
  above for its date-sorting behavior). Zero LLM involvement.
- `scripts\build_placeholder_findings.ps1` — stands in for the Claude-authoring
  step with an obvious `[CLAUDE PLACEHOLDER ...]` string in every required
  field, so the pipeline can be proven/run start-to-finish with no LLM at all
  (see README.md's "Running the pipeline manually, without Claude"). Output from
  this is never meant to be published as-is.
- `scripts\lib\ReportRenderLib.psm1` — shared helpers both scripts above import:
  CSV-string-to-number parsing, the 19-slot gear-order/enchantable-slot tables
  (gotcha #31's exact bug class — kept in exactly one place on purpose),
  per-class cooldown target-labeling mode (self/party/other), and the
  `@LOOP`/`@SLOT`/`@OPTIONAL` HTML-comment templating primitives the 7 template
  files use (string/regex based, no DOM library, consistent with every other
  script here).
- **Regression-tested against all 4 classes now** (2026-07-14: Crowns/Paladin
  and Vajomee/Shaman first, Danceswtrees/Druid and Lippies/Priest added the same
  day) — all mechanical content matched the real hand-written pages exactly
  (after accounting for a few deliberate, documented canonicalizations: sort
  order, `0%` vs `0.0%`, guid-suffix-only-on-name-collision, and — Lippies
  specifically — a gear-consistency banner whose real prose structure the
  template's fixed wrapper text can't reproduce verbatim). The Druid fixture
  exercised both Druid-only paths for real: Tree of Life uptime (0% on 7 of 9
  kills, real non-zero values of 93.7%/100% on the other 2 — all matched
  exactly) and the conditional Rebirth row (5 of 9 kills had a real,
  judgment-worthy death-to-Rebirth case; `IncludeRebirthRow` correctly
  included/omitted the row on every boss). The Priest fixture confirmed the
  `priest_pws_benchmark_bias` canned caveat renders correctly.
  The regression pass also caught real mistakes *in the original hand-written
  pages* that the new pipeline avoids — not just non-regressive, a real
  accuracy improvement each time: a mislabeled Divine Favor self% on 2 of 10
  Crowns pages, a missed OffHand missing-enchant flag on Vajomee's gear audit,
  and on Danceswtrees specifically, 2 of 3 real missing-enchant gaps (Feet,
  OffHand) that the hand-written raid overview never flagged at all (only
  caught the cloak).
- **Real bug found and fixed during the Druid/Priest regression pass**: Mana
  Potion's cooldown-table "target" column always rendered as `—` instead of
  `self`, even when it was genuinely cast, for **every class** — root cause was
  `build_boss_report_data.ps1` hardcoding Mana Potion's `Targets` array to `@()`
  regardless of real casts, which silently broke `Format-CooldownTarget`'s
  "self" mode (it checks `Targets.Count`, not the `Count` field directly).
  Fixed to populate one real `Target = "self"` entry per actual cast. **Every
  already-generated `report_data.json` in the repo was regenerated** to
  propagate the fix (all 7 real character+report folders) — this was safe and
  necessary since `build_boss_report_data.ps1` makes zero API calls and is
  meant to be safely re-run at any time, but be aware if a diff shows unrelated
  `report_data.json` churn from 2026-07-14, this is why.
- Two real PowerShell 5.1 source-encoding bugs were hit and fixed while
  building this (see "Ground rules" below for the durable rule) — worth naming
  here since they cost real debugging time twice: a literal non-ASCII character
  embedded directly in a `.ps1` file (once in `ReportRenderLib.psm1`, once
  months apart in `update_hub_pages.ps1`'s date-parsing regex) silently
  mangled into garbage on parse/execution because the file has no BOM.

## Repo structure

```
WORKFLOW.md                          <- read this first, full pipeline documentation
CLAUDE.md                            <- this file

scripts/
  pull_character_TEMPLATE.ps1        <- pulls one specific healer's full raid night (methodology-v2,
                                         events-based; migrated to the v2 GraphQL API 2026-07-12).
                                         Old v1-API version preserved as
                                         pull_character_TEMPLATE_v1.ps1. Gained real per-fight spec
                                         resolution 2026-07-16 (general, class-agnostic - not
                                         Dreamstate-specific, see "Mid-raid spec switching" above) -
                                         the one script every prior class port required zero changes
                                         to; this is the first real exception, driven by a genuine
                                         multi-spec-in-one-report case (Turkeykin), not a hypothetical.
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
  pull_top100_paladin.ps1             <- Top 100 Holy Paladin benchmark pull, methodology-v2,
                                         parallelized, diff-based against manifest.json (active/
                                         archived model) — ported to the v2 GraphQL API 2026-07-13,
                                         same day right after Priest. Real cooldowns (Holy Shock/
                                         Divine Favor/Divine Shield/Cleanse/Hand of Protection/
                                         Blessing of Freedom/Dark Rune) confirmed against a real
                                         Crowns report before being wired up - no Rebirth-equivalent
                                         or Tree-of-Life-equivalent exists for Paladin, confirmed
                                         absent from real data, not assumed. Real finding, corrected
                                         after checking the full Top 100 sample: Holy Shock's cast
                                         (guid 33072) and its resulting heal (guid 33074) are two
                                         DIFFERENT real guids, not one - see WORKFLOW.md's "v2
                                         GraphQL API" section for the full writeup, including how the
                                         first draft of this finding was too broad and had to be
                                         corrected. Old v1-API version preserved as
                                         pull_top100_paladin_v1.ps1.
  pull_top100_dreamstate.ps1          <- Top 100 Druid-Dreamstate benchmark pull, methodology-v2,
                                         parallelized, diff-based against manifest.json (active/
                                         archived model) — added 2026-07-16. **Genuinely different
                                         from every prior port: Dreamstate is a SPEC of the already-
                                         tracked Druid class, not a new class** — this script's real
                                         WCL `className`/`specName` ("Druid"/"Dreamstate") differ from
                                         its own pipeline identity (`data\Classes\Dreamstate\`), a
                                         split no prior class needed (every other class's `$className`
                                         served both roles identically). Real cooldowns (Innervate/
                                         Rebirth/Dark Rune, carried over from Druid-Restoration) plus a
                                         new Improved Faerie Fire uptime stat confirmed against a real
                                         Turkeykin report (`XJp8vAxzM4KtHYyb`, the same report already
                                         used for Crowns/Lippies) before being wired up - no Nature's
                                         Swiftness/Swiftmend/Tranquility exist for this build,
                                         confirmed absent from real data, not assumed just because it
                                         shares a base class with Restoration. See WORKFLOW.md's "v2
                                         GraphQL API" section for the full discovery writeup, including
                                         the real dead-end (Improved Faerie Fire doesn't exist as a
                                         discrete debuff event on this server at all - it's read from a
                                         completely different real field instead). No v1 version exists
                                         for this build - it was born directly on the v2 pipeline.
  pull_top100_TEMPLATE.ps1           <- generic template any of the five builds' v2 scripts were
                                         ultimately generated from (via their preserved *_v1.ps1
                                         ancestors, where one exists); still the base for a
                                         hypothetical new class's first pull script
                                         (pull_top100_druid.ps1/pull_top100_shaman.ps1/
                                         pull_top100_priest_holy.ps1/pull_top100_paladin.ps1/
                                         pull_top100_dreamstate.ps1 are the better structural reference
                                         for porting straight to v2 instead)
  migrate_class_to_active.ps1        <- ONE-TIME migration tool, date-folder -> active/archived +
                                         manifest.json. Already run for Druid (2026-07-12, migrated
                                         the 2026-07-10 pull). Has Shaman/Priest/Paladin classID/specID
                                         entries too (housekeeping only - none of the other three
                                         classes' old date-folder data had anything events-shaped to
                                         migrate forward, so this tool was NOT actually run for any of
                                         them; each of pull_top100_shaman.ps1/pull_top100_priest_holy.ps1/
                                         pull_top100_paladin.ps1 bootstrapped its own empty manifest
                                         from scratch instead) - not needed again unless a fifth class
                                         is ever added on the old convention first.
  summarize_class_benchmarks.ps1     <- reads data\Classes\{Class}\active\, writes benchmark_*.csv
                                         there too. Cooldown-guid table and Tree-of-Life buff column
                                         are class-keyed (fixed 2026-07-12 while porting Shaman, extended
                                         2026-07-13 for Priest then Paladin - see WORKFLOW.md gotcha
                                         #29/#30 area - this used to be a single flat, ungated
                                         Druid-only table that would have silently miscomputed
                                         cooldown numbers for any other class); archives the previous
                                         CSV set to archived\benchmark_history\{date}\ on a real
                                         day-over-day regen, see "Data model" below. Makes zero API
                                         calls itself, so unaffected by the v1/v2 API migration.
  lib/WclV2Api.psm1                  <- shared module for the v2 GraphQL API (OAuth token fetch/
                                         cache, generic query POST, paginated events() wrapper). Used
                                         by pull_character_TEMPLATE.ps1 and all five pull_top100_*.ps1
                                         scripts — see WORKFLOW.md's "v2 GraphQL API" section for the
                                         full endpoint mapping and auth setup.
  build_boss_report_data.ps1         <- reads pulled character data + that class's benchmark_*.csv,
                                         writes {code}_report_data.json (every real number needed for
                                         a report, zero interpretation). Makes zero API calls. Now
                                         also writes a RaidDate field (added 2026-07-14 alongside the
                                         report-code folder change - see above), and (added 2026-07-16,
                                         general/class-agnostic) a SpecCoverage field + real fight-list
                                         narrowing when a character played more than one spec across
                                         the report - see "Mid-raid spec switching" above.
  build_boss_analysis.ps1            <- NEW 2026-07-14, part of the local-scripting pipeline (see
                                         above) - report_data.json -> {code}_analysis.json, pre-flags
                                         every script-safe judgment call. Zero API calls, zero LLM.
  render_healer_report.ps1           <- NEW 2026-07-14, part of the local-scripting pipeline (see
                                         above) - report_data.json + analysis.json + findings.json +
                                         templates -> docs\{healer}\{code}\*.html. Zero LLM involvement.
  update_hub_pages.ps1               <- NEW 2026-07-14, part of the local-scripting pipeline (see
                                         above) - surgical upsert of the two hub pages, always
                                         re-sorted by raid date descending. Zero LLM involvement.
  build_placeholder_findings.ps1     <- NEW 2026-07-14, part of the local-scripting pipeline (see
                                         above) - stands in for Claude's findings.json authoring step
                                         so the pipeline can run with no LLM at all (see README.md).
  lib/ReportRenderLib.psm1           <- NEW 2026-07-14, shared helpers for build_boss_analysis.ps1
                                         and render_healer_report.ps1 (see "Local-scripting pipeline"
                                         above for what's in it).

scripts/archive/                    <- superseded/completed one-time scripts, kept as historical
                                         reference only, never run again in normal operation:
  pull_character_TEMPLATE_v1.ps1, pull_top100_{druid,shaman,priest_holy,paladin}_v1.ps1
                                     <- old v1 REST API versions, preserved when each class migrated
                                         to the v2 GraphQL API (see intro above).
  smoke_test_v2_api.ps1              <- moved here 2026-07-14 (was in scripts/ root) - throwaway
                                         verification script for the v1->v2 API migration's Phase 0,
                                         which is now fully complete for all four classes.
  backfill_activetime_danceswtrees.ps1, backfill_activetime_top100_druid.ps1,
  compute_danceswtrees_remaining_bosses.ps1
                                     <- one-off catch-up/analysis scripts from before this pipeline's
                                         current shape, already run, no longer relevant.

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
  boss_page_template_paladin.html    <- Holy Paladin variant, added 2026-07-13 (same day right after
                                         Priest) - same section shape again, with Paladin's real
                                         cooldowns (Holy Shock/Divine Favor/Divine Shield/Cleanse/
                                         Hand of Protection/Blessing of Freedom) and no Rebirth row or
                                         Tree-of-Life-equivalent stat (neither concept exists for this
                                         class either - see pull_top100_paladin.ps1's header). Also
                                         where the Holy Shock cast-vs-heal guid split lives (guid
                                         33072 cast, guid 33074 heal - see WORKFLOW.md's "v2 GraphQL
                                         API" section). Every Fresh SSC/TK healer class had its own
                                         boss page template as of this point.
  boss_page_template_dreamstate.html <- Druid-Dreamstate variant, added 2026-07-16 - based on the
                                         Druid-Restoration template's section *shape* (it's the closest
                                         match, since Dreamstate keeps the Rebirth row unlike Shaman/
                                         Priest/Paladin's templates), but with Dreamstate's own real
                                         cooldowns (Innervate/Rebirth/Dark Rune) and the Tree of Life
                                         stat block replaced by a new Improved Faerie Fire uptime stat
                                         of the same shape (see pull_top100_dreamstate.ps1's header for
                                         why this is a completely different real mechanism, not reused
                                         Tree-of-Life code). No Nature's Swiftness/Swiftmend/Tranquility
                                         rows - confirmed absent from real data, not assumed. Every
                                         Fresh SSC/TK healer BUILD now has its own boss page template.
  raid_overview_template.html        <- per-raid-night page (gear audit + 10-boss summary) - gained a
                                         new, general, class-agnostic optional SPEC_COVERAGE_NOTE block
                                         2026-07-16 (see "Mid-raid spec switching" above) - omitted
                                         entirely for every healer without a real spec split.
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

data/Classes/{Druid,Shaman,Priest,Paladin,Dreamstate}/  (v2 — active/archived + manifest.json, see
        "Data model" below. "Dreamstate" is a pipeline-key folder name, not a real WCL class - its
        real WCL identity is className: "Druid", specName: "Dreamstate", kept in a separate folder
        from data/Classes/Druid/ (Restoration) on purpose, see "Mid-raid spec switching" above)
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
data/Classes/Paladin/2026-07-10/    <- OLD v1 pull, preserved untouched, same reasoning again - not
                                        the active data anymore

data/Characters/{Name}/{ReportCode}/  (see "data\Characters\ and docs\ folders — report code, not
        raid date" above - keyed by WCL report code, NOT raid date, since 2026-07-14)
  fights_{code}.json                 <- report-wide fight list + actors, includes a raidDate field
  fight{ID}_{bossSlug}_*.json         <- per-boss-kill healing/casts/consumables/gear/activetime/deaths
  {code}_v2_rankings.json            <- real per-fight WCL percentile/rank
  {code}_report_data.json            <- every real number needed for a report (includes RaidDate)
  {code}_analysis.json               <- NEW 2026-07-14, only present for reports built through the
                                         local-scripting pipeline (see above) - pre-flagged judgment calls
  {code}_findings.json               <- NEW 2026-07-14, same - the Claude-authored free-text strings

docs/  (already generated, not templates, actual pages. v1 output moved here 2026-07-12 for
        GitHub Pages, see "Hosting" below — this is now the real path for ALL generated output,
        v1 and v2 alike; a healer folder can contain BOTH generations in different report-code
        subfolders, e.g. docs\vajomee\Mfz4kW6JpjFPArat\ is v1-methodology, docs\vajomee\Z4zNt28raQ6GLbkC\
        is v2 - check which specific report-code folder, not just the healer name, before assuming
        which methodology a page uses. Folders were renamed from {date}\ to {ReportCode}\ on
        2026-07-14 - see the section above for why and what changed)
  index.html                         <- site homepage, links to all healers below
  crowns/, danceswtrees/, lippies/, vajomee/
    index.html                       <- per-healer raid-night list, always sorted by raid date
                                         descending (see above) regardless of insertion order
    {ReportCode}/index.html          <- raid overview for that night
    {ReportCode}/healer_audit_{boss}.html  <- one per boss kill (v1 or v2 methodology depending on
                                         which pipeline generated that specific folder; hand-written
                                         or script-rendered depending on authoring method, see
                                         "Local-scripting pipeline" above - check for a sibling
                                         {code}_analysis.json/{code}_findings.json in the matching
                                         data\Characters\ folder to tell which)
    {ReportCode}-v1/...               <- a preserved v1-methodology site for the SAME report code,
                                         where one exists (see above) - never overwritten
```

Not included here (repo-specific, never shared in the source conversation):
`apikey.txt` (gitignored, v1 REST API key — no longer used by any currently-active
pull script, kept only for the preserved `*_v1.ps1` reference scripts),
`v2_client_id.txt`/`v2_client_secret.txt`/`v2_access_token.txt` (gitignored, v2
GraphQL OAuth credentials used by `WclV2Api.psm1`, now shared by
`pull_character_TEMPLATE.ps1` and all five `pull_top100_*.ps1` scripts),
`.gitignore`.

## Current state — what's solid vs. what's open

**v1 (simple) — shipped, and superseded per class as v2 lands:**
- v1-methodology pages still exist for Danceswtrees and Vajomee under `docs/`
  (each with all 10 SSC/TK boss kills for one raid night). **Crowns and
  Lippies no longer have any v1 page on disk as of 2026-07-16** — their `-v1`
  folders were deleted along with everything else for those two healers (see
  the correction below and "Recently closed" further down) — don't assume all
  4 healers still have one just because this was true before that date. This
  was the old gear-check + basic-spell-composition
  methodology — not being extended further, kept only as historical reference
  now that every original tracked class has a v2 pipeline (Dreamstate, added
  later, was born directly on v2 and never had a v1 page at all — this whole
  v1/v2 split doesn't apply to it). Danceswtrees's, Lippies's, and
  Crowns's own v1 pages had been superseded by real v2 pages for the same raid
  night (moved aside to a `-v1`-suffixed sibling folder, not deleted —
  Crowns's move happened 2026-07-13; folders were still date-named at that
  point, renamed to report-code-named on 2026-07-14, see above — a stray `_v1`
  (underscore) reference in one old cross-link was a genuine pre-existing
  typo, not a second real naming convention, fixed during that rename).
  **Correction, 2026-07-16: Crowns's and Lippies's `-v1` folders no longer
  exist** — both healers' entire `data\Characters\` and `docs\` trees for
  report `XJp8vAxzM4KtHYyb` (v1, v2-hand-written, and the `-v1` sibling alike)
  were deleted at explicit user instruction and rebuilt from scratch through
  the local-scripting pipeline (see "Local-scripting pipeline" below) — a
  deliberate, one-time deviation from the "kept forever, never deleted"
  convention this file otherwise documents for `-v1` folders, not a
  convention change. Danceswtrees's own `-v1` folder is untouched and still
  follows the original convention. Vajomee's
  earliest raid night (2026-07-03, report `Mfz4kW6JpjFPArat`) still has only a
  v1 page, but that's a genuinely separate raid night from her v2 raid nights
  (2026-07-10/`Z4zNt28raQ6GLbkC`, 2026-07-12/`QTaWq74txvPF82AR`), not the same
  night pending a regen — don't assume "class is v2" means every historical
  raid night for that healer has been regenerated.
- `data\Classes\{Shaman,Priest,Paladin}\2026-07-10\` (or 2026-07-07, check the
  actual folder) still exist as the old v1-generation Top 100 pulls, preserved
  untouched on disk, same convention as keeping `*_v1.ps1` scripts around — none
  of these are the active data for their class anymore, superseded by the v2
  ports below.

**v2 (enhanced) — Druid-Restoration, Shaman, Priest, Paladin, and Druid-Dreamstate — all five builds now:**
- `pull_character_TEMPLATE.ps1` (shared/class-agnostic) and `pull_top100_druid.ps1`
  were migrated from the v1 REST API to the v2 GraphQL API on 2026-07-12 (this was
  originally just meant to fix a null-percentile bug — v1's percentile endpoints
  are structurally incapable of returning an exact report+fight match — but the
  fix was expanded to a full API migration once the root cause was understood).
  `pull_top100_shaman.ps1` was ported the same day, as the "Phase 3" pilot class
  for extending this same v2 architecture beyond Druid; `pull_top100_priest_holy.ps1`
  followed the next day (2026-07-13); `pull_top100_paladin.ps1` followed the same
  day right after Priest — all three modeled directly on `pull_top100_druid.ps1`
  since none of the old v1 scripts shared much structurally with it (sequential,
  single healing-TABLE-per-parse, no casts/consumables/activetime/deaths at
  all). All five scripts were equivalence/smoke tested against real data before
  the old v1-API versions were preserved as `*_v1.ps1` and the new versions
  promoted to the production filenames. Full mapping/rationale for all four
  originally-ported classes in WORKFLOW.md's "v2 GraphQL API" section — the
  durable copy (plan files are session-scoped working documents, and the plan
  file at `C:\Users\raymo\.claude\plans\playful-baking-sunset.md` holds only
  the Shaman port's own plan; neither the Priest nor the Paladin port had a
  separate plan file). **No class uses the v1 REST API or `apikey.txt`
  anymore.** The same WORKFLOW.md section also has Dreamstate's own separate
  writeup (added 2026-07-16, a genuinely different kind of port — a spec of
  an already-tracked class, not a new class — see "Current state" below).
- Pipeline validated end to end on real data for all five builds: events-based
  healing/casts (no truncation), cooldown/utility tracking with self-vs-other
  targets (Druid-Restoration: Innervate/Nature's Swiftness/Swiftmend/Rebirth/
  Dark Rune with real Tree of Life buff uptime; Shaman: Earth Shield/Mana Tide
  Totem/Ancestral Swiftness/Dark Rune, confirmed against a real Vajomee report;
  Priest: Shadowfiend/Power Word: Shield/Chakra/Blessing of Life/Fear Ward/Dark
  Rune, confirmed against a real Lippies report; Paladin: Holy Shock/Divine
  Favor/Divine Shield/Cleanse/Hand of Protection/Blessing of Freedom/Dark Rune,
  confirmed against a real Crowns report — no Rebirth-equivalent or
  self-buff-uptime concept exists for Shaman, Priest, OR Paladin in this TBC
  ruleset; Druid-Dreamstate: Innervate/Rebirth/Dark Rune with a real Improved
  Faerie Fire uptime stat, confirmed against a real Turkeykin report — no
  Nature's Swiftness/Swiftmend/Tranquility exist for this build either,
  confirmed absent, not assumed), each build's own boss page template.
- All **10 of 10 bosses** pulled and confirmed on disk for Druid
  (`data\Classes\Druid\active\`, 1,000 parses), Shaman
  (`data\Classes\Shaman\active\`, ~995/1,000 — a handful of parses hit the known
  ~0.5% combatantinfo-snapshot gap, see item 3 below), Priest
  (`data\Classes\Priest\active\`, 989/1,000 — 11 failed, same gap, ~1.1%), and
  Paladin (`data\Classes\Paladin\active\`, **989/1,000** — 11 failed, same gap,
  ~1.1%, matching Priest's rate almost exactly). All four use the same
  RunspacePool + active/archived + `manifest.json` model — see "Data model"
  below. **Verify boss/parse counts against `manifest.json` or the actual folder
  before trusting a number someone recalls from memory** — this has drifted from
  reality before.
- `summarize_class_benchmarks.ps1` has been run against all five builds' full
  active sets — all four `benchmark_*.csv` files exist for each in their own
  `data\Classes\{Class}\active\` (`data\Classes\Dreamstate\active\` for the
  fifth). Its cooldown-guid table and Tree-of-Life buff column are class-keyed
  (made so while porting Shaman, extended again for Priest then Paladin), and
  a third, parallel Improved-Faerie-Fire debuff-uptime column (new,
  2026-07-16, deliberately its own flag rather than folded into the
  Tree-of-Life one — the two uptime concepts have genuinely different real
  data shapes) was added for Dreamstate (previously a single flat, ungated
  Druid-only table
  that would have silently miscomputed cooldown numbers for any other class —
  see WORKFLOW.md gotcha #29/#30 area).
- **Real finding from the Priest benchmark run**: Power Word: Shield's
  `Top100UsedPct` in `benchmark_cooldowns.csv` is ~0% on 9 of 10 bosses (1% on
  Kael'thas) — verified not a bug despite Lippies herself casting it 8 times in
  her own raid night; the benchmark population is systematically biased away
  from this ability by the HPS ranking metric, not reflecting a real "norm." Any
  Priest boss page must not read a real character's Shield usage as "overusing"
  it relative to this benchmark.
- **Real finding from the Paladin benchmark run, corrected after checking the
  full Top 100 sample**: Holy Shock's cast (guid 33072) and its resulting heal
  are logged under two DIFFERENT real guids, not one — the heal lands under
  guid 33074, also named "Holy Shock." The first draft of this finding (scoped
  only to Crowns's own report) claimed Holy Shock "doesn't itself heal," which
  turned out to be too broad — the wider Top 100 sample shows real players
  landing real Holy Shock heals (guid 33074) worth 0.6-1.7% of total healing on
  several bosses; Crowns's own 8 real casts this raid simply never happened to
  land one. Corrected in `pull_top100_paladin.ps1`'s header,
  `build_boss_report_data.ps1`'s and `summarize_class_benchmarks.ps1`'s
  comments, and `boss_page_template_paladin.html`'s guidance before this ever
  reached a real generated page — see WORKFLOW.md's "v2 GraphQL API" section
  for the full writeup and the lesson it draws (a discovery pass scoped to one
  character's report needs checking against the full Top 100 sample before a
  "never does X" claim goes into permanent documentation).
- **Druid-Dreamstate ported 2026-07-16** — genuinely different from every
  prior port: a SPEC of the already-tracked Druid class (WCL classID 2 /
  specID 6), not a new class. Real-data discovery pass against Turkeykin's
  real report (`XJp8vAxzM4KtHYyb`, the same report already used for Crowns/
  Lippies) confirmed the real kit: Innervate/Rebirth/Dark Rune carried over
  from Druid-Restoration unchanged, plus a new Improved Faerie Fire uptime
  stat unique to this build. **Confirmed absent, not assumed**: Nature's
  Swiftness, Swiftmend, Tranquility — zero real casts across Turkeykin's 4
  real Dreamstate fights. Discovery surfaced a real, non-hypothetical
  complication no prior class port had: **Turkeykin plays TWO real specs in
  that one report** — Balance (DPS) on all 6 SSC bosses, Dreamstate (healer)
  on the 4 TK bosses — which is what drove the new general "Mid-raid spec
  switching" mechanism (see above), not something specific to Dreamstate
  itself. Improved Faerie Fire uptime also turned out to be a real dead end
  on the first approach tried (an event-based debuff-interval reconstruction
  parallel to Tree of Life's) — checked exhaustively (scoped, unscoped, AND
  WCL's own aggregated debuff table, across all 4 real fights) and the
  debuff genuinely never appears as a discrete event on this server. The real
  mechanism, found instead: `table(dataType: Casts)`'s own per-ability
  `uptime` field, which DOES carry real values (47-75% across Turkeykin's 4
  fights) for this ability without any event-interval reconstruction needed
  at all — see WORKFLOW.md's "v2 GraphQL API" section for the full writeup.
  A real Top 100 benchmark pull completed for all 13 SSC/TK + Gruul's Lair/
  Magtheridon's Lair bosses (1,299/1,300 real parses, 1 failed on a private
  report — see `data\Classes\Dreamstate\active\`). **Two real, non-obvious
  PowerShell/.NET bugs were caught and fixed while building the per-fight
  spec resolution this port needed** — see WORKFLOW.md gotchas #34
  (`[ordered]@{}` + integer-key indexing resolves to a positional indexer,
  not a key lookup) and #35 (a cached-file re-read path silently double-
  wrapped already-correctly-shaped JSON).
- **All four ORIGINAL v2 healer sites have been generated end-to-end**:
  Danceswtrees/Druid (`docs\danceswtrees\Fm9XdWYtz8VCLnwg\`) and Vajomee/Shaman
  (`docs\vajomee\Z4zNt28raQ6GLbkC\`) remain hand-written by Claude from real
  `build_boss_report_data.ps1` output, generated 2026-07-13, untouched since.
  **Lippies/Priest and Crowns/Paladin are different now** — both
  (`docs\lippies\XJp8vAxzM4KtHYyb\`, `docs\crowns\XJp8vAxzM4KtHYyb\`) were
  deleted and rebuilt from scratch on 2026-07-16 through the
  `render_healer_report.ps1` pipeline (fresh WCL API pull, not reused data —
  see "Recently closed" below), so these two are script-rendered, not
  hand-written, and no longer have a `-v1` sibling folder (deleted along with
  everything else for those two healers, at explicit user instruction — see
  "Two generations" above for why this is a one-time deviation, not a
  convention change). **All folder names above reflect the 2026-07-14
  report-code rename — these were `docs\{healer}\{date}\` right up until that
  migration** (see "data\Characters\ and docs\ folders" above). There is no
  more open per-healer v2 site regen work on the original four-healer scope.
- **A fifth real v2 site exists now too — Turkeykin/Dreamstate
  (`docs\turkeykin\XJp8vAxzM4KtHYyb\`), added 2026-07-16 — but it is
  DELIBERATELY NOT linked from the main site index (`docs\index.html`)**, at
  explicit user instruction ("keep this healer hidden for now except by
  users who have the direct url"). Her own hub page
  (`docs\turkeykin\index.html`) exists and is fully functional (built via
  `update_hub_pages.ps1` WITHOUT `-IsNewHealer`) — real content, real 4-boss
  raid overview, reachable by anyone with the direct URL — she's just not
  discoverable by browsing from `docs\index.html`. **Don't add
  `-IsNewHealer` for Turkeykin in a future run without checking with the
  user first** — that flag is specifically what would add her to the main
  index and end the "hidden for now" state. `update_hub_pages.ps1` itself
  had its own separate class-gate (a second `$classSpecMap` hard-stop, not
  the one in `render_healer_report.ps1`) that was missed when Dreamstate was
  first added and had to be fixed after a real failed manual run — worth
  remembering that a new class/build addition to this pipeline has now
  bitten this exact class-gate pattern twice, in two different scripts.

**Recently closed:**
- Crowns's v2 site regen (2026-07-13) — done. Has a full raid overview + all 10
  boss pages, committed (`e463b9f6`, `a1633da6`) and pushed to `master`. Every
  one of the 4 existing healer sites now has a real v2 version.
- The GitHub Pages toggle (2026-07-13) — done. Confirmed live by fetching
  `https://twiztid-ace.github.io/WC_log_analysis/` directly: it serves the real
  site homepage listing all 4 healers (Crowns, Danceswtrees, Lippies, Vajomee).
  See the "Hosting" section below.
- The local-scripting pipeline (2026-07-14) — built, and regression-tested
  against all 4 classes (see "Local-scripting pipeline" above). Caught a real,
  now-fixed bug affecting every class along the way (Mana Potion's cooldown
  target always showing `—` instead of `self`). Not yet used to generate any
  brand-new real report (only re-verified against existing real data).
- `data\Characters\`/`docs\` folders renamed from date to report code
  (2026-07-14), including the 4 healers' existing real data — see
  "data\Characters\ and docs\ folders" above. **Any doc-audit or link check
  should use the report-code paths in this file, not the `{date}\` paths an
  older version of this file (or memory of one) might suggest.**
- **An earlier raid tier — Gruul's Lair (High King Maulgar, Gruul the
  Dragonkiller) and Magtheridon's Lair — was added to the pipeline
  (2026-07-15)**, alongside the existing SSC/TK tier, for all four classes:
  `pull_top100_{druid,shaman,priest_holy,paladin}.ps1`,
  `pull_character_TEMPLATE.ps1`, `build_boss_report_data.ps1`, and
  `summarize_class_benchmarks.ps1` all know about the new boss IDs now, and a
  real Top 100 benchmark pull completed for all four classes' `active\Gruul\`
  and `active\Magtheridon\` folders (~500 real parses each, confirmed on disk
  for Druid, Shaman, Priest, and Paladin alike). This is genuinely older
  content than SSC/TK, not a new raid tier being
  added on top — the point was filling in earlier attunement-chain bosses
  healers may still have logs for, not tracking new current content.
- **The local-scripting pipeline's first real production use (2026-07-15)**:
  report `LKbVcNfRxyBkj2mg` (12 real boss kills — the 10 usual SSC/TK bosses
  plus Maulgar and Gruul from the newly-added tier, all real kills, no wipes)
  was pulled, analyzed, and rendered end-to-end through
  `render_healer_report.ps1` for the first time ever on brand-new data (every
  prior real v2 site was hand-written by Claude — see "Local-scripting
  pipeline" above). **This is a shared raid log — both Danceswtrees (Druid,
  `data\Characters\Danceswtrees\LKbVcNfRxyBkj2mg\`) and Vajomee (Shaman,
  `data\Characters\Vajomee\LKbVcNfRxyBkj2mg\`) were pulled and rendered from
  this same report code the same day**, each with their own real
  `_analysis.json`/`_findings.json` and all 12 `docs\{healer}\LKbVcNfRxyBkj2mg\
  healer_audit_*.html` pages (confirmed on disk 2026-07-16, both hub pages
  link it) — this was not a Druid-only run. It was initially rendered and
  **published with `build_placeholder_findings.ps1`'s placeholder text still
  in it** — a real mistake, caught and fixed the same session by authoring a
  real `LKbVcNfRxyBkj2mg_findings.json` (for at least Danceswtrees; not
  independently reconfirmed whether Vajomee's findings.json went through the
  same placeholder-then-fix cycle) via the generate-healer-report skill and
  re-rendering. Two real, previously-undiscovered bugs surfaced during this
  first real run, both fixed and unlikely to be class- or report-specific:
  - **The raid overview's "bosses killed" line used to be a hardcoded
    `-TotalBosses`/`-BossesKilled` tier-size default (10 on both
    `render_healer_report.ps1` and `update_hub_pages.ps1`)** — broke the
    moment a report had more than 10 real bosses in it (rendered a
    nonsensical "12/10 bosses killed"). Fixed by deriving the denominator
    from each report's own real fight data instead: `build_boss_report_data.ps1`
    now writes a real `BossesAttempted` count to `report_data.json` (every
    real boss pull this report has, kill or wipe), and both rendering
    scripts only show a `<kills>/<attempted>` denominator when a real wipe is
    present in that specific report — otherwise it's just "`<N>` bosses
    killed". `-TotalBosses` is gone from both scripts; `update_hub_pages.ps1`
    takes an optional `-BossesAttempted` instead, only needed when a real
    wipe happened.
  - **OffHand(16) was wrongly in `ReportRenderLib.psm1`'s
    `$script:EnchantableSlotIndexes` allowlist**, flagging a real, permanent
    false-positive "missing enchant" gap on every report this pipeline has
    ever rendered — every tracked healer spec (Resto Druid, Resto Shaman,
    Holy Priest, Holy Paladin) holds a non-weapon "Held In Off-Hand" item
    there (an orb/tome/idol, confirmed live via the real gear.json icon
    `inv_misc_orb_01.jpg` on Danceswtrees's own report), and only an actual
    off-hand weapon or shield can carry a permanent enchant in this era — a
    caster off-hand item never can, full stop, regardless of what's actually
    equipped there. Removed from the allowlist entirely, same treatment as
    the existing ring exclusion (gotcha #6). **Checked for Lippies and Crowns
    on 2026-07-16** (moot for them now — their pages are script-rendered with
    the fix already applied, see "Recently closed" below) — **still not
    checked for Danceswtrees's or Vajomee's original hand-written pages**
    (`Fm9XdWYtz8VCLnwg`, `Z4zNt28raQ6GLbkC` — these predate the render
    pipeline and have never been regenerated through it) — worth a spot-check
    if a gear-audit accuracy pass is ever done on those two specifically.

- **Crowns's and Lippies's sites were deleted and rebuilt from scratch through
  the local-scripting pipeline (2026-07-16)**, at explicit user request after
  a prior patch-in-place pass (refreshing benchmarks and correcting drifted
  numbers in the existing hand-written `findings.json`, see below) was judged
  insufficient — the user wanted a genuine from-scratch regeneration, not
  edited old content. Everything for both healers (`data\Characters\`, `docs\`,
  including the `-v1` siblings) was deleted and rebuilt via a fresh WCL API
  pull for the same report code (`XJp8vAxzM4KtHYyb`) they already had — no new
  raid night, just a new authoring method for an existing one. Two real,
  previously-undiscovered errors in the OLD hand-written `findings.json` were
  caught in the process, both from claims that didn't hold up against a
  ground-up rebuild of the aggregate numbers they summarized (versus a
  narrower drifted-number patch pass, which only checks individual cited
  figures against fresh data, not whether the aggregate claim built from them
  was ever correct): Lippies's raid-overview banner said overheal exceeded the
  Top 100 sample's worst parse on "7 of 10" kills but omitted Lurker from the
  list, despite Lurker's own boss page confirming the same fact — the real
  count is 8 of 10; and a separate summary line said "6 of 10" kills landed
  under the 20th percentile while naming 7 bosses in the same sentence — the
  real count is 7 of 10. Also confirmed live: **the same WCL report+fight's
  own percentile can drift slightly between two separate pulls of the same
  report** (e.g. Crowns's Lady Vashj kill: 86th on 2026-07-13's pull, 85th on
  2026-07-16's re-pull of the identical fight) — not previously documented,
  worth remembering before treating a pulled percentile as a fixed, permanent
  number. A same-day patch-in-place pass (before the full rebuild) also caught
  and fixed the OffHand allowlist bug's real effect on Lippies specifically:
  her original hand-written page never flagged two genuine missing-enchant
  gaps (Feet, item 30100; Back, item 28765) — same class of miss as the
  Danceswtrees Feet/OffHand catch noted above.
- **Druid-Dreamstate ported end-to-end (2026-07-16)** — real Top 100 pull
  (1,299/1,300 parses across all 13 bosses), real report for Turkeykin
  (report `XJp8vAxzM4KtHYyb`, 4 real boss kills — Al'ar, Void Reaver,
  Solarian, Kael'thas), rendered and confirmed on disk
  (`docs\turkeykin\XJp8vAxzM4KtHYyb\`), her own hub page built (deliberately
  NOT linked from the main index, see the "v2" bullets above). New general
  mid-raid spec-switching mechanism built and proven on real data alongside
  it (see "Mid-raid spec switching" above). Both `CLAUDE.md` and
  `WORKFLOW.md` updated the same day to reflect all of this — if this
  section still says "four classes" or "four builds" anywhere by the time
  you're reading it, that's stale, not current.

**Explicitly open, in priority-ish order:**
1. Tranquility's guid is unknown/unobserved (Druid-only concept) —
   `$cooldownGuids["Tranquility"]` is an empty array in both Druid-touching
   scripts and will silently show 0 forever until someone adds the real guid once
   it's actually seen in a pull.
2. **Every class this project tracks (Druid, Shaman, Priest, Paladin) is now on
   the v2 pipeline, and a fifth BUILD (Druid-Dreamstate) has now actually been
   added too** — the playbook below is proven five times over now, including
   once for a build that's a SPEC of an already-tracked class rather than a
   whole new class (a real, previously-hypothetical scenario the (a)-(e) steps
   below didn't originally anticipate — see the new (f) and (g)):
   (a) a real-data discovery pass BEFORE writing any class-specific guid table
   (never assume a class's cooldown kit or self-buff-uptime concept from
   memory, and don't over-generalize a finding scoped to one character's
   report — check it against the full Top 100 sample before it goes into
   permanent documentation, see the Holy Shock finding above), (b) build the
   new pull script as a separate file modeled on the existing v2 scripts,
   smoke-test on one boss into a scratch folder, then promote, (c) add the
   class's entries to `build_boss_report_data.ps1`'s and
   `summarize_class_benchmarks.ps1`'s class-keyed tables, (d) build
   `boss_page_template_{class}.html` from the existing templates' section
   *shape*, not their specific content, (e) extend the generate-healer-report
   skill's class gate once proven end-to-end, (f) **new, from the Dreamstate
   port**: if the new build shares a real WCL class with an already-tracked
   one, don't assume its cooldown kit or self-buff-uptime concept carries over
   just because the base class is the same — check independently, and design
   a real split between the pipeline's own class-track key (folder/manifest/
   table key) and the real WCL `className`/`specName` values from the start,
   (g) **new, also from the Dreamstate port**: check EVERY script that gates
   on a hardcoded class list, not just the ones you remember touching last
   time — `render_healer_report.ps1`'s class gate and `update_hub_pages.ps1`'s
   were both missed on the first pass (two separate `$classSpecMap`-shaped
   hard-stops in two different scripts), and the second one only surfaced
   after a real failed manual run. `grep` for the previous class list's exact
   wording across `scripts\` before considering a new build "done."
3. One narrow, accepted gap, reconfirmed with real Shaman, Priest, and Paladin
   data at a broadly similar rate: no `combatantinfo` snapshot even within the
   2-minute backward buffer, likely a late-joining player — 1 case for Druid
   (~0.1%), ~5 for Shaman (~0.5%), 11 for Priest (~1.1%), 11 for Paladin
   (~1.1%, matching Priest almost exactly) — currently just reported as a
   failure for that one player's consumables data, not chased further.
4. **Power Word: Shield's Top 100 benchmark is a real but misleading ~0%** (9 of
   10 bosses) — see the "v2" bullets above. Any coverage-note on a Priest boss
   page must name this caveat rather than reading it as a norm. `build_boss_analysis.ps1`
   auto-tags this as the `priest_pws_benchmark_bias` canned caveat (see
   "Local-scripting pipeline" above) for any report built through the new pipeline.
5. **Holy Shock's cast and heal use two different real guids** (33072 cast,
   33074 heal) — see the "v2" bullets above. Any coverage-note on a Paladin boss
   page must reflect this, not assume Holy Shock never heals. `build_boss_analysis.ps1`
   auto-tags this as the `paladin_holy_shock_guid_split` canned caveat for any
   report built through the new pipeline.
6. **Not tracked, per explicit 2026-07-16 instruction**: whether Lippies/
   Crowns (or any other healer) has a real rendered report against the
   Gruul's Lair/Magtheridon's Lair tier. No healer this project tracks has
   had a real raid night on those bosses recently, and this file no longer
   monitors that gap — don't resurrect this as an open item without a new,
   real reason to (e.g. an actual new pull against those bosses). Danceswtrees
   and Vajomee's existing real reports against that tier (report
   `LKbVcNfRxyBkj2mg`, see "Recently closed" above) are unaffected by this —
   this is about not chasing further rollout, not about undoing what exists.
7. **Dreamstate has only one real data point so far — Turkeykin.** Every prior
   class port got a second real-report cross-check before being called
   "regression-tested" in this file's own language; Dreamstate hasn't had
   that yet. Not urgent (the one real data point is thorough — 4 real boss
   kills, a real multi-spec-in-one-report case, a real Top 100 pull), but
   worth naming so a future reader doesn't over-trust "confirmed against real
   data" as broadly as the phrase reads for the other four builds.
8. **Turkeykin's site is deliberately unlisted from the main site index** —
   see the "v2" bullets above for the full framing. Revisit whenever the user
   is ready to make her visible (re-run `update_hub_pages.ps1` with
   `-IsNewHealer`) — don't do this proactively without checking first.
9. **Not pushed to GitHub yet.** All of this session's Dreamstate work
   (scripts, templates, Turkeykin's data/docs, the two doc files this section
   lives in) is sitting in local commits only (this repo has an active
   auto-commit hook, confirmed live — commits appear without an explicit
   `git commit` being run) — none of it is live on GitHub Pages until an
   actual `git push` happens. Confirm with the user before pushing, same as
   any other shared/external action.

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
- **Never embed a literal non-ASCII character directly in a `.ps1`/`.psm1` file's
  source** (added 2026-07-14, generalizing gotcha #14's BOM/encoding class) —
  Windows PowerShell 5.1 reads its own source using the system default codepage
  when the file has no BOM, silently mangling any literal em-dash/arrow/middle-dot/
  etc. embedded in a string OR regex literal. Hit this twice for real, months
  apart: once in `ReportRenderLib.psm1` (broke the parser outright), once in
  `update_hub_pages.ps1`'s date-extraction regex (parsed silently but wrongly —
  every single existing raid-row failed to match its own date and sorted last).
  Always use `[char]0xNNNN` and interpolate instead — see either script for the
  pattern.
- **`data\Characters\`/`docs\` raid-night folders are keyed by WCL report code,
  not raid date** (added 2026-07-14, see "data\Characters\ and docs\ folders"
  above) — never assume or hardcode a `{yyyy-MM-dd}\` path for a NEW report; two
  raids on the same calendar date is a real scenario the old convention silently
  corrupted data for. `data\Classes\` (Top 100 benchmark data) is a completely
  separate model and is NOT affected by this — don't conflate the two.

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

**Migration done (2026-07-12), committed and pushed since.** The live v1 site
output (`index.html`, `crowns/`, `danceswtrees/`, `lippies/`, `vajomee/`) now
lives under `docs/` at repo root, moved as one whole tree (not piecemeal)
specifically so the pages' relative links (`../index.html`, etc.) kept resolving
correctly — spot-checked after the move: `docs/index.html`'s healer links,
`docs/danceswtrees/index.html`'s `../index.html` back-link, and its raid-date
subfolder link all still resolve. `scripts/`, `data/`, `templates/`,
`reference/`, `examples/`, `WORKFLOW.md`, `CLAUDE.md` stay at repo
root — Pages only serves what's inside `docs/`, so keeping them at root just
means they're not web-served (still visible in the repo browser itself, since
the repo is public — Pages scoping doesn't hide them, it just keeps them out of
the served site). This has since been committed and pushed to `master` via
SourceTree (confirmed by real commit history and by the live Pages site itself,
which can only be serving `docs/` content that's actually on `master`).

**One-time setup on github.com — done.** The GitHub Pages toggle has been
flipped (Settings → Pages → Source → "Deploy from a branch" → Branch: `master`,
folder: `/docs`), and the site is confirmed live: fetched
`https://twiztid-ace.github.io/WC_log_analysis/` directly on 2026-07-13 and it
serves the real homepage, listing all 4 healers (Crowns, Danceswtrees, Lippies,
Vajomee) with working links. It's a **project site**, served from a subpath, not
domain root — no accidentally-absolute-link problems observed, consistent with
the site's relative-link convention.

**Ongoing publish workflow:** regenerate/edit the static pages under `docs/`,
commit, push via SourceTree — GitHub rebuilds Pages automatically (typically
under a minute), no separate build step, since this has always been plain
static HTML/CSS with no bundler.

**Status: folder migration done, Pages toggle flipped, site confirmed live.**
Any future doc-audit should still re-check the live URL rather than trust this
line indefinitely — hosting config is a real, external piece of state this file
can't observe automatically.

**A second, later folder rename (2026-07-14) changed every existing raid
night's URL** — see "data\Characters\ and docs\ folders — report code, not raid
date" above. E.g. `https://twiztid-ace.github.io/WC_log_analysis/crowns/2026-07-07/`
became `.../crowns/XJp8vAxzM4KtHYyb/`. This was a deliberate, one-time fix for a
real data-corruption bug (see that section), not something to undo, but it does
mean any bookmark/external link to an old date-based URL now 404s — not
verified against the live site after this specific rename at the time this note
was written; re-check the live URLs if that matters for a given task.
