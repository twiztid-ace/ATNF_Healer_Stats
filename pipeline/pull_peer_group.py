"""Phase 4 of the additive coaching-style analysis layer: peer-group
comparison. Pulls a real peer pool for one (class, boss, size, duration)
combination from WCL v2's characterRankings, coarse-filtered by raid size
and fight duration (confirmed live 2026-07-20: found 164 real peers for one
boss kill from rankings pages alone, zero extra calls beyond the rankings
pages themselves), then one table(dataType: Summary) call per coarse-
surviving candidate for real healer-count/item-level context.

Cached per class+boss+size+duration-bucket (NOT per character), so the same
peer pool is reused across every tracked healer of that class who killed
that boss with a similar raid size/duration - see the approved plan's Phase
4 risk note on why this dedup is load-bearing, not optional polish, at
scale (an un-deduped `generate-all` could multiply this pull's real cost by
every tracked healer x every boss they killed).

Deliberately simpler than pull_top100.py's active/archived+manifest model:
a peer pool for a fixed PAST duration bucket doesn't need day-to-day
membership tracking the way a live, constantly-refreshing Top 100 ranking
does - once fetched, a cache file is reused indefinitely. A fresh
--force-refresh is a real, deliberate manual step, never something this
module decides on its own.

Genuinely opt-in and NOT part of the routine pipeline (see cli.py's
--with-peer-comparison flag) - the real per-call cost (one Summary table
call per coarse-matched candidate) is too high to run unconditionally on
every report generation.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from pipeline import bosses as bosses_module
from pipeline import classes as classes_module
from pipeline import jsonio, wcl_api

DURATION_TOLERANCE = 0.20
# `characterRankings(metric: hps, page: N)` returns entries HPS-DESCENDING -
# scanning pages 1..N and stopping as soon as MAX_PEER_CANDIDATES coarse
# matches accumulate would silently take the highest-HPS matching parses
# first, recreating exactly the "compared against the best, not real peers"
# bias this whole phase exists to eliminate (confirmed live 2026-07-20: an
# early version of this file did exactly that and returned "below average"
# for all 12 of one real healer's real kills - not plausible variance, a
# real methodology bug). Fixed by scanning a wide page range in full, THEN
# evenly downsampling across the whole matched range - see the
# `coarse[::step]` line below.
MAX_RANKING_PAGES = 8
# Real, deliberate cost cap - one Summary table() call per candidate here,
# so this bounds Phase 4's worst-case per-boss API cost. 40 real peers is
# still a meaningful comparison sample; this is not a claim that 40 is the
# true total population size.
MAX_PEER_CANDIDATES = 40


def _duration_bucket_label(duration_ms: float) -> str:
    """20-second buckets, floor-rounded - e.g. a real 146.6s kill maps to
    "140-160s". Coarse but stable: two healers' kills at 146.6s and 152.1s
    on the same boss/size share one cached peer pool instead of minting a
    new one for every slightly-different real duration."""
    bucket_start = int(duration_ms // 20000) * 20
    return f"{bucket_start}-{bucket_start + 20}s"


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def pull_peer_group(
    class_name: str, boss_slug: str, target_duration_ms: float, target_size: int,
    classes_root: str = "data/Classes", force_refresh: bool = False,
) -> dict[str, Any]:
    cfg = classes_module.get(class_name)
    meta = bosses_module.by_slug(boss_slug)
    if meta is None:
        raise KeyError(f"'{boss_slug}' has no known boss metadata - see pipeline/bosses.py.")

    bucket = _duration_bucket_label(target_duration_ms)
    out_dir = Path(classes_root) / class_name / "PeerGroups" / meta.folder_name
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"size{target_size}_{bucket}.json"

    if out_file.exists() and not force_refresh:
        print(f"  Reusing cached peer pool: {out_file}")
        return jsonio.read_json(out_file)

    token = wcl_api.get_wcl_access_token()
    print(f"  Fetching real peer pool: {class_name}/{meta.display}, size={target_size}, duration bucket {bucket}...")

    coarse: list[dict] = []
    for page in range(1, MAX_RANKING_PAGES + 1):
        q = (
            f'query {{ worldData {{ encounter(id: {meta.encounter_id}) {{ '
            f'characterRankings(className: "{cfg.wcl_class_name}", specName: "{cfg.wcl_spec_name}", '
            f'metric: hps, page: {page}) }} }} }}'
        )
        r = wcl_api.invoke_wcl_graphql(q, access_token=token)
        if r.errors:
            print(f"    page {page} FAILED: {r.errors}")
            break
        data = r.data["worldData"]["encounter"]["characterRankings"]
        for entry in data["rankings"]:
            if entry.get("size") != target_size:
                continue
            dur = entry.get("duration", 0)
            if dur and abs(dur - target_duration_ms) / target_duration_ms <= DURATION_TOLERANCE:
                coarse.append(entry)
        if not data.get("hasMorePages"):
            break
    print(f"    {len(coarse)} coarse-matched candidate(s) (real size+duration match) found across the scanned range.")

    # Evenly downsample across the WHOLE matched range rather than taking a
    # prefix - `coarse` is ordered HPS-descending (see MAX_RANKING_PAGES's
    # docstring above), so a prefix would silently mean "the best-performing
    # matches", not a real cross-section of real peers.
    if len(coarse) > MAX_PEER_CANDIDATES:
        step = len(coarse) / MAX_PEER_CANDIDATES
        sampled = [coarse[int(i * step)] for i in range(MAX_PEER_CANDIDATES)]
    else:
        sampled = coarse
    print(f"    Downsampled to {len(sampled)} candidate(s), evenly spread across the real HPS range, for the real per-candidate Summary lookup.")

    candidates = []
    for entry in sampled:
        report_code = entry["report"]["code"]
        fight_id = entry["report"]["fightID"]
        q = f'query {{ reportData {{ report(code: "{report_code}") {{ table(fightIDs: [{fight_id}], dataType: Summary) }} }} }}'
        r = wcl_api.invoke_wcl_graphql(q, access_token=token)
        healer_count = None
        item_level = None
        if not r.errors and r.data:
            table = r.data["reportData"]["report"].get("table")
            if table and table.get("data"):
                item_level = table["data"].get("itemLevel")
                comp = table["data"].get("composition") or []
                healer_count = sum(1 for p in comp for s in (p.get("specs") or []) if s.get("role") == "healer")
        candidates.append({
            "Name": entry["name"], "Amount": entry["amount"], "Duration": entry["duration"],
            "Size": entry["size"], "ReportCode": report_code, "FightID": fight_id,
            "HealerCount": healer_count, "ItemLevel": item_level,
        })
    print(f"    {len(candidates)} real candidate(s) fetched with Summary-table context (healer count/item level).")

    peer_pool = {
        "ClassName": class_name, "BossSlug": boss_slug, "BossDisplay": meta.display,
        "TargetSize": target_size, "DurationBucket": bucket, "DurationToleranceRatio": DURATION_TOLERANCE,
        "FetchedAt": _now_iso(),
        "Candidates": candidates,
    }
    jsonio.write_json(out_file, peer_pool)
    print(f"  Wrote {out_file}")
    return peer_pool


def main() -> int:
    parser = argparse.ArgumentParser(description="Phase 4 coaching-layer peer-group pull (opt-in, real API cost)")
    parser.add_argument("--class-name", required=True)
    parser.add_argument("--boss-slug", required=True)
    parser.add_argument("--target-duration-ms", type=float, required=True)
    parser.add_argument("--target-size", type=int, required=True)
    parser.add_argument("--classes-root", default="data/Classes")
    parser.add_argument("--force-refresh", action="store_true")
    args = parser.parse_args()

    pull_peer_group(args.class_name, args.boss_slug, args.target_duration_ms, args.target_size, args.classes_root, args.force_refresh)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
