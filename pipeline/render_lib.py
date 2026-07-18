"""Non-templating half of ReportRenderLib.psm1 - shared gear/cooldown/caveat
helpers used by build_analysis.py and (later) render_report.py.

The templating primitives (Expand-TemplateLoop, Set-TemplateSlot,
Set-TemplateOptional, etc.) are NOT ported here - those are being replaced
entirely by Jinja2 in Phase 4, per the approved migration plan.

Class-specific data (cooldown target modes, active stat blocks, has_tranquility/
has_rebirth) now lives in pipeline/classes.py rather than being duplicated here -
this module's Get-CooldownTargetMode/Get-ActiveStatBlocks equivalents are thin
wrappers over that single source of truth.
"""

from __future__ import annotations

import datetime as _dt

from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape

from pipeline import classes as classes_module

EM_DASH = "—"
RIGHT_ARROW = "→"
MULT_SIGN = "×"


def make_jinja_env(templates_root: str) -> Environment:
    """Shared Jinja2 config for both the per-boss/raid-overview renderer
    (render_report.py) and the hub-page renderer (hub_pages.py) - kept in one
    place so the two can't drift apart (autoescape/StrictUndefined behavior
    matters for both, see render_report.py's module docstring)."""
    return Environment(
        loader=FileSystemLoader(templates_root),
        autoescape=select_autoescape(["html", "jinja"]),
        undefined=StrictUndefined,
        trim_blocks=True,
        lstrip_blocks=True,
    )


def format_long_date(yyyy_mm_dd: str) -> str:
    """Matches PowerShell's ToString("MMMM d, yyyy") - full month name, day
    with no leading zero, 4-digit year. Built manually rather than via
    strftime's "%-d"/"%#d" (platform-specific: Unix vs Windows use different
    flags for "no leading zero", so neither is portable)."""
    dt = _dt.datetime.strptime(yyyy_mm_dd, "%Y-%m-%d")
    return f"{dt.strftime('%B')} {dt.day}, {dt.year}"

# ===== 19-slot gear order (WORKFLOW.md gotcha #31) - fixed WoW combatantinfo
# gear[] position, confirmed real, never re-derive this ad hoc. =====
GEAR_SLOT_NAMES = [
    "Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet",
    "Wrist", "Hands", "Finger1", "Finger2", "Trinket1", "Trinket2",
    "Back", "MainHand", "OffHand", "Ranged", "Tabard",
]

# OffHand(16) deliberately excluded - a caster off-hand "held" item (orb, tome,
# idol) can't carry a permanent enchant in this era, and combatantinfo's gear[]
# entries carry no item type/subclass field to distinguish it from a real
# off-hand weapon/shield, so the safe default is to never flag this slot.
ENCHANTABLE_SLOT_INDEXES = {0, 2, 4, 6, 7, 8, 9, 14, 15}

# Known, confirmed real per-guid labels for specific multi-rank spells whose
# guid split has actually been investigated - NOT a general "guess what any
# 2-guid spell means" mechanism.
KNOWN_SPELL_RANK_LABELS = {33763: "HoT", 33778: "Bloom"}


def get_known_spell_rank_label(guid: int) -> str | None:
    return KNOWN_SPELL_RANK_LABELS.get(guid)


def get_gear_slot_name(slot_index: int) -> str:
    if 0 <= slot_index < len(GEAR_SLOT_NAMES):
        return GEAR_SLOT_NAMES[slot_index]
    return f"Unknown({slot_index})"


def test_slot_enchantable(slot_index: int, gear_item_at_slot: dict | None = None) -> bool:
    """`gear_item_at_slot` is accepted for signature parity with the PS
    original but unused - the allowlist alone is authoritative now that
    OffHand has been removed from it."""
    return slot_index in ENCHANTABLE_SLOT_INDEXES


def convert_to_bm_number(value) -> float | None:
    """Parses a BM/BMSpells/BMCooldowns/BMBuffs CSV-string field to a float
    or None. Blank/empty -> None (means "no data"), never coerced to 0 (a
    real, meaningful zero)."""
    if value is None:
        return None
    s = str(value).strip()
    if s == "":
        return None
    try:
        return float(s)
    except ValueError:
        return None


def get_cooldown_target_mode(class_name: str, ability_name: str) -> str:
    cfg = classes_module.CLASSES.get(class_name)
    if cfg and ability_name in cfg.target_mode:
        return cfg.target_mode[ability_name]
    return "other"


def format_cooldown_target(targets: list[dict], mode: str) -> str:
    """Collapses a CooldownRows[ability].Targets array (list of {"Target":
    ..., "Timestamp": ...} dicts, matching report_data.json's real JSON
    shape) into the exact display string used across every hand-built page
    in the original pipeline."""
    if mode == "party":
        return "party" if len(targets) > 0 else EM_DASH
    if mode == "self":
        return "self" if len(targets) > 0 else EM_DASH
    if len(targets) == 0:
        return EM_DASH

    order: list[str] = []
    counts: dict[str, int] = {}
    for t in targets:
        name = "self" if t["Target"] == "self" else t["Target"]
        if name not in counts:
            counts[name] = 0
            order.append(name)
        counts[name] += 1

    parts = []
    for name in order:
        if name == "self":
            parts.append("self")
        elif counts[name] > 1:
            parts.append(f"{RIGHT_ARROW} {name} {MULT_SIGN}{counts[name]}")
        else:
            parts.append(f"{RIGHT_ARROW} {name}")
    return ", ".join(parts)


def test_tranquility_include(count: int, top100_used_pct: float | None) -> bool:
    """Exact numeric rule from SKILL.md/WORKFLOW.md (Druid Tranquility only)."""
    if top100_used_pct is None:
        return False
    pct = float(top100_used_pct)
    if count > 0 and pct <= 20:
        return True
    if count == 0 and pct >= 50:
        return True
    return False


def test_cooldown_deviates(count: int, top100_used_pct: float | None) -> bool:
    """Generalizes the same threshold to every tracked cooldown for every
    class - feeds RaidWideRollups.CooldownDeviations in the analysis file."""
    if top100_used_pct is None:
        return False
    pct = float(top100_used_pct)
    if count == 0 and pct >= 50:
        return True
    if count > 0 and pct <= 20:
        return True
    return False


def get_canned_caveats(class_name: str, cooldown_rows: dict | None, spell_rows: list[dict] | None) -> list[str]:
    """Fixed, already-documented facts (not per-page discoveries) - tags when
    the trigger condition is met so a findings-authoring step is prompted to
    use the documented caveat language rather than reinvent/misstate it."""
    tags = []
    if class_name == "Priest" and cooldown_rows and "Power Word: Shield" in cooldown_rows:
        tags.append("priest_pws_benchmark_bias")
    if class_name == "Paladin" and cooldown_rows and "Holy Shock" in cooldown_rows:
        has_heal_row = any(int(row["Guid"]) == 33074 for row in (spell_rows or []))
        if not has_heal_row:
            tags.append("paladin_holy_shock_guid_split")
    return tags


def get_active_stat_blocks(class_name: str) -> list[str]:
    cfg = classes_module.CLASSES.get(class_name)
    return list(cfg.active_stat_blocks) if cfg else ["Flask", "Food", "ManaConsumable", "HPM"]
