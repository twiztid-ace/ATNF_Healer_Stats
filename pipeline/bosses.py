"""Single source of truth for boss ID/slug/display metadata.

Consolidates what was previously duplicated across build_boss_report_data.ps1's
$bossMeta, every pull_top100_*.ps1's $bosses table, and
summarize_class_benchmarks.ps1's own boss iteration - confirmed identical
(same encounterID, same slug, same folder name) across all of those real
PowerShell sources before being written here. Boss data is class-independent -
SSC/TK/Gruul's Lair/Magtheridon's Lair bosses are the same regardless of which
class is being pulled/analyzed.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class BossMeta:
    encounter_id: int
    slug: str          # matches pull_character_TEMPLATE.ps1's fight{ID}_{slug}_*.json filename convention
    folder_name: str    # matches data/Classes/{Class}/active/{FolderName}/
    display: str         # matches the "Boss" column in every benchmark_*.csv
    rankings_file: str    # matches data/Classes/{Class}/active/rankings_{file}.json


BOSSES: dict[int, BossMeta] = {
    50649: BossMeta(50649, "maulgar", "Maulgar", "High King Maulgar", "rankings_maulgar.json"),
    50650: BossMeta(50650, "gruul", "Gruul", "Gruul the Dragonkiller", "rankings_gruul.json"),
    50651: BossMeta(50651, "magtheridon", "Magtheridon", "Magtheridon", "rankings_magtheridon.json"),
    100623: BossMeta(100623, "hydross", "Hydross", "Hydross the Unstable", "rankings_hydross.json"),
    100624: BossMeta(100624, "lurker", "Lurker", "The Lurker Below", "rankings_lurker.json"),
    100625: BossMeta(100625, "leotheras", "Leotheras", "Leotheras the Blind", "rankings_leotheras.json"),
    100626: BossMeta(100626, "karathress", "Karathress", "Fathom-Lord Karathress", "rankings_karathress.json"),
    100627: BossMeta(100627, "morogrim", "Morogrim", "Morogrim Tidewalker", "rankings_morogrim.json"),
    100628: BossMeta(100628, "vashj", "Vashj", "Lady Vashj", "rankings_vashj.json"),
    100730: BossMeta(100730, "alar", "Alar", "Al'ar", "rankings_alar.json"),
    100731: BossMeta(100731, "voidreaver", "VoidReaver", "Void Reaver", "rankings_voidreaver.json"),
    100732: BossMeta(100732, "solarian", "Solarian", "High Astromancer Solarian", "rankings_solarian.json"),
    100733: BossMeta(100733, "kaelthas", "Kaelthas", "Kael'thas Sunstrider", "rankings_kaelthas.json"),
}


def by_slug(slug: str) -> BossMeta | None:
    for meta in BOSSES.values():
        if meta.slug == slug:
            return meta
    return None


def by_display(display: str) -> BossMeta | None:
    for meta in BOSSES.values():
        if meta.display == display:
            return meta
    return None
