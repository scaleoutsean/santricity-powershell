<#
.SYNOPSIS
Deletes a SANtricity Host Group (Cluster).

.DESCRIPTION
Removes a Host Group from the storage array.
**Safety**: Checks for active mappings and existing hosts within the group before deletion.
If hosts exist, the deletion is blocked unless -Force is specified (which will delete the hosts as well).

.PARAMETER HostGroupId
The ID (Ref) of the Host Group to remove.

.PARAMETER HostGroupName
The name of the Host Group to remove.

.PARAMETER Force
Deletes the Host Group even if it contains Hosts or has active mappings.
**WARNING**: This will also delete all Hosts contained in this group.

.EXAMPLE
Remove-SANtricityHostGroup -HostGroupName "Cluster-A"
#>
function Remove-SANtricityHostGroup {
    [CmdletBinding(DefaultParameterSetName="ById", SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true, ParameterSetName="ById", Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias("id", "ClusterRef", "HostGroupRef")]
        [string]$HostGroupId,

        [Parameter(Mandatory=$true, ParameterSetName="ByName")]
        [string]$HostGroupName,

        [switch]$Force
    )

    process {
        # 1. Resolve Host Group
        if ($PSCmdlet.ParameterSetName -eq "ByName") {
            Write-Verbose "Resolving Host Group Name '$HostGroupName'..."
            $groups = Get-SANtricityHostGroup
            $matched = $groups | Where-Object { $_.name -eq $HostGroupName -or $_.label -eq $HostGroupName }
            
            if (-not $matched) { throw "Host Group '$HostGroupName' not found." }
            if ($matched -is [array]) {
                 # Exact match check
                 $exact = $matched | Where-Object { $_.name -eq $HostGroupName }
                 if ($exact -and $exact.Count -eq 1) { $matched = $exact }
                 else { throw "Multiple host groups matched '$HostGroupName'. Please use HostGroupId." }
            }
            $HostGroupId = $matched.id
        }

        # 2. Safety Checks (Members and Mappings)
        Write-Verbose "Checking for hosts in group '$HostGroupId'..."
        
        $allHosts = Get-SANtricityHost
        $memberHosts = $allHosts | Where-Object { $_.clusterRef -eq $HostGroupId }
        
        $hostCount = if ($memberHosts) { 
            if ($memberHosts -is [array]) { $memberHosts.Count } else { 1 } 
        } else { 0 }

        # Check for Mappings (Directly onto the Cluster object)
        Write-Verbose "Checking for active mappings on Host Group '$HostGroupId'..."
        $allMappings = Get-SANtricityVolumeMapping
        $clusterMappings = $allMappings | Where-Object { ($_.mapRef -eq $HostGroupId -or $_.targetId -eq $HostGroupId) }
        
        $mapCount = if ($clusterMappings) {
            if ($clusterMappings -is [array]) { $clusterMappings.Count } else { 1 }
        } else { 0 }

        if (($hostCount -gt 0 -or $mapCount -gt 0) -and -not $Force) {
            $errDetails = ""
            if ($hostCount -gt 0) { $errDetails += "$hostCount member host(s)" }
            if ($hostCount -gt 0 -and $mapCount -gt 0) { $errDetails += " and " }
            if ($mapCount -gt 0) { $errDetails += "$mapCount active mapping(s)" }

            $msg = "Cannot delete Host Group '$HostGroupId'. It contains $errDetails. Deleting it will also delete all member hosts. Use -Force to delete anyway."
            
            $ex = [System.InvalidOperationException]::new($msg)
            $CategoryInfo = [System.Management.Automation.ErrorCategory]::ResourceBusy
            $ErrorRecord = [System.Management.Automation.ErrorRecord]::new($ex, "HostGroupNotEmpty", $CategoryInfo, $HostGroupId)
            $PSCmdlet.ThrowTerminatingError($ErrorRecord)
        } elseif ($hostCount -gt 0) {
             Write-Warning "Deleting Host Group '$HostGroupId' which contains $hostCount host(s). Member hosts will also be deleted."
        }

        # 3. Execution (DELETE host-groups/{id})
        if ($PSCmdlet.ShouldProcess("Host Group $HostGroupId", "Remove-SANtricityHostGroup")) {
             Invoke-SANtricityRequest -Method DELETE -Path "/host-groups/$HostGroupId"
        }
    }
}
