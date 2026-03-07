
function Get-SANtricityVolume {
    <#
    .SYNOPSIS
    Retrieve volumes from the SANtricity API.

    .DESCRIPTION
    Calls the controller's volumes endpoint and returns volume objects.
    By default, it returns only standard and thin volumes (user-usable LUNs).
    Use -IncludeSystem to see internal volumes (repositories, etc.).

    .PARAMETER IncludeSystem
    If specified, includes all volume types, including internal repository volumes.

    .PARAMETER Name
    Filter by Volume Name (wildcards supported).

    .PARAMETER HostRef
    Filter by Host or Host Group Reference (ID). 
    If provided, returns only volumes mapped to this host/group.
    
    .PARAMETER Size
    Filter by Volume Capacity. Supports standard unit suffixes (KB, MB, GB, TB) and binary/decimal notation.
    Examples: '100GB', '1.5TiB', '500G'. When units are used, performs an approximate match (within 1 MB).
    Plain numbers are treated as exact bytes.

    .PARAMETER MetadataKey
    Filter volumes that have a specific metadata key.

    .PARAMETER MetadataValue
    Filter volumes where the metadata value matches this string.
    If MetadataKey is also provided, it checks the value for that specific key.
    If only MetadataValue is provided, it checks if any metadata key has this value. Supports wildcards.

    .PARAMETER SizeMin
    Filter volumes with capacity greater than or equal to this size.
    Supports standard unit suffixes (KB, MB, GB, TB, GiB, TiB).
    
    .PARAMETER SizeMax
    Filter volumes with capacity less than or equal to this size.
    Supports standard unit suffixes (KB, MB, GB, TB, GiB, TiB).
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeSystem,
        
        [Parameter(Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [string]$Name,
        
        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string]$HostRef,

        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string]$Size,

        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string]$SizeMin,

        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string]$SizeMax,

        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string]$MetadataKey,

        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string]$MetadataValue
    )

    process {
        # Fetch all volumes first
        $vols = Invoke-SANtricityRequest -Method 'GET' -Path '/volumes'
        
        if (-not $vols) { return $null }

        # Filter: System Volumes
        if (-not $IncludeSystem) {
            $vols = $vols | Where-Object { $_.volumeUse -in @('standardVolume', 'thinVolume') }
        }

        # Filter: HostRef (requires fetching mappings)
        if (-not [string]::IsNullOrWhiteSpace($HostRef)) {
            $mappings = Get-SANtricityVolumeMapping
            if ($mappings) {
                # Find volumeRefs mapped to this HostRef
                $mappedVolumeRefs = $mappings | Where-Object { $_.mapRef -eq $HostRef } | ForEach-Object { $_.volumeRef }
                $vols = $vols | Where-Object { $_.volumeRef -in $mappedVolumeRefs }
            } else {
                # HostRef provided but no mappings found at all -> return empty
                return $null 
            }
        }
        
        # Helper for size parsing
        function Get-BytesFromSizeString {
            param([string]$s)
            
            if ($s -match '^\d+$') { return [int64]$s }
            
            $suffix = $s -replace '[\d\.]+', ''
            $val    = $s -replace '[^\d\.]+', ''
            [double]$d = $val

            switch -Regex ($suffix) {
                '(?i)^k$'   { return [int64]($d * 1000) }
                '(?i)^kb$'  { return [int64]($d * 1000) }
                '(?i)^ki$'  { return [int64]($d * 1024) }
                '(?i)^kib$' { return [int64]($d * 1024) }
                
                '(?i)^m$'   { return [int64]($d * 1000 * 1000) }
                '(?i)^mb$'  { return [int64]($d * 1000 * 1000) }
                '(?i)^mi$'  { return [int64]($d * 1024 * 1024) }
                '(?i)^mib$' { return [int64]($d * 1024 * 1024) }

                '(?i)^g$'   { return [int64]($d * 1000 * 1000 * 1000) }
                '(?i)^gb$'  { return [int64]($d * 1000 * 1000 * 1000) }
                '(?i)^gi$'  { return [int64]($d * 1024 * 1024 * 1024) }
                '(?i)^gib$' { return [int64]($d * 1024 * 1024 * 1024) }
                
                '(?i)^t$'   { return [int64]($d * 1000 * 1000 * 1000 * 1000) }
                '(?i)^tb$'  { return [int64]($d * 1000 * 1000 * 1000 * 1000) }
                '(?i)^ti$'  { return [int64]($d * 1024 * 1024 * 1024 * 1024) }
                '(?i)^tib$' { return [int64]($d * 1024 * 1024 * 1024 * 1024) }
                
                default { 
                    # Try PowerShell native casting if suffix matches standard ones
                    try { return [int64](Invoke-Expression $s) } catch { return 0 }
                }
            }
        }

        # Apply client-side filters
        foreach ($v in $vols) {
            $match = $true

            # Parse Metadata: Convert list of KV objects to Hashtable
            if ($v.metadata -is [Array]) {
                $mdHash = @{}
                foreach ($item in $v.metadata) {
                    if ($item.key) {
                        $mdHash[$item.key] = $item.value
                    }
                }
                # Preserve original metadata as 'MetadataList'
                $v | Add-Member -MemberType NoteProperty -Name 'MetadataList' -Value $v.metadata -Force
                $v.metadata = $mdHash
            } elseif ($null -eq $v.metadata) {
                $v.metadata = @{}
            }
            
            # Name Filter
            if (-not [string]::IsNullOrWhiteSpace($Name)) {
                if ($v.label -notlike $Name) { $match = $false }
            }
            
            # Size Filter
            if ($match -and -not [string]::IsNullOrWhiteSpace($Size)) {
                $targetBytes = Get-BytesFromSizeString $Size
                if ($targetBytes -gt 0) {
                    [int64]$volBytes = $v.capacity
                    # Tolerance: If user uses units, allow slight deviation (e.g. 10MB) due to rounding/overhead
                    # If raw number, require exact match
                    if ($Size -match '^\d+$') {
                       if ($volBytes -ne $targetBytes) { $match = $false } 
                    } else {
                       # Approx match (within 10MB)
                       $diff = [Math]::Abs($volBytes - $targetBytes)
                       if ($diff -gt 10485760) { $match = $false }
                    }
                }
            }
            
            # Size Min Filter
            if ($match -and -not [string]::IsNullOrWhiteSpace($SizeMin)) {
                $minBytes = Get-BytesFromSizeString $SizeMin
                if ($minBytes -gt 0) {
                     [int64]$volBytes = $v.capacity
                     if ($volBytes -lt $minBytes) { $match = $false }
                }
            }

            # Size Max Filter
            if ($match -and -not [string]::IsNullOrWhiteSpace($SizeMax)) {
                $maxBytes = Get-BytesFromSizeString $SizeMax
                if ($maxBytes -gt 0) {
                     [int64]$volBytes = $v.capacity
                     if ($volBytes -gt $maxBytes) { $match = $false }
                }
            }

            # Metadata Filter
            if ($match) {
                if (-not [string]::IsNullOrWhiteSpace($MetadataKey)) {
                    if (-not $v.metadata.ContainsKey($MetadataKey)) { $match = $false }
                }
                
                if ($match -and -not [string]::IsNullOrWhiteSpace($MetadataValue)) {
                    if (-not [string]::IsNullOrWhiteSpace($MetadataKey)) {
                        # Key specific check
                        if ($v.metadata[$MetadataKey] -notlike $MetadataValue) { $match = $false }
                    } else {
                        # Check if any value matches
                        if (-not ($v.metadata.Values | Where-Object { $_ -like $MetadataValue })) { $match = $false }
                    }
                }
            }

            if ($match) { $v }
        }
    }
}
