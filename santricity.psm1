<#
Simple SANtricity PowerShell helpers for PowerShell 7.
#>

using namespace System.Collections.Generic

if (-not (Get-Variable -Name SANtricity_Config -Scope Script -ErrorAction SilentlyContinue)) {
    Set-Variable -Name SANtricity_Config -Scope Script -Value @{}
}

# Try to import bundled PowerShellRich for nicer CLI output when available
$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$richModulePath = Join-Path $scriptDir 'PowerShellRich/PowerShellRich.psd1'
if (Test-Path $richModulePath) {
    Import-Module $richModulePath -Force -ErrorAction SilentlyContinue
}

# Dot-source public helpers (keep core Connect/Invoke in this root file)
$publicPath = Join-Path $scriptDir 'Public/MappingReport.psm1'
if (Test-Path $publicPath) { . $publicPath }

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
    Whether to verify TLS certificates.

    .PARAMETER ApiBasePathPrefix
    API base path prefix (default 'devmgr/v2'). Use full API prefix; system scope will
    be added as '/storage-systems/{id}/' when needed.

    .PARAMETER AuthBasicPath
    Path used for auth basic endpoints (default 'devmgr/utils').

    .PARAMETER StorageSystemId
    Storage system id to use in API paths (default '1').

    .PARAMETER IdCase
    Identifier normalization mode: 'none' (default), 'upper', or 'lower'. When set,
    IDs returned from the array and those provided by the user will be normalized
    using this setting to improve matching.

    .EXAMPLE
    Connect-SANtricity -BaseUrl 'https://10.113.1.158:8443' -Username admin -Password admin -IdCase upper

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
        [string] $ApiBasePathPrefix = 'devmgr/v2',
        [string] $AuthBasicPath = 'devmgr/utils',
        [string] $StorageSystemId = '1',
        [ValidateSet('none','upper','lower')] [string] $IdCase = 'none'
    )

    $headers = @{}
    if ($Auth -eq 'Jwt' -and $Token) {
        $headers['Authorization'] = "Bearer $Token"
    } elseif ($Auth -eq 'Basic' -and $Username -and $Password) {
        $pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$Username`:$Password"))
        $headers['Authorization'] = "Basic $pair"
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

    Set-Variable -Name SANtricity_Config -Scope Script -Value @{ BaseUrls = $baseUrls ; Headers = $headers ; VerifySsl = $VerifySsl ; ApiBasePathPrefix = $ApiBasePathPrefix.Trim('/') ; AuthBasicPath = $AuthBasicPath.Trim('/') ; StorageSystemId = $StorageSystemId ; IdCase = $IdCase }

    Write-Verbose "SANtricity_Config set: BaseUrls=$($baseUrls -join ',') StorageSystemId=$StorageSystemId"
    Write-Host "Connected to SANtricity controller(s): $($baseUrls -join ',') (StorageSystemId: $StorageSystemId)"
    return $true
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
    $cfg = Get-Variable -Name SANtricity_Config -Scope Script -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Value
    if (-not $cfg -or -not $cfg.ContainsKey('IdCase')) { return $Id }
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
    HTTP method (GET, POST, PUT, DELETE).

    .PARAMETER Path
    Relative resource path. If it begins with '/', it is appended to the ApiBasePathPrefix/StorageSystemId
    (e.g. '/volumes' -> /devmgr/v2/storage-systems/{id}/volumes). If it contains 'login' or does not start
    with '/', the AuthBasicPath is used (e.g. 'login' -> /devmgr/utils/login).
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $Method,
        [Parameter(Mandatory = $true)] [string] $Path,
        [bool] $UseSystemScope = $true
    )

    $cfg = Get-Variable -Name SANtricity_Config -Scope Script -ErrorAction Stop | Select-Object -ExpandProperty Value
    if (-not $cfg) { throw 'Not connected. Call Connect-SANtricity first.' }

    $lastException = $null
    $lastAttemptedUrl = $null
    foreach ($base in $cfg.BaseUrls) {
        try {
            if ($Path.StartsWith('http')) {
                $url = $Path
            } elseif ($Path.StartsWith('/')) {
                # decide whether to include storage system id in API path
                if ($UseSystemScope) {
                    $systemId = Get-SANtricitySystemId
                    $url = "${base}/${($cfg.ApiBasePathPrefix)}/storage-systems/${systemId}/${($Path.TrimStart('/'))}"
                } else {
                    $url = "${base}/${($cfg.ApiBasePathPrefix)}/${($Path.TrimStart('/'))}"
                }
            } elseif ($Path -match 'login' -or $Path.StartsWith($cfg.AuthBasicPath)) {
                $p = $Path.TrimStart('/')
                $url = "${base}/${($cfg.AuthBasicPath)}/$p"
            } else {
                # default to API path
                $systemId = Get-SANtricitySystemId
                $url = "${base}/${($cfg.ApiBasePathPrefix)}/storage-systems/${systemId}/${($Path.TrimStart('/'))}"
            }

            $lastAttemptedUrl = $url
            $invokeArgs = @{ Uri = $url ; Method = $Method ; Headers = $cfg.Headers ; ErrorAction = 'Stop' }
            if (-not $cfg.VerifySsl) { $invokeArgs['SkipCertificateCheck'] = $true }
            return Invoke-RestMethod @invokeArgs
        } catch {
            $lastException = $_
            Write-Verbose "Request attempt failed: $lastAttemptedUrl -> $($_.Exception.Message)"
            # try next base URL if available
            continue
        }
    }
    if ($lastException) {
        $baseCount = $cfg.BaseUrls.Count
        $msg = "Request failed after trying $baseCount base URL(s). Last attempted: $lastAttemptedUrl. Error: $($lastException.Exception.Message)"
        throw $msg
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

    $cfg = Get-Variable -Name SANtricity_Config -Scope Script -ErrorAction Stop | Select-Object -ExpandProperty Value
    if (-not $cfg) { throw 'Not connected. Call Connect-SANtricity first.' }
    if ($cfg.StorageSystemId -and $cfg.StorageSystemId -ne '1') {
        return $cfg.StorageSystemId
    }

    # attempt discovery if StorageSystemId is default/placeholder
    $discovered = Discover-SANtricitySystemId
    if ($discovered) {
        # persist discovered id
        $cfg.StorageSystemId = $discovered
        Set-Variable -Name SANtricity_Config -Scope Script -Value $cfg
        return $discovered
    }
    return $cfg.StorageSystemId
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

    $vols = @(Get-SANtricityVolumes)
    $pools = @(Get-SANtricityStoragePools)
    $hosts = @(Get-SANtricityHosts)
    $groups = @(Get-SANtricityHostGroups)
    $mappings = @(Get-SANtricityVolumeMappings)

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

Export-ModuleMember -Function *-SANtricity*,Show-SANtricityMappingsReportFormatted
