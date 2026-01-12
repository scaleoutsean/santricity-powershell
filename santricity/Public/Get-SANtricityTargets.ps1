<#
.SYNOPSIS
Retrieves SANtricity Target information (IQN/NQN, Portals) and mapped volumes.

.DESCRIPTION
Returns connection information for the storage array (Target Name, Portals) and
a list of volumes mapped to a specific Host or Host Group.
Useful for configuring host-side initiators (iSCSI/NVMe) and verifying LUN visibility.

.PARAMETER HostName
Filter by Host Name. Returns targets and volumes visible to this host (including Host Group mappings).

.PARAMETER HostGroupName
Filter by Host Group Name. Returns targets and volumes visible to this group.

.PARAMETER Protocol
Filter details by protocol ('iscsi', 'nvme', 'all'). Default is 'all'.

.EXAMPLE
Get-SANtricityTargets -HostName "ESX-01" -Protocol iscsi
#>
function Get-SANtricityTargets {
    [CmdletBinding(DefaultParameterSetName="All")]
    param(
        [Parameter(ParameterSetName="ByHost")]
        [string] $HostName,

        [Parameter(ParameterSetName="ByHostGroup")]
        [Alias("ClusterNAME")]
        [string] $HostGroupName,

        [Parameter()]
        [ValidateSet('iscsi', 'nvme', 'all')]
        [string] $Protocol = 'all'
    )

    process {
        # --- 1. Gather Context (Target Info) ---
        $results = @()
        
        # Get System Info for WWN-based name construction fallback
        $sysInfo = Invoke-SANtricityRequest -Method GET -Path "/storage-systems/1" 
        $baseWwn = $sysInfo.wwn.ToLower()

        # --- iSCSI Target Info ---
        if ($Protocol -in @('all', 'iscsi')) {
            try {
                $iscsiSettings = Invoke-SANtricityRequest -Method GET -Path "/iscsi/target-settings" -ErrorAction SilentlyContinue
                if ($iscsiSettings) {
                    $tgtName = if ($iscsiSettings.nodeName.iscsiNodeName) { 
                        $iscsiSettings.nodeName.iscsiNodeName 
                    } else { 
                        # Fallback construction
                        "iqn.1992-08.com.netapp:5700.$baseWwn"
                    }
                    
                    $portals = if ($iscsiSettings.portals) { 
                        $iscsiSettings.portals.ipAddress.ipv4Address 
                    } else { @() }

                    $results += [PSCustomObject]@{
                        Protocol = 'iscsi'
                        TargetName = $tgtName
                        Portals = $portals
                        MappedVolumes = @() # To be filled
                    }
                }
            } catch {
                Write-Verbose "iSCSI target settings not available or failed."
            }
        }

        # --- NVMe Target Info ---
        if ($Protocol -in @('all', 'nvme')) {
            # Attempt to fetch NVMe/RoCE settings
            # Note: Endpoint path varies by firmware. Trying common paths or construction.
            try {
                 # NVMe NQN construction is often reliable for E-Series if API is elusive.
                 $nqn = "nqn.1992-08.com.netapp:5700.$baseWwn"
                 
                 # Portals: query interfaces for 'ib', 'nvmeOf', or 'roce' types
                 # 'GET /interfaces' is heavy but contains IP data.
                 # Optimization: Only fetch if needed.
                 $interfaces = Invoke-SANtricityRequest -Method GET -Path "/interfaces" -ErrorAction SilentlyContinue
                 # Filter for RoCE/InfiniBand (NVMe-oF capable) with IPs
                 $nvmeInterfaces = $interfaces | Where-Object { 
                    ($_.ioInterfaceTypeData.interfaceType -in @('ib', 'nvmeOf', 'roce')) -and 
                    $_.ioInterfaceTypeData.ib.ipv4Data.ipv4Address 
                 }
                 $nvmePortals = $nvmeInterfaces | ForEach-Object { $_.ioInterfaceTypeData.ib.ipv4Data.ipv4Address }

                 if ($nqn) {
                     $results += [PSCustomObject]@{
                        Protocol = 'nvme'
                        TargetName = $nqn
                        Portals = $nvmePortals
                        MappedVolumes = @()
                     }
                 }
            } catch {
                Write-Verbose "NVMe detection failed."
            }
        }

        # --- 2. Resolve Mappings (LUNs) ---
        # If no host/group specified, we return the target info with empty volume lists (or default view).
        # If Host/Group specified, we calculate visible LUNs.

        $targetIds = @() # Collection of {ref, type} to filter mappings
        
        if ($HostName) {
            Write-Verbose "Resolving Host '$HostName'..."
            $hosts = Get-SANtricityHosts
            $h = $hosts | Where-Object { $_.name -eq $HostName -or $_.label -eq $HostName }
            if (-not $h) { throw "Host '$HostName' not found." }
            if ($h -is [array]) { $h = $h[0] } # Take first if dupes (handled by creation logic usually)
            
            $targetIds += @{ Id = $h.id; Type = 'host' }
            if ($h.clusterRef -and $h.clusterRef -ne "0000000000000000000000000000000000000000") {
                $targetIds += @{ Id = $h.clusterRef; Type = 'cluster' }
                Write-Verbose "Host is in Cluster '$($h.clusterRef)', including cluster mappings."
            }
        }
        elseif ($HostGroupName) {
            Write-Verbose "Resolving Host Group '$HostGroupName'..."
            $groups = Get-SANtricityHostGroups
            $g = $groups | Where-Object { $_.name -eq $HostGroupName -or $_.label -eq $HostGroupName }
            if (-not $g) { throw "Host Group '$HostGroupName' not found." }
            
            $targetIds += @{ Id = $g.id; Type = 'cluster' }
        }

        # Only fetch volume data if we have targets to filter by
        if ($targetIds.Count -gt 0) {
            Write-Verbose "Fetching Mappings and Volumes..."
            $validRefs = $targetIds.Id
            
            # Get All Mappings
            $mappings = Get-SANtricityVolumeMappings
            # Filter relevant mappings
            # API uses mapRef for the target (Host/Cluster) ID
            $myMappings = $mappings | Where-Object { $validRefs -contains $_.mapRef }
            
            if ($myMappings) {
                # Get All Volumes (Optimization: Fetch only needed if possible, but GET /volumes is standard)
                $volumes = Get-SANtricityVolumes
                
                $mappedVols = @()
                foreach ($map in $myMappings) {
                    $vol = $volumes | Where-Object { $_.id -eq $map.volumeRef }
                    if ($vol) {
                        $mappedVols += [ordered]@{
                            Name = $vol.name
                            LUN  = $map.lun
                            WWN  = $vol.worldWideName
                            Size = $vol.capacity
                            MapType = if ($map.mapRef -eq $targetIds[0].Id) { "Direct" } else { "Inherited" }
                        }
                    }
                }
                
                # Attach to results
                foreach ($res in $results) {
                    $res.MappedVolumes = $mappedVols
                }
            }
        }

        return $results
    }
}
