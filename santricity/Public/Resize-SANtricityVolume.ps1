<#
.SYNOPSIS
Resize (expand) an existing volume.

.DESCRIPTION
Increases the size of a volume. Note that SANtricity volume expansion is one-way (increase only).
Currently, despite the API field name, this cmdlet expects you to provide the NEW TOTAL SIZE.

.PARAMETER VolumeId
The ID of the volume to resize.

.PARAMETER VolumeName
The name of the volume to resize.

.PARAMETER Size
The new TOTAL size of the volume.

.PARAMETER SizeUnit
Unit for the size (gb, tb, mb).

.EXAMPLE
Resize-SANtricityVolume -VolumeName "Vol1" -Size 100 -SizeUnit "gb"
Resizes Vol1 to 100GB total.
#>
function Resize-SANtricityVolume {
    [CmdletBinding(DefaultParameterSetName="ById")]
    param (
        # Identification
        [Parameter(Mandatory=$true, ParameterSetName="ById", Position=0)]
        [string]$VolumeId,

        [Parameter(Mandatory=$true, ParameterSetName="ByName")]
        [string]$VolumeName,

        # Size
        [Parameter(Mandatory=$true, Position=1)]
        [Alias("TotalSize","NewSize")]
        [int64]$Size,

        [Parameter(Mandatory=$true)]
        [ValidateSet("bytes","mb","gb","tb")]
        [string]$SizeUnit
    )

    process {
        # 1. Resolve Volume ID if Name provided
        if ($PSCmdlet.ParameterSetName -eq "ByName") {
            Write-Verbose "Resolving Volume Name '$VolumeName' to ID..."
            $vols = Get-SANtricityVolumes
            $matched = $vols | Where-Object { $_.name -eq $VolumeName -or $_.label -eq $VolumeName }
            if (-not $matched) {
                throw "Volume '$VolumeName' not found."
            }
            if ($matched -is [array]) {
                # Try to filter by exact match if multiple
                $exact = $matched | Where-Object { $_.name -eq $VolumeName }
                if ($exact -and $exact.Count -eq 1) {
                    $matched = $exact
                } else {
                    throw "Multiple volumes matched name '$VolumeName'. Please use VolumeId."
                }
            }
            $VolumeId = $matched.id
        }

        # 2. Build Body
        $body = @{
            expansionSize = $Size
            sizeUnit = $SizeUnit.ToLower()
        }

        Write-Verbose "Resizing (Expanding) Volume $VolumeId to new total size $Size $SizeUnit..."
        
        # 3. Call API
        return Invoke-SANtricityRequest -Method 'POST' -Path "/volumes/$VolumeId/expand" -Body $body
    }
}
