"""Redesigned replacement for update_hub_pages.ps1.

Per the approved migration plan, this is a deliberate redesign, not a
straight port: instead of regex-scraping already-rendered HTML back out to
figure out what rows already exist (update_hub_pages.ps1's approach), a
small per-healer data/Characters/{Name}/index.json and a top-level
data/site_index.json are the source of truth. Every hub-page update is:
load JSON -> upsert -> sort -> write JSON -> fully re-render both hub pages
from JSON + Jinja2 templates. This means:
  - A `docs/` wipe-and-regenerate is always safe (it wasn't before - the old
    approach mutated docs/ HTML in place with no other record of what
    should be there).
  - Inserting an already-listed report_code is a trivial, safe no-op update
    rather than needing a separate regex-based duplicate-detection scan.
  - "-IsNewHealer"/"-ResortOnly" are no longer separate flags: new-healer
    detection is a free dict-membership check, and "resort" is just
    "re-render" - both fall out of the same upsert_raid_night() call.

Sort order: raid_date descending, report_code ascending as an explicit,
deterministic tie-break - a cleaner invariant than the original's reliance
on "whatever order rows happened to be in the existing HTML," which only
worked because PowerShell's Sort-Object happens to be stable.
"""

from __future__ import annotations

from pathlib import Path

from pipeline import character_themes, classes as classes_module
from pipeline import jsonio, render_lib

DISPLAY_NAME_TO_CLASS = {cfg.display_name: key for key, cfg in classes_module.CLASSES.items()}


def _bosses_label(bosses_killed: int, bosses_attempted: int) -> str:
    if bosses_attempted > bosses_killed:
        return f"{bosses_killed}/{bosses_attempted} bosses"
    return f"{bosses_killed} {'boss killed' if bosses_killed == 1 else 'bosses killed'}"


def _raid_count_label(count: int) -> str:
    return f"{count} {'raid night' if count == 1 else 'raid nights'} analyzed"


def _healer_index_path(characters_root: str, character_name: str) -> Path:
    return Path(characters_root) / character_name / "index.json"


def load_healer_index(characters_root: str, character_name: str) -> dict | None:
    return jsonio.read_json_if_exists(_healer_index_path(characters_root, character_name))


def load_site_index(data_root: str = "data") -> dict:
    path = Path(data_root) / "site_index.json"
    data = jsonio.read_json_if_exists(path)
    return data if data else {"healers": []}


def _sort_raid_nights(raid_nights: list[dict]) -> list[dict]:
    return sorted(raid_nights, key=lambda r: (r["raid_date"], r["report_code"]), reverse=True)


def _sort_healers(healers: list[dict]) -> list[dict]:
    return sorted(healers, key=lambda h: h["character_name"].lower())


def upsert_raid_night(
    character_name: str,
    class_name: str,
    report_code: str,
    raid_date: str,
    raid_title: str,
    bosses_killed: int,
    bosses_attempted: int = 0,
    server: str = "Dreamscythe",
    region: str = "US",
    source: str = "v2",
    characters_root: str = "data/Characters",
    docs_root: str = "docs",
    templates_root: str = "templates_jinja",
    data_root: str = "data",
) -> None:
    """Loads (or creates) this healer's index.json, upserts the raid night
    by report_code, sorts, writes it back, then fully re-renders both hub
    pages. Also auto-registers the healer in site_index.json if this is
    their first raid night - no separate "-IsNewHealer" flag needed."""
    if class_name not in classes_module.CLASSES:
        raise ValueError(f"unrecognized ClassName '{class_name}' - must be one of {list(classes_module.CLASSES)}.")
    cfg = classes_module.get(class_name)
    healer_slug = character_name.lower()

    if bosses_attempted == 0:
        bosses_attempted = bosses_killed

    # Prefer the real, already-computed BossesKilled/BossesAttempted from
    # this report's own report_data.json over whatever was passed in -
    # matches the original's real-data override (guards a historical
    # wipe-miscounting bug).
    report_data_path = Path(characters_root) / character_name / report_code / f"{report_code}_report_data.json"
    if report_data_path.exists():
        real_report_data = jsonio.read_json(report_data_path)
        real_bosses_killed = len(real_report_data["Bosses"])
        real_bosses_attempted = real_report_data.get("BossesAttempted") or real_bosses_killed
        if real_bosses_killed != bosses_killed:
            print(f"  NOTE: bosses_killed={bosses_killed} passed, but {report_data_path} shows {real_bosses_killed} real boss kill(s) - using the real value.")
        if real_bosses_attempted != bosses_attempted:
            print(f"  NOTE: bosses_attempted={bosses_attempted} passed, but {report_data_path} shows {real_bosses_attempted} real distinct boss(es) attempted - using the real value.")
        bosses_killed = real_bosses_killed
        bosses_attempted = real_bosses_attempted

    index_data = load_healer_index(characters_root, character_name)
    is_new_healer = index_data is None
    if index_data is None:
        index_data = {
            "character_name": character_name, "class_name": class_name,
            "server": server, "region": region, "raid_nights": [],
        }

    new_entry = {
        "report_code": report_code, "raid_date": raid_date, "raid_title": raid_title,
        "bosses_killed": bosses_killed, "bosses_attempted": bosses_attempted, "source": source,
    }
    existing = next((r for r in index_data["raid_nights"] if r["report_code"] == report_code), None)
    if existing:
        index_data["raid_nights"][index_data["raid_nights"].index(existing)] = new_entry
        print(f"Report {report_code} already listed for {character_name} - updated in place.")
    else:
        index_data["raid_nights"].append(new_entry)
        print(f"Inserted new raid night for {character_name}: report {report_code}.")

    index_data["raid_nights"] = _sort_raid_nights(index_data["raid_nights"])
    jsonio.write_json(_healer_index_path(characters_root, character_name), index_data)

    render_healer_hub(index_data, docs_root, templates_root)

    site_index = load_site_index(data_root)
    if not any(h["character_name"] == character_name for h in site_index["healers"]):
        site_index["healers"].append({
            "character_name": character_name, "healer_slug": healer_slug,
            "class_name": class_name, "display_name": cfg.display_name,
        })
        site_index["healers"] = _sort_healers(site_index["healers"])
        jsonio.write_json(Path(data_root) / "site_index.json", site_index)
        render_site_index(site_index, docs_root, templates_root)
        print(f"Registered new healer '{character_name}' in site_index.json and re-rendered docs/index.html.")
        if is_new_healer:
            print("  NOTE: this healer is now linked from the site homepage. If you intended to keep them "
                  "unlisted (direct-URL-only), remove their entry from data/site_index.json and re-render.")


def resort_only(character_name: str, characters_root: str = "data/Characters", docs_root: str = "docs", templates_root: str = "templates_jinja") -> None:
    """Re-renders a healer's hub page from their existing index.json with no
    data mutation - trivial now, since re-rendering is always a full,
    deterministic rebuild from the JSON. There is no separate "resort"
    code path anymore; this is just render_healer_hub with no upsert."""
    index_data = load_healer_index(characters_root, character_name)
    if index_data is None:
        raise FileNotFoundError(f"no index.json found for '{character_name}' under {characters_root} - nothing to resort.")
    index_data["raid_nights"] = _sort_raid_nights(index_data["raid_nights"])
    jsonio.write_json(_healer_index_path(characters_root, character_name), index_data)
    render_healer_hub(index_data, docs_root, templates_root)


def render_healer_hub(index_data: dict, docs_root: str = "docs", templates_root: str = "templates_jinja") -> Path:
    env = render_lib.make_jinja_env(templates_root)
    template = env.get_template("healer_raidlist.html.jinja")
    cfg = classes_module.get(index_data["class_name"])

    raid_rows = []
    for r in index_data["raid_nights"]:
        raid_rows.append({
            "report_code": r["report_code"], "raid_title": r["raid_title"],
            "raid_date_display": render_lib.format_long_date(r["raid_date"]),
            "bosses_label": _bosses_label(r["bosses_killed"], r["bosses_attempted"]),
        })

    html = template.render(
        healer_name=index_data["character_name"], healer_class_spec=cfg.display_name,
        server=index_data["server"], region=index_data["region"],
        raid_count_label=_raid_count_label(len(raid_rows)), raid_nights=raid_rows,
        theme_style_block=character_themes.theme_style_block(index_data["character_name"], path_prefix=""),
        theme_tag=character_themes.theme_tag(index_data["character_name"]),
    )
    out_path = Path(docs_root) / index_data["character_name"].lower() / "index.html"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    jsonio.write_text(out_path, html)
    print(f"Wrote {out_path}")
    return out_path


def render_site_index(site_index: dict, docs_root: str = "docs", templates_root: str = "templates_jinja") -> Path:
    env = render_lib.make_jinja_env(templates_root)
    template = env.get_template("site_index.html.jinja")
    html = template.render(healers=site_index["healers"])
    out_path = Path(docs_root) / "index.html"
    jsonio.write_text(out_path, html)
    print(f"Wrote {out_path}")
    return out_path
