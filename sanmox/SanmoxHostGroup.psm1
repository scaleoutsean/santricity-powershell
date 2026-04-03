function Get-SanmoxHostGroup {
    [CmdletBinding()]
    param()

    Write-SpectreHost -Message "[cyan]Fetching SANtricity Host Groups (analogous to SolidFire VAGs)...[/]"
    try {
        $hostGroups = @(Get-SANtricityHostGroup)
        $allHosts   = @(Get-SANtricityHost)

        if (-not $hostGroups) {
            Write-SpectreHost -Message "[yellow]No Host Groups discovered.[/]"
            return
        }

        $tableData = $hostGroups | Sort-Object label | ForEach-Object {
            $grp     = $_
            $members = @($allHosts | Where-Object { $_.clusterRef -eq $grp.id })
            $memberNames = if ($members.Count -gt 0) {
                ($members.label | Sort-Object) -join ', '
            } else { '[grey](none)[/]' }

            $protocols = @($members | ForEach-Object {
                $h = $_
                @(
                    ($h.hostSidePorts | Where-Object { $_.type }                       | ForEach-Object { $_.type })
                    ($h.initiators    | Where-Object { $_.nodeName.ioInterfaceType }   | ForEach-Object { $_.nodeName.ioInterfaceType })
                )
            } | Select-Object -Unique | Where-Object { $_ } | Sort-Object)
            $transportStr = if ($protocols.Count -gt 0) { $protocols -join ', ' } else { '[grey]unknown[/]' }

            [PSCustomObject]@{
                'Group'     = $grp.label
                'Members'   = $memberNames
                'Transport' = $transportStr
                'SA Ctrl'   = if ($grp.isSAControlled) { '[yellow]Yes[/]' } else { 'No' }
            }
        }

        Write-SpectreHost -Message ""
        try { Format-SpectreTable -Data $tableData } catch { $tableData | Format-Table -AutoSize }

    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Error fetching Host Groups: $err[/]"
    }
}