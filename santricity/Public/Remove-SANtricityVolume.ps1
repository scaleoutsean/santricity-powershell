<#
.SYNOPSIS
Deletes a SANtricity volume.

.DESCRIPTION
Removes a volume from the storage array.
Checks for active volume mappings before deletion to prevent accidental data loss.
Use -Force to delete a volume that is currently mapped.

.PARAMETER VolumeId
The ID (Ref) of the volume to remove.

.PARAMETER VolumeName
The name of the volume to remove.

.PARAMETER Force
Deletes the volume even if it has active mappings.

.EXAMPLE
Remove-SANtricityVolume -VolumeName "TestVol"
#>
function Remove-SANtricityVolume {
    [CmdletBinding(DefaultParameterSetName="ById", SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true, ParameterSetName="ById", Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias("id", "VolumeRef")]
        [string]$VolumeId,

        [Parameter(Mandatory=$true, ParameterSetName="ByName")]
        [string]$VolumeName,

        [switch]$Force
    )

    process {
        # 1. Resolve Volume
        if ($PSCmdlet.ParameterSetName -eq "ByName") {
            Write-Verbose "Resolving Volume Name '$VolumeName'..."
            $vols = Get-SANtricityVolumes
            $matched = $vols | Where-Object { $_.name -eq $VolumeName -or $_.label -eq $VolumeName }
            
            if (-not $matched) { throw "Volume '$VolumeName' not found." }
            if ($matched -is [array]) {
                 $exact = $matched | Where-Object { $_.name -eq $VolumeName }
                 if ($exact -and $exact.Count -eq 1) { $matched = $exact }
                 else { throw "Multiple volumes matched '$VolumeName'." }
            }
            $VolumeId = $matched.id
        }

        # 2. Check for dependencies (Mappings)
        Write-Verbose "Checking for active mappings..."
        $allMappings = Get-SANtricityVolumeMappings
        $activeMappings = $allMappings | Where-Object { $_.volumeRef -eq $VolumeId -or $_.mappableObjectId -eq $VolumeId }

        if ($activeMappings) {
            $count = if ($activeMappings -is [array]) { $activeMappings.Count } else { 1 }
            if (-not $Force) {
                $msg = "Volume '$VolumeId' has $count active mapping(s). Use -Force to delete anyway."
                $ex = [System.InvalidOperationException]::new($msg)
                $CategoryInfo = [System.Management.Automation.ErrorCategory]::ResourceBusy
                $ErrorRecord = [System.Management.Automation.ErrorRecord]::new($ex, "VolumeIsMapped", $CategoryInfo, $VolumeId)
                $PSCmdlet.ThrowTerminatingError($ErrorRecord)
            } else {
                Write-Warning "Deleting volume '$VolumeId' which has $count active mapping(s)."
            }
        }

        if ($PSCmdlet.ShouldProcess("Volume $VolumeId", "Remove-SANtricityVolume")) {
             Invoke-SANtricityRequest -Method DELETE -Path "/volumes/$VolumeId"
        }
    }
}
