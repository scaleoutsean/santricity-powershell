
function Get-SANtricityHostGroup {
    <#
    .SYNOPSIS
    Retrieve host-groups from the SANtricity API.

    .DESCRIPTION
    Calls the controller's host-groups endpoint and returns host-group objects.
    Supports client-side filtering by Name.

    .PARAMETER Name
    Filter by Host Group Name (wildcards supported).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [string]$Name
    )

    process {
        $groups = Invoke-SANtricityRequest -Method 'GET' -Path '/host-groups'
        
        if ($null -eq $groups) { return }

        foreach ($g in $groups) {
            if (-not [string]::IsNullOrWhiteSpace($Name)) {
                if ($g.name -notlike $Name) { continue }
            }
            $g
        }
    }
}
