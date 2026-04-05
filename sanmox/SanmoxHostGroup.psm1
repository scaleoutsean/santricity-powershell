function Get-SanmoxHostGroup {
    [CmdletBinding()]
    param()

    Write-SpectreHost -Message "[cyan]Fetching configured SANtricity Host Group/Host entries...[/]"
    try {
        $configuredTargets = @($Global:sanConfig.SanHostGroupName | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($configuredTargets.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]No Host Group/Host configured in sanconfig.json (SanHostGroupName).[/]"
            return
        }

        $hostGroups = @(Get-SANtricityHostGroup)
        $allHosts   = @(Get-SANtricityHost)

        $tableData = @()
        $missing = @()
        foreach ($configured in $configuredTargets) {
            $configuredName = [string]$configured
            $grp = $hostGroups | Where-Object { $_.name -eq $configuredName -or $_.label -eq $configuredName } | Select-Object -First 1
            if ($grp) {
                $members = @($allHosts | Where-Object { $_.clusterRef -eq $grp.id })
                $memberNames = if ($members.Count -gt 0) {
                    ($members.label | Sort-Object) -join ', '
                } else { '(none)' }

                $protocols = @($members | ForEach-Object {
                    $h = $_
                    @(
                        ($h.hostSidePorts | Where-Object { $_.type }                       | ForEach-Object { $_.type })
                        ($h.initiators    | Where-Object { $_.nodeName.ioInterfaceType }   | ForEach-Object { $_.nodeName.ioInterfaceType })
                    )
                } | Select-Object -Unique | Where-Object { $_ } | Sort-Object)
                $transportStr = if ($protocols.Count -gt 0) { $protocols -join ', ' } else { 'unknown' }

                $tableData += [PSCustomObject]@{
                    'Type'      = 'Host Group'
                    'Configured' = $configuredName
                    'Resolved'  = [string]$grp.label
                    'Members'   = $memberNames
                    'Transport' = $transportStr
                    'SA Ctrl'   = if ($grp.isSAControlled) { 'Yes' } else { 'No' }
                }
                continue
            }

            $host = $allHosts | Where-Object { $_.name -eq $configuredName -or $_.label -eq $configuredName } | Select-Object -First 1
            if ($host) {
                $hostProtocols = @(
                    ($host.hostSidePorts | Where-Object { $_.type } | ForEach-Object { $_.type })
                    ($host.initiators | Where-Object { $_.nodeName.ioInterfaceType } | ForEach-Object { $_.nodeName.ioInterfaceType })
                    ($host.ports | Where-Object { $_.type } | ForEach-Object { $_.type })
                    ($host.ports | Where-Object { $_.portType } | ForEach-Object { $_.portType })
                ) | Where-Object { $_ } | Select-Object -Unique | Sort-Object
                $hostTransport = if ($hostProtocols.Count -gt 0) { $hostProtocols -join ', ' } else { 'unknown' }

                $tableData += [PSCustomObject]@{
                    'Type'      = 'Host'
                    'Configured' = $configuredName
                    'Resolved'  = if ($host.label) { [string]$host.label } else { [string]$host.name }
                    'Members'   = '(single host)'
                    'Transport' = $hostTransport
                    'SA Ctrl'   = '-'
                }
                continue
            }

            $missing += $configuredName
        }

        if ($tableData.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]Configured Host Group/Host entries were not found on this SANtricity array.[/]"
            if ($missing.Count -gt 0) {
                Write-SpectreHost -Message "[yellow]Missing: $($missing -join ', ')[/]"
            }
            return
        }

        if ($missing.Count -gt 0) {
            Write-SpectreHost -Message "[yellow]Some configured entries were not found: $($missing -join ', ')[/]"
        }

        $tableData = @($tableData | Sort-Object -Property Type, Resolved)

        Write-SpectreHost -Message ""
        try { Format-SpectreTable -Data $tableData } catch { $tableData | Format-Table -AutoSize }

    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Error fetching Host Groups: $err[/]"
    }
}