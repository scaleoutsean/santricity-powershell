<#
.SYNOPSIS
Deletes a SANtricity volume mapping.

.DESCRIPTION
Removes the mapping (LUN) between a volume and a target (Host or Host Group).
Allows specifying the target by name, with safety checks to ensure the name
uniquely identifies a single Host or Host Group.

.PARAMETER MappingRef
The ID (Ref) of the mapping to remove.

.PARAMETER VolumeName
The name of the volume to unmap.

.PARAMETER TargetName
The name of the Host or Host Group to unmap from.
Checks both Hosts and Host Groups. Fails if name is ambiguous (found in both, or duplicates within one type).

.EXAMPLE
Remove-SANtricityVolumeMapping -MappingRef "123456"

.EXAMPLE
Remove-SANtricityVolumeMapping -VolumeName "DataVol1" -TargetName "ESX-Cluster"
#>
function Remove-SANtricityVolumeMapping {
    [CmdletBinding(DefaultParameterSetName="ById", SupportsShouldProcess=$true)]
    [Alias("Remove-SANtricityHostMapping")]
    param (
        [Parameter(Mandatory=$true, ParameterSetName="ById", Position=0, ValueFromPipeline=$true)]
        [string]$MappingRef,

        [Parameter(Mandatory=$true, ParameterSetName="ByVolumeAndTargetName")]
        [string]$VolumeName,

        [Parameter(Mandatory=$true, ParameterSetName="ByVolumeAndTargetName")]
        [string]$TargetName
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq "ByVolumeAndTargetName") {
            # 1. Resolve Volume
            Write-Verbose "Resolving Volume '$VolumeName'..."
            $vols = Get-SANtricityVolume
            $matchedVol = $vols | Where-Object { $_.name -eq $VolumeName -or $_.label -eq $VolumeName }
            
            if (-not $matchedVol) { throw "Volume '$VolumeName' not found." }
            if ($matchedVol -is [array]) { 
                # Try exact match if multiple partial matches
                $exact = $matchedVol | Where-Object { $_.name -eq $VolumeName }
                if ($exact -and $exact.Count -eq 1) { $matchedVol = $exact }
                else { throw "Multiple volumes matched '$VolumeName'." }
            }
            $volumeId = $matchedVol.id

            # 2. Resolve Target (Safety Check)
            Write-Verbose "Resolving Target '$TargetName' in Hosts and Host Groups..."
            $hosts = Get-SANtricityHost
            $groups = Get-SANtricityHostGroup
            
            $matchedHosts = @($hosts | Where-Object { $_.name -eq $TargetName -or $_.label -eq $TargetName })
            $matchedGroups = @($groups | Where-Object { $_.name -eq $TargetName -or $_.label -eq $TargetName })

            if ($matchedHosts.Count -gt 1) { 
                throw "TargetName '$TargetName' matches multiple Hosts. Please use ID." 
            }
            if ($matchedGroups.Count -gt 1) { 
                throw "TargetName '$TargetName' matches multiple Host Groups. Please use ID." 
            }
            
            if ($matchedHosts.Count -eq 1 -and $matchedGroups.Count -eq 1) {
                # Collision between Host and Group
                throw "TargetName '$TargetName' matches both a Host and a Host Group. Please use ID to be specific."
            }
            
            if ($matchedHosts.Count -eq 0 -and $matchedGroups.Count -eq 0) {
                throw "TargetName '$TargetName' not found in Hosts or Host Groups."
            }

            $targetId = if ($matchedHosts.Count -eq 1) { 
                # Smart Host Cluster Resolution
                $h = $matchedHosts[0]
                $zeroRef = "0" * 40
                # If host is in a cluster, we likely mapped it to the ClusterRef
                if ($h.clusterRef -and $h.clusterRef -ne $zeroRef) {
                    Write-Warning "Host '$($h.label)' is part of a cluster/host-group. Assuming mapping is to the cluster ($($h.clusterRef))."
                    $h.clusterRef
                } else {
                    $h.id
                }
            } else { 
                $matchedGroups[0].id 
            }
            $targetType = if ($matchedHosts.Count -eq 1) { "Host (or Cluster)" } else { "Host Group" }

            Write-Verbose "Resolved Target '$TargetName' to $targetType ($targetId)"

            # 3. Find Mapping
            Write-Verbose "Finding mapping for Volume $volumeId and Target $targetId..."
            $mappings = Get-SANtricityVolumeMapping
            $matchingMapping = $mappings | Where-Object { 
                $_.volumeRef -eq $volumeId -and $_.mapRef -eq $targetId 
            }
            
            if (-not $matchingMapping) { 
                # Try fallback to mappableObjectId/targetId if API returns that format
                $matchingMapping = $mappings | Where-Object { 
                    $_.mappableObjectId -eq $volumeId -and $_.targetId -eq $targetId 
                }
            }
            
            if (-not $matchingMapping) { 
                throw "No active mapping found for Volume '$VolumeName' (ID: $volumeId) and Target '$TargetName' (ID: $targetId)." 
            }
            if ($matchingMapping -is [array]) {
                # Should not happen ideally for one volume-target pair
                throw "Multiple mappings found for this volume and target. This is unexpected."
            }

            $MappingRef = $matchingMapping.id
            Write-Verbose "Found MappingRef: $MappingRef"
        }

        if ($PSCmdlet.ShouldProcess("Mapping $MappingRef", "Remove-SANtricityVolumeMapping")) {
             Invoke-SANtricityRequest -Method DELETE -Path "/volume-mappings/$MappingRef"
        }
    }
}
