<#
.SYNOPSIS
Gets the SSD Flash Cache configuration from the SANtricity storage system.

.DESCRIPTION
Retrieves details about the SSD Flash Cache (read-only caching layer), including its capacity, state, associated drives, and cached volumes.
Note that there can be at most one Flash Cache per storage system.

.PARAMETER Id
Optional filter by Flash Cache ID (flashCacheRef or id).

.PARAMETER Name
Optional filter by Flash Cache Name (label).

.EXAMPLE
Get-SANtricityFlashCache
#>
function Get-SANtricityFlashCache {
    [CmdletBinding(DefaultParameterSetName='All')]
    param(
        [Parameter(Mandatory=$false, ParameterSetName='ById')]
        [string]$Id,

        [Parameter(Mandatory=$false, ParameterSetName='ByName')]
        [string]$Name
    )

    process {
        Write-Verbose "Querying the SANtricity storage system for Flash Cache configuration..."
        $caches = Invoke-SANtricityRequest -Method GET -Path "/flash-cache"

        if ($PSBoundParameters.ContainsKey('Id')) {
            $caches = $caches | Where-Object { $_.id -eq $Id -or $_.flashCacheRef -eq $Id }
        }
        if ($PSBoundParameters.ContainsKey('Name')) {
            $caches = $caches | Where-Object { $_.name -match $Name -or $_.flashCacheBase.label -match $Name }
        }

        $caches
    }
}
