# One-off backfill: fetch activeTime/activeTimeReduced for Danceswtrees's 10 already-
# pulled Hydross-TK boss kills (2026-07-07 raid night), using the same healing-TABLE
# call added to pull_character_TEMPLATE.ps1 on 2026-07-12. Not part of the normal
# pipeline - existing character pulls predate this field and need a one-time catch-up.
$ErrorActionPreference = "Stop"
Set-Location "C:\Users\raymo\wc_logs"

$apiKey = (Get-Content "apikey.txt" -Raw).Trim()
$baseUrl = "https://fresh.warcraftlogs.com/v1"
$reportID = "XJp8vAxzM4KtHYyb"
$characterName = "Danceswtrees"
$outDir = "data\Characters\Danceswtrees\2026-07-07"

$fightsData = Get-Content (Join-Path $outDir "fights_$reportID.json") -Raw | ConvertFrom-Json

$labels = @{
    6  = "fight06_hydross"
    14 = "fight14_lurker"
    24 = "fight24_leotheras"
    33 = "fight33_karathress"
    41 = "fight41_morogrim"
    46 = "fight46_vashj"
    55 = "fight55_alar"
    65 = "fight65_voidreaver"
    73 = "fight73_solarian"
    81 = "fight81_kaelthas"
}

foreach ($fightID in $labels.Keys | Sort-Object) {
    $label = $labels[$fightID]
    $fight = $fightsData.fights | Where-Object { $_.id -eq $fightID } | Select-Object -First 1
    if (-not $fight) {
        Write-Host "$label - SKIPPED (fight id $fightID not found in fights_$reportID.json)"
        continue
    }
    $outFile = Join-Path $outDir "$($label)_activetime.json"
    if (Test-Path $outFile) {
        Write-Host "$label - already have activetime.json, skipping"
        continue
    }
    $start = $fight.start_time
    $end = $fight.end_time
    $url = "$baseUrl/report/tables/healing/$reportID`?start=$start&end=$end&api_key=$apiKey"
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
        $data = $resp.Content | ConvertFrom-Json
        $entry = $data.entries | Where-Object { $_.name -eq $characterName } | Select-Object -First 1
        if (-not $entry) {
            Write-Host "$label - FAILED (no matching entry in healing table response)"
            continue
        }
        $duration = $end - $start
        $activeTimePct = if ($duration -gt 0) { [math]::Round(($entry.activeTime / $duration) * 100, 1) } else { 0 }
        $activeTimeReducedPct = if ($duration -gt 0) { [math]::Round(($entry.activeTimeReduced / $duration) * 100, 1) } else { 0 }
        $out = [PSCustomObject]@{
            activeTime = $entry.activeTime
            activeTimeReduced = $entry.activeTimeReduced
            activeTimePct = $activeTimePct
            activeTimeReducedPct = $activeTimeReducedPct
        }
        $jsonText = $out | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($outFile, $jsonText, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "$label - OK (activeTime=$activeTimePct%)"
    } catch {
        Write-Host "$label - FAILED: $_"
    }
    Start-Sleep -Milliseconds 300
}
