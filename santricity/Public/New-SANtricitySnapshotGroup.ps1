
function New-SANtricitySnapshotGroup {
    <#
    .SYNOPSIS
    Create a new snapshot group for a base volume.

    .DESCRIPTION
    Allocates a new repository volume and creates a snapshot group (Consistency Group)
    for the specified base volume. This is required before taking the first snapshot.

    .PARAMETER BaseVolumeId
    The unique identifier (Ref) of the base volume to protect.

    .PARAMETER VolumeName
    The name of the base volume. Normalized to BaseVolumeId internally.

    .PARAMETER Name
    Name for the new Snapshot Group. Defaults to "SG_<VolumeName>".

    .PARAMETER RepositoryPercentage
    Percentage of base volume capacity to allocate for the repository (default 20).

    .PARAMETER WarningThreshold
    Percentage at which to issue a repository full warning (default 80).

    .PARAMETER AutoDeleteLimit
    Number of snapshots to keep before auto-deleting oldest (default 30).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param(
        [Parameter(ParameterSetName = 'Default', Mandatory = $true)]
        [string]$BaseVolumeId,

        [Parameter(ParameterSetName = 'ByVolumeName', Mandatory = $true)]
        [string]$VolumeName,

        [string]$Name,
        [int]$RepositoryPercentage = 20,
        [int]$WarningThreshold = 80,
        [int]$AutoDeleteLimit = 30
    )

    # 1. Resolve Volume Name to ID if needed
    if ($PSCmdlet.ParameterSetName -eq 'ByVolumeName') {
        $vol = Get-SANtricityVolumes | Where-Object { $_.label -eq $VolumeName }
        if (-not $vol) {
            throw "Volume with name '$VolumeName' not found."
        }
        $BaseVolumeId = $vol.id
    } else {
        # Fetch volume anyway to get the name for default naming
        $vol = Get-SANtricityVolumes | Where-Object { $_.id -eq $BaseVolumeId }
        if (-not $vol) {
             # Fallback if ID lookup fails (rare)
             $VolumeName = "vol_$BaseVolumeId"
        } else {
             $VolumeName = $vol.label
        }
    }

    # 2. Set Default Group Name if not provided
    if (-not $Name) {
        $Name = "SG_$VolumeName"
    }

    # 3. Validation: Check if group already exists
    $existing = Get-SANtricitySnapshotGroup -BaseVolumeId $BaseVolumeId
    if ($existing) {
        throw "A snapshot group already exists for volume '$VolumeName' (Group: $($existing.name))."
    }

    Write-Verbose "Creating Snapshot Group '$Name' for Volume '$VolumeName' ($RepositoryPercentage% Repo)..."

    # 4. Construct Payload (matches HAR capture /repositories/concat/single)
    # The 'newVolCandidate' structure tells it to allocate new space.
    $payload = @{
        baseMappableObjectId = $BaseVolumeId
        name = $Name
        repositoryPercentage = $RepositoryPercentage
        warningThreshold = $WarningThreshold
        autoDeleteLimit = $AutoDeleteLimit
        fullPolicy = "purgepit" # "purge point-in-time" (auto-delete oldest)
        repositoryCandidate = @{
            candType = "newVolCandidate"
            newVolCandidate = @{
                candidateSelectionType = "freeExtent"
                volumeCandidateData = @{
                    diskPoolVolumeCandidateData = @{
                        unusableCapacity = "0"
                        reconstructionReservedAmt = "0"
                        reconstructionReservedDriveCount = 0
                    }
                }
            }
        }
    }

    # IMPORTANT: The HAR trace showed POST /repositories/concat/single for implicit creation,
    # but standard docs often point to POST /snapshot-groups.
    # We will try the standard endpoint first as it's cleaner, but if that fails regarding
    # candidate allocation, we might need to be more specific.
    #
    # However, your notes show a payload for POST /snapshot-groups that includes 'repositoryCandidate'.
    # This implies the standard endpoint handles allocation if you provide the candidate struct.
    
    return Invoke-SANtricityRequest -Method 'POST' -Path '/snapshot-groups' -Body $payload
}
