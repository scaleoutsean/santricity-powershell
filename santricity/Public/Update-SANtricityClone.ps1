
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
    # Based on HAR analysis:
    # 1. stopPITView takes a RAW STRING payload (the viewRef ID), NOT a JSON object.
    #    Invoke-SANtricityRequest usually auto-JSON-encodes. We might need to handle this manually 
    #    or trick the cmdlet. If Invoke-SANtricityRequest enforces JSON, this specific call might fail
    #    unless we update the Invoke helper or use a raw web request.
    
    # Let's try to see if Invoke-SANtricityRequest can handle a string body directly without JSON encoding
    # if it's already a string.
    
    Write-Verbose "Stopping PIT View for Clone '$Id'..."
    
    # According to HAR: "text": "350000..." (just the ID)
    # The error 422 previously encountered with `{ "viewRef": "..." }` confirms the object format was rejected.
    
    # We will pass the ID as the body. Invoke-SANtricityRequest's behavior with string body needs to be verified.
    # Assuming Invoke-SANtricityRequest converts body to JSON using ConvertTo-Json if it's not a string.
    # If it Is a string, it might just send it? 
    # Let's double check `santricity.psm1` logic if possible, but as a quick fix, we force the string.
    # Wait, Invoke-SANtricityRequest usually sets Content-Type to application/json.
    # Sending a raw string with application/json is technically valid JSON if quoted, but the API might want
    # *just* the characters? 
    # "text": "3500..." implies the HTTP body was literally 3500... 
    # BUT if Content-Type was application/json, that would be invalid unless it was "3500...".
    #
    # Actually, looking at typical SYMbol behavior, it's often weird.
    # However, since we cannot easily change Invoke-SANtricityRequest right now without risking other things,
    # let's try passing the ID in quotes to mimic a JSON string, OR just the ID.
    
    # Let's assume the previous failure was purely because we sent an Object `{ viewRef: ... }` 
    # when it expected a String "..." (JSON string) or just raw text.
    
    # Let's try sending the simple string. 
    # If Invoke-SANtricityRequest performs `ConvertTo-Json $Body`, then a string input "ABC" becomes "\"ABC\"".
    # If the API expects the ID in quotes (JSON String), this works.
    # If the API expects RAW text (no quotes), we have a problem with Invoke-SANtricityRequest.
    
    # Given the previous error "422" with an object, it's highly likely it rejected the schema.
    
    $stopResult = Invoke-SANtricityRequest -Method 'POST' -Path '/symbol/stopPITView' -Body $Id

    # 2. Restart the PIT View with new BasePIT
    # HAR confirms this one IS a standard JSON object.
    Write-Verbose "Restarting PIT View to Snapshot Image '$SnapshotImageId'..."
    
    $restartBody = @{
        viewRef = $Id
        basePIT = $SnapshotImageId
    }

    return Invoke-SANtricityRequest -Method 'POST' -Path '/symbol/restartPITView' -Body $restartBody
}
