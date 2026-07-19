"""Single orchestrator CLI for the Python pipeline.

One subcommand per pipeline stage, plus a chaining `generate` command that
runs the whole thing - auto-resolving the character's real class/spec (see
pull_character.py's pipeline_class_name resolution, which the PowerShell
original never persisted anywhere, relying on a human reading console
output instead) and dispatching pull-top100/summarize-benchmarks for the
right class automatically.

`generate` stops before the findings-authoring step unless
--placeholder-findings is passed - findings.json is the one step that
genuinely needs real judgment (an LLM, or a human), not something this CLI
can produce on its own. This is the "data only" one-liner described in
README.md; the "with Claude findings" one-liner is still the
generate-healer-report skill, which shells out to this same CLI for every
other step.
"""

from __future__ import annotations

import argparse
import sys

from pipeline import (
    build_analysis as build_analysis_module,
    build_report_data as build_report_data_module,
    hub_pages,
    jsonio,
    paths,
    placeholder_findings as placeholder_findings_module,
    pull_character as pull_character_module,
    pull_top100 as pull_top100_module,
    render_report as render_report_module,
    summarize_benchmarks as summarize_benchmarks_module,
)


def _findings_source(findings_path) -> str:
    """"placeholder" if findings.json's content is actually the placeholder
    text (whether written moments ago via --placeholder-findings, or already
    sitting there from an earlier placeholder run), "pipeline" otherwise.
    Checked by content rather than by whether --placeholder-findings was
    passed on *this* invocation, since a prior real findings.json is reused
    as-is (see the "Using existing ..." branches above) regardless of that
    flag."""
    findings = jsonio.read_json(findings_path)
    if findings.get("RaidOverview", {}).get("RAID_SUMMARY_FINDING") == placeholder_findings_module.PLACEHOLDER:
        return "placeholder"
    return "pipeline"


def _add_common_roots(parser: argparse.ArgumentParser, *, characters=True, classes=False, templates=False, docs=False, data=False) -> None:
    if characters:
        parser.add_argument("--characters-root", default="data/Characters")
    if classes:
        parser.add_argument("--classes-root", default="data/Classes")
    if templates:
        parser.add_argument("--templates-root", default="templates_jinja")
    if docs:
        parser.add_argument("--docs-root", default="docs")
    if data:
        parser.add_argument("--data-root", default="data")


def cmd_pull_character(args: argparse.Namespace) -> int:
    result = pull_character_module.pull_character(
        args.report_code, args.character_name, args.server, args.region, args.class_name,
        args.spec, args.date_override, args.max_threads, args.characters_root,
    )
    print(f"\nResolved pipeline class: {result['pipeline_class_name']} (WCL: {result['wcl_class_name']}/{result['resolved_spec']})")
    return 0


def cmd_pull_top100(args: argparse.Namespace) -> int:
    pull_top100_module.pull_top100(args.class_name, args.max_threads, args.classes_root)
    return 0


def cmd_summarize_benchmarks(args: argparse.Namespace) -> int:
    summarize_benchmarks_module.summarize_benchmarks(args.class_name, args.classes_root_override, args.date_folder)
    return 0


def cmd_build_report_data(args: argparse.Namespace) -> int:
    build_report_data_module.build_report_data(args.character_name, args.report_code, args.class_name, args.characters_root, args.classes_root)
    return 0


def cmd_build_analysis(args: argparse.Namespace) -> int:
    build_analysis_module.build_analysis(args.character_name, args.report_code, args.class_name, args.characters_root)
    return 0


def cmd_placeholder_findings(args: argparse.Namespace) -> int:
    placeholder_findings_module.build_placeholder_findings(args.character_name, args.report_code, args.characters_root, args.force)
    return 0


def cmd_render(args: argparse.Namespace) -> int:
    render_report_module.render_healer_report(
        args.character_name, args.report_code, args.class_name, args.healer_slug,
        args.raid_title, args.characters_root, args.templates_root, args.output_root,
    )
    return 0


def cmd_update_hub(args: argparse.Namespace) -> int:
    if args.resort_only:
        hub_pages.resort_only(args.character_name, args.characters_root, args.docs_root, args.templates_root)
    else:
        missing = [f"--{name}" for name, val in (
            ("raid-date", args.raid_date), ("report-code", args.report_code),
            ("class-name", args.class_name), ("bosses-killed", args.bosses_killed), ("raid-title", args.raid_title),
        ) if not val]
        if missing:
            print(f"ERROR: missing required argument(s): {', '.join(missing)} (all required unless --resort-only is passed).")
            return 1
        hub_pages.upsert_raid_night(
            args.character_name, args.class_name, args.report_code, args.raid_date, args.raid_title,
            args.bosses_killed, args.bosses_attempted, args.server, args.region, "pipeline",
            args.characters_root, args.docs_root, args.templates_root, args.data_root,
        )
    return 0


def cmd_generate(args: argparse.Namespace) -> int:
    print("=== generate: step 1/6 - pull character data ===")
    pull_result = pull_character_module.pull_character(
        args.report_code, args.character_name, spec=args.spec, max_threads=args.max_threads,
        characters_root=args.characters_root,
    )
    class_name = pull_result["pipeline_class_name"]
    if not class_name:
        print(
            f"ERROR: could not resolve a supported pipeline class from WCL class "
            f"'{pull_result['wcl_class_name']}' / spec '{pull_result['resolved_spec']}'. "
            f"This class/spec combination isn't on the pipeline yet - see pipeline/classes.py."
        )
        return 1
    print(f"Resolved pipeline class: {class_name}")

    print(f"\n=== generate: step 2/6 - refresh {class_name}'s Top 100 benchmark ===")
    pull_top100_module.pull_top100(class_name, args.max_threads, args.classes_root)

    print(f"\n=== generate: step 3/6 - re-summarize {class_name} benchmarks ===")
    summarize_benchmarks_module.summarize_benchmarks(class_name, args.classes_root)

    print("\n=== generate: step 4/6 - compute report data + analysis ===")
    build_report_data_module.build_report_data(args.character_name, args.report_code, class_name, args.characters_root, args.classes_root)
    build_analysis_module.build_analysis(args.character_name, args.report_code, class_name, args.characters_root)

    char_root = args.characters_root
    report_data_file = paths.find_file_recursive(f"{char_root}/{args.character_name}", f"{args.report_code}_report_data.json")
    char_dir = report_data_file.parent
    findings_path = char_dir / f"{args.report_code}_findings.json"

    print("\n=== generate: step 5/6 - findings ===")
    if not findings_path.exists():
        if args.placeholder_findings:
            placeholder_findings_module.build_placeholder_findings(args.character_name, args.report_code, args.characters_root)
        else:
            print(
                f"No findings.json exists yet at {findings_path}.\n"
                f"This is the one step that needs real judgment - run the generate-healer-report skill in\n"
                f"Claude Code, hand-author {args.report_code}_findings.json yourself (see the schema in\n"
                f"render_report.py's docstring), or re-run this command with --placeholder-findings for a\n"
                f"data-only placeholder version. Then re-run:\n"
                f"  python -m pipeline.cli render --character-name {args.character_name} --report-code {args.report_code} --class-name {class_name}\n"
                f"  python -m pipeline.cli update-hub --character-name {args.character_name} --report-code {args.report_code} "
                f"--class-name {class_name} --raid-date {pull_result['raid_date']} --raid-title \"{args.raid_title}\" --bosses-killed <N>"
            )
            return 0
    else:
        print(f"Using existing {findings_path}.")

    print("\n=== generate: step 6/6 - render + update hub pages ===")
    render_report_module.render_healer_report(
        args.character_name, args.report_code, class_name, raid_title=args.raid_title,
        characters_root=args.characters_root, templates_root=args.templates_root, output_root=args.docs_root,
    )

    report_data = jsonio.read_json(report_data_file)
    bosses_killed = len(report_data["Bosses"])
    bosses_attempted = report_data.get("BossesAttempted") or bosses_killed
    hub_pages.upsert_raid_night(
        args.character_name, class_name, args.report_code, pull_result["raid_date"], args.raid_title,
        bosses_killed, bosses_attempted, args.server, args.region,
        _findings_source(findings_path),
        args.characters_root, args.docs_root, args.templates_root, args.data_root,
    )

    print("\nDone.")
    return 0


def cmd_generate_all(args: argparse.Namespace) -> int:
    site_index = hub_pages.load_site_index(args.data_root)
    if args.character_names:
        names = [n.strip() for n in args.character_names.split(",") if n.strip()]
    else:
        names = [h["character_name"] for h in site_index["healers"]]

    if not names:
        print(
            "No healers registered in data/site_index.json, and no --character-names override "
            "was given - nothing to do. (Registering a healer's first report via `generate` also "
            "registers them here for future generate-all runs.)"
        )
        return 1

    print(f"=== generate-all: report {args.report_code} against {len(names)} already-tracked healer(s): {', '.join(names)} ===")

    class_names_refreshed: set[str] = set()
    results: list[tuple[str, str, str]] = []

    for name in names:
        print(f"\n--- {name} ---")
        try:
            pull_result = pull_character_module.pull_character(
                args.report_code, name, max_threads=args.max_threads, characters_root=args.characters_root,
            )
        except RuntimeError as exc:
            message = str(exc)
            # Per-character conditions (not in this report's actors[], or plays
            # more than one spec and needs an explicit --spec) only rule this
            # one healer out - every other name may still be a real hit. Any
            # other RuntimeError (bad/private report code, API failure) will
            # fail identically for every remaining name, so stop the batch
            # instead of burning API calls repeating the same failure N times.
            if "was not found in this report's actors" in message or "plays more than one real spec" in message:
                print(f"  SKIP {name}: {message}")
                results.append((name, "skipped", message.splitlines()[0]))
                continue
            print(f"  ERROR {name}: {message}")
            print("  This looks like a report-level failure (bad/private report code, or an API error) "
                  "rather than something specific to this healer - stopping the batch rather than "
                  "repeating the same failure for every remaining name.")
            results.append((name, "error", message.splitlines()[0]))
            break

        class_name = pull_result["pipeline_class_name"]
        if not class_name:
            print(f"  SKIP {name}: unsupported class/spec (WCL: {pull_result['wcl_class_name']}/{pull_result['resolved_spec']}) - not on the pipeline yet.")
            results.append((name, "skipped", "unsupported class/spec"))
            continue
        if pull_result["boss_fights_count"] == 0:
            print(f"  SKIP {name}: 0 boss kills resolved for this character/spec in this report (not present, benched, or off-spec throughout).")
            results.append((name, "skipped", "0 boss kills in this report"))
            continue
        print(f"  Resolved pipeline class: {class_name}")

        if class_name not in class_names_refreshed:
            print(f"  Refreshing {class_name}'s Top 100 benchmark...")
            pull_top100_module.pull_top100(class_name, args.max_threads, args.classes_root)
            summarize_benchmarks_module.summarize_benchmarks(class_name, args.classes_root)
            class_names_refreshed.add(class_name)
        else:
            print(f"  {class_name}'s Top 100 benchmark already refreshed earlier this run - reusing.")

        build_report_data_module.build_report_data(name, args.report_code, class_name, args.characters_root, args.classes_root)
        build_analysis_module.build_analysis(name, args.report_code, class_name, args.characters_root)

        report_data_file = paths.find_file_recursive(f"{args.characters_root}/{name}", f"{args.report_code}_report_data.json")
        char_dir = report_data_file.parent
        findings_path = char_dir / f"{args.report_code}_findings.json"

        if not findings_path.exists():
            if args.placeholder_findings:
                placeholder_findings_module.build_placeholder_findings(name, args.report_code, args.characters_root)
            else:
                print(f"  {name}: report_data.json + analysis.json ready, but no findings.json yet - "
                      f"skipping render/hub for now. Author {findings_path} (see render_report.py's "
                      f"docstring, or the generate-healer-report skill), then re-run this same command.")
                results.append((name, "needs-findings", str(findings_path)))
                continue
        else:
            print(f"  Using existing {findings_path}.")

        render_report_module.render_healer_report(
            name, args.report_code, class_name, raid_title=args.raid_title,
            characters_root=args.characters_root, templates_root=args.templates_root, output_root=args.docs_root,
        )

        report_data = jsonio.read_json(report_data_file)
        bosses_killed = len(report_data["Bosses"])
        bosses_attempted = report_data.get("BossesAttempted") or bosses_killed
        hub_pages.upsert_raid_night(
            name, class_name, args.report_code, pull_result["raid_date"], args.raid_title,
            bosses_killed, bosses_attempted, args.server, args.region,
            _findings_source(findings_path),
            args.characters_root, args.docs_root, args.templates_root, args.data_root,
        )
        results.append((name, "done", f"{bosses_killed}/{bosses_attempted} bosses"))

    print("\n=== generate-all summary ===")
    for name, status, detail in results:
        print(f"  {name}: {status} - {detail}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m pipeline.cli", description="ATNF Healer Analysis pipeline orchestrator")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("pull-character", help="Pull one healer's full raid night")
    p.add_argument("--report-code", required=True)
    p.add_argument("--character-name", required=True)
    p.add_argument("--server", default=None)
    p.add_argument("--region", default=None)
    p.add_argument("--class-name", default=None)
    p.add_argument("--spec", default=None)
    p.add_argument("--date-override", default=None)
    p.add_argument("--max-threads", type=int, default=10)
    _add_common_roots(p)
    p.set_defaults(func=cmd_pull_character)

    p = sub.add_parser("pull-top100", help="Refresh one class's Top 100 benchmark")
    p.add_argument("--class-name", required=True)
    p.add_argument("--max-threads", type=int, default=10)
    _add_common_roots(p, characters=False, classes=True)
    p.set_defaults(func=cmd_pull_top100)

    p = sub.add_parser("summarize-benchmarks", help="Re-summarize a class's Top 100 CSVs")
    p.add_argument("--class-name", required=True)
    p.add_argument("--classes-root-override", default=None)
    p.add_argument("--date-folder", default=None)
    p.set_defaults(func=cmd_summarize_benchmarks)

    p = sub.add_parser("build-report-data", help="Compute report_data.json (zero API calls)")
    p.add_argument("--character-name", required=True)
    p.add_argument("--report-code", required=True)
    p.add_argument("--class-name", required=True)
    _add_common_roots(p, classes=True)
    p.set_defaults(func=cmd_build_report_data)

    p = sub.add_parser("build-analysis", help="Pre-flag script-safe judgment calls into analysis.json")
    p.add_argument("--character-name", required=True)
    p.add_argument("--report-code", required=True)
    p.add_argument("--class-name", required=True)
    _add_common_roots(p)
    p.set_defaults(func=cmd_build_analysis)

    p = sub.add_parser("placeholder-findings", help="Write a placeholder findings.json (data-only, no LLM)")
    p.add_argument("--character-name", required=True)
    p.add_argument("--report-code", required=True)
    p.add_argument("--force", action="store_true")
    _add_common_roots(p)
    p.set_defaults(func=cmd_placeholder_findings)

    p = sub.add_parser("render", help="Render boss pages + raid overview from report_data/analysis/findings")
    p.add_argument("--character-name", required=True)
    p.add_argument("--report-code", required=True)
    p.add_argument("--class-name", required=True)
    p.add_argument("--healer-slug", default=None)
    p.add_argument("--raid-title", default="SSC / TK")
    _add_common_roots(p, templates=True, docs=False)
    p.add_argument("--output-root", default="docs")
    p.set_defaults(func=cmd_render)

    p = sub.add_parser("update-hub", help="Upsert a raid night into both hub pages (or --resort-only)")
    p.add_argument("--character-name", required=True)
    p.add_argument("--raid-date", default=None)
    p.add_argument("--report-code", default=None)
    p.add_argument("--class-name", default=None)
    p.add_argument("--bosses-killed", type=int, default=None)
    p.add_argument("--bosses-attempted", type=int, default=0)
    p.add_argument("--raid-title", default=None)
    p.add_argument("--server", default="Dreamscythe")
    p.add_argument("--region", default="US")
    p.add_argument("--resort-only", action="store_true")
    _add_common_roots(p, templates=True, docs=True, data=True)
    p.set_defaults(func=cmd_update_hub)

    p = sub.add_parser("generate", help="Run the full pipeline end to end")
    p.add_argument("--character-name", required=True)
    p.add_argument("--report-code", required=True)
    p.add_argument("--spec", default=None)
    p.add_argument("--raid-title", default="SSC / TK")
    p.add_argument("--server", default="Dreamscythe")
    p.add_argument("--region", default="US")
    p.add_argument("--max-threads", type=int, default=10)
    p.add_argument("--placeholder-findings", action="store_true", help="Data-only run: stand in for the LLM findings-authoring step with placeholder text")
    _add_common_roots(p, classes=True, templates=True, docs=True, data=True)
    p.set_defaults(func=cmd_generate)

    p = sub.add_parser("generate-all", help="Run the full pipeline for every already-tracked healer against one report code")
    p.add_argument("--report-code", required=True)
    p.add_argument("--character-names", default=None, help="Comma-separated override list; default is every healer already in data/site_index.json")
    p.add_argument("--raid-title", default="SSC / TK")
    p.add_argument("--server", default="Dreamscythe")
    p.add_argument("--region", default="US")
    p.add_argument("--max-threads", type=int, default=10)
    p.add_argument("--placeholder-findings", action="store_true", help="Data-only run: stand in for the LLM findings-authoring step with placeholder text, for every healer that needs it")
    _add_common_roots(p, classes=True, templates=True, docs=True, data=True)
    p.set_defaults(func=cmd_generate_all)

    return parser


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")

    parser = build_parser()
    args = parser.parse_args()
    try:
        return args.func(args)
    except (FileNotFoundError, FileExistsError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
