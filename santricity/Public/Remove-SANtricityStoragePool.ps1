<#
.SYNOPSIS
Deletes a SANtricity Storage Pool.

.DESCRIPTION
Removes a Storage Pool from the storage array.
**Safety**: Checks for existing volumes and active mappings on those volumes before deletion.
If volumes exist, the deletion is blocked unless -Force is specified.
Note: Deleting a pool implicitly deletes all volumes within it on most firmware versions.

.PARAMETER PoolId
The ID (Ref) of the Storage Pool to remove.

.PARAMETER PoolName
The name of the Storage Pool to remove.

.PARAMETER Force
Deletes the pool even if it contains volumes or active mappings.

.EXAMPLE
Remove-SANtricityStoragePool -PoolName "Pool_1"
#>
function Remove-SANtricityStoragePool {
    [CmdletBinding(DefaultParameterSetName="ById", SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true, ParameterSetName="ById", Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias("id", "StoragePoolRef")]
        [string]$PoolId,

        [Parameter(Mandatory=$true, ParameterSetName="ByName")]
        [string]$PoolName,

        [switch]$Force
    )

    process {
        # 1. Resolve Pool
        if ($PSCmdlet.ParameterSetName -eq "ByName") {
            Write-Verbose "Resolving Pool Name '$PoolName'..."
            $pools = Get-SANtricityStoragePool
            $matched = $pools | Where-Object { $_.name -eq $PoolName -or $_.label -eq $PoolName }
            
            if (-not $matched) { throw "Storage Pool '$PoolName' not found." }
            if ($matched -is [array]) {
                 # Exact match check
                 $exact = $matched | Where-Object { $_.name -eq $PoolName }
                 if ($exact -and $exact.Count -eq 1) { $matched = $exact }
                 else { throw "Multiple storage pools matched '$PoolName'." }
            }
            $PoolId = $matched.id
            Write-Verbose "Resolved Pool '$PoolName' to ID: $PoolId"
        }

        # 2. Safety Checks (Volume and Mapping dependencies)
        Write-Verbose "Checking for volumes in pool '$PoolId'..."
        
        # Get all volumes (optimization: could filter at API level if supported, but typically client-side for this module)
        $allVolumes = Get-SANtricityVolume
        $poolVolumes = $allVolumes | Where-Object { $_.volumeGroupRef -eq $PoolId }

        if ($poolVolumes) {
            $volCount = if ($poolVolumes -is [array]) { $poolVolumes.Count } else { 1 }
            $volIds = if ($poolVolumes -is [array]) { $poolVolumes.id } else { $poolVolumes.id }
            
            # Check for Mappings on these volumes
            Write-Verbose "Volumes found. Checking for active mappings..."
            $allMappings = Get-SANtricityVolumeMapping
            
            # Filter mappings where map.volumeRef matches any of our pool volumes
            # $volIds might be a single string or an array
            $activeMappings = $allMappings | Where-Object { 
                $vRef = $_.volumeRef; 
                # Handle array or single id comparison
                if ($volIds -is [array]) { $volIds -contains $vRef } else { $volIds -eq $vRef }
            }
            
            $mapCount = if ($activeMappings) { 
                if ($activeMappings -is [array]) { $activeMappings.Count } else { 1 } 
            } else { 0 }

            if (-not $Force) {
                $errDetails = "Pool contains $volCount volume(s)"
                if ($mapCount -gt 0) {
                    $errDetails += " and $mapCount active volume mapping(s)"
                }
                
                $msg = "Cannot delete Storage Pool '$PoolId'. $errDetails. This operation would destroy all data on these volumes. Use -Force to delete anyway."
                
                $ex = [System.InvalidOperationException]::new($msg)
                $CategoryInfo = [System.Management.Automation.ErrorCategory]::ResourceBusy
                $ErrorRecord = [System.Management.Automation.ErrorRecord]::new($ex, "StoragePoolHasVolumes", $CategoryInfo, $PoolId)
                $PSCmdlet.ThrowTerminatingError($ErrorRecord)
            } else {
                Write-Warning "Deleting Pool '$PoolId' containing $volCount volume(s) and $mapCount mapping(s). Data will be lost."
            }
        }

        # 3. Execution
        if ($PSCmdlet.ShouldProcess("Storage Pool $PoolId", "Remove-SANtricityStoragePool")) {
             # We rely on default behavior (delete volumes) since user has been warned/Forced
             Invoke-SANtricityRequest -Method DELETE -Path "/storage-pools/$PoolId"
        }
    }
}
