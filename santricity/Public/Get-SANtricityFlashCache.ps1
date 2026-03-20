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

.PARAMETER ResolveNames
If specified, fetches all volumes and drives and adds 'cachedVolumeNames' and 'driveNames' arrays mapping the IDs to their actual names/labels.

.EXAMPLE
Get-SANtricityFlashCache -ResolveNames
#>
function Get-SANtricityFlashCache {
    [CmdletBinding(DefaultParameterSetName='All')]
    param(
        [Parameter(Mandatory=$false, ParameterSetName='ById')]
        [string]$Id,

        [Parameter(Mandatory=$false, ParameterSetName='ByName')]
        [string]$Name,

        [Parameter()]
        [switch]$ResolveNames
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

        if ($ResolveNames.IsPresent -and $caches) {
            Write-Verbose "Resolving names for cached volumes and drive references..."
            $allVolumes = Invoke-SANtricityRequest -Method GET -Path "/volumes"
            $allDrives = Invoke-SANtricityRequest -Method GET -Path "/drives"

            # Create fast lookup tables
            $volMap = @{}
            foreach ($v in $allVolumes) { $volMap[$v.id] = $v.name }

            $driveMap = @{}
            foreach ($d in $allDrives) { 
                # Create a readable drive label based on physical location if available (e.g. Tray:Slot)
                $label = "Drive-$($d.id)"
                if ($d.physicalLocation) {
                    $label = "Tray:$($d.physicalLocation.trayRef) Slot:$($d.physicalLocation.slot)"
                }
                $driveMap[$d.id] = $label
            }

            foreach ($cache in $caches) {
                # Add synthetic array properties containing actual names
                $cache | Add-Member -MemberType NoteProperty -Name "cachedVolumeNames" -Value @()
                foreach ($cv in $cache.cachedVolumes) {
                    if ($volMap.ContainsKey($cv)) {
                        $cache.cachedVolumeNames += $volMap[$cv]
                    }
                }

                $cache | Add-Member -MemberType NoteProperty -Name "driveNames" -Value @()
                foreach ($dr in $cache.driveRefs) {
                    if ($driveMap.ContainsKey($dr)) {
                        $cache.driveNames += $driveMap[$dr]
                    }
                }
            }
        }

        $caches
    }
}
