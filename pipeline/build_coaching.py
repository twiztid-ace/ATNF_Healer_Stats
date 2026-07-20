"""Additive "coaching-style" analysis layer (see Restoration Druid Healing
Analysis.pdf and the approved plan for the full phased rollout). Reads a
character's already-pulled data - {code}_report_data.json plus the raw
fight*_casts_events.json / fight*_lifebloom_buffs_events.json files
pull_character.py already writes - and writes a companion
{code}_coaching.json, following the exact same zero-API, zero-LLM discipline
as build_analysis.py: every judgment call is a pure predicate in
render_lib.py, every result is a structured field (never free text), and
anything that would require guessing intent (not just describing what
happened) is gated behind a tag string for findings.json to pick up, never
asserted here as fact.

Phase 1 covers mana-timing (zero new API calls - classResources is already
sitting unused in every existing casts_events.json file). Phase 2 adds
Lifebloom refresh-timing (Druid-Restoration only - a new but low-cost
report-wide Buffs pull already done by pull_character.py). Phase 3 adds
damage-correlated coaching (cross-class): cooldown-opportunity windows
(real raid-wide damage spikes with no tracked cooldown cast nearby) and
proactive-vs-reactive healing timing (every real targeted cast classified
against that target's own real damage-taken timeline) - both derived from
the new fight*_damagetaken_events.json raw file pull_character.py now
writes for every fight, every class. Phase 4 adds peer-group comparison
(cross-class, genuinely OPT-IN via include_peer_comparison=False by
default / --with-peer-comparison on the CLI) - unlike Phases 1-3, this one
DOES make real new API calls of its own (via pull_peer_group.py), so it is
never run silently as part of the default build-coaching pass."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from pipeline import paths, pull_peer_group as pull_peer_group_module, render_lib, wcl_api
from pipeline import jsonio
from pipeline.numeric import round_net

# Fixed thresholds for tagging a boss's mana-timing pattern as caveat-worthy -
# same "fixed numeric rule, not a per-page discovery" spirit as
# render_lib.test_tranquility_include. Chosen to flag genuinely extended
# low-mana stretches, not routine dips every healer experiences.
LOW_MANA_TIME_CAVEAT_THRESHOLD_PCT = 15.0

# Below this real proactive-share, a kill's overall casting pattern is
# flagged as "mostly reactive" - a fixed threshold, not a per-page read.
HOT_TIMING_MOSTLY_REACTIVE_THRESHOLD_PCT = 30.0


def _primary_lifebloom_target(events: list[dict]) -> tuple[int, str] | None:
    """The real target Lifebloom was maintained on the most this fight,
    resolved directly from the Lifebloom event stream itself (most real
    apply/refresh/stack events for one targetID) - not inferred from overall
    healing distribution, which can be skewed by heavy raid-wide Rejuvenation
    volume even when Lifebloom itself was single-target on the tank the
    whole kill. Returns (targetID, targetName) or None if the fight has no
    real Lifebloom events at all."""
    counts: dict[int, int] = {}
    names: dict[int, str] = {}
    for e in events:
        tid = e.get("targetID")
        if tid is None:
            continue
        counts[tid] = counts.get(tid, 0) + 1
        if tid not in names and e.get("targetName"):
            names[tid] = e["targetName"]
    if not counts:
        return None
    top_id = max(counts, key=counts.get)
    return top_id, names.get(top_id, f"Unknown_{top_id}")


def _get_own_raid_size(report_code: str, fight_id: int, access_token: str) -> int | None:
    """One real Summary-table call to learn the character's own real raid
    size for this specific kill (composition list length) - needed as the
    real matching criterion for pull_peer_group.py, not guessed from a
    healer-count heuristic. Only ever called when peer comparison is
    explicitly requested (see include_peer_comparison below) - this is
    real, additional API cost, not free."""
    q = f'query {{ reportData {{ report(code: "{report_code}") {{ table(fightIDs: [{fight_id}], dataType: Summary) }} }} }}'
    r = wcl_api.invoke_wcl_graphql(q, access_token=access_token)
    if r.errors:
        return None
    table = r.data["reportData"]["report"].get("table")
    if not table or not table.get("data"):
        return None
    comp = table["data"].get("composition") or []
    return len(comp) or None


def build_coaching(
    character_name: str,
    report_code: str,
    class_name: str,
    characters_root: str = "data/Characters",
    include_peer_comparison: bool = False,
    classes_root: str = "data/Classes",
) -> dict[str, Any]:
    char_root = Path(characters_root) / character_name
    if not char_root.exists():
        raise FileNotFoundError(f"{char_root} not found.")

    fights_file = paths.find_file_recursive(char_root, f"fights_{report_code}.json")
    if not fights_file:
        raise FileNotFoundError(
            f"no fights_{report_code}.json found under {char_root} - "
            f"run pull_character.py for '{character_name}' / {report_code} first."
        )
    char_dir = fights_file.parent
    fights_data = jsonio.read_json(fights_file)
    fight_times = {f["id"]: (f["start_time"], f["end_time"]) for f in fights_data["fights"]}

    report_data_file = char_dir / f"{report_code}_report_data.json"
    if not report_data_file.exists():
        raise FileNotFoundError(
            f"{report_data_file} not found - run build_report_data.py for "
            f"{character_name} / {report_code} / {class_name} first."
        )
    report_data = jsonio.read_json(report_data_file)

    boss_results: dict[str, dict] = {}

    for slug, boss in report_data["Bosses"].items():
        fight_id = boss["FightID"]
        times = fight_times.get(fight_id)
        if not times:
            print(f"  WARNING: {slug} (fight {fight_id}) - not found in fights_{report_code}.json, skipping coaching analysis for this boss.")
            continue
        fight_start, fight_end = times

        label = f"fight{fight_id:02d}_{slug}"
        casts_path = char_dir / f"{label}_casts_events.json"
        casts_data = jsonio.read_json_if_exists(casts_path)
        if casts_data is None:
            print(f"  WARNING: {slug} - {casts_path.name} not found, skipping mana-timing for this boss.")
            mana_timing = None
        else:
            mana_timing = render_lib.compute_mana_timing(casts_data.get("events", []), fight_start, fight_end)

        mana_potion_targets = boss.get("CooldownRows", {}).get("Mana Potion", {}).get("Targets", [])
        missed_second_potion = render_lib.test_missed_second_potion(mana_potion_targets, fight_end)

        tags: list[str] = []
        if mana_timing and mana_timing["TimeBelowLowThresholdPct"] >= LOW_MANA_TIME_CAVEAT_THRESHOLD_PCT:
            tags.append("mana_timing_extended_low_mana")
        if missed_second_potion:
            tags.append("mana_timing_missed_second_potion_window")

        lifebloom_refresh = None
        lifebloom_target_name = None
        if class_name == "Druid":
            lifebloom_path = char_dir / f"{label}_lifebloom_buffs_events.json"
            lifebloom_data = jsonio.read_json_if_exists(lifebloom_path)
            if lifebloom_data and lifebloom_data.get("events"):
                primary = _primary_lifebloom_target(lifebloom_data["events"])
                if primary:
                    target_id, lifebloom_target_name = primary
                    lifebloom_refresh = render_lib.lifebloom_refresh_analysis(lifebloom_data["events"], target_id, fight_start, fight_end)
                    if lifebloom_refresh and lifebloom_refresh["EarlyRefreshCount"] > 0:
                        tags.append("lifebloom_early_refresh_present")

        damagetaken_path = char_dir / f"{label}_damagetaken_events.json"
        damagetaken_data = jsonio.read_json_if_exists(damagetaken_path)
        cooldown_opps: list[dict] = []
        hot_timing = None
        if damagetaken_data is None:
            print(f"  WARNING: {slug} - {damagetaken_path.name} not found, skipping cooldown-opportunity/hot-timing analysis for this boss.")
        else:
            damage_events = damagetaken_data.get("events", [])
            spikes = render_lib.detect_damage_spikes(damage_events, fight_start, fight_end)
            raw_opps = render_lib.cooldown_opportunities(spikes, boss.get("CooldownRows", {}))
            # Stored fight-relative (ms since this fight's own start), not
            # report-relative - matches how the rest of coaching.json's
            # display-facing numbers are scoped to one kill.
            cooldown_opps = [
                {"Timestamp": round_net(o["Timestamp"] - fight_start), "TotalDamage": o["TotalDamage"], "RatioToAvg": o["RatioToAvg"]}
                for o in raw_opps
            ]
            if casts_data is not None:
                hot_timing = render_lib.hot_timing_proactive_reactive(casts_data.get("events", []), damage_events)

        if cooldown_opps:
            tags.append("cooldown_opportunity_present")
        if hot_timing and hot_timing["ProactivePct"] < HOT_TIMING_MOSTLY_REACTIVE_THRESHOLD_PCT:
            tags.append("hot_timing_mostly_reactive")

        peer_comparison = None
        peer_comparison_note = None
        if include_peer_comparison:
            token = wcl_api.get_wcl_access_token()
            own_size = _get_own_raid_size(report_code, fight_id, token)
            if own_size is None:
                print(f"  WARNING: {slug} - could not resolve this kill's own real raid size, skipping peer comparison for this boss.")
            else:
                peer_pool = pull_peer_group_module.pull_peer_group(class_name, slug, boss["Duration"], own_size, classes_root)
                peer_values = [c["Amount"] for c in peer_pool["Candidates"] if c.get("Amount") is not None]
                peer_comparison = render_lib.compute_peer_comparison(boss["HPS"], peer_values)
                if peer_comparison:
                    tags.append("peer_group_matching_caveat")
                    peer_comparison_note = (
                        f"Compared against {peer_comparison['PeerGroupSize']} real {class_name} parses on "
                        f"{boss['Display']} with the same raid size ({own_size}) and a similar fight duration "
                        f"({peer_pool['DurationBucket']}, +/-{int(peer_pool['DurationToleranceRatio'] * 100)}%) - "
                        f"no attempt was made to match healing assignment (tank-healing vs. raid-healing) similarity."
                    )

        boss_results[slug] = {
            "ManaTiming": mana_timing,
            "MissedSecondPotionWindow": missed_second_potion,
            "LifebloomRefresh": lifebloom_refresh,
            "LifebloomTargetName": lifebloom_target_name,
            "CooldownOpportunities": cooldown_opps,
            "HotTimingProactiveReactive": hot_timing,
            "PeerComparison": peer_comparison,
            "PeerComparisonNote": peer_comparison_note,
            "CannedCaveats": tags,
        }

    coaching = {
        "CharacterName": character_name, "ReportCode": report_code, "ClassName": class_name,
        "Bosses": boss_results,
    }

    out_path = char_dir / f"{report_code}_coaching.json"
    jsonio.write_json(out_path, coaching)
    print(f"\nWrote {out_path}")
    print(f"{len(boss_results)} boss(es) analyzed.")
    return coaching


def main() -> int:
    parser = argparse.ArgumentParser(description="Coaching-layer analysis (mana timing, Lifebloom, damage correlation, opt-in peer comparison)")
    parser.add_argument("--character-name", required=True)
    parser.add_argument("--report-code", required=True)
    parser.add_argument("--class-name", required=True)
    parser.add_argument("--characters-root", default="data/Characters")
    parser.add_argument("--classes-root", default="data/Classes")
    parser.add_argument("--with-peer-comparison", action="store_true", help="Phase 4: real peer-group comparison - makes real new API calls, opt-in only")
    args = parser.parse_args()

    build_coaching(
        args.character_name, args.report_code, args.class_name, args.characters_root,
        args.with_peer_comparison, args.classes_root,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
