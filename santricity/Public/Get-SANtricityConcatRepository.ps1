function Get-SANtricityConcatRepository {
    <#
    .SYNOPSIS
    Retrieve the list of Concat Repository Volumes.
    #>
    [CmdletBinding()]
    param()

    return Invoke-SANtricityRequest -Method 'GET' -Path '/repositories/concat'
}
