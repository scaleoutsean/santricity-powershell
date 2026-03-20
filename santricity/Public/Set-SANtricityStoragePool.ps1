<#
.SYNOPSIS
Modifies properties of a SANtricity Storage Pool (Volume Group or DDP).

.DESCRIPTION
Abstracts the complex SANtricity API requirements for modifying storage pools. Changing multiple priorities
requires multiple API requests, and SSD optimization uses a global Key-Value endpoint with escaped JSON strings.
This cmdlet handles all of those intricacies automatically behind a unified parameter set.

.PARAMETER Id
The VolumeGroupRef (ID) of the Storage Pool. Required.

.PARAMETER Name
New name for the storage pool.

.PARAMETER SsdOptimizationCapacity
Percentage of the pool (int) reserved for SSD garbage collection (overprovisioning). 
Note: This feature is limited to specific NVMe-only storage arrays (e.g., EF80, EF50, EF300, EF600) and media types. On unsupported systems, this parameter will emit a warning and gracefully continue.

.PARAMETER ReservedDriveCount
(DDP Only) Number of reserved drives for reconstruction. Allowed values: 1-10.

.PARAMETER PriorityBackground
(DDP Only) Background operation priority. Allowed: lowest, low, medium, high, highest.

.PARAMETER PriorityDegraded
(DDP Only) Degraded reconstruction priority. Allowed: lowest, low, medium, high, highest.

.PARAMETER PriorityCritical
(DDP Only) Critical reconstruction priority. Allowed: lowest, low, medium, high, highest.

.PARAMETER ThresholdWarning
(DDP Only) Warning alert capacity threshold percentage. Allowed: 1-100.

.PARAMETER ThresholdCritical
(DDP Only) Critical alert capacity threshold percentage. Allowed: 1-100.

.EXAMPLE
Get-SANtricityStoragePool -Name "data11" | Set-SANtricityStoragePool -PriorityBackground low -SsdOptimizationCapacity 5
#>
function Set-SANtricityStoragePool {
    [CmdletBinding(DefaultParameterSetName='ById')]
    param(
        [Parameter(Mandatory=$true, ParameterSetName='ById', ValueFromPipelineByPropertyName=$true)]
        [Alias('PoolId', 'VolumeGroupRef')]
        [string]$Id,

        [Parameter(Mandatory=$true, ParameterSetName='ByName')]
        [string]$Name,

        [Parameter(Mandatory=$false)]
        [string]$NewName,

        [Parameter(Mandatory=$false)]
        [int]$SsdOptimizationCapacity,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 10)]
        [int]$ReservedDriveCount,

        [Parameter(Mandatory=$false)]
        [ValidateSet('lowest', 'low', 'medium', 'high', 'highest')]
        [string]$PriorityBackground,

        [Parameter(Mandatory=$false)]
        [ValidateSet('lowest', 'low', 'medium', 'high', 'highest')]
        [string]$PriorityDegraded,

        [Parameter(Mandatory=$false)]
        [ValidateSet('lowest', 'low', 'medium', 'high', 'highest')]
        [string]$PriorityCritical,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 100)]
        [int]$ThresholdWarning,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 100)]
        [int]$ThresholdCritical
    )

    process {
        $lastResult = $null

        # If user passed -Name instead of -Id, we must resolve it first
        if ($PSCmdlet.ParameterSetName -eq 'ByName') {
            Write-Verbose "Resolving Storage Pool by name '$Name'..."
            $pool = Get-SANtricityStoragePool -Name "^$Name$" | Select-Object -First 1
            if (-not $pool) {
                throw "Could not find storage pool with name '$Name'."
            }
            $Id = if ($pool.volumeGroupRef) { $pool.volumeGroupRef } else { $pool.id }
            Write-Verbose "Resolved Name '$Name' to Id '$Id'."
        }

        # 1. Base Pool Updates (Name, ReservedDriveCount)
        $baseBody = @{}
        if ($PSBoundParameters.ContainsKey('NewName')) { 
            $baseBody['name'] = $NewName 
        }
        if ($PSBoundParameters.ContainsKey('ReservedDriveCount')) { 
            $baseBody['reservedDriveCount'] = $ReservedDriveCount 
        }
        
        if ($baseBody.Count -gt 0) {
            Write-Verbose "Updating base storage pool properties for $Id..."
            $lastResult = Invoke-SANtricityRequest -Method POST -Path "/storage-pools/$Id" -Body $baseBody
        }

        # 2. Priorities (API requires separate POST per priority change)
        $priorities = @{}
        if ($PSBoundParameters.ContainsKey('PriorityBackground')) { $priorities['background'] = $PriorityBackground }
        if ($PSBoundParameters.ContainsKey('PriorityDegraded')) { $priorities['degraded'] = $PriorityDegraded }
        if ($PSBoundParameters.ContainsKey('PriorityCritical')) { $priorities['critical'] = $PriorityCritical }
        
        foreach ($p in $priorities.Keys) {
            Write-Verbose "Updating storage pool priority ($p) to $($priorities[$p])..."
            $pBody = @{
                poolPriority = @{
                    priorityType = $p
                    priority = $priorities[$p]
                }
            }
            $lastResult = Invoke-SANtricityRequest -Method POST -Path "/storage-pools/$Id" -Body $pBody
        }

        # 3. Thresholds (API requires separate POST per threshold change)
        $thresholds = @{}
        if ($PSBoundParameters.ContainsKey('ThresholdWarning')) { $thresholds['warning'] = $ThresholdWarning }
        if ($PSBoundParameters.ContainsKey('ThresholdCritical')) { $thresholds['critical'] = $ThresholdCritical }
        
        foreach ($t in $thresholds.Keys) {
            Write-Verbose "Updating storage pool threshold ($t) to $($thresholds[$t])..."
            $tBody = @{
                poolThreshold = @{
                    thresholdType = $t
                    value = $thresholds[$t]
                }
            }
            $lastResult = Invoke-SANtricityRequest -Method POST -Path "/storage-pools/$Id" -Body $tBody
        }

        # 4. SSD Optimization Capacity (Key-Value map string quirk)
        if ($PSBoundParameters.ContainsKey('SsdOptimizationCapacity')) {
            Write-Verbose "Updating SSD Optimization Capacity to $SsdOptimizationCapacity%..."
            $kvPath = '/key-values/storagePoolSsdOptimizationCapacity'
            
            # Fetch existing map to ensure we don't clobber other pools
            $existingKv = $null
            try {
                $existingKv = Invoke-SANtricityRequest -Method GET -Path $kvPath -ErrorAction Stop
            } catch {
                Write-Verbose "Could not fetch existing optimization capacity settings (key may not exist). Generating new map."
            }

            $mapObj = @{}
            if ($existingKv -and $existingKv.value) {
                try {
                    # Convert the stringified JSON payload
                    $mapObj = $existingKv.value | ConvertFrom-Json -AsHashtable
                } catch {
                    Write-Warning "Failed to parse existing storagePoolSsdOptimizationCapacity string. Clobbering old map."
                    $mapObj = @{}
                }
            }

            # Inject the current pool's new capacity percent
            $mapObj[$Id] = $SsdOptimizationCapacity

            # Convert back to standard payload JSON representation per the user example payload
            try {
                $lastResult = Invoke-SANtricityRequest -Method POST -Path $kvPath -Body $mapObj -ErrorAction Stop
            } catch {
                if ($_.Exception.Message -match "404") {
                    Write-Warning "SSD Optimization Capacity (-SsdOptimizationCapacity) is not supported on this array model or media type (likely requires NVMe-specific models like EF600/EF300/EF80/EF50). Parameter ignored."
                } else {
                    Write-Warning "Failed to set SSD Optimization Capacity: $($_.Exception.Message). Parameter ignored."
                }
            }
        }

        # Return the final modified state
        # In case nothing was changed, fetch it to fulfill expected pipeline behavior
        if (-not $lastResult) {
            $lastResult = Invoke-SANtricityRequest -Method GET -Path "/storage-pools/$Id"
        }
        
        return $lastResult
    }
}
