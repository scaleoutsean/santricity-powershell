function Stop-SANtricityVolumeCopy {
    <#
    .SYNOPSIS
    Stops one or more active Volume Copy jobs.

    .DESCRIPTION
    Aborts a running Volume Copy operation.
    The target volume may be left in an inconsistent or unusable state depending on the progress.

    .PARAMETER Id
    One or more Volume Copy IDs (Job Ref) to stop.
    Note: This is the Job ID, not the Volume ID.

    .EXAMPLE
    Stop-SANtricityVolumeCopy -Id "1800..."
    
    .EXAMPLE
    Get-SANtricityVolumeCopy | Where-Object { $_.copyPriority -eq 'priority0' } | Stop-SANtricityVolumeCopy
    #>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias("VolumeCopyId", "volcopyRef", "JobId")]
        [string[]]$Id
    )

    process {
        foreach ($i in $Id) {
            if ($PSCmdlet.ShouldProcess($i, "Stop Volume Copy Job")) {
                try {
                    # URI: /volume-copy-jobs-control/{id}?control=stop
                    # The "?" must be escaped or handled carefully in some contexts, but simple string interpolation works.
                    $uri = "/volume-copy-jobs-control/${i}?control=stop"
                    
                    # POST with empty body (action is in query param)
                    $null = Invoke-SANtricityRequest -Method 'POST' -Path $uri
                    
                    Write-Verbose "Successfully stopped Volume Copy job $i"
                }
                catch {
                    Write-Error "Failed to stop Volume Copy job $i : $_"
                }
            }
        }
    }
}
