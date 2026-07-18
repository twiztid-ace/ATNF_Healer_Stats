"""Shared OAuth2 + GraphQL client for Warcraft Logs' v2 API.

Function-for-function port of scripts/lib/WclV2Api.psm1. Requires the same
three gitignored files at the repo root: v2_client_id.txt, v2_client_secret.txt,
and v2_access_token.txt (created automatically on first use).

Two PowerShell-specific gotchas documented in the original module simply
don't apply here and are not ported:
  - The `.GetNewClosure()` scoping gotcha (Invoke-WclGraphQLPaged's
    $QueryBuilder) - Python closures capture enclosing-scope variables
    correctly by default.
  - The `List[object]` -> `@()` array-collapse bug - Python lists have no
    such coercion trap.
"""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

import requests

from pipeline import jsonio

TOKEN_ENDPOINT = "https://www.warcraftlogs.com/oauth/token"
GRAPHQL_ENDPOINT = "https://www.warcraftlogs.com/api/v2/client"
# (connect, read) timeout tuple for every request in this module - a stalled
# socket must surface as a normal error result within a bounded time instead
# of hanging a worker thread indefinitely (pull_top100.py/pull_character.py
# fan these calls out across a ThreadPoolExecutor).
REQUEST_TIMEOUT = (10, 30)


@dataclass
class WclResult:
    data: Any
    errors: list | None


@dataclass
class PageResult:
    items: list
    next_page_timestamp: float | None


@dataclass
class PagedResult:
    items: list
    errors: list | None
    page_count: int


@dataclass
class ConsumableClassification:
    flask: dict | None
    battle_elixir: dict | None
    guardian_elixir: dict | None


def get_wcl_jwt_expiry(token: str) -> datetime:
    """Decodes a JWT's payload segment (no signature verification - we only
    need our own token's exp claim) and returns the expiry as a UTC datetime.

    Confirmed live (Phase 2 parity testing) that WCL's `exp` claim is a JSON
    float with a fractional-second component (e.g. 1815001557.993964), not a
    bare integer. `int(...)` truncates toward zero here, matching RFC 7519's
    NumericDate interpretation; PowerShell's `[int64]` cast on the equivalent
    double instead rounds to nearest, so Get-WclJwtExpiry can read exactly
    1 second later than this function for the same token. Immaterial to the
    5-minute refresh buffer either way - documented so it isn't mistaken for
    a real bug if ever compared side-by-side again."""
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError(f"Not a JWT (expected 3 dot-separated segments, got {len(parts)})")
    payload = parts[1].replace("-", "+").replace("_", "/")
    payload += "=" * ((4 - len(payload) % 4) % 4)
    decoded = json.loads(base64.b64decode(payload).decode("utf-8"))
    return datetime.fromtimestamp(int(decoded["exp"]), tz=timezone.utc)


def get_wcl_access_token(
    client_id_file: str = "v2_client_id.txt",
    client_secret_file: str = "v2_client_secret.txt",
    token_file: str = "v2_access_token.txt",
    force_refresh: bool = False,
) -> str:
    """Returns a valid access token, refreshing via the client_credentials
    grant if the cached one is missing, unparseable, or within 5 minutes of
    expiring. Checked fresh on every call rather than cached in-process, same
    as the PowerShell original (token lifetime is ~360 days, so refresh is
    rare; each invocation is short-lived anyway)."""
    token_path = Path(token_file)
    if token_path.exists() and not force_refresh:
        cached = jsonio.read_text(token_path).strip()
        if cached:
            try:
                expiry = get_wcl_jwt_expiry(cached)
                if expiry > datetime.now(timezone.utc) + timedelta(minutes=5):
                    return cached
            except Exception:
                pass  # unparseable cached token - fall through and fetch a fresh one

    id_path, secret_path = Path(client_id_file), Path(client_secret_file)
    if not id_path.exists() or not secret_path.exists():
        raise FileNotFoundError(
            f"Missing {client_id_file} / {client_secret_file} at repo root. "
            f"Register a client at https://www.warcraftlogs.com/api/clients/ "
            f"(Name: anything; Redirect URL: a placeholder like http://localhost "
            f"- required by the form, unused by the client_credentials grant) "
            f"and save the Client ID / Client Secret into these two files."
        )
    client_id = jsonio.read_text(id_path).strip()
    client_secret = jsonio.read_text(secret_path).strip()

    resp = requests.post(
        TOKEN_ENDPOINT,
        auth=(client_id, client_secret),
        data={"grant_type": "client_credentials"},
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()
    access_token = resp.json()["access_token"]
    jsonio.write_text(token_path, access_token)
    return access_token


def invoke_wcl_graphql(
    query: str,
    variables: dict | None = None,
    access_token: str | None = None,
    is_retry: bool = False,
) -> WclResult:
    """POSTs one GraphQL query. NEVER raises on a GraphQL-level error (HTTP
    200 with a top-level "errors" array) - callers must check .errors
    explicitly. Self-heals on a live 401 by refreshing the token and
    retrying exactly once (is_retry guards against infinite recursion)."""
    token = access_token if access_token else get_wcl_access_token()
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    body: dict[str, Any] = {"query": query}
    if variables:
        body["variables"] = variables

    try:
        resp = requests.post(GRAPHQL_ENDPOINT, headers=headers, json=body, timeout=REQUEST_TIMEOUT)
        if resp.status_code == 401 and not is_retry:
            fresh_token = get_wcl_access_token(force_refresh=True)
            return invoke_wcl_graphql(query, variables, fresh_token, is_retry=True)
        resp.raise_for_status()
    except requests.exceptions.RequestException as exc:
        if getattr(exc, "response", None) is not None and exc.response.status_code == 401 and not is_retry:
            fresh_token = get_wcl_access_token(force_refresh=True)
            return invoke_wcl_graphql(query, variables, fresh_token, is_retry=True)
        return WclResult(data=None, errors=[f"HTTP request failed: {exc}"])

    parsed = resp.json()
    errors = parsed.get("errors")
    return WclResult(data=parsed.get("data"), errors=errors)


def invoke_wcl_graphql_paged(
    query_builder: Callable[[float], str],
    extract_page: Callable[[Any], PageResult],
    access_token: str | None = None,
    initial_start_time: float = 0.0,
    max_pages: int = 500,
) -> PagedResult:
    """Generic pagination wrapper around any events()-shaped field
    ({data:[...], nextPageTimestamp}). `query_builder` builds the query text
    for a given start_time; `extract_page` pulls {items, next_page_timestamp}
    out of one page's raw response data."""
    all_items: list = []
    start_time = initial_start_time
    page_count = 0
    errors = None

    while True:
        page_count += 1
        if page_count > max_pages:
            print(
                f"  WARNING: invoke_wcl_graphql_paged hit max_pages ({max_pages}) - "
                f"stopping, possible pagination loop (verify next_page_timestamp is advancing)"
            )
            break
        query = query_builder(start_time)
        result = invoke_wcl_graphql(query, access_token=access_token)
        if result.errors:
            errors = result.errors
            break
        page = extract_page(result.data)
        all_items.extend(page.items)
        if page_count >= 2:
            print(f"  ...page {page_count} (running total {len(all_items)} events)")
        if page.next_page_timestamp is None:
            break
        start_time = page.next_page_timestamp

    return PagedResult(items=all_items, errors=errors, page_count=page_count)


# ===== TBC consumable classification =====
# Real TBC rule (patch 2.1+): a character can have EITHER (1 Battle Elixir +
# 1 Guardian Elixir) OR (1 Flask, which occupies both slots at once) - never
# a flask alongside either elixir type, never two of the same elixir type.
# Copied verbatim from WclV2Api.psm1 - these are hard-won, confirmed-against-
# real-data facts (see that module's comments for the "Elixir of Draenic
# Wisdom"/"Healing Power" discovery writeups), not to be "cleaned up."
TBC_FLASK_NAMES = [
    "Flask of Blinding Light", "Flask of Pure Death", "Flask of Mighty Restoration",
    "Flask of Relentless Assault", "Flask of Fortification", "Flask of Chromatic Wonder",
    "Flask of Petrification",
]
TBC_BATTLE_ELIXIR_NAMES = [
    "Elixir of Major Agility", "Elixir of Major Strength", "Elixir of Major Frost Power",
    "Elixir of Major Shadow Power", "Elixir of Major Firepower", "Adept's Elixir",
    "Healing Power", "Elixir of Demonslaying", "Onslaught Elixir",
    "Elixir of the Mongoose", "Elixir of Camouflage", "Elixir of Major Fire Power",
]
TBC_GUARDIAN_ELIXIR_NAMES = [
    "Elixir of Major Mageblood", "Elixir of Major Fortitude", "Elixir of Major Defense",
    "Elixir of Draenic Wisdom", "Earthen Elixir", "Elixir of Empowerment",
    "Elixir of Draconic Defense", "Elixir of Ironskin",
]


def classify_consumables(auras: list[dict]) -> ConsumableClassification:
    """Classifies a snapshot's real auras[] into (at most) one real Flask,
    one real Battle Elixir, one real Guardian Elixir - never more than one
    of each, per the real game rule these three are mutually exclusive
    within their own category."""
    flask = next((a for a in auras if a.get("name") in TBC_FLASK_NAMES), None)
    battle_elixir = next((a for a in auras if a.get("name") in TBC_BATTLE_ELIXIR_NAMES), None)
    guardian_elixir = next((a for a in auras if a.get("name") in TBC_GUARDIAN_ELIXIR_NAMES), None)
    return ConsumableClassification(flask=flask, battle_elixir=battle_elixir, guardian_elixir=guardian_elixir)
