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

function Connect-SANtricity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $BaseUrl,
        [string] $Username,
        [string] $Password,
        [string] $Token,
        [ValidateSet('Basic','Jwt')] [string] $Auth = 'Basic',
        [bool] $VerifySsl = $true
    )

    $headers = @{}
    if ($Auth -eq 'Jwt' -and $Token) {
        $headers['Authorization'] = "Bearer $Token"
    } elseif ($Auth -eq 'Basic' -and $Username -and $Password) {
        $pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$Username`:$Password"))
        $headers['Authorization'] = "Basic $pair"
    }

    Set-Variable -Name SANtricity_Config -Scope Script -Value @{ BaseUrl = $BaseUrl.TrimEnd('/') ; Headers = $headers ; VerifySsl = $VerifySsl }
    return $true
}

function Invoke-SANtricityRequest {
    param(
        [Parameter(Mandatory = $true)] [string] $Method,
        [Parameter(Mandatory = $true)] [string] $Path
    )

    $cfg = Get-Variable -Name SANtricity_Config -Scope Script -ErrorAction Stop | Select-Object -ExpandProperty Value
    if (-not $cfg) { throw 'Not connected. Call Connect-SANtricity first.' }
    $url = if ($Path.StartsWith('http')) { $Path } else { "$($cfg.BaseUrl)/$($Path.TrimStart('/'))" }

    $invokeArgs = @{ Uri = $url ; Method = $Method ; Headers = $cfg.Headers ; ErrorAction = 'Stop' }
    if (-not $cfg.VerifySsl) { $invokeArgs['SkipCertificateCheck'] = $true }

    try {
        return Invoke-RestMethod @invokeArgs
    } catch {
        throw "Request failed: $($_.Exception.Message)"
    }
}

function Get-SANtricityVolumes {
    return Invoke-SANtricityRequest -Method 'GET' -Path '/volumes'
}

function Get-SANtricityStoragePools {
    return Invoke-SANtricityRequest -Method 'GET' -Path '/storage-pools'
}

function Get-SANtricityHosts {
    return Invoke-SANtricityRequest -Method 'GET' -Path '/hosts'
}

function Get-SANtricityHostGroups {
    return Invoke-SANtricityRequest -Method 'GET' -Path '/host-groups'
}

function Get-SANtricityVolumeMappings {
    return Invoke-SANtricityRequest -Method 'GET' -Path '/volume-mappings'
}

function Get-SANtricityMappingsReport {
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
