
function Get-SANtricitySnapshotImage {
    <#
    .SYNOPSIS
    Retrieves snapshot images (point-in-time copies) from the array.

    .DESCRIPTION
    Returns a list of snapshot images. Can be filtered by specific ID, owning Snapshot Group, or Base Volume.

    .PARAMETER Id
    Optional. The unique identifier (PitRef) of the snapshot image.

    .PARAMETER GroupId
    Optional. Filter by the Snapshot Group ID (PitGroupRef).

    .PARAMETER BaseVolumeId
    Optional. Filter by the Base Volume ID.

    .EXAMPLE
    Get-SANtricitySnapshotImage
    List all snapshot images.

    .EXAMPLE
    Get-SANtricitySnapshotImage -GroupId "3300..."
    List images belonging to a specific group.
    #>
    [CmdletBinding()]
    param(
        [string]$Id,
        [string]$GroupId,
        [string]$BaseVolumeId
    )

    if ($Id) {
        return Invoke-SANtricityRequest -Method 'GET' -Path "/snapshot-images/$Id"
    }

    $images = Invoke-SANtricityRequest -Method 'GET' -Path '/snapshot-images'

    if (-not $images) { return $null }

    if ($GroupId) {
        $images = $images | Where-Object { $_.pitGroupRef -eq $GroupId }
    }

    if ($BaseVolumeId) {
        $images = $images | Where-Object { $_.baseVol -eq $BaseVolumeId }
    }

    return $images
}
