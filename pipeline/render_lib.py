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
from pipeline.numeric import round_net

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

# ===== 19-slot gear order (see CLAUDE.md's "Ground rules") - fixed WoW
# combatantinfo gear[] position, confirmed real, never re-derive this ad hoc. =====
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
    """Exact numeric rule from SKILL.md/CLAUDE.md (Druid Tranquility only)."""
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


# ===== Mana-timing coaching (Phase 1) =====
#
# WCL v2's `classResources[]` sub-object on a Casts event has field names
# that do NOT mean what they literally say. Confirmed live 2026-07-20 via
# (a) cross-referencing this pipeline's own already-known Lifebloom mana
# cost (report_data.json's ManaCostByGuid: {"33763": 220} - exactly matches),
# and (b) a full-fight self-consistency check (never negative, never exceeds
# the pool, matches worldData.encounter's separate Resources-events
# maxResourceAmount). The real mapping:
#   entry["amount"] -> the character's MAX mana pool (constant all fight)
#   entry["max"]    -> the mana COST of this specific cast
#   entry["type"]   -> the character's CURRENT mana at the moment of this
#                       cast, BEFORE this cast's own cost is deducted
# Do not "fix" these names to look more sensible without re-verifying live -
# this is the real, confirmed shape of WCL's response, not a bug in this file.

def parse_mana_readings(cast_events: list[dict]) -> list[dict]:
    """Extracts one mana reading per cast event that carries classResources
    (some events - e.g. procs with no resourceActor - don't), sorted by
    timestamp. See the module-level note above for the real field mapping."""
    readings = []
    for ev in cast_events:
        cr = ev.get("classResources")
        if not cr:
            continue
        entry = cr[0]
        pool = entry.get("amount")
        current = entry.get("type")
        cost = entry.get("max") or 0
        if not pool:
            continue
        readings.append({
            "Timestamp": ev["timestamp"], "CurrentMana": current, "MaxMana": pool, "Cost": cost,
            "AbilityGuid": ev.get("abilityGameID"),
            "PctAtCast": round_net((current / pool) * 100, 1),
        })
    readings.sort(key=lambda r: r["Timestamp"])
    return readings


def compute_mana_timing(
    cast_events: list[dict], fight_start: float, fight_end: float,
    low_pct_threshold: float = 20, high_pct_threshold: float = 90,
) -> dict | None:
    """Mana-timing summary for one boss kill - zero new API calls, entirely
    derived from classResources already sitting in existing
    fight*_casts_events.json files. Returns None when the fight has no usable
    mana readings (e.g. a non-mana-user, or every cast event lacked
    classResources).

    "Time spent" figures are a step-function approximation (mana level held
    constant from one reading to the next) since readings only exist at cast
    moments, not continuously - a documented approximation, not a measured
    fact, same spirit as this pipeline's other derived-not-logged figures."""
    readings = parse_mana_readings(cast_events)
    if not readings:
        return None

    last = readings[-1]
    # Clamped to 0 - real mana can't go negative; a small negative raw value
    # here just means the "current mana before this cast" reading already
    # accounted for a regen tick this approximation doesn't otherwise model
    # (e.g. Dark Rune landing right at the last cast).
    ending_mana = max(0, last["CurrentMana"] - last["Cost"])
    ending_pct = round_net((ending_mana / last["MaxMana"]) * 100, 1) if last["MaxMana"] else None

    low_mana_casts = sum(1 for r in readings if r["PctAtCast"] < low_pct_threshold)
    high_mana_casts = sum(1 for r in readings if r["PctAtCast"] >= high_pct_threshold)

    points = [(fight_start, readings[0]["PctAtCast"])] + [(r["Timestamp"], r["PctAtCast"]) for r in readings] + [(fight_end, ending_pct)]
    time_low_ms = 0.0
    time_high_ms = 0.0
    for (t0, pct0), (t1, _pct1) in zip(points, points[1:]):
        if pct0 is None:
            continue
        dur = max(0.0, t1 - t0)
        if pct0 < low_pct_threshold:
            time_low_ms += dur
        elif pct0 >= high_pct_threshold:
            time_high_ms += dur

    fight_duration_ms = max(1.0, fight_end - fight_start)
    return {
        "StartingManaPct": readings[0]["PctAtCast"], "EndingManaPctApprox": ending_pct,
        "LowManaCastCount": low_mana_casts, "HighManaCastCount": high_mana_casts,
        "TimeBelowLowThresholdPct": round_net((time_low_ms / fight_duration_ms) * 100, 1),
        "TimeAboveHighThresholdPct": round_net((time_high_ms / fight_duration_ms) * 100, 1),
        "LowThreshold": low_pct_threshold, "HighThreshold": high_pct_threshold,
        "ReadingCount": len(readings),
    }


# ===== Lifebloom refresh-timing coaching (Phase 2, Druid-Restoration only) =====

LIFEBLOOM_BASE_DURATION_MS = 7000
# A refresh landing with more than this much of the buff's 7s base duration
# still remaining is flagged as an "early refresh" candidate - real ticks
# get wasted this way. This is a fixed observable-fact threshold, not a
# judgment call about whether it was a mistake (e.g. a deliberate stack
# refresh before a known damage spike can look identical) - see
# CLAUDE.md's ground rules on never presenting a guess about intent as fact.
LIFEBLOOM_EARLY_REFRESH_THRESHOLD_MS = 4000


def lifebloom_refresh_analysis(events: list[dict], target_id: int, fight_start: float, fight_end: float) -> dict | None:
    """Reconstructs one target's real Lifebloom coverage/stack-time/refresh-
    timing for one boss kill, from real apply/applybuffstack(stack)/
    refreshbuff/removebuff events (same interval-reconstruction technique
    already proven for Tree of Life - _tree_of_life_uptime_for_fight in
    pull_character.py - generalized here to a STACKED buff instead of a
    simple on/off toggle). `target_id` scopes to one real target (the one
    Lifebloom was actually maintained on the most this fight, resolved by
    the caller) - a Druid can run Lifebloom on more than one target across a
    fight, and merging their intervals together would misrepresent
    per-target coverage. Returns None when there are no real events for
    this target in this window (never fabricate a 0% row for an untouched
    target).

    If the buff was already up when the fight window opened (the first real
    event inside the window is anything other than a fresh `applybuff`),
    this floors the incoming stack at 1 (a real fact can't be recovered
    from data before this window) and leaves the refresh-timing baseline
    (`last_refresh_ts`) unset until a real refresh/apply is actually
    observed inside the window - an "early refresh" is never flagged
    against an assumed, not-really-known prior refresh time."""
    in_window = sorted(
        (e for e in events if e.get("targetID") == target_id and fight_start <= e["timestamp"] <= fight_end),
        key=lambda e: e["timestamp"],
    )
    if not in_window:
        return None

    first = in_window[0]
    active, stack = (False, 0) if first["type"] == "applybuff" else (True, 1)
    last_ts = fight_start
    last_refresh_ts: float | None = None

    total_active_ms = 0.0
    stack_time_ms = {1: 0.0, 2: 0.0, 3: 0.0}
    refresh_count = 0
    early_refreshes: list[dict] = []

    for ev in in_window:
        ts = ev["timestamp"]
        gap = ts - last_ts
        if active:
            total_active_ms += gap
            if stack in stack_time_ms:
                stack_time_ms[stack] += gap

        if ev["type"] == "applybuff":
            active, stack = True, 1
            last_refresh_ts = ts
        elif ev["type"] == "applybuffstack":
            stack = ev.get("stack", stack)
        elif ev["type"] == "refreshbuff":
            if last_refresh_ts is not None:
                remaining = LIFEBLOOM_BASE_DURATION_MS - (ts - last_refresh_ts)
                if remaining > LIFEBLOOM_EARLY_REFRESH_THRESHOLD_MS:
                    early_refreshes.append({"Timestamp": ts, "RemainingMs": round_net(remaining), "Stack": stack})
            refresh_count += 1
            last_refresh_ts = ts
        elif ev["type"] == "removebuff":
            active, stack = False, 0

        last_ts = ts

    if active:
        gap = fight_end - last_ts
        total_active_ms += gap
        if stack in stack_time_ms:
            stack_time_ms[stack] += gap

    duration = fight_end - fight_start
    uptime_pct = round_net((total_active_ms / duration) * 100, 1) if duration > 0 else 0

    return {
        "UptimePct": uptime_pct,
        "StackTimeMs": {str(k): round_net(v) for k, v in stack_time_ms.items()},
        "RefreshCount": refresh_count,
        "EarlyRefreshCount": len(early_refreshes),
        "EarlyRefreshes": early_refreshes,
    }


# ===== Damage-correlation coaching (Phase 3, cross-class) =====

DAMAGE_SPIKE_WINDOW_MS = 3000
# A window's real damage total needs to be at least this many times the
# fight's own average per-window damage to count as a real burst - relative
# to THIS fight's own baseline, not a fixed absolute number, since raid
# size/boss/duration change what "normal" damage looks like fight to fight.
DAMAGE_SPIKE_MULTIPLIER = 2.5
COOLDOWN_OPPORTUNITY_TOLERANCE_MS = 10000
HOT_TIMING_REACTIVE_WINDOW_MS = 2000
HOT_TIMING_PROACTIVE_WINDOW_MS = 5000


def detect_damage_spikes(
    damage_events: list[dict], fight_start: float, fight_end: float,
    window_ms: float = DAMAGE_SPIKE_WINDOW_MS, spike_multiplier: float = DAMAGE_SPIKE_MULTIPLIER,
) -> list[dict]:
    """Buckets real raid-wide damage-taken (`amount` - actual HP lost, not
    `unmitigatedAmount` - a fully-mitigated hit that cost 0 real HP isn't
    itself an emergency a healer needed to answer) into fixed windows
    across the fight, flags any window whose total is a real multiple of
    the fight's own average per-window damage as a burst-damage moment.
    Returns real timestamps (report-relative, same as the raw event
    stream) - the caller is responsible for converting to fight-relative
    if that's what gets stored/displayed."""
    duration = fight_end - fight_start
    if duration <= 0 or not damage_events:
        return []
    num_windows = max(1, int(duration // window_ms) + 1)
    totals = [0.0] * num_windows
    for ev in damage_events:
        amt = ev.get("amount", 0) or 0
        idx = int((ev["timestamp"] - fight_start) // window_ms)
        if 0 <= idx < num_windows:
            totals[idx] += amt
    avg = sum(totals) / num_windows
    if avg <= 0:
        return []
    return [
        {"Timestamp": fight_start + i * window_ms, "TotalDamage": round_net(total), "RatioToAvg": round_net(total / avg, 2)}
        for i, total in enumerate(totals) if total >= avg * spike_multiplier
    ]


def cooldown_opportunities(damage_spikes: list[dict], cooldown_rows: dict, tolerance_ms: float = COOLDOWN_OPPORTUNITY_TOLERANCE_MS) -> list[dict]:
    """For each real detected damage spike, checks whether ANY tracked
    cooldown (from CooldownRows' real cast timestamps, already in
    report_data.json - no re-pull needed) landed within `tolerance_ms`
    either side. Flags spikes with none as a real, observable "cooldown-idle
    high-damage window" - this NEVER claims a specific cooldown should have
    been used (that would need to know which target was in danger and
    whether the healer even had that cooldown off recharge, neither of
    which this mechanism can determine), only that the window itself is a
    real fact with no cooldown use nearby."""
    all_cast_ts = [t["Timestamp"] for row in cooldown_rows.values() for t in row.get("Targets", []) if t.get("Timestamp") is not None]
    return [
        spike for spike in damage_spikes
        if not any(abs(ts - spike["Timestamp"]) <= tolerance_ms for ts in all_cast_ts)
    ]


def hot_timing_proactive_reactive(
    cast_events: list[dict], damage_events: list[dict],
    reactive_window_ms: float = HOT_TIMING_REACTIVE_WINDOW_MS, proactive_window_ms: float = HOT_TIMING_PROACTIVE_WINDOW_MS,
) -> dict | None:
    """Classifies each real targeted cast this fight as proactive (landed
    ahead of that target's next real damage-taken event, within
    `proactive_window_ms`) or reactive (landed shortly after that target's
    most recent real damage-taken event, within `reactive_window_ms`) -
    using the character's own cast events (the moment the button was
    pressed) rather than each resulting heal/HoT tick, which would
    multiply-count one real cast many times over. A cast with real damage
    both shortly before AND after is classified reactive only - it may ALSO
    have prepared for what came next, but this mechanism can't distinguish
    genuine preparation from coincidence, so it is never double-counted
    into proactive too.

    Covers every real targeted cast, cross-class, rather than a hand-curated
    per-class "which spells count as a HoT" list (which would need new,
    unvalidated per-class knowledge this phase doesn't have) - the damage
    correlation itself naturally selects only casts that landed near real
    damage; a self-only utility cast with no nearby damage signal either way
    just falls into Unclassified, which is correct (there's no real
    proactive/reactive question to ask about it). Returns None when there's
    nothing classifiable at all (no real targeted casts, or no real damage
    this fight)."""
    by_target: dict[int, list[float]] = {}
    for ev in damage_events:
        tid = ev.get("targetID")
        if tid is not None:
            by_target.setdefault(tid, []).append(ev["timestamp"])

    proactive = reactive = unclassified = 0
    for ev in cast_events:
        tid = ev.get("targetID")
        if tid is None or tid == -1:
            continue
        ts = ev["timestamp"]
        target_damage_ts = by_target.get(tid, [])
        has_recent_before = any(0 <= ts - d <= reactive_window_ms for d in target_damage_ts)
        has_soon_after = any(0 <= d - ts <= proactive_window_ms for d in target_damage_ts)
        if has_recent_before:
            reactive += 1
        elif has_soon_after:
            proactive += 1
        else:
            unclassified += 1

    total_classified = proactive + reactive
    if total_classified == 0:
        return None

    return {
        "ProactiveCount": proactive, "ReactiveCount": reactive, "UnclassifiedCount": unclassified,
        "ProactivePct": round_net((proactive / total_classified) * 100, 1),
    }


# ===== Peer-group comparison (Phase 4, cross-class, opt-in) =====

def compute_peer_comparison(character_value: float, peer_values: list[float]) -> dict | None:
    """Real peer-relative HPS comparison, same Value/RatioToAvg/Flag shape
    as build_analysis.py's Deviations["HPS"] block, but against a real
    peer pool (pull_peer_group.py's Candidates - matched by raid size and
    fight duration, NOT healing-assignment similarity, which is explicitly
    out of scope - see the caveat text build_coaching.py attaches
    alongside this) instead of the Top 100 sample. Returns None when
    there's no real peer data to compare against - never a 0-peer
    "comparison" presented as if it meant something."""
    if not peer_values:
        return None
    sorted_values = sorted(peer_values)
    n = len(sorted_values)
    peer_avg = sum(sorted_values) / n
    peer_median = sorted_values[n // 2] if n % 2 else (sorted_values[n // 2 - 1] + sorted_values[n // 2]) / 2
    rank = sum(1 for v in sorted_values if v > character_value) + 1
    ratio = round_net(character_value / peer_avg, 2) if peer_avg > 0 else None
    flag = "in_line"
    if ratio is not None:
        flag = "below_avg" if ratio < 0.9 else ("above_avg" if ratio > 1.1 else "in_line")
    return {
        "Value": round_net(character_value), "PeerGroupSize": n,
        "PeerAvg": round_net(peer_avg), "PeerMedian": round_net(peer_median),
        "RatioToAvg": ratio, "RankAmongPeers": rank, "Flag": flag,
    }


def test_missed_second_potion(potion_targets: list[dict], fight_end: float, potion_cooldown_ms: float = 120000) -> bool:
    """Real TBC mechanic, not a guess: potions share a fixed 120s internal
    cooldown. Fixed numeric rule (same style/shape as test_tranquility_include):
    flags a real, missed second-use opportunity when exactly one potion was
    used early enough in the fight that the cooldown would have been up again
    before the fight ended, but no second use was ever cast. Never fires for
    zero or 2+ real uses - those aren't a "missed opportunity" by this rule."""
    if len(potion_targets) != 1:
        return False
    first_ts = potion_targets[0].get("Timestamp")
    if first_ts is None:
        return False
    return (fight_end - first_ts) >= potion_cooldown_ms
