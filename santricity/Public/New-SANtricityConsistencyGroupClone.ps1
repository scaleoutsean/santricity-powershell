function New-SANtricityConsistencyGroupClone {
    <#
    .SYNOPSIS
    Creates a snapshot view (Linked Clone) for a Consistency Group.

    .DESCRIPTION
    Creates access volumes (clones) for all members of a consistency group from a specific point-in-time snapshot.
    The clone can be Read-Only or Read-Write.

    .PARAMETER ConsistencyGroupId
    The ID (Ref) of the source Consistency Group.

    .PARAMETER Name
    The name for the new View object.

    .PARAMETER PitSequenceNumber
    The sequence number of the snapshot to use. If omitted, uses the latest snapshot.

    .PARAMETER AccessMode
    'readOnly' or 'readWrite'. Defaults to 'readOnly'.
    
    .PARAMETER RepositoryPercentage
    Percentage of base volume size to allocate for copy-on-write repository (Read-Write mode only).

    .EXAMPLE
    New-SANtricityConsistencyGroupClone -ConsistencyGroupId "2A00..." -Name "Clone1" -AccessMode ReadWrite
    #>
    [CmdletBinding()]
    [Alias("New-SANtricityConsistencyGroupView")]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConsistencyGroupId,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$PitSequenceNumber,

        [ValidateSet('readOnly', 'readWrite')]
        [string]$AccessMode = 'readOnly',

        [int]$RepositoryPercentage = 20
    )

    process {
        # 1. Resolve PIT Sequence if not provided (Get latest)
        
        # We need to map Name/Label to ConsistencyGroupId if a name was provided (implied logic, but param is Id)
        # Assuming ConsistencyGroupId is the ID/Ref.
        
        if (-not $PitSequenceNumber) {
            Write-Verbose "Resolving latest snapshot for CG $ConsistencyGroupId..."
            
            # API endpoint to get list of snapshots for a CG
            # GET /consistency-groups/{id}/snapshots
            $snapUri = "/consistency-groups/$ConsistencyGroupId/snapshots"
            try {
                $snaps = Invoke-SANtricityRequest -Method 'GET' -Path $snapUri
            } catch {
                throw "Failed to list snapshots for CG ${ConsistencyGroupId}: $_"
            }
            
            if (-not $snaps) { throw "No snapshots found for Consistency Group ${ConsistencyGroupId}" }
            
            # Sort descending by sequence number
            # Need to ensure property name matches API response (pitSequenceNumber)
            # The API returns an array (multiple base volume snapshots for same sequence).
            # We just need one unique sequence number.
            $latest = $snaps | Sort-Object pitSequenceNumber -Descending | Select-Object -First 1
            $PitSequenceNumber = $latest.pitSequenceNumber
            Write-Verbose "Using latest snapshot sequence: $PitSequenceNumber"
        }

        # 2. Build Payload
        # Endpoint: /consistency-groups/{id}/views
        $uri = "/consistency-groups/$ConsistencyGroupId/views"
        
        $payload = @{
            name = $Name
            pitSequenceNumber = $PitSequenceNumber
            accessMode = $AccessMode
        }

        if ($AccessMode -eq 'readWrite') {
            # Based on Swagger, this field might be repositoryPercent (no age) or repositoryPercentage
            # Example shows 'repositoryPercent'
            $payload['repositoryPercent'] = $RepositoryPercentage
        }

        Write-Verbose "Creating CG View '$Name' (Mode: $AccessMode)..."
        
        try {
            $view = Invoke-SANtricityRequest -Method 'POST' -Path $uri -Body $payload
            return $view
        } catch {
            throw "Failed to create Consistency Group View: $_"
        }
    }
}
