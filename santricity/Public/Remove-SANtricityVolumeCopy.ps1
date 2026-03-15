function Remove-SANtricityVolumeCopy {
    <#
    .SYNOPSIS
    Removes a Volume Copy relationship (Job).

    .DESCRIPTION
    Deletes the volume copy pair definition (Job). 
    This does NOT delete the source or target data volumes themselves, but removes the relationship between them.
    Until this relationship is removed (or completes with Auto-Clear enabled), the Target Volume cannot be used for other operations.

    If a copy is in progress, it must usually be stopped first (see Stop-SANtricityVolumeCopy).

    .PARAMETER Id
    The unique identifier (Ref) of the volume copy pair (Job) to remove.
    Note: This is NOT a Volume ID.

    .EXAMPLE
    Remove-SANtricityVolumeCopy -Id "1800..."
    Removes the copy relationship, freeing the target volume.
    #>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias("VolumeCopyId", "volcopyRef", "JobId")]
        [string[]]$Id
    )

    process {
        foreach ($i in $Id) {
            if ($PSCmdlet.ShouldProcess($i, "Remove Volume Copy Relationship (Job)")) {
                try {
                    $uri = "/volume-copy-jobs/${i}"
                    $null = Invoke-SANtricityRequest -Method 'DELETE' -Path $uri
                    Write-Verbose "Successfully removed Volume Copy relationship (Job) $i"
                }
                catch {
                    Write-Error "Failed to remove Volume Copy relationship $i : $_"
                }
            }
        }
    }
}
