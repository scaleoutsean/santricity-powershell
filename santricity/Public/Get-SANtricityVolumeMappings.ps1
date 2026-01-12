
function Get-SANtricityVolumeMappings {
    <#
    .SYNOPSIS
    Retrieve volume mappings from the SANtricity API.

    .DESCRIPTION
    Calls the controller's volume-mappings endpoint and returns mapping objects.
    #>
    return Invoke-SANtricityRequest -Method 'GET' -Path '/volume-mappings'
}
