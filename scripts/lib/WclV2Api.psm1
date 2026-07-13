# WclV2Api.psm1
#
# Shared OAuth2 + GraphQL helpers for Warcraft Logs' v2 API
# (https://www.warcraftlogs.com/api/v2/client), replacing the v1 REST API's
# `api_key=` query param auth. See WORKFLOW.md / the migration plan for why:
# v1's only percentile sources (/parses/character/, /rankings/character/) can't
# answer "what was this exact report+fight's percentile" - v2's
# reportData.report(code).rankings(fightIDs:[...]) can, confirmed live.
#
# Requires three files at the repo root (gitignored, same convention as
# apikey.txt): v2_client_id.txt, v2_client_secret.txt (from registering a client
# at https://www.warcraftlogs.com/api/clients/ - use a placeholder redirect URL
# like http://localhost, it's required by the form but unused by this grant
# type), and v2_access_token.txt (created automatically on first use).
#
# Usage (run from repo root, same as every other script here):
#   Import-Module (Join-Path $PSScriptRoot "lib\WclV2Api.psm1") -Force
#   $result = Invoke-WclGraphQL -Query 'query { rateLimitData { limitPerHour } }'
#
# RunspacePool note: worker scriptblocks dispatched into a runspace pool do NOT
# inherit the parent session's Import-Module. Each worker must
# Import-Module this file by absolute path (passed in as an argument, same
# pattern already used for $baseUrl/$apiKey in the v1 scripts). To avoid every
# parallel worker independently reading/refreshing the token file (a needless
# race), the OUTER script should call Get-WclAccessToken ONCE and pass the
# resolved token string into each worker, which then passes it to
# Invoke-WclGraphQL via -AccessToken. Invoke-WclGraphQL still self-heals on a
# live 401 regardless (calls Get-WclAccessToken -ForceRefresh and retries once) -
# a harmless safety net even if multiple workers hit it at once, since the token
# file is small and idempotent to rewrite.

$script:TokenEndpoint = "https://www.warcraftlogs.com/oauth/token"
$script:GraphQLEndpoint = "https://www.warcraftlogs.com/api/v2/client"

# Decodes a JWT's payload segment (no signature verification - we don't need it,
# we're just reading our own token's exp claim to decide whether to refresh) and
# returns the expiry as a UTC DateTime.
function Get-WclJwtExpiry {
    param([Parameter(Mandatory=$true)][string]$Token)
    $parts = $Token -split '\.'
    if ($parts.Count -ne 3) { throw "Not a JWT (expected 3 dot-separated segments, got $($parts.Count))" }
    $payload = $parts[1].Replace('-','+').Replace('_','/')
    $payload += ('=' * ((4 - $payload.Length % 4) % 4))
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    return [DateTimeOffset]::FromUnixTimeSeconds([int64]$json.exp).UtcDateTime
}

# Returns a valid access token, refreshing it via the client_credentials grant
# if the cached one is missing, unparseable, or within 5 minutes of expiring.
# Confirmed working token lifetime is ~360 days, so this refreshes rarely - it's
# still checked on every call rather than cached in-process, since each script
# invocation is short-lived anyway (matches this pipeline's existing pattern of
# re-reading apikey.txt fresh each run rather than caching across runs).
function Get-WclAccessToken {
    param(
        [string]$ClientIdFile = "v2_client_id.txt",
        [string]$ClientSecretFile = "v2_client_secret.txt",
        [string]$TokenFile = "v2_access_token.txt",
        [switch]$ForceRefresh
    )
    if ((Test-Path $TokenFile) -and -not $ForceRefresh) {
        $cached = (Get-Content $TokenFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($cached) {
            try {
                $expiry = Get-WclJwtExpiry -Token $cached
                if ($expiry -gt (Get-Date).ToUniversalTime().AddMinutes(5)) {
                    return $cached
                }
            } catch {
                # Unparseable cached token - fall through and fetch a fresh one.
            }
        }
    }

    if (-not (Test-Path $ClientIdFile) -or -not (Test-Path $ClientSecretFile)) {
        throw "Missing $ClientIdFile / $ClientSecretFile at repo root. Register a client at https://www.warcraftlogs.com/api/clients/ (Name: anything; Redirect URL: a placeholder like http://localhost - required by the form, unused by the client_credentials grant) and save the Client ID / Client Secret into these two files."
    }
    $clientId = (Get-Content $ClientIdFile -Raw).Trim()
    $clientSecret = (Get-Content $ClientSecretFile -Raw).Trim()
    $pair = "$clientId`:$clientSecret"
    $basicAuth = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    $headers = @{ Authorization = "Basic $basicAuth" }
    $resp = Invoke-RestMethod -Uri $script:TokenEndpoint -Method Post -Headers $headers -Body @{ grant_type = "client_credentials" } -ErrorAction Stop
    [System.IO.File]::WriteAllText($TokenFile, $resp.access_token, (New-Object System.Text.UTF8Encoding $false))
    return $resp.access_token
}

# POSTs one GraphQL query. Returns [PSCustomObject]@{ Data; Errors } - GraphQL
# returns HTTP 200 even on a query error (a top-level "errors" array alongside
# possibly-null "data"), so this NEVER throws on that case - callers must check
# .Errors explicitly rather than relying on try/catch. Only a real transport
# failure (network error, non-200 status) produces an exception-derived Errors
# entry here.
function Invoke-WclGraphQL {
    param(
        [Parameter(Mandatory=$true)][string]$Query,
        [hashtable]$Variables,
        [string]$AccessToken,
        [switch]$IsRetry
    )
    $token = if ($AccessToken) { $AccessToken } else { Get-WclAccessToken }
    $headers = @{ Authorization = "Bearer $token" }
    $bodyObj = @{ query = $Query }
    if ($Variables) { $bodyObj.variables = $Variables }
    $bodyJson = $bodyObj | ConvertTo-Json -Depth 10 -Compress

    try {
        $resp = Invoke-WebRequest -Uri $script:GraphQLEndpoint -Method Post -Headers $headers -ContentType "application/json" -Body $bodyJson -UseBasicParsing -ErrorAction Stop
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -eq 401 -and -not $IsRetry) {
            $freshToken = Get-WclAccessToken -ForceRefresh
            return Invoke-WclGraphQL -Query $Query -Variables $Variables -AccessToken $freshToken -IsRetry
        }
        return [PSCustomObject]@{ Data = $null; Errors = @("HTTP request failed: $_") }
    }

    $parsed = $resp.Content | ConvertFrom-Json
    $errors = $null
    if ($parsed.PSObject.Properties.Name -contains "errors") { $errors = $parsed.errors }
    return [PSCustomObject]@{ Data = $parsed.data; Errors = $errors }
}

# Wraps Invoke-WclGraphQL for a paginated `events()`-shaped field (the only v2
# field confirmed to paginate - returns {data:[...], nextPageTimestamp}).
# $QueryBuilder: scriptblock taking one $startTime arg, returning the full query
#   string for that page (the caller embeds $startTime into its own query text).
# $ExtractPage: scriptblock taking the raw $Data from one page's response,
#   returning [PSCustomObject]@{ Items = <array>; NextPageTimestamp = <float-or-null> }
#   - the caller knows the exact path into $Data for its specific query shape.
# Stops early (with a warning) after $MaxPages as a safety valve against a
# malformed/looping nextPageTimestamp - this should never realistically trigger.
#
# CALLER GOTCHA (cost real debugging time, confirmed live - avoid repeating it):
# this function invokes $QueryBuilder via `& $QueryBuilder $startTime` from ITS
# OWN function scope. If $QueryBuilder references any variable that is LOCAL to
# the function/scriptblock where $QueryBuilder was defined (not script-scope,
# not global), that variable resolves to $null here - PowerShell's dynamic
# scoping does not expose a defining function's locals to a different function
# that later invokes the block. This silently produces a malformed query (empty
# report code / fight ID / etc), which typically comes back as zero results with
# NO error, not an exception - exactly the failure mode that caught this the
# first time (every fight's healing/casts events silently returned 0). ALWAYS
# call `.GetNewClosure()` on $QueryBuilder wherever it references anything other
# than genuine script-scope variables, e.g.:
#   $queryBuilder = { param($startTime) "query { ... $localVar ... }" }.GetNewClosure()
function Invoke-WclGraphQLPaged {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$QueryBuilder,
        [Parameter(Mandatory=$true)][scriptblock]$ExtractPage,
        [string]$AccessToken,
        [double]$InitialStartTime = 0,
        [int]$MaxPages = 500
    )
    $allItems = New-Object System.Collections.Generic.List[object]
    $startTime = $InitialStartTime
    $pageCount = 0
    $errors = $null

    while ($true) {
        $pageCount++
        if ($pageCount -gt $MaxPages) {
            Write-Host "  WARNING: Invoke-WclGraphQLPaged hit MaxPages ($MaxPages) - stopping, possible pagination loop (verify nextPageTimestamp is advancing)"
            break
        }
        $query = & $QueryBuilder $startTime
        $result = Invoke-WclGraphQL -Query $query -AccessToken $AccessToken
        if ($result.Errors) {
            $errors = $result.Errors
            break
        }
        $page = & $ExtractPage $result.Data
        foreach ($item in $page.Items) { $allItems.Add($item) }
        if ($pageCount -ge 2) {
            Write-Host "  ...page $pageCount (running total $($allItems.Count) events)"
        }
        if ($null -eq $page.NextPageTimestamp) { break }
        $startTime = $page.NextPageTimestamp
    }

    # .ToArray(), NOT a bare $allItems (a List[object]) and NOT @($allItems) either
    # - confirmed live on Windows PowerShell 5.1: wrapping a
    # List[object]-of-PSCustomObject in @() throws "Argument types do not match"
    # as a NON-terminating error (silently continues) rather than failing loudly,
    # leaving the caller with a truncated/empty array and no visible sign
    # anything went wrong. Cost real debugging time to trace (every fight's
    # healing/casts events came back as 0 with no error anywhere in the chain -
    # the underlying List itself was always fully populated). .ToArray() is a
    # plain .NET method, not PowerShell's array-coercion machinery, and produces
    # a normal object[] callers can safely index/wrap/pipe with no surprises.
    return [PSCustomObject]@{ Items = $allItems.ToArray(); Errors = $errors; PageCount = $pageCount }
}

Export-ModuleMember -Function Get-WclJwtExpiry, Get-WclAccessToken, Invoke-WclGraphQL, Invoke-WclGraphQLPaged
