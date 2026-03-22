function Get-SANtricitySnapshotGroupRepositoryUtilization {
    <#
    .SYNOPSIS
    Retrieve repository usage statistics for Snapshot Groups.
    #>
    [CmdletBinding()]
    param()

    return Invoke-SANtricityRequest -Method 'GET' -Path '/snapshot-groups/repository-utilization'
}
