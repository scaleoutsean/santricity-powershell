
function New-SANtricityClone {
    <#
    .SYNOPSIS
    Creates a new Snapshot Volume (Clone) from a Snapshot Image.

    .DESCRIPTION
    Creates a viewable volume from a specific point-in-time snapshot image.
    Currently defaults to Read-Only view mode.

    .PARAMETER SnapshotImageId
    The unique identifier (PitRef) of the snapshot image to use as the base.
    You can retrieve this from Get-SANtricitySnapshotImage (not yet implemented) or New-SANtricitySnapshot.

    .PARAMETER Name
    The name (label) for the new snapshot volume.

    .PARAMETER RepositoryPercentage
    Percentage of the base volume capacity to allocate for the clone's repository (tracking changes).
    Default is 20.

    .PARAMETER FullThreshold
    Percentage fullness of the repository at which to issue a warning. Default is 85.

    .PARAMETER AccessMode
    "ReadOnly" (default) or "ReadWrite".
    NOTE: "ReadWrite" maps to "readWrite" viewMode. This may require complex repository allocation 
    which is not fully implemented in this version. ReadOnly is recommended for testing.

    .EXAMPLE
    New-SANtricityClone -SnapshotImageId "3400..." -Name "clone_analysis_1"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SnapshotImageId,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [int]$RepositoryPercentage = 10,
        [int]$FullThreshold = 85,
        
        [ValidateSet("ReadOnly", "ReadWrite")]
        [string]$AccessMode = "ReadOnly"
    )

    # Map AccessMode to viewMode API string
    # Logic: API typically uses camelCase 'readOnly' or 'readWrite'.
    $viewMode = "readOnly"
    if ($AccessMode -eq "ReadWrite") {
        $viewMode = "readWrite"
        Write-Warning "Creating ReadWrite clones may fail if the array requires explicit repositoryCandidate structures. If this fails, use ReadOnly."
    }

    $payload = @{
        snapshotImageId = $SnapshotImageId
        fullThreshold = $FullThreshold
        name = $Name
        viewMode = $viewMode
        repositoryPercentage = $RepositoryPercentage
    }

    Write-Verbose "Creating Snapshot Volume '$Name' (Mode: $viewMode) from Snapshot Image '$SnapshotImageId'..."
    
    return Invoke-SANtricityRequest -Method 'POST' -Path '/snapshot-volumes' -Body $payload
}
