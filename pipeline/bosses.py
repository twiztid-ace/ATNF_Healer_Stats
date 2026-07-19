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
    # Karazhan (Phase 0, zone 1047) - confirmed live 2026-07-19 against real
    # report cd7hBa6WNG1gjDZy (all 10 encounterIDs matched data/zones.json's
    # existing Karazhan snapshot exactly). Deliberately NOT included: the
    # "Chess Event" (encounterID 660) that also appears in that report's real
    # fight list - it's Netherspite's pre-fight mini-game, not one of the 10
    # real Karazhan boss kills, so it's left unmapped and build_report_data.py
    # will skip it with its normal "no known slug/display mapping" warning.
    50652: BossMeta(50652, "attumen", "Attumen", "Attumen the Huntsman", "rankings_attumen.json"),
    50653: BossMeta(50653, "moroes", "Moroes", "Moroes", "rankings_moroes.json"),
    50654: BossMeta(50654, "maiden", "Maiden", "Maiden of Virtue", "rankings_maiden.json"),
    50655: BossMeta(50655, "opera", "Opera", "Opera Hall", "rankings_opera.json"),
    50656: BossMeta(50656, "curator", "Curator", "The Curator", "rankings_curator.json"),
    50657: BossMeta(50657, "illhoof", "Illhoof", "Terestian Illhoof", "rankings_illhoof.json"),
    50658: BossMeta(50658, "aran", "Aran", "Shade of Aran", "rankings_aran.json"),
    50659: BossMeta(50659, "netherspite", "Netherspite", "Netherspite", "rankings_netherspite.json"),
    50661: BossMeta(50661, "malchezaar", "Malchezaar", "Prince Malchezaar", "rankings_malchezaar.json"),
    50662: BossMeta(50662, "nightbane", "Nightbane", "Nightbane", "rankings_nightbane.json"),
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
