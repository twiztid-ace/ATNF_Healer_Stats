# ATNF Healer Analysis — Master Workflow
 
This document is the single source of truth for how we analyze a healer's raid performance
using Warcraft Logs data. Read this first before starting any new healer analysis.
 
## Overview of the pipeline
 
1. Get the character's name + a WCL report link for the raid night to analyze.
2. Pull that report's fight list (confirms roster, class/spec, boss kill timestamps).
3. Pull the healer's own healing table for each boss kill.
4. Pull the healer's real WCL percentile for each fight (via parses/character).
5. (Optional, for deeper analysis) Pull Top 100 benchmark data for the healer's
   class/spec on each boss via `pull_top100_TEMPLATE.ps1`, then run
   `summarize_class_benchmarks.ps1` to condense it into the two benchmark CSVs
   (see "Data delivery convention" below) — this is what actually gets referenced
   for spell composition and target distribution comparisons, not the raw files.
6. Build the site pages (see "Site structure" below) using real data only — never
   fabricate or estimate numbers we haven't actually pulled.
## API basics
 
- **Base URL**: `https://fresh.warcraftlogs.com/v1`
- **Auth**: query param `api_key=...` (read from `apikey.txt` at repo root — never
  hardcode the key in scripts or commit it to git)
- This is the **V1 API** (deprecated but still functional on the Fresh realm cluster).
  Some endpoints behave unexpectedly — see "Gotchas" below.
- Reports can be **private**. If a report code returns `{"status":400,"error":"This
  report does not exist or is private."}`, that's not a typo issue — the report owner
  needs to make it public, or someone with access needs to share the raw data another way.
## Key endpoints
 
| Purpose | Endpoint |
|---|---|
| Fight list + roster for a report | `GET /report/fights/{reportCode}?api_key=...` |
| Healing table for a time range | `GET /report/tables/healing/{reportCode}?start=X&end=Y&sourceclass={Class}&api_key=...` |
| Combatant gear/talent snapshot | `GET /report/events/{reportCode}?start=X&end=Y&filter=type%3D%22combatantinfo%22&api_key=...` |
| Zone list (get encounter IDs) | `GET /zones?api_key=...` |
| Class/spec ID lookup | `GET /classes?api_key=...` |
| Top 100 rankings for one boss | `GET /rankings/encounter/{encounterID}?metric=hps&spec={specID}&class={classID}&api_key=...` |
| A character's real percentile per boss (best parse only) | `GET /rankings/character/{name}/{server}/{region}?zone=1056&metric=hps&api_key=...` |
| ALL of a character's parses (not just best) | `GET /parses/character/{name}/{server}/{region}?zone=1056&metric=hps&api_key=...` |
 
Use `parses/character` (not `rankings/character`) when you need the percentile for a
*specific* fight rather than the character's all-time best on that boss.
 
## SSC/TK reference IDs
 
Zone ID: **1056**
 
| Boss | Encounter ID |
|---|---|
| Hydross the Unstable | 100623 |
| The Lurker Below | 100624 |
| Leotheras the Blind | 100625 |
| Fathom-Lord Karathress | 100626 |
| Morogrim Tidewalker | 100627 |
| Lady Vashj | 100628 |
| Al'ar | 100730 |
| Void Reaver | 100731 |
| High Astromancer Solarian | 100732 |
| Kael'thas Sunstrider | 100733 |
 
| Class | ID | Restoration/Holy spec ID |
|---|---|---|
| Druid | 2 | 4 (Restoration) |
| Paladin | 6 | 1 (Holy) |
| Priest | 7 | 1 (Discipline) or 2 (Holy) |
| Shaman | 9 | 3 (Restoration) |
 
Full class/spec table available via `GET /classes` if a new class comes up.
 
## Pulling a specific character's raid data — exact commands
 
This is the step-by-step recipe for step 1-4 of the pipeline above, generalized from
how we did it for Danceswtrees, Crowns, and Vajomee. Replace `{REPORT_CODE}`,
`{CHARACTER_NAME}`, `{SERVER}`, `{REGION}`, and the boss time ranges with the real
values for the character/raid being pulled.
 
**Step 1 — Get the report's fight list** (confirms roster, class/spec, boss timestamps):
```bash
curl -s "https://fresh.warcraftlogs.com/v1/report/fights/{REPORT_CODE}?api_key={API_KEY}" -o fights_{REPORT_CODE}.json
```
From the response, find the character in `friendlies[]` to confirm their `type` (class)
and check `fights[]` (top-level, filter to `boss != 0` and `kill == true`) for each
boss's `id`, `start_time`, and `end_time`. **If the report code has already been pulled
for a different character in this project** (e.g. two healers logged the same raid
night), reuse that same fights file instead of re-fetching — this happened with
Danceswtrees and Crowns both being in report `XJp8vAxzM4KtHYyb`.
 
**Step 2 — Pull the healing table for each boss kill**, one call per boss, using that
boss's `start_time`/`end_time` from Step 1 and the character's class in `sourceclass`:
```bash
curl -s "https://fresh.warcraftlogs.com/v1/report/tables/healing/{REPORT_CODE}?start={START}&end={END}&sourceclass={ClassName}&api_key={API_KEY}" -o fight{FIGHT_ID}_{bossname}.json
```
This returns ALL players of that class in the fight (gotcha #3) — match the specific
character by exact `name` in the response's `entries[]`. Each matched entry already
includes `gear`, `targets`, and `abilities` — no separate combatantInfo pull needed.
 
**Step 3 — Pull the character's full parse history** (for real WCL percentiles per
fight, not just their all-time best):
```bash
curl -s "https://fresh.warcraftlogs.com/v1/parses/character/{CHARACTER_NAME}/{SERVER}/{REGION}?zone=1056&metric=hps&api_key={API_KEY}" -o {charactername}_all_parses.json
```
 
**Step 4 — Match each boss fight to its real percentile.** Try an exact match first
(`reportID == {REPORT_CODE}` AND `fightID` == that boss's fight ID from Step 1). If no
exact match exists, fall back to matching by `startTime` (within ~2000ms of the
report's absolute start + that fight's `start_time` offset) and `duration` (within
~100ms) against the same `encounterName` — this is gotcha #5 (duplicate raid uploads),
which has come up multiple times and is expected, not an error.
 
Organize all of Step 1-3's output files under `data\Characters\{CharacterName}\{date}\`
per the folder convention below, or zip them as `{CharacterName}_{date}.zip` for
per-request chat upload per the "Data delivery convention" below.
 
## Data delivery convention
 
Two distinct data types, with two different delivery methods — don't conflate them.
 
**Class benchmark data — summarized CSVs, uploaded to project knowledge (persists)**
 
Project knowledge does **not** support `.zip` files (it extracts text from supported
document types directly: PDF, DOCX, CSV, TXT, HTML, ODT, RTF, EPUB — no unzip step).
The raw Top 100 dataset (rankings + 1000 fight files per class) is also too large and
too granular to be useful there even if zip were supported — what the analysis actually
needs is the *derived* benchmark numbers, not the raw files.
 
Workflow:
1. Pull the raw data locally with `pull_top100_TEMPLATE.ps1` (as before) into
   `data\Classes\{Class}\{date}\`.
2. Run `summarize_class_benchmarks.ps1 -ClassName {Class} -DateFolder {date}` from the
   repo root. This reads the raw data and computes, per boss: HPS top1/top10avg/median,
   overheal best/median/worst, Top 10 spell composition %, Top 10 target coverage/
   concentration %. Handles the Unicode-filename decoding gotcha (see below) itself.
3. This writes two small CSVs into that same folder:
   - `benchmark_summary.csv` — one row per boss (HPS, overheal, target stats)
   - `benchmark_spell_composition.csv` — one row per boss+spell (Top 10 avg %)
4. Upload **both CSVs** to project knowledge. Small, text-based, no zip needed, and this
   is what future chats in this project should reference for benchmark comparisons —
   not the raw 1000-file dataset, which never needs to be uploaded anywhere.
The raw per-fight JSON files stay local (or in whatever local backup you keep) — they're
just the intermediate step used to produce the CSVs, not something the project or any
chat needs direct access to going forward.
 
**Character-specific raid data — zip, uploaded directly in chat (per-request, not
project knowledge)**: `{CharacterName}_{date}.zip`
```
fights_{reportCode}.json              <- fight list for that raid night
fight{fightID}_{bossname}.json        <- one per boss kill, healer's own healing table
                                          (gear/targets/abilities already embedded per
                                          entry — no separate combatantInfo pull needed)
{charactername}_all_parses.json       <- from parses/character, for real WCL percentiles
```
This is what's needed to build one specific healer's site pages (raid overview + all
boss pages) for one raid night. Uploaded directly into the chat/request when generating
that character's HTML output — a one-time input for that generation, not a standing
project file. Zip works fine here because it's a normal chat upload processed with the
code execution/bash tool (unzip + parse), unlike project knowledge which has no such
tool available. Confirmed complete/sufficient as of the Danceswtrees 2026-07-07 example —
no gaps.

Generated site output (HTML pages) — zip, never individual file shares: once the healer/raid/boss HTML pages are built (see "Site structure" below), deliver them as a single {healername}_site.zip preserving the real folder structure:
{healername}/
  index.html
  {date}/
    index.html
    healer_audit_{boss}.html   <- one per kill
Do not share the generated pages one-by-one as individual files (e.g. via a present-files-style tool). Sharing them individually flattens the directory structure — there is no folder in the delivered output, so ../index.html- and healer_audit_{boss}.html-style relative links between pages break, and same-named files at different levels (the healer's raid-list index.html vs. a given raid's overview index.html) collide/overwrite each other once flattened. Always zip the whole {healername}/ folder from the repo root and share that single archive instead, so the person can unzip it locally with the hierarchy — and therefore the relative links — intact.
 
## Folder structure convention (local, before summarizing)
 
```
{repo root}/
  apikey.txt              <- gitignored, just the raw key on one line
  .gitignore               <- must include "apikey.txt"
  pull_top100_{class}.ps1  <- one per class, or use the generic template
  data/
    Classes/
      {ClassName}/
        {date}/
          rankings_hydross.json       <- Top 100 rankings, one file per boss
          rankings_lurker.json
          ... (10 total)
          {BossFolderName}/           <- e.g. "Hydross", "VoidReaver" (no spaces)
            {reportID}_{fightID}_{playerName}.json   <- one per Top 100 parse
```
 
Individual character report pulls (for the specific healer being analyzed, not the
Top 100 benchmark) get organized separately:
 
```
  data/
    Characters/
      {CharacterName}/
        {raidDate}/
          fights_{reportCode}.json
          fight{N}_{bossname}.json    <- healing table per boss kill
          {charactername}_all_parses.json   <- from parses/character
```
 
## Site structure (the actual HTML output)
 
Three-level hierarchy:
 
```
/index.html                              <- Healer picker (site homepage)
/{healername}/index.html                 <- List of raid nights for this healer
/{healername}/{date}/index.html          <- Raid overview: gear audit + 10-boss summary table
/{healername}/{date}/healer_audit_{boss}.html   <- Individual boss deep-dive (one per kill)
```
 
Each level links back up (`← All healers`, `← All raids`) and the boss pages link back
to the raid overview and forward via the boss-name links in its summary table.
 
**Design system**: see `design_tokens.md` in this same knowledge base. Ledger/ink-teal-
and-parchment theme, Cormorant Garamond + Inter + IBM Plex Mono. Reuse these exact
tokens for every new healer/raid — don't reinvent the palette each time.
 
## What goes on each page
 
**Boss page** (per kill):
1. Header: character name, class/spec, report+fight IDs, percentile badge (number
   only, NO letter grades — this was an explicit correction, keep it)
2. Scorecard: HPS, overheal, effective healing, active time — each compared against
   real Top 100 benchmark numbers where available
3. Spell composition: character's cast mix vs. Top 10 average. **Must show the union
   of both spell lists**, not just the character's own top spells — otherwise
   benchmark-only spells (things the character never cast) get silently hidden from
   the comparison. This was a real bug we caught and fixed.
4. Target distribution: top 5 healing recipients + coverage %, compared against real
   Top 10 average concentration/coverage for that specific boss (not just described
   qualitatively — compute the actual benchmark numbers from the raw target arrays)
**Raid overview page** (one per raid night):
1. Gear audit — lives HERE ONLY, not repeated on every boss page. Confirm gear is
   identical across all kills that night before presenting one audit (check gem IDs,
   enchant IDs, item IDs per slot across all fights) — flag any slot that changes
   mid-raid as a separate note, don't just silently take the first fight's gear.
2. Per-boss summary table: HPS, overheal, percentile, link to each boss's full page.
3. Any raid-wide pattern findings that only made sense in aggregate (e.g. we found one
   healer cast zero Healing Stream Totem across all 10 kills — that's raid-level context, not a single-boss finding).
**Healer's raid list page**: just a list of raid nights analyzed, links to each raid
overview. Extensible — new raid nights get added as new dated entries.
 
**Site homepage**: list of healers analyzed, links to each healer's raid list.
 
## Gotchas / lessons learned (read before repeating mistakes)
 
1. **Unicode player names get hex-escaped in filenames.** When PowerShell writes
   `Invoke-WebRequest -OutFile` for a player with non-ASCII characters in their name
   (Korean, Chinese, accented Latin), the filename gets encoded like `#Uc5ec#Uc220`.
   Decode with regex `#U([0-9a-fA-F]{4})` → `chr(int(match, 16))` before matching
   against the `name` field inside the JSON.
2. **Ability names are localized per player's game client.** The same spell (e.g.
   Chain Heal) can appear as different strings depending on what language client cast
   it — Korean, Chinese, etc. Aggregate by the `guid` field (spell ID), NOT by name.
   Build a canonical name lookup by preferring ASCII names when voting across all
   instances of a guid.
3. **Healing table entries are per-fight, multi-player.** A `GET /report/tables/healing`
   response with `sourceclass=X` returns ALL players of that class/spec in that fight,
   not just the one you want. Match by exact `name` field.
4. **Fight-level `targets` array in the healing table is truncated to top 5.** It is
   NOT the complete target list. Always check `sum(targets) / total * 100` to see
   actual coverage — don't assume it's 100%.
5. **Duplicate raid uploads mean rankings sometimes point to a different report code.**
   If multiple raiders log the same pull, WCL may attribute the canonical ranking to
   someone else's upload. When an exact reportID+fightID match fails in
   `parses/character`, fall back to matching by `startTime` (within ~2000ms) and
   `duration` (within ~100ms) against the same encounterName. This has happened
   multiple times and is expected behavior, not an error.
6. **Ring enchants are self-only in this era of the game.** Only the character's own
   Enchanting profession can apply them — they can't be given by a guildmate like
   every other enchant type. NEVER flag missing ring enchants as a gear audit
   deficiency; it unfairly penalizes non-enchanters. All other enchant slots
   (weapon, head, shoulder, chest, legs, feet, wrist, hands, back) are fair game.
7. **Meta gems: verify the actual tooltip, don't infer from the name.** We initially
   assumed "Bracing Earthstorm Diamond" was purely defensive based on its name — it
   actually gives +26 Healing. Always fetch the real Wowhead tooltip via
   `web_search` + `web_fetch` before characterizing a gem/enchant's effect.
8. **V1 rankings/encounter endpoint wants numeric class/spec IDs**, not string names.
   `class=Shaman&spec=Restoration` fails with `"Invalid class and spec specified."`
   Use the numeric IDs from the reference table above (or `GET /classes` to confirm).
9. **No letter grades, ever.** An earlier version of the report used A/B/C/D/F grades
   on a wax-seal badge. This was explicitly removed in favor of showing just the raw
   percentile number — letter grades read as punitive/hurtful in a way a number
   doesn't. Keep it numeric-only across all future pages.
10. **`Invoke-WebRequest -OutFile` in PowerShell can silently error mid-batch.** Always
    wrap in try/catch and log failures rather than letting the whole script die. The
    pull scripts already do this — preserve that pattern in any new script.
## Copyright / IP note
 
Wowhead item/enchant/gem lookups are done via web_search + web_fetch, one call per
item. This is slow (2 calls per unique item) but necessary since enchantment IDs
in the WCL data (`permanentEnchant` field) don't reliably resolve via search unless
the log version includes `permanentEnchantName` directly (some newer report versions
do include this — check for it first before doing manual Wowhead lookups, it saves
significant time).