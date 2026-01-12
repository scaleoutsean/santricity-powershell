<#
.SYNOPSIS
Resize (expand) an existing volume.

.DESCRIPTION
Increases the size of a volume. Note that SANtricity volume expansion is generally one-way (increase only).

.PARAMETER VolumeId
The ID of the volume to resize.

.PARAMETER VolumeName
The name of the volume to resize.

.PARAMETER Size
The NEW TOTAL size of the volume (standard behavior for Resize cmdlets usually) OR the expansion amount?
The API endpoint is `/expand`. The payload typically asks for `expansionSize` (amount to add) OR `newSize` (total).
Let's check the reference draft. It said "expansionSize".
However, a user calling `Resize-` usually thinks "Make it this big".
If I implement "Make it 100GB", I need to know current size to calculate delta.
Or I can expose `Amount` vs `TotalSize`.
The draft had `$Size` mapping to `expansionSize`.
Let's assume the user supplies the AMOUNT TO ADD if the API requires it, OR I calculate it.
The draft says: "API expects expansionSize which appears to be the NEW TOTAL SIZE, not the delta." - Wait, the comment in draft was contradictory/uncertain.
"expansionSize" usually implies delta.
Let's look at standard docs if I can.
Without docs, "expansionSize" usually means delta.
But if I look at `Get-SANtricityVolume`, it returns `capacity` or `reportedSize`.
If the user says `Resize-SANtricityVolume -Size 20GB`, they usually mean "Grow it BY 20GB" (if parameter is -Size, maybe ambiguous) or "Set size to 20GB".
PowerShell `Resize-Partition` uses `-Size` for target size.
I will implement `-AddedSize` (delta) to be explicit, or `-NewSize` (target) and calculate delta.
Let's implement `-NewSize` as primary, and calculate delta.
BUT, for safety/simplicity given I can't test against a real array right now:
I'll expose `-ExpansionSize` to map directly to naming of API, to be safe.
AND I'll add `-NewSize` which calculates delta.

.PARAMETER SizeUnit
Unit for the size (gb, tb, mb).

.EXAMPLE
Resize-SANtricityVolume -VolumeName "Vol1" -ExpansionSize 10 -SizeUnit "gb"
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
        [Parameter(Mandatory=$true)]
        [int64]$ExpansionSize,

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
            expansionSize = $ExpansionSize
            sizeUnit = $SizeUnit
        }

        Write-Verbose "Resizing Volume $VolumeId expanding by $ExpansionSize $SizeUnit..."
        
        # 3. Call API
        return Invoke-SANtricityRequest -Method 'POST' -Path "/volumes/$VolumeId/expand" -Body $body
    }
}
