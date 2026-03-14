#!/usr/bin/env pwsh
# -*- coding: utf-8 -*-
<#
Simple SANtricity PowerShell helpers for PowerShell 7.
Copyright: 2026 scaleoutSean (github.com/scaleoutsean)
License: Apache License 2.0 (see LICENSE file for details)
#>


using namespace System.Collections.Generic
using namespace System.Security.Cryptography.X509Certificates

$script:SANtricity_Config = [pscustomobject]@{}
$script:SANtricityTranscriptInfo = $null

# Try to import bundled PowerShellRich for nicer CLI output when available
$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$repoRoot = Split-Path -Path $scriptDir -Parent
$richModulePath = Join-Path $repoRoot 'PowerShellRich/PowerShellRich.psd1'
try {
    Import-Module $richModulePath -Force -ErrorAction SilentlyContinue
} catch {
    # PowerShellRich not available - continuing without rich formatting
}

# Source Private Functions
$privateFunctionsPath = Join-Path $scriptDir 'Private'
if (Test-Path $privateFunctionsPath) {
    $privateFunctions = Get-ChildItem -Path $privateFunctionsPath -Filter '*.ps1'
    foreach ($func in $privateFunctions) {
        . $func.FullName
    }
}

# Source Public Functions
$publicFunctionsPath = Join-Path $scriptDir 'Public'
if (Test-Path $publicFunctionsPath) {
    $publicFunctions = Get-ChildItem -Path $publicFunctionsPath -Filter '*.ps1'
    foreach ($func in $publicFunctions) {
        . $func.FullName
    }
}

# Clean out the inline definitions of functions that have been moved to external files.
# The remaining functions (Connect-SANtricity, Invoke-SANtricityRequest set global state so they remain here for clarity,
# though they could also be moved).

function Connect-SANtricity {
    <#
    .SYNOPSIS
    Create a connection configuration for SANtricity controllers.

    .DESCRIPTION
    Stores connection information (one or more controller base URLs, auth headers,
    API base path and storage system id) in the script-scoped `SANtricity_Config` variable.

    .PARAMETER BaseUrl
    One or more controller base URLs (string or string[]). Example: 'https://10.0.0.1:8443'

    .PARAMETER Username
    Username for Basic auth.

    .PARAMETER Password
    Password for Basic auth.

    .PARAMETER Token
    JWT token for Bearer auth.

    .PARAMETER Auth
    Authentication mode: 'Basic' or 'Jwt'.

    .PARAMETER VerifySsl
    Whether to verify TLS certificates. Set to $false to skip certificate validation
    (uses Invoke-RestMethod's -SkipCertificateCheck). For production, use -TrustedCertificate
    instead to properly trust the controller's certificate.

    .PARAMETER TrustedCertificate
    Path to a .pem or .cer file containing the SANtricity controller certificate or a custom CA chain.
    When provided, those certificates will be trusted for TLS connections through the legacy HttpClient
    pipeline. The module automatically enables the legacy pipeline when this parameter is used so you
    can avoid -VerifySsl:$false in production.

    .PARAMETER ApiBasePathPrefix
    API base path prefix (default 'devmgr/v2'). Use full API prefix; system scope will
    be added as '/storage-systems/{id}/' when needed.

    .PARAMETER AuthBasicPath
    Path used for auth basic endpoints (default 'devmgr/utils').

    .PARAMETER StorageSystemId
    Storage system id to use in API paths (default '1'). Provide the actual system ID/WWN
    to skip auto-discovery, which requires a successful TLS-protected API call.

    .PARAMETER IdCase
    Identifier normalization mode: 'none' (default), 'upper', or 'lower'. When set,
    IDs returned from the array and those provided by the user will be normalized
    using this setting to improve matching.

    .PARAMETER CreateTranscript
    Start a PowerShell transcript for troubleshooting. WARNING: transcripts capture
    everything typed, including credentials; use only in secure environments.

    .PARAMETER TranscriptPath
    Optional custom path for the transcript file when -CreateTranscript is used.

    .PARAMETER ValidateConnection
    When specified, performs a quick request against the controller to confirm it is
    reachable and attempt to discover the storage-system id immediately.

    .PARAMETER SkipLogin
    Create the connection configuration without authenticating. Useful for dry-run testing
    or CI where the controller is not reachable.

    .PARAMETER UseLegacyHttpClient
    Enable the legacy HttpClient-based request pipeline that supports trusted certificate
    pinning via -TrustedCertificate.

    .EXAMPLE
    Connect-SANtricity -BaseUrl 'https://10.1.1.1:8443' -Username admin -Password admin -IdCase upper

    Connect-SANtricity -BaseUrl @('https://c1:8443','https://c2:8443') -Username admin -Password admin -IdCase lower
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [Alias('BaseUrls', 'Url')] [object] $BaseUrl,
        [Alias('User')] [string] $Username,
        [Alias('Pass')] [string] $Password,
        [string] $Token,
        [pscredential] $Credential,
        [ValidateSet('Basic','Jwt')] [string] $Auth = 'Basic',
        [object] $VerifySsl = $true,
        [Alias('IgnoreCertErrors')] [switch] $SkipCertificateCheck,
        [string] $TrustedCertificate,
        [string] $ApiBasePathPrefix = 'devmgr/v2',
        [string] $AuthBasicPath = 'devmgr/utils',
        [string] $StorageSystemId = '1',
        [ValidateSet('none','upper','lower')] [string] $IdCase = 'none',
        [switch] $CreateTranscript,
        [string] $TranscriptPath,
        [switch] $ValidateConnection,
        [switch] $SkipLogin,
        [switch] $UseLegacyHttpClient
    )

    if ($SkipCertificateCheck) { $VerifySsl = $false }
    if ($Credential) {
        $Username = $Credential.UserName
        $Password = $Credential.GetNetworkCredential().Password
    }

    if ([string]::IsNullOrWhiteSpace($ApiBasePathPrefix)) { $ApiBasePathPrefix = 'devmgr/v2' }
    else { $ApiBasePathPrefix = $ApiBasePathPrefix.Trim('/') }

    if ([string]::IsNullOrWhiteSpace($AuthBasicPath)) { $AuthBasicPath = 'devmgr/utils' }
    else { $AuthBasicPath = $AuthBasicPath.Trim('/') }

    # normalize BaseUrl into an array of trimmed strings
    $baseUrls = @()
    if ($null -ne $BaseUrl) {
        if ($BaseUrl -is [System.Array]) {
            foreach ($u in $BaseUrl) { $baseUrls += $u.TrimEnd('/') }
        } else {
            $baseUrls = ,($BaseUrl.ToString().TrimEnd('/'))
        }
    }

    $trustedCertInfo = $null

    # Session-based authentication (like curl but with persistent session)
    $webSession = $null
    $lastLoginError = $null
    if ($SkipLogin) {
        Write-Verbose 'SkipLogin specified; connection config will be created without authenticating.'
    } elseif ($Username -and $Password) {
        # Login to get session cookie
        Write-Verbose "Attempting session-based login with user: $Username"
        Write-Verbose "BaseUrls configured: $($baseUrls -join ', ')"
        Write-Verbose "AuthBasicPath: $AuthBasicPath"
        
        foreach ($base in $baseUrls) {
            try {
                $loginUrl = "$base/$AuthBasicPath/login"
                Write-Verbose "Login URL: $loginUrl"
                
                $loginBodyHashtable = @{
                    userId = $Username
                    password = $Password
                    xsrfProtected = $false
                }
                $loginBody = $loginBodyHashtable | ConvertTo-Json

                $sanitizedBody = (@{
                    userId = $Username
                    password = '<redacted>'
                    xsrfProtected = $loginBodyHashtable.xsrfProtected
                } | ConvertTo-Json)
                Write-Verbose "Login body (sanitized): $sanitizedBody"
                
                $loginHeaders = @{
                    'Accept' = 'application/json'
                    'Content-Type' = 'application/json'
                }
                
                $loginParams = @{
                    Uri = $loginUrl
                    Method = 'POST'
                    Headers = $loginHeaders
                    Body = $loginBody
                    SessionVariable = 'webSession'
                }
                
                if ($VerifySsl -eq $false) {
                    $loginParams['SkipCertificateCheck'] = $true
                    Write-Verbose "Skipping certificate check for login"
                }
                
                Write-Verbose "Sending login request..."
                $loginResponse = Invoke-RestMethod @loginParams
                Write-Verbose "Login successful! Session captured."
                break
            } catch {
                $lastLoginError = $_
                Write-Warning "Login failed at ${base}: $($_.Exception.Message)"
                if ($_.ErrorDetails.Message) {
                    Write-Warning "Error details: $($_.ErrorDetails.Message)"
                }
                continue
            }
        }
        
        if (-not $webSession) {
            $errMsg = "Failed to establish session with any configured controller."
            if ($lastLoginError) {
                $errMsg += " Last error: $($lastLoginError.Exception.Message)"
            }
            throw $errMsg
        }
    } elseif ($Auth -eq 'Jwt' -and $Token) {
        # JWT token support (session not needed)
        $headers = @{ 'Authorization' = "Bearer $Token" }
        Write-Verbose "Using JWT token authentication"
    } else {
        throw "Either Username/Password or Token must be provided"
    }

    if ($TrustedCertificate) {
        $resolvedCertPath = [System.IO.Path]::GetFullPath($TrustedCertificate)
        if (-not [System.IO.File]::Exists($resolvedCertPath)) {
            throw "Trusted certificate file not found: $TrustedCertificate"
        }
        if (-not $UseLegacyHttpClient) {
            Write-Verbose "-TrustedCertificate specified; enabling legacy HttpClient pipeline for certificate pinning."
            $UseLegacyHttpClient = $true
        }
        $trustedCertInfo = Get-SANtricityTrustedCertificateInfo -Path $resolvedCertPath
        $TrustedCertificate = $resolvedCertPath
    }

    # Normalize VerifySsl to a boolean even if user passed a string like 'false' or '0'
    try {
        if ($VerifySsl -is [string]) {
            switch ($VerifySsl.ToLowerInvariant()) {
                'true' { $VerifySsl = $true }
                'false' { $VerifySsl = $false }
                '1' { $VerifySsl = $true }
                '0' { $VerifySsl = $false }
                default { $VerifySsl = [bool]::Parse($VerifySsl) }
            }
        } else {
            $VerifySsl = [bool]$VerifySsl
        }
    } catch {
        # fallback to true when conversion fails
        $VerifySsl = $true
    }

    if ([string]::IsNullOrWhiteSpace($ApiBasePathPrefix)) { $ApiBasePathPrefix = 'devmgr/v2' }
    else { $ApiBasePathPrefix = $ApiBasePathPrefix.Trim('/') }

    if ([string]::IsNullOrWhiteSpace($AuthBasicPath)) { $AuthBasicPath = 'devmgr/utils' }
    else { $AuthBasicPath = $AuthBasicPath.Trim('/') }

    $script:SANtricity_Config = [pscustomobject]@{
        BaseUrls        = $baseUrls
        WebSession      = $webSession
        Headers         = if ($Auth -eq 'Jwt') { $headers } else { @{} }
        VerifySsl       = $VerifySsl
        TrustedCertificate = $TrustedCertificate
        TrustedCertificateInfo = $trustedCertInfo
        UseLegacyHttpClient = [bool]$UseLegacyHttpClient
        ApiBasePathPrefix = $ApiBasePathPrefix
        AuthBasicPath   = $AuthBasicPath
        StorageSystemId = $StorageSystemId
        StorageSystemIdExplicit = $PSBoundParameters.ContainsKey('StorageSystemId')
        IdCase          = $IdCase
        LastSuccessfulBaseUrl = $null
    }

    Write-Verbose "SANtricity_Config set: BaseUrls=$($baseUrls -join ',') StorageSystemId=$StorageSystemId"

    $summary = [ordered]@{
        BaseUrls        = $baseUrls
        ActiveBaseUrl   = if ($baseUrls.Count -gt 0) { $baseUrls[0] } else { $null }
        StorageSystemId = $StorageSystemId
        StorageSystemIdExplicit = $PSBoundParameters.ContainsKey('StorageSystemId')
        AuthMode        = $Auth
        VerifySsl       = [bool]$VerifySsl
        IdCase          = $IdCase
        ApiBasePath     = $ApiBasePathPrefix
        AuthBasicPath   = $AuthBasicPath
        Validated       = $false
        TranscriptActive = $false
        TranscriptPath   = $null
    }

    if ($CreateTranscript) {
        try {
            $transcriptInfo = Start-SANtricityTranscript -Path $TranscriptPath -Append -IncludeInvocationHeader
            if ($transcriptInfo) {
                $summary.TranscriptActive = $true
                $summary.TranscriptPath = $transcriptInfo.Path
                Write-Warning "Transcript logging is enabled. Remove or secure $($transcriptInfo.Path) after troubleshooting."
            }
        } catch {
            Write-Warning "Failed to start transcript: $($_.Exception.Message)"
        }
    }

    if ($ValidateConnection) {
        try {
            $resolvedId = Get-SANtricitySystemId
            if ($resolvedId) { $summary.StorageSystemId = $resolvedId }
            $cfgLatest = $script:SANtricity_Config
            if ($cfgLatest -and ($cfgLatest.PSObject.Properties.Name -contains 'LastSuccessfulBaseUrl') -and $cfgLatest.LastSuccessfulBaseUrl) {
                $summary.ActiveBaseUrl = $cfgLatest.LastSuccessfulBaseUrl
            }
            $summary.Validated = $true
            Write-Verbose "Validated SANtricity controller via $($summary.ActiveBaseUrl)"
        } catch {
            $summary.ValidationError = $_.Exception.Message
            Write-Warning "Validation attempt failed: $($_.Exception.Message)"
        }
    }

    Write-Host "SANtricity config ready for $($summary.ActiveBaseUrl) (StorageSystemId: $($summary.StorageSystemId))"
    return [PSCustomObject]$summary
}


function Invoke-SANtricityRequest {
    <#
    .SYNOPSIS
    Invoke an HTTP request against SANtricity controllers with failover.

    .PARAMETER Method
    HTTP method (GET, POST, PUT, DELETE, PATCH, HEAD).

    .PARAMETER Path
    Relative resource path. If it begins with '/', it is appended to the ApiBasePathPrefix/StorageSystemId
    (e.g. '/volumes' -> /devmgr/v2/storage-systems/{id}/volumes). If it contains 'login' or does not start
    with '/', the AuthBasicPath is used (e.g. 'login' -> /devmgr/utils/login).

    .PARAMETER Body
    Optional payload. Non-string values are converted to JSON automatically.

    .PARAMETER ContentType
    Content-Type header when a body is present (default 'application/json').

    .PARAMETER AdditionalHeaders
    Optional per-call headers merged with the connection headers.

    .PARAMETER RawResponse
    Return the raw response string instead of attempting JSON conversion.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $Method,
        [Parameter(Mandatory = $true)] [string] $Path,
        [bool] $UseSystemScope = $true,
        [object] $Body,
        [string] $ContentType = 'application/json',
        [hashtable] $AdditionalHeaders,
        [switch] $RawResponse
    )

    $cfg = $script:SANtricity_Config
    if (-not $cfg) { throw 'Not connected. Call Connect-SANtricity first.' }
    if (-not $cfg.BaseUrls -or $cfg.BaseUrls.Count -eq 0) {
        throw 'No controller BaseUrl has been configured. Call Connect-SANtricity first.'
    }

    $apiBasePath = $cfg.ApiBasePathPrefix
    if ([string]::IsNullOrWhiteSpace($apiBasePath)) {
        $apiBasePath = 'devmgr/v2'
        $cfg.ApiBasePathPrefix = $apiBasePath
        $script:SANtricity_Config = $cfg
    } else {
        $apiBasePath = $apiBasePath.Trim('/')
    }

    $authBasicPath = $cfg.AuthBasicPath
    if ([string]::IsNullOrWhiteSpace($authBasicPath)) {
        $authBasicPath = 'devmgr/utils'
        $cfg.AuthBasicPath = $authBasicPath
        $script:SANtricity_Config = $cfg
    } else {
        $authBasicPath = $authBasicPath.Trim('/')
    }

    $methodUpper = $Method.ToUpperInvariant()
    $httpMethod = switch ($methodUpper) {
        'GET' { [System.Net.Http.HttpMethod]::Get }
        'POST' { [System.Net.Http.HttpMethod]::Post }
        'PUT' { [System.Net.Http.HttpMethod]::Put }
        'DELETE' { [System.Net.Http.HttpMethod]::Delete }
        'PATCH' { [System.Net.Http.HttpMethod]::new('PATCH') }
        'HEAD' { [System.Net.Http.HttpMethod]::Head }
        default { throw "Unsupported HTTP method '$Method'." }
    }

    if ($PSBoundParameters.ContainsKey('Body') -and $methodUpper -in @('GET','HEAD')) {
        throw "HTTP method '$Method' cannot include a body."
    }

    $lastException = $null
    $lastAttemptedUrl = $null
    foreach ($base in $cfg.BaseUrls) {
        try {
            $trimmedPath = if ($null -ne $Path) { $Path.Trim() } else { '' }

            if ([string]::IsNullOrWhiteSpace($trimmedPath)) {
                throw 'Request path was empty.'
            }

            $baseUriValue = if ($base.EndsWith('/')) { $base } else { "$base/" }
            $baseUri = [System.Uri]::new($baseUriValue, [System.UriKind]::Absolute)
            Write-Verbose "Base URI: $baseUriValue | Trimmed path: $trimmedPath | UseSystemScope: $UseSystemScope"

            if ($trimmedPath.StartsWith('http',[System.StringComparison]::OrdinalIgnoreCase)) {
                $url = $trimmedPath
                Write-Verbose "Using absolute URL from Path: $url"
            } elseif ($trimmedPath.StartsWith('/')) {
                if ($UseSystemScope) {
                    $systemId = Get-SANtricitySystemId
                    if ([string]::IsNullOrWhiteSpace($systemId)) {
                        throw "StorageSystemId is empty; cannot construct system-scoped path. Call Connect-SANtricity with -StorageSystemId."
                    }
                    $systemId = $systemId.Trim('/')
                    $pathSegment = $trimmedPath.TrimStart('/')
                    $relative = "${apiBasePath}/storage-systems/${systemId}/${pathSegment}"
                    Write-Verbose "System-scoped path: apiBasePath=$apiBasePath, systemId=$systemId, segment=$pathSegment -> $relative"
                } else {
                    $pathSegment = $trimmedPath.TrimStart('/')
                    $relative = "${apiBasePath}/${pathSegment}"
                    Write-Verbose "Non-system-scoped path: apiBasePath=$apiBasePath, segment=$pathSegment -> $relative"
                }
                $url = [System.Uri]::new($baseUri, $relative.TrimStart('/')).AbsoluteUri
            } elseif ($trimmedPath -match 'login' -or $trimmedPath.StartsWith($authBasicPath,[System.StringComparison]::OrdinalIgnoreCase)) {
                $pathSegment = $trimmedPath.TrimStart('/')
                $relative = "${authBasicPath}/${pathSegment}"
                Write-Verbose "Auth path: authBasicPath=$authBasicPath, segment=$pathSegment -> $relative"
                $url = [System.Uri]::new($baseUri, $relative.TrimStart('/')).AbsoluteUri
            } else {
                $systemId = Get-SANtricitySystemId
                if ([string]::IsNullOrWhiteSpace($systemId)) {
                    throw "StorageSystemId is empty; cannot construct default system-scoped path. Call Connect-SANtricity with -StorageSystemId."
                }
                $systemId = $systemId.Trim('/')
                $pathSegment = $trimmedPath.TrimStart('/')
                $relative = "${apiBasePath}/storage-systems/${systemId}/${pathSegment}"
                Write-Verbose "Default system-scoped path: apiBasePath=$apiBasePath, systemId=$systemId, segment=$pathSegment -> $relative"
                $url = [System.Uri]::new($baseUri, $relative.TrimStart('/')).AbsoluteUri
            }

            $lastAttemptedUrl = $url
            Write-Verbose ("WebRequest: {0} {1}" -f $methodUpper, $url)

            # Build headers
            $headers = @{}
            foreach ($key in $cfg.Headers.Keys) {
                if ($cfg.Headers[$key]) { $headers[$key] = $cfg.Headers[$key] }
            }
            if ($AdditionalHeaders) {
                foreach ($key in $AdditionalHeaders.Keys) {
                    if ($AdditionalHeaders[$key]) { $headers[$key] = $AdditionalHeaders[$key] }
                }
            }

            # Prepare sanitized headers for verbose logging
            $logHeaders = $headers.Clone()
            if ($logHeaders.ContainsKey('Authorization')) {
                $authValue = $logHeaders['Authorization']
                if ($authValue -and $authValue.StartsWith('Bearer ', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $logHeaders['Authorization'] = 'Bearer <redacted>'
                } elseif ($authValue -and $authValue.StartsWith('Basic ', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $logHeaders['Authorization'] = 'Basic <redacted>'
                }
            }
            Write-Verbose ("Request headers: {0}" -f ($logHeaders | ConvertTo-Json -Depth 8))

            if (-not $cfg.UseLegacyHttpClient) {
                # Build Invoke-RestMethod parameters
                $restParams = @{
                    Uri = $url
                    Method = $methodUpper
                    Headers = $headers
                    TimeoutSec = 90
                }
                
                # Use WebSession for session-based auth (Basic)
                if ($cfg.PSObject.Properties.Name -contains 'WebSession' -and $cfg.WebSession) {
                    $restParams['WebSession'] = $cfg.WebSession
                }

                # Handle TLS certificate validation
                if ($cfg.VerifySsl -eq $false) {
                    Write-Verbose "Disabling TLS certificate validation with -SkipCertificateCheck"
                    $restParams['SkipCertificateCheck'] = $true
                }

                # Handle request body
                if ($PSBoundParameters.ContainsKey('Body')) {
                    $bodyPayload = $Body
                    if ($null -ne $bodyPayload -and -not ($bodyPayload -is [string])) {
                        $bodyPayload = $bodyPayload | ConvertTo-Json -Depth 32
                    }
                    if ($bodyPayload) {
                        # Redact sensitive data from logs
                        $logPayload = $bodyPayload
                        if ($logPayload -match 'password":\s*"[^"]+') {
                           $logPayload = $logPayload -replace 'password":\s*"[^"]+', 'password": "REDACTED'
                        }
                        if ($logPayload -match 'currentPassword":\s*"[^"]+') {
                           $logPayload = $logPayload -replace 'currentPassword":\s*"[^"]+', 'currentPassword": "REDACTED'
                        }
                        if ($logPayload -match 'newPassword":\s*"[^"]+') {
                           $logPayload = $logPayload -replace 'newPassword":\s*"[^"]+', 'newPassword": "REDACTED'
                        }
                        Write-Verbose "Request Body: $logPayload"
                    }
                    $restParams['Body'] = $bodyPayload
                    $restParams['ContentType'] = $ContentType
                }

                # Make the request
                $response = Invoke-RestMethod @restParams

                Write-Verbose ("WebResponse: {0} {1}" -f $methodUpper, $url)
                $cfg.LastSuccessfulBaseUrl = $base
                $script:SANtricity_Config = $cfg

                if ($RawResponse) {
                    if ($response -is [string]) { return $response }
                    return ($response | ConvertTo-Json -Depth 64)
                }
                return $response
            }

            Write-Verbose "Using legacy HttpClientHandler path for this request"
            $handler = [System.Net.Http.HttpClientHandler]::new()

            if ($cfg.VerifySsl -eq $false) {
                Write-Verbose "Legacy mode: disabling TLS validation via custom callback"
                $callback = [System.Func[System.Net.Http.HttpRequestMessage, System.Security.Cryptography.X509Certificates.X509Certificate2, System.Security.Cryptography.X509Certificates.X509Chain, System.Net.Security.SslPolicyErrors, bool]] {
                    param($request, $cert, $chain, $errors)
                    return $true
                }
                $handler.ServerCertificateCustomValidationCallback = $callback
            } elseif ($cfg.TrustedCertificateInfo) {
                $trustInfo = $cfg.TrustedCertificateInfo
                Write-Verbose "Legacy mode: enforcing trusted certificates from $($trustInfo.Path)"
                $trustedLeafThumbprints = @($trustInfo.LeafThumbprints)
                $trustedRootThumbprints = @($trustInfo.RootThumbprints)
                $trustedRoots = @($trustInfo.RootCertificates)
                $trustedIntermediates = @($trustInfo.IntermediateCertificates)

                $callback = [System.Func[System.Net.Http.HttpRequestMessage, System.Security.Cryptography.X509Certificates.X509Certificate2, System.Security.Cryptography.X509Certificates.X509Chain, System.Net.Security.SslPolicyErrors, bool]] {
                    param($request, $cert, $chain, $errors)
                    if ($null -eq $cert) { return $false }

                    if ($trustedLeafThumbprints -and ($trustedLeafThumbprints -contains $cert.Thumbprint)) {
                        return $true
                    }

                    if ($chain -and $trustedRootThumbprints -and $chain.ChainElements.Count -gt 0) {
                        $chainRoot = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
                        if ($trustedRootThumbprints -contains $chainRoot.Thumbprint) {
                            return $true
                        }
                    }

                    if (($trustedRoots.Count -gt 0) -or ($trustedIntermediates.Count -gt 0)) {
                        $customChain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
                        try {
                            $policy = $customChain.ChainPolicy
                            $policy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                            $policy.RevocationFlag = [System.Security.Cryptography.X509Certificates.X509RevocationFlag]::EntireChain
                            foreach ($extra in $trustedIntermediates) { $null = $policy.ExtraStore.Add($extra) }

                            $policyProps = $policy.PSObject.Properties.Name
                            $hasCustomStore = $policyProps -contains 'CustomTrustStore'
                            $hasTrustMode = $policyProps -contains 'TrustMode'

                            if ($hasCustomStore -and $hasTrustMode -and $trustedRoots.Count -gt 0) {
                                foreach ($root in $trustedRoots) { $null = $policy.CustomTrustStore.Add($root) }
                                $policy.TrustMode = [System.Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
                            } else {
                                foreach ($root in $trustedRoots) { $null = $policy.ExtraStore.Add($root) }
                                $policy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
                            }

                            if ($customChain.Build($cert)) { return $true }
                        } finally {
                            $customChain.Dispose()
                        }
                    }

                    return $false
                }
                $handler.ServerCertificateCustomValidationCallback = $callback
            } else {
                Write-Verbose "Legacy mode: using system trust store for TLS validation"
            }

            $client = [System.Net.Http.HttpClient]::new($handler)
            $client.Timeout = [System.TimeSpan]::FromSeconds(90)
            $requestMessage = [System.Net.Http.HttpRequestMessage]::new($httpMethod, $url)

            foreach ($key in $headers.Keys) {
                if ($headers[$key]) { $null = $requestMessage.Headers.TryAddWithoutValidation($key, $headers[$key]) }
            }

            if ($PSBoundParameters.ContainsKey('Body')) {
                $bodyPayload = $Body
                if ($null -ne $bodyPayload -and -not ($bodyPayload -is [string]) -and -not ($bodyPayload -is [byte[]])) {
                    $bodyPayload = $bodyPayload | ConvertTo-Json -Depth 32
                }

                if ($bodyPayload -is [byte[]]) {
                    $content = [System.Net.Http.ByteArrayContent]::new($bodyPayload)
                    if ($ContentType) {
                        $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)
                    }
                } else {
                    $encoding = [System.Text.Encoding]::UTF8
                    $useContentType = if ($ContentType) { $ContentType } else { 'application/json' }
                    $content = [System.Net.Http.StringContent]::new([string]$bodyPayload, $encoding, $useContentType)
                }
                $requestMessage.Content = $content
            }

            try {
                $responseMessage = $client.SendAsync($requestMessage).GetAwaiter().GetResult()
                $rawResponse = if ($responseMessage.Content) { $responseMessage.Content.ReadAsStringAsync().GetAwaiter().GetResult() } else { $null }

                if (-not $responseMessage.IsSuccessStatusCode) {
                    $statusMsg = "{0} ({1})" -f [int]$responseMessage.StatusCode, $responseMessage.ReasonPhrase
                    $errorText = "Response status code does not indicate success: $statusMsg"
                    if ($rawResponse) { $errorText = "$errorText. Body: $rawResponse" }
                    throw [System.Net.Http.HttpRequestException]::new($errorText)
                }

                Write-Verbose ("WebResponse: {0} {1}" -f $methodUpper, $url)
                $cfg.LastSuccessfulBaseUrl = $base
                $script:SANtricity_Config = $cfg

                if ($RawResponse) { return $rawResponse }
                if ([string]::IsNullOrWhiteSpace($rawResponse)) { return $true }

                try {
                    return $rawResponse | ConvertFrom-Json -Depth 64
                } catch {
                    return $rawResponse
                }
            } finally {
                if ($responseMessage) { $responseMessage.Dispose() }
                if ($requestMessage) { $requestMessage.Dispose() }
                if ($client) { $client.Dispose() }
                if ($handler) { $handler.Dispose() }
            }
        } catch {
            $lastException = $_
            Write-Verbose "Request attempt failed: $lastAttemptedUrl -> $($_.Exception.Message)"
            continue
        }
    }
    if ($lastException) {
        $baseCount = $cfg.BaseUrls.Count
        $msg = "Request failed after trying $baseCount base URL(s). Last attempted: $lastAttemptedUrl. Error: $($lastException.Exception.Message)"
        $errorRecord = New-Object System.Management.Automation.ErrorRecord ($lastException.Exception, 'SANtricityRequestFailed', [System.Management.Automation.ErrorCategory]::InvalidOperation, $lastAttemptedUrl)
        $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails($msg)
        throw $errorRecord
    }
}

# Export functions defined inline plus all public functions found in Public/ directory
$publicFunctionsPath = Join-Path $scriptDir 'Public'
$dynamicExports = if (Test-Path $publicFunctionsPath) {
    (Get-ChildItem -Path $publicFunctionsPath -Filter '*.ps1').BaseName
} else { @() }
$staticExports = @('Connect-SANtricity', 'Invoke-SANtricityRequest')

Export-ModuleMember -Function ($staticExports + $dynamicExports)
