"""Port of pull_character_TEMPLATE.ps1.

Pulls one healer's full raid night: fight list, real per-fight rankings
(also the only source of per-fight spec - a character can play more than
one real spec across a report's boss kills, a confirmed real case, see
pull_character_TEMPLATE.ps1's own STEP 3b comment), then per-boss-kill
healing/casts events, consumables+gear snapshot, active time (with
same-raid tracked-healer raw-healing comparison data), and deaths.

RunspacePool -> concurrent.futures.ThreadPoolExecutor, same as
pull_top100.py. Unlike that script, this one does NOT promote its
ability-name cache to a shared/locked structure across workers - only
~9-10 workers run per character pull (one per boss kill), so the
redundant-lookup cost is genuinely negligible at this scale (matching the
original's own documented reasoning for the same asymmetry).
"""

from __future__ import annotations

import argparse
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, TypedDict

from pipeline import bosses as bosses_module
from pipeline import classes as classes_module
from pipeline import jsonio, paths, wcl_api
from pipeline.numeric import round_net


class PullCharacterResult(TypedDict):
    out_dir: Path
    wcl_class_name: str | None
    resolved_spec: str | None
    pipeline_class_name: str | None
    raid_date: str
    boss_fights_count: int
    total_done: int
    total_failed: int


TREE_OF_LIFE_GUID = 33891
IMPROVED_FAERIE_FIRE_GUID = 26993
HEALING_TOUCH_GUID = 26979
TRACKED_HEALER_ICONS = {
    "Druid-Restoration", "Druid-Dreamstate", "Shaman-Restoration",
    "Priest-Holy", "Priest-Discipline", "Paladin-Holy",
}


def _resolve_pipeline_class_name(wcl_class_name: str | None, wcl_spec_name: str | None) -> str | None:
    """Maps a real (WCL className, WCL specName) pair to this pipeline's own
    class key (e.g. ("Druid", "Dreamstate") -> "Dreamstate", ("Druid",
    "Restoration") -> "Druid") - the split every downstream step (build_report_data,
    build_analysis, render_report, pull_top100) needs but the PowerShell
    original never persisted anywhere, relying on a human reading console
    output instead (see the generate-healer-report skill's "note the resolved
    class" step). Returns None if no config matches (unsupported class/spec)."""
    if not wcl_class_name or not wcl_spec_name:
        return None
    for key, cfg in classes_module.CLASSES.items():
        if cfg.wcl_class_name == wcl_class_name and cfg.wcl_spec_name == wcl_spec_name:
            return key
    return None


def _get_boss_slug(boss_id: int, boss_name: str) -> str:
    meta = bosses_module.BOSSES.get(boss_id)
    if meta:
        return meta.slug
    return re.sub(r"[^a-z0-9]", "", boss_name.lower())


def _resolve_ability_name_local(guid: int, cache: dict, access_token: str) -> dict:
    key = int(guid)
    if key in cache:
        return cache[key]
    q = f"query {{ gameData {{ ability(id: {key}) {{ name icon }} }} }}"
    r = wcl_api.invoke_wcl_graphql(q, access_token=access_token)
    entry = {"name": None, "icon": None}
    if not r.errors and r.data and r.data.get("gameData", {}).get("ability"):
        entry["name"] = r.data["gameData"]["ability"]["name"]
        entry["icon"] = r.data["gameData"]["ability"]["icon"]
    cache[key] = entry
    return entry


def _get_tree_of_life_events(report_code: str, character_id: int, report_start: int, report_end: int, access_token: str) -> list[dict]:
    """Fetches the report-wide real Tree of Life buff events (one API call,
    reused across every fight below) - but does NOT reconstruct continuous
    report-wide intervals from them anymore. A single continuous reconstruction
    across the whole report conflated "no applybuff/removebuff event fired
    near this fight" with "genuinely out of the buff", which is wrong: this
    realm's "Incarnation: Tree of Life" is a real, re-castable ability, and a
    fight with zero real toggle events can mean EITHER "still up from an
    earlier cast, nothing changed" OR "was never re-entered" - those aren't
    distinguishable from the event stream alone. See
    _tree_of_life_uptime_for_fight's per-fight, evidence-based resolution of
    that ambiguity (confirmed against real data: a report-wide reconstruction
    put Danceswtrees's real Karathress kill at 3.6% uptime; WCL's own
    server-computed table(dataType: Casts) uptime for that exact fight was
    76.3% - the per-fight approach here reproduces that 76.3% exactly)."""
    print(f"  Fetching report-wide Tree of Life buff events (guid {TREE_OF_LIFE_GUID})...")
    report_end_offset = report_end - report_start

    def query_builder(start_time: float) -> str:
        return (
            f'query {{ reportData {{ report(code: "{report_code}") {{ '
            f"events(sourceID: {character_id}, dataType: Buffs, startTime: {start_time}, endTime: {report_end_offset}) "
            f"{{ data nextPageTimestamp }} }} }} }}"
        )

    def extract_page(data: Any) -> wcl_api.PageResult:
        ev = data["reportData"]["report"]["events"]
        return wcl_api.PageResult(items=ev["data"], next_page_timestamp=ev.get("nextPageTimestamp"))

    paged = wcl_api.invoke_wcl_graphql_paged(query_builder, extract_page, access_token=access_token)
    if paged.errors:
        print(f"  FAILED fetching report-wide buffs events - {paged.errors}")
        return []

    tol_events = sorted((e for e in paged.items if e.get("abilityGameID") == TREE_OF_LIFE_GUID), key=lambda e: e["timestamp"])
    print(f"  Fetched {len(tol_events)} real Tree of Life buff event(s) report-wide")
    return tol_events


def _tree_of_life_uptime_for_fight(tol_events: list[dict], fight_start: float, fight_end: float, fight_casts_events: list[dict]) -> float:
    """Per-fight uptime, evidence-based rather than assumed from a report-wide
    chain. Real rule, confirmed against real Danceswtrees data (see
    _get_tree_of_life_events's docstring):
      - A real removebuff is the first event seen inside this fight's own
        window -> the buff was already up when the fight started (no earlier
        applybuff needed inside the window to prove that), active from fight
        start until that removal.
      - A real applybuff is the first event seen -> NOT up at fight start,
        inactive until that cast.
      - Every following apply/remove pair inside the window reconstructs
        normally.
      - Zero real toggle events anywhere in the window -> ambiguous from this
        signal alone (could mean "still up the whole fight, nothing to log"
        OR "never re-entered"). Healing Touch (guid 26979) cannot be cast
        while shapeshifted into Tree of Life - a real, hard game-mechanic
        fact - so a real Healing Touch cast anywhere in the fight's own casts
        proves the character was NOT in the buff for at least that moment;
        per explicit instruction, treat that as 0% uptime for the whole
        fight rather than estimating a partial window. No Healing Touch cast
        either -> assume 100% (still up the entire fight)."""
    duration = fight_end - fight_start
    if duration <= 0:
        return 0

    in_window = sorted((e for e in tol_events if fight_start <= e["timestamp"] <= fight_end), key=lambda e: e["timestamp"])
    if not in_window:
        has_healing_touch = any(e.get("abilityGameID") == HEALING_TOUCH_GUID for e in fight_casts_events)
        return 0 if has_healing_touch else 100

    intervals: list[tuple[float, float]] = []
    active = False
    interval_start = None
    first = in_window[0]
    if first["type"] == "removebuff":
        intervals.append((fight_start, first["timestamp"]))
    elif first["type"] == "applybuff":
        active = True
        interval_start = first["timestamp"]
    for ev in in_window[1:]:
        if ev["type"] == "applybuff":
            if not active:
                interval_start = ev["timestamp"]
                active = True
        elif ev["type"] == "removebuff":
            if active:
                intervals.append((interval_start, ev["timestamp"]))
                active = False
    if active:
        intervals.append((interval_start, fight_end))

    overlap = sum(min(iv_end, fight_end) - max(iv_start, fight_start) for iv_start, iv_end in intervals)
    return round_net((overlap / duration) * 100, 1)


def _pull_one_fight(
    fight_id: int, boss_slug: str, start_time: float, end_time: float, report_code: str,
    character_id: int, character_name: str, actor_names: dict[int, str],
    tree_of_life_events: list[dict], out_dir: Path, access_token: str,
    compute_improved_faerie_fire: bool, report_end_time: float,
) -> dict:
    label = f"fight{fight_id:02d}_{boss_slug}"
    messages: list[str] = []
    result = {"ok": True, "messages": messages}

    def resolve_actor_name(actor_id) -> str | None:
        if actor_id is None:
            return None
        key = int(actor_id)
        return actor_names.get(key, f"Unknown_{key}")

    local_ability_cache: dict[int, dict] = {}
    fight_ok = True

    def get_events(data_type: str, out_file: Path) -> bool:
        if out_file.exists():
            return True

        def query_builder(page_start_time: float) -> str:
            return (
                f'query {{ reportData {{ report(code: "{report_code}") {{ '
                f"events(fightIDs: [{fight_id}], sourceID: {character_id}, dataType: {data_type}, "
                f"includeResources: true, startTime: {page_start_time}, endTime: {end_time}) "
                f"{{ data nextPageTimestamp }} }} }} }}"
            )

        def extract_page(data: Any) -> wcl_api.PageResult:
            ev = data["reportData"]["report"]["events"]
            return wcl_api.PageResult(items=ev["data"], next_page_timestamp=ev.get("nextPageTimestamp"))

        paged = wcl_api.invoke_wcl_graphql_paged(query_builder, extract_page, access_token=access_token, initial_start_time=start_time)
        if paged.errors:
            messages.append(f"  {label} - FAILED ({data_type} events): {paged.errors}")
            return False

        events = paged.items
        for ev in events:
            src_name = resolve_actor_name(ev.get("sourceID"))
            tgt_name = resolve_actor_name(ev["targetID"]) if ev.get("targetID") is not None else src_name
            ability_info = _resolve_ability_name_local(ev["abilityGameID"], local_ability_cache, access_token)
            ev["sourceName"] = src_name
            ev["targetName"] = tgt_name
            ev["ability"] = {"name": ability_info["name"], "guid": ev["abilityGameID"], "abilityIcon": ability_info["icon"]}

        total_amount = sum(e.get("amount", 0) or 0 for e in events)
        total_overheal = sum(e.get("overheal", 0) or 0 for e in events)
        view_name = data_type.lower()
        out = {
            "sourceID": character_id, "sourceName": character_name, "view": view_name,
            "eventCount": len(events), "totalAmount": total_amount, "totalOverheal": total_overheal,
            "events": events,
        }
        jsonio.write_json(out_file, out)
        if paged.page_count > 1:
            messages.append(f"  {label} - {view_name} events: {len(events)} across {paged.page_count} pages, total={total_amount}, overheal={total_overheal}")
        else:
            messages.append(f"  {label} - {view_name} events: {len(events)}, total={total_amount}, overheal={total_overheal}")
        return True

    def get_combatant_info_snapshot() -> dict | None:
        # Search the report's own full start-to-end window, not this fight's own end time -
        # confirmed via live data (2026-07-18) that real WoW combat logs only emit a fresh
        # COMBATANT_INFO snapshot near an encounter's first real pull, not on every
        # wipe-and-repull. Gear/consumables genuinely carry over unchanged across repulls,
        # but a same-boss repull's valid snapshot commonly sits 5-17 minutes before the
        # repull itself - and for a fight that ISN'T the report's last one, the only real
        # snapshot can just as easily land AFTER this fight ends (a late arrival relative to
        # an early fight, snapshotted near a later pull in the same report) - confirmed live
        # 2026-07-18 fixing 6 of 7 benchmark parses wrongly marked irrecoverable, see
        # CLAUDE.md. Using fight-scoped end_time here would silently miss both cases.
        q = f'query {{ reportData {{ report(code: "{report_code}") {{ events(dataType: CombatantInfo, startTime: 0, endTime: {report_end_time}) {{ data }} }} }} }}'
        r = wcl_api.invoke_wcl_graphql(q, access_token=access_token)
        if r.errors:
            messages.append(f"  {label} - combatantinfo request FAILED (network/API error) - {r.errors}")
            return None
        all_events = r.data["reportData"]["report"]["events"]["data"]
        candidates = [e for e in all_events if e.get("sourceID") == character_id]
        if not candidates:
            messages.append(f"  {label} - combatantinfo request OK but found {len(all_events)} total entries, NONE for sourceID={character_id} anywhere earlier in the report")
            return None
        # Confirmed via live data (2026-07-18, Charmaine/Poliovictim): WCL sometimes logs a
        # corrupted stub entry (auras: [], all-zero stats, placeholder talent icons) that can
        # sit closer in time than a real snapshot - prefer any candidate with a genuinely
        # non-empty auras list before falling back to plain closest-by-distance.
        real_candidates = [e for e in candidates if e.get("auras")]
        pool = real_candidates if real_candidates else candidates
        closest = min(pool, key=lambda e: abs(e["timestamp"] - start_time))
        gap_ms = closest["timestamp"] - start_time
        if gap_ms > 2000:
            messages.append(f"  {label} - WARNING: closest combatantinfo snapshot is {round(gap_ms / 1000, 1)}s AFTER fight start - no earlier snapshot found anywhere in the report (consumable/gear status may not reflect the true pull-start state)")
        elif gap_ms < -120000:
            messages.append(f"  {label} - combatantinfo snapshot found {round(-gap_ms / 1000, 1)}s before official fight start (using it - this is an earlier attempt's snapshot; expected since WoW doesn't re-log gear/consumables on every repull)")
        elif gap_ms < -1000:
            messages.append(f"  {label} - combatantinfo snapshot found {round(-gap_ms / 1000, 1)}s before official fight start (using it - this is expected, see script header)")
        if not closest.get("auras") and not closest.get("gear"):
            messages.append(f"  {label} - combatantinfo entry found for sourceID={character_id} but it has neither auras nor gear fields")
            return None
        return closest

    def get_improved_faerie_fire_uptime() -> float | None:
        q = f'query {{ reportData {{ report(code: "{report_code}") {{ table(fightIDs: [{fight_id}], dataType: Casts, sourceID: {character_id}, startTime: {start_time}, endTime: {end_time}) }} }} }}'
        r = wcl_api.invoke_wcl_graphql(q, access_token=access_token)
        if r.errors:
            messages.append(f"  {label} - FAILED improved-faerie-fire casts-table - {r.errors}")
            return None
        entries = r.data["reportData"]["report"]["table"]["data"]["entries"]
        ff_entry = next((e for e in entries if e.get("guid") == IMPROVED_FAERIE_FIRE_GUID), None)
        if not ff_entry or not ff_entry.get("uptime"):
            return 0
        duration = end_time - start_time
        if duration <= 0:
            return 0
        return round_net((ff_entry["uptime"] / duration) * 100, 1)

    healing_out = out_dir / f"{label}_healing_events.json"
    if not get_events("Healing", healing_out):
        fight_ok = False

    casts_out = out_dir / f"{label}_casts_events.json"
    if not get_events("Casts", casts_out):
        fight_ok = False

    consumables_out = out_dir / f"{label}_consumables.json"
    gear_out = out_dir / f"{label}_gear.json"
    needs_consumables = not consumables_out.exists()
    needs_gear = not gear_out.exists()
    if needs_consumables or needs_gear:
        snapshot = get_combatant_info_snapshot()
        if snapshot is None:
            messages.append(f"  {label} - FAILED (combatantinfo snapshot unavailable for consumables/gear)")
            fight_ok = False
        else:
            if needs_consumables:
                if not snapshot.get("auras"):
                    messages.append(f"  {label}_consumables.json - FAILED (snapshot has no auras field)")
                    fight_ok = False
                else:
                    cc = wcl_api.classify_consumables(snapshot["auras"])
                    food = next((a for a in snapshot["auras"] if a.get("name") == "Well Fed"), None)
                    fight_casts_events = jsonio.read_json(casts_out)["events"] if casts_out.exists() else []
                    tree_of_life_pct = _tree_of_life_uptime_for_fight(tree_of_life_events, start_time, end_time, fight_casts_events)
                    out = {
                        "flaskActive": bool(cc.flask), "flaskName": cc.flask["name"] if cc.flask else None,
                        "battleElixirActive": bool(cc.battle_elixir), "battleElixirName": cc.battle_elixir["name"] if cc.battle_elixir else None,
                        "guardianElixirActive": bool(cc.guardian_elixir), "guardianElixirName": cc.guardian_elixir["name"] if cc.guardian_elixir else None,
                        "foodActive": bool(food), "foodName": food["name"] if food else None,
                        "treeOfLifeUptimePct": tree_of_life_pct,
                    }
                    iff_msg = ""
                    if compute_improved_faerie_fire:
                        iff_pct = get_improved_faerie_fire_uptime()
                        if iff_pct is None:
                            iff_pct = 0
                            fight_ok = False
                        out["improvedFaerieFireUptimePct"] = iff_pct
                        iff_msg = f" improvedFaerieFire={iff_pct}%"
                    jsonio.write_json(consumables_out, out)
                    messages.append(f"  {label}_consumables.json - OK (flask={bool(cc.flask)} battleElixir={bool(cc.battle_elixir)} guardianElixir={bool(cc.guardian_elixir)} food={bool(food)} treeOfLife={tree_of_life_pct}%{iff_msg})")
            if needs_gear:
                if not snapshot.get("gear"):
                    messages.append(f"  {label}_gear.json - FAILED (snapshot has no gear field)")
                    fight_ok = False
                else:
                    jsonio.write_json(gear_out, {"gear": snapshot["gear"], "talents": snapshot.get("talents")})
                    filled_count = sum(1 for g in snapshot["gear"] if g.get("id"))
                    messages.append(f"  {label}_gear.json - OK ({filled_count}/{len(snapshot['gear'])} slots filled)")

    active_time_out = out_dir / f"{label}_activetime.json"
    if not active_time_out.exists():
        at_query = f'query {{ reportData {{ report(code: "{report_code}") {{ table(fightIDs: [{fight_id}], dataType: Healing, startTime: {start_time}, endTime: {end_time}) }} }} }}'
        at_result = wcl_api.invoke_wcl_graphql(at_query, access_token=access_token)
        if at_result.errors:
            messages.append(f"  {label}_activetime.json - FAILED: {at_result.errors}")
            fight_ok = False
        else:
            all_entries = at_result.data["reportData"]["report"]["table"]["data"]["entries"]
            at_entry = next((e for e in all_entries if e["name"] == character_name), None)
            if not at_entry:
                messages.append(f"  {label}_activetime.json - FAILED (no matching entry in healing table response)")
                fight_ok = False
            else:
                duration = end_time - start_time
                active_time_pct = round_net((at_entry["activeTime"] / duration) * 100, 1) if duration > 0 else 0
                active_time_reduced_pct = round_net((at_entry["activeTimeReduced"] / duration) * 100, 1) if duration > 0 else 0
                same_raid_healers_raw = [
                    {"Name": e["name"], "Total": e["total"], "ItemLevel": e.get("itemLevel"), "Icon": e.get("icon")}
                    for e in all_entries if e.get("icon") in TRACKED_HEALER_ICONS
                ]
                jsonio.write_json(active_time_out, {
                    "activeTime": at_entry["activeTime"], "activeTimeReduced": at_entry["activeTimeReduced"],
                    "activeTimePct": active_time_pct, "activeTimeReducedPct": active_time_reduced_pct,
                    "sameRaidHealersRawHealing": same_raid_healers_raw,
                })
                messages.append(f"  {label}_activetime.json - OK (activeTime={active_time_pct}%, {len(same_raid_healers_raw)} tracked-spec healer(s) captured)")

    deaths_out = out_dir / f"{label}_deaths.json"
    if not deaths_out.exists():
        deaths_query = f'query {{ reportData {{ report(code: "{report_code}") {{ table(fightIDs: [{fight_id}], dataType: Deaths, startTime: {start_time}, endTime: {end_time}) }} }} }}'
        deaths_result = wcl_api.invoke_wcl_graphql(deaths_query, access_token=access_token)
        if deaths_result.errors:
            messages.append(f"  {label}_deaths.json - FAILED: {deaths_result.errors}")
            fight_ok = False
        else:
            jsonio.write_json(deaths_out, deaths_result.data["reportData"]["report"]["table"]["data"])
            messages.append(f"  {label}_deaths.json - OK")

    result["ok"] = fight_ok
    return result


def pull_character(
    report_code: str, character_name: str, server: str | None = None, region: str | None = None,
    class_name: str | None = None, spec: str | None = None, date_override: str | None = None,
    max_threads: int = 10, characters_root: str = "data/Characters",
) -> PullCharacterResult:
    m = re.search(r"warcraftlogs\.com/reports/([A-Za-z0-9]+)", report_code)
    if m:
        report_code = m.group(1)

    print(f"Running with --max-threads {max_threads} (default 10 - lower this if you see rate-limit failures)")
    token = wcl_api.get_wcl_access_token()
    print()

    characters_root_path = Path(characters_root)

    print(f"=== Step 1: Fight list for report {report_code} ===")
    cached_fights_file = paths.find_file_recursive(characters_root_path, f"fights_{report_code}.json") if characters_root_path.exists() else None
    cached_candidate = jsonio.read_json(cached_fights_file) if cached_fights_file else None

    if cached_candidate and "actors" in cached_candidate:
        print(f"  Found cached fights file: {cached_fights_file} - reusing, not re-fetching.")
        fights_data = cached_candidate
    else:
        if cached_fights_file:
            print(f"  Found cached fights file: {cached_fights_file}, but it's the old pre-migration v1 shape (no actors[]) - ignoring it and re-fetching from the v2 API.")
        print("  Not cached anywhere yet - fetching from the API...")
        report_query = f'''query {{
  reportData {{
    report(code: "{report_code}") {{
      title
      startTime
      endTime
      region {{ compactName }}
      fights {{ id encounterID name kill startTime endTime }}
      masterData {{ actors {{ id name type subType server }} }}
    }}
  }}
}}'''
        report_result = wcl_api.invoke_wcl_graphql(report_query, access_token=token)
        if report_result.errors:
            raise RuntimeError(
                f"failed to fetch fight list for {report_code}: {report_result.errors} "
                f"(This usually means the report is private - the owner needs to make it public.)"
            )
        report = report_result.data["reportData"]["report"]
        if not report:
            raise RuntimeError(f"report {report_code} returned no data - check the code is correct and the report is public.")

        reshaped_fights = [
            {"id": f["id"], "boss": f["encounterID"], "name": f["name"], "kill": f["kill"], "start_time": int(f["startTime"]), "end_time": int(f["endTime"])}
            for f in report["fights"]
        ]
        reshaped_actors = [
            {"id": a["id"], "name": a["name"], "type": a["type"], "subType": a.get("subType"), "server": a.get("server")}
            for a in report["masterData"]["actors"]
        ]
        fights_data = {
            "title": report["title"], "start": int(report["startTime"]), "end": int(report["endTime"]),
            "region": report["region"]["compactName"], "fights": reshaped_fights, "actors": reshaped_actors,
        }

    actor_names = {int(a["id"]): a["name"] for a in fights_data["actors"] if a.get("id") is not None}

    # ===== Step 2: raid date =====
    raid_date = None
    if date_override:
        raid_date = date_override
    else:
        title_match = re.search(r"(\d{1,2})\.(\d{1,2})\.(\d{4})", fights_data["title"])
        if title_match:
            month, day, year = title_match.group(1).zfill(2), title_match.group(2).zfill(2), title_match.group(3)
            raid_date = f"{year}-{month}-{day}"
        elif fights_data.get("start"):
            raid_date = datetime.fromtimestamp(fights_data["start"] / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
            print(f"  WARNING: couldn't parse a date out of the report title ('{fights_data['title']}') - derived {raid_date} from the report's start timestamp instead. Pass --date-override if this is wrong.")
        else:
            raise RuntimeError("could not determine the raid date from the report title or start time. Pass --date-override 'YYYY-MM-DD' explicitly.")
    print(f"  Raid date: {raid_date}")
    fights_data["raidDate"] = raid_date

    # ===== Step 3: class/server/region/actor ID =====
    friendly = next((a for a in fights_data["actors"] if a["name"] == character_name and a["type"] == "Player"), None)
    character_id = None
    if friendly:
        if not class_name:
            class_name = friendly.get("subType")
        if not server:
            server = friendly.get("server")
        if not region:
            region = fights_data["region"]
        character_id = friendly["id"]
        print(f"  Found '{character_name}' in actors[]: {class_name}, {server}-{region}, report-local id={character_id}")
    else:
        if not class_name or not server or not region:
            raise RuntimeError(
                f"'{character_name}' was not found in this report's actors[] list. "
                f"Re-run with --class, --server, and --region supplied explicitly if this character "
                f"genuinely isn't in this report (e.g. resolving them from a different raid)."
            )
        print(f"  '{character_name}' not in actors[] - using supplied overrides: {class_name}, {server}-{region}")
        print("  WARNING: no report-local actor ID available - rankings/spec resolution and all fight-level pulls will be SKIPPED.")

    out_dir = characters_root_path / character_name / report_code
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"  Output folder: {out_dir}")
    print()

    fights_out_file = out_dir / f"fights_{report_code}.json"
    if not fights_out_file.exists():
        jsonio.write_json(fights_out_file, fights_data)

    # ===== Step 3b: real per-fight rankings + spec resolution =====
    print(f"=== Step 2: Real per-fight rankings + spec resolution for {character_name} ===")
    all_boss_fights = [f for f in fights_data["fights"] if f["boss"] != 0 and f["kill"] is True]
    rankings_out_file = out_dir / f"{report_code}_v2_rankings.json"
    resolved_spec = None
    boss_fights: list[dict] = []

    if not character_id or not all_boss_fights:
        print("  Skipping - no report-local actor ID or no boss kills in this report.")
    else:
        if rankings_out_file.exists():
            print(f"  {report_code}_v2_rankings.json - already have it, reusing for spec resolution.")
            rankings_data = jsonio.read_json(rankings_out_file)
        else:
            fight_id_list = ",".join(str(f["id"]) for f in all_boss_fights)
            rankings_query = f'query {{ reportData {{ report(code: "{report_code}") {{ rankings(fightIDs: [{fight_id_list}], playerMetric: hps) }} }} }}'
            rankings_result = wcl_api.invoke_wcl_graphql(rankings_query, access_token=token)
            if rankings_result.errors:
                raise RuntimeError(
                    f"rankings fetch failed - {rankings_result.errors}. This call is required for "
                    f"per-fight spec resolution (STEP 3b), not optional - refusing to guess which "
                    f"fights belong to which spec. Re-run once the API is reachable again."
                )
            rankings_data = rankings_result.data["reportData"]["report"]["rankings"]
            jsonio.write_json(rankings_out_file, rankings_data)
            print(f"  {report_code}_v2_rankings.json - OK ({len(all_boss_fights)} fight(s) looked up)")

        per_fight_spec: dict[int, dict | None] = {}
        if rankings_data and rankings_data.get("data"):
            for fight_entry in rankings_data["data"]:
                found = None
                for role_name in ("tanks", "healers", "dps"):
                    role_obj = fight_entry.get("roles", {}).get(role_name)
                    if role_obj and role_obj.get("characters"):
                        match = next((c for c in role_obj["characters"] if c["name"] == character_name), None)
                        if match:
                            found = {"class": match["class"], "spec": match["spec"], "role": role_name}
                            break
                per_fight_spec[int(fight_entry["fightID"])] = found

        distinct_specs = list(dict.fromkeys(v["spec"] for v in per_fight_spec.values() if v))
        not_found_fights = [f for f in all_boss_fights if not per_fight_spec.get(int(f["id"]))]
        for f in not_found_fights:
            print(f"  NOTE: '{character_name}' not found in any role list for fight {f['id']} ('{f['name']}') - treating as not-present this fight (bench/sat out), excluding.")

        if len(distinct_specs) > 1 and not spec:
            lines = [f"'{character_name}' plays more than one real spec across this report's boss kills - real per-fight breakdown:"]
            for f in all_boss_fights:
                entry = per_fight_spec.get(int(f["id"]))
                spec_label = f"{entry['class']} / {entry['spec']} ({entry['role']})" if entry else "not found in any role this fight"
                lines.append(f"         fight {f['id']} ('{f['name']}'): {spec_label}")
            lines.append(f"       Pass --spec '<one of the specs above>' to analyze only the fights where '{character_name}' played that spec.")
            raise RuntimeError("\n".join(lines))

        resolved_spec = spec if spec else (distinct_specs[0] if len(distinct_specs) == 1 else None)
        if resolved_spec and not spec:
            print(f"  Confirmed real spec for every boss kill this character appears in: {resolved_spec}")
        elif resolved_spec:
            print(f"  Analyzing only fights where '{character_name}' played spec: {resolved_spec}")

        boss_fights = [f for f in all_boss_fights if (entry := per_fight_spec.get(int(f["id"]))) and entry["spec"] == resolved_spec]
        boss_fight_ids = {f["id"] for f in boss_fights}
        excluded_fights = [f for f in all_boss_fights if f["id"] not in boss_fight_ids]
        for f in excluded_fights:
            entry = per_fight_spec.get(int(f["id"]))
            other_spec_label = entry["spec"] if entry else "unknown (not found in any role list)"
            print(f"  SKIP: fight {f['id']} ('{f['name']}') - '{character_name}' was playing {other_spec_label}, not {resolved_spec}, this fight.")

        spec_coverage = {
            "CharacterName": character_name, "AnalyzedClass": class_name, "AnalyzedSpec": resolved_spec,
            "TotalBossesInReport": len(all_boss_fights), "BossesAnalyzed": len(boss_fights),
            "Bosses": [
                {
                    "FightID": f["id"], "BossName": f["name"], "BossSlug": _get_boss_slug(f["boss"], f["name"]),
                    "ResolvedClass": (per_fight_spec.get(int(f["id"])) or {}).get("class"),
                    "ResolvedSpec": (per_fight_spec.get(int(f["id"])) or {}).get("spec"),
                    "Included": f["id"] in boss_fight_ids,
                }
                for f in all_boss_fights
            ],
        }
        spec_coverage_out_file = out_dir / f"{report_code}_spec_coverage.json"
        jsonio.write_json(spec_coverage_out_file, spec_coverage)
        print(f"  {report_code}_spec_coverage.json - OK ({len(boss_fights)} of {len(all_boss_fights)} boss kills in spec '{resolved_spec}')")
    print()

    # ===== Step 4: per-boss-kill data =====
    print("=== Step 3: Fight data per boss kill (healing events, casts events, consumables, deaths) ===")
    tree_of_life_events: list[dict] = []
    if character_id:
        tree_of_life_events = _get_tree_of_life_events(report_code, character_id, fights_data["start"], fights_data["end"], token)

    if not character_id:
        print("  SKIPPED - no report-local actor ID for the character (see warning above).")
        boss_fights = []

    if character_id and not boss_fights:
        print("  No boss kills in the analyzed spec found in this report - nothing to pull here.")
    elif character_id:
        print(f"  {len(boss_fights)} boss kill(s) found in the analyzed spec.")

    total_done = total_failed = 0
    compute_improved_faerie_fire = resolved_spec == "Dreamstate"

    if boss_fights:
        print(f"  fetching {len(boss_fights)} boss kill(s) ({max_threads} threads)...")
        with ThreadPoolExecutor(max_workers=max_threads) as executor:
            futures = [
                executor.submit(
                    _pull_one_fight, fight["id"], _get_boss_slug(fight["boss"], fight["name"]), fight["start_time"], fight["end_time"],
                    report_code, character_id, character_name, actor_names, tree_of_life_events, out_dir, token, compute_improved_faerie_fire,
                    fights_data["end"],
                )
                for fight in boss_fights
            ]
            for future in futures:
                try:
                    result = future.result()
                    for msg in result["messages"]:
                        print(msg)
                    if result["ok"]:
                        total_done += 1
                    else:
                        total_failed += 1
                except Exception as exc:
                    print(f"  Worker threw unexpectedly: {exc}")
                    total_failed += 1
    print()

    print()
    print("==================================")
    print(f"Done. Output: {out_dir}")
    print(f"  Boss kills fully pulled (healing+casts+consumables+deaths ok): {total_done}")
    print(f"  Boss kills with at least one failed pull:                {total_failed}")

    pipeline_class_name = _resolve_pipeline_class_name(class_name, resolved_spec)
    return {
        "out_dir": out_dir,
        "wcl_class_name": class_name,
        "resolved_spec": resolved_spec,
        "pipeline_class_name": pipeline_class_name,
        "raid_date": raid_date,
        "boss_fights_count": len(boss_fights),
        "total_done": total_done,
        "total_failed": total_failed,
    }


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")

    parser = argparse.ArgumentParser(description="Port of pull_character_TEMPLATE.ps1")
    parser.add_argument("--report-code", required=True)
    parser.add_argument("--character-name", required=True)
    parser.add_argument("--server", default=None)
    parser.add_argument("--region", default=None)
    parser.add_argument("--class-name", default=None)
    parser.add_argument("--spec", default=None)
    parser.add_argument("--date-override", default=None)
    parser.add_argument("--max-threads", type=int, default=10)
    parser.add_argument("--characters-root", default="data/Characters")
    args = parser.parse_args()

    pull_character(
        args.report_code, args.character_name, args.server, args.region, args.class_name,
        args.spec, args.date_override, args.max_threads, args.characters_root,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
