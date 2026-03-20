<#
.SYNOPSIS
Retrieves drives from the SANtricity storage system.

.DESCRIPTION
Gets a list of all physical drives in the system.

.PARAMETER Status
Filter drives by status (e.g., 'optimal').

.PARAMETER MediaPool
Filter drives by media pool.

.EXAMPLE
Get-SANtricityDrive
Get-SANtricityDrive -Status optimal
#>
function Get-SANtricityDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$Status
    )
    process {
        $drives = Invoke-SANtricityRequest -Method GET -Path '/drives'
        
        if ($Status) {
            $drives = $drives | Where-Object { $_.status -eq $Status }
        }
        
        return $drives
    }
}
