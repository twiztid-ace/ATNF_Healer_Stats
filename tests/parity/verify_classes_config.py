"""Phase 1's own verification: since pipeline/classes.py and pipeline/bosses.py
have no PowerShell equivalent to diff output against (they're new
consolidating scaffolding, not a port of one script), this instead re-parses
the real PowerShell source files with regex and asserts pipeline/classes.py's
values still match - self-checking as the PowerShell scripts keep evolving
during the transition (both implementations run side by side for a while).

Run: python -m tests.parity.verify_classes_config
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from pipeline.classes import CLASSES  # noqa: E402
from pipeline.bosses import BOSSES  # noqa: E402


def fail(msg: str, errors: list[str]) -> None:
    errors.append(msg)


def verify_class_id_spec_id(errors: list[str]) -> None:
    scripts_dir = REPO_ROOT / "scripts"
    pattern_by_class = {
        "Druid": "pull_top100_druid.ps1",
        "Shaman": "pull_top100_shaman.ps1",
        "Priest": "pull_top100_priest_holy.ps1",
        "Paladin": "pull_top100_paladin.ps1",
        "Dreamstate": "pull_top100_dreamstate.ps1",
    }
    for class_key, filename in pattern_by_class.items():
        path = scripts_dir / filename
        text = path.read_text(encoding="utf-8-sig")
        class_id_match = re.search(r"\$classID\s*=\s*(\d+)", text)
        spec_id_match = re.search(r"\$specID\s*=\s*(\d+)", text)
        if not class_id_match or not spec_id_match:
            fail(f"{filename}: could not find $classID/$specID", errors)
            continue
        cfg = CLASSES[class_key]
        if int(class_id_match.group(1)) != cfg.class_id:
            fail(
                f"{filename}: real classID={class_id_match.group(1)} but "
                f"classes.py has class_id={cfg.class_id}",
                errors,
            )
        if int(spec_id_match.group(1)) != cfg.spec_id:
            fail(
                f"{filename}: real specID={spec_id_match.group(1)} but "
                f"classes.py has spec_id={cfg.spec_id}",
                errors,
            )


def verify_class_spec_map(errors: list[str]) -> None:
    path = REPO_ROOT / "scripts" / "render_healer_report.ps1"
    text = path.read_text(encoding="utf-8-sig")
    block_match = re.search(r"\$classSpecByClass\s*=\s*@\{(.*?)\}", text, re.DOTALL)
    if not block_match:
        fail("render_healer_report.ps1: could not find $classSpecByClass block", errors)
        return
    entries = re.findall(r'"(\w+)"\s*=\s*"([^"]+)"', block_match.group(1))
    for class_key, display_name in entries:
        cfg = CLASSES.get(class_key)
        if cfg is None:
            fail(f"render_healer_report.ps1 has class '{class_key}' not present in classes.py", errors)
            continue
        if cfg.display_name != display_name:
            fail(
                f"render_healer_report.ps1: real display name for {class_key} is "
                f"'{display_name}' but classes.py has '{cfg.display_name}'",
                errors,
            )


def verify_boss_meta(errors: list[str]) -> None:
    path = REPO_ROOT / "scripts" / "build_boss_report_data.ps1"
    text = path.read_text(encoding="utf-8-sig")
    row_pattern = re.compile(
        r'(\d+)\s*=\s*@\{\s*Slug\s*=\s*"([^"]+)";\s*FolderName\s*=\s*"([^"]+)";\s*Display\s*=\s*"([^"]+)"\s*\}'
    )
    found_ids = set()
    for encounter_id, slug, folder_name, display in row_pattern.findall(text):
        found_ids.add(int(encounter_id))
        meta = BOSSES.get(int(encounter_id))
        if meta is None:
            fail(f"build_boss_report_data.ps1 has boss id {encounter_id} not present in bosses.py", errors)
            continue
        if (meta.slug, meta.folder_name, meta.display) != (slug, folder_name, display):
            fail(
                f"boss id {encounter_id}: real (slug,folder,display)=({slug},{folder_name},{display}) "
                f"but bosses.py has ({meta.slug},{meta.folder_name},{meta.display})",
                errors,
            )
    missing = set(BOSSES.keys()) - found_ids
    if missing:
        fail(f"bosses.py has boss ids not found in build_boss_report_data.ps1's $bossMeta: {missing}", errors)


def main() -> int:
    errors: list[str] = []
    verify_class_id_spec_id(errors)
    verify_class_spec_map(errors)
    verify_boss_meta(errors)

    if errors:
        print(f"VERIFY FAILED - {len(errors)} discrepancy(ies):")
        for e in errors:
            print(f"  - {e}")
        return 1

    print(f"VERIFY OK - {len(CLASSES)} classes, {len(BOSSES)} bosses cross-checked against real PowerShell sources.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
