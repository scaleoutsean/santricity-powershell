function Get-SanmoxVolume {
    [CmdletBinding()]
    param()
    
    $poolNameConfig = $Global:sanConfig.SanPoolName
    $poolNameSafe = $poolNameConfig.ToString().Replace('[', '[[').Replace(']', ']]')
    Write-SpectreHost -Message "[cyan]Fetching SANtricity Volumes for pool: $poolNameSafe...[/]"
    try {
        $pool = Get-SANtricityStoragePool -Name $poolNameConfig
        if (-not $pool) {
            Write-SpectreHost -Message "[yellow]Warning: Could not retrieve pool metadata for '$poolNameSafe', checking universally instead.[/]"
        }
        
        $volumes = @(Get-SANtricityVolume | Where-Object {
            $_.pool -in $poolNameConfig -or 
            ($pool.id -and $_.volumeGroupRef -in $pool.id) -or 
            ($pool.id -and $_.pool -in $pool.id)
        })
        
        if ($volumes.Count -gt 0) {
            $tableData = $volumes | Select-Object name, @{n='Size(GB)';e={[math]::Round($_.capacity / 1GB, 2)}}, id, status, volumeGroupRef
            $sortChoice = Read-SpectreSelection -Title "Sort volume list by" -Choices @(
                "1. Name (A-Z)",
                "2. Size (GB) (Largest first)",
                "3. Status (A-Z)",
                "4. Keep current order"
            ) -Color Turquoise2

            if ($sortChoice -match '^1') {
                $tableData = $tableData | Sort-Object -Property name
            } elseif ($sortChoice -match '^2') {
                $tableData = $tableData | Sort-Object -Property 'Size(GB)' -Descending
            } elseif ($sortChoice -match '^3') {
                $tableData = $tableData | Sort-Object -Property status, name
            }

            if (Get-Command -Name Format-SpectreTable -ErrorAction SilentlyContinue) {
                Format-SpectreTable -Data $tableData
            } else {
                $tableData | Format-Table -AutoSize | Out-String | Write-Host
            }
        } else {
            Write-SpectreHost -Message "[yellow]No volumes found or unable to filter by pool name.[/]"
        }
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Error retrieving volumes: $err[/]"
    }
}

function New-SanmoxVolume {
    [CmdletBinding()]
    param()

    $startCreate = Read-SpectreSelection -Title "Create a new SANtricity volume?" -Choices @("Y. Yes", "N. No (Back)")
    if ($startCreate -notmatch '^Y') {
        Write-SpectreHost -Message "[cyan]Create volume cancelled.[/]"
        return
    }

    $volName = Read-SpectreText -Message "Enter new volume name"
    if ([string]::IsNullOrWhiteSpace($volName) -or $volName -match '^(?i)c(ancel)?$') {
        Write-SpectreHost -Message "[cyan]Create volume cancelled.[/]"
        return
    }

    $volSizeStr = Read-SpectreText -Message "Enter the size (e.g. 100GB, 2TB)"
    if ([string]::IsNullOrWhiteSpace($volSizeStr) -or $volSizeStr -match '^(?i)c(ancel)?$') {
        Write-SpectreHost -Message "[cyan]Create volume cancelled.[/]"
        return
    }

    if ($volSizeStr -match '^\s*(?<size>\d+)\s*(?<unit>[gmtGDT]?[bB])?\s*$') {
        $volSize = [int]$matches['size']
        $volUnit = if ($matches['unit']) { $matches['unit'].ToLower() } else { 'gb' }
    } else {
        Write-SpectreHost -Message "[red]Invalid size format. Please use a number followed by GB or TB.[/]"
        return
    }

    $volNameSafe = $volName.ToString().Replace('[', '[[').Replace(']', ']]')
    $poolNameConfig = $Global:sanConfig.SanPoolName
    $poolName = $poolNameConfig.ToString().Replace('[', '[[').Replace(']', ']]')

    $raidLevel = ""
    try {
        $pool = Get-SANtricityStoragePool -Name $poolNameConfig -ErrorAction Stop
        if ($pool.diskPool) {
            $raidChoice = Read-SpectreSelection -Title "Pool '$poolName' is a DDP. Select RAID Level for the new volume" -Choices @("1. RAID 6 (Default)", "2. RAID 1") -Color Turquoise2
            if ($raidChoice -match "^2") {
                $raidLevel = "raid1"
            } else {
                $raidLevel = "raid6"
            }
        }
    } catch {
        Write-SpectreHost -Message "[yellow]Could not query pool info to check if it's a DDP. Proceeding with default RAID setting.[/]"
    }

    Write-SpectreHost -Message "[cyan]Creating volume '$volNameSafe' with size $volSize $volUnit on pool $poolName...[/]"
    try {
        $splat = @{
            Name = $volName
            Size = $volSize
            SizeUnit = $volUnit
            PoolName = $poolNameConfig
        }
        if ($raidLevel) { $splat.Add('RaidLevel', $raidLevel) }
        
        $newVol = New-SANtricityVolume @splat
        Write-SpectreHost -Message "[green]Successfully created volume '$volNameSafe'![/]"
        
        $hostGroups = $Global:sanConfig.SanHostGroupName
        if ($null -ne $hostGroups -and $hostGroups.Count -gt 0) {
            $selectedGroup = if ($hostGroups.Count -gt 1) {
                Read-SpectreSelection -Title "Multiple Host Groups found. Select one to map this volume to:" -Choices $hostGroups -Color Turquoise2
            } else {
                $hostGroups[0]
            }
            
            $selectedGroupSafe = $selectedGroup.ToString().Replace('[', '[[').Replace(']', ']]')
            Write-SpectreHost -Message "[cyan]Mapping volume to Host Group '$selectedGroupSafe'...[/]"
            
            try {
                # Try as a Host Group first
                try {
                    New-SANtricityVolumeMapping -VolumeName $volName -HostGroupName $selectedGroup -ErrorAction Stop | Out-Null
                    Write-SpectreHost -Message "[green]Successfully mapped volume to Host Group '$selectedGroupSafe'![/]"
                } catch {
                    if ($_.Exception.Message -match "not found") {
                        # Fallback to try mapping as a standalone Host
                        Write-SpectreHost -Message "[yellow]Host Group '$selectedGroupSafe' not found. Trying as a standalone Host instead...[/]"
                        New-SANtricityVolumeMapping -VolumeName $volName -HostName $selectedGroup -ErrorAction Stop | Out-Null
                        Write-SpectreHost -Message "[green]Successfully mapped volume to Host '$selectedGroupSafe'![/]"
                    } else {
                        throw $_
                    }
                }
            } catch {
                $mapErr = $_.ToString().Replace('[', '(').Replace(']', ')')
                Write-SpectreHost -Message "[yellow]Volume created, but failed to map to '$selectedGroupSafe': $mapErr[/]"
            }
        }
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Error creating volume: $err[/]"
    }
}

function Remove-SanmoxVolume {
    [CmdletBinding()]
    param()
    
    Write-SpectreHost -Message ""
    Write-SpectreHost -Message "[red]========================= WARNING =========================[/]"
    Write-SpectreHost -Message "[yellow]This action WILL DESTROY the LUN on the SANtricity array.[/]"
    Write-SpectreHost -Message "[yellow]If Proxmox is still using this LUN as an LVM Datastore, you[/]"
    Write-SpectreHost -Message "[yellow]MUST first:[/]"
    Write-SpectreHost -Message "[white]  1. Remove the LVM Datastore from Proxmox GUI / CLI[/]"
    Write-SpectreHost -Message "[white]  2. Wipe the VG from the PVE hosts (e.g., via `vgremove`)[/]"
    Write-SpectreHost -Message "[red]===========================================================[/]"
    Write-SpectreHost -Message ""
    
    $proceed = Read-SpectreSelection -Title "WARNING: Have you fully removed the LVM and VG from Proxmox for this volume?" -Choices @(
        "N. No, cancel this operation so I can clean up Proxmox first",
        "Y. Yes, Proxmox is clean (or this volume is completely unused/unmapped)"
    )

    if ($proceed -notmatch '^Y') {
        Write-SpectreHost -Message "[cyan]Operation cancelled. Clean up Proxmox first, then return![/]"
        return
    }

    $volName = Read-SpectreText -Message "Enter the EXACT name of the SANtricity volume to destroy"
    $confirm = Read-SpectreSelection -Title "DESTRUCTIVE ACTION: Are you absolutely sure you want to delete '$volName'?" -Choices @("N. No, cancel", "Y. Yes, destroy the volume")
    
    if ($confirm -match '^Y') {
        try {
            Remove-SANtricityVolume -VolumeName $volName -Force
            $volNameSafe = $volName.ToString().Replace('[', '[[').Replace(']', ']]')
            Write-SpectreHost -Message "[green]Successfully destroyed volume $volNameSafe[/]"
        } catch {
            $err = $_.ToString().Replace('[', '(').Replace(']', ')')
            Write-SpectreHost -Message "[red]Error removing volume: $err[/]"
        }
    } else {
        Write-SpectreHost -Message "[cyan]Deletion cancelled.[/]"
    }
}

function Set-SanmoxVolume {
    [CmdletBinding()]
    param()
    
    Write-SpectreHost -Message "[cyan]Volume Modification Wizard[/]"

    $poolNameConfig = $Global:sanConfig.SanPoolName
    $pool = $null
    try {
        $pool = Get-SANtricityStoragePool -Name $poolNameConfig -ErrorAction Stop
    } catch {
        Write-SpectreHost -Message "[yellow]Could not resolve pool '$poolNameConfig'. Listing all SANtricity volumes for selection.[/]"
    }

    $volumes = @(Get-SANtricityVolume | Where-Object {
        if (-not $pool) { return $true }
        $_.pool -in $poolNameConfig -or
        ($pool.id -and $_.volumeGroupRef -in $pool.id) -or
        ($pool.id -and $_.pool -in $pool.id)
    })

    if ($volumes.Count -eq 0) {
        Write-SpectreHost -Message "[yellow]No volumes available to modify.[/]"
        return
    }

    $volumeChoices = @("Cancel") + @($volumes | Sort-Object name | Select-Object -ExpandProperty name)
    $volSelection = Read-SpectreSelection -Title "Select SANtricity volume to modify" -Choices $volumeChoices -Color Turquoise2 -PageSize 20 -EnableSearch
    if ($volSelection -eq "Cancel") {
        Write-SpectreHost -Message "[cyan]Operation cancelled.[/]"
        return
    }

    $volName = $volSelection

    $action = Read-SpectreSelection -Title "What would you like to modify?" -Choices @(
        "1. Resize Volume",
        "2. Cache & Media Scan Options",
        "3. Rename Volume",
        "C. Cancel"
    )

    try {
        if ($action -match "^1") {
            # Since Read-SpectreText expects input, we only ask for size if they explicitly chose to resize
            $newSizeStr = Read-SpectreText -Message "Enter new total size (e.g., 200GB, 1TB)"
            
            if ($newSizeStr -match '^\s*(?<size>\d+)\s*(?<unit>[gmtGDT]?[bB])?\s*$') {
                $newSize = [int]$matches['size']
                $newUnit = if ($matches['unit']) { $matches['unit'].ToLower() } else { 'gb' }
            } else {
                Write-SpectreHost -Message "[red]Invalid size format. Please use a number followed by GB or TB.[/]"
                return
            }

            Write-SpectreHost -Message "[cyan]Resizing volume to $newSize $newUnit...[/]"
            Resize-SANtricityVolume -VolumeName $volName -Size $newSize -SizeUnit $newUnit
            Write-SpectreHost -Message "[green]Volume expanded on SANtricity![/]"
            Write-SpectreHost -Message "[yellow]=> REMINDER: To use the new capacity in Proxmox, rescan the disk and run 'pvresize /dev/disk/by-id/...<your-device-id>' on the PVE host [bold]where the volume is active[/].[/]"
            Write-SpectreHost -Message "[green]Volume update complete.[/]"

        } elseif ($action -match "^2") {
            Write-SpectreHost -Message "[cyan]Fetching current cache & scan settings for $volName...[/]"
            $volInfo = Get-SANtricityVolume -Name $volName

            if (-not $volInfo) {
                Write-SpectreHost -Message "[red]Could not retrieve volume settings for '$volName'.[/]"
                return
            }
            if ($volInfo -is [System.Array]) {
                $volInfo = $volInfo | Select-Object -First 1
            }
            
            $defaults = @()
            if ($volInfo.cache.readCacheEnable) { $defaults += "Read Cache" }
            if ($volInfo.cache.writeCacheEnable) { $defaults += "Write Cache" }
            if ($volInfo.mediaScan.enable) { $defaults += "Media Scan" }
            if ($volInfo.cache.readAheadMultiplier -gt 0) { $defaults += "Read Ahead Cache" }

            $featureChoices = @(
                "Read Cache",
                "Write Cache",
                "Media Scan",
                "Read Ahead Cache"
            )

            $currentTable = $featureChoices | ForEach-Object {
                $on = $defaults -contains $_
                [PSCustomObject]@{
                    'Current'  = if ($on) { '[green]✓ Enabled[/]' } else { '[grey]✗ Disabled[/]' }
                    'Property' = $_
                }
            }

            Write-SpectreHost -Message ""
            Write-SpectreHost -Message "[yellow]Current settings for [white]$volName[/]:[/]"
            try { Format-SpectreTable -Data $currentTable } catch { $currentTable | Format-Table -AutoSize }

            Write-SpectreHost -Message "[cyan]Select the features you want ENABLED below. Unselected items will be DISABLED.[/]"
            $selected = Read-SpectreMultiSelection -Title "Toggle for $volName" -Choices $featureChoices
            if ($null -eq $selected) {
                Write-SpectreHost -Message "[cyan]Volume settings update cancelled.[/]"
                return
            }

            $before = if ($defaults.Count -gt 0) { $defaults -join ', ' } else { 'None' }
            $after = if ($selected.Count -gt 0) { $selected -join ', ' } else { 'None' }
            Write-SpectreHost -Message "[yellow]Current:[/] [white]$before[/]"
            Write-SpectreHost -Message "[yellow]Requested:[/] [white]$after[/]"
            $confirmApply = Read-SpectreSelection -Title "Apply these cache/scan settings?" -Choices @("Y. Yes", "N. No")
            if ($confirmApply -notmatch '^Y') {
                Write-SpectreHost -Message "[cyan]Volume settings update cancelled.[/]"
                return
            }
            
            $rc = $selected -contains "Read Cache"
            $wc = $selected -contains "Write Cache"
            $ms = $selected -contains "Media Scan"
            $ra = $selected -contains "Read Ahead Cache"
            
            Write-SpectreHost -Message "[cyan]Applying new cache/scan settings to $volName...[/]"
            Set-SANtricityVolume -VolumeName $volName -ReadCacheEnabled:$rc -WriteCacheEnabled:$wc -MediaScanEnabled:$ms -ReadAheadEnabled:$ra
            Write-SpectreHost -Message "[green]Volume update complete.[/]"

        } elseif ($action -match "^3") {
            Write-SpectreHost -Message ""
            Write-SpectreHost -Message "[yellow]Note: Renaming a SANtricity volume only changes its display label on the array.[/]"
            Write-SpectreHost -Message "[yellow]It does NOT break Proxmox NVMe/iSCSI paths (which rely on EUI/WWN numbers).[/]"
            Write-SpectreHost -Message "[yellow]However, it may cause administrative confusion if the array name diverges from the PVE Datastore name.[/]"
            Write-SpectreHost -Message ""
            
            $newName = Read-SpectreText -Message "Enter new volume name"
            Write-SpectreHost -Message "[cyan]Renaming volume from $volName to $newName...[/]"
            Set-SANtricityVolume -VolumeName $volName -NewName $newName
            Write-SpectreHost -Message "[green]Volume update complete.[/]"
        } else {
            Write-SpectreHost -Message "[cyan]Volume modification cancelled.[/]"
            return
        }
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Error modifying volume: $err[/]"
    }
}