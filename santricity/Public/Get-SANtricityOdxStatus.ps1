function Get-SANtricityOdxStatus {
    <#
    .SYNOPSIS
    Check if ODX is enabled on the storage system.

    .DESCRIPTION
    Checks the Offloaded Data Transfer (ODX) status on the storage array.
    Returns $true if enabled, $false otherwise.

    .EXAMPLE
    Get-SANtricityOdxStatus
    #>
    [CmdletBinding()]
    param()

    $body = @{
        functionAction = 'getValue'
        functionID     = 'odx'
    }

    $response = Invoke-SANtricityRequest -Method 'POST' -Path '/symbol/setFunctionState?controller=auto' -Body $body

    if ($response -and $response.functionState -eq 'enabled') {
        return $true
    }
    return $false
}
