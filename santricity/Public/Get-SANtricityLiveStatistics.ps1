function Get-SANtricityLiveStatistics {
    <#
    .SYNOPSIS
    Retrieves live SANtricity statistics.

    .DESCRIPTION
    Calls the SANtricity /live-statistics endpoint. When -Type is omitted the endpoint
    returns a full aggregate object that includes systemStats and interfaceStats (these
    two fields return null when requested individually via -Type). When -Type is
    provided the response is the typed array for that object class.

    For two-sample delta calculations, do not assume a fixed client wait interval.
    Use observedTimeInMS (or observedTime) values returned by SANtricity to determine
    the true elapsed interval, then normalize counters by that measured interval.

    .PARAMETER Type
    Optional statistics type. Allowed values: drive, controller, volume.
    Omit to receive the full aggregate response (includes systemStats, interfaceStats).
    Note: 'system' and 'interface' are not valid -Type arguments — access those fields
    from the aggregate response instead.

    .EXAMPLE
    Get-SANtricityLiveStatistics

    .EXAMPLE
    (Get-SANtricityLiveStatistics).systemStats

    .EXAMPLE
    Get-SANtricityLiveStatistics -Type controller

    .EXAMPLE
    Get-SANtricityLiveStatistics -Type volume

    .EXAMPLE
    $a = (Get-SANtricityLiveStatistics).systemStats
    Start-Sleep -Seconds 60
    $b = (Get-SANtricityLiveStatistics).systemStats
    $dt = [math]::Max(1, [math]::Round((([long]$b.observedTimeInMS - [long]$a.observedTimeInMS) / 1000), 0))
    [int](($b.totalIopsServiced - $a.totalIopsServiced) / $dt)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('drive', 'controller', 'volume')]
        [string]$Type
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Type)) {
            return Invoke-SANtricityRequest -Method 'GET' -Path '/live-statistics'
        }
        $normalizedType = $Type.ToLowerInvariant()
        return Invoke-SANtricityRequest -Method 'GET' -Path "/live-statistics?type=$normalizedType"
    }
}
