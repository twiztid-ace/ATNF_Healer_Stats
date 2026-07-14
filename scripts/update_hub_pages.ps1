<#
Surgical upsert of the two hub pages after a new raid night is generated:
  - docs\{healerSlug}\index.html  (this healer's raid-night list)
  - docs\index.html               (site homepage's healer list, only with -IsNewHealer)

This is deliberately NOT a full rescan/rebuild of either file. Several existing
healer folders have v1 raid nights with no report_data.json backing at all (v1
predates this JSON pipeline), so a rescan keyed on report_data.json would silently
drop those rows. Instead this script only ever inserts one new row - every
existing row in both files is left byte-for-byte untouched.

Usage:
  powershell -File scripts\update_hub_pages.ps1 -CharacterName "Crowns" -RaidDate "2026-07-07" `
      -ReportCode "XJp8vAxzM4KtHYyb" -ClassName "Paladin" -BossesKilled 10 -RaidTitle "SSC / TK"
  # add -IsNewHealer only the first time a healer is ever added to the site
#>

param(
    [Parameter(Mandatory=$true)][string]$CharacterName,
    [Parameter(Mandatory=$true)][string]$RaidDate,
    [Parameter(Mandatory=$true)][string]$ReportCode,
    [Parameter(Mandatory=$true)][string]$ClassName,
    [Parameter(Mandatory=$true)][int]$BossesKilled,
    [Parameter(Mandatory=$true)][string]$RaidTitle,
    [int]$TotalBosses = 10,
    [string]$Server = "Dreamscythe",
    [string]$Region = "US",
    [switch]$IsNewHealer,
    [string]$DocsRoot = "docs",
    [string]$TemplatesRoot = "templates"
)

$ErrorActionPreference = "Stop"

$classSpecMap = @{
    "Druid"   = "Restoration Druid"
    "Shaman"  = "Restoration Shaman"
    "Priest"  = "Holy Priest"
    "Paladin" = "Holy Paladin"
}
if (-not $classSpecMap.ContainsKey($ClassName)) {
    Write-Host "ERROR: unrecognized ClassName '$ClassName' - must be Druid, Shaman, Priest, or Paladin."
    exit 1
}
$classSpec = $classSpecMap[$ClassName]
$healerSlug = $CharacterName.ToLower()

$raidDateObj = [datetime]::ParseExact($RaidDate, "yyyy-MM-dd", $null)
$raidDateDisplay = $raidDateObj.ToString("MMMM d, yyyy")

function Get-PluralizedCount {
    param([int]$Count, [string]$Singular, [string]$Plural)
    if ($Count -eq 1) { return "$Count $Singular" } else { return "$Count $Plural" }
}

# ----- 1. This healer's own raid-list hub page -----
$hubDir = Join-Path $DocsRoot $healerSlug
$hubPath = Join-Path $hubDir "index.html"

$newRowHtml = @"
      <a class="raid-row" href="$RaidDate/index.html">
        <div>
          <div class="raid-title">$RaidTitle</div>
          <div class="raid-meta">$raidDateDisplay &nbsp;&middot;&nbsp; report $ReportCode</div>
        </div>
        <div class="raid-meta">$BossesKilled/$TotalBosses bosses</div>
        <div class="raid-arrow">$([char]0x2192)</div>
      </a>
"@
# &middot; renders as the same middle-dot glyph the existing pages use (&nbsp;·&nbsp; visually) -
# written as an HTML entity here instead of a literal non-ASCII char, consistent with this
# project's PowerShell-source-encoding rule (see ReportRenderLib.psm1's EmDash/RightArrow pattern).

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
    if ($hub.Contains("report $ReportCode")) {
        Write-Host "Report $ReportCode is already listed on $hubPath - skipping insert (no duplicate added)."
    } else {
        $marker = '<div class="raid-list">'
        $idx = $hub.IndexOf($marker)
        if ($idx -lt 0) {
            Write-Host "ERROR: could not find '<div class=`"raid-list`">' in $hubPath - refusing to guess where to insert."
            exit 1
        }
        $insertAt = $idx + $marker.Length
        $hub = $hub.Substring(0, $insertAt) + "`r`n" + $newRowHtml.TrimEnd("`r", "`n") + $hub.Substring($insertAt)

        # Bump "N raid night(s) analyzed" - the only piece of existing text this script
        # ever rewrites, since every real hub page's own row count must stay accurate.
        $countMatch = [regex]::Match($hub, "(\d+) raid nights? analyzed")
        if ($countMatch.Success) {
            $oldCount = [int]$countMatch.Groups[1].Value
            $newCount = $oldCount + 1
            $newCountText = Get-PluralizedCount -Count $newCount -Singular "raid night analyzed" -Plural "raid nights analyzed"
            $hub = $hub.Substring(0, $countMatch.Index) + $newCountText + $hub.Substring($countMatch.Index + $countMatch.Length)
        } else {
            Write-Host "  WARNING: could not find 'N raid night(s) analyzed' text in $hubPath to update the count."
        }

        [System.IO.File]::WriteAllText($hubPath, $hub, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "Updated $hubPath (inserted new raid-row for report $ReportCode)"
    }
}

# ----- 2. Site homepage healer list (only for a genuinely new healer) -----
if ($IsNewHealer) {
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
