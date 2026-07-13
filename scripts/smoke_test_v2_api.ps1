# smoke_test_v2_api.ps1
#
# Phase 0 of the v1->v2 WCL API migration (see the approved migration plan).
# Throwaway verification script, not part of the regular pipeline: confirms
# WclV2Api.psm1 works end-to-end against the real API before any real pull
# script depends on it. Exercises the 5 call shapes the migration plan relies on:
#   1. Token fetch (Get-WclAccessToken)
#   2. reportData.report(code).fights(...)
#   3. Paginated reportData.report(code).events(dataType: Healing, ...)
#   4. reportData.report(code).table(dataType: Deaths, ...)
#   5. gameData.ability(id) name/icon lookup
#
# Run from repo root: powershell -ExecutionPolicy Bypass -File scripts\smoke_test_v2_api.ps1

Import-Module (Join-Path $PSScriptRoot "lib\WclV2Api.psm1") -Force

$reportCode = "Fm9XdWYtz8VCLnwg"
$fightID = 17
$danceswtreesID = 9
$lifebloomGuid = 33763

$failures = 0

Write-Host "=== 1. Token fetch ==="
try {
    $token = Get-WclAccessToken
    $expiry = Get-WclJwtExpiry -Token $token
    Write-Host "  OK - token acquired, expires $expiry"
} catch {
    Write-Host "  FAILED: $_"
    $failures++
    Write-Host ""
    Write-Host "Cannot continue without a token - stopping."
    exit 1
}

Write-Host ""
Write-Host "=== 2. reportData.report(code).fights(...) ==="
$fightsQuery = "query { reportData { report(code: `"$reportCode`") { fights(fightIDs: [$fightID]) { id startTime endTime name kill } } } }"
$fightsResult = Invoke-WclGraphQL -Query $fightsQuery -AccessToken $token
if ($fightsResult.Errors) {
    Write-Host "  FAILED: $($fightsResult.Errors | ConvertTo-Json -Compress)"
    $failures++
} else {
    $fight = $fightsResult.Data.reportData.report.fights[0]
    Write-Host "  OK - fight $($fight.id): $($fight.name), start=$($fight.startTime) end=$($fight.endTime) kill=$($fight.kill)"
}

Write-Host ""
Write-Host "=== 3. Paginated events(dataType: Healing) ==="
$queryBuilder = {
    param($startTime)
    "query { reportData { report(code: `"$reportCode`") { events(fightIDs: [$fightID], sourceID: $danceswtreesID, dataType: Healing, includeResources: true, startTime: $startTime) { data nextPageTimestamp } } } }"
}
$extractPage = {
    param($data)
    [PSCustomObject]@{
        Items = @($data.reportData.report.events.data)
        NextPageTimestamp = $data.reportData.report.events.nextPageTimestamp
    }
}
$pagedResult = Invoke-WclGraphQLPaged -QueryBuilder $queryBuilder -ExtractPage $extractPage -AccessToken $token
if ($pagedResult.Errors) {
    Write-Host "  FAILED: $($pagedResult.Errors | ConvertTo-Json -Compress)"
    $failures++
} else {
    Write-Host "  OK - $($pagedResult.Items.Count) healing events across $($pagedResult.PageCount) page(s)"
    $totalAmount = ($pagedResult.Items | Measure-Object -Property amount -Sum).Sum
    $totalOverheal = ($pagedResult.Items | Measure-Object -Property overheal -Sum).Sum
    Write-Host "  total=$totalAmount overheal=$totalOverheal (compare against fight17_hydross_healing_events.json: total=190331, overheal=215205)"
    $hasClassResources = @($pagedResult.Items | Where-Object { $_.classResources }).Count
    Write-Host "  events with classResources present: $hasClassResources / $($pagedResult.Items.Count)"
}

Write-Host ""
Write-Host "=== 4. table(dataType: Deaths) ==="
$deathsQuery = "query { reportData { report(code: `"$reportCode`") { table(fightIDs: [$fightID], dataType: Deaths) } } }"
$deathsResult = Invoke-WclGraphQL -Query $deathsQuery -AccessToken $token
if ($deathsResult.Errors) {
    Write-Host "  FAILED: $($deathsResult.Errors | ConvertTo-Json -Compress)"
    $failures++
} else {
    $entries = @($deathsResult.Data.reportData.report.table.data.entries)
    Write-Host "  OK - $($entries.Count) death entries (expect 10 for this fight)"
}

Write-Host ""
Write-Host "=== 5. gameData.ability(id) ==="
$abilityQuery = "query { gameData { ability(id: $lifebloomGuid) { id name icon } } }"
$abilityResult = Invoke-WclGraphQL -Query $abilityQuery -AccessToken $token
if ($abilityResult.Errors) {
    Write-Host "  FAILED: $($abilityResult.Errors | ConvertTo-Json -Compress)"
    $failures++
} else {
    $ability = $abilityResult.Data.gameData.ability
    Write-Host "  OK - guid $lifebloomGuid -> name='$($ability.name)' icon='$($ability.icon)' (expect name='Lifebloom')"
}

Write-Host ""
Write-Host "=================================="
if ($failures -eq 0) {
    Write-Host "All 5 checks passed. WclV2Api.psm1 is ready for Phase 1."
} else {
    Write-Host "$failures of 5 checks FAILED - do not proceed to Phase 1 until these pass."
    exit 1
}
