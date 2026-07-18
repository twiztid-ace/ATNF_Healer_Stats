"""Stdlib-only recursive diff for comparing PowerShell-generated output
against Python-generated output during the migration.

Deliberately not the `deepdiff` package (see the migration plan's "Explicitly
no pandas"-style reasoning: the need here is narrow enough that a ~100-line
hand-rolled differ is more transparent for parity work than a general-purpose
dependency). Ignores dict key order (PowerShell's ConvertTo-Json and Python's
json.dumps don't guarantee the same key ordering even for logically identical
objects) and applies a float tolerance, since PowerShell's [double] and
Python's float can differ in the last ULP on some divisions.
"""

from dataclasses import dataclass, field
from typing import Any


@dataclass
class Diff:
    path: str
    old: Any
    new: Any
    reason: str


@dataclass
class DiffResult:
    diffs: list[Diff] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return len(self.diffs) == 0

    def report(self) -> str:
        if self.ok:
            return "PARITY OK - no differences found."
        lines = [f"PARITY FAILED - {len(self.diffs)} difference(s):"]
        for d in self.diffs:
            lines.append(f"  {d.path}: {d.reason} (old={d.old!r}, new={d.new!r})")
        return "\n".join(lines)


def _is_number(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def deep_diff(
    old: Any,
    new: Any,
    path: str = "$",
    float_rel_tol: float = 1e-9,
    float_abs_tol: float = 1e-6,
    allowlist_paths: set[str] | None = None,
) -> DiffResult:
    """Compares two JSON-shaped trees (dict/list/scalar). `allowlist_paths`
    is an exact-match set of dotted paths permitted to differ without being
    reported - used for known-drift fields like rankings()-sourced
    percentile/rank data (see the migration plan's Phase 5 verification
    section on live-data drift)."""
    result = DiffResult()
    _walk(old, new, path, float_rel_tol, float_abs_tol, allowlist_paths or set(), result)
    return result


def _walk(old, new, path, rtol, atol, allowlist, result: DiffResult):
    if path in allowlist:
        return

    if old is None and new is None:
        return
    if old is None or new is None:
        if old != new:
            result.diffs.append(Diff(path, old, new, "one side is null"))
        return

    if _is_number(old) and _is_number(new):
        if abs(old - new) > max(atol, rtol * max(abs(old), abs(new))):
            result.diffs.append(Diff(path, old, new, "numeric value differs beyond tolerance"))
        return

    if isinstance(old, dict) and isinstance(new, dict):
        old_keys = set(old.keys())
        new_keys = set(new.keys())
        for k in sorted(old_keys - new_keys):
            result.diffs.append(Diff(f"{path}.{k}", old[k], None, "key missing in new"))
        for k in sorted(new_keys - old_keys):
            result.diffs.append(Diff(f"{path}.{k}", None, new[k], "key missing in old"))
        for k in sorted(old_keys & new_keys):
            _walk(old[k], new[k], f"{path}.{k}", rtol, atol, allowlist, result)
        return

    if isinstance(old, list) and isinstance(new, list):
        if len(old) != len(new):
            result.diffs.append(Diff(path, len(old), len(new), "list length differs"))
            return
        for i, (o, n) in enumerate(zip(old, new)):
            _walk(o, n, f"{path}[{i}]", rtol, atol, allowlist, result)
        return

    if old != new:
        result.diffs.append(Diff(path, old, new, "value differs"))


def deep_diff_csv_rows(
    old_rows: list[dict[str, str]],
    new_rows: list[dict[str, str]],
    key_fields: list[str],
    float_rel_tol: float = 1e-6,
) -> DiffResult:
    """Row-content diff for CSV output, keyed by `key_fields` rather than row
    order (order is not guaranteed to matter for these CSVs, content is)."""
    result = DiffResult()

    def key_of(row: dict[str, str]) -> tuple:
        return tuple(row.get(k, "") for k in key_fields)

    old_by_key = {key_of(r): r for r in old_rows}
    new_by_key = {key_of(r): r for r in new_rows}

    for k in sorted(set(old_by_key) - set(new_by_key)):
        result.diffs.append(Diff(str(k), old_by_key[k], None, "row missing in new"))
    for k in sorted(set(new_by_key) - set(old_by_key)):
        result.diffs.append(Diff(str(k), None, new_by_key[k], "row missing in old"))

    for k in sorted(set(old_by_key) & set(new_by_key)):
        old_row, new_row = old_by_key[k], new_by_key[k]
        all_fields = set(old_row.keys()) | set(new_row.keys())
        for field_name in sorted(all_fields):
            ov, nv = old_row.get(field_name, ""), new_row.get(field_name, "")
            if ov == nv:
                continue
            try:
                of, nf = float(ov), float(nv)
                if abs(of - nf) <= max(1e-6, float_rel_tol * max(abs(of), abs(nf))):
                    continue
            except (ValueError, TypeError):
                pass
            result.diffs.append(Diff(f"{k}.{field_name}", ov, nv, "csv field differs"))

    return result
