
function Get-SANtricityStoragePool {
    <#
    .SYNOPSIS
    Retrieve storage pools from the SANtricity API.

    .DESCRIPTION
    Calls the controller's storage-pools endpoint and returns pool objects.
    Supports filtering by Name (Label), PoolId (Ref), and RaidLevel.

    .PARAMETER Name
    Filter by Pool Label or Name (regex match).

    .PARAMETER PoolId
    Filter by Volume Group Ref (IDs).

    .PARAMETER RaidLevel
    Filter by RAID Level (e.g., 'raidDiskPool', 'raid6', 'raid1').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string]$PoolId,

        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string]$RaidLevel
    )

    process {
        $pools = Invoke-SANtricityRequest -Method 'GET' -Path '/storage-pools'
        
        if (-not $pools) { return }

        foreach ($p in $pools) {
            $match = $true

            # Filter by Name/Label (Regex)
            if ($PSBoundParameters.ContainsKey('Name')) {
                # API usually provides 'label' or 'name' (often both, identical)
                $label = if ($p.label) { $p.label } else { $p.name }
                if (-not ($label -and $label -match $Name)) { $match = $false }
            }

            # Filter by PoolId (Ref)
            # The storage-pool object usually has 'volumeGroupRef' or 'id'
            if ($match -and $PSBoundParameters.ContainsKey('PoolId')) {
                $ref = if ($p.volumeGroupRef) { $p.volumeGroupRef } else { $p.id }
                if ($ref -ne $PoolId) { $match = $false }
            }

            # Filter by RaidLevel
            if ($match -and $PSBoundParameters.ContainsKey('RaidLevel')) {
                if ($p.raidLevel -ne $RaidLevel) { $match = $false }
            }
            
            if ($match) { $p }
        }
    }
}
