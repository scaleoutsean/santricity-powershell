<#
.SYNOPSIS
Updates properties of an existing volume.

.DESCRIPTION
Updates mutable properties of a volume, such as its name, cache settings, or media scan settings.
Supports merging arbitrary properties via -ExtraProperties for advanced usage.

.PARAMETER VolumeId
The ID (Ref) of the volume to update.

.PARAMETER VolumeName
The name of the volume to update (internally resolves to volume ID (volumeRef)).

.PARAMETER NewName
The new name for the volume.

.PARAMETER ReadCacheEnabled
Enable or disable read caching.

.PARAMETER WriteCacheEnabled
Enable or disable write caching.

.PARAMETER ReadAheadEnabled
Enable or disable read-ahead caching.

.PARAMETER CacheWithoutBatteries
Enable or disable caching when batteries are missing/failed (risky).

.PARAMETER MediaScanEnabled
Enable or disable background media scanning.

.PARAMETER ParityValidationEnabled
Enable or disable parity validation during media scans.

.PARAMETER FlashCacheEnabled
Enable or disable SSD Flash Cache for this volume. To enable, a valid SSD Flash Cache must already exist on the storage system.

.PARAMETER ExtraProperties
A hashtable of additional properties to merge into the request body.
Useful for setting properties not yet explicitly supported by cmdlet parameters.

.EXAMPLE
Set-SANtricityVolume -VolumeName "OldName" -NewName "NewName" -WriteCacheEnabled $true

.EXAMPLE
Set-SANtricityVolume -VolumeName "Database-LUN-1" -FlashCacheEnabled $true


.EXAMPLE
Set-SANtricityVolume -VolumeId "123" -ExtraProperties @{ "metaTags" = @( @{ "key"="k"; "value"="v" } ) }
#>
function Set-SANtricityVolume {
    [CmdletBinding(DefaultParameterSetName="ById")]
    param (
        # Identification
        [Parameter(Mandatory=$true, ParameterSetName="ById", Position=0)]
        [string]$VolumeId,

        [Parameter(Mandatory=$true, ParameterSetName="ByName")]
        [string]$VolumeName,

        # Modifiable Properties
        [Parameter(Mandatory=$false)]
        [string]$NewName,
        
        [Parameter(Mandatory=$false)]
        [bool]$ReadCacheEnabled,

        [Parameter(Mandatory=$false)]
        [bool]$WriteCacheEnabled,

        [Parameter(Mandatory=$false)]
        [bool]$ReadAheadEnabled,

        [Parameter(Mandatory=$false)]
        [bool]$CacheWithoutBatteries,

        [Parameter(Mandatory=$false)]
        [bool]$MediaScanEnabled,

        [Parameter(Mandatory=$false)]
        [bool]$ParityValidationEnabled,

        [Parameter(Mandatory=$false)]
        [bool]$FlashCacheEnabled,

        [Parameter(Mandatory=$false)]
        [hashtable]$ExtraProperties
    )

    process {
        # 1. Resolve Volume ID if Name provided
        if ($PSCmdlet.ParameterSetName -eq "ByName") {
            Write-Verbose "Resolving Volume Name '$VolumeName' to ID..."
            $vols = Get-SANtricityVolume
            $matched = $vols | Where-Object { $_.name -eq $VolumeName -or $_.label -eq $VolumeName }
            if (-not $matched) {
                throw "Volume '$VolumeName' not found."
            }
            if ($matched -is [array]) {
                # Try exact match
                $exact = $matched | Where-Object { $_.name -eq $VolumeName }
                if ($exact -and $exact.Count -eq 1) { $matched = $exact }
                else { throw "Multiple volumes matched name '$VolumeName'. Please use VolumeId." }
            }
            $VolumeId = $matched.id
        }

        # 2. Build Update Body
        $body = [ordered]@{}
        
        if ($PSBoundParameters.ContainsKey('NewName')) { 
            $body.name = $NewName 
        }

        # Cache Settings
        $cacheSettings = @{}
        if ($PSBoundParameters.ContainsKey('ReadCacheEnabled')) { $cacheSettings['readCacheEnable'] = $ReadCacheEnabled }
        if ($PSBoundParameters.ContainsKey('WriteCacheEnabled')) { $cacheSettings['writeCacheEnable'] = $WriteCacheEnabled }
        if ($PSBoundParameters.ContainsKey('ReadAheadEnabled')) { $cacheSettings['readAheadEnable'] = $ReadAheadEnabled }
        if ($PSBoundParameters.ContainsKey('CacheWithoutBatteries')) { $cacheSettings['cacheWithoutBatteries'] = $CacheWithoutBatteries }
        
        if ($cacheSettings.Count -gt 0) {
            $body['cacheSettings'] = $cacheSettings
        }

        # Scan Settings
        $scanSettings = @{}
        if ($PSBoundParameters.ContainsKey('MediaScanEnabled')) { $scanSettings['enable'] = $MediaScanEnabled }
        if ($PSBoundParameters.ContainsKey('ParityValidationEnabled')) { $scanSettings['parityValidationEnable'] = $ParityValidationEnabled }

        if ($scanSettings.Count -gt 0) {
            $body['scanSettings'] = $scanSettings
        }

        # Merge Extra Properties
        if ($ExtraProperties) {
            foreach ($key in $ExtraProperties.Keys) {
                $body[$key] = $ExtraProperties[$key]
            }
        }
        
        $baseResult = $null
        # If no properties to update, skip the base PUT/POST update
        if ($body.Keys.Count -gt 0) {
            Write-Verbose "Updated Volume $VolumeId with properties: $($body | ConvertTo-Json -Compress -Depth 10)"
            $baseResult = Invoke-SANtricityRequest -Method 'POST' -Path "/volumes/$VolumeId" -Body $body
        }

        # 3. Handle Flash Cache Enable/Disable (Symbol API)
        if ($PSBoundParameters.ContainsKey('FlashCacheEnabled')) {
            $fcResponse = $null
            if ($FlashCacheEnabled) {
                # Enabling Flash Cache requires finding the existing Flash Cache ID
                Write-Verbose "Enabling Flash Cache for Volume '$VolumeId'..."
                $cache = Get-SANtricityFlashCache | Select-Object -First 1
                if (-not $cache) {
                    Write-Warning "Could not enable Flash Cache on Volume '$VolumeId'. No Flash Cache exists on the storage system."
                } else {
                    $fcPayload = @{
                        volumeRef = $VolumeId
                        flashCacheRef = $cache.id
                    }
                    $fcResponse = Invoke-SANtricityRequest -Method POST -Path '/symbol/enableFlashCacheVolume?verboseErrorResponse=true' -Body $fcPayload
                    if ($fcResponse -ne 'ok') { Write-Warning "Failed to enable Flash Cache: $fcResponse" }
                }
            } else {
                # Disabling Flash Cache (only needs volumeRef)
                Write-Verbose "Disabling Flash Cache for Volume '$VolumeId'..."
                $fcPayload = "`"$VolumeId`""
                $fcResponse = Invoke-SANtricityRequest -Method POST -Path '/symbol/disableFlashCacheVolume?verboseErrorResponse=true' -Body $fcPayload
                if ($fcResponse -ne 'ok') { Write-Warning "Failed to disable Flash Cache: $fcResponse" }
            }
        }

        if (-not $baseResult) {
            # In case only flash cache was updated, refresh the volume state to return
            $baseResult = Invoke-SANtricityRequest -Method GET -Path "/volumes/$VolumeId"
        }

        return $baseResult
    }
}
