function New-SANtricityConsistencyGroup {
    <#
    .SYNOPSIS
    Creates a new multi-volume Consistency Group (CG).

    .DESCRIPTION
    Creates a Consistency Group (CG) which is a container for multiple snapshot volumes (Snapshot Groups)
    that can be snapshotted atomically (e.g. for database log+data consistency).
    
    You can specify one or more member volumes to add immediately upon creation.
    When adding members, repository volumes are automatically created for each member.

    .PARAMETER Name
    The name of the new Consistency Group.

    .PARAMETER VolumeId
    Array of volume IDs (Refs) to add as members immediately. Optional.

    .PARAMETER VolumeName
    Array of volume names to add as members immediately. Normalized to IDs internally.

    .PARAMETER RepositoryPercentage
    Percentage of each base volume capacity to allocate for its repository (default 20).
    Only used if member volumes are specified.

    .PARAMETER WarningThreshold
    Warning threshold for repository utilization (default 80).
    Only used if member volumes are specified.
    
    .PARAMETER AutoDeleteLimit
    Number of snapshots to keep (default 30).
    Only used if member volumes are specified.

    .EXAMPLE
    New-SANtricityConsistencyGroup -Name "OracleCG" -VolumeName "DataVol","LogVol"
    #>
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$Name,

        [Parameter(ParameterSetName = 'Default')]
        [string[]]$VolumeId,

        [Parameter(ParameterSetName = 'ByVolumeName')]
        [string[]]$VolumeName,

        [int]$RepositoryPercentage = 20,
        [int]$WarningThreshold = 80,
        [int]$AutoDeleteLimit = 30
    )

    process {
        # 1. Resolve Volumes
        $ResolvedVolumeIds = @()

        if ($PSCmdlet.ParameterSetName -eq 'ByVolumeName' -and $VolumeName) {
            foreach ($vn in $VolumeName) {
                $vol = Get-SANtricityVolume | Where-Object { $_.label -eq $vn }
                if (-not $vol) {
                    throw "Volume with name '$vn' not found."
                }
                $ResolvedVolumeIds += $vol.id
            }
        } elseif ($VolumeId) {
            $ResolvedVolumeIds = $VolumeId
        }

        # 2. Check Exists
        $existing = Get-SANtricityConsistencyGroup -Name $Name
        if ($existing) {
            # Filter out any objects that might be empty or missing an ID
            $validExisting = @($existing) | Where-Object { -not [string]::IsNullOrWhiteSpace($_.id) }
            
            if ($validExisting.Count -gt 1) {
                Write-Warning "Multiple Consistency Groups found with name '$Name'. Using the first valid one."
                $cg = $validExisting | Select-Object -First 1
            } elseif ($validExisting.Count -eq 1) {
                $cg = $validExisting[0]
            } else {
                # Fallback if filtering removed everything (shouldn't happen if name matched)
                $cg = $existing | Select-Object -First 1
            }

            Write-Warning "Consistency Group '$Name' already exists."
            Write-Warning "Existing CG ID: $($existing.id), CG Name: $($existing.name). Member Volumes: $($existing.memberVolumeCount)"
            # If volumes are provided, we should probably ensure they are added to the existing group
            if ($ResolvedVolumeIds.Count -gt 0) {
                Write-Verbose "Adding $($ResolvedVolumeIds.Count) member volumes to existing CG '$Name'..."
                $cg = $existing
                # Check current members first to avoid re-adding (optional but good)
                # GET /consistency-groups/{id}/member-volumes
                # For now, we trust the add loop to handle duplicates or just try adding them.
                # Just fall through to add logic.
            } else {
                return $existing
            }
        } else {
             # 3. Create Empty CG (Endpoint: /consistency-groups)
            $cgPayload = @{
                name = $Name
                fullPolicy = "purgepit" # Default behavior for CGs too
                rollbackPriority = "highest" # Default priority for rollbacks
            }

            Write-Verbose "Creating empty Consistency Group '$Name'..."
            $cg = Invoke-SANtricityRequest -Method 'POST' -Path '/consistency-groups' -Body $cgPayload
            
            if (-not $cg) { throw "Failed to create Consistency Group." }
            
            # The API returns a single object on POST.
            # But just in case invoke-request wraps it or returns list, we handle it.
            if ($null -ne $cg -and $cg.GetType().IsArray) {
                 # The API might return an array with nulls, e.g. [null, null, object] or just [object]
                 # Filter for the first non-null object with an ID
                 $validObjs = @($cg) | Where-Object { $null -ne $_ -and $null -ne $_.id }
                 if ($validObjs.Count -gt 0) {
                     $cg = $validObjs[0]
                 } else {
                     # Fallback to pure index 0 if filtering failed, though likely doomed
                     $cg = $cg[0]
                 }
            }
        }

        # 4. Add Member Volumes (if any)
        if ($ResolvedVolumeIds.Count -gt 0) {
            Write-Verbose "Adding $($ResolvedVolumeIds.Count) member volumes to CG '$Name'..."
            
            foreach ($vid in $ResolvedVolumeIds) {
                # Construct payload for individual add
                # Endpoint: POST /consistency-groups/{id}/member-volumes
                # Payload: { volumeId: "...", repositoryPercent: 20 }
                $payload = @{
                    volumeId = $vid
                    repositoryPercent = $RepositoryPercentage
                }

                $maxRetries = 3
                $success = $false
                
                # Ensure we have a single ID
                $targetId = if ($cg -is [array]) { $cg[0].id } else { $cg.id }
                
                for ($i = 0; $i -lt $maxRetries; $i++) {
                    try {
                        Invoke-SANtricityRequest -Method 'POST' -Path "/consistency-groups/$targetId/member-volumes" -Body $payload -ErrorAction Stop | Out-Null
                        $success = $true
                        break
                    } catch {
                         Write-Verbose "Attempt $($i+1) to add volume $vid failed: $_. Retrying in 5 seconds..."
                         Start-Sleep -Seconds 5
                    }
                }
                
                if (-not $success) {
                    Write-Error "Failed to add volume $vid to CG after $maxRetries attempts."
                }
            }
        }
        
        # Return the object we already have/updated (no need to re-fetch if we trust $cg or refreshed it)
        # But to be safe and get the latest state including member counts:
        return Get-SANtricityConsistencyGroup -Id $cg.id
    }
}
