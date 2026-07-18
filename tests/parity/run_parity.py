"""Parity-test harness: run a PowerShell script and its Python port against
copies of the same real input, then diff their outputs.

Reused by every migration phase's parity test with different arguments -
see the migration plan's per-phase "Verification" sections. Never runs
either implementation against the live data directory directly; always
against scratch copies, so a bug in either script can't corrupt real,
already-pulled data.
"""

import shutil
import subprocess
import sys
from pathlib import Path

from .deep_diff import Diff, DiffResult, deep_diff, deep_diff_csv_rows
from pipeline import jsonio, csvio

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRATCH_ROOT = REPO_ROOT / "tests" / "parity" / "_scratch"


def make_scratch_copy(source_dir: Path, label: str) -> Path:
    """Copies source_dir into a fresh scratch subfolder, returns its path.
    Two calls with different labels (e.g. "old", "new") give each
    implementation its own isolated output area."""
    dest = SCRATCH_ROOT / label
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True, exist_ok=True)
    if source_dir.exists():
        shutil.copytree(source_dir, dest, dirs_exist_ok=True)
    return dest


def clear_scratch() -> None:
    if SCRATCH_ROOT.exists():
        shutil.rmtree(SCRATCH_ROOT)


def run_powershell(script_path: Path, args: list[str], cwd: Path = REPO_ROOT) -> subprocess.CompletedProcess:
    cmd = ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(script_path), *args]
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def run_python_module(module: str, args: list[str], cwd: Path = REPO_ROOT) -> subprocess.CompletedProcess:
    cmd = [sys.executable, "-m", module, *args]
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def compare_json_files(old_path: Path, new_path: Path, allowlist_paths: set[str] | None = None) -> DiffResult:
    result = DiffResult()
    if not old_path.exists():
        result.diffs.append(Diff("$", str(old_path), None, "old file missing"))
    if not new_path.exists():
        result.diffs.append(Diff("$", None, str(new_path), "new file missing"))
    if result.diffs:
        return result
    old_obj = jsonio.read_json(old_path)
    new_obj = jsonio.read_json(new_path)
    return deep_diff(old_obj, new_obj, allowlist_paths=allowlist_paths)


def compare_csv_files(old_path: Path, new_path: Path, key_fields: list[str]) -> DiffResult:
    old_rows = csvio.read_csv(old_path)
    new_rows = csvio.read_csv(new_path)
    return deep_diff_csv_rows(old_rows, new_rows, key_fields)


def print_result(label: str, result: DiffResult) -> bool:
    print(f"--- {label} ---")
    print(result.report())
    return result.ok
