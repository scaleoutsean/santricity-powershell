
function Get-SANtricityStoragePools {
    <#
    .SYNOPSIS
    Retrieve storage pools from the SANtricity API.

    .DESCRIPTION
    Calls the controller's storage-pools endpoint and returns pool objects.
    #>
    return Invoke-SANtricityRequest -Method 'GET' -Path '/storage-pools'
}
