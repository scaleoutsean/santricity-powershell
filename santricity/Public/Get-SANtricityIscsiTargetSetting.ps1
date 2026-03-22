function Get-SANtricityIscsiTargetSetting {
    <#
    .SYNOPSIS
    Retrieves the iSCSI target settings from the SANtricity API.

    .DESCRIPTION
    Returns raw iSCSI target configurations including IQN and configured portals.
    #>
    [CmdletBinding()]
    param()

    return Invoke-SANtricityRequest -Method 'GET' -Path '/iscsi/target-settings'
}
