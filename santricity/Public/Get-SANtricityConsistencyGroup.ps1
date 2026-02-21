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
        $result = Invoke-SANtricityRequest -Method 'GET' -Path "/consistency-groups/$Id"
        if ($result -is [array]) {
            return $result | Select-Object -First 1
        }
        return $result
    }

    $allGroups = Invoke-SANtricityRequest -Method 'GET' -Path '/consistency-groups'
    
    if (-not $allGroups) { return $null }

    if ($Name) {
        $allGroups = $allGroups | Where-Object { $_.name -eq $Name }
    }

    return $allGroups
}
