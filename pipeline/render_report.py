"""Port of render_healer_report.ps1.

Deterministic renderer: report_data.json + {code}_analysis.json +
{code}_findings.json + the class's Jinja2 boss template + raid_overview
Jinja2 template -> docs/{healer}/{outputFolder}/healer_audit_*.html (one per
boss) + index.html (raid overview). Zero LLM involvement - every mechanical
value is derived straight from data; the only free-text content comes from
findings.json.

Jinja2 configuration choices (see the migration plan's Phase 4 risk notes):
  - autoescape=True: a deliberate, documented behavior change from the
    PowerShell original (which did zero escaping). Every findings.json field
    gets real HTML escaping now EXCEPT raid_warning_banner, which the schema
    explicitly allows <strong> markup in - marked |safe in the template.
  - undefined=StrictUndefined: Jinja2's default is to silently render a
    missing variable as blank, the OPPOSITE failure mode from the original's
    loud "unfilled {{TOKEN}}" abort. StrictUndefined raises instead, matching
    the original's zero-fabrication safety net.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from pipeline import character_themes, classes as classes_module
from pipeline import jsonio, paths, render_lib
from pipeline.numeric import round_net

# Derived from classes.py's CLASSES (the single source of truth - see that
# module's docstring) rather than duplicated here, so a new class/build only
# needs one edit instead of drifting between this file and classes.py.
CLASS_SPEC_BY_CLASS = {key: cfg.display_name for key, cfg in classes_module.CLASSES.items()}
TEMPLATE_BY_CLASS = {key: cfg.template_name for key, cfg in classes_module.CLASSES.items()}


def _thousands(value: float) -> str:
    return f"{value:,.0f}"


def _percentile_color(pct: float) -> str:
    pct = max(0, min(100, pct))
    rust = (0xB5, 0x50, 0x3A)
    gold = (0xD9, 0xB2, 0x5C)
    moss = (0x5F, 0x7A, 0x52)
    if pct <= 60:
        t = pct / 60.0
        frm, to = rust, gold
    else:
        t = (pct - 60) / 40.0
        frm, to = gold, moss
    r = round_net(frm[0] + (to[0] - frm[0]) * t, 0)
    g = round_net(frm[1] + (to[1] - frm[1]) * t, 0)
    b = round_net(frm[2] + (to[2] - frm[2]) * t, 0)
    return f"#{r:02X}{g:02X}{b:02X}"


def _rank_as_pct(rank: int, count: int) -> float:
    if count <= 1:
        return 100
    return ((count - rank) / (count - 1.0)) * 100


def _ordinal_label(n: int) -> str:
    return {1: "1st", 2: "2nd", 3: "3rd"}.get(n, f"{n}th")


def _format_cooldown_benchmark(avg_casts, used_pct, self_pct, show_self_pct: bool = True) -> str:
    if used_pct is None or used_pct == "" or float(used_pct) == 0:
        return "0 avg (never used)"
    if not show_self_pct:
        return f"{avg_casts} avg"
    self_display = round_net(float(self_pct), 0) if self_pct not in (None, "") else 0
    return f"{avg_casts} avg ({self_display}% self)"


def _validate_findings(report_data: dict, findings: dict, class_name: str) -> None:
    boss_slugs = list(report_data["Bosses"].keys())
    required_boss_keys = ["SCORECARD_FINDING", "SPELL_COMPOSITION_FINDING", "COOLDOWN_FINDING", "TARGET_FINDING", "MANA_TIMING_FINDING"]
    # Lifebloom refresh-timing (coaching Phase 2) is Druid-Restoration only -
    # confirmed absent from Dreamstate's real kit (CLAUDE.md) - never
    # required for any other pipeline class/build.
    if class_name == "Druid":
        required_boss_keys.append("LIFEBLOOM_REFRESH_FINDING")
    missing = []
    boss_findings = findings.get("BossFindings", {})
    for slug in boss_slugs:
        if slug not in boss_findings:
            missing.append(f"BossFindings.{slug} (entire boss missing)")
            continue
        bf = boss_findings[slug]
        for key in required_boss_keys:
            val = bf.get(key)
            if not val or not str(val).strip():
                missing.append(f"BossFindings.{slug}.{key}")
    raid_overview = findings.get("RaidOverview", {})
    for key in ("GEAR_CONSISTENCY_FINDING", "GEAR_FINDING_NOTE", "RAID_SUMMARY_FINDING"):
        val = raid_overview.get(key)
        if not val or not str(val).strip():
            missing.append(f"RaidOverview.{key}")
    if missing:
        lines = ["findings.json is incomplete - refusing to render a page with a placeholder or empty finding."]
        for m in missing:
            lines.append(f"  missing: {m}")
        raise ValueError("\n".join(lines))


def _compute_item_level(report_data: dict) -> Any:
    gear_diff = report_data.get("GearDiff")
    if gear_diff and gear_diff.get("BaselineGear"):
        real_items = [i for i in gear_diff["BaselineGear"] if int(i.get("id", 0)) != 0]
        if real_items:
            return round_net(sum(i["itemLevel"] for i in real_items) / len(real_items), 0)
    return "?"


def render_healer_report(
    character_name: str,
    report_code: str,
    class_name: str,
    healer_slug: str | None = None,
    raid_title: str = "SSC / TK",
    characters_root: str = "data/Characters",
    templates_root: str = "templates_jinja",
    output_root: str = "docs",
) -> Path:
    if class_name not in CLASS_SPEC_BY_CLASS:
        raise ValueError(f"'{class_name}' is not a supported class (Druid, Shaman, Priest, Paladin, Dreamstate only).")
    class_spec = CLASS_SPEC_BY_CLASS[class_name]
    if not healer_slug:
        healer_slug = character_name.lower()

    char_root = Path(characters_root) / character_name
    report_data_file = paths.find_file_recursive(char_root, f"{report_code}_report_data.json")
    if not report_data_file:
        raise FileNotFoundError(f"no {report_code}_report_data.json found under {char_root} - run build_report_data.py first.")
    char_dir = report_data_file.parent
    analysis_path = char_dir / f"{report_code}_analysis.json"
    findings_path = char_dir / f"{report_code}_findings.json"
    if not analysis_path.exists():
        raise FileNotFoundError(f"{analysis_path} not found - run build_analysis.py first.")
    if not findings_path.exists():
        raise FileNotFoundError(f"{findings_path} not found - author it first (the one step that needs real judgment).")

    report_data = jsonio.read_json(report_data_file)
    analysis = jsonio.read_json(analysis_path)
    findings = jsonio.read_json(findings_path)

    coaching_path = char_dir / f"{report_code}_coaching.json"
    coaching = jsonio.read_json_if_exists(coaching_path)
    if coaching is None:
        print(f"  WARNING: {coaching_path} not found - run `build-coaching` first for real mana-timing data. Rendering with no coaching data for every boss.")
        coaching = {"Bosses": {}}

    folder_name = char_dir.name
    raid_date_folder = folder_name

    raw_raid_date = report_data.get("RaidDate")
    raid_date_display = None
    if raw_raid_date:
        try:
            raid_date_display = render_lib.format_long_date(raw_raid_date)
        except ValueError:
            raid_date_display = raw_raid_date
    else:
        try:
            raid_date_display = render_lib.format_long_date(folder_name)
        except ValueError:
            raid_date_display = folder_name

    _validate_findings(report_data, findings, class_name)

    item_level = _compute_item_level(report_data)
    out_dir = Path(output_root) / healer_slug / raid_date_folder
    out_dir.mkdir(parents=True, exist_ok=True)

    # Boss pages and the raid overview both render one level below
    # docs/{healer_slug}/ (into docs/{healer_slug}/{report_code}/), so a
    # theme's bg_image path needs a "../" prefix to resolve from here.
    theme_style_block = character_themes.theme_style_block(character_name, path_prefix="../", bg_fill_viewport=True)
    theme_tag = character_themes.theme_tag(character_name)

    env = render_lib.make_jinja_env(templates_root)
    boss_template = env.get_template(TEMPLATE_BY_CLASS[class_name])

    full_raid_title_for_boss_pages = f"{raid_title} — {raid_date_display}"
    boss_slugs = list(report_data["Bosses"].keys())
    boss_summary_rows = []

    for slug in boss_slugs:
        boss = report_data["Bosses"][slug]
        boss_analysis = analysis["Bosses"][slug]
        bf = findings["BossFindings"][slug]
        bm = boss.get("BM")

        percentile = boss["Percentile"] if boss.get("Percentile") is not None else 0
        rank = boss["Rank"] if boss.get("Rank") else "?"
        out_of = boss["OutOf"] if boss.get("OutOf") else "?"

        ilvl_seal = None
        if boss.get("ItemLevelHealingRank") and boss.get("ItemLevelHealingRankCount", 0) > 1:
            ordinal = _ordinal_label(boss["ItemLevelHealingRank"])
            ilvl_bracket = boss.get("ItemLevelBracket") or "?"
            color = _percentile_color(_rank_as_pct(boss["ItemLevelHealingRank"], boss["ItemLevelHealingRankCount"]))
            ilvl_seal = {
                "tooltip": "Rank among the other healers in this same raid on this same fight, using WCL's own real HPS Performance Comparison (By Item Level) percentile per healer - not the Top 100 sample.",
                "ordinal": ordinal, "count": boss["ItemLevelHealingRankCount"], "color": color,
                "label": f"{percentile}% by ilvl {ilvl_bracket}",
            }

        raw_seal = None
        if boss.get("RawHealingRank") and boss.get("RawHealingRankCount", 0) > 1:
            ordinal = _ordinal_label(boss["RawHealingRank"])
            color = _percentile_color(_rank_as_pct(boss["RawHealingRank"], boss["RawHealingRankCount"]))
            raw_seal = {
                "tooltip": "Rank among the same healers in this same raid on this same fight, using real raw total healing done instead of an item-level-adjusted percentile - a genuinely independent ranking from iLvl Healing Rank, not the same number relabeled.",
                "ordinal": ordinal, "count": boss["RawHealingRankCount"], "color": color,
                "label": f"{_thousands(boss['Total'])} healing",
            }

        # ----- Spell composition -----
        spell_gaps = sorted(boss_analysis["SpellGaps"], key=lambda g: (g["CharacterPct"], g["BenchmarkPct"]), reverse=True)
        name_counts: dict[str, int] = {}
        for g in spell_gaps:
            name_counts[g["Name"]] = name_counts.get(g["Name"], 0) + 1
        spell_rows = []
        for g in spell_gaps:
            known_label = render_lib.get_known_spell_rank_label(int(g["Guid"])) if g["Guid"] is not None else None
            if known_label:
                display_name = f"{g['Name']} ({known_label})"
            elif name_counts[g["Name"]] > 1:
                display_name = f"{g['Name']} (guid {g['Guid']})"
            else:
                display_name = g["Name"]
            spell_rows.append({"name": display_name, "character_pct": g["CharacterPct"], "benchmark_pct": g["BenchmarkPct"]})

        # ----- Spell ranks -----
        rank_rows = []
        for group in boss_analysis["SpellRanks"]:
            is_first = True
            for r in group["Ranks"]:
                rank_label = r.get("RankLabel")
                display_name = f"{group['Name']} ({rank_label})" if rank_label else (group["Name"] if is_first else "")
                if r.get("ManaCost") is None:
                    mana_cost_text = "?"
                elif r.get("ManaCostSource") == "benchmark":
                    mana_cost_text = f"{r['ManaCost']} mana †"
                else:
                    mana_cost_text = f"{r['ManaCost']} mana"
                rank_rows.append({
                    "name": display_name, "mana_cost": mana_cost_text,
                    "character_pct": r["CharacterPct"], "benchmark_pct": r["BenchmarkPct"],
                })
                is_first = False

        # ----- Cooldowns -----
        cd_entries = []
        for ability_name, row in boss_analysis["Cooldowns"].items():
            if ability_name == "Tranquility" and boss_analysis.get("TranquilityInclude") is not True:
                continue
            if ability_name == "Rebirth":
                include_rebirth = bool(bf.get("IncludeRebirthRow") is True)
                if not include_rebirth:
                    continue
            cd_entries.append((ability_name, row))

        never_self_abilities = {"Rebirth"}
        cd_rows = []
        for ability_name, row in cd_entries:
            can_have_different_target = render_lib.get_cooldown_target_mode(class_name, ability_name) == "other"
            show_self_pct = can_have_different_target and ability_name not in never_self_abilities
            cd_rows.append({
                "name": ability_name, "casts": row["Count"],
                "target": row["TargetLabel"] if can_have_different_target else "—",
                "benchmark": _format_cooldown_benchmark(row["Top100AvgCasts"], row["Top100UsedPct"], row["Top100SelfPct"], show_self_pct),
            })

        bm_buffs = boss.get("BMBuffs")
        flask_label = (
            "Yes" if boss.get("FlaskActive")
            else ("Elixirs" if (boss.get("BattleElixirActive") or boss.get("GuardianElixirActive")) else "No")
        )
        flask_name_parts = []
        if boss.get("FlaskActive") and boss.get("FlaskName"):
            flask_name_parts.append(boss["FlaskName"])
        if boss.get("BattleElixirActive") and boss.get("BattleElixirName"):
            flask_name_parts.append(f"{boss['BattleElixirName']} (Battle)")
        if boss.get("GuardianElixirActive") and boss.get("GuardianElixirName"):
            flask_name_parts.append(f"{boss['GuardianElixirName']} (Guardian)")
        flask_name_text = " + ".join(flask_name_parts) if flask_name_parts else "none"
        flask_benchmark_text = "?"
        if bm_buffs:
            benchmark_parts = [f"{bm_buffs['Top100FlaskActivePct']}% flask"]
            if bm_buffs.get("Top100BattleElixirActivePct") not in (None, ""):
                benchmark_parts.append(f"{bm_buffs['Top100BattleElixirActivePct']}% Battle Elixir")
            if bm_buffs.get("Top100GuardianElixirActivePct") not in (None, ""):
                benchmark_parts.append(f"{bm_buffs['Top100GuardianElixirActivePct']}% Guardian Elixir")
            flask_benchmark_text = ", ".join(benchmark_parts)

        tree_of_life_pct = tree_of_life_benchmark_pct = None
        improved_faerie_fire_pct = improved_faerie_fire_benchmark_pct = None
        if class_name == "Druid":
            tree_of_life_pct = boss.get("TreeOfLifePct") if boss.get("TreeOfLifePct") is not None else 0
            tree_of_life_benchmark_pct = bm_buffs.get("Top100TreeOfLifeAvgUptimePct", "?") if bm_buffs else "?"
        elif class_name == "Dreamstate":
            improved_faerie_fire_pct = boss.get("ImprovedFaerieFireUptimePct") if boss.get("ImprovedFaerieFireUptimePct") is not None else 0
            improved_faerie_fire_benchmark_pct = bm_buffs.get("Top100ImprovedFaerieFireAvgUptimePct", "?") if bm_buffs else "?"

        mana_potion_count = boss_analysis["Cooldowns"].get("Mana Potion", {}).get("Count", 0)
        if mana_potion_count == 0:
            mana_detail = "none used this kill"
        elif mana_potion_count == 1:
            mana_detail = "1x Mana Potion"
        else:
            mana_detail = f"{mana_potion_count}x Mana Potion"

        hpm_dev = boss_analysis["Deviations"].get("HPM")
        if hpm_dev and hpm_dev.get("Omit") is True:
            hpm = hpm_top1 = hpm_top100avg = hpm_median = "N/A"
        else:
            hpm = boss.get("HPM") if boss.get("HPM") is not None else "N/A"
            hpm_top1 = bm.get("HPM_Top1", "?") if bm else "?"
            hpm_top100avg = bm.get("HPM_Top100Avg", "?") if bm else "?"
            hpm_median = bm.get("HPM_Median", "?") if bm else "?"

        target_rows = [{"name": r["Name"], "bar_width": r["BarWidth"], "pct": r["Pct"]} for r in boss["TargetRows"]]

        healer_rank_rows = []
        for row in boss.get("HealerRanking", []):
            char_class = "is-character" if row.get("IsCharacter") else ""
            total_tooltip = (
                f"{_thousands(row['RawHealingTotal'])} total healing" if row.get("RawHealingTotal") is not None
                else f"No raw healing data available for {row['Name']} on this kill"
            )
            pct_text = f"{row['RankPercent']}%" if row.get("RankPercent") is not None else "—"
            ilvl_text = f"{pct_text} (ilvl {row['ItemLevel']})" if row.get("ItemLevel") is not None else pct_text
            healer_rank_rows.append({
                "name": row["Name"], "char_class": char_class,
                "bar_width": row.get("BarWidth") if row.get("BarWidth") is not None else 0,
                "total_pct": f"{row['TotalPct']}%" if row.get("TotalPct") is not None else "—",
                "total_tooltip": total_tooltip, "ilvl_pct": ilvl_text,
            })

        sample_n = bm.get("SampleSize", "100") if bm else "100"

        boss_coaching = coaching.get("Bosses", {}).get(slug, {})
        mana_timing = boss_coaching.get("ManaTiming")
        missed_second_potion_window = boss_coaching.get("MissedSecondPotionWindow", False)
        lifebloom_refresh = boss_coaching.get("LifebloomRefresh")
        lifebloom_target_name = boss_coaching.get("LifebloomTargetName")

        context = {
            "raid_title": full_raid_title_for_boss_pages, "boss_name": boss["Display"],
            "healer_name": character_name, "healer_class_spec": class_spec, "item_level": item_level,
            "report_code": report_code, "fight_id": boss["FightID"],
            "duration_s": round_net(boss["Duration"] / 1000, 0),
            "percentile": percentile, "percentile_color": _percentile_color(percentile),
            "rank": rank, "out_of": out_of,
            "ilvl_seal": ilvl_seal, "raw_seal": raw_seal,
            "hps": boss["HPS"], "hps_top1": bm.get("HPS_Top1", "?") if bm else "?",
            "hps_top100avg": bm.get("HPS_Top100Avg", "?") if bm else "?", "hps_median": bm.get("HPS_Median", "?") if bm else "?",
            "overheal_pct": boss["OverhealPct"], "overheal_best": bm.get("Overheal_Best", "?") if bm else "?",
            "overheal_median": bm.get("Overheal_Median", "?") if bm else "?", "overheal_worst": bm.get("Overheal_Worst", "?") if bm else "?",
            "total_healing": _thousands(boss["Total"]),
            "active_time_pct": boss["ActiveTimePct"] if boss.get("ActiveTimePct") is not None else "?",
            "active_time_top1": bm.get("ActiveTime_Top1", "?") if bm else "?",
            "active_time_top100avg": bm.get("ActiveTime_Top100Avg", "?") if bm else "?",
            "active_time_median": bm.get("ActiveTime_Median", "?") if bm else "?",
            "death_count": boss["DeathCount"] if boss.get("DeathCount") is not None else 0,
            "scorecard_finding": bf["SCORECARD_FINDING"],
            "spell_rows": spell_rows, "spell_composition_finding": bf["SPELL_COMPOSITION_FINDING"],
            "rank_rows": rank_rows,
            "cd_rows": cd_rows,
            "flask_active": flask_label, "flask_name": flask_name_text, "flask_benchmark_pct": flask_benchmark_text,
            "food_active": "Yes" if boss.get("FoodActive") else "No", "food_name": boss.get("FoodName") or "none",
            "food_benchmark_pct": bm_buffs.get("Top100FoodActivePct", "?") if bm_buffs else "?",
            "tree_of_life_pct": tree_of_life_pct, "tree_of_life_benchmark_pct": tree_of_life_benchmark_pct,
            "improved_faerie_fire_pct": improved_faerie_fire_pct, "improved_faerie_fire_benchmark_pct": improved_faerie_fire_benchmark_pct,
            "mana_consumable_count": mana_potion_count, "mana_consumable_detail": mana_detail,
            "hpm": hpm, "hpm_top1": hpm_top1, "hpm_top100avg": hpm_top100avg, "hpm_median": hpm_median,
            "cooldown_finding": bf["COOLDOWN_FINDING"],
            "coverage_pct": boss["CoveragePct"], "benchmark_coverage_pct": bm.get("Top100_TargetCoveragePct", "?") if bm else "?",
            "benchmark_top1_pct": bm.get("Top100_TargetTop1Pct", "?") if bm else "?",
            "target_rows": target_rows, "target_finding": bf["TARGET_FINDING"],
            "healer_rank_rows": healer_rank_rows,
            "benchmark_n": sample_n,
            "theme_style_block": theme_style_block, "theme_tag": theme_tag,
            "mana_timing": mana_timing, "missed_second_potion_window": missed_second_potion_window,
            "mana_timing_finding": bf["MANA_TIMING_FINDING"],
            "lifebloom_refresh": lifebloom_refresh, "lifebloom_target_name": lifebloom_target_name,
            "lifebloom_refresh_finding": bf.get("LIFEBLOOM_REFRESH_FINDING"),
        }

        # Note: no post-render scan for a literal "{{" here (the PowerShell
        # original had one) - undefined=StrictUndefined above already raises
        # immediately on any unfilled template variable, which is the actual
        # failure mode this was guarding against. A textual "{{" scan risks a
        # false positive on legitimate findings.json prose that happens to
        # quote template syntax, for no real extra safety.
        page_html = boss_template.render(**context)

        out_path = out_dir / f"healer_audit_{slug}.html"
        jsonio.write_text(out_path, page_html)
        print(f"Wrote {out_path}")

        overheal_high_class = (
            " overheal-cell high"
            if boss_analysis["Deviations"].get("Overheal", {}).get("Flag") == "exceeds_worst" else ""
        )
        ilvl_healing_rank_label = (
            f"{_ordinal_label(boss['ItemLevelHealingRank'])}/{boss['ItemLevelHealingRankCount']}"
            if boss.get("ItemLevelHealingRank") and boss.get("ItemLevelHealingRankCount", 0) > 1 else "—"
        )
        raw_healing_rank_label = (
            f"{_ordinal_label(boss['RawHealingRank'])}/{boss['RawHealingRankCount']}"
            if boss.get("RawHealingRank") and boss.get("RawHealingRankCount", 0) > 1 else "—"
        )
        boss_summary_rows.append({
            "slug": slug, "boss_name": boss["Display"], "hps": boss["HPS"],
            "overheal_high_class": overheal_high_class, "overheal_pct": boss["OverhealPct"], "percentile": percentile,
            "ilvl_healing_rank_label": ilvl_healing_rank_label, "raw_healing_rank_label": raw_healing_rank_label,
        })

    # ===== Raid overview =====
    overview_template = env.get_template("raid_overview.html.jinja")

    n_kills = len(boss_slugs)
    bosses_attempted = report_data.get("BossesAttempted") or n_kills
    bosses_killed_label = f"{n_kills}/{bosses_attempted} bosses killed" if bosses_attempted > n_kills else f"{n_kills} bosses killed"

    spec_coverage_note = None
    spec_coverage = report_data.get("SpecCoverage")
    if spec_coverage:
        excluded = spec_coverage.get("ExcludedBosses", [])
        if excluded:
            excluded_specs = list(dict.fromkeys(b["Spec"] for b in excluded))
            other_spec_label = excluded_specs[0] if len(excluded_specs) == 1 else "/".join(excluded_specs)
            spec_coverage_note = (
                f"{character_name} played a different spec ({other_spec_label}) on {len(excluded)} of "
                f"{spec_coverage['TotalBossesInReport']} bosses this raid - only the {spec_coverage['BossesAnalyzed']} "
                f"kill(s) where they were in their healing spec ({spec_coverage['AnalyzedSpec']}) are analyzed below."
            )

    # ----- Gear checklist -----
    gear_items = []
    total_slots = 19
    gear_diff = report_data.get("GearDiff")
    filled_count = total_slots
    if gear_diff and gear_diff.get("BaselineGear"):
        filled_count = sum(1 for i in gear_diff["BaselineGear"] if int(i.get("id", 0)) != 0)
    gear_items.append({
        "icon": "ok", "glyph": "✓",
        "description": f"{filled_count} of {total_slots} real equipment slots filled in the baseline loadout "
                        f"(shirt and tabard are typically the two genuinely empty cosmetic slots, no stat impact)",
        "detail": f"avg ilvl {item_level}", "long_detail": "",
    })
    gear_analysis = analysis["GearAnalysis"]
    if gear_analysis.get("EnchantableSlotCount", 0) > 0:
        enchanted_count = gear_analysis["EnchantedSlotCount"]
        enchantable_count = gear_analysis["EnchantableSlotCount"]
        ok = enchanted_count == enchantable_count
        gear_items.append({
            "icon": "ok" if ok else "note", "glyph": "✓" if ok else "i",
            "description": f"{enchanted_count} of {enchantable_count} enchantable slots carry a permanent enchant",
            "detail": "", "long_detail": "",
        })
    consumable_setup = gear_analysis.get("ConsumableSetup")
    if consumable_setup:
        cs = consumable_setup
        if cs["IncompleteBosses"]:
            gear_items.append({
                "icon": "bad", "glyph": "✗",
                "description": f"{cs['CompleteCount']} of {cs['TotalBosses']} kills had a complete consumable setup (Flask, or Battle + Guardian Elixir together)",
                "detail": "", "long_detail": f"Missing on: {', '.join(cs['IncompleteBosses'])}.",
            })
        elif cs["UnknownCount"] > 0:
            gear_items.append({
                "icon": "note", "glyph": "i",
                "description": f"Consumable setup (Flask, or Battle + Guardian Elixir) could only be confirmed on {cs['CompleteCount']} of {cs['TotalBosses']} kills",
                "detail": "", "long_detail": f"The remaining {cs['UnknownCount']} kill(s) were pulled before the elixir-classification fix and can't be verified either way from the data on disk - not a real gap, just an unresolved data gap. Re-pull to resolve.",
            })
        else:
            gear_items.append({
                "icon": "ok", "glyph": "✓",
                "description": f"{cs['CompleteCount']} of {cs['TotalBosses']} kills had a complete consumable setup (Flask, or Battle + Guardian Elixir together)",
                "detail": "", "long_detail": "",
            })
    for flag in gear_analysis.get("MissingEnchantFlags", []):
        gear_items.append({
            "icon": "bad", "glyph": "✗",
            "description": f"{flag['SlotName']} carries no permanent enchant",
            "detail": f"item {flag['ItemId']}", "long_detail": "",
        })
    for extra in findings["RaidOverview"].get("GearCheckItems", []) or []:
        icon = extra["Icon"]
        if icon not in ("ok", "bad", "note"):
            raise ValueError(f"Invalid GearCheckItems Icon '{icon}' - must be ok|bad|note.")
        glyph = {"ok": "✓", "bad": "✗", "note": "i"}[icon]
        gear_items.append({
            "icon": icon, "glyph": glyph, "description": extra["Description"],
            "detail": extra.get("Detail") or "", "long_detail": extra.get("LongDetail") or "",
        })

    ilvl_summary_text = None
    if report_data.get("RaidWideIlvlHealingRankSummary"):
        rws = report_data["RaidWideIlvlHealingRankSummary"]
        ilvl_summary_text = (
            f"iLvl Healing Rank: across the {rws['BossesCompared']} kill(s) with another tracked-spec healer present, "
            f"{character_name} ranked #1 (by WCL's own HPS Performance Comparison by Item Level) on "
            f"{rws['BossesRankedFirst']} of them, averaging the {rws['AvgRankPercent']}th percentile by item level across those kills."
        )
    raw_summary_text = None
    if report_data.get("RaidWideRawHealingRankSummary"):
        rws = report_data["RaidWideRawHealingRankSummary"]
        raw_summary_text = (
            f"Raw Healing Rank: across the {rws['BossesCompared']} kill(s) with another tracked-spec healer present, "
            f"{character_name} ranked #1 by real raw total healing done on {rws['BossesRankedFirst']} of them."
        )

    warning_banner = findings["RaidOverview"].get("RAID_WARNING_BANNER")

    overview_context = {
        "raid_title": raid_title, "raid_date_display": raid_date_display, "healer_name": character_name,
        "healer_class_spec": class_spec, "item_level": item_level, "report_code": report_code,
        "n_kills": n_kills, "bosses_killed_label": bosses_killed_label,
        "spec_coverage_note": spec_coverage_note,
        "gear_consistency_finding": findings["RaidOverview"]["GEAR_CONSISTENCY_FINDING"],
        "gear_items": gear_items, "gear_finding_note": findings["RaidOverview"]["GEAR_FINDING_NOTE"],
        "ilvl_healing_rank_summary": ilvl_summary_text, "raw_healing_rank_summary": raw_summary_text,
        "raid_warning_banner": warning_banner,
        "boss_summary_rows": boss_summary_rows, "raid_summary_finding": findings["RaidOverview"]["RAID_SUMMARY_FINDING"],
        "theme_style_block": theme_style_block, "theme_tag": theme_tag,
    }

    overview_html = overview_template.render(**overview_context)

    overview_out_path = out_dir / "index.html"
    jsonio.write_text(overview_out_path, overview_html)
    print(f"Wrote {overview_out_path}")

    print()
    print(f"Done. Rendered {n_kills} boss page(s) + raid overview to {out_dir}")
    return out_dir


def main() -> int:
    parser = argparse.ArgumentParser(description="Port of render_healer_report.ps1")
    parser.add_argument("--character-name", required=True)
    parser.add_argument("--report-code", required=True)
    parser.add_argument("--class-name", required=True)
    parser.add_argument("--healer-slug", default=None)
    parser.add_argument("--raid-title", default="SSC / TK")
    parser.add_argument("--characters-root", default="data/Characters")
    parser.add_argument("--templates-root", default="templates_jinja")
    parser.add_argument("--output-root", default="docs")
    args = parser.parse_args()

    render_healer_report(
        args.character_name, args.report_code, args.class_name, args.healer_slug,
        args.raid_title, args.characters_root, args.templates_root, args.output_root,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
