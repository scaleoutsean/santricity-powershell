
<#
    .SYNOPSIS
    Retrieve host definitions from the SANtricity API.

    .DESCRIPTION
    Calls the controller's hosts endpoint and returns host objects.
    Supports client-side filtering by Name, Port, and HostType.

    .PARAMETER Name
    Filter by Host Name (wildcards supported).

    .PARAMETER Port
    Filter by Port address (IQN, WWN, NQN). Wildcards supported.
    Checks 'ports' (iSCSI/FC/SAS) and 'initiators' (NVMe) lists.

    .PARAMETER HostTypeIndex
    Filter by Host Type Index (integer).
#>
function Get-SANtricityHost {
    [CmdletBinding()]
    param (
        [Parameter(Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [string]$Name,
        
        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string]$Port,

        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [int]$HostTypeIndex
    )

    process {
        $allHosts = Invoke-SANtricityRequest -Method 'GET' -Path '/hosts'

        if ($null -eq $allHosts) { return }

        foreach ($hostObj in $allHosts) {
            $match = $true

            # Filter by Name
            if ($PSBoundParameters.ContainsKey('Name') -and -not [string]::IsNullOrWhiteSpace($Name)) {
                if ($hostObj.name -notlike $Name) { $match = $false }
            }

            # Filter by HostTypeIndex
            if ($match -and $PSBoundParameters.ContainsKey('HostTypeIndex')) {
                # Some API versions return hostType as an object { index: 28 }, others might be flat.
                # Adapting to check both just in case, but standard is hostType.index.
                $idx = if ($hostObj.hostType -is [PSCustomObject] -or $hostObj.hostType -is [System.Collections.IDictionary]) { 
                    $hostObj.hostType.index 
                } else { 
                    $hostObj.hostType 
                }
                
                if ($idx -ne $HostTypeIndex) { $match = $false }
            }

            # Filter by Port
            if ($match -and $PSBoundParameters.ContainsKey('Port') -and -not [string]::IsNullOrWhiteSpace($Port)) {
                $portFound = $false
                
                # Check standard ports list (iSCSI, FC)
                if ($hostObj.ports) {
                    foreach ($p in $hostObj.ports) {
                        # $p might be a string or object with 'label'/'port' etc.
                        # Usually it is an object with 'port' property (the address).
                        $addr = if ($p.port) { $p.port } else { $p }
                        if ($addr -like $Port) { 
                            $portFound = $true
                            break 
                        }
                    }
                }

                # Check initiators list (NVMe)
                if (-not $portFound -and $hostObj.initiators) {
                    foreach ($init in $hostObj.initiators) {
                        # structure: init -> nodeName -> nvmeNodeName (NQN)
                        $nqn = if ($init.nodeName -and $init.nodeName.nvmeNodeName) {
                            $init.nodeName.nvmeNodeName
                        } else { $null }
                        
                        if ($nqn -and $nqn -like $Port) {
                            $portFound = $true
                            break
                        }
                    }
                }

                if (-not $portFound) { $match = $false }
            }
            
            if ($match) { $hostObj }
        }
    }
}
