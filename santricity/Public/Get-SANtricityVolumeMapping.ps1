
function Get-SANtricityVolumeMapping {
    <#
    .SYNOPSIS
    Retrieve volume mappings from the SANtricity API.

    .DESCRIPTION
    Calls the controller's volume-mappings endpoint and returns mapping objects.
    Supports filtering by mapRef (Host or Cluster Ref) and Type (host, cluster, all).

    .PARAMETER Type
    Filter by mapping type: 'host', 'cluster' (Host Group), or 'all' (default).
    
    .PARAMETER MapRef
    Filter by partial or exact mapRef (Host or Cluster ID).
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [ValidateSet('host', 'cluster', 'all')]
        [string]$Type,

        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string]$MapRef
    )

    process {
        $mappings = Invoke-SANtricityRequest -Method 'GET' -Path '/volume-mappings'
        
        if (-not $mappings) { return }

        foreach ($m in $mappings) {
            $match = $true

            # Filter by Type
            if ($PSBoundParameters.ContainsKey('Type') -and $Type -ne 'all') {
                # API 'type' field is 'host' or 'cluster' (sometimes 'all' for default group)
                if ($m.type -ne $Type) { $match = $false }
            }
            # Handle 'all' type implicitly or if user requested specific filtering on other properties
            
            # Filter by MapRef
            if ($match -and -not [string]::IsNullOrWhiteSpace($MapRef)) {
                if (-not ($m.mapRef -and $m.mapRef -like "*$MapRef*")) { $match = $false }
            }

            if ($match) { $m }
        }
    }
}
