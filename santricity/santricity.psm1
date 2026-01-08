#!/usr/bin/env pwsh
# -*- coding: utf-8 -*-
<#
Simple SANtricity PowerShell helpers for PowerShell 7.
Copyright: 2026 scaleoutSean (github.com/scaleoutsean)
License: Apache License 2.0 (see LICENSE file for details)
#>


using namespace System.Collections.Generic

$script:SANtricity_Config = [pscustomobject]@{}
$script:SANtricityTranscriptInfo = $null

# Try to import bundled PowerShellRich for nicer CLI output when available
$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$repoRoot = Split-Path -Path $scriptDir -Parent
$richModulePath = Join-Path $repoRoot 'PowerShellRich/PowerShellRich.psd1'
if (Test-Path $richModulePath) {
    Import-Module $richModulePath -Force -ErrorAction SilentlyContinue
}

# Dot-source public helpers (keep core Connect/Invoke in this root file)
$publicPath = Join-Path $scriptDir 'Public/MappingReport.psm1'
try {
    . $publicPath
} catch {
    # MappingReport helpers not available - continuing without them
}

function Start-SANtricityTranscript {
    <#
    .SYNOPSIS
    Start a transcript for troubleshooting SANtricity CLI usage.

    .PARAMETER Path
    Optional path for the transcript file. Defaults to the current directory with a timestamped filename.

    .PARAMETER Append
    Append to the file if it already exists (default: true).

    .PARAMETER IncludeInvocationHeader
    Include invocation headers in the transcript (default: true).
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [switch] $Append,
        [switch] $IncludeInvocationHeader
    )

    if ($script:SANtricityTranscriptInfo -and $script:SANtricityTranscriptInfo.Active) {
        Write-Verbose "Transcript already active at $($script:SANtricityTranscriptInfo.Path)"
        return [PSCustomObject]$script:SANtricityTranscriptInfo
    }

    if (-not $Path) {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $Path = Join-Path -Path (Get-Location).Path -ChildPath "santricity_client_${timestamp}.log"
    } elseif (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path -Path (Get-Location).Path -ChildPath $Path
    }

    $Path = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $startParams = @{ LiteralPath = $Path }
    if ($Append.IsPresent) { $startParams['Append'] = $true } else { $startParams['Append'] = $true }
    if ($IncludeInvocationHeader.IsPresent -or -not $PSBoundParameters.ContainsKey('IncludeInvocationHeader')) {
        $startParams['IncludeInvocationHeader'] = $true
    }

    Start-Transcript @startParams | Out-Null

    $info = [ordered]@{ Active = $true ; Path = $Path ; Started = Get-Date }
    $script:SANtricityTranscriptInfo = $info
    return [PSCustomObject]$info
}

function Stop-SANtricityTranscript {
    <#
    .SYNOPSIS
    Stop an active SANtricity transcript if one is running.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:SANtricityTranscriptInfo -or -not $script:SANtricityTranscriptInfo.Active) {
        Write-Verbose 'No SANtricity transcript is currently active.'
        return $false
    }

    try {
        Stop-Transcript | Out-Null
        $script:SANtricityTranscriptInfo = $null
        return $true
    } catch {
        Write-Warning "Failed to stop transcript: $($_.Exception.Message)"
        return $false
    }
}

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
    Path to a .pem or .cer file containing the SANtricity controller's certificate or CA chain.
    When provided, this certificate will be trusted for TLS connections. Use this instead of
    -VerifySsl:$false for production deployments.

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

    .EXAMPLE
    Connect-SANtricity -BaseUrl 'https://10.1.1.1:8443' -Username admin -Password admin -IdCase upper

    Connect-SANtricity -BaseUrl @('https://c1:8443','https://c2:8443') -Username admin -Password admin -IdCase lower
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [Alias('BaseUrls')] [object] $BaseUrl,
        [string] $Username,
        [string] $Password,
        [string] $Token,
        [ValidateSet('Basic','Jwt')] [string] $Auth = 'Basic',
        [object] $VerifySsl = $true,
        [string] $TrustedCertificate,
        [string] $ApiBasePathPrefix = 'devmgr/v2',
        [string] $AuthBasicPath = 'devmgr/utils',
        [string] $StorageSystemId = '1',
        [ValidateSet('none','upper','lower')] [string] $IdCase = 'none',
        [switch] $CreateTranscript,
        [string] $TranscriptPath,
        [switch] $ValidateConnection
    )

    if ([string]::IsNullOrWhiteSpace($ApiBasePathPrefix)) { $ApiBasePathPrefix = 'devmgr/v2' }
    else { $ApiBasePathPrefix = $ApiBasePathPrefix.Trim('/') }

    if ([string]::IsNullOrWhiteSpace($AuthBasicPath)) { $AuthBasicPath = 'devmgr/utils' }
    else { $AuthBasicPath = $AuthBasicPath.Trim('/') }

    # Session-based authentication (like curl but with persistent session)
    $webSession = $null
    $lastLoginError = $null
    if ($Username -and $Password) {
        # Login to get session cookie
        Write-Verbose "Attempting session-based login with user: $Username"
        foreach ($base in $baseUrls) {
            try {
                $loginUrl = "$base/$AuthBasicPath/login"
                Write-Verbose "Login URL: $loginUrl"
                
                $loginBody = @{
                    userId = $Username
                    password = $Password
                    xsrfProtected = $false
                } | ConvertTo-Json
                
                Write-Verbose "Login body: $loginBody"
                
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
    } else {
        throw "Either Username/Password or Token must be provided"
    }

    # normalize BaseUrl into an array of trimmed strings
    $baseUrls = @()
    if ($null -ne $BaseUrl) {
        if ($BaseUrl -is [System.Array]) {
            foreach ($u in $BaseUrl) { $baseUrls += $u.TrimEnd('/') }
        } else {
            $baseUrls = ,($BaseUrl.ToString().TrimEnd('/'))
        }
    }

    # If TrustedCertificate is provided and VerifySsl wasn't explicitly set, enable validation
    if (-not [string]::IsNullOrWhiteSpace($TrustedCertificate) -and -not $PSBoundParameters.ContainsKey('VerifySsl')) {
        Write-Verbose "TrustedCertificate provided - enabling TLS validation"
        $VerifySsl = $true
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
        ApiBasePathPrefix = $ApiBasePathPrefix
        AuthBasicPath   = $AuthBasicPath
        StorageSystemId = $StorageSystemId
        StorageSystemIdExplicit = $PSBoundParameters.ContainsKey('StorageSystemId')
        IdCase          = $IdCase
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

function Normalize-SANtricityId {
    <#
    .SYNOPSIS
    Normalize hex-like identifiers according to configured casing.

    .PARAMETER Id
    Identifier string to normalize.

    .DESCRIPTION
    Applies casing normalization (upper/lower) when configured; returns original string
    when `none` is selected.
    #>
    param([Parameter(Mandatory=$true)][string] $Id)

    if (-not $Id) { return $Id }
    $cfg = $script:SANtricity_Config
    if (-not $cfg -or -not ($cfg.PSObject.Properties.Name -contains 'IdCase')) { return $Id }
    switch ($cfg.IdCase) {
        'upper' { return $Id.ToUpperInvariant() }
        'lower' { return $Id.ToLowerInvariant() }
        default { return $Id }
    }
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
            } elseif ($cfg.PSObject.Properties.Name -contains 'TrustedCertificate' -and -not [string]::IsNullOrWhiteSpace($cfg.TrustedCertificate)) {
                Write-Verbose "TrustedCertificate parameter is not yet implemented in Invoke-RestMethod"
                Write-Verbose "Workaround: Using -SkipCertificateCheck (certificate will be loaded but not validated)"
                Write-Warning "Certificate trust validation not yet implemented. Install the certificate in your system trust store, or use -VerifySsl:`$false for testing."
                # For now, skip validation - proper implementation requires HttpClientHandler with custom callback
                $restParams['SkipCertificateCheck'] = $true
            }

            # Handle request body
            if ($PSBoundParameters.ContainsKey('Body')) {
                $bodyPayload = $Body
                if ($null -ne $bodyPayload -and -not ($bodyPayload -is [string])) {
                    $bodyPayload = $bodyPayload | ConvertTo-Json -Depth 32
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

function Get-SANtricitySystemId {
    <#
    .SYNOPSIS
    Return the configured storage system id (placeholder).

    .DESCRIPTION
    Currently returns the configured `StorageSystemId` from the connection config; in future
    this can query the controller to discover the actual system id/WWN.
    #>
    param()

    $cfg = $script:SANtricity_Config
    if (-not $cfg) { throw 'Not connected. Call Connect-SANtricity first.' }
    
    # If user explicitly provided a StorageSystemId, use it without discovery
    if ($cfg.PSObject.Properties.Name -contains 'StorageSystemIdExplicit' -and $cfg.StorageSystemIdExplicit) {
        $id = [string]$cfg.StorageSystemId
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'Configured StorageSystemId is empty or whitespace. Call Connect-SANtricity with a valid -StorageSystemId.'
        }
        Write-Verbose "Using explicitly configured StorageSystemId: $id"
        return $id
    }
    
    # If we have a non-default ID, use it
    if ($cfg.StorageSystemId -and $cfg.StorageSystemId -ne '1') {
        $id = [string]$cfg.StorageSystemId
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'Configured StorageSystemId is empty or whitespace. Call Connect-SANtricity with a valid -StorageSystemId.'
        }
        Write-Verbose "Using configured StorageSystemId: $id"
        return $id
    }

    # attempt discovery if StorageSystemId is default/placeholder
    $discovered = Discover-SANtricitySystemId
    if ($discovered) {
        # persist discovered id
        $cfg.StorageSystemId = $discovered
        $script:SANtricity_Config = $cfg
        Write-Verbose "Discovered and cached StorageSystemId: $discovered"
        return $discovered
    }
    $fallback = if ($cfg.StorageSystemId) { [string]$cfg.StorageSystemId } else { '1' }
    if ([string]::IsNullOrWhiteSpace($fallback)) {
        throw 'Unable to determine StorageSystemId. Call Connect-SANtricity with -StorageSystemId or ensure the controller is reachable.'
    }
    Write-Verbose "Using fallback StorageSystemId: $fallback"
    return $fallback
}

function Discover-SANtricitySystemId {
    <#
    .SYNOPSIS
    Discover the storage-system id/WWN by querying the controller's /storage-systems endpoint.
    #>
    param()

    $payload = Invoke-SANtricityRequest -Method 'GET' -Path '/storage-systems' -UseSystemScope:$false
    if ($payload -is [System.Collections.IEnumerable]) {
        foreach ($item in $payload) {
            if ($item -is [System.Collections.IDictionary]) {
                $candidate = $null
                if ($item.Contains('wwn')) { $candidate = $item['wwn'] }
                if (-not $candidate -and $item.Contains('id')) { $candidate = $item['id'] }
                if ($candidate -and [string]::IsNullOrWhiteSpace($candidate) -eq $false) {
                    return $candidate.Trim()
                }
            }
        }
    }
    return $null
}

function Get-SANtricityVolumes {
    <#
    .SYNOPSIS
    Retrieve volumes from the SANtricity API.

    .DESCRIPTION
    Calls the controller's volumes endpoint and returns the volume objects.
    #>
    return Invoke-SANtricityRequest -Method 'GET' -Path '/volumes'
}

function Get-SANtricityStoragePools {
    <#
    .SYNOPSIS
    Retrieve storage pools from the SANtricity API.

    .DESCRIPTION
    Calls the controller's storage-pools endpoint and returns pool objects.
    #>
    return Invoke-SANtricityRequest -Method 'GET' -Path '/storage-pools'
}

function Get-SANtricityHosts {
    <#
    .SYNOPSIS
    Retrieve host definitions from the SANtricity API.

    .DESCRIPTION
    Calls the controller's hosts endpoint and returns host objects.
    #>
    return Invoke-SANtricityRequest -Method 'GET' -Path '/hosts'
}

function Get-SANtricityHostGroups {
    <#
    .SYNOPSIS
    Retrieve host-groups from the SANtricity API.

    .DESCRIPTION
    Calls the controller's host-groups endpoint and returns host-group objects.
    #>
    return Invoke-SANtricityRequest -Method 'GET' -Path '/host-groups'
}

function Get-SANtricityVolumeMappings {
    <#
    .SYNOPSIS
    Retrieve volume mappings from the SANtricity API.

    .DESCRIPTION
    Calls the controller's volume-mappings endpoint and returns mapping objects.
    #>
    return Invoke-SANtricityRequest -Method 'GET' -Path '/volume-mappings'
}

function Get-SANtricityMappingsReport {
    <#
    .SYNOPSIS
    Build a consolidated mappings report.

    .DESCRIPTION
    Aggregates volumes, pools, hosts, host-groups and volume mappings to produce a
    report suitable for display or further processing.

    .EXAMPLE
    Get-SANtricityMappingsReport | Format-Table -AutoSize
    #>
    [CmdletBinding()]
    param()

    $fetch = {
        param(
            [string] $description,
            [string] $path,
            [scriptblock] $operation
        )

        try {
            return @(& $operation)
        } catch {
            $msg = "Get-SANtricityMappingsReport failed while retrieving $description ($path). $($_.Exception.Message)"
            throw $msg
        }
    }

    $vols = & $fetch 'volumes' '/volumes' { Get-SANtricityVolumes }
    $pools = & $fetch 'storage pools' '/storage-pools' { Get-SANtricityStoragePools }
    $hosts = & $fetch 'hosts' '/hosts' { Get-SANtricityHosts }
    $groups = & $fetch 'host groups' '/host-groups' { Get-SANtricityHostGroups }
    $mappings = & $fetch 'volume mappings' '/volume-mappings' { Get-SANtricityVolumeMappings }

    # build lookups mapping multiple id keys to objects
    $volById = [Dictionary[string,object]]::new()
    foreach ($v in $vols) {
        foreach ($k in @('volumeRef','id','mappableObjectId')) {
            if ($v.$k) { $volById[[string]$v.$k] = $v }
        }
    }

    $poolById = [Dictionary[string,object]]::new()
    foreach ($p in $pools) {
        foreach ($k in @('id','volumeGroupRef','volumeGroupId')) { if ($p.$k) { $poolById[[string]$p.$k] = $p } }
    }

    $hostByRef = [Dictionary[string,object]]::new()
    foreach ($h in $hosts) {
        foreach ($k in @('hostRef','id','clusterRef')) { if ($h.$k) { $hostByRef[[string]$h.$k] = $h } }
    }

    $groupByCluster = [Dictionary[string,object]]::new()
    foreach ($g in $groups) {
        foreach ($k in @('clusterRef','id')) { if ($g.$k) { $groupByCluster[[string]$g.$k] = $g } }
    }

    $out = @()
    foreach ($m in $mappings) {
        $row = [ordered]@{}
        foreach ($prop in $m.PSObject.Properties) { $row[$prop.Name] = $prop.Value }

        $vid = $m.volumeRef -or $m.mappableObjectId -or $m.mappableObjectRef
        if ($vid -and $volById.ContainsKey([string]$vid)) {
            $vol = $volById[[string]$vid]
            $row['mappableObjectName'] = $vol.name -or $vol.label
            foreach ($cap in @('capacity','reportedSize','currentVolumeSize')) { if ($vol.$cap) { $row['capacity'] = $vol.$cap ; break } }
            $poolId = $vol.volumeGroupRef -or $vol.poolId -or $vol.storagePoolId
            if ($poolId -and $poolById.ContainsKey([string]$poolId)) {
                $pool = $poolById[[string]$poolId]
                $row['poolName'] = $pool.label -or $pool.name
                if ($pool.freeSpace) { $row['poolFreeSpace'] = $pool.freeSpace }
                if ($pool.raidLevel) { $row['raidLevel'] = $pool.raidLevel }
            }
        }

        $target = $m.targetId -or $m.clusterRef -or $m.hostRef -or $m.hostGroup
        if ($target) {
            if ($hostByRef.ContainsKey([string]$target)) {
                $h = $hostByRef[[string]$target]
                $row['hostLabel'] = $h.label -or $h.name
                $row['hostRef'] = $h.hostRef -or $h.id
                $row['targetLabel'] = $row['hostLabel']
            } elseif ($groupByCluster.ContainsKey([string]$target)) {
                $g = $groupByCluster[[string]$target]
                $row['hostGroup'] = $g.label -or $g.name
                $row['clusterRef'] = $g.clusterRef -or $g.id
                $row['targetLabel'] = $row['hostGroup']
            } else {
                $row['targetLabel'] = [string]$target
            }
        }

        $mapId = $m.mapRef -or $m.mappingRef -or $m.id -or $m.lunMappingRef
        if ($mapId) { $row['mappingRef'] = $mapId }

        $obj = [PSCustomObject] $row
        $out += $obj
    }

    return $out
}

function Show-SANtricityMappingsReportFormatted {
    [CmdletBinding()]
    param()

    $report = Get-SANtricityMappingsReport
    <#
    .SYNOPSIS
    Display a formatted mappings report in the console.

    .DESCRIPTION
    Uses the optional PowerShellRich module to render a rich table when available,
    otherwise falls back to `Format-Table`.

    .EXAMPLE
    Show-SANtricityMappingsReportFormatted
    #>

    if (-not $report -or $report.Count -eq 0) {
        if (Get-Module -Name PowerShellRich -ListAvailable -ErrorAction SilentlyContinue) {
            Write-Rich "No mappings found."
        } else {
            Write-Output "No mappings found."
        }
        return
    }

    $cols = @('mappingRef','mappableObjectName','capacity','poolName','poolFreeSpace','targetLabel')
    $rows = foreach ($r in $report) {
        @(
            ($r.mappingRef -as [string]),
            ($r.mappableObjectName -as [string]),
            ($r.capacity -as [string]),
            ($r.poolName -as [string]),
            ($r.poolFreeSpace -as [string]),
            ($r.targetLabel -as [string])
        )
    }

    if (Get-Module -Name PowerShellRich -ListAvailable -ErrorAction SilentlyContinue) {
        $table = New-RichTable -Columns $cols -Rows $rows -Title 'SANtricity Mappings' -HeaderStyle 'bold cyan' -BorderStyle 'dim white'
        Write-Rich $table
    } else {
        $report | Format-Table -Property $cols -AutoSize
    }
}

Export-ModuleMember -Function Connect-SANtricity,Start-SANtricityTranscript,Stop-SANtricityTranscript,Get-SANtricityVolumes,Get-SANtricityStoragePools,Get-SANtricityHosts,Get-SANtricityHostGroups,Get-SANtricityVolumeMappings,Get-SANtricityMappingsReport,Show-SANtricityMappingsReportFormatted,Map-SANtricityVolume
