"""Shared path-resolution helpers.

Both pull_character_TEMPLATE.ps1 (fight-list cache reuse) and
build_boss_report_data.ps1/render_healer_report.ps1 (locating a character's
report folder) use the same real pattern: recursively search under a
character's root folder for a specific filename, since the folder itself may
be named by report code (current convention) or by raid date (legacy,
pre-2026-07-14 pulls) - see CLAUDE.md's "data\\Characters\\ and docs\\
folders" section. This module centralizes that lookup once instead of
re-implementing it per script.
"""

from pathlib import Path


def find_file_recursive(root: Path | str, filename: str) -> Path | None:
    """Mirrors `Get-ChildItem -Path $root -Recurse -Filter $filename |
    Select-Object -First 1`. Returns the first match found, or None."""
    root = Path(root)
    if not root.exists():
        return None
    matches = sorted(root.rglob(filename))
    return matches[0] if matches else None


def find_character_report_dir(characters_root: Path | str, character_name: str, report_code: str) -> Path | None:
    """Locates the folder containing fights_{report_code}.json for a given
    character - the same lookup pull_character_TEMPLATE.ps1 uses for cache
    reuse and build_boss_report_data.ps1 uses to resolve $charDir."""
    char_root = Path(characters_root) / character_name
    fights_file = find_file_recursive(char_root, f"fights_{report_code}.json")
    return fights_file.parent if fights_file else None


def find_report_data_file(characters_root: Path | str, character_name: str, report_code: str) -> Path | None:
    char_root = Path(characters_root) / character_name
    return find_file_recursive(char_root, f"{report_code}_report_data.json")
