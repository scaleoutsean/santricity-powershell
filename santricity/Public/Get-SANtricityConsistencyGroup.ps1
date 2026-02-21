function Get-SANtricityConsistencyGroup {
    <#
    .SYNOPSIS
    Retrieves information about Consistency Groups (CGs).

    .DESCRIPTION
    Returns a list of all consistency groups on the storage array.
    Consistency groups allow snapshots of multiple volumes to be taken simultaneously for data consistency.

    .PARAMETER Id
    The unique identifier (Ref) of the consistency group to retrieve.

    .PARAMETER Name
    Filter by the user-assigned label of the consistency group.

    .EXAMPLE
    Get-SANtricityConsistencyGroup
    #>
    [CmdletBinding()]
    param(
        [string]$Id,
        [string]$Name
    )

    if ($Id) {
        # Retrieve all groups and filter by ID to ensure consistent object structure
        # (Direct endpoint can sometimes behave inconsistently regarding list wrapping)
        $allGroups = Invoke-SANtricityRequest -Method 'GET' -Path '/consistency-groups'
        if (-not $allGroups) { return $null }

        return $allGroups | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    }

    $allGroups = Invoke-SANtricityRequest -Method 'GET' -Path '/consistency-groups'
    
    if (-not $allGroups) { return $null }

    if ($Name) {
        $allGroups = $allGroups | Where-Object { $_.name -eq $Name }
    }

    return $allGroups
}
