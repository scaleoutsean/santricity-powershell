
function New-SANtricitySnapshotGroup {
    <#
    .SYNOPSIS
    Create a new snapshot group for a base volume.

    .DESCRIPTION
    Allocates a new repository volume and creates a snapshot group (for a single base volume).
    This is required before taking the first snapshot of that volume.
    
    Note: For multi-volume consistency, use New-SANtricityConsistencyGroup (creating a group for multiple volumes).

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
        $vol = Get-SANtricityVolume | Where-Object { $_.label -eq $VolumeName }
        if (-not $vol) {
            throw "Volume with name '$VolumeName' not found."
        }
        $BaseVolumeId = $vol.id
    } else {
        # Fetch volume anyway to get the name for default naming
        $vol = Get-SANtricityVolume | Where-Object { $_.id -eq $BaseVolumeId }
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

    # 4. Construct Payload
    # We use the minimal payload structure which relies on the array to automatically
    # select the repository location (usually same pool/group as base volume).
    $payload = @{
        baseMappableObjectId = $BaseVolumeId
        name = $Name
        repositoryPercentage = $RepositoryPercentage
        warningThreshold = $WarningThreshold
        autoDeleteLimit = $AutoDeleteLimit
        fullPolicy = "purgepit" # "purge point-in-time" (auto-delete oldest)
        storagePoolId = $null   # Let array decide (usually implies same pool)
    }
    
    return Invoke-SANtricityRequest -Method 'POST' -Path '/snapshot-groups' -Body $payload
}
