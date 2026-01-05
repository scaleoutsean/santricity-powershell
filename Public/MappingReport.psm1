<#
Module containing report and helper functions for SANtricity mappings.
#>

function Get-SANtricityVolumes {
    <#
    .SYNOPSIS
    Get volumes from the configured storage system.
    #>
    param()

    return Invoke-SANtricityRequest -Method 'GET' -Path '/volumes'
}

function Get-SANtricityStoragePools {
    <#
    .SYNOPSIS
    Get storage pools from the configured storage system.
    #>
    param()

    return Invoke-SANtricityRequest -Method 'GET' -Path '/storage-pools'
}

function Get-SANtricityHosts {
    <#
    .SYNOPSIS
    Get hosts from the configured storage system.
    #>
    param()

    return Invoke-SANtricityRequest -Method 'GET' -Path '/hosts'
}

function Get-SANtricityHostGroups {
    <#
    .SYNOPSIS
    Get host groups from the configured storage system.
    #>
    param()

    return Invoke-SANtricityRequest -Method 'GET' -Path '/host-groups'
}

function Get-SANtricityVolumeMappings {
    <#
    .SYNOPSIS
    Get volume mappings from the configured storage system.
    #>
    param()

    return Invoke-SANtricityRequest -Method 'GET' -Path '/volume-mappings'
}

function Get-SANtricityMappingsReport {
    <#
    .SYNOPSIS
    Build a consolidated mappings report from SANtricity API data.
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
            if ($v.$k) { $key = Normalize-SANtricityId -Id ([string]$v.$k) ; $volById[$key] = $v }
        }
    }

    $poolById = [Dictionary[string,object]]::new()
    foreach ($p in $pools) {
        foreach ($k in @('id','volumeGroupRef','volumeGroupId')) { if ($p.$k) { $key = Normalize-SANtricityId -Id ([string]$p.$k) ; $poolById[$key] = $p } }
    }

    $hostByRef = [Dictionary[string,object]]::new()
    foreach ($h in $hosts) {
        foreach ($k in @('hostRef','id','clusterRef')) { if ($h.$k) { $key = Normalize-SANtricityId -Id ([string]$h.$k) ; $hostByRef[$key] = $h } }
    }

    $groupByCluster = [Dictionary[string,object]]::new()
    foreach ($g in $groups) {
        foreach ($k in @('clusterRef','id')) { if ($g.$k) { $key = Normalize-SANtricityId -Id ([string]$g.$k) ; $groupByCluster[$key] = $g } }
    }

    $out = @()
    foreach ($m in $mappings) {
        $row = [ordered]@{}
        foreach ($prop in $m.PSObject.Properties) { $row[$prop.Name] = $prop.Value }

        $vid = $m.volumeRef -or $m.mappableObjectId -or $m.mappableObjectRef
        $normVid = if ($vid) { Normalize-SANtricityId -Id ([string]$vid) } else { $null }
        if ($normVid -and $volById.ContainsKey([string]$normVid)) {
            $vol = $volById[[string]$normVid]
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
        $normTarget = if ($target) { Normalize-SANtricityId -Id ([string]$target) } else { $null }
        if ($target) {
            if ($normTarget -and $hostByRef.ContainsKey([string]$normTarget)) {
                $h = $hostByRef[[string]$normTarget]
                $row['hostLabel'] = $h.label -or $h.name
                $row['hostRef'] = $h.hostRef -or $h.id
                $row['targetLabel'] = $row['hostLabel']
            } elseif ($normTarget -and $groupByCluster.ContainsKey([string]$normTarget)) {
                $g = $groupByCluster[[string]$target]
                $row['hostGroup'] = $g.label -or $g.name
                $row['clusterRef'] = $g.clusterRef -or $g.id
                $row['targetLabel'] = $row['hostGroup']
            } else {
                $row['targetLabel'] = [string]$target
            }
        }

        $mapId = $m.mapRef -or $m.mappingRef -or $m.id -or $m.lunMappingRef
        if ($mapId) { $row['mappingRef'] = Normalize-SANtricityId -Id ([string]$mapId) }

        $obj = [PSCustomObject] $row
        $out += $obj
    }

    return $out
}

function Show-SANtricityMappingsReportFormatted {
    <#
    .SYNOPSIS
    Format and display the mappings report using PowerShellRich when available.
    #>
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

function Map-SANtricityVolume {
    <#
    .SYNOPSIS
    Create a volume mapping (map a volume to a host or host-group).

    .DESCRIPTION
    Sends a POST to /volume-mappings to create a mapping. User-supplied IDs are
    normalized according to the connection `IdCase` setting (see `Connect-SANtricity`).

    .PARAMETER MappableObjectId
    The volume identifier (volumeRef / mappableObjectId).

    .PARAMETER TargetId
    The target identifier (hostRef or hostGroup id).

    .PARAMETER Lun
    Optional LUN value.

    .PARAMETER Perms
    Optional permissions mask.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string] $MappableObjectId,
        [Parameter(Mandatory=$true)][string] $TargetId,
        [int] $Lun,
        [int] $Perms
    )

    $mid = Normalize-SANtricityId -Id $MappableObjectId
    $tid = Normalize-SANtricityId -Id $TargetId

    $payload = @{ mappableObjectId = $mid ; targetId = $tid }
    if ($PSBoundParameters.ContainsKey('Lun')) { $payload['lun'] = $Lun }
    if ($PSBoundParameters.ContainsKey('Perms')) { $payload['perms'] = $Perms }

    return Invoke-SANtricityRequest -Method 'POST' -Path '/volume-mappings' -Body ($payload | ConvertTo-Json -Depth 10)
}

Export-ModuleMember -Function Get-SANtricityVolumes,Get-SANtricityStoragePools,Get-SANtricityHosts,Get-SANtricityHostGroups,Get-SANtricityVolumeMappings,Get-SANtricityMappingsReport,Show-SANtricityMappingsReportFormatted,Map-SANtricityVolume
