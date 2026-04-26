function New-JwtPolicyYaml {
    <#
    .SYNOPSIS
        Generates the jwt-policy.yaml file for the agentgateway JWT authentication policy.

    .DESCRIPTION
        Constructs a jwt-policy.yaml AgentgatewayPolicy manifest with inline JWKS, issuer,
        and audience values. The JWKS public keys are fetched live from either a JWK Set URI
        or an OpenID Connect well-known configuration URI using Get-JwkCollection (PSJsonWebToken).
        The resulting YAML is written to jwt-policy.yaml in the current working directory
        unless OutputPath is specified.

    .PARAMETER Uri
        The URI from which to retrieve the JSON Web Key Set. Accepts a direct JWK Set URI
        (e.g. https://idp.example.com/.well-known/jwks.json) or an OpenID Connect
        well-known configuration URI (e.g. https://idp.example.com/.well-known/openid-configuration).
        Get-JwkCollection resolves both forms automatically.

    .PARAMETER Issuer
        The token issuer claim value to require in the JWT authentication policy.
        Must match the "iss" claim in tokens issued by your identity provider,
        e.g. "https://idp.example.com/".

    .PARAMETER Audiences
        One or more audience values to require in the JWT authentication policy.
        Corresponds to the "aud" claim in the JWT.
        Example: @("https://api.example.com")

    .PARAMETER OutputPath
        The file path to write the generated YAML. Defaults to
        jwt-policy.yaml in the current working directory.

    .EXAMPLE
        New-JwtPolicyYaml `
            -Uri "https://idp.example.com/.well-known/openid-configuration" `
            -Issuer "https://idp.example.com/" `
            -Audiences "https://api.example.com"

        Fetches live JWKS via the OpenID Connect discovery document and writes jwt-policy.yaml with one audience.

    .EXAMPLE
        $audiences = @("https://api.example.com", "https://gateway.example.com")
        New-JwtPolicyYaml `
            -Uri "https://idp.example.com/.well-known/jwks.json" `
            -Issuer "https://idp.example.com/" `
            -Audiences $audiences `
            -OutputPath ./custom-jwt-policy.yaml

        Fetches JWKS from a direct JWK Set URI and writes to a custom output path.

    .NOTES
        Requires the powershell-yaml and PSJsonWebToken modules.
        Install with: Install-Module powershell-yaml, PSJsonWebToken
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [Alias('jku', 'JsonWebKeyUri', 'WellKnownConfigUri')]
        [System.Uri]$Uri,

        [Parameter(Mandatory, Position = 1)]
        [string]$Issuer,

        [Parameter(Mandatory, Position = 2)]
        [string[]]$Audiences,

        [Parameter()]
        [string]$OutputPath = (Join-Path $PWD 'jwt-policy.yaml')
    )

    begin {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
        }
        catch {
            Write-Error -ErrorAction Stop `
                -Message "Failed to import module 'powershell-yaml'. Install it with: Install-Module powershell-yaml" `
                -Exception $_.Exception `
                -Category NotInstalled `
                -TargetObject 'powershell-yaml'
        }

        try {
            Import-Module PSJsonWebToken -ErrorAction Stop
        }
        catch {
            Write-Error -ErrorAction Stop `
                -Message "Failed to import module 'PSJsonWebToken'. Install it with: Install-Module PSJsonWebToken" `
                -Exception $_.Exception `
                -Category NotInstalled `
                -TargetObject 'PSJsonWebToken'
        }
    }

    process {
        Write-Verbose "Fetching JWK collection from $Uri"
        $jwks = Get-JwkCollection -Uri $Uri
        $jwkSetJson = @{ keys = $jwks } | ConvertTo-Json -Depth 12 -Compress

        $policy = [ordered]@{
            apiVersion = 'agentgateway.dev/v1alpha1'
            kind       = 'AgentgatewayPolicy'
            metadata   = [ordered]@{
                name      = 'jwt-auth-policy'
                namespace = 'agentgateway-system'
            }
            spec       = [ordered]@{
                targetRefs = @(
                    [ordered]@{
                        group = 'gateway.networking.k8s.io'
                        kind  = 'Gateway'
                        name  = 'agentgateway-proxy'
                    }
                )
                traffic    = [ordered]@{
                    jwtAuthentication = [ordered]@{
                        mode      = 'Strict'
                        providers = @(
                            [ordered]@{
                                issuer    = $Issuer
                                audiences = $Audiences
                                jwks      = [ordered]@{
                                    inline = $jwkSetJson
                                }
                            }
                        )
                    }
                }
            }
        }

        $yaml = ConvertTo-Yaml $policy

        $outputDir = Split-Path $OutputPath
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir | Out-Null
        }

        Set-Content -Path $OutputPath -Value $yaml -Encoding UTF8
        Write-Host "Written: $OutputPath"
    }
}
