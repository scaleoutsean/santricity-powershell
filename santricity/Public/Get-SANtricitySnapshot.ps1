
function Get-SANtricitySnapshot {
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

    .PARAMETER Newest
    If specified, returns only the single most recent snapshot (based on pitTimestamp/pitSequenceNumber).

    .PARAMETER Oldest
    If specified, returns only the single oldest snapshot.

    .EXAMPLE
    Get-SANtricitySnapshot
    List all snapshot images.

    .EXAMPLE
    Get-SANtricitySnapshot -GroupId "3300..." -Newest
    Get the most recent snapshot for a specific group.
    #>
    [CmdletBinding()]
    param(
        [string]$Id,
        [string]$GroupId,
        [string]$BaseVolumeId,
        [switch]$Newest,
        [switch]$Oldest
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

    # Sorting Logic
    if ($Newest -or $Oldest) {
        # Sort by Sequence Number (reliable integer) or Timestamp
        $sorted = $images | Sort-Object -Property pitSequenceNumber

        if ($Oldest) {
            return $sorted | Select-Object -First 1
        }
        if ($Newest) {
            return $sorted | Select-Object -Last 1
        }
    }

    return $images
}
