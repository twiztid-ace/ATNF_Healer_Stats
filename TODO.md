# TODO / known issues

Issues surfaced while generating the Danceswtrees 2026-06-30 v2 report
(report `Fm9XdWYtz8VCLnwg`). Not fixed yet — logged here for follow-up.

## 1. Percentile/rank null for 8 of 9 boss kills in this pull

`build_boss_report_data.ps1` matches percentile/rank by exact `reportID+fightID`
against `danceswtrees_all_parses.json`. Only fight21 (The Lurker Below) had a
matching entry (64th percentile) — the other 8 kills from this same report came
back `null`.

Checked `danceswtrees_all_parses.json` directly: it only has ~6-8 entries per
encounter total, spanning many different past raid nights, and this report only
shows up once (the Lurker kill). WCL's `/parses/character/` endpoint appears to
index parses with some lag after report upload, or otherwise caps/delays how many
of a report's kills show up per encounter — not yet confirmed which. The pages
were written honestly ("hasn't appeared in WCL's parse history yet"), not
fabricated, per the pipeline's own rule.

**Follow-up:** re-run `build_boss_report_data.ps1` against this report at a later
date to see if the missing 8 percentiles resolve once WCL finishes indexing. If
they never resolve, investigate the real cause (rate limit on this endpoint,
zone/metric param issue, or a genuine per-encounter cap on `/parses/character/`).

## 2. `pull_character_TEMPLATE.ps1` can silently leave a 0-byte corrupted file

Found `fight36_karathress_deaths.json` at 0 bytes after the first (pre-parallelized)
run hit a wave of real WCL API 504s. `Invoke-WebRequest -OutFile` appears to create
the destination file before the request completes, so a mid-request failure can
leave an empty file on disk. The script's own re-run logic only checks
`Test-Path` (file exists), not that it's non-empty/valid JSON — so a corrupted
0-byte file would never be retried on a subsequent run.

Worked around manually this time (deleted the file, re-ran the pull, it backfilled
correctly). Not yet fixed in the script itself.

**Follow-up:** make every `-OutFile` write in `pull_character_TEMPLATE.ps1` and
`pull_top100_druid.ps1` either write to a temp file and move it into place only on
success, or have the existence check also verify file size > 0 before treating it
as "already fetched."

## 3. `benchmark_spell_composition.csv` vs `benchmark_cooldowns.csv` disagree on Tranquility

For at least 3 bosses this run (Morogrim, Void Reaver, High Astromancer Solarian),
`BMSpells` (spell-composition aggregate) shows a nonzero Tranquility % of total
healing (1.1%, 1.2%, 0.6% respectively), while `BMCooldowns` (cooldown-usage
aggregate) shows `Top100UsedPct: 0` for Tranquility on the same bosses — i.e. one
aggregate says nobody in the Top 100 sample cast it, the other says it contributed
real healing throughput. Both are presumably computed from the same underlying
per-parse healing/casts event files by `summarize_class_benchmarks.ps1`, just via
two different aggregation passes.

Not reconciled — both numbers were shown as-computed on the generated pages rather
than silently fixed or hidden, per the "never fabricate/never silently smooth over"
rule, but the underlying discrepancy is real and worth root-causing.

**Follow-up:** check `summarize_class_benchmarks.ps1`'s two aggregation code paths
for Tranquility specifically — likely a rounding-to-zero threshold difference or a
guid-matching gap between the two passes.

## 4. One benchmark spell name has no guid suffix (Solarian only)

`Fm9XdWYtz8VCLnwg_report_data.json`'s `Bosses.solarian.BMSpells` includes a row
named `癒合` (1.8%) with no `(guid NNNNN)` suffix, unlike every other spell row on
every other boss this run. Displayed as-is on the generated page rather than
guessed at (guid-based identity couldn't be confirmed), but this looks like a gap
in `build_boss_report_data.ps1`'s spell-name/guid annotation logic — every other
row consistently carries its guid.

**Follow-up:** find which real guid this row corresponds to in the underlying Top
100 Solarian healing-event data, and check why the annotation step skipped it.
