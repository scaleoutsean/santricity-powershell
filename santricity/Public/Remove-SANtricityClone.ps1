
function Remove-SANtricityClone {
    <#
    .SYNOPSIS
    Deletes a Snapshot Volume (Clone).

    .DESCRIPTION
    Removes the specified Snapshot Volume. This does not delete the underlying Snapshot Image 
    or the Base Volume, but it destroys the clone and its specific data/repository.

    .PARAMETER Id
    The unique identifier (ViewRef) of the snapshot volume to delete.

    .PARAMETER Name
    The name of the snapshot volume to delete (resolved to Id).

    .EXAMPLE
    Remove-SANtricityClone -Name "clone_test_1"
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = 'id')]
        [string]$Id,

        [Parameter(ParameterSetName = 'ByName', Mandatory = $true)]
        [string]$Name
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        $clone = Get-SANtricityClone | Where-Object { $_.label -eq $Name }
        if (-not $clone) {
            throw "Snapshot Volume (Clone) with name '$Name' not found."
        }
        $Id = $clone.id
    }

    Write-Verbose "Deleting Snapshot Volume '$Id'..."
    return Invoke-SANtricityRequest -Method 'DELETE' -Path "/snapshot-volumes/$Id"
}
