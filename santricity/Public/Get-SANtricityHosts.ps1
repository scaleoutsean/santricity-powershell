
function Get-SANtricityHosts {
    <#
    .SYNOPSIS
    Retrieve host definitions from the SANtricity API.

    .DESCRIPTION
    Calls the controller's hosts endpoint and returns host objects.
    #>
    return Invoke-SANtricityRequest -Method 'GET' -Path '/hosts'
}
