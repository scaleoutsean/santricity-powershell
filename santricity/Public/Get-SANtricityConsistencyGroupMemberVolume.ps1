function Get-SANtricityConsistencyGroupMemberVolume {
    <#
    .SYNOPSIS
    Retrieve member volumes for Consistency Groups.

    .DESCRIPTION
    Returns a list of all consistency group member volumes.
    #>
    [CmdletBinding()]
    param()

    return Invoke-SANtricityRequest -Method 'GET' -Path '/consistency-groups/member-volumes'
}
