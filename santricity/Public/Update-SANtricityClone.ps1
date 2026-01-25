
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

    # The workflow requires interacting with the 'symbol' endpoint (low-level commands)
    # 1. Stop the PIT View
    Write-Verbose "Stopping PIT View for Clone '$Id'..."
    
    # Note: stopPITView takes just the viewRef string in some contexts according to user notes, 
    # but usually Symbol endpoints expect specific JSON structure.
    # User note: "Amazingly this just passes a text string, not JSON" - wait, let's look closer at the note.
    # "Payload: {"viewRef":"..."}" - User notes say payload is JSON.
    # "stopPitView ... Amazingly this just passes a text string, not JSON - PitView ID." 
    # BUT then below specificies: POST .../symbol/stopPITView Payload: {"viewRef": "string", "basePIT": "string"} for restart
    # Let's try the standard object payload first as that's safe for Invoke-SANtricityRequest which json-encodes bodies.
    
    $stopBody = @{
        viewRef = $Id
    }

    # We need to target /symbol/stopPITView
    # Invoke-SANtricityRequest usually targets /devmgr/v2/storage-systems/1/...
    # If we pass a path starting with /symbol, we need to make sure Invoke handles it or we pass it relative.
    # The standard Path parameter is appended to the BaseUrl.
    # If BaseUrl is .../storage-systems/1, then Path '/symbol/stopPITView' works perfectly.

    $stopResult = Invoke-SANtricityRequest -Method 'POST' -Path '/symbol/stopPITView' -Body $stopBody

    # 2. Restart the PIT View with new BasePIT
    Write-Verbose "Restarting PIT View to Snapshot Image '$SnapshotImageId'..."
    
    $restartBody = @{
        viewRef = $Id
        basePIT = $SnapshotImageId
    }

    return Invoke-SANtricityRequest -Method 'POST' -Path '/symbol/restartPITView' -Body $restartBody
}
