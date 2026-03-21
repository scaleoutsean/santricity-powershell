<#
.SYNOPSIS
Gets Snapshot Schedules from the SANtricity storage system.

.DESCRIPTION
Retrieves details about snapshot schedules, which map to specific source objects like Snapshot Groups or Consistency Groups. 
It supports pipeline input, so you can locate schedules bound to a specific snapshot group or consistency group by piping that object into this cmdlet.

.PARAMETER Id
Optional filter by Snapshot Schedule ID (schedRef).

.PARAMETER TargetObjectId
Optional filter by the ID of the object the schedule is attached to (such as a Snapshot Group ID or Consistency Group ID). 
Typically provided via pipeline.

.EXAMPLE
Get-SANtricitySnapshotSchedule

.EXAMPLE
Get-SANtricitySnapshotGroup -Name "MySnapGroup" | Get-SANtricitySnapshotSchedule
#>
function Get-SANtricitySnapshotSchedule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipelineByPropertyName=$true)]
        [Alias('schedRef')]
        [string]$Id,

        [Parameter(Mandatory=$false, ValueFromPipelineByPropertyName=$true)]
        [Alias('targetObject', 'pitGroupRef', 'cgRef', 'consistencyGroupId')]
        [string]$TargetObjectId
    )

    process {
        Write-Verbose "Querying SANtricity for Snapshot Schedules..."
        $schedules = Invoke-SANtricityRequest -Method GET -Path "/snapshot-schedules"

        if ($PSBoundParameters.ContainsKey('Id')) {
            $schedules = $schedules | Where-Object { $_.id -eq $Id -or $_.schedRef -eq $Id }
        }

        if ($PSBoundParameters.ContainsKey('TargetObjectId')) {
            $schedules = $schedules | Where-Object { $_.targetObject -eq $TargetObjectId }
        }

        $schedules | Select-Object schedRef, scheduleStatus, action, targetObject, creationTime, lastRunTime, nextRunTime, @{N='schedule';E={$_.schedule.calendar.scheduleMethod}}, id
    }
}
