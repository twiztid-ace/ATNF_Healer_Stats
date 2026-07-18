"""Port of build_boss_analysis.ps1.

Reads a character's {code}_report_data.json (already produced by
build_report_data.py - zero API calls, zero raw-event re-reads) and writes a
companion {code}_analysis.json that pre-flags every script-safe numeric
judgment call, so the one remaining LLM step (authoring {code}_findings.json)
is verification/wording, not raw arithmetic.

Field names below are deliberately PascalCase, matching the PowerShell
original's PSCustomObject property names exactly, for parity-diffing against
real PowerShell-generated analysis.json files.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Any

from pipeline import paths, render_lib
from pipeline.render_lib import convert_to_bm_number as bm_num
from pipeline import jsonio
from pipeline.numeric import round_net

KNOWN_RANK_MANA_COST = {33778: 0}

TBC_FLASK_NAMES = [
    "Flask of Blinding Light", "Flask of Pure Death", "Flask of Mighty Restoration",
    "Flask of Relentless Assault", "Flask of Fortification", "Flask of Chromatic Wonder",
    "Flask of Petrification",
]


def _get_deviation_flag(ratio_to_avg: float) -> str:
    if ratio_to_avg < 0.9:
        return "below_avg"
    if ratio_to_avg > 1.1:
        return "above_avg"
    return "in_line"


def _get_gap_flag(gap_points: float) -> str:
    if gap_points < -10:
        return "below_avg"
    if gap_points > 10:
        return "above_avg"
    return "in_line"


def _get_overheal_flag(value: float, worst: float) -> str:
    if value > worst:
        return "exceeds_worst"
    if value >= worst - 5:
        return "near_worst"
    return "in_line"


def _split_bm_spell_string(spell_string: str) -> dict:
    m = re.match(r"^(.*)\s\(guid (\d+)\)$", spell_string)
    if m:
        return {"Name": m.group(1), "Guid": int(m.group(2))}
    return {"Name": spell_string, "Guid": None}


def build_analysis(
    character_name: str,
    report_code: str,
    class_name: str,
    characters_root: str = "data/Characters",
) -> dict[str, Any]:
    char_root = Path(characters_root) / character_name
    if not char_root.exists():
        raise FileNotFoundError(f"{char_root} not found.")
    report_data_file = paths.find_file_recursive(char_root, f"{report_code}_report_data.json")
    if not report_data_file:
        raise FileNotFoundError(
            f"no {report_code}_report_data.json found under {char_root} - "
            f"run build_report_data.py --character-name {character_name} "
            f"--report-code {report_code} --class-name {class_name} first."
        )
    char_dir = report_data_file.parent
    print(f"Report data folder: {char_dir}")

    report_data = jsonio.read_json(report_data_file)

    boss_results: dict[str, dict] = {}
    death_count_rows = []
    overheal_exceeds_worst = []
    self_death_bosses = []
    lowest_percentile = []
    cooldown_deviations_by_ability: dict[str, dict] = {}

    for slug, boss in report_data["Bosses"].items():
        bm = boss.get("BM")

        # ----- Deviations -----
        deviations: dict[str, dict] = {}
        if bm:
            hps_avg = bm_num(bm.get("HPS_Top100Avg"))
            if hps_avg is not None and hps_avg > 0:
                ratio = round_net(boss["HPS"] / hps_avg, 2)
                deviations["HPS"] = {
                    "Value": boss["HPS"], "Top1": bm_num(bm.get("HPS_Top1")), "Top100Avg": hps_avg,
                    "Median": bm_num(bm.get("HPS_Median")), "RatioToAvg": ratio, "Flag": _get_deviation_flag(ratio),
                }
            overheal_worst = bm_num(bm.get("Overheal_Worst"))
            if overheal_worst is not None:
                gap_to_worst = round_net(boss["OverhealPct"] - overheal_worst, 1)
                flag = _get_overheal_flag(boss["OverhealPct"], overheal_worst)
                deviations["Overheal"] = {
                    "Value": boss["OverhealPct"], "Best": bm_num(bm.get("Overheal_Best")),
                    "Median": bm_num(bm.get("Overheal_Median")), "Worst": overheal_worst,
                    "GapToWorst": gap_to_worst, "Flag": flag,
                }
                if flag == "exceeds_worst":
                    overheal_exceeds_worst.append(slug)
            at_avg = bm_num(bm.get("ActiveTime_Top100Avg"))
            if at_avg is not None and boss.get("ActiveTimePct") is not None:
                gap = round_net(boss["ActiveTimePct"] - at_avg, 1)
                deviations["ActiveTime"] = {
                    "Value": boss["ActiveTimePct"], "Top1": bm_num(bm.get("ActiveTime_Top1")), "Top100Avg": at_avg,
                    "Median": bm_num(bm.get("ActiveTime_Median")), "GapToAvg": gap, "Flag": _get_gap_flag(gap),
                }
            hpm_sample_used = bm_num(bm.get("HPM_SampleUsed"))
            hpm_avg = bm_num(bm.get("HPM_Top100Avg"))
            omit_hpm = hpm_sample_used is None or hpm_sample_used == 0
            if not omit_hpm and hpm_avg is not None and hpm_avg > 0 and boss.get("HPM") is not None:
                ratio = round_net(boss["HPM"] / hpm_avg, 2)
                deviations["HPM"] = {
                    "Value": boss["HPM"], "Top1": bm_num(bm.get("HPM_Top1")), "Top100Avg": hpm_avg,
                    "Median": bm_num(bm.get("HPM_Median")), "RatioToAvg": ratio,
                    "Flag": _get_deviation_flag(ratio), "Omit": False,
                }
            elif omit_hpm:
                deviations["HPM"] = {"Omit": True}
            tc_avg = bm_num(bm.get("Top100_TargetCoveragePct"))
            if tc_avg is not None:
                gap = round_net(boss["CoveragePct"] - tc_avg, 1)
                deviations["TargetCoverage"] = {"Value": boss["CoveragePct"], "Top100Avg": tc_avg, "GapPoints": gap, "Flag": _get_gap_flag(gap)}
            top_avg = bm_num(bm.get("Top100_TargetTop1Pct"))
            if top_avg is not None:
                gap = round_net(boss["Top1Pct"] - top_avg, 1)
                deviations["Top1Concentration"] = {"Value": boss["Top1Pct"], "Top100Avg": top_avg, "GapPoints": gap, "Flag": _get_gap_flag(gap)}

        # ----- Spell gaps -----
        char_by_guid: dict[int, dict] = {}
        char_by_name: dict[str, list[dict]] = {}
        for row in boss.get("SpellRows", []):
            char_by_guid[int(row["Guid"])] = row
            char_by_name.setdefault(row["Name"], []).append(row)

        matched_guids: set[int] = set()
        spell_gaps = []
        for bm_spell in boss.get("BMSpells", []):
            parsed = _split_bm_spell_string(bm_spell["Spell"])
            bm_pct = bm_num(bm_spell.get("Top100Pct"))
            if bm_pct is None:
                bm_pct = 0
            char_row = None
            if parsed["Guid"]:
                char_row = char_by_guid.get(parsed["Guid"])
            elif parsed["Name"] in char_by_name:
                for candidate in char_by_name[parsed["Name"]]:
                    if int(candidate["Guid"]) not in matched_guids:
                        char_row = candidate
                        break
            char_pct = 0.0
            guid_out = parsed["Guid"]
            if char_row:
                char_pct = char_row["Pct"]
                guid_out = int(char_row["Guid"])
                matched_guids.add(int(char_row["Guid"]))
            gap = round_net(char_pct - bm_pct, 1)
            spell_gaps.append({
                "Guid": guid_out, "Name": parsed["Name"], "CharacterPct": char_pct, "BenchmarkPct": bm_pct,
                "GapPoints": gap, "BenchmarkOnly": char_row is None,
            })
        # Character-only spells (never appear in the benchmark at all)
        for row in boss.get("SpellRows", []):
            if int(row["Guid"]) not in matched_guids:
                spell_gaps.append({
                    "Guid": int(row["Guid"]), "Name": row["Name"], "CharacterPct": row["Pct"], "BenchmarkPct": 0.0,
                    "GapPoints": round_net(row["Pct"], 1), "BenchmarkOnly": False, "CharacterOnly": True,
                })
        top_spell_gap = None
        if spell_gaps:
            top = max(spell_gaps, key=lambda g: abs(g["GapPoints"]))
            top_spell_gap = {"Guid": top["Guid"], "Name": top["Name"], "GapPoints": top["GapPoints"]}

        # ----- Spell ranks -----
        mana_cost_by_guid = boss.get("ManaCostByGuid")
        bm_manacost_by_guid = report_data.get("BenchmarkManaCostByGuid")
        gaps_by_name: dict[str, list[dict]] = {}
        for g in spell_gaps:
            gaps_by_name.setdefault(g["Name"], []).append(g)
        spell_ranks = []
        for name, group in gaps_by_name.items():
            if len(group) < 2:
                continue
            rank_rows = []
            for g in group:
                mana_cost = None
                mana_cost_source = None
                if mana_cost_by_guid and g["Guid"] is not None:
                    key = str(g["Guid"])
                    if key in mana_cost_by_guid:
                        mana_cost, mana_cost_source = mana_cost_by_guid[key], "character"
                if mana_cost is None and g["Guid"] is not None and int(g["Guid"]) in KNOWN_RANK_MANA_COST:
                    mana_cost, mana_cost_source = KNOWN_RANK_MANA_COST[int(g["Guid"])], "known"
                if mana_cost is None and bm_manacost_by_guid and g["Guid"] is not None:
                    key = str(g["Guid"])
                    if key in bm_manacost_by_guid:
                        mana_cost, mana_cost_source = bm_manacost_by_guid[key], "benchmark"
                rank_label = render_lib.get_known_spell_rank_label(int(g["Guid"])) if g["Guid"] is not None else None
                rank_rows.append({
                    "Guid": g["Guid"], "ManaCost": mana_cost, "ManaCostSource": mana_cost_source,
                    "CharacterPct": g["CharacterPct"], "BenchmarkPct": g["BenchmarkPct"], "RankLabel": rank_label,
                })
            rank_rows.sort(key=lambda r: r["ManaCost"] if r["ManaCost"] is not None else float("inf"))
            spell_ranks.append({"Name": name, "Ranks": rank_rows})

        # ----- Cooldown deviations -----
        cooldowns: dict[str, dict] = {}
        bm_cd_by_ability = {cd["Ability"]: cd for cd in boss.get("BMCooldowns", [])}
        for ability_name, cd_row in boss.get("CooldownRows", {}).items():
            mode = render_lib.get_cooldown_target_mode(class_name, ability_name)
            target_label = render_lib.format_cooldown_target(cd_row["Targets"], mode)
            bm_cd = bm_cd_by_ability.get(ability_name)
            used_pct = bm_num(bm_cd.get("Top100UsedPct")) if bm_cd else None
            avg_casts = bm_num(bm_cd.get("Top100AvgCasts")) if bm_cd else None
            self_pct = bm_num(bm_cd.get("Top100SelfPct")) if bm_cd else None
            deviates = render_lib.test_cooldown_deviates(cd_row["Count"], used_pct)
            direction = ("undercast" if cd_row["Count"] == 0 else "overcast") if deviates else None
            cooldowns[ability_name] = {
                "Count": cd_row["Count"], "SelfCount": cd_row["SelfCount"], "TargetLabel": target_label,
                "Top100AvgCasts": avg_casts, "Top100UsedPct": used_pct, "Top100SelfPct": self_pct,
                "Deviates": deviates, "DeviationDirection": direction,
            }
            if deviates:
                entry = cooldown_deviations_by_ability.setdefault(ability_name, {"UndercastBosses": [], "OvercastBosses": []})
                entry["UndercastBosses" if direction == "undercast" else "OvercastBosses"].append(slug)

        tranquility_include = None
        rebirth_candidates = None
        if class_name == "Druid" and "Tranquility" in boss.get("CooldownRows", {}):
            tq_row = boss["CooldownRows"]["Tranquility"]
            tq_bm = bm_cd_by_ability.get("Tranquility")
            tq_used_pct = bm_num(tq_bm.get("Top100UsedPct")) if tq_bm else None
            tranquility_include = render_lib.test_tranquility_include(tq_row["Count"], tq_used_pct)
        # Rebirth is a SEPARATE check from Tranquility above, gated on "Druid OR
        # Dreamstate" - not folded into the Druid-only block, so Dreamstate's
        # Rebirth row is never blocked from IncludeRebirthRow eligibility.
        if class_name in ("Druid", "Dreamstate") and "Rebirth" in boss.get("CooldownRows", {}):
            rb_row = boss["CooldownRows"]["Rebirth"]
            rebirth_candidates = {"Deaths": boss.get("DeathList", []), "RebirthCasts": rb_row["Targets"]}

        # ----- Self-deaths -----
        self_deaths = [d for d in boss.get("DeathList", []) if d["Name"] == character_name]
        if self_deaths:
            self_death_bosses.append(slug)

        # ----- Nearest cooldown to each death -----
        all_cooldown_casts = []
        for ability_name, cd_row in boss.get("CooldownRows", {}).items():
            for t in cd_row["Targets"]:
                if t.get("Timestamp"):
                    all_cooldown_casts.append({"Ability": ability_name, "Timestamp": t["Timestamp"]})
        deaths_nearest_cooldown = []
        for d in boss.get("DeathList", []):
            if not all_cooldown_casts:
                continue
            nearest = min(all_cooldown_casts, key=lambda c: abs(c["Timestamp"] - d["Timestamp"]))
            deaths_nearest_cooldown.append({
                "DeathName": d["Name"], "DeathTimestamp": d["Timestamp"],
                "NearestCooldown": nearest["Ability"], "NearestCooldownTimestamp": nearest["Timestamp"],
                "DeltaMs": abs(nearest["Timestamp"] - d["Timestamp"]),
            })

        canned_caveats = render_lib.get_canned_caveats(class_name, boss.get("CooldownRows"), boss.get("SpellRows"))

        boss_results[slug] = {
            "Deviations": deviations, "SpellGaps": spell_gaps, "TopSpellGap": top_spell_gap,
            "SpellRanks": spell_ranks, "Cooldowns": cooldowns,
            "TranquilityInclude": tranquility_include, "RebirthCandidates": rebirth_candidates,
            "SelfDeaths": self_deaths, "DeathsNearestCooldown": deaths_nearest_cooldown,
            "CannedCaveats": canned_caveats,
        }

        if boss.get("DeathCount") is not None:
            death_count_rows.append({"Slug": slug, "DeathCount": boss["DeathCount"]})
        if boss.get("Percentile") is not None:
            lowest_percentile.append({"Slug": slug, "Percentile": boss["Percentile"]})

        if not bm:
            print(f"  WARNING: {slug} - no BM benchmark row, deviation flags will be sparse for this boss.")

    # ----- Gear analysis -----
    gear_analysis: dict[str, Any] = {"MissingEnchantFlags": [], "DifferingSlotsAnnotated": [], "EnchantableSlotCount": 0, "EnchantedSlotCount": 0}
    gear_diff = report_data.get("GearDiff")
    if gear_diff and gear_diff.get("BaselineGear"):
        baseline = gear_diff["BaselineGear"]
        for i, item in enumerate(baseline):
            if render_lib.test_slot_enchantable(i, item):
                gear_analysis["EnchantableSlotCount"] += 1
                has_enchant = item.get("permanentEnchant") is not None
                if has_enchant:
                    gear_analysis["EnchantedSlotCount"] += 1
                else:
                    gear_analysis["MissingEnchantFlags"].append(
                        {"SlotIndex": i, "SlotName": render_lib.get_gear_slot_name(i), "ItemId": item.get("id")}
                    )
        for diff in gear_diff.get("DifferingSlots", []):
            slot_name = render_lib.get_gear_slot_name(diff["SlotIndex"])
            variants = diff["Variants"]
            total_seen = sum(len(v["SeenOn"]) for v in variants)
            minority_variant = min(variants, key=lambda v: len(v["SeenOn"]))
            likely_benign = False
            reason = "needs review"
            if len(variants) > 1 and total_seen > 0:
                minority_share = len(minority_variant["SeenOn"]) / total_seen
                if minority_share <= 0.2:
                    likely_benign = True
                    reason = "single/minority-kill variant"
            gear_analysis["DifferingSlotsAnnotated"].append(
                {"SlotIndex": diff["SlotIndex"], "SlotName": slot_name, "LikelyBenign": likely_benign, "Reason": reason}
            )
    else:
        print("  WARNING: no GearDiff.BaselineGear in report_data.json - gear analysis will be empty.")

    # ----- Consumable setup check -----
    consumable_rows = []
    for slug, b in report_data["Bosses"].items():
        is_real_flask = b.get("FlaskActive") is True and b.get("FlaskName") in TBC_FLASK_NAMES
        has_new_format_data = b.get("BattleElixirActive") is not None and b.get("GuardianElixirActive") is not None
        is_complete = False
        is_unknown = False
        if is_real_flask:
            is_complete = True
        elif has_new_format_data:
            is_complete = b["BattleElixirActive"] is True and b["GuardianElixirActive"] is True
        else:
            is_unknown = True
        consumable_rows.append({"Slug": slug, "Display": b["Display"], "IsComplete": is_complete, "IsUnknown": is_unknown})
    gear_analysis["ConsumableSetup"] = {
        "TotalBosses": len(consumable_rows),
        "CompleteCount": sum(1 for r in consumable_rows if r["IsComplete"]),
        "UnknownCount": sum(1 for r in consumable_rows if r["IsUnknown"]),
        "IncompleteBosses": [r["Display"] for r in consumable_rows if not r["IsComplete"] and not r["IsUnknown"]],
    }

    # ----- Raid-wide rollups -----
    # Secondary sort key (Slug, ascending) added for deterministic tie-break -
    # the PowerShell original's `Sort-Object -Property DeathCount -Descending`
    # does not preserve original insertion order among exactly-tied DeathCount
    # values the way a true stable-sort-then-reverse would (confirmed via
    # parity testing: PS's tie order doesn't match its own Bosses insertion
    # order, and isn't simply reversed either - an internal Sort-Object
    # implementation detail, not a documented contract). Since neither
    # implementation defined an explicit tie-break, alphabetical-by-slug here
    # is a deliberate, documented determinism improvement, not an attempt to
    # replicate PowerShell's incidental tie order. The SET of {slug,
    # deathCount} pairs and Rank values is unaffected either way.
    death_count_rows.sort(key=lambda r: (-r["DeathCount"], r["Slug"]))
    death_count_by_boss = [
        {"Slug": r["Slug"], "DeathCount": r["DeathCount"], "Rank": i + 1} for i, r in enumerate(death_count_rows)
    ]
    lowest_percentile_sorted = sorted(lowest_percentile, key=lambda r: r["Percentile"])[:3]

    analysis = {
        "CharacterName": character_name, "ReportCode": report_code, "ClassName": class_name,
        "Bosses": boss_results,
        "RaidWideRollups": {
            "DeathCountByBoss": death_count_by_boss,
            "OverhealExceedsWorstBosses": overheal_exceeds_worst,
            "CooldownDeviations": cooldown_deviations_by_ability,
            "SelfDeathBosses": self_death_bosses,
            "LowestPercentileBosses": lowest_percentile_sorted,
        },
        "GearAnalysis": gear_analysis,
    }

    out_path = char_dir / f"{report_code}_analysis.json"
    jsonio.write_json(out_path, analysis)
    print(f"\nWrote {out_path}")
    print(f"{len(boss_results)} boss(es) analyzed.")
    return analysis


def main() -> int:
    parser = argparse.ArgumentParser(description="Port of build_boss_analysis.ps1")
    parser.add_argument("--character-name", required=True)
    parser.add_argument("--report-code", required=True)
    parser.add_argument("--class-name", required=True)
    parser.add_argument("--characters-root", default="data/Characters")
    args = parser.parse_args()

    build_analysis(args.character_name, args.report_code, args.class_name, args.characters_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
