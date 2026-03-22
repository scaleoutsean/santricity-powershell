function Get-SANtricityConsistencyGroupClone {
    <#
    .SYNOPSIS
    Retrieve consistency group clone volumes (snapshot views).

    .DESCRIPTION
    Returns a list of all consistency group snapshot views (clones).

    .PARAMETER ConsistencyGroupId
    Optional. The ID of the consistency group. If specified, only returns views for that specific consistency group.

    .PARAMETER ViewId
    Optional. The ID of the specific consistency group view to retrieve. Requires ConsistencyGroupId.

    .PARAMETER Newest
    If specified, returns only the single most recently created view in the array.

    .PARAMETER Oldest
    If specified, returns only the single oldest created view.
    #>
    [CmdletBinding()]
    [Alias("Get-SANtricityConsistencyGroupView")]
    param(
        [string]$ConsistencyGroupId,
        [string]$ViewId,
        [switch]$Newest,
        [switch]$Oldest
    )

    $views = if ($ConsistencyGroupId -and $ViewId) {
        Invoke-SANtricityRequest -Method 'GET' -Path "/consistency-groups/$ConsistencyGroupId/views/$ViewId"
    } elseif ($ConsistencyGroupId) {
        Invoke-SANtricityRequest -Method 'GET' -Path "/consistency-groups/$ConsistencyGroupId/views"
    } else {
        Invoke-SANtricityRequest -Method 'GET' -Path '/consistency-groups/views'
    }

    if (-not $views) { return $null }

    if ($Newest -or $Oldest) {
        # 'pitSequenceNumber' natively tracks internal generation logic on the array
        $sorted = $views | Sort-Object -Property pitSequenceNumber
        if ($Oldest) { return $sorted | Select-Object -First 1 }
        if ($Newest) { return $sorted | Select-Object -Last 1 }
    }

    return $views
}
