
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

    $registerKey = {
        param(
            [Dictionary[string,object]] $dict,
            [object] $value,
            [object] $payload
        )

        if ($null -eq $value) { return }
        $text = [string]$value
        if ([string]::IsNullOrWhiteSpace($text)) { return }
        $key = Normalize-SANtricityId -Id $text
        if (-not $key) { $key = $text }
        $dict[$key] = $payload
    }

    $resolveLookup = {
        param(
            [Dictionary[string,object]] $dict,
            [object] $value
        )

        if (-not $dict -or $dict.Count -eq 0 -or $null -eq $value) { return $null }
        $text = [string]$value
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $key = Normalize-SANtricityId -Id $text
        if (-not $key) { $key = $text }
        if ($dict.ContainsKey($key)) { return $dict[$key] }
        return $null
    }

    $firstPresent = {
        param([object[]] $values)
        foreach ($value in $values) {
            if ($null -eq $value) { continue }
            if ($value -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
                continue
            }
            return $value
        }
        return $null
    }

    # build lookups mapping multiple id keys to objects (ids normalized via Normalize-SANtricityId)
    $volById = [Dictionary[string,object]]::new()
    foreach ($v in $vols) {
        foreach ($candidate in @($v.volumeRef,$v.id,$v.mappableObjectId,$v.mappableObjectRef,$v.mappableObject)) {
            & $registerKey $volById $candidate $v
        }
    }

    $poolById = [Dictionary[string,object]]::new()
    foreach ($p in $pools) {
        foreach ($candidate in @($p.id,$p.volumeGroupRef,$p.volumeGroupId,$p.storagePoolId,$p.poolId)) {
            & $registerKey $poolById $candidate $p
        }
    }

    $hostByRef = [Dictionary[string,object]]::new()
    foreach ($h in $hosts) {
        foreach ($candidate in @($h.hostRef,$h.id,$h.clusterRef)) {
            & $registerKey $hostByRef $candidate $h
        }
    }

    $groupByCluster = [Dictionary[string,object]]::new()
    foreach ($g in $groups) {
        foreach ($candidate in @($g.clusterRef,$g.id)) {
            & $registerKey $groupByCluster $candidate $g
        }
    }

    $out = @()
    foreach ($m in $mappings) {
        $row = [ordered]@{}
        foreach ($prop in $m.PSObject.Properties) { $row[$prop.Name] = $prop.Value }

        $volume = $null
        foreach ($vid in @($m.volumeRef,$m.mappableObjectId,$m.mappableObjectRef,$m.mappableObject)) {
            $volume = & $resolveLookup $volById $vid
            if ($volume) { break }
        }

        if ($volume) {
            $volName = & $firstPresent @($volume.name,$volume.label,$volume.volumeName,$volume.mappableObjectName,$volume.mappableObjectLabel)
            if ($volName) { $row['mappableObjectName'] = $volName }

            $capacityValue = & $firstPresent @($volume.capacity,$volume.reportedSize,$volume.currentVolumeSize,$volume.totalSizeInBytes)
            if ($capacityValue) { $row['capacity'] = $capacityValue }

            $poolIdCandidate = & $firstPresent @($volume.volumeGroupRef,$volume.poolId,$volume.storagePoolId,$volume.volumeGroupId)
            if ($poolIdCandidate) {
                $pool = & $resolveLookup $poolById $poolIdCandidate
                if ($pool) {
                    $poolName = & $firstPresent @($pool.label,$pool.name,$pool.volumeGroupLabel,$pool.volumeGroupName)
                    if ($poolName) { $row['poolName'] = $poolName }

                    $poolFree = & $firstPresent @($pool.freeSpace,$pool.freeSpaceInBytes,$pool.freeCapacity,$pool.availableSpace)
                    if ($poolFree) { $row['poolFreeSpace'] = $poolFree }

                    $raidValue = & $firstPresent @($pool.raidLevel)
                    if (-not $raidValue -and $pool.extents) {
                        $firstExtent = $null
                        if (($pool.extents -is [System.Collections.IEnumerable]) -and -not ($pool.extents -is [string])) {
                            foreach ($ext in $pool.extents) { $firstExtent = $ext ; break }
                        }
                        if ($firstExtent -and $firstExtent.raidLevel) { $raidValue = $firstExtent.raidLevel }
                    }
                    if (-not $raidValue -and $volume.raidLevel) { $raidValue = $volume.raidLevel }
                    if ($raidValue) { $row['raidLevel'] = $raidValue }
                }
            }
        }

        $hostMatch = $null
        $groupMatch = $null
        foreach ($candidate in @($m.targetId,$m.clusterRef,$m.hostRef,$m.hostGroup,$m.mapRef,$m.lunMappingRef)) {
            if (-not $hostMatch) { $hostMatch = & $resolveLookup $hostByRef $candidate }
            if ($hostMatch) { break }
            if (-not $groupMatch) { $groupMatch = & $resolveLookup $groupByCluster $candidate }
            if ($groupMatch) { break }
        }

        $targetLabel = $null
        if ($hostMatch) {
            $hostLabel = & $firstPresent @($hostMatch.label,$hostMatch.name,$hostMatch.hostLabel,$hostMatch.hostName)
            if ($hostLabel) {
                $row['hostLabel'] = $hostLabel
                $targetLabel = $hostLabel
            }
            $hostRefValue = & $firstPresent @($hostMatch.hostRef,$hostMatch.id,$hostMatch.clusterRef)
            if ($hostRefValue) { $row['hostRef'] = $hostRefValue }
        } elseif ($groupMatch) {
            $groupLabel = & $firstPresent @($groupMatch.label,$groupMatch.name,$groupMatch.hostGroupLabel,$groupMatch.clusterName)
            if ($groupLabel) {
                $row['hostGroup'] = $groupLabel
                $targetLabel = $groupLabel
            }
            $clusterRefValue = & $firstPresent @($groupMatch.clusterRef,$groupMatch.id)
            if ($clusterRefValue) { $row['clusterRef'] = $clusterRefValue }
        }

        if (-not $targetLabel) {
            foreach ($fallback in @($m.targetLabel,$m.targetName,$m.hostGroup,$m.hostLabel,$m.clusterName,$m.targetId,$m.hostRef,$m.clusterRef,$m.mapRef,$m.lunMappingRef)) {
                if ($null -ne $fallback -and -not [string]::IsNullOrWhiteSpace([string]$fallback)) {
                    $targetLabel = [string]$fallback
                    break
                }
            }
        }
        if ($targetLabel) { $row['targetLabel'] = $targetLabel }

        $mapId = & $firstPresent @($m.mapRef,$m.mappingRef,$m.lunMappingRef,$m.id)
        if ($mapId) { $row['mappingRef'] = $mapId }

        $out += [PSCustomObject]$row
    }

    return $out
}
