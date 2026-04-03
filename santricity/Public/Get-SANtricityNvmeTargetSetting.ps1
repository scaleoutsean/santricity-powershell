function Get-SANtricityNvmeTargetSetting {
    <#
    .SYNOPSIS
    Retrieves the NVMe-oF target or initiator settings from the SANtricity API.

    .DESCRIPTION
    Returns raw NVMe over Fabrics base configuration, primarily containing the NQN and target references.
    #>
    [CmdletBinding()]
    param()

    # NetApp Swagger lists this as nvmeof/initiator-settings but it represents the target NQN in the response
    try {
        return Invoke-SANtricityRequest -Method 'GET' -Path '/nvmeof/initiator-settings'
    } catch {
        $statusCode = $null
        if ($_.Exception -and $_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
        }

        if ($statusCode -eq 404 -or $_.ToString() -match '\b404\b') {
            Write-Warning 'NVMe-oF target settings endpoint is not available (HTTP 404). NVMe-oF protocol may not be enabled on this array.'
            return $null
        }

        throw
    }
}
