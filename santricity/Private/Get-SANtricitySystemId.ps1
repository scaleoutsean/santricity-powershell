
function Get-SANtricitySystemId {
    <#
    .SYNOPSIS
    Return the configured storage system id (placeholder).

    .DESCRIPTION
    Currently returns the configured `StorageSystemId` from the connection config; in future
    this can query the controller to discover the actual system id/WWN.
    #>
    param()

    $cfg = $script:SANtricity_Config
    if (-not $cfg) { throw 'Not connected. Call Connect-SANtricity first.' }
    
    # If user explicitly provided a StorageSystemId, use it without discovery
    if ($cfg.PSObject.Properties.Name -contains 'StorageSystemIdExplicit' -and $cfg.StorageSystemIdExplicit) {
        $id = [string]$cfg.StorageSystemId
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'Configured StorageSystemId is empty or whitespace. Call Connect-SANtricity with a valid -StorageSystemId.'
        }
        Write-Verbose "Using explicitly configured StorageSystemId: $id"
        return $id
    }
    
    # If we have a non-default ID, use it
    if ($cfg.StorageSystemId -and $cfg.StorageSystemId -ne '1') {
        $id = [string]$cfg.StorageSystemId
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'Configured StorageSystemId is empty or whitespace. Call Connect-SANtricity with a valid -StorageSystemId.'
        }
        Write-Verbose "Using configured StorageSystemId: $id"
        return $id
    }

    # attempt discovery if StorageSystemId is default/placeholder
    $discovered = Discover-SANtricitySystemId
    if ($discovered) {
        # persist discovered id
        $cfg.StorageSystemId = $discovered
        $script:SANtricity_Config = $cfg
        Write-Verbose "Discovered and cached StorageSystemId: $discovered"
        return $discovered
    }
    $fallback = if ($cfg.StorageSystemId) { [string]$cfg.StorageSystemId } else { '1' }
    if ([string]::IsNullOrWhiteSpace($fallback)) {
        throw 'Unable to determine StorageSystemId. Call Connect-SANtricity with -StorageSystemId or ensure the controller is reachable.'
    }
    Write-Verbose "Using fallback StorageSystemId: $fallback"
    return $fallback
}
