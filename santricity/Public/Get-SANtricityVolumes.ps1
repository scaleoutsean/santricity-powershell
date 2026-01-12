
function Get-SANtricityVolumes {
    <#
    .SYNOPSIS
    Retrieve volumes from the SANtricity API.

    .DESCRIPTION
    Calls the controller's volumes endpoint and returns the volume objects.
    #>
    return Invoke-SANtricityRequest -Method 'GET' -Path '/volumes'
}
