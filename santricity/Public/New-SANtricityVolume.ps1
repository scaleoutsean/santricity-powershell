<#
.SYNOPSIS
Create a new volume.

.DESCRIPTION
Creates a new volume in a specified storage pool. Supports automatic pool selection based on size and RAID level matching.

.PARAMETER PoolId
The ID of the storage pool to create the volume in.

.PARAMETER PoolName
The name of the storage pool to create the volume in.

.PARAMETER Auto
Automatically select a storage pool that fits the size and RAID requirements.

.PARAMETER Name
The name of the new volume.

.PARAMETER SizeUnit
Unit for the size (gb, tb, mb).

.PARAMETER Size
Size of the volume.

.PARAMETER SegSize
Segment size in KiB. Optional. Only applying to standard pools (diskPool=false).

.PARAMETER DataAssuranceEnabled
Enables Data Assurance (DA).

.PARAMETER RaidLevel
Required RAID level (raid1, raid5, raid6, raid0). Important for Auto selection and validation. DDP pools support raid1 and raid6.

.PARAMETER MetaTags
Array of Key/Value pairs for metadata.

.PARAMETER BlockSize
Sector size (usually 512 or 4096).

.EXAMPLE
New-SANtricityVolume -PoolName "Pool1" -Name "Vol1" -Size 10 -SizeUnit gb
New-SANtricityVolume -Auto -RaidLevel raid6 -Name "Vol2" -Size 100 -SizeUnit gb
#>
function New-SANtricityVolume {
    [CmdletBinding(DefaultParameterSetName="Auto")]
    param (
        [Parameter(Mandatory=$true, ParameterSetName="ById")]
        [string]$PoolId,

        [Parameter(Mandatory=$true, ParameterSetName="ByName")]
        [string]$PoolName,

        [Parameter(Mandatory=$false, ParameterSetName="Auto")]
        [switch]$Auto,

        [Parameter(Mandatory=$true)]
        [string]$Name,

        [Parameter(Mandatory=$true)]
        [ValidateSet("gb","tb","mb")]
        [string]$SizeUnit,

        [Parameter(Mandatory=$true)]
        [int]$Size,

        [Parameter(Mandatory=$false)]
        [int]$SegSize,

        [Parameter(Mandatory=$false)]
        [bool]$DataAssuranceEnabled = $false,

        [Parameter(Mandatory=$false)]
        [ValidateSet("raid1","raid5","raid6","raid0")]
        [string]$RaidLevel,

        [Parameter(Mandatory=$false)]
        [array]$MetaTags,

        [Parameter(Mandatory=$false)]
        [int]$BlockSize
    )

    $SelectedPoolId = $null

    if ($PSCmdlet.ParameterSetName -eq "ById") {
        $SelectedPoolId = $PoolId
    }
    elseif ($PSCmdlet.ParameterSetName -eq "ByName") {
        # Resolve By Name
        Write-Verbose "Resolving pool name '$PoolName'..."
        $pools = Get-SANtricityStoragePool
        $matchedPool = $pools | Where-Object { 
            $_.label -eq $PoolName -or $_.name -eq $PoolName -or $_.volumeGroupName -eq $PoolName
        }
        if (-not $matchedPool) {
            throw "Storage pool with name '$PoolName' not found."
        }
        if ($matchedPool -is [array]) {
            throw "Multiple pools matched name '$PoolName'. Please use PoolId."
        }
        $SelectedPoolId = $matchedPool.id
    }
    elseif ($PSCmdlet.ParameterSetName -eq "Auto") {
        # Auto Selection Logic
        Write-Verbose "Auto-selecting storage pool..."
        $pools = Get-SANtricityStoragePool
        if (-not $pools) {
            throw "No storage pools found on the array."
        }

        # 2. Filter pools that can fit the requested size
        # Convert requested size to bytes for comparison check
        $reqBytes = 0
        switch ($SizeUnit) {
            "mb" { $reqBytes = $Size * 1MB }
            "gb" { $reqBytes = $Size * 1GB }
            "tb" { $reqBytes = $Size * 1TB }
        }
        
        $candidates = @()
        foreach ($p in $pools) {
             # freeSpace is typically a string in API response, cast to int64
             $free = if ($p.freeSpace) { [int64]$p.freeSpace } else { 0 }
             if ($free -ge $reqBytes) {
                 $candidates += $p
             }
        }

        if ($candidates.Count -eq 0) {
            throw "No storage pool has enough free space for $Size $SizeUnit."
        }

        # 3. Apply RAID Level filter if specified
        if ($RaidLevel) {
            $raidCandidates = @()
            foreach ($p in $candidates) {
                if ($p.raidLevel -eq $RaidLevel) {
                    $raidCandidates += $p
                } elseif ($p.diskPool -and ($RaidLevel -eq 'raid1' -or $RaidLevel -eq 'raid6')) {
                   # DDP normally simulates these protection levels
                   $raidCandidates += $p
                }
            }
            if ($raidCandidates.Count -eq 0) {
                throw "No storage pool with sufficient space supports RAID level '$RaidLevel'."
            }
            $candidates = $raidCandidates
        }

        # 4. Strict Selection: Prefer DDP, Fail if ambiguous
        $ddpCandidates = $candidates | Where-Object { $_.diskPool -eq $true }

        if ($candidates.Count -eq 1) {
            $SelectedPool = $candidates[0]
        } elseif ($ddpCandidates.Count -eq 1) {
            $SelectedPool = $ddpCandidates[0]
            Write-Verbose "Multiple candidate pools found, but only one DDP ($($SelectedPool.label)). Selected DDP as target."
        } else {
            $names = $candidates.label -join ', '
            throw "Automatic pool selection failed: Ambiguous match. Multiple suitable pools found ($names). Please specify -PoolName or -PoolId."
        }
        
        Write-Verbose "Auto-selected pool: $($SelectedPool.label) ($($SelectedPool.id))"
        $SelectedPoolId = $SelectedPool.id
    }

    # Prepare POST body
    $body = @{
        poolId = $SelectedPoolId
        name = $Name
        sizeUnit = $SizeUnit.ToLower()
        size = $Size
    }
    if ($PSBoundParameters.ContainsKey('SegSize')) {
        $body.segSize = $SegSize
    }
    if ($PSBoundParameters.ContainsKey('DataAssuranceEnabled')) {
        $body.dataAssuranceEnabled = $DataAssuranceEnabled
    }
    if ($RaidLevel) {
        $body.raidLevel = $RaidLevel
    }
    if ($MetaTags) {
        $body.metaTags = $MetaTags
    }
    if ($BlockSize) {
        $body.blockSize = $BlockSize
    }

    Write-Verbose "Creating volume '$Name' in pool '$SelectedPoolId'..."
    return Invoke-SANtricityRequest -Method 'POST' -Path '/volumes' -Body $body
}
