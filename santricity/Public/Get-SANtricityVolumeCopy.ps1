function Get-SANtricityVolumeCopy {
    <#
    .SYNOPSIS
    Retrieves the status or configuration of active Volume Copy jobs.

    .DESCRIPTION
    Returns a list of Volume Copy jobs.
    By default, it returns the job configuration (source/target/priority).
    Use -Progress to retrieve the current execution status (percent complete, time remaining).

    .PARAMETER VolumeCopyId
    The unique identifier (Ref or WWN) of the volume copy job to retrieve.
    If omitted, returns all active jobs.

    .PARAMETER Progress
    If specified, returns the live progress of the copy job(s) instead of static configuration.

    .EXAMPLE
    Get-SANtricityVolumeCopy
    
    .EXAMPLE
    Get-SANtricityVolumeCopy -Progress
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$VolumeCopyId,

        [Parameter(Mandatory = $false)]
        [switch]$Progress
    )

    process {
        try {
            # Determine base path based on whether Progress is requested
            # /volume-copy-jobs         -> Configuration/Static info
            # /volume-copy-jobs-control -> Progress/Status info
            $basePath = if ($Progress) { '/volume-copy-jobs-control' } else { '/volume-copy-jobs' }
            
            if ($VolumeCopyId) {
                # Get specific job
                $path = "$basePath/$VolumeCopyId"
                $response = Invoke-SANtricityRequest -Method 'GET' -Path $path
                return $response
            }
            else {
                # Get all jobs
                $response = Invoke-SANtricityRequest -Method 'GET' -Path $basePath
                return $response
            }
        }
        catch {
            Write-Error "Failed to retrieve Volume Copy info: $_"
        }
    }
}
