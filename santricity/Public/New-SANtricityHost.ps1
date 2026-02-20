<#
.SYNOPSIS
Creates a new Host in SANtricity.

.DESCRIPTION
Creates a new Host definition, optionally setting its Host Type and adding interface ports (iSCSI IQNs, FC WWNs, or NVMe NQNs).

.PARAMETER Name
The name of the new Host.

.PARAMETER Port
One or more port identifiers (IQN, WWN, or NQN) to associate with this host.
If provided, the port type is inferred from the format (iqn.*/eui.* -> iscsi, nqn.* -> nvmeof, else -> iscsi).

.PARAMETER HostTypeIndex
The operating system type index for the host (default: 28 for Linux).
Common values: 0 (Windows), 1 (Linux DM-MP), 28 (Linux), etc.

.PARAMETER HostGroupId
Optional ID (Ref) of a Host Group to add this host to.

.PARAMETER ChapSecret
Optional CHAP secret for iSCSI ports. Applied to all ports specified if type is iSCSI.

.EXAMPLE
New-SANtricityHost -Name "ESX01" -Port "iqn.1998-01.com.vmware:esx01-123456"

.EXAMPLE
New-SANtricityHost -Name "LinuxDB" -Port @("iqn.1994-05.com.redhat:01", "iqn.1994-05.com.redhat:02") -HostTypeIndex 28
#>
function New-SANtricityHost {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Name,

        [Parameter(Mandatory=$false)]
        [string[]]$Port,

        [Parameter(Mandatory=$false)]
        [int]$HostTypeIndex = 28,

        [Parameter(Mandatory=$false)]
        [string]$HostGroupId,

        [Parameter(Mandatory=$false)]
        [string]$ChapSecret
    )

    process {
        # 1. Build Ports Array
        $portsList = @()
        
        if ($Port) {
            $counter = 1
            foreach ($p in $Port) {
                $p = $p.Trim()
                if ([string]::IsNullOrWhiteSpace($p)) { continue }

                # Port Label Logic: User noted quirk where label must be Name_N
                $portLabel = "${Name}_${counter}"
                
                # Infer Type
                if ($p.StartsWith("iqn.", [System.StringComparison]::InvariantCultureIgnoreCase) -or 
                    $p.StartsWith("eui.", [System.StringComparison]::InvariantCultureIgnoreCase)) {
                    $type = "iscsi"
                } elseif ($p.StartsWith("nqn.", [System.StringComparison]::InvariantCultureIgnoreCase)) {
                    $type = "nvmeof" 
                } else {
                    $type = "iscsi" # Default to iSCSI as per user environment preference
                }

                $portObj = [ordered]@{
                    type = $type
                    port = $p
                    label = $portLabel
                }

                if ($type -eq "iscsi" -and -not [string]::IsNullOrWhiteSpace($ChapSecret)) {
                    $portObj["iscsiChapSecret"] = $ChapSecret
                }
                
                $portsList += $portObj
                $counter++
            }
        }

        # 2. Build Request Body
        $body = [ordered]@{
            name = $Name
            hostType = @{ index = $HostTypeIndex }
            ports = $portsList
            groupId = if ($HostGroupId) { $HostGroupId } else { "0000000000000000000000000000000000000000" } 
        }

        Write-Verbose "Creating Host '$Name' with $($portsList.Count) ports (Type Index: $HostTypeIndex)..."
        
        # 3. Call API
        return Invoke-SANtricityRequest -Method POST -Path '/hosts' -Body $body
    }
}
