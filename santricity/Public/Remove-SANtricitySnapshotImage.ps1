
function Remove-SANtricitySnapshotImage {
    <#
    .SYNOPSIS
    Deletes a snapshot image.

    .DESCRIPTION
    Removes a Point-in-Time (PiT) snapshot image from the system.
    Note: SANtricity generally requires deleting the OLDEST snapshot in a group first.
    Use the -Oldest switch with the Group/BaseVolume filtering to automatically find and target it.

    .PARAMETER Id
    The unique identifier (PitRef) of the snapshot image to delete.

    .PARAMETER Oldest
    Automatically selects the oldest snapshot image from the filtered set (GroupId or BaseVolumeId).

    .PARAMETER GroupId
    Filter by Snapshot Group ID (PitGroupRef). Required if using -Oldest.

    .PARAMETER BaseVolumeId
    Filter by Base Volume ID. Can be used with -Oldest to find the oldest snapshot for a volume.

    .EXAMPLE
    Remove-SANtricitySnapshotImage -Id "34000..."

    .EXAMPLE
    Remove-SANtricitySnapshotImage -GroupId "33000..." -Oldest
    Safely removes the oldest snapshot in the group (required deletion order).
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess = $true)]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = 'id')]
        [string]$Id,

        [Parameter(ParameterSetName = 'ByOldest', Mandatory = $true)]
        [switch]$Oldest,

        [Parameter(ParameterSetName = 'ByOldest', Mandatory = $false)]
        [string]$GroupId,
        
        [Parameter(ParameterSetName = 'ByOldest', Mandatory = $false)]
        [string]$BaseVolumeId
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'ByOldest') {
            if (-not $GroupId -and -not $BaseVolumeId) {
                throw "When using -Oldest, you must specify either -GroupId or -BaseVolumeId to identify the scope."
            }

            Write-Verbose "Finding the oldest snapshot..."
            $oldestSnap = Get-SANtricitySnapshotImage -GroupId $GroupId -BaseVolumeId $BaseVolumeId -Oldest
            
            if (-not $oldestSnap) {
                Write-Warning "No snapshots found matching the specified criteria."
                return
            }
            
            $Id = $oldestSnap.id
            Write-Verbose "Targeting oldest snapshot: Seequece $($oldestSnap.pitSequenceNumber) (Timestamp: $($oldestSnap.pitTimestamp)) - ID: $Id"
        }

        if ($PSCmdlet.ShouldProcess("Snapshot Image $Id", "Remove Snapshot Image")) {
            return Invoke-SANtricityRequest -Method 'DELETE' -Path "/snapshot-images/$Id"
        }
    }
}
