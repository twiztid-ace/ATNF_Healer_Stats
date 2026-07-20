"""Port of build_placeholder_findings.ps1.

Generates a {code}_findings.json filled entirely with an obvious placeholder
string, so the pipeline can run start-to-finish with no LLM involved (see
README.md's "data only" one-liner). render_report.py refuses to run without
a findings.json and refuses to treat a missing/blank finding as "skip it",
so a real stand-in file has to exist for a no-Claude run to produce pages.

The output is NOT a real report - every finding reads as an obvious
placeholder on the rendered page on purpose.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from pipeline import jsonio, paths

PLACEHOLDER = (
    "[CLAUDE PLACEHOLDER - no real finding was generated for this page. Run "
    "the generate-healer-report skill in Claude Code, or hand-author a real "
    "findings.json, before treating this as a real audit.]"
)


def build_placeholder_findings(
    character_name: str,
    report_code: str,
    characters_root: str = "data/Characters",
    force: bool = False,
) -> Path:
    char_root = Path(characters_root) / character_name
    if not char_root.exists():
        raise FileNotFoundError(f"{char_root} not found - run pull_character.py and build_report_data.py first.")

    report_data_file = paths.find_file_recursive(char_root, f"{report_code}_report_data.json")
    if not report_data_file:
        raise FileNotFoundError(f"no {report_code}_report_data.json found under {char_root} - run build_report_data.py first.")

    char_dir = report_data_file.parent
    findings_path = char_dir / f"{report_code}_findings.json"

    if findings_path.exists() and not force:
        raise FileExistsError(
            f"{findings_path} already exists - refusing to overwrite a possibly-real "
            f"findings.json. Pass force=True if you really want to replace it with "
            f"placeholder text."
        )

    report_data = jsonio.read_json(report_data_file)
    boss_slugs = list(report_data["Bosses"].keys())
    if not boss_slugs:
        raise ValueError(f"{report_data_file} has no bosses - nothing to generate placeholder findings for.")

    boss_findings = {}
    for slug in boss_slugs:
        entry = {
            "SCORECARD_FINDING": PLACEHOLDER,
            "SPELL_COMPOSITION_FINDING": PLACEHOLDER,
            "COOLDOWN_FINDING": PLACEHOLDER,
            "TARGET_FINDING": PLACEHOLDER,
            "MANA_TIMING_FINDING": PLACEHOLDER,
            "COOLDOWN_OPPORTUNITY_FINDING": PLACEHOLDER,
            "HOT_TIMING_FINDING": PLACEHOLDER,
        }
        # Lifebloom refresh-timing (coaching Phase 2) is Druid-Restoration
        # only - see render_report.py's _validate_findings for the matching
        # class-gated requirement.
        if report_data.get("ClassName") == "Druid":
            entry["LIFEBLOOM_REFRESH_FINDING"] = PLACEHOLDER
        boss_findings[slug] = entry

    findings = {
        "CharacterName": character_name,
        "ReportCode": report_code,
        "BossFindings": boss_findings,
        "RaidOverview": {
            "GEAR_CONSISTENCY_FINDING": PLACEHOLDER,
            "GEAR_FINDING_NOTE": PLACEHOLDER,
            "RAID_SUMMARY_FINDING": PLACEHOLDER,
        },
    }

    jsonio.write_json(findings_path, findings)
    print(f"Wrote {findings_path} ({len(boss_slugs)} boss(es), every finding is a placeholder).")
    print()
    print("WARNING: this is not a real report. Every finding on the rendered pages will read as a")
    print("placeholder. Re-run the generate-healer-report skill in Claude Code (or hand-author a")
    print("real findings.json) before treating this output as a real audit.")
    return findings_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Port of build_placeholder_findings.ps1")
    parser.add_argument("--character-name", required=True)
    parser.add_argument("--report-code", required=True)
    parser.add_argument("--characters-root", default="data/Characters")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    build_placeholder_findings(args.character_name, args.report_code, args.characters_root, args.force)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
