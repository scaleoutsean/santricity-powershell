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
    return Invoke-SANtricityRequest -Method 'GET' -Path '/nvmeof/initiator-settings'
}
