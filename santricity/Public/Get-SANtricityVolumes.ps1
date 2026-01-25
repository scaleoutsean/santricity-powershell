
function Get-SANtricityVolumes {
    <#
    .SYNOPSIS
    Retrieve volumes from the SANtricity API.

    .DESCRIPTION
    Calls the controller's volumes endpoint and returns volume objects.
    By default, it returns only standard and thin volumes (user-usable LUNs).
    Use -IncludeSystem to see internal volumes (repositories, etc.).

    .PARAMETER IncludeSystem
    If specified, includes all volume types, including internal repository volumes.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeSystem
    )

    $vols = Invoke-SANtricityRequest -Method 'GET' -Path '/volumes'
    
    if (-not $vols) { return $null }

    if (-not $IncludeSystem) {
        # Default behavior: Filter for user-usable volumes only
        return $vols | Where-Object { $_.volumeUse -in @('standardVolume', 'thinVolume') }
    }

    return $vols
}
