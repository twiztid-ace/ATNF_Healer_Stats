"""Port of build_boss_report_data.ps1.

Pure local computation - makes ZERO API calls, reads only files already
pulled to disk by pull_character.py / pull_top100.py / summarize_benchmarks.py.
Turns those raw files into one clean {code}_report_data.json with every real
number needed to author a healer's boss pages + raid overview.

Field names in every dict below are deliberately PascalCase, matching the
PowerShell original's PSCustomObject property names exactly - this is what
lets tests/parity/deep_diff.py compare this module's JSON output directly
against the real PowerShell-generated report_data.json files.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from statistics import mean
from typing import Any

from pipeline import bosses as bosses_module
from pipeline import classes as classes_module
from pipeline import csvio, jsonio, paths
from pipeline.numeric import round_net

TRACKED_HEALER_SPEC_KEYS = {
    "Druid|Restoration", "Druid|Dreamstate", "Shaman|Restoration",
    "Priest|Holy", "Priest|Discipline", "Paladin|Holy",
}


def _is_self_target(source_name: str | None, target_name: str | None) -> bool:
    """A spell logged against the Environment pseudo-actor (targetID=-1)
    mechanically cannot have gone to a real other player - treated as self,
    same as an empty targetName or sourceName==targetName."""
    return (source_name == target_name) or (not target_name) or (target_name == "Environment")


def _round(value: float, digits: int = 0):
    return round_net(value, digits)


def build_report_data(
    character_name: str,
    report_code: str,
    class_name: str,
    characters_root: str = "data/Characters",
) -> dict[str, Any]:
    cfg = classes_module.get(class_name)
    cooldown_guids = cfg.cooldown_guids
    mana_potion_name = cfg.mana_potion_name

    char_root = Path(characters_root) / character_name
    if not char_root.exists():
        raise FileNotFoundError(f"{char_root} not found - run pull_character.py for '{character_name}' first.")

    fights_file = paths.find_file_recursive(char_root, f"fights_{report_code}.json")
    if not fights_file:
        raise FileNotFoundError(
            f"no fights_{report_code}.json found anywhere under {char_root} - "
            f"run pull_character.py --report-code {report_code} --character-name {character_name} first."
        )
    char_dir = fights_file.parent
    print(f"Character data folder: {char_dir}")

    fights_data = jsonio.read_json(fights_file)
    raid_date = fights_data.get("raidDate")

    rankings_path = char_dir / f"{report_code}_v2_rankings.json"
    rankings_data = jsonio.read_json_if_exists(rankings_path)
    if rankings_data is None:
        print(f"  WARNING: {rankings_path} not found - percentile/rank will be blank for every boss.")

    spec_coverage_path = char_dir / f"{report_code}_spec_coverage.json"
    spec_coverage_data = jsonio.read_json_if_exists(spec_coverage_path)
    spec_coverage = None
    if spec_coverage_data and spec_coverage_data["TotalBossesInReport"] > spec_coverage_data["BossesAnalyzed"]:
        spec_coverage = {
            "AnalyzedSpec": spec_coverage_data["AnalyzedSpec"],
            "TotalBossesInReport": spec_coverage_data["TotalBossesInReport"],
            "BossesAnalyzed": spec_coverage_data["BossesAnalyzed"],
            "ExcludedBosses": [
                {"BossName": b["BossName"], "Spec": b["ResolvedSpec"]}
                for b in spec_coverage_data["Bosses"] if not b["Included"]
            ],
        }

    bench_dir = Path("data/Classes") / class_name / "active"
    if not bench_dir.exists():
        raise FileNotFoundError(
            f"{bench_dir} not found - run pull_top100.py --class-name {class_name} "
            f"then summarize_benchmarks.py --class-name {class_name} first."
        )
    bm_summary = csvio.read_csv(bench_dir / "benchmark_summary.csv")
    bm_spells = csvio.read_csv(bench_dir / "benchmark_spell_composition.csv")
    bm_cooldowns = csvio.read_csv(bench_dir / "benchmark_cooldowns.csv")
    bm_buffs = csvio.read_csv(bench_dir / "benchmark_buffs.csv")
    manacost_path = bench_dir / "benchmark_manacost_by_guid.csv"
    if manacost_path.exists():
        bm_manacost_by_guid = {row["Guid"]: float(row["ManaCost"]) for row in csvio.read_csv(manacost_path)}
    else:
        print(f"  WARNING: {manacost_path} not found - Spell Ranks section won't have a benchmark "
              f"fallback for mana costs the character didn't cast this kill.")
        bm_manacost_by_guid = {}

    all_fights = fights_data["fights"]
    if spec_coverage:
        included_fight_ids = {b["FightID"] for b in spec_coverage_data["Bosses"] if b["Included"]}
        all_fights = [f for f in all_fights if f["id"] in included_fight_ids]
    all_boss_pulls = [f for f in all_fights if f.get("boss", 0) != 0]
    boss_fights = [f for f in all_boss_pulls if f.get("kill") is True]
    distinct_bosses_attempted = len({f["boss"] for f in all_boss_pulls})
    print(
        f"{len(boss_fights)} boss kill(s) found for {character_name} in report {report_code} "
        f"({distinct_bosses_attempted} distinct boss(es) attempted, {len(all_boss_pulls)} total real pull(s) including any wipes)."
    )

    results: dict[str, dict] = {}
    gear_by_boss: dict[str, list] = {}

    for fight in boss_fights:
        boss_id = fight["boss"]
        meta = bosses_module.BOSSES.get(boss_id)
        if meta is None:
            print(f"  WARNING: boss id {boss_id} ('{fight.get('name')}') has no known slug/display mapping - skipping.")
            continue

        label = f"fight{fight['id']:02d}_{meta.slug}"
        duration = fight["end_time"] - fight["start_time"]

        healing_path = char_dir / f"{label}_healing_events.json"
        casts_path = char_dir / f"{label}_casts_events.json"
        if not healing_path.exists() or not casts_path.exists():
            print(f"  WARNING: {label} - missing healing_events or casts_events, skipping this boss entirely.")
            continue

        healing_data = jsonio.read_json(healing_path)
        casts_data = jsonio.read_json(casts_path)
        consumables_data = jsonio.read_json_if_exists(char_dir / f"{label}_consumables.json")
        active_time_data = jsonio.read_json_if_exists(char_dir / f"{label}_activetime.json")
        deaths_data = jsonio.read_json_if_exists(char_dir / f"{label}_deaths.json")
        gear_data = jsonio.read_json_if_exists(char_dir / f"{label}_gear.json")

        total = healing_data.get("totalAmount", 0)
        overheal = healing_data.get("totalOverheal", 0)
        raw_healing = total + overheal
        overheal_pct = _round((overheal / raw_healing) * 100, 1) if raw_healing > 0 else 0
        hps = _round(total / (duration / 1000), 0) if duration > 0 else 0

        # ----- Spell composition, strictly by guid -----
        abilities: dict[int, dict] = {}
        for ev in healing_data.get("events", []):
            ability = ev.get("ability")
            if ability and ev.get("amount") and "healthstone" not in ability["name"].lower():
                guid = ability["guid"]
                if guid not in abilities:
                    abilities[guid] = {"Name": ability["name"], "Total": 0.0}
                abilities[guid]["Total"] += ev["amount"]
        spell_rows = []
        for guid, a in abilities.items():
            pct = _round((a["Total"] / total) * 100, 1) if total > 0 else 0
            spell_rows.append({"Guid": guid, "Name": a["Name"], "Total": _round(a["Total"], 0), "Pct": pct})
        spell_rows.sort(key=lambda r: r["Total"], reverse=True)

        # ----- Real mana cost per guid, from classResources on this fight's own casts -----
        mana_cost_by_guid: dict[str, float] = {}
        for ev in casts_data.get("events", []):
            ability = ev.get("ability")
            resources = ev.get("classResources")
            if ability and resources and len(resources) > 0:
                g = str(ability["guid"])
                if g not in mana_cost_by_guid:
                    mana_cost_by_guid[g] = _round(resources[0]["max"], 0)

        # ----- Target distribution -----
        targets: dict[str, float] = {}
        for ev in healing_data.get("events", []):
            name = ev.get("targetName")
            amount = ev.get("amount")
            if name and amount:
                targets[name] = targets.get(name, 0.0) + amount
        sorted_targets = sorted(targets.items(), key=lambda kv: kv[1], reverse=True)
        top5 = sorted_targets[:5]
        top5_sum = sum(v for _, v in top5)
        coverage_pct = _round((top5_sum / total) * 100, 1) if total > 0 else 0
        top1_pct = _round((sorted_targets[0][1] / total) * 100, 1) if sorted_targets and total > 0 else 0
        top_amount = top5[0][1] if top5 else 1
        target_rows = []
        for name, value in top5:
            pct = _round((value / total) * 100, 1) if total > 0 else 0
            bar_width = _round((value / top_amount) * 100, 1) if top_amount > 0 else 0
            target_rows.append({"Name": name, "Pct": pct, "BarWidth": bar_width, "Amount": _round(value, 0)})

        # ----- Cooldowns/utility, excluding begincast -----
        cooldown_rows: dict[str, dict] = {}
        for cd_name, guid_list in cooldown_guids.items():
            matched = (
                [ev for ev in casts_data.get("events", [])
                 if ev.get("ability", {}).get("guid") in guid_list and ev.get("type") != "begincast"]
                if len(guid_list) > 0 else []
            )
            target_list = []
            for m in matched:
                is_self = _is_self_target(m.get("sourceName"), m.get("targetName"))
                target_list.append({"Target": "self" if is_self else m.get("targetName"), "Timestamp": m.get("timestamp")})
            self_count = sum(1 for t in target_list if t["Target"] == "self")
            cooldown_rows[cd_name] = {"Count": len(matched), "SelfCount": self_count, "Targets": target_list}

        if mana_potion_name:
            mana_matched = [ev for ev in casts_data.get("events", []) if ev.get("ability", {}).get("name") == mana_potion_name]
            mana_targets = [{"Target": "self", "Timestamp": ev.get("timestamp")} for ev in mana_matched]
            cooldown_rows["Mana Potion"] = {"Count": len(mana_matched), "SelfCount": len(mana_matched), "Targets": mana_targets}

        # ----- HPM -----
        mana_spent = 0.0
        for ev in casts_data.get("events", []):
            resources = ev.get("classResources")
            if resources and len(resources) > 0:
                mana_spent += resources[0]["max"]
        hpm = round_net(total / mana_spent, 2) if mana_spent > 0 else None

        active_time_pct = active_time_data.get("activeTimePct") if active_time_data else None

        death_count = len(deaths_data.get("entries", [])) if deaths_data else None
        death_list = [{"Name": d["name"], "Timestamp": d["timestamp"]} for d in (deaths_data.get("entries", []) if deaths_data else [])]

        # ----- Percentile/rank, matched by exact fightID -----
        ranking_fight = None
        if rankings_data:
            ranking_fight = next((r for r in rankings_data["data"] if r["fightID"] == fight["id"]), None)
        healer_match = None
        if ranking_fight:
            healer_match = next(
                (c for c in ranking_fight["roles"]["healers"]["characters"] if c["name"] == character_name), None
            )
        percentile = _round(healer_match["rankPercent"], 0) if healer_match else None
        rank = healer_match["rank"] if healer_match else None
        out_of = healer_match["totalParses"] if healer_match else None
        if not healer_match:
            print(f"  WARNING: {label} - no matching healer entry in {report_code}_v2_rankings.json for "
                  f"fightID={fight['id']} - percentile/rank will be blank.")

        # ----- ItemLevel Healing Rank -----
        ilvl_healing_rank_rows = []
        if ranking_fight and ranking_fight["roles"]["healers"]["characters"]:
            ilvl_healers = sorted(
                (c for c in ranking_fight["roles"]["healers"]["characters"]
                 if f"{c['class']}|{c['spec']}" in TRACKED_HEALER_SPEC_KEYS),
                key=lambda c: c["rankPercent"], reverse=True,
            )
            ilvl_healing_rank_rows = [
                {
                    "Name": c["name"], "Class": c["class"], "Spec": c["spec"],
                    "RankPercent": _round(c["rankPercent"], 0),
                    "ItemLevelBracket": c["bracketData"], "TotalParses": c["totalParses"],
                    "IsCharacter": c["name"] == character_name,
                }
                for c in ilvl_healers
            ]
        ilvl_healing_rank = next(
            (i + 1 for i, r in enumerate(ilvl_healing_rank_rows) if r["IsCharacter"]), None
        )
        ilvl_healing_rank_count = len(ilvl_healing_rank_rows)

        # ----- Raw Healing Rank -----
        raw_healing_rank_rows = []
        if active_time_data and active_time_data.get("sameRaidHealersRawHealing"):
            raw_healers = sorted(active_time_data["sameRaidHealersRawHealing"], key=lambda h: h["Total"], reverse=True)
            raw_healing_rank_rows = [
                {
                    "Name": h["Name"], "Total": _round(h["Total"], 0), "ItemLevel": h.get("ItemLevel"),
                    "IsCharacter": h["Name"] == character_name,
                }
                for h in raw_healers
            ]
        raw_healing_rank = next(
            (i + 1 for i, r in enumerate(raw_healing_rank_rows) if r["IsCharacter"]), None
        )
        raw_healing_rank_count = len(raw_healing_rank_rows)
        item_level_bracket = healer_match["bracketData"] if healer_match else None

        # ----- Healer Ranking (merged view) -----
        healer_ranking_by_name: dict[str, dict] = {}
        for h in raw_healing_rank_rows:
            healer_ranking_by_name[h["Name"]] = {
                "Name": h["Name"], "IsCharacter": h["IsCharacter"],
                "RawHealingTotal": h["Total"], "RankPercent": None, "ItemLevel": h["ItemLevel"],
            }
        for h in ilvl_healing_rank_rows:
            if h["Name"] in healer_ranking_by_name:
                row = healer_ranking_by_name[h["Name"]]
                row["RankPercent"] = h["RankPercent"]
                if row["ItemLevel"] is None:
                    row["ItemLevel"] = h["ItemLevelBracket"]
            else:
                healer_ranking_by_name[h["Name"]] = {
                    "Name": h["Name"], "IsCharacter": h["IsCharacter"],
                    "RawHealingTotal": None, "RankPercent": h["RankPercent"], "ItemLevel": h["ItemLevelBracket"],
                }
        healer_ranking_rows = sorted(
            healer_ranking_by_name.values(),
            key=lambda r: r["RawHealingTotal"] if r["RawHealingTotal"] is not None else -1,
            reverse=True,
        )
        raw_totals = [r["RawHealingTotal"] for r in healer_ranking_rows if r["RawHealingTotal"] is not None]
        top_raw_healing_total = max(raw_totals) if raw_totals else 0
        combined_raw_healing_total = sum(raw_totals) if raw_totals else 0
        for row in healer_ranking_rows:
            if row["RawHealingTotal"] is not None and top_raw_healing_total > 0:
                row["BarWidth"] = _round((row["RawHealingTotal"] / top_raw_healing_total) * 100, 1)
            else:
                row["BarWidth"] = None
            if row["RawHealingTotal"] is not None and combined_raw_healing_total > 0:
                row["TotalPct"] = _round((row["RawHealingTotal"] / combined_raw_healing_total) * 100, 1)
            else:
                row["TotalPct"] = None

        # ----- Benchmark comparisons -----
        bm_row = next((r for r in bm_summary if r["Boss"] == meta.display), None)
        bm_spell_rows = [r for r in bm_spells if r["Boss"] == meta.display]
        bm_cd_rows = [r for r in bm_cooldowns if r["Boss"] == meta.display]
        bm_buff_row = next((r for r in bm_buffs if r["Boss"] == meta.display), None)
        if not bm_row:
            print(f"  WARNING: {label} - no benchmark_summary.csv row for '{meta.display}' - Top 100 comparisons will be blank.")

        results[meta.slug] = {
            "Display": meta.display, "FightID": fight["id"], "Duration": duration,
            "Total": _round(total, 0), "Overheal": _round(overheal, 0), "OverhealPct": overheal_pct, "HPS": hps,
            "SpellRows": spell_rows, "ManaCostByGuid": mana_cost_by_guid,
            "TargetRows": target_rows, "CoveragePct": coverage_pct, "Top1Pct": top1_pct,
            "DistinctTargetCount": len(sorted_targets),
            "CooldownRows": cooldown_rows, "ManaSpent": _round(mana_spent, 0), "HPM": hpm,
            "ActiveTimePct": active_time_pct, "DeathCount": death_count, "DeathList": death_list,
            "Percentile": percentile, "Rank": rank, "OutOf": out_of,
            "ItemLevelBracket": item_level_bracket,
            "ItemLevelHealingRank": ilvl_healing_rank, "ItemLevelHealingRankCount": ilvl_healing_rank_count,
            "ItemLevelHealingRankHealers": ilvl_healing_rank_rows,
            "RawHealingRank": raw_healing_rank, "RawHealingRankCount": raw_healing_rank_count,
            "RawHealingRankHealers": raw_healing_rank_rows,
            "HealerRanking": healer_ranking_rows,
            "FlaskActive": bool(consumables_data["flaskActive"]) if consumables_data else None,
            "FlaskName": consumables_data.get("flaskName") if consumables_data else None,
            "BattleElixirActive": bool(consumables_data["battleElixirActive"]) if consumables_data and "battleElixirActive" in consumables_data else None,
            "BattleElixirName": consumables_data.get("battleElixirName") if consumables_data and "battleElixirName" in consumables_data else None,
            "GuardianElixirActive": bool(consumables_data["guardianElixirActive"]) if consumables_data and "guardianElixirActive" in consumables_data else None,
            "GuardianElixirName": consumables_data.get("guardianElixirName") if consumables_data and "guardianElixirName" in consumables_data else None,
            "FoodActive": bool(consumables_data["foodActive"]) if consumables_data else None,
            "FoodName": consumables_data.get("foodName") if consumables_data else None,
            "TreeOfLifePct": consumables_data.get("treeOfLifeUptimePct") if consumables_data else None,
            "ImprovedFaerieFireUptimePct": consumables_data.get("improvedFaerieFireUptimePct") if consumables_data and "improvedFaerieFireUptimePct" in consumables_data else None,
            "BM": bm_row, "BMSpells": bm_spell_rows, "BMCooldowns": bm_cd_rows, "BMBuffs": bm_buff_row,
        }

        if gear_data and gear_data.get("gear"):
            gear_by_boss[meta.slug] = gear_data["gear"]

    # ----- Gear diff across every kill with a real gear.json -----
    gear_diff = None
    if gear_by_boss:
        boss_slugs_with_gear = list(gear_by_boss.keys())
        first_slug = boss_slugs_with_gear[0]
        slot_count = len(gear_by_boss[first_slug])
        slot_diffs = []
        for i in range(slot_count):
            variants: dict[str, dict] = {}
            for slug in boss_slugs_with_gear:
                g = gear_by_boss[slug][i]
                gem_ids = ",".join(str(gem["id"]) for gem in g.get("gems", [])) if g.get("gems") else ""
                sig = f"{g.get('id')}|{g.get('permanentEnchant')}|{g.get('temporaryEnchant')}|{gem_ids}"
                if sig not in variants:
                    variants[sig] = {"Item": g, "Bosses": []}
                variants[sig]["Bosses"].append(slug)
            if len(variants) > 1:
                variant_list = [
                    {
                        "ItemId": v["Item"].get("id"), "PermanentEnchant": v["Item"].get("permanentEnchant"),
                        "TemporaryEnchant": v["Item"].get("temporaryEnchant"), "Icon": v["Item"].get("icon"),
                        "SeenOn": v["Bosses"],
                    }
                    for v in variants.values()
                ]
                slot_diffs.append({"SlotIndex": i, "Icon": gear_by_boss[first_slug][i].get("icon"), "Variants": variant_list})
        gear_diff = {
            "BossesCompared": boss_slugs_with_gear, "SlotCount": slot_count,
            "DifferingSlots": slot_diffs, "ConsistentAcrossAllKills": len(slot_diffs) == 0,
            "BaselineGear": gear_by_boss[first_slug],
        }
    else:
        print("  WARNING: no *_gear.json files found for any boss - gear audit section will have no real data.")

    # ----- Raid-wide summaries -----
    bosses_with_ilvl = [b for b in results.values() if b["ItemLevelHealingRankCount"] > 1 and b["ItemLevelHealingRank"] is not None]
    raid_wide_ilvl_summary = None
    if bosses_with_ilvl:
        raid_wide_ilvl_summary = {
            "AvgRankPercent": _round(mean(b["Percentile"] for b in bosses_with_ilvl), 0),
            "BossesRankedFirst": sum(1 for b in bosses_with_ilvl if b["ItemLevelHealingRank"] == 1),
            "BossesCompared": len(bosses_with_ilvl),
        }

    bosses_with_raw = [b for b in results.values() if b["RawHealingRankCount"] > 1 and b["RawHealingRank"] is not None]
    raid_wide_raw_summary = None
    if bosses_with_raw:
        raid_wide_raw_summary = {
            "BossesRankedFirst": sum(1 for b in bosses_with_raw if b["RawHealingRank"] == 1),
            "BossesCompared": len(bosses_with_raw),
        }

    output = {
        "CharacterName": character_name, "ClassName": class_name, "ReportCode": report_code,
        "RaidDate": raid_date, "Bosses": results, "GearDiff": gear_diff,
        "BossesAttempted": distinct_bosses_attempted, "SpecCoverage": spec_coverage,
        "RaidWideIlvlHealingRankSummary": raid_wide_ilvl_summary,
        "RaidWideRawHealingRankSummary": raid_wide_raw_summary,
        "BenchmarkManaCostByGuid": bm_manacost_by_guid,
    }

    out_path = char_dir / f"{report_code}_report_data.json"
    jsonio.write_json(out_path, output)
    print(f"\nWrote {out_path}")
    print(f"{len(results)} boss kill(s) processed.")
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description="Port of build_boss_report_data.ps1")
    parser.add_argument("--character-name", required=True)
    parser.add_argument("--report-code", required=True)
    parser.add_argument("--class-name", required=True)
    parser.add_argument("--characters-root", default="data/Characters")
    args = parser.parse_args()

    build_report_data(args.character_name, args.report_code, args.class_name, args.characters_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
