# ReportRenderLib.psm1
#
# NOTE on non-ASCII characters (em-dash, right-arrow, multiplication sign):
# built via [char] codes below, never as literal Unicode characters in this
# file's source text. PowerShell 5.1 reads a .ps1/.psm1 file with no BOM using
# the system's default (non-UTF8) codepage, which silently mangles a literal
# UTF-8-encoded em-dash/arrow into 2-3 garbage characters INSIDE a string
# literal - confirmed live: this broke the parser outright the first time this
# file was written with real "-" "-" "x" characters embedded directly (see
# CLAUDE.md gotcha #14, the same class of BOM/encoding bug). [char] codes sidestep
# the problem regardless of how this file itself is saved/read.
#
# Shared helpers for the deterministic report-rendering pipeline
# (build_boss_analysis.ps1, render_healer_report.ps1). Single source of truth
# for lookups/logic that previously had to be re-derived by hand every report
# generation - the 19-slot gear-order mapping in particular is exactly the
# class of thing that produced a real historical bug (WORKFLOW.md gotcha #31,
# slot 3/Shirt misread as OffHand) when re-derived ad hoc instead of centralized
# here.
#
# Usage (run from repo root, same as every other script here):
#   Import-Module (Join-Path $PSScriptRoot "lib\ReportRenderLib.psm1") -Force

# ===== 19-slot gear order (WORKFLOW.md gotcha #31) - fixed WoW combatantinfo
# gear[] position, confirmed real, never re-derive this from DifferingSlots/
# ConsistentAcrossAllKills alone (those only diff a kill against itself, they
# don't validate the position mapping itself). =====
$script:EmDash = [char]0x2014
$script:RightArrow = [char]0x2192
$script:MultSign = [char]0x00D7

$script:GearSlotNames = @(
    "Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet",
    "Wrist", "Hands", "Finger1", "Finger2", "Trinket1", "Trinket2",
    "Back", "MainHand", "OffHand", "Ranged", "Tabard"
)

# ===== Enchantable-slot allowlist, cross-checked against the real Crowns
# gear-audit prose (explicitly enumerates Head/Shoulder/Chest/Legs/Feet/Wrist/
# Hands/Back/MainHand) and WORKFLOW.md gotcha #6 (rings are self-only enchant
# in this era, never flag). Explicitly NOT enchantable in this TBC ruleset:
# Neck(1), Shirt(3), Waist(5), Finger1/2(10,11), Trinket1/2(12,13),
# OffHand(16), Ranged/Relic(17), Tabard(18).
#
# OffHand(16) was removed from this list 2026-07-15 - a real false-positive
# found on Danceswtrees's Gruul's Lair report: every tracked healer spec
# (Resto Druid, Resto Shaman, Holy Priest, Holy Paladin) holds a non-weapon
# "Held In Off-Hand" item there (an orb, tome, idol, etc. - confirmed here by
# the real gear.json icon "inv_misc_orb_01.jpg", not a weapon/shield icon),
# and only an actual off-hand weapon or shield can carry a permanent enchant
# in this era - a caster off-hand item never can, regardless of whether a
# real item (non-zero id) is equipped there. combatantinfo's gear[] entries
# carry no item type/subclass field to distinguish "real off-hand weapon" from
# "held item" mechanically, so - same reasoning as the ring exclusion below -
# the safe default is to never flag this slot at all rather than risk a false
# "missing enchant" claim on every report this pipeline has ever rendered. =====
$script:EnchantableSlotIndexes = @(0, 2, 4, 6, 7, 8, 9, 14, 15)

# ===== Per-class cooldown target-labeling mode, confirmed against real
# hand-built pages this session (Crowns/Paladin, Vajomee/Shaman) and each
# class's boss_page_template comments. "party" renders literally as the word
# "party" (Mana Tide Totem/Ancestral Swiftness have no real per-player target
# in the data - they're ground-placed totems); "self" renders as "self" when
# Count>0 else "-"; "other" collapses real Targets[] into
# "-> Name" / "-> Name xN" / "-> Name1, -> Name2" / "-" when Count==0. =====
$script:CooldownTargetMode = @{
    "Druid"   = @{
        "Innervate" = "other"; "Nature's Swiftness" = "self"; "Swiftmend" = "other"
        "Tranquility" = "other"; "Rebirth" = "other"; "Dark Rune" = "self"; "Mana Potion" = "self"
    }
    "Shaman"  = @{
        "Earth Shield" = "other"; "Mana Tide Totem" = "party"; "Ancestral Swiftness" = "party"
        "Dark Rune" = "self"; "Mana Potion" = "self"
    }
    "Priest"  = @{
        "Shadowfiend" = "self"; "Power Word: Shield" = "other"; "Chakra" = "self"
        "Blessing of Life" = "self"; "Fear Ward" = "other"; "Dark Rune" = "self"; "Mana Potion" = "self"
    }
    "Paladin" = @{
        "Holy Shock" = "other"; "Divine Favor" = "self"; "Divine Shield" = "self"
        "Cleanse" = "other"; "Hand of Protection" = "other"; "Blessing of Freedom" = "other"
        "Dark Rune" = "self"; "Mana Potion" = "self"
    }
}

# Parses a BM/BMSpells/BMCooldowns/BMBuffs CSV-string field (all-string once
# loaded via Import-Csv, and still a JSON string once report_data.json
# round-trips it) to a [double] or $null. Blank/empty -> $null (means "no
# data" - nobody in the sample cast it, self% is undefined), never coerced to
# 0 (a real, meaningful zero).
function ConvertTo-BMNumber {
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ($s.Trim() -eq "") { return $null }
    $parsed = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-GearSlotName {
    param([Parameter(Mandatory=$true)][int]$SlotIndex)
    if ($SlotIndex -ge 0 -and $SlotIndex -lt $script:GearSlotNames.Count) {
        return $script:GearSlotNames[$SlotIndex]
    }
    return "Unknown($SlotIndex)"
}

# $GearItemAtSlot is accepted for signature stability (callers built around
# the old OffHand(16) special-case still pass it) but no slot currently in
# $script:EnchantableSlotIndexes needs the actual equipped item to decide -
# the allowlist alone is authoritative now that OffHand has been removed from it.
function Test-SlotEnchantable {
    param(
        [Parameter(Mandatory=$true)][int]$SlotIndex,
        $GearItemAtSlot = $null
    )
    if ($script:EnchantableSlotIndexes -notcontains $SlotIndex) { return $false }
    return $true
}

# Collapses a CooldownRows[ability].Targets array into the exact display
# string used across every hand-built page this session.
function Format-CooldownTarget {
    param(
        [Parameter(Mandatory=$true)]$TargetsArray,
        [Parameter(Mandatory=$true)][string]$Mode
    )
    $targets = @($TargetsArray)
    $dash = $script:EmDash
    $arrow = $script:RightArrow
    $mult = $script:MultSign
    if ($Mode -eq "party") {
        return $(if ($targets.Count -gt 0) { "party" } else { "$dash" })
    }
    if ($Mode -eq "self") {
        return $(if ($targets.Count -gt 0) { "self" } else { "$dash" })
    }
    if ($targets.Count -eq 0) { return "$dash" }
    $order = New-Object System.Collections.Generic.List[string]
    $counts = @{}
    foreach ($t in $targets) {
        $name = if ($t.Target -eq "self") { "self" } else { $t.Target }
        if (-not $counts.ContainsKey($name)) { $counts[$name] = 0; $order.Add($name) }
        $counts[$name] += 1
    }
    $parts = @()
    foreach ($name in $order) {
        if ($name -eq "self") { $parts += "self" }
        elseif ($counts[$name] -gt 1) { $parts += "$arrow $name $mult$($counts[$name])" }
        else { $parts += "$arrow $name" }
    }
    return ($parts -join ", ")
}

# Exact numeric rule from SKILL.md/WORKFLOW.md (Druid Tranquility only). Known
# caveat, not fixed here: Tranquility's guid list in build_boss_report_data.ps1
# is a literal empty array, so Count is always hardcoded 0 today - only the
# "didn't cast it while >=50% did" branch can ever fire until that gap is
# closed (tracked separately, out of scope here).
function Test-TranquilityInclude {
    param(
        [Parameter(Mandatory=$true)][int]$Count,
        $Top100UsedPct
    )
    if ($null -eq $Top100UsedPct) { return $false }
    $pct = [double]$Top100UsedPct
    if ($Count -gt 0 -and $pct -le 20) { return $true }
    if ($Count -eq 0 -and $pct -ge 50) { return $true }
    return $false
}

# Generalizes the same threshold to every tracked cooldown for every class -
# feeds RaidWideRollups.CooldownDeviations in the analysis file. This is the
# single highest-value rollup in practice (it's what produced "Ancestral
# Swiftness uncast on 5 of 10 kills" and "Divine Shield: 0 casts on Vashj
# despite 57% of the sample using it" by hand).
function Test-CooldownDeviates {
    param(
        [Parameter(Mandatory=$true)][int]$Count,
        $Top100UsedPct
    )
    if ($null -eq $Top100UsedPct) { return $false }
    $pct = [double]$Top100UsedPct
    if ($Count -eq 0 -and $pct -ge 50) { return $true }
    if ($Count -gt 0 -and $pct -le 20) { return $true }
    return $false
}

# Fixed, already-documented facts (not per-page discoveries) - tags when the
# trigger condition is met so Claude is prompted to use the documented
# caveat language rather than reinvent/misstate it. Claude still writes the
# actual sentence; this only flags WHEN it applies.
function Get-CannedCaveats {
    param(
        [Parameter(Mandatory=$true)][string]$ClassName,
        $CooldownRows,
        $SpellRows
    )
    $tags = @()
    if ($ClassName -eq "Priest" -and $CooldownRows -and ($CooldownRows.PSObject.Properties.Name -contains "Power Word: Shield")) {
        $tags += "priest_pws_benchmark_bias"
    }
    if ($ClassName -eq "Paladin" -and $CooldownRows -and ($CooldownRows.PSObject.Properties.Name -contains "Holy Shock")) {
        $hasHealRow = $false
        foreach ($row in @($SpellRows)) {
            if ([int]$row.Guid -eq 33074) { $hasHealRow = $true; break }
        }
        if (-not $hasHealRow) { $tags += "paladin_holy_shock_guid_split" }
    }
    return $tags
}

# Class-gated stat blocks for section 03's stat-grid - gates strictly on
# ClassName, NEVER on whether TreeOfLifePct is null, because it serializes as
# a real 0 (not null) even for non-Druid classes in real report_data.json
# output (confirmed directly against Crowns's real JSON) - a null-check would
# silently show a fake "0% uptime" stat for classes that don't have the
# concept at all.
function Get-ActiveStatBlocks {
    param([Parameter(Mandatory=$true)][string]$ClassName)
    if ($ClassName -eq "Druid") { return @("Flask", "Food", "TreeOfLife", "ManaConsumable", "HPM") }
    return @("Flask", "Food", "ManaConsumable", "HPM")
}

function Get-CooldownTargetMode {
    param(
        [Parameter(Mandatory=$true)][string]$ClassName,
        [Parameter(Mandatory=$true)][string]$AbilityName
    )
    if ($script:CooldownTargetMode.ContainsKey($ClassName) -and $script:CooldownTargetMode[$ClassName].ContainsKey($AbilityName)) {
        return $script:CooldownTargetMode[$ClassName][$AbilityName]
    }
    return "other"
}

# ===== Templating primitives - plain string/regex, no DOM library, matching
# every other script in this repo. =====

# Extracts the row-template between <!--@LOOP:Name--> and <!--@ENDLOOP:Name-->
# once, builds one row per item in $Rows via $RowTokenBuilder (a scriptblock
# taking one row object and returning a hashtable of TOKEN->value), and
# splices the concatenated result back in place of the whole marked span.
function Expand-TemplateLoop {
    param(
        [Parameter(Mandatory=$true)][string]$TemplateText,
        [Parameter(Mandatory=$true)][string]$LoopName,
        [Parameter(Mandatory=$true)][array]$Rows,
        [Parameter(Mandatory=$true)][scriptblock]$RowTokenBuilder
    )
    $startMarker = "<!--@LOOP:$LoopName-->"
    $endMarker = "<!--@ENDLOOP:$LoopName-->"
    $startIdx = $TemplateText.IndexOf($startMarker)
    if ($startIdx -lt 0) { throw "Expand-TemplateLoop: start marker '@LOOP:$LoopName' not found." }
    $endIdx = $TemplateText.IndexOf($endMarker, $startIdx)
    if ($endIdx -lt 0) { throw "Expand-TemplateLoop: end marker '@ENDLOOP:$LoopName' not found." }

    $rowTemplate = $TemplateText.Substring($startIdx + $startMarker.Length, $endIdx - ($startIdx + $startMarker.Length))
    $built = New-Object System.Text.StringBuilder
    foreach ($row in $Rows) {
        $rowHtml = $rowTemplate
        $tokens = & $RowTokenBuilder $row
        foreach ($key in $tokens.Keys) {
            $rowHtml = $rowHtml.Replace("{{$key}}", [string]$tokens[$key])
        }
        [void]$built.Append($rowHtml)
    }
    $before = $TemplateText.Substring(0, $startIdx)
    $after = $TemplateText.Substring($endIdx + $endMarker.Length)
    return $before + $built.ToString() + $after
}

# Replaces the whole span between <!--@SLOT:Name--> and <!--@ENDSLOT--> (which
# includes the {{TOKEN}} plus its inline authoring instructions) with just the
# findings string - never leaves instructional text behind in a final page.
function Set-TemplateSlot {
    param(
        [Parameter(Mandatory=$true)][string]$TemplateText,
        [Parameter(Mandatory=$true)][string]$SlotName,
        [Parameter(Mandatory=$true)][string]$Value
    )
    $startMarker = "<!--@SLOT:$SlotName-->"
    $endMarker = "<!--@ENDSLOT-->"
    $startIdx = $TemplateText.IndexOf($startMarker)
    if ($startIdx -lt 0) { throw "Set-TemplateSlot: start marker '@SLOT:$SlotName' not found." }
    $searchFrom = $startIdx + $startMarker.Length
    $endIdx = $TemplateText.IndexOf($endMarker, $searchFrom)
    if ($endIdx -lt 0) { throw "Set-TemplateSlot: end marker for slot '$SlotName' not found." }
    $before = $TemplateText.Substring(0, $startIdx)
    $after = $TemplateText.Substring($endIdx + $endMarker.Length)
    return $before + $Value + $after
}

# Direct, non-marker {{TOKEN}} substitution for simple once-per-page values
# (HPS, PERCENTILE, etc.) that have no surrounding instructional text.
# Optional block: <!--@OPTIONAL:Name-->...<!--@SLOT:Name-->{{TOKEN}}...<!--@ENDSLOT-->...<!--@ENDOPTIONAL-->
# If $Value is non-empty, keeps the wrapped content with the inner slot filled;
# if $Value is null/empty, removes the whole optional span (e.g. the raid
# overview's rust "raid-wide warning" banner, which real hand-built pages show
# prominently when there's a genuine raid-wide finding, and omit entirely
# otherwise - not a per-page-guaranteed element the way coverage-notes are).
function Set-TemplateOptional {
    param(
        [Parameter(Mandatory=$true)][string]$TemplateText,
        [Parameter(Mandatory=$true)][string]$OptionalName,
        [Parameter(Mandatory=$true)][string]$SlotName,
        [string]$Value
    )
    $startMarker = "<!--@OPTIONAL:$OptionalName-->"
    $endMarker = "<!--@ENDOPTIONAL:$OptionalName-->"
    $startIdx = $TemplateText.IndexOf($startMarker)
    if ($startIdx -lt 0) { throw "Set-TemplateOptional: start marker '@OPTIONAL:$OptionalName' not found." }
    $endIdx = $TemplateText.IndexOf($endMarker, $startIdx)
    if ($endIdx -lt 0) { throw "Set-TemplateOptional: end marker '@ENDOPTIONAL:$OptionalName' not found." }
    $before = $TemplateText.Substring(0, $startIdx)
    $after = $TemplateText.Substring($endIdx + $endMarker.Length)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $before + $after
    }
    $inner = $TemplateText.Substring($startIdx + $startMarker.Length, $endIdx - ($startIdx + $startMarker.Length))
    $inner = Set-TemplateSlot -TemplateText $inner -SlotName $SlotName -Value $Value
    return $before + $inner + $after
}

# Same marker pair as Set-TemplateOptional, but hands the caller the raw inner
# template text instead of filling a single nested @SLOT - needed whenever the
# optional block's content is a @LOOP (a variable number of rows, e.g. the
# spell-ranks section) rather than one free-text value. Caller decides whether
# to keep the section at all (pass $Keep) and, if so, runs Expand-TemplateLoop
# (or anything else) on .Inner before splicing it back between .Before/.After.
function Get-OptionalSectionBounds {
    param(
        [Parameter(Mandatory=$true)][string]$TemplateText,
        [Parameter(Mandatory=$true)][string]$OptionalName
    )
    $startMarker = "<!--@OPTIONAL:$OptionalName-->"
    $endMarker = "<!--@ENDOPTIONAL:$OptionalName-->"
    $startIdx = $TemplateText.IndexOf($startMarker)
    if ($startIdx -lt 0) { throw "Get-OptionalSectionBounds: start marker '@OPTIONAL:$OptionalName' not found." }
    $endIdx = $TemplateText.IndexOf($endMarker, $startIdx)
    if ($endIdx -lt 0) { throw "Get-OptionalSectionBounds: end marker '@ENDOPTIONAL:$OptionalName' not found." }
    return [PSCustomObject]@{
        Before = $TemplateText.Substring(0, $startIdx)
        Inner  = $TemplateText.Substring($startIdx + $startMarker.Length, $endIdx - ($startIdx + $startMarker.Length))
        After  = $TemplateText.Substring($endIdx + $endMarker.Length)
    }
}

# Strips every HTML comment (including any leftover @LOOP/@SLOT/@OPTIONAL
# markers and the templates' own development-time documentation prose) from
# a fully-rendered page. Comments are development-time only and should never
# appear in real output - call this as the LAST step before writing a file,
# so the "any remaining {{TOKEN}}" safety check downstream only ever catches
# a genuinely missed substitution in real content, not documentation text
# that happens to mention a token name literally.
function Remove-HtmlComments {
    param([Parameter(Mandatory=$true)][string]$TemplateText)
    return [regex]::Replace($TemplateText, "<!--(?s).*?-->", "")
}

function Set-TemplateToken {
    param(
        [Parameter(Mandatory=$true)][string]$TemplateText,
        [Parameter(Mandatory=$true)][string]$Token,
        $Value
    )
    return $TemplateText.Replace("{{$Token}}", [string]$Value)
}
