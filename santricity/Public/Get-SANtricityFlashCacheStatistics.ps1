<#
.SYNOPSIS
Gets statistics for the SSD Flash Cache.

.DESCRIPTION
Retrieves counters and gauge statistics for the read-only cache layer, such as cache hits, misses, IOPS, and populated bytes.
Uses the internal Symbol API endpoint /symbol/getFlashCacheStatistics.

.PARAMETER Id
The Flash Cache reference ID (flashCacheRef) to retrieve statistics for. If not provided, the cmdlet will automatically query the system for an existing Flash Cache and use its ID.

.PARAMETER Gauges
Include gauge metrics (absolute values: availableBytes, allocatedBytes, populatedCleanBytes, populatedDirtyBytes). 
If neither -Gauges nor -Counters is specified, all metrics are returned.

.PARAMETER Counters
Include counter metrics (cumulative values: reads, writes, hits, misses, etc).
If neither -Gauges nor -Counters is specified, all metrics are returned.

.PARAMETER Interval
If specified alongside counters, the cmdlet will sleep for the specified duration (in seconds) and calculate the per-second rate of the counters. Gauges will just reflect the final sampled state.

.EXAMPLE
Get-SANtricityFlashCacheStatistics -Gauges

.EXAMPLE
Get-SANtricityFlashCacheStatistics -Counters -Interval 10
#>
function Get-SANtricityFlashCacheStatistics {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias('flashCacheRef')]
        [string]$Id,

        [Parameter()]
        [switch]$Gauges,

        [Parameter()]
        [switch]$Counters,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$Interval
    )

    process {
        if (-not $Id) {
            Write-Verbose "Flash Cache ID not provided. Querying system for existing Flash Cache..."
            $cache = Get-SANtricityFlashCache | Select-Object -First 1
            if (-not $cache) {
                Write-Warning "No Flash Cache found on the current storage system."
                return
            }
            $Id = $cache.id
        }

        # If neither explicitly given, default to both
        $returnGauges = $Gauges.IsPresent -or (-not $Gauges.IsPresent -and -not $Counters.IsPresent)
        $returnCounters = $Counters.IsPresent -or (-not $Gauges.IsPresent -and -not $Counters.IsPresent)

        $gaugeNames = @('availableBytes', 'allocatedBytes', 'populatedCleanBytes', 'populatedDirtyBytes')
        $counterNames = @('reads', 'readBlocks', 'writes', 'writeBlocks', 'fullCacheHits', 
            'fullCacheHitBlocks', 'partialCacheHits', 'partialCacheHitBlocks', 'completeCacheMiss', 
            'completeCacheMissBlocks', 'populateOnReads', 'populateOnReadBlocks', 'populateOnWrites', 
            'populateOnWriteBlocks', 'invalidates', 'recycles')

        $path = "/symbol/getFlashCacheStatistics?verboseErrorResponse=true&controller=auto"
        $payload = "`"$Id`""

        Write-Verbose "Querying initial statistics for Flash Cache ID: $Id"
        $resp1 = Invoke-SANtricityRequest -Method POST -Path $path -Body $payload -ErrorAction Stop

        if ($resp1.returnCode -ne 'ok') {
            Write-Warning "Failed to get Flash Cache statistics. Return code: $($resp1.returnCode)"
            return $resp1
        }
        $stats1 = $resp1.flashCacheStatistics

        $stats2 = $stats1
        $actualInterval = 1
        
        if ($Interval -gt 0) {
            Write-Verbose "Sleeping for $Interval seconds to calculate counter rates..."
            Start-Sleep -Seconds $Interval
            $resp2 = Invoke-SANtricityRequest -Method POST -Path $path -Body $payload -ErrorAction Stop
            if ($resp2.returnCode -eq 'ok') {
                $stats2 = $resp2.flashCacheStatistics
                # Protect against timestamp weirdness in case it's millisecond vs seconds, though SYMbol uses seconds natively
                if ($stats2.timestamp -and $stats1.timestamp -and ($stats2.timestamp -ne $stats1.timestamp)) {
                    $actualInterval = [long]$stats2.timestamp - [long]$stats1.timestamp
                } else {
                    $actualInterval = $Interval
                }
                $actualInterval = [math]::Max(1, $actualInterval)
            }
        }

        $resultObj = [ordered]@{}
        $resultObj['timestamp'] = $stats2.timestamp
        $resultObj['intervalSeconds'] = if ($Interval -gt 0) { $actualInterval } else { 0 }

        if ($returnGauges) {
            foreach ($g in $gaugeNames) {
                $resultObj[$g] = [long]($stats2.$g)
            }
        }

        if ($returnCounters) {
            foreach ($c in $counterNames) {
                if ($Interval -gt 0) {
                    # Rate per second calculation
                    $diff = [long]($stats2.$c) - [long]($stats1.$c)
                    $rate = [math]::Round($diff / $actualInterval, 2)
                    $resultObj["$($c)PerSecond"] = $rate
                } else {
                    $resultObj[$c] = [long]($stats1.$c)
                }
            }
        }

        return [PSCustomObject]$resultObj
    }
}
