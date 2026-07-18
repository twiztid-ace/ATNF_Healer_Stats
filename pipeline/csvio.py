"""CSV write helper matching Export-Csv -Encoding UTF8's behavior.

On Windows PowerShell 5.1, `Export-Csv -Encoding UTF8` always adds a BOM -
kept deliberately in the existing pipeline for Excel compatibility (contrast
with jsonio.py, where JSON is always written WITHOUT a BOM). This asymmetry
is intentional and preserved here via `encoding="utf-8-sig"`.

Open risk flagged in the migration plan: confirm with the project owner
whether Excel is still a real consumer of these CSVs before assuming this
needs to stay - if not, drop `-sig` and simplify to one code path.
"""

import csv
from pathlib import Path
from typing import Any


def write_csv(path: Path | str, rows: list[dict[str, Any]], fieldnames: list[str] | None = None) -> None:
    if fieldnames is None:
        fieldnames = list(rows[0].keys()) if rows else []
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def read_csv(path: Path | str) -> list[dict[str, str]]:
    """Mirrors Import-Csv: every value comes back as a string (or ''), same
    as PowerShell's CSV import - callers use ConvertTo-BMNumber-equivalent
    parsing (see render_lib.py) rather than relying on this to type-convert."""
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))
