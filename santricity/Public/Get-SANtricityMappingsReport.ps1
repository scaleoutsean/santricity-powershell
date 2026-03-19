
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
    param(
        [Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [string]$HostName,

        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string]$Volume
    )

    $fetch = {
        param(
            [string] $description,
            [string] $path,
            [scriptblock] $operation
        )

        try {
            $cmdResult = & $operation
            # Ensure multi-element arrays are correctly unrolled by returning exactly what was produced.
            # If we wrap it in `@()` prematurely while it already is an Array[], it can become a nested array (`Object[]`).
            if ($null -eq $cmdResult) { return @() }
            if ($cmdResult -is [System.Array]) { return $cmdResult }
            return @($cmdResult)
        } catch {
            $msg = "Get-SANtricityMappingsReport failed while retrieving $description ($path). $($_.Exception.Message)"
            throw $msg
        }
    }

    # Pass filters down to sub-commands where supported to reduce data transfer
    $hostParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($HostName)) { $hostParams['Name'] = $HostName }
    $hosts = & $fetch 'hosts' '/hosts' { Get-SANtricityHost @hostParams }
    
    $volParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($Volume)) { $volParams['Name'] = $Volume }
    $vols = & $fetch 'volumes' '/volumes' { Get-SANtricityVolume @volParams }
    $pools = & $fetch 'storage pools' '/storage-pools' { Get-SANtricityStoragePool }
    
    # We fetch all groups because we might match a host inside a group even if filtering by host name
    # If the user passed -Host, they might mean HostName OR HostGroupName. 
    # For now, let's fetch all groups to be safe, or filter if we want to support HostGroup filtering too.
    $groups = & $fetch 'host groups' '/host-groups' { Get-SANtricityHostGroup }
    
    $mappings = & $fetch 'volume mappings' '/volume-mappings' { Get-SANtricityVolumeMapping }

    $registerKey = {
        param(
            [Dictionary[string,object]] $dict,
            [object] $value,
            [object] $payload
        )

        if ($null -eq $value) { return }
        $text = [string]$value
        if ([string]::IsNullOrWhiteSpace($text)) { return }
        
        $cfg = $script:SANtricity_Config
        $key = $text
        if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'IdCase')) {
            switch ($cfg.IdCase) {
                'upper' { $key = $text.ToUpperInvariant() }
                'lower' { $key = $text.ToLowerInvariant() }
            }
        }

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
        
        $cfg = $script:SANtricity_Config
        $key = $text
        if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'IdCase')) {
            switch ($cfg.IdCase) {
                'upper' { $key = $text.ToUpperInvariant() }
                'lower' { $key = $text.ToLowerInvariant() }
            }
        }
        
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
        foreach ($candidate in @($h.hostRef,$h.id)) {
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

        $matchedVol = $null
        foreach ($vid in @($m.volumeRef,$m.mappableObjectId,$m.mappableObjectRef,$m.mappableObject)) {
            $matchedVol = & $resolveLookup $volById $vid
            if ($matchedVol) { break }
        }

        if ($matchedVol) {
            $volName = & $firstPresent @($matchedVol.name,$matchedVol.label,$matchedVol.volumeName,$matchedVol.mappableObjectName,$matchedVol.mappableObjectLabel)
            if ($volName) { $row['mappableObjectName'] = $volName }

            $capacityValue = & $firstPresent @($matchedVol.capacity,$matchedVol.reportedSize,$matchedVol.currentVolumeSize,$matchedVol.totalSizeInBytes)
            if ($capacityValue) { $row['capacity'] = $capacityValue }

            $poolIdCandidate = & $firstPresent @($matchedVol.volumeGroupRef,$matchedVol.poolId,$matchedVol.storagePoolId,$matchedVol.volumeGroupId)
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
                    if (-not $raidValue -and $matchedVol.raidLevel) { $raidValue = $matchedVol.raidLevel }
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

        # Filter: Host/Group Name (Simple Regex)
        if (-not [string]::IsNullOrWhiteSpace($HostName)) {
            $h = if ($row.Contains('hostLabel')) { $row['hostLabel'] } else { $null }
            $g = if ($row.Contains('hostGroup')) { $row['hostGroup'] } else { $null }
            $t = if ($row.Contains('targetLabel')) { $row['targetLabel'] } else { $null }
            
            $match = $false
            if ($h -and $h -match $HostName) { $match = $true }
            if (-not $match -and $g -and $g -match $HostName) { $match = $true }
            if (-not $match -and $t -and $t -match $HostName) { $match = $true }
            
            if (-not $match) { continue }
        }

        # Filter: Volume Name (Simple Regex)
        if (-not [string]::IsNullOrWhiteSpace($Volume)) {
            $v = if ($row.Contains('mappableObjectName')) { $row['mappableObjectName'] } else { $null }
            if (-not ($v -and $v -match $Volume)) { continue }
        }

        $mapId = & $firstPresent @($m.mapRef,$m.mappingRef,$m.lunMappingRef,$m.id)
        if ($mapId) { $row['mappingRef'] = $mapId }

        $out += [PSCustomObject]$row
    }

    return $out
}
