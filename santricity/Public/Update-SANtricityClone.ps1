
function Update-SANtricityClone {
    <#
    .SYNOPSIS
    Refresh (Reset) a Snapshot Volume (Clone) to a new Snapshot Image.

    .DESCRIPTION
    Updates an existing Snapshot Volume (View) to point to a different Snapshot Image (PIT).
    This effectively "refreshes" the clone data to a different point in time.
    
    The process involves stopping the current View and restarting it with the new base PIT.

    .PARAMETER Id
    The unique identifier (ViewRef) of the Snapshot Volume to refresh.

    .PARAMETER Name
    The name of the Snapshot Volume (to resolve to Id).

    .PARAMETER SnapshotImageId
    The unique identifier (PitRef) of the new Snapshot Image to use.

    .EXAMPLE
    Update-SANtricityClone -Name "clone_db_test" -SnapshotImageId "34000..."
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory = $true)]
        [string]$Id,

        [Parameter(ParameterSetName = 'ByName', Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$SnapshotImageId
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        $clone = Get-SANtricityClone | Where-Object { $_.label -eq $Name }
        if (-not $clone) {
            throw "Snapshot Volume '$Name' not found."
        }
        $Id = $clone.id
    }

    # 1. Stop the current PIT View
    # The API expects the ViewRef ID as a simple JSON string (e.g. "3500...")
    Write-Verbose "Stopping PIT View for Clone '$Id'..."
    $null = Invoke-SANtricityRequest -Method 'POST' -Path '/symbol/stopPITView' -Body $Id

    # 2. Restart the PIT View with new BasePIT
    # The API expects a JSON object with viewRef and basePIT
    Write-Verbose "Restarting PIT View to Snapshot Image '$SnapshotImageId'..."
    
    $restartBody = @{
        viewRef = $Id
        basePIT = $SnapshotImageId
    }

    return Invoke-SANtricityRequest -Method 'POST' -Path '/symbol/restartPITView' -Body $restartBody
}
