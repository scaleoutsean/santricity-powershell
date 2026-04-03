function Get-SANtricityIscsiTargetSetting {
    <#
    .SYNOPSIS
    Retrieves the iSCSI target settings from the SANtricity API.

    .DESCRIPTION
    Returns raw iSCSI target configurations including IQN and configured portals.
    #>
    [CmdletBinding()]
    param()

    try {
        return Invoke-SANtricityRequest -Method 'GET' -Path '/iscsi/target-settings'
    } catch {
        $statusCode = $null
        if ($_.Exception -and $_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
        }

        if ($statusCode -eq 404 -or $_.ToString() -match '\b404\b') {
            Write-Warning 'iSCSI target settings endpoint is not available (HTTP 404). iSCSI protocol may not be enabled on this array.'
            return $null
        }

        throw
    }
}
