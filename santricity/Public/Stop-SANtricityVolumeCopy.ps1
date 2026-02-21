function Stop-SANtricityVolumeCopy {
    <#
    .SYNOPSIS
    Stops one or more active Volume Copy jobs.

    .DESCRIPTION
    Aborts a running Volume Copy operation.
    The target volume may be left in an inconsistent or unusable state depending on the progress.

    .PARAMETER VolumeCopyId
    One or more Volume Copy IDs (Ref or WWN) to stop.

    .EXAMPLE
    Stop-SANtricityVolumeCopy -VolumeCopyId "0200..."
    
    .EXAMPLE
    Get-SANtricityVolumeCopy | Where-Object { $_.copyPriority -eq 'priority0' } | Stop-SANtricityVolumeCopy
    #>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string[]]$VolumeCopyId
    )

    process {
        foreach ($id in $VolumeCopyId) {
            if ($PSCmdlet.ShouldProcess($id, "Stop Volume Copy Job")) {
                try {
                    # URI: /volume-copy-jobs-control/{id}?control=stop
                    # The "?" must be escaped or handled carefully in some contexts, but simple string interpolation works.
                    $uri = "/volume-copy-jobs-control/${id}?control=stop"
                    
                    # POST with empty body (action is in query param)
                    $null = Invoke-SANtricityRequest -Method 'POST' -Path $uri
                    
                    Write-Verbose "Successfully stopped Volume Copy job $id"
                }
                catch {
                    Write-Error "Failed to stop Volume Copy job $id : $_"
                }
            }
        }
    }
}
