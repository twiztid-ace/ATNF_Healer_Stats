"""Consolidated port of pull_top100_{druid,shaman,priest_holy,paladin,dreamstate}.ps1.

The 5 PowerShell scripts were ~90% structurally identical - only classID/
specID/wclClassName/wclSpecName and the buff/debuff-uptime mechanism
(Tree of Life for Druid, Improved Faerie Fire for Dreamstate, neither for
Shaman/Priest/Paladin) varied. This engine reads all of that from
pipeline/classes.py's ClassConfig instead of being duplicated 5 times,
dispatched via --class-name.

Maintains the same active/archived + manifest.json model, the same diff
algorithm (new/reentered/dropped/still-active), and writes the exact same
per-parse output file set with the exact same field names, so
summarize_benchmarks.py needs zero changes to read this engine's output.

RunspacePool -> concurrent.futures.ThreadPoolExecutor. The PowerShell
ConcurrentDictionary caches (fightsCache/actorNamesCache/deathsClaimed/
abilityCache) become plain dicts guarded by threading.Lock - Python's GIL
makes individual dict operations atomic, but the check-then-act patterns
here (the "first thread to claim a death wins" race, cache-miss-then-fill)
still need explicit locking to preserve the same semantics as the original.
"""

from __future__ import annotations

import argparse
import shutil
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

from pipeline import bosses as bosses_module
from pipeline import classes as classes_module
from pipeline import jsonio, wcl_api
from pipeline.numeric import round_net

TREE_OF_LIFE_GUID = 33891
IMPROVED_FAERIE_FIRE_GUID = 26993


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class RunState:
    """Shared, lock-guarded caches for one full run - the Python equivalent
    of the PS script's ConcurrentDictionary instances."""

    def __init__(self):
        self.fights_cache: dict[str, dict] = {}
        self.fights_lock = threading.Lock()
        self.deaths_claimed: set[str] = set()
        self.deaths_lock = threading.Lock()
        self.ability_cache: dict[int, dict] = {}
        self.ability_lock = threading.Lock()


def _resolve_ability_name(guid: int, state: RunState, access_token: str) -> dict:
    with state.ability_lock:
        cached = state.ability_cache.get(guid)
    if cached is not None:
        return cached
    q = f"query {{ gameData {{ ability(id: {guid}) {{ name icon }} }} }}"
    r = wcl_api.invoke_wcl_graphql(q, access_token=access_token)
    entry = {"name": None, "icon": None}
    if not r.errors and r.data and r.data.get("gameData", {}).get("ability"):
        entry["name"] = r.data["gameData"]["ability"]["name"]
        entry["icon"] = r.data["gameData"]["ability"]["icon"]
    with state.ability_lock:
        state.ability_cache[guid] = entry
    return entry


def _get_events(
    view: str, out_file: Path, start_time: float, end_time: float,
    source_id: int, source_name: str, actor_names: dict[int, str],
    report_id: str, fight_id: int, access_token: str, state: RunState,
    messages: list[str], idx: int, player_name: str,
) -> bool:
    if out_file.exists():
        return True

    data_type = "Healing" if view == "healing" else "Casts"

    def query_builder(page_start_time: float) -> str:
        return (
            f'query {{ reportData {{ report(code: "{report_id}") {{ '
            f"events(fightIDs: [{fight_id}], sourceID: {source_id}, dataType: {data_type}, "
            f"includeResources: true, startTime: {page_start_time}, endTime: {end_time}) "
            f"{{ data nextPageTimestamp }} }} }} }}"
        )

    def extract_page(data: Any) -> wcl_api.PageResult:
        ev = data["reportData"]["report"]["events"]
        return wcl_api.PageResult(items=ev["data"], next_page_timestamp=ev.get("nextPageTimestamp"))

    paged = wcl_api.invoke_wcl_graphql_paged(query_builder, extract_page, access_token=access_token, initial_start_time=start_time)
    if paged.errors:
        messages.append(f"[{idx}] FAILED {view} events for {report_id}/{fight_id} ({player_name}) - {paged.errors}")
        return False

    events = paged.items
    for ev in events:
        src_name = actor_names.get(int(ev["sourceID"]), f"Unknown_{ev['sourceID']}")
        target_id = ev.get("targetID")
        if target_id is not None and int(target_id) in actor_names:
            tgt_name = actor_names[int(target_id)]
        elif target_id is not None:
            tgt_name = f"Unknown_{target_id}"
        else:
            tgt_name = src_name
        ability_info = _resolve_ability_name(ev["abilityGameID"], state, access_token)
        ev["sourceName"] = src_name
        ev["targetName"] = tgt_name
        ev["ability"] = {"name": ability_info["name"], "guid": ev["abilityGameID"], "abilityIcon": ability_info["icon"]}

    total_amount = sum(ev.get("amount", 0) or 0 for ev in events)
    total_overheal = sum(ev.get("overheal", 0) or 0 for ev in events)
    out = {
        "sourceID": source_id, "sourceName": source_name, "view": view,
        "eventCount": len(events), "totalAmount": total_amount, "totalOverheal": total_overheal,
        "events": events,
    }
    jsonio.write_json(out_file, out)
    if len(events) >= 2900:
        messages.append(f"[{idx}] {report_id}/{fight_id} ({player_name}) - {view} events: {len(events)} (HIGH - verify not silently capped)")
    return True


def _get_consumables_snapshot(report_id: str, fight_id: int, start_time: float, end_time: float, source_id: int, access_token: str, messages: list[str], idx: int, player_name: str) -> dict | None:
    buffer_ms = 120000
    query_start = max(0, start_time - buffer_ms)
    q = f'query {{ reportData {{ report(code: "{report_id}") {{ events(dataType: CombatantInfo, startTime: {query_start}, endTime: {end_time}) {{ data }} }} }} }}'
    r = wcl_api.invoke_wcl_graphql(q, access_token=access_token)
    if r.errors:
        messages.append(f"[{idx}] FAILED combatantinfo for {report_id}/{fight_id} ({player_name}) - {r.errors}")
        return None
    all_events = r.data["reportData"]["report"]["events"]["data"]
    candidates = [e for e in all_events if e.get("sourceID") == source_id]
    if not candidates:
        messages.append(f"[{idx}] combatantinfo OK but no entry for sourceID={source_id} even with backward buffer ({report_id}/{fight_id}, {player_name})")
        return None
    closest = min(candidates, key=lambda e: abs(e["timestamp"] - start_time))
    if not closest.get("auras"):
        return None
    cc = wcl_api.classify_consumables(closest["auras"])
    food = next((a for a in closest["auras"] if a.get("name") == "Well Fed"), None)
    return {
        "flaskActive": bool(cc.flask), "flaskName": cc.flask["name"] if cc.flask else None,
        "battleElixirActive": bool(cc.battle_elixir), "battleElixirName": cc.battle_elixir["name"] if cc.battle_elixir else None,
        "guardianElixirActive": bool(cc.guardian_elixir), "guardianElixirName": cc.guardian_elixir["name"] if cc.guardian_elixir else None,
        "foodActive": bool(food), "foodName": food["name"] if food else None,
    }


def _get_tree_of_life_uptime(report_id: str, fight_id: int, start_time: float, end_time: float, source_id: int, access_token: str, messages: list[str], idx: int, player_name: str) -> float | None:
    q = f'query {{ reportData {{ report(code: "{report_id}") {{ events(fightIDs: [{fight_id}], sourceID: {source_id}, dataType: Buffs, startTime: {start_time}, endTime: {end_time}) {{ data }} }} }} }}'
    r = wcl_api.invoke_wcl_graphql(q, access_token=access_token)
    if r.errors:
        messages.append(f"[{idx}] FAILED tree-of-life buffs events for {report_id}/{fight_id} ({player_name}) - {r.errors}")
        return None
    tol_events = sorted(
        (e for e in r.data["reportData"]["report"]["events"]["data"] if e.get("abilityGameID") == TREE_OF_LIFE_GUID),
        key=lambda e: e["timestamp"],
    )
    intervals = []
    active = False
    interval_start = None
    is_first_event = True
    for ev in tol_events:
        if ev["type"] == "applybuff":
            if not active:
                interval_start = ev["timestamp"]
                active = True
        elif ev["type"] == "removebuff":
            if active:
                intervals.append((interval_start, ev["timestamp"]))
                active = False
            elif is_first_event:
                intervals.append((start_time, ev["timestamp"]))
        is_first_event = False
    if active:
        intervals.append((interval_start, end_time))
    overlap = 0
    for iv_start, iv_end in intervals:
        ov_start = max(iv_start, start_time)
        ov_end = min(iv_end, end_time)
        if ov_end > ov_start:
            overlap += ov_end - ov_start
    duration = end_time - start_time
    if duration <= 0:
        return 0
    return round_net((overlap / duration) * 100, 1)


def _get_improved_faerie_fire_uptime(report_id: str, fight_id: int, start_time: float, end_time: float, source_id: int, access_token: str, messages: list[str], idx: int, player_name: str) -> float | None:
    q = f'query {{ reportData {{ report(code: "{report_id}") {{ table(fightIDs: [{fight_id}], dataType: Casts, sourceID: {source_id}, startTime: {start_time}, endTime: {end_time}) }} }} }}'
    r = wcl_api.invoke_wcl_graphql(q, access_token=access_token)
    if r.errors:
        messages.append(f"[{idx}] FAILED improved-faerie-fire casts-table for {report_id}/{fight_id} ({player_name}) - {r.errors}")
        return None
    entries = r.data["reportData"]["report"]["table"]["data"]["entries"]
    ff_entry = next((e for e in entries if e.get("guid") == IMPROVED_FAERIE_FIRE_GUID), None)
    if not ff_entry or not ff_entry.get("uptime"):
        return 0
    duration = end_time - start_time
    if duration <= 0:
        return 0
    return round_net((ff_entry["uptime"] / duration) * 100, 1)


def _pull_one_parse(
    report_id: str, fight_id: int, player_name: str, idx: int,
    cfg: classes_module.ClassConfig, out_dir: Path, state: RunState, access_token: str,
) -> dict:
    messages: list[str] = []
    result = {"ok": True, "messages": messages, "report_id": report_id, "fight_id": fight_id, "player_name": player_name, "safe_name": None}

    # --- fetch (or reuse) this report's fight list + actor-name lookup ---
    with state.fights_lock:
        cached = state.fights_cache.get(report_id)
    if cached is None:
        report_query = f'query {{ reportData {{ report(code: "{report_id}") {{ fights {{ id startTime endTime }} masterData {{ actors {{ id name }} }} }} }} }}'
        r = wcl_api.invoke_wcl_graphql(report_query, access_token=access_token)
        if r.errors or not r.data.get("reportData", {}).get("report"):
            result["ok"] = False
            messages.append(f"[{idx}] FAILED fetching report {report_id} (fights list) - {r.errors}")
            return result
        report = r.data["reportData"]["report"]
        fights = [{"id": f["id"], "start_time": int(f["startTime"]), "end_time": int(f["endTime"])} for f in report["fights"]]
        actor_names = {int(a["id"]): a["name"] for a in report["masterData"]["actors"] if a.get("id") is not None}
        actors_by_name = {a["name"]: a["id"] for a in report["masterData"]["actors"] if a.get("name")}
        cached = {"fights": fights, "actor_names": actor_names, "actors_by_name": actors_by_name}
        with state.fights_lock:
            state.fights_cache[report_id] = cached

    fight = next((f for f in cached["fights"] if f["id"] == fight_id), None)
    if not fight:
        result["ok"] = False
        messages.append(f"[{idx}] SKIP: fight {fight_id} not found in report {report_id}")
        return result

    if player_name not in cached["actors_by_name"]:
        result["ok"] = False
        messages.append(f"[{idx}] SKIP: '{player_name}' not found in report {report_id} actors[] (can't scope sourceID)")
        return result
    player_id = cached["actors_by_name"][player_name]
    actor_names = cached["actor_names"]
    start, end = fight["start_time"], fight["end_time"]
    safe_name = "".join(c if c not in '\\/:*?"<>|' else "_" for c in player_name)
    result["safe_name"] = safe_name

    parse_ok = True

    healing_out = out_dir / f"{report_id}_{fight_id}_{safe_name}_healing_events.json"
    if not _get_events("healing", healing_out, start, end, player_id, player_name, actor_names, report_id, fight_id, access_token, state, messages, idx, player_name):
        parse_ok = False

    casts_out = out_dir / f"{report_id}_{fight_id}_{safe_name}_casts_events.json"
    if not _get_events("casts", casts_out, start, end, player_id, player_name, actor_names, report_id, fight_id, access_token, state, messages, idx, player_name):
        parse_ok = False

    consumables_out = out_dir / f"{report_id}_{fight_id}_{safe_name}_consumables.json"
    if not consumables_out.exists():
        snapshot = _get_consumables_snapshot(report_id, fight_id, start, end, player_id, access_token, messages, idx, player_name)
        if snapshot is None:
            parse_ok = False
        else:
            out = dict(snapshot)
            has_buff_uptime = "TreeOfLife" in cfg.active_stat_blocks
            has_debuff_uptime = "ImprovedFaerieFire" in cfg.active_stat_blocks
            if has_buff_uptime:
                tol_pct = _get_tree_of_life_uptime(report_id, fight_id, start, end, player_id, access_token, messages, idx, player_name)
                if tol_pct is None:
                    tol_pct = 0
                    parse_ok = False
                out["treeOfLifeUptimePct"] = tol_pct
            if has_debuff_uptime:
                iff_pct = _get_improved_faerie_fire_uptime(report_id, fight_id, start, end, player_id, access_token, messages, idx, player_name)
                if iff_pct is None:
                    iff_pct = 0
                    parse_ok = False
                out["improvedFaerieFireUptimePct"] = iff_pct
            jsonio.write_json(consumables_out, out)

    active_time_out = out_dir / f"{report_id}_{fight_id}_{safe_name}_activetime.json"
    if not active_time_out.exists():
        at_query = f'query {{ reportData {{ report(code: "{report_id}") {{ table(fightIDs: [{fight_id}], dataType: Healing, sourceClass: "{cfg.wcl_class_name}", startTime: {start}, endTime: {end}) }} }} }}'
        at_result = wcl_api.invoke_wcl_graphql(at_query, access_token=access_token)
        if at_result.errors:
            messages.append(f"[{idx}] FAILED activetime healing-table call for {report_id}/{fight_id} ({player_name}) - {at_result.errors}")
            parse_ok = False
        else:
            entries = at_result.data["reportData"]["report"]["table"]["data"]["entries"]
            at_entry = next((e for e in entries if e["name"] == player_name), None)
            if not at_entry:
                messages.append(f"[{idx}] FAILED activetime for {report_id}/{fight_id} ({player_name}) - no matching entry in healing table response")
                parse_ok = False
            else:
                duration = end - start
                active_time_pct = round_net((at_entry["activeTime"] / duration) * 100, 1) if duration > 0 else 0
                active_time_reduced_pct = round_net((at_entry["activeTimeReduced"] / duration) * 100, 1) if duration > 0 else 0
                jsonio.write_json(active_time_out, {
                    "activeTime": at_entry["activeTime"], "activeTimeReduced": at_entry["activeTimeReduced"],
                    "activeTimePct": active_time_pct, "activeTimeReducedPct": active_time_reduced_pct,
                })

    # --- deaths (fight-wide, once per report+fight) ---
    deaths_out = out_dir / f"{report_id}_{fight_id}_deaths.json"
    if not deaths_out.exists():
        deaths_key = f"{report_id}|{fight_id}"
        with state.deaths_lock:
            claimed = deaths_key not in state.deaths_claimed
            if claimed:
                state.deaths_claimed.add(deaths_key)
        if claimed:
            deaths_query = f'query {{ reportData {{ report(code: "{report_id}") {{ table(fightIDs: [{fight_id}], dataType: Deaths, startTime: {start}, endTime: {end}) }} }} }}'
            deaths_result = wcl_api.invoke_wcl_graphql(deaths_query, access_token=access_token)
            if deaths_result.errors:
                messages.append(f"[{idx}] FAILED deaths table for {report_id}/{fight_id} - {deaths_result.errors}")
            else:
                jsonio.write_json(deaths_out, deaths_result.data["reportData"]["report"]["table"]["data"])
        if not deaths_out.exists():
            parse_ok = False

    result["ok"] = parse_ok
    return result


def pull_top100(class_name: str, max_threads: int = 10, classes_root: str = "data/Classes") -> None:
    cfg = classes_module.get(class_name)
    class_dir = Path(classes_root) / cfg.manifest_root_key
    active_dir = class_dir / "active"
    archived_dir = class_dir / "archived"
    manifest_path = class_dir / "manifest.json"
    today = date.today().isoformat()
    now_iso = _now_iso()

    access_token = wcl_api.get_wcl_access_token()
    print(f"Running with --max-threads {max_threads} (default 10 - lower this if you see rate-limit failures)")
    print(f"Today: {today}")
    print()

    active_dir.mkdir(parents=True, exist_ok=True)
    (archived_dir / "rankings_history").mkdir(parents=True, exist_ok=True)

    if manifest_path.exists():
        manifest = jsonio.read_json(manifest_path)
    else:
        print(f"No manifest.json found - creating a fresh one for {cfg.manifest_root_key}.")
        manifest = {
            "schemaVersion": 2, "className": cfg.manifest_root_key, "classID": cfg.class_id, "specID": cfg.spec_id,
            "benchmarkGeneratedDate": None, "bosses": {},
        }

    state = RunState()
    total_new = total_confirmed = total_archived = total_reentered = total_failed = 0

    for boss_meta in bosses_module.BOSSES.values():
        boss_name = boss_meta.folder_name
        encounter_id = boss_meta.encounter_id
        rankings_file_name = boss_meta.rankings_file
        active_rankings_path = active_dir / rankings_file_name
        boss_active_dir = active_dir / boss_name
        boss_archived_dir = archived_dir / boss_name
        boss_active_dir.mkdir(parents=True, exist_ok=True)

        print(f"=== {boss_name} ===")

        rankings_query = (
            f'query {{ worldData {{ encounter(id: {encounter_id}) {{ '
            f'characterRankings(className: "{cfg.wcl_class_name}", specName: "{cfg.wcl_spec_name}", metric: hps, page: 1) }} }} }}'
        )
        rankings_result = wcl_api.invoke_wcl_graphql(rankings_query, access_token=access_token)
        char_rankings = None
        if not rankings_result.errors and rankings_result.data:
            char_rankings = rankings_result.data.get("worldData", {}).get("encounter", {}).get("characterRankings")
        if rankings_result.errors or not char_rankings:
            print(f"  FAILED fetching rankings - {rankings_result.errors} - skipping this boss entirely this run.")
            print()
            continue
        fresh_rankings = char_rankings["rankings"]

        reshaped_for_disk = [
            {"name": r["name"], "reportID": r["report"]["code"], "fightID": r["report"]["fightID"], "duration": r["duration"], "total": r["amount"]}
            for r in fresh_rankings
        ]
        print(f"  got {len(fresh_rankings)} fresh rankings")

        if boss_name not in manifest["bosses"]:
            manifest["bosses"][boss_name] = {
                "encounterID": encounter_id, "lastPulledDate": None, "rankingsSnapshotDate": None, "parses": {},
            }
        boss_entry = manifest["bosses"][boss_name]

        fresh_by_key = {}
        for k, r in enumerate(fresh_rankings):
            key = f"{r['report']['code']}_{r['report']['fightID']}_{r['name']}"
            fresh_by_key[key] = {"rank": k + 1, "hps": r["amount"], "reportID": r["report"]["code"], "fightID": r["report"]["fightID"], "name": r["name"]}

        active_manifest_keys = {k for k, p in boss_entry["parses"].items() if p["status"] == "active"}
        archived_manifest_keys = {k for k, p in boss_entry["parses"].items() if p["status"] == "archived"}
        new_keys = [k for k in fresh_by_key if k not in boss_entry["parses"]]
        reentered_keys = [k for k in fresh_by_key if k in archived_manifest_keys]
        dropped_keys = [k for k in active_manifest_keys if k not in fresh_by_key]
        still_active_keys = [k for k in active_manifest_keys if k in fresh_by_key]

        for key in still_active_keys:
            boss_entry["parses"][key]["rank"] = fresh_by_key[key]["rank"]
            boss_entry["parses"][key]["hps"] = round_net(fresh_by_key[key]["hps"], 1)
            boss_entry["parses"][key]["lastConfirmedInTop100At"] = now_iso
        total_confirmed += len(still_active_keys)

        if dropped_keys:
            boss_archived_dir.mkdir(parents=True, exist_ok=True)
        for key in dropped_keys:
            p = boss_entry["parses"][key]
            stem = f"{p['reportID']}_{p['fightID']}_{p['safeName']}"
            for suffix in ("healing_events", "casts_events", "consumables", "activetime"):
                src_path = boss_active_dir / f"{stem}_{suffix}.json"
                if src_path.exists():
                    shutil.move(str(src_path), str(boss_archived_dir / src_path.name))
                elif suffix != "activetime":
                    print(f"  WARNING: expected {src_path} to archive for dropped parse {key}, not found.")
            p["status"] = "archived"
            p["archivedAt"] = now_iso
        total_archived += len(dropped_keys)

        for key in reentered_keys:
            p = boss_entry["parses"][key]
            stem = f"{p['reportID']}_{p['fightID']}_{p['safeName']}"
            for suffix in ("healing_events", "casts_events", "consumables", "activetime"):
                src_path = boss_archived_dir / f"{stem}_{suffix}.json"
                if src_path.exists():
                    shutil.move(str(src_path), str(boss_active_dir / src_path.name))
                elif suffix != "activetime":
                    print(f"  WARNING: expected {src_path} to restore for re-entered parse {key}, not found in archived/{boss_name}.")
            p["status"] = "active"
            p["archivedAt"] = None
            p["rank"] = fresh_by_key[key]["rank"]
            p["hps"] = round_net(fresh_by_key[key]["hps"], 1)
            p["lastConfirmedInTop100At"] = now_iso
        if reentered_keys:
            total_reentered += len(reentered_keys)
            print(f"  {len(reentered_keys)} parse(s) RE-ENTERED the Top 100 (restored from archived/, zero API calls): {', '.join(reentered_keys)}")

        changed = bool(new_keys) or bool(dropped_keys) or bool(reentered_keys)
        if changed:
            if active_rankings_path.exists():
                old_snapshot_date = boss_entry.get("rankingsSnapshotDate") or "unknown-date"
                rankings_history_dir = archived_dir / "rankings_history" / boss_name
                rankings_history_dir.mkdir(parents=True, exist_ok=True)
                shutil.move(str(active_rankings_path), str(rankings_history_dir / f"{old_snapshot_date}.json"))
            jsonio.write_json(active_rankings_path, {"rankings": reshaped_for_disk})
            boss_entry["rankingsSnapshotDate"] = today
            print(f"  rankings CHANGED ({len(new_keys)} new, {len(dropped_keys)} dropped, {len(reentered_keys)} re-entered) - snapshot updated")
        else:
            print(f"  rankings unchanged since {boss_entry.get('rankingsSnapshotDate')} - not rewriting active/{rankings_file_name}")
        boss_entry["lastPulledDate"] = today

        if not new_keys:
            print("  no new parses to fetch")
            jsonio.write_json(manifest_path, manifest)
            print()
            continue

        print(f"  fetching {len(new_keys)} new parses ({max_threads} threads)...")
        boss_new_ok = boss_new_failed = 0
        with ThreadPoolExecutor(max_workers=max_threads) as executor:
            futures = {
                executor.submit(_pull_one_parse, fresh_by_key[key]["reportID"], fresh_by_key[key]["fightID"], fresh_by_key[key]["name"], i + 1, cfg, boss_active_dir, state, access_token): key
                for i, key in enumerate(new_keys)
            }
            for future in futures:
                key = futures[future]
                try:
                    result = future.result()
                    for msg in result["messages"]:
                        print(f"  {msg}")
                    if result["ok"]:
                        entry = fresh_by_key[key]
                        boss_entry["parses"][key] = {
                            "reportID": result["report_id"], "fightID": result["fight_id"], "playerName": result["player_name"],
                            "safeName": result["safe_name"], "status": "active", "rank": entry["rank"], "hps": round_net(entry["hps"], 1),
                            "firstSeenAt": now_iso, "lastConfirmedInTop100At": now_iso, "archivedAt": None,
                        }
                        boss_new_ok += 1
                    else:
                        boss_new_failed += 1
                except Exception as exc:
                    print(f"  Worker threw unexpectedly for {key}: {exc}")
                    boss_new_failed += 1

        print(f"  {boss_name} new parses done: {boss_new_ok} ok, {boss_new_failed} failed")
        total_new += boss_new_ok
        total_failed += boss_new_failed

        jsonio.write_json(manifest_path, manifest)
        print()

    print("==================================")
    print("Done.")
    print(f"  New parses fetched (ok):        {total_new}")
    print(f"  New parses failed:              {total_failed}")
    print(f"  Still-active (no refetch):      {total_confirmed}")
    print(f"  Archived (dropped from Top 100): {total_archived}")
    print(f"  Re-entered (restored, no refetch): {total_reentered}")
    print(f"  Unique reports fetched:         {len(state.fights_cache)}")
    print(f"  manifest.json:                  {manifest_path}")


def main() -> int:
    # Real player names include non-ASCII characters (Korean/Chinese names,
    # accented European names - already confirmed in this project's real
    # data). Windows' console defaults to a codepage that can't encode them,
    # which otherwise crashes mid-run on the first such name printed - not a
    # hypothetical, hit live during Phase 5 parity testing (a real Korean
    # player name in the Top 100 sample). errors="replace" is a last-resort
    # safety net; UTF-8 stdout renders correctly in any modern terminal.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")

    parser = argparse.ArgumentParser(description="Consolidated port of pull_top100_{class}.ps1")
    parser.add_argument("--class-name", required=True)
    parser.add_argument("--max-threads", type=int, default=10)
    parser.add_argument("--classes-root", default="data/Classes")
    args = parser.parse_args()

    pull_top100(args.class_name, args.max_threads, args.classes_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
