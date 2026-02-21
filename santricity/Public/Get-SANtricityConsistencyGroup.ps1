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

    # Retrieve all consistency groups first.
    # We always list all because looking up by ID via /member-volumes is unreliable for checking CG properties/existence.
    $allGroups = Invoke-SANtricityRequest -Method 'GET' -Path '/consistency-groups'
    
    # DEBUG: Inspect the response to understand why discovery fails
    Write-Host "DEBUG: Type of `$allGroups is $($allGroups.GetType().FullName)"
    Write-Host "DEBUG: Count of `$allGroups is $($allGroups.Count)"
    if ($allGroups) {
        Write-Host "DEBUG: First item: $($allGroups | Select-Object -First 1 | ConvertTo-Json -Depth 2 -Compress)"
    } else {
        Write-Host "DEBUG: `$allGroups is null or empty"
    }

    if (-not $allGroups) { return $null }

    if ($Id) {
        $allGroups = $allGroups | Where-Object { $_.id -eq $Id }
    }

    if ($Name) {
        $allGroups = $allGroups | Where-Object { $_.name -eq $Name }
    }

    return $allGroups

}
