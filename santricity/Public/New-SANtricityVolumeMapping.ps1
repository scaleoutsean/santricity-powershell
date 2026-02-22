<#
.SYNOPSIS
Maps a volume to a host or host group.

.DESCRIPTION
Creates a mapping (LUN) between a volume and a target (Host or Host Group).

.PARAMETER VolumeId
The ID of the volume to map.

.PARAMETER VolumeName
The name of the volume to map.

.PARAMETER TargetId
The ID (Ref) of the Host or Host Group.

.PARAMETER HostName
The name of the Host to map to.

.PARAMETER HostGroupName
The name of the Host Group to map to.

.PARAMETER Lun
Optional LUN number. If invalid or not specified, the array assigns one automatically.

.EXAMPLE
New-SANtricityVolumeMapping -VolumeName "Vol1" -HostName "ESX01"
#>
function New-SANtricityVolumeMapping {
    [CmdletBinding(DefaultParameterSetName="ById")]
    [Alias("New-SANtricityHostMapping")]
    param (
        # Volume Identification
        [Parameter(Mandatory=$true, ParameterSetName="ById")]
        [Parameter(Mandatory=$true, ParameterSetName="TargetName")]
        [string]$VolumeId,

        [Parameter(Mandatory=$true, ParameterSetName="ByName")]
        [Parameter(Mandatory=$true, ParameterSetName="ByNameAndTargetName")]
        [string]$VolumeName,

        # Target Identification
        [Parameter(Mandatory=$true, ParameterSetName="ById")]
        [Parameter(Mandatory=$true, ParameterSetName="ByName")]
        [string]$TargetId, 
        
        [Parameter(Mandatory=$true, ParameterSetName="TargetName")]
        [Parameter(Mandatory=$true, ParameterSetName="ByNameAndTargetName")]
        [string]$HostName,

        [Parameter(Mandatory=$true, ParameterSetName="TargetGroupName")]
        [Parameter(Mandatory=$true, ParameterSetName="ByNameAndTargetGroupName")]
        [string]$HostGroupName,

        [Parameter(Mandatory=$false)]
        [int]$Lun
    )

    process {
        # 1. Resolve Volume
        if ($PSCmdlet.ParameterSetName -like "*ByName*") {
            Write-Verbose "Resolving Volume Name '$VolumeName'..."
            $vols = Get-SANtricityVolume
            $matched = $vols | Where-Object { $_.name -eq $VolumeName -or $_.label -eq $VolumeName }
            if (-not $matched) { throw "Volume '$VolumeName' not found." }
            if ($matched -is [array]) {
                 $exact = $matched | Where-Object { $_.name -eq $VolumeName }
                 if ($exact -and $exact.Count -eq 1) { $matched = $exact }
                 else { throw "Multiple volumes matched '$VolumeName'." }
            }
            $VolumeId = $matched.id
        }

        # Pre-check: Verify if volume is already mapped
        # This avoids a 422 error from the array.
        Write-Verbose "Checking for existing mappings for volume '$VolumeId'..."
        $allMappings = Get-SANtricityVolumeMapping
        $existing = $allMappings | Where-Object { $_.volumeRef -eq $VolumeId }
        if ($existing) {
            $msg = "Volume is already mapped to target '$($existing.mapRef)' (LUN $($existing.lun))."
            # We could return the existing mapping, but since this is New-, throwing or warning is appropriate.
            # User feedback suggests preventing the 422 is the goal.
            throw $msg
        }

        # 2. Resolve Target (if Name provided)
        # Note: We support HostName OR HostGroupName parameters to look up distinctly
        if ($PSBoundParameters.ContainsKey('HostName')) {
             Write-Verbose "Resolving Host Name '$HostName'..."
             $hosts = Get-SANtricityHost
             $matchedH = $hosts | Where-Object { $_.name -eq $HostName -or $_.label -eq $HostName }
             if (-not $matchedH) { throw "Host '$HostName' not found." }
             if ($matchedH -is [array]) { throw "Multiple hosts matched '$HostName'." }
             
             # Check for Cluster Association
             $zeroRef = "0" * 40
             if ($matchedH.clusterRef -and $matchedH.clusterRef -ne $zeroRef) {
                 Write-Warning "Host '$HostName' is part of a cluster/host-group ($($matchedH.clusterRef)). Mapping to the cluster instead."
                 $TargetId = $matchedH.clusterRef
             } else {
                 $TargetId = $matchedH.id
             }
        } elseif ($PSBoundParameters.ContainsKey('HostGroupName')) {
             Write-Verbose "Resolving Host Group Name '$HostGroupName'..."
             $groups = Get-SANtricityHostGroup
             $matchedG = $groups | Where-Object { $_.name -eq $HostGroupName -or $_.label -eq $HostGroupName }
             if (-not $matchedG) { throw "Host Group '$HostGroupName' not found." }
             if ($matchedG -is [array]) { throw "Multiple host groups matched '$HostGroupName'." }
             $TargetId = $matchedG.id
        }

        # 2. Build Request Body
        $body = @{
            mappableObjectId = $VolumeId
            targetId = $TargetId
        }
        
        if ($PSBoundParameters.ContainsKey('Lun')) {
            $body.lun = $Lun
        }

        Write-Verbose "Mapping Volume $VolumeId to Target $TargetId..."
        
        return Invoke-SANtricityRequest -Method 'POST' -Path "/volume-mappings" -Body $body
    }
}
