
function Get-SANtricityClone {
    <#
    .SYNOPSIS
    Retrieves all Snapshot Volumes (Clones) from the array.

    .DESCRIPTION
    Returns a list of snapshot volumes. These are viewable volumes created from a Snapshot Image.
    They are often referred to as "Clones" or "Snapshot Views".

    .PARAMETER Id
    Optional. The specific ID (ViewRef) of the snapshot volume to retrieve.

    .EXAMPLE
    Get-SANtricityClone
    List all snapshot volumes.
    #>
    [CmdletBinding()]
    param(
        [string]$Id
    )

    $path = "/snapshot-volumes"
    if ($Id) {
        $path += "/$Id"
    }

    return Invoke-SANtricityRequest -Method 'GET' -Path $path
}
