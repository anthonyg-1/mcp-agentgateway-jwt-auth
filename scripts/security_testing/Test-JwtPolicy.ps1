#Requires -Modules PSJsonWebToken
<#
.SYNOPSIS
    Tests agentgateway's JWT authentication policy.

.DESCRIPTION
    Exercises the AgentgatewayPolicy (Strict mode, RS256, Auth0 JWKS) by sending
    requests with a variety of tokens and asserting the expected HTTP response code.

    Test matrix:
      1. No token                       -> 401  (Strict mode blocks anonymous)
      2. Garbage token                  -> 401
      3. HS256 token (alg confusion)    -> 401  (gateway expects RS256)
      4. Expired JWT                    -> 401
      5. Wrong audience                 -> 401
      6. Wrong issuer                   -> 401
      7. Valid Auth0 JWT                -> 2xx  (happy path)

    Requires a running agentgateway reachable at $GatewayUrl.
    Env vars AUTH0_DOMAIN, AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET, AUTH0_AUDIENCE
    are read automatically if the corresponding parameters are not supplied.

.PARAMETER GatewayUrl
    Base URL of the agentgateway, e.g. http://localhost:8080.
    Defaults to $env:GATEWAY_URL, then http://localhost:8080.

.PARAMETER GatewayPath
    Path to probe on the gateway. Defaults to /mcp.

.PARAMETER Auth0Domain
    Auth0 tenant domain (no scheme), e.g. dev-xxxx.us.auth0.com.
    Defaults to $env:AUTH0_DOMAIN.

.PARAMETER ClientId
    Auth0 machine-to-machine client ID. Defaults to $env:AUTH0_CLIENT_ID.

.PARAMETER ClientSecret
    Auth0 client secret. Defaults to $env:AUTH0_CLIENT_SECRET.

.PARAMETER Audience
    JWT audience claim expected by the gateway.
    Defaults to $env:AUTH0_AUDIENCE, then https://mcp.gateway.

.EXAMPLE
    # Use env vars (typical CI usage)
    ./Test-JwtPolicy.ps1

.EXAMPLE
    # Override the gateway URL
    ./Test-JwtPolicy.ps1 -GatewayUrl http://192.168.64.2:30080
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'Colored pass/fail output is the primary purpose of this test script.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'New-FakeToken generates a JWT string in memory; no system state is changed.'
)]
[CmdletBinding()]
param(
    [string]$GatewayUrl   = ($env:GATEWAY_URL   ? $env:GATEWAY_URL   : 'http://localhost:8080'),
    [string]$GatewayPath  = '/mcp',
    [string]$Auth0Domain  = $env:AUTH0_DOMAIN,
    [string]$ClientId     = $env:AUTH0_CLIENT_ID,
    [string]$ClientSecret = $env:AUTH0_CLIENT_SECRET,
    [string]$Audience     = ($env:AUTH0_AUDIENCE ? $env:AUTH0_AUDIENCE : 'https://mcp.gateway')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- helpers ------------------------------------------------------------------

function Write-Pass {
    param([string]$Label)
    Write-Host "[PASS] $Label" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Label, [string]$Detail)
    $msg = "[FAIL] $Label"
    if ($Detail) { $msg += ": $Detail" }
    Write-Host $msg -ForegroundColor Red
}

function Write-Section {
    param([string]$Title)
    Write-Host "`n-- $Title --" -ForegroundColor Cyan
}

# Sends a GET to the gateway and returns the HTTP status code (int).
# Never throws; connection errors return 0.
function Invoke-Gateway {
    param(
        [string]$Token
    )

    $uri     = "$GatewayUrl$GatewayPath"
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }

    try {
        $response = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers `
            -TimeoutSec 10 -SkipHttpErrorCheck
        return [int]$response.StatusCode
    }
    catch {
        # Connection refused or DNS failure; surface as 0.
        Write-Verbose "Request error: $_"
        return 0
    }
}

# Creates a self-signed HS256 JWT that will fail RS256 validation at the gateway.
function New-FakeToken {
    param(
        [hashtable]$ClaimOverrides = @{}
    )

    $now = [DateTimeOffset]::UtcNow

    # Use the real issuer so only the algorithm / signature is wrong.
    $claims = @{
        sub = 'test-subject'
        iss = "https://$Auth0Domain/"
        aud = $Audience
        iat = $now.ToUnixTimeSeconds()
        exp = $now.AddHours(1).ToUnixTimeSeconds()
    }
    foreach ($key in $ClaimOverrides.Keys) { $claims[$key] = $ClaimOverrides[$key] }

    return New-JsonWebToken -Claims $claims -HashAlgorithm SHA256 -SecretKey 'not-the-right-key'
}

# Assert helpers - each returns $true on success, $false on failure.
function Assert-StatusCode {
    param(
        [string]$Label,
        [int]$Actual,
        [int]$Expected
    )

    if ($Actual -eq 0) {
        Write-Fail $Label "gateway unreachable (status 0); is agentgateway running at $GatewayUrl?"
        return $false
    }
    if ($Actual -eq $Expected) {
        Write-Pass "$Label (HTTP $Actual)"
        return $true
    }
    Write-Fail $Label "expected HTTP $Expected, got HTTP $Actual"
    return $false
}

function Assert-Rejected {
    param([string]$Label, [int]$Actual)
    Assert-StatusCode -Label $Label -Actual $Actual -Expected 401
}

function Assert-Accepted {
    param([string]$Label, [int]$Actual)
    if ($Actual -ge 200 -and $Actual -lt 300) {
        Write-Pass "$Label (HTTP $Actual)"
        return $true
    }
    if ($Actual -eq 0) {
        Write-Fail $Label "gateway unreachable (status 0); is agentgateway running at $GatewayUrl?"
        return $false
    }
    Write-Fail $Label "expected 2xx, got HTTP $Actual"
    return $false
}

# -- preflight ----------------------------------------------------------------

Write-Host "`nagentgateway JWT Policy Test Suite" -ForegroundColor White
Write-Host "Gateway : $GatewayUrl$GatewayPath"
Write-Host "Audience: $Audience"
Write-Host "Issuer  : https://$Auth0Domain/"

$passed = 0
$failed = 0

function Tally {
    param([bool]$Ok)
    if ($Ok) { $script:passed++ } else { $script:failed++ }
}

# -- token acquisition --------------------------------------------------------

Write-Section 'Token Acquisition'

if (-not $Auth0Domain -or -not $ClientId -or -not $ClientSecret) {
    Write-Host '[SKIP] AUTH0_DOMAIN / AUTH0_CLIENT_ID / AUTH0_CLIENT_SECRET not set; skipping live-token tests.' `
        -ForegroundColor Yellow
    $validToken = $null
}
else {
    try {
        $tokenResponse = Invoke-RestMethod `
            -Uri     "https://$Auth0Domain/oauth/token" `
            -Method  Post `
            -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' } `
            -Body    "grant_type=client_credentials&client_id=$ClientId&client_secret=$ClientSecret&audience=$Audience"

        $validToken = $tokenResponse.access_token

        # Decode and display the token's expiry without verifying the signature.
        $decoded = Get-JsonWebTokenPayload -JsonWebToken $validToken -AsHashtable
        $expiry  = [DateTimeOffset]::FromUnixTimeSeconds($decoded.exp).ToLocalTime()
        Write-Pass "Auth0 token acquired (expires $($expiry.ToString('HH:mm:ss zzz')))"
        $passed++
    }
    catch {
        Write-Fail 'Auth0 token acquisition' "$_"
        $failed++
        $validToken = $null
    }
}

# -- negative tests -----------------------------------------------------------

Write-Section 'Negative Tests (all expect HTTP 401)'

# 1. No token
Tally (Assert-Rejected 'No Authorization header' (Invoke-Gateway -Token ''))

# 2. Garbage token
Tally (Assert-Rejected 'Garbage token' (Invoke-Gateway -Token 'not.a.jwt'))

# 3. Algorithm confusion: HS256 token with correct claims
$hs256Token = New-FakeToken
Tally (Assert-Rejected 'HS256 token (algorithm confusion)' (Invoke-Gateway -Token $hs256Token))

# 4. Expired JWT (exp in the past, iat 2 h ago)
$now = [DateTimeOffset]::UtcNow
$expiredToken = New-FakeToken -ClaimOverrides @{
    iat = $now.AddHours(-2).ToUnixTimeSeconds()
    exp = $now.AddHours(-1).ToUnixTimeSeconds()
}
Tally (Assert-Rejected 'Expired JWT' (Invoke-Gateway -Token $expiredToken))

# 5. Wrong audience
$wrongAudToken = New-FakeToken -ClaimOverrides @{ aud = 'https://wrong.audience/' }
Tally (Assert-Rejected 'Wrong audience' (Invoke-Gateway -Token $wrongAudToken))

# 6. Wrong issuer
$wrongIssToken = New-FakeToken -ClaimOverrides @{ iss = 'https://evil.example.com/' }
Tally (Assert-Rejected 'Wrong issuer' (Invoke-Gateway -Token $wrongIssToken))

# -- positive test ------------------------------------------------------------

Write-Section 'Positive Test (expects HTTP 2xx)'

if ($validToken) {
    Tally (Assert-Accepted 'Valid Auth0 JWT' (Invoke-Gateway -Token $validToken))
}
else {
    Write-Host '[SKIP] No valid token; positive test skipped.' -ForegroundColor Yellow
}

# -- summary ------------------------------------------------------------------

Write-Host ''
Write-Host ('-' * 45)
$totalColor = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "Results: $passed passed, $failed failed" -ForegroundColor $totalColor
Write-Host ('-' * 45)

exit $failed   # non-zero exit lets CI pipelines detect failures
