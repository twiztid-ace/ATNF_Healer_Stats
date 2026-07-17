"""Shared rounding helper matching .NET's Math.Round / PowerShell's
[math]::Round semantics exactly.

Confirmed via real parity testing (summarize_benchmarks.py, Paladin/Vashj,
Hand of Protection: 5 casts / 100 parses): Python's built-in round() operates
on the TRUE binary double value, which for 5/100 is actually
0.050000000000000002775... (not exactly 0.05) - round() correctly rounds
this up to 0.1. .NET's Math.Round instead compensates for exactly this class
of decimal-literal binary representation error, effectively rounding the
value AS IF it were the exact decimal 0.05 a person would have typed, then
applies round-half-to-even to THAT - giving 0.0. Neither is "wrong" in
isolation; they're different, both internally-consistent conventions. This
project's PowerShell original relies on .NET's convention throughout
(HPS/HPM/UsedPct/SelfPct/etc.), so this helper reproduces it via Decimal(str(value))
- Python's str() on a float already gives the shortest round-tripping decimal
representation (i.e. the "human-typed" value), which is exactly what .NET's
compensation algorithm targets.
"""

from decimal import ROUND_HALF_EVEN, Decimal


def round_net(value: float, digits: int = 0):
    """Rounds like PowerShell's [math]::Round($value, $digits) (.NET's
    Math.Round with default MidpointRounding.ToEven, decimal-compensated).
    Returns an int when digits == 0 (matching how a whole-number double
    serializes via PowerShell's ConvertTo-Json), else a float."""
    quantum = Decimal(1).scaleb(-digits) if digits > 0 else Decimal(1)
    result = Decimal(str(value)).quantize(quantum, rounding=ROUND_HALF_EVEN)
    return int(result) if digits == 0 else float(result)
