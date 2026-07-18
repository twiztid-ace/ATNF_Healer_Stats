"""Port of summarize_class_benchmarks.ps1.

Reads the raw Top 100 data pulled by pull_top100.py and computes the derived
benchmark stats used everywhere downstream, writing 5 CSVs to
data/Classes/{Class}/active/ (or data/Classes/{Class}/{DateFolder}/ in legacy
mode via --date-folder).

Field/column names below are deliberately kept identical to the PowerShell
original's CSV headers, for parity-diffing against real PowerShell-generated
CSVs. The "median" computed here is deliberately NOT statistics.median() -
it replicates the PS original's exact (non-textbook) index-based pick
(`sorted[n // 2]` on a pre-sorted list) so output matches exactly.
"""

from __future__ import annotations

import argparse
import shutil
from datetime import date
from pathlib import Path
from typing import Any

from pipeline import bosses as bosses_module
from pipeline import classes as classes_module
from pipeline import csvio, jsonio
from pipeline.numeric import round_net

MANA_POTION_NAME = "Restore Mana"


def _is_ascii(s: str | None) -> bool:
    if s is None:
        return False
    return s.isascii()


def _add_guid_aggregate(agg: dict[int, dict], guid: int, name: str, amount: float) -> None:
    """Prefers an ASCII display name when multiple locales are seen for the
    same guid (Lifebloom was seen under 7 different names in real data)."""
    if guid not in agg:
        agg[guid] = {"Name": name, "Total": 0.0}
    else:
        if not _is_ascii(agg[guid]["Name"]) and _is_ascii(name):
            agg[guid]["Name"] = name
    agg[guid]["Total"] += amount


def _blank(value, digits: int) -> Any:
    return round_net(value, digits) if value is not None else None


def summarize_benchmarks(
    class_name: str,
    classes_root_override: str | None = None,
    date_folder: str | None = None,
) -> None:
    classes_root = classes_root_override if classes_root_override else "data/Classes"
    class_dir = Path(classes_root) / class_name
    today = date.today().isoformat()
    using_active_model = not date_folder

    manifest = None
    prior_generated_date = None

    if using_active_model:
        work_dir = class_dir / "active"
        archived_dir = class_dir / "archived"
        manifest_path = class_dir / "manifest.json"

        if not work_dir.exists():
            raise FileNotFoundError(
                f"{work_dir} not found. Either run pull_top100.py first (it creates "
                f"active/manifest.json), or pass --date-folder if this class is still "
                f"on the old date-stamped-folder convention."
            )
        if not manifest_path.exists():
            raise FileNotFoundError(f"{manifest_path} not found - needed for staleness tracking.")

        manifest = jsonio.read_json(manifest_path)
        prior_generated_date = manifest.get("benchmarkGeneratedDate")
        if prior_generated_date == today:
            print(f"Benchmark already generated today ({today}) - regenerating anyway (recomputation is free), "
                  f"same-day re-run won't create a new history snapshot.")
        elif prior_generated_date is None:
            print("No prior benchmark generation recorded - this will be the first.")
        else:
            print(f"Benchmark last generated {prior_generated_date} - STALE relative to today ({today}), regenerating.")
    else:
        work_dir = class_dir / date_folder
        if not work_dir.exists():
            raise FileNotFoundError(f"{work_dir} not found.")
        print(f"Using the old date-folder convention ({date_folder}) - no manifest/staleness tracking or CSV history for this class yet.")
    print()

    cfg = classes_module.get(class_name)
    cooldown_guids = cfg.cooldown_guids
    mana_potion_name = MANA_POTION_NAME
    has_buff_uptime = "TreeOfLife" in cfg.active_stat_blocks
    has_debuff_uptime = "ImprovedFaerieFire" in cfg.active_stat_blocks

    # boss folder name -> (rankings filename, display name), same order as
    # the PS original's $bosses table (Gruul's Lair/Magtheridon's Lair first,
    # then SSC/TK) - matches pipeline/bosses.py's own definition order.
    bosses_table = {meta.folder_name: meta for meta in bosses_module.BOSSES.values()}

    summary_rows: list[dict] = []
    spell_comp_rows: list[dict] = []
    cooldown_rows: list[dict] = []
    buff_rows: list[dict] = []
    mana_cost_by_guid_agg: dict[str, dict] = {}

    for boss_folder, meta in bosses_table.items():
        boss_name = meta.display
        boss_dir = work_dir / boss_folder
        rankings_file = work_dir / meta.rankings_file

        if not boss_dir.exists():
            print(f"SKIP: {boss_dir} not found.")
            continue
        if not rankings_file.exists():
            print(f"SKIP: {rankings_file} not found (needed for duration/HPS) - rankings pull may have failed.")
            continue

        rankings_data = jsonio.read_json(rankings_file)
        if "error" in rankings_data:
            print(f"SKIP: {boss_folder} rankings file contains an API error, not a rankings list.")
            continue
        rankings = rankings_data["rankings"]

        healing_files = sorted(boss_dir.glob("*_healing_events.json"))
        print(f"Processing {boss_name} ({len(healing_files)} healing event files)...")

        casts_fail_count = 0
        consumables_fail_count = 0
        records: list[dict] = []

        for file in healing_files:
            try:
                healing_data = jsonio.read_json(file)
            except Exception:
                continue
            player_name = healing_data.get("sourceName")
            if not player_name:
                continue

            name_parts = file.stem.split("_", 2)
            report_id = name_parts[0]
            fight_id = int(name_parts[1])

            rank_match = next(
                (r for r in rankings if r["reportID"] == report_id and r["fightID"] == fight_id and r["name"] == player_name),
                None,
            )
            if not rank_match:
                print(f"  WARNING: no rankings entry matched for {player_name} ({report_id}/{fight_id}) - skipping (can't get duration/HPS).")
                continue

            total = healing_data.get("totalAmount", 0)
            overheal = healing_data.get("totalOverheal", 0)
            raw = total + overheal
            overheal_pct = (overheal / raw) * 100 if raw > 0 else 0
            hps = total / (rank_match["duration"] / 1000) if rank_match["duration"] > 0 else 0

            # ----- Spell composition, by guid -----
            abilities: dict[int, dict] = {}
            targets: dict[str, float] = {}
            for ev in healing_data.get("events", []):
                ability = ev.get("ability")
                amount = ev.get("amount")
                if ability and amount:
                    _add_guid_aggregate(abilities, ability["guid"], ability["name"], amount)
                target_name = ev.get("targetName")
                if target_name and amount:
                    targets[target_name] = targets.get(target_name, 0.0) + amount
            sorted_targets = sorted(targets.items(), key=lambda kv: kv[1], reverse=True)
            top5_sum = sum(v for _, v in sorted_targets[:5])
            coverage_pct = (top5_sum / total) * 100 if total > 0 else 0
            top1_pct = (sorted_targets[0][1] / total) * 100 if sorted_targets and total > 0 else 0

            # ----- Cooldowns/utility/consumables, from *_casts_events.json -----
            cooldown_counts = None
            casts_file = file.with_name(file.name.replace("_healing_events.json", "_casts_events.json"))
            mana_spent = None
            if casts_file.exists():
                try:
                    casts_data = jsonio.read_json(casts_file)

                    mana_spent = 0.0
                    for ev in casts_data.get("events", []):
                        resources = ev.get("classResources")
                        if resources and len(resources) > 0:
                            cost = resources[0]["max"]
                            mana_spent += cost
                            ability = ev.get("ability")
                            if ability and ability.get("guid"):
                                guid_key = str(ability["guid"])
                                if guid_key not in mana_cost_by_guid_agg:
                                    mana_cost_by_guid_agg[guid_key] = {
                                        "Guid": ability["guid"], "Name": ability["name"],
                                        "ManaCost": cost, "SampleCount": 1,
                                    }
                                else:
                                    entry = mana_cost_by_guid_agg[guid_key]
                                    entry["SampleCount"] += 1
                                    existing = entry["ManaCost"]
                                    if existing != cost:
                                        if existing == 0 and cost != 0:
                                            entry["ManaCost"] = cost
                                        elif cost != 0:
                                            print(f"  NOTE: guid {guid_key} ({ability['name']}) mana cost varies "
                                                  f"across the sample: {existing} vs {cost} - keeping {existing}.")

                    cooldown_counts = {}
                    for cd_name, guid_list in cooldown_guids.items():
                        matched = (
                            [ev for ev in casts_data.get("events", [])
                             if ev.get("ability", {}).get("guid") in guid_list and ev.get("type") != "begincast"]
                            if len(guid_list) > 0 else []
                        )
                        self_count = sum(
                            1 for ev in matched
                            if ev.get("sourceName") == ev.get("targetName")
                            or not ev.get("targetName")
                            or ev.get("targetName") == "Environment"
                        )
                        cooldown_counts[cd_name] = {"Count": len(matched), "SelfCount": self_count}
                    mana_matched = [ev for ev in casts_data.get("events", []) if ev.get("ability", {}).get("name") == mana_potion_name]
                    cooldown_counts["Mana Potion"] = {"Count": len(mana_matched), "SelfCount": len(mana_matched)}
                except Exception:
                    casts_fail_count += 1
                    cooldown_counts = None

            # ----- Self-buff uptime, from *_consumables.json -----
            buff_uptimes = None
            consumables_file = file.with_name(file.name.replace("_healing_events.json", "_consumables.json"))
            if consumables_file.exists():
                try:
                    consumables_data = jsonio.read_json(consumables_file)
                    buff_uptimes = {
                        "FlaskActive": bool(consumables_data.get("flaskActive")),
                        "BattleElixirActive": bool(consumables_data["battleElixirActive"]) if "battleElixirActive" in consumables_data else None,
                        "GuardianElixirActive": bool(consumables_data["guardianElixirActive"]) if "guardianElixirActive" in consumables_data else None,
                        "FoodActive": bool(consumables_data.get("foodActive")),
                    }
                    if has_buff_uptime:
                        buff_uptimes["TreeOfLifePct"] = consumables_data.get("treeOfLifeUptimePct")
                    if has_debuff_uptime:
                        buff_uptimes["ImprovedFaerieFirePct"] = consumables_data.get("improvedFaerieFireUptimePct")
                except Exception:
                    consumables_fail_count += 1
                    buff_uptimes = None

            hpm = total / mana_spent if (mana_spent and mana_spent > 0) else None

            # ----- Active Time, from *_activetime.json -----
            active_time_pct = None
            active_time_file = file.with_name(file.name.replace("_healing_events.json", "_activetime.json"))
            if active_time_file.exists():
                try:
                    active_time_data = jsonio.read_json(active_time_file)
                    active_time_pct = active_time_data.get("activeTimePct")
                except Exception:
                    active_time_pct = None

            records.append({
                "PlayerName": player_name, "HPS": hps, "HPM": hpm, "OverhealPct": overheal_pct,
                "CoveragePct": coverage_pct, "Top1Pct": top1_pct, "ActiveTimePct": active_time_pct,
                "Abilities": abilities, "Cooldowns": cooldown_counts, "BuffUptimes": buff_uptimes,
            })

        if not records:
            continue
        if casts_fail_count > 0:
            print(f"  WARNING: {casts_fail_count} casts_events files for {boss_name} failed to parse - those players excluded from the cooldown aggregate only.")
        if consumables_fail_count > 0:
            print(f"  WARNING: {consumables_fail_count} consumables files for {boss_name} failed to parse - those players excluded from the buff aggregate only.")

        sorted_recs = sorted(records, key=lambda r: r["HPS"], reverse=True)
        n = len(sorted_recs)
        top1 = sorted_recs[0]["HPS"]
        top100_avg = sum(r["HPS"] for r in sorted_recs) / n
        median = sorted_recs[n // 2]["HPS"]

        oh_sorted = sorted(records, key=lambda r: r["OverhealPct"])
        oh_best = oh_sorted[0]["OverhealPct"]
        oh_median = oh_sorted[n // 2]["OverhealPct"]
        oh_worst = oh_sorted[n - 1]["OverhealPct"]

        cov_avg = sum(r["CoveragePct"] for r in sorted_recs) / n
        top1_pct_avg = sum(r["Top1Pct"] for r in sorted_recs) / n

        sample_with_hpm = [r for r in sorted_recs if r["HPM"] is not None]
        hpm_sample_used = len(sample_with_hpm)
        hpm_top1 = hpm_top100_avg = hpm_median = None
        if hpm_sample_used > 0:
            hpm_sorted = sorted(sample_with_hpm, key=lambda r: r["HPM"], reverse=True)
            hpm_top1 = hpm_sorted[0]["HPM"]
            hpm_top100_avg = sum(r["HPM"] for r in sample_with_hpm) / hpm_sample_used
            hpm_median = hpm_sorted[hpm_sample_used // 2]["HPM"]

        sample_with_active_time = [r for r in sorted_recs if r["ActiveTimePct"] is not None]
        active_time_sample_used = len(sample_with_active_time)
        at_top1 = at_top100_avg = at_median = None
        if active_time_sample_used > 0:
            at_sorted = sorted(sample_with_active_time, key=lambda r: r["ActiveTimePct"], reverse=True)
            at_top1 = at_sorted[0]["ActiveTimePct"]
            at_top100_avg = sum(r["ActiveTimePct"] for r in sample_with_active_time) / active_time_sample_used
            at_median = at_sorted[active_time_sample_used // 2]["ActiveTimePct"]

        summary_rows.append({
            "Boss": boss_name,
            "HPS_Top1": round_net(top1, 0), "HPS_Top100Avg": round_net(top100_avg, 0), "HPS_Median": round_net(median, 0),
            "HPM_Top1": _blank(hpm_top1, 2), "HPM_Top100Avg": _blank(hpm_top100_avg, 2), "HPM_Median": _blank(hpm_median, 2),
            "ActiveTime_Top1": _blank(at_top1, 1), "ActiveTime_Top100Avg": _blank(at_top100_avg, 1), "ActiveTime_Median": _blank(at_median, 1),
            "Overheal_Best": round_net(oh_best, 1), "Overheal_Median": round_net(oh_median, 1), "Overheal_Worst": round_net(oh_worst, 1),
            "Top100_TargetCoveragePct": round_net(cov_avg, 1), "Top100_TargetTop1Pct": round_net(top1_pct_avg, 1),
            "SampleSize": n, "HPM_SampleUsed": hpm_sample_used, "ActiveTime_SampleUsed": active_time_sample_used,
        })

        # ----- Spell composition aggregate, strictly by guid -----
        spell_agg: dict[int, dict] = {}
        spell_total = 0.0
        for r in sorted_recs:
            for guid, a in r["Abilities"].items():
                _add_guid_aggregate(spell_agg, guid, a["Name"], a["Total"])
                spell_total += a["Total"]
        name_counts: dict[str, int] = {}
        for guid, a in spell_agg.items():
            name_counts[a["Name"]] = name_counts.get(a["Name"], 0) + 1
        for guid, a in spell_agg.items():
            pct = (a["Total"] / spell_total) * 100 if spell_total > 0 else 0
            if pct >= 0.5:
                display_name = a["Name"]
                if name_counts[display_name] > 1:
                    display_name = f"{display_name} (guid {guid})"
                spell_comp_rows.append({"Boss": boss_name, "Spell": display_name, "Top100Pct": round_net(pct, 1)})

        # ----- Cooldowns/utility/consumables aggregate -----
        cd_names = list(cooldown_guids.keys()) + ["Mana Potion"]
        sample_with_cooldowns = [r for r in sorted_recs if r["Cooldowns"] is not None]
        cd_sample_used = len(sample_with_cooldowns)
        for cd_name in cd_names:
            if cd_sample_used == 0:
                continue
            counts = [r["Cooldowns"][cd_name]["Count"] for r in sample_with_cooldowns]
            self_counts = [r["Cooldowns"][cd_name]["SelfCount"] for r in sample_with_cooldowns]
            avg_casts = sum(counts) / len(counts)
            used_count = sum(1 for c in counts if c > 0)
            used_pct = (used_count / cd_sample_used) * 100
            total_casts = sum(counts)
            total_self = sum(self_counts)
            self_pct = (total_self / total_casts) * 100 if total_casts > 0 else None
            cooldown_rows.append({
                "Boss": boss_name, "Ability": cd_name,
                "Top100AvgCasts": round_net(avg_casts, 1), "Top100UsedPct": round_net(used_pct, 0),
                "Top100SelfPct": _blank(self_pct, 0), "SampleUsed": cd_sample_used,
            })

        # ----- Self-buff uptime aggregate -----
        sample_with_buffs = [r for r in sorted_recs if r["BuffUptimes"] is not None]
        buff_sample_used = len(sample_with_buffs)
        if buff_sample_used > 0:
            flask_count = sum(1 for r in sample_with_buffs if r["BuffUptimes"]["FlaskActive"])
            food_count = sum(1 for r in sample_with_buffs if r["BuffUptimes"]["FoodActive"])
            battle_elixir_sample = [r for r in sample_with_buffs if r["BuffUptimes"]["BattleElixirActive"] is not None]
            guardian_elixir_sample = [r for r in sample_with_buffs if r["BuffUptimes"]["GuardianElixirActive"] is not None]
            battle_elixir_count = sum(1 for r in battle_elixir_sample if r["BuffUptimes"]["BattleElixirActive"])
            guardian_elixir_count = sum(1 for r in guardian_elixir_sample if r["BuffUptimes"]["GuardianElixirActive"])

            buff_row: dict[str, Any] = {
                "Boss": boss_name,
                "Top100FlaskActivePct": round_net((flask_count / buff_sample_used) * 100, 0),
                "Top100BattleElixirActivePct": round_net((battle_elixir_count / len(battle_elixir_sample)) * 100, 0) if battle_elixir_sample else None,
                "Top100GuardianElixirActivePct": round_net((guardian_elixir_count / len(guardian_elixir_sample)) * 100, 0) if guardian_elixir_sample else None,
                "Top100FoodActivePct": round_net((food_count / buff_sample_used) * 100, 0),
            }
            if has_buff_uptime:
                tree_vals = [r["BuffUptimes"]["TreeOfLifePct"] for r in sample_with_buffs if r["BuffUptimes"].get("TreeOfLifePct") is not None]
                tree_avg = sum(tree_vals) / len(tree_vals) if tree_vals else 0
                buff_row["Top100TreeOfLifeAvgUptimePct"] = round_net(tree_avg, 1)
            if has_debuff_uptime:
                iff_vals = [r["BuffUptimes"]["ImprovedFaerieFirePct"] for r in sample_with_buffs if r["BuffUptimes"].get("ImprovedFaerieFirePct") is not None]
                iff_avg = sum(iff_vals) / len(iff_vals) if iff_vals else 0
                buff_row["Top100ImprovedFaerieFireAvgUptimePct"] = round_net(iff_avg, 1)
            buff_row["SampleUsed"] = buff_sample_used
            buff_rows.append(buff_row)
        else:
            print(f"  NOTE: no buff data aggregated for {boss_name} (no players had a parseable consumables file).")

    out_summary = work_dir / "benchmark_summary.csv"
    out_spells = work_dir / "benchmark_spell_composition.csv"
    out_cooldowns = work_dir / "benchmark_cooldowns.csv"
    out_buffs = work_dir / "benchmark_buffs.csv"
    out_manacost = work_dir / "benchmark_manacost_by_guid.csv"

    # ----- Archive the previous CSV set before overwriting - active-model only -----
    if using_active_model and out_summary.exists() and prior_generated_date and prior_generated_date != today:
        history_dir = archived_dir / "benchmark_history" / prior_generated_date
        history_dir.mkdir(parents=True, exist_ok=True)
        for f in (out_summary, out_spells, out_cooldowns, out_buffs, out_manacost):
            if f.exists():
                shutil.copy2(f, history_dir)
        print(f"Archived previous ({prior_generated_date}) benchmark CSVs to {history_dir}")

    csvio.write_csv(out_summary, summary_rows)
    csvio.write_csv(
        out_spells,
        sorted(spell_comp_rows, key=lambda r: (r["Boss"], -r["Top100Pct"])),
    )
    csvio.write_csv(out_cooldowns, sorted(cooldown_rows, key=lambda r: (r["Boss"], r["Ability"])))
    csvio.write_csv(out_buffs, sorted(buff_rows, key=lambda r: r["Boss"]))
    manacost_rows = sorted(mana_cost_by_guid_agg.values(), key=lambda r: (r["Name"] or "", r["Guid"]))
    csvio.write_csv(out_manacost, manacost_rows)

    if using_active_model:
        manifest["benchmarkGeneratedDate"] = today
        jsonio.write_json(manifest_path, manifest)

    print()
    print("Done. Wrote:")
    print(f"  {out_summary}")
    print(f"  {out_spells}")
    print(f"  {out_cooldowns}")
    print(f"  {out_buffs}")
    if using_active_model:
        print(f"Updated manifest.json benchmarkGeneratedDate -> {today}")
    print()
    print("Upload all four CSVs to project knowledge - small, text-based, no zip needed.")


def main() -> int:
    parser = argparse.ArgumentParser(description="Port of summarize_class_benchmarks.ps1")
    parser.add_argument("--class-name", required=True)
    parser.add_argument("--classes-root-override", default=None)
    parser.add_argument("--date-folder", default=None)
    args = parser.parse_args()

    summarize_benchmarks(args.class_name, args.classes_root_override, args.date_folder)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
