"""BOM-less UTF-8 JSON read/write helpers.

Matches every PowerShell script's [System.IO.File]::WriteAllText(...,
(New-Object System.Text.UTF8Encoding $false)) convention - JSON is always
written WITHOUT a BOM in this pipeline (contrast with csvio.py, where a BOM
is added deliberately for Excel compatibility - see that module's docstring).
"""

import json
from pathlib import Path
from typing import Any


def read_json(path: Path | str) -> Any:
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def read_json_if_exists(path: Path | str) -> Any | None:
    p = Path(path)
    if not p.exists():
        return None
    return read_json(p)


def write_json(path: Path | str, obj: Any, indent: int = 2) -> None:
    text = json.dumps(obj, indent=indent, ensure_ascii=False)
    write_text(path, text)


def write_text(path: Path | str, text: str) -> None:
    """Writes plain text (e.g. the v2 access token file) BOM-less, UTF-8."""
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def read_text(path: Path | str) -> str:
    with open(path, "r", encoding="utf-8-sig") as f:
        return f.read()
