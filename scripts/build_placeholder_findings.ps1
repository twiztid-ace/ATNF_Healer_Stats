# build_placeholder_findings.ps1
#
# Generates a {ReportCode}_findings.json filled entirely with an obvious
# placeholder string instead of real analysis. This exists so the pipeline can
# be run start-to-finish with NO LLM involved at all (see README.md's "Running
# the pipeline manually, without Claude" section) - render_healer_report.ps1
# refuses to run without a findings.json, and deliberately refuses to treat a
# missing/empty finding as "fine, skip it" (see its own validation step), so a
# real stand-in file has to exist for a no-Claude run to produce any pages.
#
# The output is NOT a real report. Every finding reads as a placeholder on the
# rendered page on purpose - this script exists to prove the mechanical half of
# the pipeline end-to-end (data pull -> analysis -> render -> hub pages), not to
# produce something publishable. Re-run the generate-healer-report skill in
# Claude Code (or hand-author a real findings.json following its schema) before
# treating any page this produces as a real audit.
#
# Usage (run from repo root, same convention as every other script here):
#   powershell -ExecutionPolicy Bypass -File scripts\build_placeholder_findings.ps1 -CharacterName "Crowns" -ReportCode "XJp8vAxzM4KtHYyb"
#
# Refuses to overwrite an existing findings.json unless -Force is passed, so a
# real Claude-authored file already sitting there is never silently clobbered.
#
# Output: data\Characters\{CharacterName}\{raidDate}\{ReportCode}_findings.json
# (same folder as report_data.json - raidDate resolved by locating that file).

param(
    [Parameter(Mandatory=$true)][string]$CharacterName,
    [Parameter(Mandatory=$true)][string]$ReportCode,
    [string]$CharactersRoot = "data\Characters",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$Placeholder = "[CLAUDE PLACEHOLDER - no real finding was generated for this page. Run the generate-healer-report skill in Claude Code, or hand-author a real findings.json, before treating this as a real audit.]"

# ----- Locate report_data.json (same search pattern build_boss_analysis.ps1
# and render_healer_report.ps1 use). -----
$charRoot = Join-Path $CharactersRoot $CharacterName
if (-not (Test-Path $charRoot)) {
    Write-Host "ERROR: $charRoot not found - run pull_character_TEMPLATE.ps1 and build_boss_report_data.ps1 first."
    exit 1
}
$reportDataFile = Get-ChildItem -Path $charRoot -Recurse -Filter "$($ReportCode)_report_data.json" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $reportDataFile) {
    Write-Host "ERROR: no $($ReportCode)_report_data.json found under $charRoot - run build_boss_report_data.ps1 first."
    exit 1
}
$charDir = $reportDataFile.DirectoryName
$findingsPath = Join-Path $charDir "$($ReportCode)_findings.json"

if ((Test-Path $findingsPath) -and (-not $Force)) {
    Write-Host "ERROR: $findingsPath already exists - refusing to overwrite a possibly-real findings.json."
    Write-Host "  Pass -Force if you really want to replace it with placeholder text."
    exit 1
}

$reportData = Get-Content $reportDataFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
$bossSlugs = @($reportData.Bosses.PSObject.Properties.Name)
if ($bossSlugs.Count -eq 0) {
    Write-Host "ERROR: $($reportDataFile.FullName) has no bosses - nothing to generate placeholder findings for."
    exit 1
}

$bossFindings = [ordered]@{}
foreach ($slug in $bossSlugs) {
    $bossFindings[$slug] = [ordered]@{
        SCORECARD_FINDING          = $Placeholder
        SPELL_COMPOSITION_FINDING  = $Placeholder
        COOLDOWN_FINDING           = $Placeholder
        TARGET_FINDING             = $Placeholder
    }
}

$findings = [ordered]@{
    CharacterName = $CharacterName
    ReportCode    = $ReportCode
    BossFindings  = $bossFindings
    RaidOverview  = [ordered]@{
        GEAR_CONSISTENCY_FINDING = $Placeholder
        GEAR_FINDING_NOTE        = $Placeholder
        RAID_SUMMARY_FINDING     = $Placeholder
    }
}

$json = $findings | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($findingsPath, $json, (New-Object System.Text.UTF8Encoding $false))

Write-Host "Wrote $findingsPath ($($bossSlugs.Count) boss(es), every finding is a placeholder)."
Write-Host ""
Write-Host "WARNING: this is not a real report. Every finding on the rendered pages will read as a"
Write-Host "placeholder. Re-run the generate-healer-report skill in Claude Code (or hand-author a"
Write-Host "real findings.json) before treating this output as a real audit."
