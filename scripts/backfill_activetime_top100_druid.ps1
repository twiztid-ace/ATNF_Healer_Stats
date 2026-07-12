# One-off backfill: fetch activeTime/activeTimeReduced for every already-active Druid
# Top 100 parse (~1000 across all 10 bosses), using the same healing-TABLE call added
# to pull_top100_druid.ps1's per-parse worker on 2026-07-12. The normal diff-based
# active/archived pipeline does zero API calls for already-confirmed-active parses, so
# this field doesn't exist yet for any parse pulled before today - this is a one-time
# catch-up, not part of the recurring pipeline. Mirrors pull_top100_druid.ps1's
# RunspacePool pattern (MaxThreads=10, already validated safe at this concurrency).
param(
    [int]$MaxThreads = 10
)

$ErrorActionPreference = "Stop"
Set-Location "C:\Users\raymo\wc_logs"

$apiKey = (Get-Content "apikey.txt" -Raw).Trim()
$baseUrl = "https://fresh.warcraftlogs.com/v1"
$classDir = "data\Classes\Druid"
$activeDir = Join-Path $classDir "active"
$manifestPath = Join-Path $classDir "manifest.json"

# -Encoding UTF8 is required here (matches pull_top100_druid.ps1's manifest read) -
# without it, PowerShell 5.1's Get-Content mangles non-ASCII player names (Chinese,
# Korean, accented Latin) into mojibake, silently breaking the later name-match
# against the healing table response. Confirmed on this exact script's first run:
# every failure was a non-ASCII name, all real ASCII names matched fine.
$manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

# Flatten every active parse across all 10 bosses into one worklist.
$worklist = New-Object System.Collections.Generic.List[object]
foreach ($bossName in $manifest.bosses.PSObject.Properties.Name) {
    $boss = $manifest.bosses.$bossName
    foreach ($parseProp in $boss.parses.PSObject.Properties) {
        $p = $parseProp.Value
        if ($p.status -ne "active") { continue }
        $worklist.Add([PSCustomObject]@{
            BossName   = $bossName
            ReportID   = $p.reportID
            FightID    = $p.fightID
            PlayerName = $p.playerName
            SafeName   = $p.safeName
        })
    }
}
Write-Host "Total active parses to check: $($worklist.Count)"

$fightsCache = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()

$workerScript = {
    param($item, $baseUrl, $apiKey, $activeDir, $fightsCache)

    $result = [PSCustomObject]@{ Ok = $true; Messages = New-Object System.Collections.Generic.List[string]; Skipped = $false }
    $outDir = Join-Path $activeDir $item.BossName
    $outFile = Join-Path $outDir "$($item.ReportID)_$($item.FightID)_$($item.SafeName)_activetime.json"

    if (Test-Path $outFile) {
        $result.Skipped = $true
        return $result
    }

    if (-not $fightsCache.ContainsKey($item.ReportID)) {
        try {
            $fightsUrl = "$baseUrl/report/fights/$($item.ReportID)`?api_key=$apiKey"
            $fd = Invoke-RestMethod -Uri $fightsUrl -UseBasicParsing -ErrorAction Stop
            [void]$fightsCache.TryAdd($item.ReportID, $fd)
        } catch {
            $result.Ok = $false
            $result.Messages.Add("FAILED fetching report $($item.ReportID) (fights list) - $_")
            return $result
        }
    }
    $fightsData = $fightsCache[$item.ReportID]
    $fight = $fightsData.fights | Where-Object { $_.id -eq $item.FightID }
    if (-not $fight) {
        $result.Ok = $false
        $result.Messages.Add("SKIP: fight $($item.FightID) not found in report $($item.ReportID)")
        return $result
    }
    $start = $fight.start_time
    $end = $fight.end_time

    $atUrl = "$baseUrl/report/tables/healing/$($item.ReportID)`?start=$start&end=$end&sourceclass=Druid&api_key=$apiKey"
    try {
        $atResp = Invoke-WebRequest -Uri $atUrl -UseBasicParsing -ErrorAction Stop
        $atData = $atResp.Content | ConvertFrom-Json
    } catch {
        $result.Ok = $false
        $result.Messages.Add("FAILED healing table for $($item.ReportID)/$($item.FightID) ($($item.PlayerName)) - $_")
        return $result
    }
    $atEntry = $atData.entries | Where-Object { $_.name -eq $item.PlayerName } | Select-Object -First 1
    if (-not $atEntry) {
        $result.Ok = $false
        $result.Messages.Add("FAILED activetime for $($item.ReportID)/$($item.FightID) ($($item.PlayerName)) - no matching entry")
        return $result
    }
    $duration = $end - $start
    $activeTimePct = if ($duration -gt 0) { [math]::Round(($atEntry.activeTime / $duration) * 100, 1) } else { 0 }
    $activeTimeReducedPct = if ($duration -gt 0) { [math]::Round(($atEntry.activeTimeReduced / $duration) * 100, 1) } else { 0 }
    $out = [PSCustomObject]@{
        activeTime = $atEntry.activeTime
        activeTimeReduced = $atEntry.activeTimeReduced
        activeTimePct = $activeTimePct
        activeTimeReducedPct = $activeTimeReducedPct
    }
    $jsonText = $out | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($outFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
    return $result
}

$pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
$pool.Open()

$jobs = New-Object System.Collections.Generic.List[object]
foreach ($item in $worklist) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($workerScript).AddArgument($item).AddArgument($baseUrl).AddArgument($apiKey).AddArgument($activeDir).AddArgument($fightsCache)
    $handle = $ps.BeginInvoke()
    $jobs.Add([PSCustomObject]@{ Pipe = $ps; Handle = $handle; Item = $item })
}

$ok = 0
$skipped = 0
$failed = 0
$n = 0
foreach ($job in $jobs) {
    $n++
    try {
        $result = $job.Pipe.EndInvoke($job.Handle)
        foreach ($msg in $result.Messages) { Write-Host "[$n/$($jobs.Count)] $msg" }
        if ($result.Skipped) { $skipped++ }
        elseif ($result.Ok) { $ok++ }
        else { $failed++ }
    } catch {
        Write-Host "[$n/$($jobs.Count)] Worker threw unexpectedly for $($job.Item.ReportID)/$($job.Item.FightID) ($($job.Item.PlayerName)) - $_"
        $failed++
    } finally {
        $job.Pipe.Dispose()
    }
    if ($n % 100 -eq 0) { Write-Host "--- progress: $n/$($jobs.Count) (ok=$ok skipped=$skipped failed=$failed) ---" }
}

$pool.Close()
$pool.Dispose()

Write-Host ""
Write-Host "DONE - ok=$ok skipped=$skipped failed=$failed (total=$($jobs.Count))"
