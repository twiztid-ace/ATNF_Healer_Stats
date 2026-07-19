# statusline.ps1
#
# Claude Code statusLine command for this project. Shows Claude's own
# session/weekly usage (from the statusLine JSON payload's rate_limits field -
# Pro/Max plans only, and only after the first API response in a session, so
# this is displayed conditionally) and the live Warcraft Logs v2 GraphQL API
# rate limit (points spent this hour / limit, next reset) whenever the current
# session is working inside this repo. See CLAUDE.md's "WCL v2 GraphQL API
# reference" section for why the WCL part matters - the hourly clock has
# caused a real full lockout before (429 even on the rateLimitData diagnostic
# itself).
#
# Deliberately omits model name / directory (already visible elsewhere in the
# UI) and uses compact abbreviations/units throughout - this line is meant to
# maximize how much of the limited status bar width goes to the numbers that
# actually matter.
#
# The WCL segment is cached to .wcl_ratelimit_cache.json (repo root,
# gitignored) with a 5-minute TTL so this doesn't spend a GraphQL call - and
# therefore rate-limit points - on every single statusline render. Claude's
# own rate_limits are handed to us directly in the payload, so no caching is
# needed for that part.
#
# NOTE: this is not currently the active statusLine command (see the global
# ~/.claude/settings.json, which points at a separate, simpler script) - kept
# here as the WCL-aware version, moved out of the now-deleted scripts\ folder
# (2026-07-19, end of the PowerShell->Python migration) along with its one
# real dependency, tools\WclV2Api.psm1 (a trimmed copy of the old
# scripts\lib\WclV2Api.psm1).

$repoRoot = "C:\Users\raymo\wc_logs"
$cacheFile = Join-Path $repoRoot ".wcl_ratelimit_cache.json"
$ttlSeconds = 300

# Compact "h:mmtt" -> "2:33p" (no space, single-letter am/pm) to save width.
function Format-ClockCompact {
    param([Parameter(Mandatory=$true)][datetime]$DateTime, [switch]$IncludeDay)
    $fmt = if ($IncludeDay) { "ddd h:mmtt" } else { "h:mmtt" }
    $s = $DateTime.ToString($fmt)
    return ($s -replace 'AM$','a' -replace 'PM$','p')
}

# 8178 -> "8.2k", 18000 -> "18k", 950 -> "950".
function Format-CountCompact {
    param([Parameter(Mandatory=$true)][double]$Value)
    if ($Value -ge 1000) {
        $k = [math]::Round($Value / 1000, 1)
        if ($k -eq [math]::Floor($k)) { return "$([int]$k)k" }
        return "${k}k"
    }
    return "$([int]$Value)"
}

$inputJson = [Console]::In.ReadToEnd()
$ctx = $null
if ($inputJson) {
    try { $ctx = $inputJson | ConvertFrom-Json } catch {}
}

$cwd = $null
if ($ctx.workspace.current_dir) { $cwd = $ctx.workspace.current_dir }
elseif ($ctx.cwd) { $cwd = $ctx.cwd }
else { $cwd = (Get-Location).Path }

$parts = New-Object System.Collections.Generic.List[string]

# Claude's own 5-hour session / 7-day weekly usage, if present - absent for
# non-subscribers or before the first API response in a session, so this must
# degrade silently rather than erroring the whole statusline.
try {
    $fiveHour = $ctx.rate_limits.five_hour
    if ($fiveHour -and $null -ne $fiveHour.used_percentage) {
        $pct = [math]::Round($fiveHour.used_percentage)
        $resetLocal = [DateTimeOffset]::FromUnixTimeSeconds([int64]$fiveHour.resets_at).ToLocalTime()
        $parts.Add("Sess $pct%~$(Format-ClockCompact -DateTime $resetLocal.DateTime)")
    }
} catch {}
try {
    $sevenDay = $ctx.rate_limits.seven_day
    if ($sevenDay -and $null -ne $sevenDay.used_percentage) {
        $pct = [math]::Round($sevenDay.used_percentage)
        $resetLocal = [DateTimeOffset]::FromUnixTimeSeconds([int64]$sevenDay.resets_at).ToLocalTime()
        $parts.Add("Wk $pct%~$(Format-ClockCompact -DateTime $resetLocal.DateTime -IncludeDay)")
    }
} catch {}

$inProject = $cwd -like "$repoRoot*"

if ($inProject) {
    $cache = $null
    if (Test-Path $cacheFile) {
        try { $cache = Get-Content $cacheFile -Raw | ConvertFrom-Json } catch {}
    }

    $needsRefresh = $true
    if ($cache -and $cache.fetchedAtUtc) {
        try {
            $fetchedAt = [datetime]::Parse($cache.fetchedAtUtc).ToUniversalTime()
            if (((Get-Date).ToUniversalTime() - $fetchedAt).TotalSeconds -lt $ttlSeconds) {
                $needsRefresh = $false
            }
        } catch {}
    }

    if ($needsRefresh) {
        try {
            Import-Module (Join-Path $repoRoot "tools\WclV2Api.psm1") -Force
            Push-Location $repoRoot
            $result = Invoke-WclGraphQL -Query 'query { rateLimitData { limitPerHour pointsSpentThisHour pointsResetIn } }'
            Pop-Location
            if (-not $result.Errors -and $result.Data.rateLimitData) {
                $fresh = [PSCustomObject]@{
                    limitPerHour        = $result.Data.rateLimitData.limitPerHour
                    pointsSpentThisHour = $result.Data.rateLimitData.pointsSpentThisHour
                    pointsResetIn       = $result.Data.rateLimitData.pointsResetIn
                    fetchedAtUtc        = (Get-Date).ToUniversalTime().ToString("o")
                }
                $fresh | ConvertTo-Json | Set-Content -Path $cacheFile -Encoding utf8
                $cache = $fresh
            }
        } catch {}
    }

    if ($cache -and $cache.limitPerHour) {
        try {
            $fetchedAt = [datetime]::Parse($cache.fetchedAtUtc).ToUniversalTime()
            $elapsed = ((Get-Date).ToUniversalTime() - $fetchedAt).TotalSeconds
            $remaining = [math]::Max(0, [int]($cache.pointsResetIn - $elapsed))
            $resetClock = Format-ClockCompact -DateTime (Get-Date).AddSeconds($remaining)
            $pct = [math]::Round(($cache.pointsSpentThisHour / $cache.limitPerHour) * 100)
            $spent = Format-CountCompact -Value $cache.pointsSpentThisHour
            $limit = Format-CountCompact -Value $cache.limitPerHour
            $parts.Add("WCL $pct%~$resetClock ($spent/$limit)")
        } catch {}
    }
}

Write-Output ($parts -join " | ")
