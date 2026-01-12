
function Get-SANtricityHostGroups {
    <#
    .SYNOPSIS
    Retrieve host-groups from the SANtricity API.

    .DESCRIPTION
    Calls the controller's host-groups endpoint and returns host-group objects.
    #>
    return Invoke-SANtricityRequest -Method 'GET' -Path '/host-groups'
}
