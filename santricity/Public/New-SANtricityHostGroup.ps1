<#
.SYNOPSIS
Creates a new Host Group (Cluster).

.DESCRIPTION
Creates a new Host Group container for grouping hosts.

.PARAMETER Name
The name of the new Host Group.

.PARAMETER HostId
Optional list of Host IDs (Refs) to initially add to this group.

.EXAMPLE
New-SANtricityHostGroup -Name "Cluster-A"

.EXAMPLE
New-SANtricityHostGroup -Name "Cluster-B" -HostId "HOST_REF_1", "HOST_REF_2"
#>
function New-SANtricityHostGroup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Name,

        [Parameter(Mandatory=$false)]
        [string[]]$HostId
    )

    process {
        # 1. Build Request Body
        $body = [ordered]@{
            name = $Name
            hosts = if ($HostId) { $HostId } else { @() }
        }

        Write-Verbose "Creating Host Group '$Name'..."
        
        # 2. Call API
        return Invoke-SANtricityRequest -Method POST -Path '/host-groups' -Body $body
    }
}
