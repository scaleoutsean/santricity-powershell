
function Get-SANtricitySnapshotGroup {
    <#
    .SYNOPSIS
    Retrieve snapshot groups from the SANtricity API.

    .DESCRIPTION
    Returns a list of all snapshot groups. Supports filtering by name, ID, or base volume.

    .PARAMETER Id
    The unique identifier (Ref) of the snapshot group to retrieve.

    .PARAMETER Name
    Filter by the user-assigned label of the snapshot group.

    .PARAMETER BaseVolumeId
    Filter by the unique identifier (Ref) of the base volume.

    .PARAMETER VolumeName
    Filter by the name of the base volume. Resolves to BaseVolumeId internally.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param(
        [Parameter(ParameterSetName = 'Default')]
        [string]$Id,

        [Parameter(ParameterSetName = 'Default')]
        [string]$Name,

        [Parameter(ParameterSetName = 'Default')]
        [string]$BaseVolumeId,

        [Parameter(ParameterSetName = 'ByVolumeName')]
        [string]$VolumeName
    )

    if ($Id) {
        return Invoke-SANtricityRequest -Method 'GET' -Path "/snapshot-groups/$Id"
    }

    $allGroups = Invoke-SANtricityRequest -Method 'GET' -Path '/snapshot-groups'
    
    if (-not $allGroups) { return $null }

    if ($Name) {
        $allGroups = $allGroups | Where-Object { $_.name -eq $Name }
    }

    if ($VolumeName) {
        $vol = Get-SANtricityVolume | Where-Object { $_.label -eq $VolumeName }
        if (-not $vol) {
            Write-Error "Volume with name '$VolumeName' not found."
            return $null
        }
        $BaseVolumeId = $vol.id
    }

    if ($BaseVolumeId) {
        $allGroups = $allGroups | Where-Object { $_.baseVolume -eq $BaseVolumeId }
    }

    return $allGroups
}
