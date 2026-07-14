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
data\Characters\{Name}\      Per-character pulled data + generated report_data.json/analysis.json/findings.json
docs\                        The generated static site (served via GitHub Pages from /docs)
.claude\skills\generate-healer-report\   The Claude Code skill that runs this pipeline end to end
```

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
# Note the resolved class and raid date printed in its output - both are
# needed for every step below.

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
```

After step 8, `docs\<name-lowercase>\<date>\` has a full set of boss pages and a
raid overview — but every coverage-note on every page is the placeholder text
from step 6, not a real finding. To turn this into a real, publishable report,
either:
- re-run `/generate-healer-report <name> <code>` in Claude Code (it will detect
  the existing `report_data.json`/`analysis.json` and just needs a real
  `findings.json` written and the render/hub steps re-run), or
- hand-author a real `data\Characters\<name>\<date>\<code>_findings.json`
  yourself, following the schema documented in `render_healer_report.ps1`'s own
  header comment and in `SKILL.md`, then re-run steps 7-8 above.

## Hosting

The generated site lives under `docs\` and is served by GitHub Pages
(`master` branch, `/docs` folder — see `CLAUDE.md`'s "Hosting" section for the
full setup). Regenerating a report and pushing `docs\` is the entire publish
step; there is no separate build process.
