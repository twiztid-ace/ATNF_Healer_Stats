<#
Surgical upsert of the two hub pages after a new raid night is generated:
  - docs\{healerSlug}\index.html  (this healer's raid-night list)
  - docs\index.html               (site homepage's healer list, only with -IsNewHealer)

This is deliberately NOT a full rescan/rebuild of either file. Several existing
healer folders have v1 raid nights with no report_data.json backing at all (v1
predates this JSON pipeline), so a rescan keyed on report_data.json would silently
drop those rows. Instead this script only ever inserts one new row - every
OTHER existing row in the healer's raid-list is preserved untouched. The one
exception: the raid-list is always re-sorted by real raid date, descending,
after the insert - see "Ordering" below for why this can't just be "always
insert at the top."

The inserted row links to {ReportCode}/index.html, NOT {RaidDate}/index.html -
render_healer_report.ps1's output folder is keyed by ReportCode (not raid date,
since two raids can happen on the same calendar date - see
pull_character_TEMPLATE.ps1), so the link has to match that folder name exactly.
-RaidDate is only ever used for the human-readable date text next to the link.

Ordering: a healer's raid-list must always read newest-first. Folders are keyed
by ReportCode now, not date, so insertion order no longer has any natural
correlation with raid-chronology - generating an older report AFTER a newer one
(e.g. backfilling a missed raid night) is a real, expected scenario, not just a
hypothetical. So every insert re-parses EVERY existing row's own date text,
combines it with the new row, and rewrites the whole list stably sorted by date
descending - self-healing regardless of what order rows happen to already be in
on disk. Existing real pages use two different date-text formats ("July 7,
2026" and "07.10.2026" - both real, from earlier hand-authored/generated pages,
never reconciled) - the parser tries both. A row whose date text can't be
parsed at all is sorted last with a WARNING printed, never silently dropped.

Usage:
  powershell -File scripts\update_hub_pages.ps1 -CharacterName "Crowns" -RaidDate "2026-07-07" `
      -ReportCode "XJp8vAxzM4KtHYyb" -ClassName "Paladin" -BossesKilled 10 -RaidTitle "SSC / TK"
  # add -IsNewHealer only the first time a healer is ever added to the site

  # Re-sort an existing healer's raid-list without inserting anything (e.g. to
  # verify/fix ordering after a manual edit, or after this script's own sort
  # logic changes) - only -CharacterName is required:
  powershell -File scripts\update_hub_pages.ps1 -CharacterName "Crowns" -ResortOnly
#>

param(
    [Parameter(Mandatory=$true)][string]$CharacterName,
    [string]$RaidDate,
    [string]$ReportCode,
    [string]$ClassName,
    [int]$BossesKilled,
    [string]$RaidTitle,
    [int]$BossesAttempted = 0,
    [string]$Server = "Dreamscythe",
    [string]$Region = "US",
    [switch]$IsNewHealer,
    [switch]$ResortOnly,
    [string]$DocsRoot = "docs",
    [string]$TemplatesRoot = "templates",
    [string]$CharactersRoot = "data\Characters"
)

$ErrorActionPreference = "Stop"

if (-not $ResortOnly) {
    $missing = @()
    if (-not $RaidDate)   { $missing += "-RaidDate" }
    if (-not $ReportCode) { $missing += "-ReportCode" }
    if (-not $ClassName)  { $missing += "-ClassName" }
    if (-not $BossesKilled) { $missing += "-BossesKilled" }
    if (-not $RaidTitle)  { $missing += "-RaidTitle" }
    if ($missing.Count -gt 0) {
        Write-Host "ERROR: missing required parameter(s): $($missing -join ', ') (all required unless -ResortOnly is passed)."
        exit 1
    }

    # Prefer the real, already-computed BossesKilled/BossesAttempted from this
    # report's own report_data.json over whatever was passed on the command
    # line - added after a real bug: -BossesAttempted was hand-computed wrong
    # (counted Morogrim's wipe-then-kill as 2 distinct bosses attempted
    # instead of 1) and passed straight through to this hub row with no
    # cross-check, rendering a wrong "10/11 bosses" for a raid that only ever
    # had 10 real distinct bosses. report_data.json's own BossesAttempted
    # (build_boss_report_data.ps1, itself already fixed for this bug) and
    # Bosses.Count are the authoritative source whenever the file exists -
    # the passed parameters are now only a fallback for a report_data.json
    # that genuinely doesn't exist yet, and any real mismatch against what
    # was passed gets a visible warning instead of silently trusting the
    # stale/wrong value.
    $reportDataPath = Join-Path (Join-Path $CharactersRoot $CharacterName) (Join-Path $ReportCode "$($ReportCode)_report_data.json")
    if (Test-Path $reportDataPath) {
        $realReportData = Get-Content $reportDataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $realBossesKilled = @($realReportData.Bosses.PSObject.Properties.Name).Count
        $realBossesAttempted = if ($realReportData.PSObject.Properties.Name -contains "BossesAttempted" -and $realReportData.BossesAttempted) { $realReportData.BossesAttempted } else { $realBossesKilled }
        if ($realBossesKilled -ne $BossesKilled) {
            Write-Host "  NOTE: -BossesKilled $BossesKilled passed, but $reportDataPath shows $realBossesKilled real boss kill(s) - using the real value."
        }
        if ($realBossesAttempted -ne $BossesAttempted) {
            Write-Host "  NOTE: -BossesAttempted $BossesAttempted passed, but $reportDataPath shows $realBossesAttempted real distinct boss(es) attempted - using the real value."
        }
        $BossesKilled = $realBossesKilled
        $BossesAttempted = $realBossesAttempted
    }
}

$classSpecMap = @{
    "Druid"   = "Restoration Druid"
    "Shaman"  = "Restoration Shaman"
    "Priest"  = "Holy Priest"
    "Paladin" = "Holy Paladin"
}
if ($ClassName -and -not $classSpecMap.ContainsKey($ClassName)) {
    Write-Host "ERROR: unrecognized ClassName '$ClassName' - must be Druid, Shaman, Priest, or Paladin."
    exit 1
}
$classSpec = if ($ClassName) { $classSpecMap[$ClassName] } else { $null }
$healerSlug = $CharacterName.ToLower()

$raidDateObj = $null
$raidDateDisplay = $null
if ($RaidDate) {
    $raidDateObj = [datetime]::ParseExact($RaidDate, "yyyy-MM-dd", $null)
    $raidDateDisplay = $raidDateObj.ToString("MMMM d, yyyy")
}

function Get-PluralizedCount {
    param([int]$Count, [string]$Singular, [string]$Plural)
    if ($Count -eq 1) { return "$Count $Singular" } else { return "$Count $Plural" }
}

# Tries every real date-text format seen across existing hub pages ("July 7,
# 2026" and "07.10.2026" both occur on real, already-published pages). Returns
# $null (never throws) if nothing matches, so a garbled/unexpected row can be
# handled by the caller (sort last + warn) rather than crashing the whole script.
function Get-RaidRowDate {
    param([string]$DateText)
    $DateText = $DateText.Trim()
    foreach ($fmt in @("MMMM d, yyyy", "MM.dd.yyyy", "yyyy-MM-dd")) {
        try { return [datetime]::ParseExact($DateText, $fmt, [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
    }
    return $null
}

# Extracts every <a class="raid-row">...</a> block from the raid-list's raw
# inner HTML, parses each one's own date text, appends $NewRowHtml (if any),
# then returns the whole set stably re-joined in date-descending order. Ties
# (including two rows sharing an identical date, e.g. a v1/v2 pair) keep their
# relative input order - a newly-appended row is placed after any existing
# same-date row for exactly that reason.
function Get-SortedRaidListHtml {
    param([string]$RowsRawHtml, [string]$NewRowHtml, [Nullable[datetime]]$NewRowDate)

    $rowMatches = [regex]::Matches($RowsRawHtml, '<a class="raid-row".*?</a>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($m in $rowMatches) {
        $block = $m.Value
        $middleDot = [char]0x00B7
        $dateMatchPattern = '<div class="raid-meta">(.*?)\s*&nbsp;(?:&middot;|' + $middleDot + ')&nbsp;\s*report'
        $dateMatch = [regex]::Match($block, $dateMatchPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $parsedDate = $null
        if ($dateMatch.Success) { $parsedDate = Get-RaidRowDate -DateText $dateMatch.Groups[1].Value }
        if (-not $parsedDate) {
            $preview = $block.Substring(0, [Math]::Min(100, $block.Length)) -replace "`r?`n\s*", " "
            Write-Host "  WARNING: could not parse a date out of an existing raid-row - it will sort last. Row starts: $preview..."
            $parsedDate = [datetime]::MinValue
        }
        $rows.Add([PSCustomObject]@{ Html = $block; Date = $parsedDate })
    }

    if ($NewRowHtml) {
        $rows.Add([PSCustomObject]@{ Html = $NewRowHtml.Trim(); Date = $NewRowDate })
    }

    # Sort-Object is a stable sort in Windows PowerShell 5.1 - ties preserve
    # the order they were added in above, which is what makes the "new row
    # sorts after an existing same-date row" behavior above actually hold.
    $sorted = @($rows | Sort-Object -Property Date -Descending)
    return ($sorted.Html -join "`r`n      ")
}

# Locates the raid-list container's raw inner HTML by its two guaranteed
# neighboring markers (every real hub page has <div class="empty-note"> as the
# very next sibling after raid-list's own rows) rather than a nested-div-aware
# HTML parse - consistent with every other script in this pipeline (string/
# regex based, no DOM library).
function Get-RaidListBounds {
    param([string]$Html)
    $listMarker = '<div class="raid-list">'
    $emptyNoteMarker = '<div class="empty-note">'
    $listStart = $Html.IndexOf($listMarker)
    if ($listStart -lt 0) { return $null }
    $contentStart = $listStart + $listMarker.Length
    $emptyNoteStart = $Html.IndexOf($emptyNoteMarker, $contentStart)
    if ($emptyNoteStart -lt 0) { return $null }
    $closingDivIdx = $Html.LastIndexOf("</div>", $emptyNoteStart)
    if ($closingDivIdx -lt $contentStart) { return $null }
    return [PSCustomObject]@{ ContentStart = $contentStart; ContentEnd = $closingDivIdx }
}

# ----- 1. This healer's own raid-list hub page -----
$hubDir = Join-Path $DocsRoot $healerSlug
$hubPath = Join-Path $hubDir "index.html"

$newRowHtml = $null
if (-not $ResortOnly) {
    # Denominator is real, not a hardcoded tier-size guess: only shown when
    # -BossesAttempted is explicitly passed higher than -BossesKilled (i.e. a
    # real wipe happened this raid night). No wipe known -> just "N bosses
    # killed", no "/M". Replaces an earlier hardcoded "-TotalBosses" (default
    # 10) that produced a nonsensical "12/10 bosses" once Gruul's Lair bosses
    # started appearing alongside SSC/TK in the same report.
    $bossesLabel = if ($BossesAttempted -gt $BossesKilled) { "$BossesKilled/$BossesAttempted bosses" } else { "$BossesKilled bosses killed" }
    $newRowHtml = @"
      <a class="raid-row" href="$ReportCode/index.html">
        <div>
          <div class="raid-title">$RaidTitle</div>
          <div class="raid-meta">$raidDateDisplay &nbsp;&middot;&nbsp; report $ReportCode</div>
        </div>
        <div class="raid-meta">$bossesLabel</div>
        <div class="raid-arrow">$([char]0x2192)</div>
      </a>
"@
}
# &middot; renders as the same middle-dot glyph the existing pages use (&nbsp;[middle dot]&nbsp; visually) -
# written as an HTML entity here instead of a literal non-ASCII char, consistent with this
# project's PowerShell-source-encoding rule (see ReportRenderLib.psm1's EmDash/RightArrow pattern).

if ($ResortOnly -and -not (Test-Path $hubPath)) {
    Write-Host "ERROR: -ResortOnly was passed but $hubPath doesn't exist - nothing to resort."
    exit 1
}

if (-not (Test-Path $hubPath)) {
    Write-Host "No hub page yet for '$CharacterName' - creating from template."
    New-Item -ItemType Directory -Path $hubDir -Force | Out-Null
    $tplPath = Join-Path $TemplatesRoot "healer_raidlist_template.html"
    $tpl = [System.IO.File]::ReadAllText($tplPath, [System.Text.Encoding]::UTF8)

    $loopStart = $tpl.IndexOf("<!--@LOOP:RAID_ROW-->")
    $loopEnd = $tpl.IndexOf("<!--@ENDLOOP:RAID_ROW-->") + "<!--@ENDLOOP:RAID_ROW-->".Length
    if ($loopStart -lt 0 -or $loopEnd -lt 0) {
        Write-Host "ERROR: healer_raidlist_template.html is missing its @LOOP:RAID_ROW markers."
        exit 1
    }
    $hub = $tpl.Substring(0, $loopStart).TrimEnd() + "`r`n" + $newRowHtml.TrimEnd("`r", "`n") + $tpl.Substring($loopEnd)

    $hub = $hub.Replace("{{HEALER_NAME}}", $CharacterName)
    $hub = $hub.Replace("{{HEALER_CLASS_SPEC}}", $classSpec)
    $hub = $hub.Replace("{{SERVER}}", $Server)
    $hub = $hub.Replace("{{REGION}}", $Region)
    $hub = $hub.Replace("{{N}} raid night(s) analyzed", (Get-PluralizedCount -Count 1 -Singular "raid night analyzed" -Plural "raid nights analyzed"))
    $hub = [regex]::Replace($hub, "<!--(?s).*?-->", "")

    if ($hub.Contains("{{")) {
        Write-Host "ERROR: new hub page still has an unfilled {{TOKEN}} after rendering - refusing to write."
        exit 1
    }
    [System.IO.File]::WriteAllText($hubPath, $hub, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Wrote $hubPath (new healer hub page, 1 raid night)"
} else {
    $hub = [System.IO.File]::ReadAllText($hubPath, [System.Text.Encoding]::UTF8)
    if ((-not $ResortOnly) -and $hub.Contains("report $ReportCode")) {
        Write-Host "Report $ReportCode is already listed on $hubPath - skipping insert (no duplicate added)."
    } else {
        $bounds = Get-RaidListBounds -Html $hub
        if (-not $bounds) {
            Write-Host "ERROR: could not locate the raid-list container in $hubPath (expected '<div class=`"raid-list`">' followed by '<div class=`"empty-note`">') - refusing to guess."
            exit 1
        }
        $existingRowsRaw = $hub.Substring($bounds.ContentStart, $bounds.ContentEnd - $bounds.ContentStart)
        $sortedRowsHtml = Get-SortedRaidListHtml -RowsRawHtml $existingRowsRaw -NewRowHtml $newRowHtml -NewRowDate $raidDateObj
        $hub = $hub.Substring(0, $bounds.ContentStart) + "`r`n      " + $sortedRowsHtml + "`r`n    " + $hub.Substring($bounds.ContentEnd)

        if (-not $ResortOnly) {
            # Bump "N raid night(s) analyzed" - the only piece of existing text
            # (beyond row order) this script ever rewrites, since every real hub
            # page's own row count must stay accurate.
            $countMatch = [regex]::Match($hub, "(\d+) raid nights? analyzed")
            if ($countMatch.Success) {
                $oldCount = [int]$countMatch.Groups[1].Value
                $newCount = $oldCount + 1
                $newCountText = Get-PluralizedCount -Count $newCount -Singular "raid night analyzed" -Plural "raid nights analyzed"
                $hub = $hub.Substring(0, $countMatch.Index) + $newCountText + $hub.Substring($countMatch.Index + $countMatch.Length)
            } else {
                Write-Host "  WARNING: could not find 'N raid night(s) analyzed' text in $hubPath to update the count."
            }
        }

        [System.IO.File]::WriteAllText($hubPath, $hub, (New-Object System.Text.UTF8Encoding $false))
        if ($ResortOnly) {
            Write-Host "Re-sorted $hubPath by raid date (descending)."
        } else {
            Write-Host "Updated $hubPath (inserted new raid-row for report $ReportCode, list re-sorted by raid date descending)"
        }
    }
}

# ----- 2. Site homepage healer list (only for a genuinely new healer) -----
if ($IsNewHealer -and -not $ResortOnly) {
    $siteIndexPath = Join-Path $DocsRoot "index.html"
    $siteIndex = [System.IO.File]::ReadAllText($siteIndexPath, [System.Text.Encoding]::UTF8)
    if ($siteIndex.Contains("href=`"$healerSlug/index.html`"")) {
        Write-Host "$CharacterName is already listed on $siteIndexPath - skipping (-IsNewHealer had no effect)."
    } else {
        $newHealerRowHtml = @"
      <a class="healer-row" href="$healerSlug/index.html">
        <div>
          <div class="healer-name">$CharacterName</div>
        </div>
        <div class="healer-class">$classSpec</div>
        <div class="healer-arrow">$([char]0x2192)</div>
      </a>
"@
        $marker = '<div class="healer-list">'
        $idx = $siteIndex.IndexOf($marker)
        if ($idx -lt 0) {
            Write-Host "ERROR: could not find '<div class=`"healer-list`">' in $siteIndexPath - refusing to guess where to insert."
            exit 1
        }
        $insertAt = $idx + $marker.Length
        $siteIndex = $siteIndex.Substring(0, $insertAt) + "`r`n" + $newHealerRowHtml.TrimEnd("`r", "`n") + $siteIndex.Substring($insertAt)
        [System.IO.File]::WriteAllText($siteIndexPath, $siteIndex, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "Updated $siteIndexPath (inserted new healer-row for $CharacterName)"
    }
}

Write-Host ""
Write-Host "Done."
