
function Discover-SANtricitySystemId {
    <#
    .SYNOPSIS
    Discover the storage-system id/WWN by querying the controller's /storage-systems endpoint.
    #>
    param()

    $payload = Invoke-SANtricityRequest -Method 'GET' -Path '/storage-systems' -UseSystemScope:$false
    if ($payload -is [System.Collections.IEnumerable]) {
        foreach ($item in $payload) {
            if ($item -is [System.Collections.IDictionary]) {
                $candidate = $null
                if ($item.Contains('wwn')) { $candidate = $item['wwn'] }
                if (-not $candidate -and $item.Contains('id')) { $candidate = $item['id'] }
                if ($candidate -and [string]::IsNullOrWhiteSpace($candidate) -eq $false) {
                    return $candidate.Trim()
                }
            }
        }
    }
    return $null
}
