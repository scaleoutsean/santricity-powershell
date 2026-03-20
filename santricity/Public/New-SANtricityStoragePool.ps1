<#
.SYNOPSIS
Create a new storage pool (Volume Group or DDP).

.DESCRIPTION
Creates a new storage pool. Supports creating pools with specific RAID levels or simply using all available drives (Auto).
When using -Auto, it attempts to select the largest group of compatible (same media type) unbound drives.
Do not confuse this with the logic and options available in SMcli. This cmdlet is streamlined and targets single shelf pools.

.PARAMETER Name
Name of the new storage pool.

.PARAMETER RaidLevel
RAID level for the pool. Default: 'raidDiskPool' (DDP).
Allowed values: raidDiskPool, raid1, raid5, raid6, raid0.

.PARAMETER DriveCount
Number of drives to use. If not specified, and Auto is used, all available drives (of the largest compatible group) are used.

.PARAMETER Auto
Automatically select optimal unassigned drives.

.PARAMETER DiskIds
List of drive identifiers (driveRef) to use. Overrides Auto.

.PARAMETER DriveSlots
List of drive slots (IDs 0..N) to use. Requires fetching drive details first. Use Get-SANtricityDrive to find slot numbers. Overrides Auto.

.EXAMPLE
New-SANtricityStoragePool -Name "Pool1" -Auto
New-SANtricityStoragePool -Name "Pool1" -RaidLevel raid6 -DriveCount 10 -Auto
New-SANtricityStoragePool -Name "Pool1" -DiskIds @("0100000000000000000000000000000000000000", "0100000000000000000000000000000000000001")
New-SANtricityStoragePool -Name "Pool1" -DriveSlots 2,18
#>
function New-SANtricityStoragePool {
    [CmdletBinding(DefaultParameterSetName='Auto')]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,

        [Parameter(Mandatory=$false)]
        [ValidateSet('raidDiskPool','raid0','raid1','raid5','raid6')]
        [string]$RaidLevel = 'raidDiskPool',

        [Parameter(Mandatory=$false)]
        [int]$DriveCount,

        [Parameter(Mandatory=$true, ParameterSetName='Auto')]
        [switch]$Auto,

        [Parameter(Mandatory=$true, ParameterSetName='ManualIds')]
        [string[]]$DiskIds,

        [Parameter(Mandatory=$true, ParameterSetName='ManualSlots')]
        [int[]]$DriveSlots
    )

    $selectedDriveIds = @()

    if ($PSCmdlet.ParameterSetName -eq 'ManualIds') {
        $selectedDriveIds = $DiskIds
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'ManualSlots') {
        Write-Verbose "Resolving drive slots to IDs..."
        $allDrives = Get-SANtricityDrive
        if (-not $allDrives) { throw "No drives found to resolve slots." }
        
        $foundDrives = $allDrives | Where-Object { 
            $_.physicalLocation -and 
            ($_.physicalLocation.slot -in $DriveSlots)
        }

        # Check if we found all requested slots
        $foundSlots = $foundDrives | ForEach-Object { $_.physicalLocation.slot }
        $missingSlots = $DriveSlots | Where-Object { $_ -notin $foundSlots }
        
        if ($missingSlots) {
            Write-Warning "Could not find drives for requested slots: $($missingSlots -join ', ')"
        }

        if ($foundDrives.Count -eq 0) {
            throw "No drives found matching the requested slots."
        }

        $selectedDriveIds = $foundDrives.id
    }
    elseif ($Auto) {
        Write-Verbose "Retrieving all drives..."
        $allDrives = Get-SANtricityDrive
        
        if (-not $allDrives) {
            throw "No drives found on the system."
        }

        Write-Verbose "Filtering for optimal, unassigned, non-hotspare drives..."
        # Filter for candidates: optimal, not assigned to a pool, not hot spare
        $candidates = $allDrives | Where-Object { 
            ($_.status -eq 'optimal') -and 
            (-not $_.hotSpare) -and
            ($_.currentVolumeGroupRef -eq $null -or $_.currentVolumeGroupRef -match '^[0]+$')
        }

        if (-not $candidates) {
            throw "No optimal unassigned drives found."
        }
        
        # Group by media type to avoid mixing SSD and HDD
        $groups = $candidates | Group-Object -Property driveMediaType
        
        if ($groups.Count -gt 1) {
            Write-Verbose "Found mixed media types: $($groups | ForEach-Object { $_.Name + '(' + $_.Count + ')' } | Join-String -Separator ', ')"
        }
        
        # Select the group with the most drives
        $bestGroup = $groups | Sort-Object Count -Descending | Select-Object -First 1
        
        Write-Verbose "Selected media type: '$($bestGroup.Name)' with $($bestGroup.Count) drives."
        $finalCandidates = $bestGroup.Group

        # If user wanted specific count
        if ($PSBoundParameters.ContainsKey('DriveCount')) {
            if ($finalCandidates.Count -lt $DriveCount) {
                throw "Requested $DriveCount drives, but only $($finalCandidates.Count) available of type $($bestGroup.Name)."
            }
            $finalCandidates = $finalCandidates | Select-Object -First $DriveCount
        }

        $selectedDriveIds = $finalCandidates.id
    }

    if ($selectedDriveIds.Count -eq 0) {
        throw "No drives selected for pool creation."
    }

    Write-Verbose "Creating pool '$Name' with $($selectedDriveIds.Count) drives (RAID: $RaidLevel)."

    # API expects 'diskDriveIds' (list of IDs) not 'driveRef'
    $body = @{
        name = $Name
        raidLevel = $RaidLevel
        diskDriveIds = $selectedDriveIds
        eraseSecuredDrives = $true
    }
    
    $response = Invoke-SANtricityRequest -Method 'POST' -Path '/storage-pools' -Body $body
    return $response
}
