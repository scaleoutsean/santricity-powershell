function Remove-SANtricityConsistencyGroup {
    <#
    .SYNOPSIS
    Deletes a specific Consistency Group (CG).

    .DESCRIPTION
    Removing a CG deletes all snapshots and snapshot groups contained within it.
    It does NOT delete the base volumes, but it frees the repo volumes.

    .PARAMETER Id
    The unique identifier (Ref) of the consistency group to delete.

    .PARAMETER Name
    The name of the consistency group to delete.

    .EXAMPLE
    Remove-SANtricityConsistencyGroup -Name "OracleCG"
    #>
    [CmdletBinding(DefaultParameterSetName="ById", SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true, ParameterSetName="ById", ValueFromPipeline=$true, ValueFromPipelineByPropertyName="id")]
        [string]$Id,

        [Parameter(Mandatory=$true, ParameterSetName="ByName")]
        [string]$Name
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq "ByName") {
            $cg = Get-SANtricityConsistencyGroup -Name $Name
            if (-not $cg) {
                Write-Warning "Consistency Group '$Name' not found."
                return
            }
            $Id = $cg.id
        }

        if ($PSCmdlet.ShouldProcess("Consistency Group $Id", "Delete")) {
            Invoke-SANtricityRequest -Method 'DELETE' -Path "/consistency-groups/$Id"
        }
    }
}
