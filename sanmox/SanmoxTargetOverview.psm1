function Get-SanmoxTargetOverview {
    [CmdletBinding()]
    param()

    $poolName = $Global:sanConfig.SanPoolName

    # --- Volume bar/breakdown charts ---
    Write-SpectreHost -Message "[cyan]Fetching volumes in pool '$poolName'...[/]"
    try {
        $pool    = Get-SANtricityStoragePool -Name $poolName
        $volumes = @(Get-SANtricityVolume | Where-Object {
            $_.pool -in $poolName -or $_.volumeGroupRef -in $pool.id -or $_.pool -in $pool.id
        } | Sort-Object label)

        if ($volumes.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]No volumes found in pool '$poolName'.[/]"
        } else {
            $maxChartItems = 12
            $volumesBySize = @($volumes | Sort-Object { [double]$_.capacity } -Descending)
            $chartSource = @()
            if ($volumesBySize.Count -lt $maxChartItems) {
                $chartSource = $volumesBySize
            } else {
                $top = @($volumesBySize | Select-Object -First $maxChartItems)
                $rest = @($volumesBySize | Select-Object -Skip $maxChartItems)
                $othersCapacity = 0
                foreach ($item in $rest) {
                    $othersCapacity += [double]$item.capacity
                }

                $chartSource = @($top)
                if ($othersCapacity -gt 0) {
                    $chartSource += [PSCustomObject]@{
                        label = 'Others'
                        capacity = [string]$othersCapacity
                    }
                }
            }

            $palette = @(
                'Blue1','Green','Orange3','Purple_1','Yellow','Turquoise2',
                'Red','Aqua','Chartreuse1','DeepPink1','LightSlateBlue','Gold1'
            )
            $chartItems = @()
            for ($i = 0; $i -lt $chartSource.Count; $i++) {
                $v  = $chartSource[$i]
                $gb = [Math]::Round([double]$v.capacity / 1GB, 1)
                $chartItems += New-SpectreChartItem -Label $v.label -Value $gb -Color $palette[$i % $palette.Count]
            }

            Write-SpectreHost -Message ""
            Write-SpectreHost -Message "[yellow]Volume sizes — pool [white]$poolName[/] (GB)[/]"
            if ($volumesBySize.Count -ge $maxChartItems) {
                Write-SpectreHost -Message "[grey]Showing top $maxChartItems largest volumes plus Others (total volumes: $($volumesBySize.Count)).[/]"
            }
            $chartItems | Format-SpectreBarChart
            Write-SpectreHost -Message ""
            $chartItems | Format-SpectreBreakdownChart
        }
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Error fetching volumes: $err[/]"
    }

    # --- iSCSI Target Settings ---
    Write-SpectreHost -Message ""
    Write-SpectreRule -Title "iSCSI Target Settings" -Alignment Center -Color Blue
    try {
        $iscsi = Get-SANtricityIscsiTargetSetting
        if ($iscsi) {
            $iqn        = $iscsi.nodeName.iscsiNodeName
            $authMethod = ($iscsi.configuredAuthMethods.authMethodData | Select-Object -First 1).authMethod
            $portals    = @($iscsi.portals | ForEach-Object {
                $ip = if ($_.ipAddress.ipv4Address) { $_.ipAddress.ipv4Address } else { $_.ipAddress.ipv6Address }
                "$ip`:$($_.tcpListenPort)"
            } | Sort-Object -Unique)

            $iscsiTable = @(
                [PSCustomObject]@{ Property = 'IQN';     Value = $iqn }
                [PSCustomObject]@{ Property = 'Auth';    Value = $authMethod }
                [PSCustomObject]@{ Property = 'Portals'; Value = $portals -join ', ' }
            )
            try { Format-SpectreTable -Data $iscsiTable } catch { $iscsiTable | Format-Table -AutoSize }
        } else {
            Write-SpectreHost -Message "[yellow]No iSCSI target settings returned.[/]"
        }
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Error fetching iSCSI target settings: $err[/]"
    }

    # --- NVMe-oF Target Settings ---
    Write-SpectreHost -Message ""
    Write-SpectreRule -Title "NVMe-oF Target Settings" -Alignment Center -Color Blue
    try {
        $nvme = Get-SANtricityNvmeTargetSetting
        if ($nvme) {
            $nvmeNodeName = $null
            if ($nvme.PSObject.Properties['nodeName'] -and $null -ne $nvme.nodeName) {
                if ($nvme.nodeName.PSObject.Properties['nvmeNodeName']) {
                    $nvmeNodeName = $nvme.nodeName.nvmeNodeName
                }
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$nvmeNodeName)) {
                $nvmeTable = @(
                    [PSCustomObject]@{ Property = 'nvmeNodeName'; Value = [string]$nvmeNodeName }
                )
                try { Format-SpectreTable -Data $nvmeTable } catch { $nvmeTable | Format-Table -AutoSize }
            } else {
                Write-SpectreHost -Message "[yellow]NVMe-oF response did not include nodeName.nvmeNodeName.[/]"
            }
        } else {
            Write-SpectreHost -Message "[yellow]No NVMe-oF target settings returned.[/]"
        }
    } catch {
        # Detect HTTP 404 gracefully — NVMe-oF may simply not be licensed/enabled
        $statusCode = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
        }
        if ($statusCode -eq 404 -or $_.ToString() -match '\b404\b') {
            Write-SpectreHost -Message "[yellow]NVMe-oF protocol may not be enabled on this array (HTTP 404).[/]"
        } else {
            $err = $_.ToString().Replace('[', '(').Replace(']', ')')
            Write-SpectreHost -Message "[red]Error fetching NVMe-oF target settings: $err[/]"
        }
    }

    Write-SpectreHost -Message ""
    Write-SpectreHost -Message "[grey]Press Enter to return to the main menu...[/]"
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
