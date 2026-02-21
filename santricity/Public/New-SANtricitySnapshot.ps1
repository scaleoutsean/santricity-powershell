
function New-SANtricitySnapshot {
    <#
    .SYNOPSIS
    Create a new snapshot image for a volume.

    .DESCRIPTION
    Creates an instant snapshot of the specified volume. If a Snapshot Group does not 
    exist for the volume, one will be created automatically if -Force is specified.

    .PARAMETER BaseVolumeId
    The unique identifier (Ref) of the base volume.

    .PARAMETER VolumeName
    The name of the base volume. Normalized to BaseVolumeId internally.

    .PARAMETER Force
    Automatically create a Snapshot Group (and Repository) if one does not exist.
    Without this switch, the command fails if the snapshot infrastructure is missing.

    .PARAMETER RepositoryPercentage (Optional)
    When creating a new group (with -Force), specified repo size percentage (default 20).

    .EXAMPLE
    New-SANtricitySnapshot -VolumeName "db_vol"
    Taking a snapshot of an existing group.

    .EXAMPLE
    New-SANtricitySnapshot -VolumeName "new_vol" -Force
    Creating a new group/repo and then taking the first snapshot.

    .EXAMPLE
    New-SANtricitySnapshot -ConsistencyGroup "OracleCG"
    Taking a snapshot of an entire Consistency Group.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param(
        [Parameter(ParameterSetName = 'Default', Mandatory = $true)]
        [string]$BaseVolumeId,

        [Parameter(ParameterSetName = 'ByVolumeName', Mandatory = $true)]
        [string]$VolumeName,

        [Parameter(ParameterSetName = 'ByConsistencyGroup', Mandatory = $true)]
        [string]$ConsistencyGroup,

        [switch]$Force,
        
        [int]$RepositoryPercentage = 20
    )

    # ----------------------------
    # Scenario A: Consistency Group Snapshot
    # ----------------------------
    if ($PSCmdlet.ParameterSetName -eq 'ByConsistencyGroup') {
        # 1. Resolve CG (Try Name first, then ID)
        $cgParam = $ConsistencyGroup
        
        # Try assuming it's a Name
        $cg = Get-SANtricityConsistencyGroup -Name $cgParam
        
        if (-not $cg) {
            # Try assuming it's an ID
            try {
                $cg = Get-SANtricityConsistencyGroup -Id $cgParam -ErrorAction Stop
            } catch {
                $cg = $null
            }
        }
        
        if (-not $cg) { throw "Consistency Group '$cgParam' not found." }

        Write-Verbose "Creating snapshot for Consistency Group '$($cg.name)'..."
        
        # Endpoint: POST /consistency-groups/{cg-id}/snapshots
        return Invoke-SANtricityRequest -Method 'POST' -Path "/consistency-groups/$($cg.id)/snapshots"
    }

    # ----------------------------
    # Scenario B: Single Volume Snapshot
    # ----------------------------

    # 1. Resolve Volume Name to ID if needed
    if ($PSCmdlet.ParameterSetName -eq 'ByVolumeName') {
        $vol = Get-SANtricityVolumes | Where-Object { $_.label -eq $VolumeName }
        if (-not $vol) {
            throw "Volume with name '$VolumeName' not found."
        }
        $BaseVolumeId = $vol.id
    } else {
        # Fetch volume anyway to get the name for logging
        $vol = Get-SANtricityVolumes | Where-Object { $_.id -eq $BaseVolumeId }
        $VolumeName = if ($vol) { $vol.label } else { "vol_$BaseVolumeId" }
    }

    # 2. Check for Existing Group
    Write-Verbose "Checking for existing snapshot group for '$VolumeName'..."
    $group = Get-SANtricitySnapshotGroup -BaseVolumeId $BaseVolumeId

    if (-not $group) {
        if (-not $Force) {
            throw "No snapshot group exists for volume '$VolumeName'. Use -Force to automatically create one."
        }
        
        Write-Verbose "No group found. Creating new Snapshot Group (Force=$true)..."
        # Implicitly allow default naming and settings for the group
        $group = New-SANtricitySnapshotGroup -BaseVolumeId $BaseVolumeId -RepositoryPercentage $RepositoryPercentage
        
        if (-not $group) {
            throw "Failed to create snapshot group."
        }
        Write-Verbose "Snapshot Group created: $($group.name) ($($group.id))"
    } else {
        Write-Verbose "Found existing snapshot group: $($group.name)"
    }

    # 3. Create the Snapshot Image
    # Payload is simply the Group Ref
    $payload = @{
        groupId = $group.id
    }

    Write-Verbose "Creating new snapshot image in group '$($group.name)'..."
    return Invoke-SANtricityRequest -Method 'POST' -Path '/snapshot-images' -Body $payload
}
