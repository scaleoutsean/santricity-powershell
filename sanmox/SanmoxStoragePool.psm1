function Get-SanmoxStoragePoolOverview {
    [CmdletBinding()]
    param()

    $poolName = $Global:sanConfig.SanPoolName
    $poolNameSafe = $poolName.ToString().Replace('[', '[[').Replace(']', ']]')
    Write-SpectreHost -Message "[cyan]Fetching details for Storage Pool: $poolNameSafe...[/]"

    try {
        $pool = Get-SANtricityStoragePool -Name $poolName

        if (-not $pool) {
            Write-SpectreHost -Message "[yellow]Could not retrieve pool details for '$poolNameSafe'.[/]"
            return
        }

        # Fetch volumes to get count and names
        $volumes = @(Get-SANtricityVolume | Where-Object {
            $_.pool -in $poolName -or $_.volumeGroupRef -in $pool.id -or $_.pool -in $pool.id
        })
        
        $volCount = $volumes.Count
        
        $volNamesStr = "None"
        if ($volCount -gt 0) {
            if ($volCount -le 20) {
                $volNamesStr = ($volumes.name | Sort-Object) -join ', '
            } else {
                $volNamesStr = (($volumes | Select-Object -First 20).name -join ', ') + "... (and $($volCount - 20) more)"
            }
        }

        function Convert-BytesToGB([string]$bytesStr) {
            if ([string]::IsNullOrWhiteSpace($bytesStr)) { return "0 GB" }
            try {
                $bytes = [double]$bytesStr
                return "$([Math]::Round($bytes / 1GB, 2)) GB"
            } catch {
                return $bytesStr
            }
        }

        $props = @(
            [PSCustomObject]@{ Property = "Name"; Value = $pool.name }
            [PSCustomObject]@{ Property = "Free Space"; Value = $(Convert-BytesToGB $pool.freeSpace) }
            [PSCustomObject]@{ Property = "Used Space"; Value = $(Convert-BytesToGB $pool.usedSpace) }
            [PSCustomObject]@{ Property = "Total Raided Space"; Value = $(Convert-BytesToGB $pool.totalRaidedSpace) }
            [PSCustomObject]@{ Property = "Volume Count"; Value = $volCount }
            [PSCustomObject]@{ Property = "Volume Names"; Value = $volNamesStr }
            [PSCustomObject]@{ Property = "Drive Physical Type"; Value = $pool.drivePhysicalType }
            [PSCustomObject]@{ Property = "Drive Media Type"; Value = $pool.driveMediaType }
        )

        Write-SpectreHost -Message ""
        try { Format-SpectreTable -Data $props } catch { $props | Format-Table -AutoSize }

        Write-SpectreHost -Message "[grey]Press Enter to return to the main menu...[/]"
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Error retrieving storage pool details: $err[/]"
    }
}
