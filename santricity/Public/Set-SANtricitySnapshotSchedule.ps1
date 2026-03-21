<#
.SYNOPSIS
Suspends or Resumes a SANtricity Snapshot Schedule.

.DESCRIPTION
Enables or disables an existing snapshot schedule. Because modifying a schedule through the API requires
posting the entire schedule template back, this cmdlet gracefully resolves the existing schedule,
updates strictly the `enabled` field, and posts it via the Symbol API descriptor lists.

.PARAMETER Id
The Snapshot Schedule ID (schedRef). This is required.

.PARAMETER Suspend
Switch to disable the execution of the snapshot schedule.

.PARAMETER Resume
Switch to enable the execution of the snapshot schedule.

.EXAMPLE
Get-SANtricitySnapshotSchedule | Set-SANtricitySnapshotSchedule -Suspend
#>
function Set-SANtricitySnapshotSchedule {
    [CmdletBinding(DefaultParameterSetName='Resume')]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias('schedRef')]
        [string]$Id,

        [Parameter(Mandatory=$false, ParameterSetName='Suspend')]
        [switch]$Suspend,

        [Parameter(Mandatory=$false, ParameterSetName='Resume')]
        [switch]$Resume
    )

    process {
        Write-Verbose "Fetching existing template for Snapshot Schedule '$Id' to safely reconstruct modify payload..."
        $schedule = Get-SANtricitySnapshotSchedule -Id $Id | Select-Object -First 1
        
        if (-not $schedule) {
            throw "Snapshot Schedule not found for ID: $Id"
        }

        # Determine target state
        $enabled = $true
        if ($Suspend.IsPresent) { $enabled = $false }
        if ($Resume.IsPresent)  { $enabled = $true }

        Write-Verbose "Modifying schedule execution state for '$Id' (Enabled: $enabled)"

        # Re-fetch the raw object using standard Invoke to get the full "schedule" tree since Get-SANtricitySnapshotSchedule selects output format
        $rawSchedules = Invoke-SANtricityRequest -Method GET -Path "/snapshot-schedules"
        $rawTarget = $rawSchedules | Where-Object { $_.id -eq $Id -or $_.schedRef -eq $Id } | Select-Object -First 1

        if (-not $rawTarget.schedule) {
            throw "Failed to extract core schedule timetable from schedule '$Id'."
        }

        # Build massive Symbol modifyScheduleList descriptor
        # We must push 'enabled', 'schedRef', 'schedule', 'startDate', 'recurrence', 'timezone'
        $updateBody = @{
            scheduleUpdateDescriptor = @(
                @{
                    enabled    = $enabled
                    schedRef   = $Id
                    schedule   = $rawTarget.schedule
                    startDate  = $rawTarget.startDate
                    recurrence = $rawTarget.recurrence
                    timezone   = $rawTarget.timezone
                }
            )
        }

        $path = "/symbol/modifyScheduleList?verboseErrorResponse=true"
        
        Write-Verbose "Posting modifyScheduleList descriptor..."
        $response = Invoke-SANtricityRequest -Method POST -Path $path -Body $updateBody
        
        if ($response -ne 'ok') {
            Write-Warning "Failed to update schedule status. Array responded: $response"
            return $response
        }

        # Refetch to return modified object
        return Get-SANtricitySnapshotSchedule -Id $Id
    }
}
