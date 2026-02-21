function Remove-SANtricityVolumeCopy {
    <#
    .SYNOPSIS
    Removes a Volume Copy pair relationship.

    .DESCRIPTION
    Deletes the volume copy pair definition. This does not delete the source or target volumes, 
    but removes the relationship between them.
    If a copy is in progress, it must usually be stopped first.

    .PARAMETER VolumeCopyId
    The ID (Ref) of the volume copy pair to remove.

    .EXAMPLE
    Remove-SANtricityVolumeCopy -VolumeCopyId "0200..."
    #>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string[]]$VolumeCopyId
    )

    process {
        foreach ($id in $VolumeCopyId) {
            if ($PSCmdlet.ShouldProcess($id, "Remove Volume Copy Pair")) {
                try {
                    $uri = "/volume-copy-jobs/${id}"
                    $null = Invoke-SANtricityRequest -Method 'DELETE' -Path $uri
                    Write-Verbose "Successfully removed Volume Copy relationship $id"
                }
                catch {
                    Write-Error "Failed to remove Volume Copy relationship $id : $_"
                }
            }
        }
    }
}
