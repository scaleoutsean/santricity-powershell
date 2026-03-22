function Get-SANtricitySnapshotVolume {
    <#
    .SYNOPSIS
    Retrieve all standalone Snapshot Volumes (Linked Clones).

    .DESCRIPTION
    Returns all snapshot volumes (also known as clones or views).
    These are the host-mappable, logical volumes backed by a Snapshot Image.

    .PARAMETER Newest
    If specified, returns only the single most recently created volume (based on pitSequenceNumber mapping to image).

    .PARAMETER Oldest
    If specified, returns only the single oldest created volume.
    #>
    [CmdletBinding()]
    param(
        [switch]$Newest,
        [switch]$Oldest
    )

    $vols = Invoke-SANtricityRequest -Method 'GET' -Path '/snapshot-volumes'
    
    if (-not $vols) { return $null }

    if ($Newest -or $Oldest) {
        # The Snapshot Volume metadata has sequence numbers mapped to its base image
        $sorted = $vols | Sort-Object -Property volumeHandle
        
        if ($Oldest) { return $sorted | Select-Object -First 1 }
        if ($Newest) { return $sorted | Select-Object -Last 1 }
    }

    return $vols
}
