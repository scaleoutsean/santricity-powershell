function Get-SANtricityConsistencyGroupCloneVolume {
    <#
    .SYNOPSIS
    Retrieve the underlying SnapshotVolumes (Clones) associated with a Consistency Group.

    .DESCRIPTION
    Returns the individual SnapshotVolumes (clones) that make up a Consistency Group.
    This is often required to determine if the view volumes are mapped as ReadOnly or ReadWrite.

    .PARAMETER ConsistencyGroupId
    The ID (Ref) of the consistency group.

    .PARAMETER ViewId
    The ID (Ref) of the consistency group view.

    .PARAMETER Newest
    If specified, returns only the single most recently created volume (lowest/highest sequence via Handle).

    .PARAMETER Oldest
    If specified, returns only the single oldest created volume.
    #>
    [CmdletBinding()]
    [Alias("Get-SANtricityConsistencyGroupViewVolume")]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConsistencyGroupId,

        [Parameter(Mandatory = $true)]
        [string]$ViewId,

        [switch]$Newest,
        [switch]$Oldest
    )

    $vols = Invoke-SANtricityRequest -Method 'GET' -Path "/consistency-groups/$ConsistencyGroupId/views/$ViewId/views"
    
    if (-not $vols) { return $null }

    if ($Newest -or $Oldest) {
        $sorted = $vols | Sort-Object -Property volumeHandle
        if ($Oldest) { return $sorted | Select-Object -First 1 }
        if ($Newest) { return $sorted | Select-Object -Last 1 }
    }

    return $vols
}
