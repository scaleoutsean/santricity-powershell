function New-SANtricityVolumeCopy {
    <#
    .SYNOPSIS
    Creates a new Volume Copy (full physical copy) from a source volume to a target volume.

    .DESCRIPTION
    Establishes a Volume Copy relationship to copy data from a Source Volume to a Target Volume.
    This creates a "split" clone (full copy) unlike a Snapshot Volume (linked clone).

    The target volume must be:
    - Of equal or greater capacity than the source.
    - Unmapped (no I/O access) during the copy process.
    - Of the same protection type (e.g. PI).
    - **Of the same block size (sector size)** as the source (e.g. 4K Native vs 512n).
      - NVMe volumes are typically 4K sector size.
      - SAS (HDD/SSD) volumes are typically 512n sector size.
      - Copying between these different sector sizes is NOT supported.
    
    Cross-pool copies (e.g. from SSD pool to HDD pool) ARE supported provided the sector sizes match.

    .PARAMETER SourceVolumeId
    The identifier (Ref or WWN) of the source volume.
    
    .PARAMETER TargetVolumeId
    The identifier (Ref or WWN) of the target volume.
    
    .PARAMETER CopyPriority
    Priority of the copy operation (Priority0 lowest, Priority4 highest). 
    Default is Priority2.

    .PARAMETER TargetWriteProtected
    If set, blocks write I/O to the target volume while the copy job exists.
    
    .PARAMETER OnlineCopy
    If set, creates a snapshot of the source volume to perform the copy, allowing the source
    volume to remain online and writable during the copy process.
    Requires available repository capacity on the source pool (system will automatically select best candidate).

    .PARAMETER RepositoryPercentage
    Specific percentage of the base volume capacity to allocate for the copy-on-write repository.
    Only valid when -OnlineCopy is specified. Default is 20 if not specified.

    .EXAMPLE
    New-SANtricityVolumeCopy -SourceVolumeId "0200..." -TargetVolumeId "0201..." -CopyPriority Priority3 -OnlineCopy
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$SourceVolumeId,

        [Parameter(Mandatory = $true)]
        [string]$TargetVolumeId,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Priority0", "Priority1", "Priority2", "Priority3", "Priority4")]
        [string]$CopyPriority = "Priority2",

        [Parameter(Mandatory = $false)]
        [switch]$TargetWriteProtected,

        [Parameter(Mandatory = $false)]
        [switch]$OnlineCopy,

        [Parameter(Mandatory = $false)]
        [int]$RepositoryPercentage = 20
    )

    process {
        if ($PSBoundParameters.ContainsKey('RepositoryPercentage') -and -not $OnlineCopy.IsPresent) {
            throw "The parameter '-RepositoryPercentage' can only be used when '-OnlineCopy' is specified."
        }

        $body = @{
            sourceId             = $SourceVolumeId
            targetId             = $TargetVolumeId
            copyPriority         = "priority$($CopyPriority.Replace('Priority',''))" # API expects priority0..4
            targetWriteProtected = $TargetWriteProtected.IsPresent
            onlineCopy           = $OnlineCopy.IsPresent
        }
        
        if ($OnlineCopy.IsPresent) {
            # Based on SMcli syntax, repositoryPercentOfBase is expected.
            $body['repositoryPercentOfBase'] = $RepositoryPercentage
        }

        # Api usually expects camelCase enum values like "priority2"
        $body.copyPriority = $body.copyPriority.ToLower()

        try {
            # POST to create/start the copy job
            $response = Invoke-SANtricityRequest -Method 'POST' -Path '/volume-copy-jobs' -Body $body
            return $response
        }
        catch {
            Write-Error "Failed to create Volume Copy job: $_"
        }
    }
}
