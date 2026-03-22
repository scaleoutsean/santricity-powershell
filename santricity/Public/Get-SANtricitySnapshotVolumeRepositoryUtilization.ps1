function Get-SANtricitySnapshotVolumeRepositoryUtilization {
    <#
    .SYNOPSIS
    Retrieve the repository usage statistics for all Snapshot Volumes.
    #>
    [CmdletBinding()]
    param()

    return Invoke-SANtricityRequest -Method 'GET' -Path '/snapshot-volumes/repository-utilization'
}
