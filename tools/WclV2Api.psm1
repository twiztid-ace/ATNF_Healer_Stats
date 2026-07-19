# WclV2Api.psm1 (trimmed)
#
# Minimal OAuth2 + GraphQL client for Warcraft Logs' v2 API
# (https://www.warcraftlogs.com/api/v2/client), kept only for
# tools\statusline.ps1's WCL rate-limit segment. This is a trimmed copy of the
# old pipeline's scripts\lib\WclV2Api.psm1 (removed 2026-07-19 once the
# PowerShell->Python migration was complete and no longer needed as a
# rollback) - dropped the pagination helper and TBC consumable-classification
# logic, since a statusline only ever makes one small rateLimitData query.
# The live pipeline's own equivalent is pipeline\wcl_api.py (Python).
#
# Requires three files at the repo root (gitignored): v2_client_id.txt,
# v2_client_secret.txt (from registering a client at
# https://www.warcraftlogs.com/api/clients/), and v2_access_token.txt
# (created automatically on first use).

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

Export-ModuleMember -Function Get-WclJwtExpiry, Get-WclAccessToken, Invoke-WclGraphQL
