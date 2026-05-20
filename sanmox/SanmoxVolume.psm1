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

function Convert-SanmoxVolumeSizeInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputText
    )

    if ($InputText -notmatch '^\s*(?<size>\d+)\s*(?<unit>mib|mi|mb|m|gib|gi|gb|g|tib|ti|tb|t)?\s*$') {
        return $null
    }

    $size = [int]$matches['size']
    $rawUnit = if ($matches['unit']) { $matches['unit'].ToLowerInvariant() } else { '' }

    $normalizedUnit = switch ($rawUnit) {
        ''    { 'gb' }
        'm'   { 'mb' }
        'mi'  { 'mb' }
        'mib' { 'mb' }
        'mb'  { 'mb' }
        'g'   { 'gb' }
        'gi'  { 'gb' }
        'gib' { 'gb' }
        'gb'  { 'gb' }
        't'   { 'tb' }
        'ti'  { 'tb' }
        'tib' { 'tb' }
        'tb'  { 'tb' }
        default { $null }
    }

    if ($null -eq $normalizedUnit) {
        return $null
    }

    $displayUnit = switch ($normalizedUnit) {
        'mb' { 'MB' }
        'gb' { 'GB' }
        'tb' { 'TB' }
    }

    [PSCustomObject]@{
        Size           = $size
        SizeUnit       = $normalizedUnit
        DisplayUnit    = $displayUnit
        OriginalInput  = $InputText.Trim()
    }
}

function Get-SanmoxTargetTransport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetName
    )

    $getHostProtocols = {
        param($HostObject)

        $protocols = @()

        foreach ($hostSidePort in @($HostObject.hostSidePorts)) {
            if ($null -ne $hostSidePort -and -not [string]::IsNullOrWhiteSpace([string]$hostSidePort.type)) {
                $protocols += [string]$hostSidePort.type
            }
        }

        foreach ($initiator in @($HostObject.initiators)) {
            if ($null -ne $initiator.nodeName -and -not [string]::IsNullOrWhiteSpace([string]$initiator.nodeName.ioInterfaceType)) {
                $protocols += [string]$initiator.nodeName.ioInterfaceType
            }
        }

        foreach ($port in @($HostObject.ports)) {
            if ($null -ne $port) {
                if (-not [string]::IsNullOrWhiteSpace([string]$port.type)) {
                    $protocols += [string]$port.type
                } elseif (-not [string]::IsNullOrWhiteSpace([string]$port.portType)) {
                    $protocols += [string]$port.portType
                }
            }
        }

        @(
            $protocols |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
                Select-Object -Unique
        )
    }

    $allHostGroups = @(Get-SANtricityHostGroup)
    $allHosts = @(Get-SANtricityHost)

    $existingGroup = $allHostGroups | Where-Object { $_.name -eq $TargetName -or $_.label -eq $TargetName } | Select-Object -First 1
    if ($existingGroup) {
        $memberHosts = @($allHosts | Where-Object { $_.clusterRef -eq $existingGroup.id })
        $protocols = foreach ($memberHost in $memberHosts) {
            & $getHostProtocols $memberHost
        }
        $uniqueProtocols = @($protocols | Select-Object -Unique)
        if ($uniqueProtocols.Count -eq 0) { return 'unknown' }
        if ($uniqueProtocols.Count -eq 1) { return [string]$uniqueProtocols[0] }
        return ($uniqueProtocols -join '+')
    }

    $existingHost = $allHosts | Where-Object { $_.name -eq $TargetName -or $_.label -eq $TargetName } | Select-Object -First 1
    if ($existingHost) {
        $hostProtocols = @(& $getHostProtocols $existingHost)
        $uniqueHostProtocols = @($hostProtocols | Select-Object -Unique)
        if ($uniqueHostProtocols.Count -eq 0) { return 'unknown' }
        if ($uniqueHostProtocols.Count -eq 1) { return [string]$uniqueHostProtocols[0] }
        return ($uniqueHostProtocols -join '+')
    }

    return 'unknown'
}

function Get-SanmoxPveCliHintData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VolumeName,

        [string]$PreferredTargetName
    )

    $mappings = @(Get-SANtricityMappingsReport | Where-Object { $_.mappableObjectName -eq $VolumeName })
    if ($PreferredTargetName) {
        $preferredMappings = @($mappings | Where-Object {
            ([string]$_.targetLabel -eq $PreferredTargetName) -or ([string]$_.hostGroup -eq $PreferredTargetName)
        })
        if ($preferredMappings.Count -gt 0) {
            $mappings = $preferredMappings
        }
    }

    if ($mappings.Count -eq 0) {
        return $null
    }

    $mapping = $mappings | Select-Object -First 1
    $targetName = if ($mapping.PSObject.Properties['hostGroup'] -and -not [string]::IsNullOrWhiteSpace([string]$mapping.hostGroup)) {
        [string]$mapping.hostGroup
    } elseif ($mapping.PSObject.Properties['targetLabel'] -and -not [string]::IsNullOrWhiteSpace([string]$mapping.targetLabel)) {
        [string]$mapping.targetLabel
    } else {
        [string]$PreferredTargetName
    }

    $transport = if (-not [string]::IsNullOrWhiteSpace($targetName)) {
        Get-SanmoxTargetTransport -TargetName $targetName
    } else {
        'unknown'
    }

    $isNvmeTransport = [string]$transport -match 'nvme'
    $isIscsiTransport = [string]$transport -match 'iscsi'

    $volumeWwn = if ($mapping.PSObject.Properties['volumeWwn'] -and -not [string]::IsNullOrWhiteSpace([string]$mapping.volumeWwn)) {
        [string]$mapping.volumeWwn
    } else {
        ''
    }

    $euiValue = ''
    if ($mapping.PSObject.Properties['volumeEui'] -and -not [string]::IsNullOrWhiteSpace([string]$mapping.volumeEui)) {
        $euiValue = [string]$mapping.volumeEui
    } elseif ($volumeWwn) {
        $euiValue = $volumeWwn
    }

    $euiPath = ''
    if ($isNvmeTransport -and $euiValue) {
        $normalizedEui = ($euiValue -replace '^0x', '').Trim().ToLowerInvariant()
        $euiPath = "/dev/disk/by-id/nvme-eui.$normalizedEui"
    }

    $altPath = ''
    if ($isNvmeTransport -and $null -ne $mapping.chassisSerialNumber -and $null -ne $mapping.lunId) {
        $altPath = "/dev/disk/by-id/nvme-NetApp_E-Series_" + $mapping.chassisSerialNumber + "_" + $mapping.lunId
    }

    $iscsiPaths = @()
    if ($isIscsiTransport) {
        try {
            $iscsiSettings = Get-SANtricityIscsiTargetSetting -ErrorAction Stop
            $iscsiTargetName = if ($iscsiSettings.nodeName -and $iscsiSettings.nodeName.iscsiNodeName) {
                [string]$iscsiSettings.nodeName.iscsiNodeName
            } else {
                ''
            }

            $lunValue = ''
            if ($mapping.PSObject.Properties['lunId'] -and -not [string]::IsNullOrWhiteSpace([string]$mapping.lunId)) {
                $lunValue = [string]$mapping.lunId
            } elseif ($mapping.PSObject.Properties['lun'] -and -not [string]::IsNullOrWhiteSpace([string]$mapping.lun)) {
                $lunValue = [string]$mapping.lun
            } elseif ($mapping.PSObject.Properties['logicalUnitNumber'] -and -not [string]::IsNullOrWhiteSpace([string]$mapping.logicalUnitNumber)) {
                $lunValue = [string]$mapping.logicalUnitNumber
            }

            if ($iscsiTargetName -and $lunValue) {
                $iscsiPaths = foreach ($portal in @($iscsiSettings.portals)) {
                    $ipv4Address = if ($portal.ipAddress) { $portal.ipAddress.ipv4Address } else { $null }
                    if ([string]::IsNullOrWhiteSpace([string]$ipv4Address)) { continue }
                    $portalLabel = if ($null -ne $portal.tcpListenPort) {
                        "$ipv4Address`:$($portal.tcpListenPort)"
                    } else {
                        [string]$ipv4Address
                    }
                    "/dev/disk/by-path/ip-$portalLabel-iscsi-$iscsiTargetName-lun-$lunValue"
                }
            }
        } catch {
        }
    }

    $primaryPath = if ($isNvmeTransport -and $euiPath) {
        $euiPath
    } elseif ($isNvmeTransport -and $altPath) {
        $altPath
    } elseif ($iscsiPaths.Count -gt 0) {
        [string]$iscsiPaths[0]
    } else {
        ''
    }

    [PSCustomObject]@{
        VolumeName   = $VolumeName
        TargetName   = $targetName
        Transport    = [string]$transport
        PrimaryPath  = $primaryPath
        IscsiPaths   = @($iscsiPaths)
        EuiPath      = $euiPath
        AltPath      = $altPath
        VgName       = if ($VolumeName -match '^vg_') { $VolumeName } else { "vg_$VolumeName" }
        VolumeWwn    = $volumeWwn
    }
}

function Show-SanmoxPveCliHint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VolumeName,

        [string]$PreferredTargetName
    )

    $volNameSafe = $VolumeName.ToString().Replace('[', '[[').Replace(']', ']]')
    $answer = Read-SpectreSelection -Title "Would you like to show a hint for PVE CLI commands to create PV and VG on '$volNameSafe'?" -Choices @(
        'Y. Yes',
        'N. No'
    ) -Color Turquoise2

    if ($answer -notmatch '^Y') {
        return
    }

    Write-SpectreHost -Message "[cyan]Okay. Make sure the device is visible on the correct PVE node and not currently in use.[/]"

    try {
        $hintData = Get-SanmoxPveCliHintData -VolumeName $VolumeName -PreferredTargetName $PreferredTargetName
        if ($null -eq $hintData) {
            Write-SpectreHost -Message "[yellow]Could not derive a mapped device path for volume '$volNameSafe' yet. Discover/login/connect the volume on the PVE host first, then use lsblk or /dev/disk/by-id to find it.[/]"
            return
        }

        Write-SpectreHost -Message "[cyan]Generated PVE CLI commands for volume '$volNameSafe':[/]"
        Write-SpectreHost -Message "[cyan]Note:[/] Run these on the correct PVE node after iSCSI login or NVMe connect/discover completes. Verify the device path before writing labels or LVM metadata."

        if ([string]::IsNullOrWhiteSpace($hintData.PrimaryPath)) {
            Write-SpectreHost -Message "[yellow]No single primary device path could be derived automatically for transport '$($hintData.Transport)'.[/]"
            if ($hintData.EuiPath) {
                Write-SpectreHost -Message "Preferred NVMe EUI path: $($hintData.EuiPath)"
            }
            if ($hintData.AltPath) {
                Write-SpectreHost -Message "Alternate NVMe path: $($hintData.AltPath)"
            }
            foreach ($candidatePath in @($hintData.IscsiPaths)) {
                Write-SpectreHost -Message "Candidate iSCSI path: $candidatePath"
            }
            Write-SpectreHost -Message "[yellow]After the device appears on the host, create the VG with:[/] vgcreate $($hintData.VgName) <device-path>"
            return
        }

        Write-SpectreHost -Message "parted $($hintData.PrimaryPath) mklabel gpt"
        Write-SpectreHost -Message "pvcreate -y -ff $($hintData.PrimaryPath)"
        Write-SpectreHost -Message "vgcreate $($hintData.VgName) $($hintData.PrimaryPath)"

        if ($hintData.EuiPath -or $hintData.AltPath -or $hintData.IscsiPaths.Count -gt 1) {
            Write-SpectreHost -Message "[yellow]Prefer the most persistent path available:[/]"
            if ($hintData.EuiPath) {
                Write-SpectreHost -Message "- NVMe EUI path: $($hintData.EuiPath)"
            }
            if ($hintData.AltPath) {
                Write-SpectreHost -Message "- NVMe alternate path: $($hintData.AltPath)"
            }
            foreach ($candidatePath in @($hintData.IscsiPaths)) {
                Write-SpectreHost -Message "- iSCSI path: $candidatePath"
            }
        }

        Write-SpectreHost -Message "[yellow]PVE 'shared 1' is not the same as LVM lvmlockd shared VGs (`vgcreate --shared`). For standard Proxmox shared LVM-on-SAN workflows, use regular `vgcreate` unless you have explicitly designed for lvmlockd/sanlock or dlm.[/]"
    } catch {
        $hintErr = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[yellow]Failed to generate CLI hint: $hintErr[/]"
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

    $volSizeStr = Read-SpectreText -Message "Enter the size (examples: 10, 10Gi, 10GiB, 10GB, 10G; 10 defaults to SANtricity 'gb')"
    if ([string]::IsNullOrWhiteSpace($volSizeStr) -or $volSizeStr -match '^(?i)c(ancel)?$') {
        Write-SpectreHost -Message "[cyan]Create volume cancelled.[/]"
        return
    }

    $parsedCreateSize = Convert-SanmoxVolumeSizeInput -InputText $volSizeStr
    if ($null -eq $parsedCreateSize) {
        Write-SpectreHost -Message "[red]Invalid size format. Use examples like 10, 10Gi, 10GiB, 10GB, 10G, 2TB, or 512MB.[/]"
        return
    }

    $volSize = $parsedCreateSize.Size
    $volUnit = $parsedCreateSize.SizeUnit
    $volDisplayUnit = $parsedCreateSize.DisplayUnit

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

    Write-SpectreHost -Message "[cyan]Creating volume '$volNameSafe' with size $volSize $volDisplayUnit (SANtricity API unit: $volUnit) on pool $poolName...[/]"
    try {
        $mappingSucceeded = $false
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
                    $mappingSucceeded = $true
                    Write-SpectreHost -Message "[green]Successfully mapped volume to Host Group '$selectedGroupSafe'![/]"
                } catch {
                    if ($_.Exception.Message -match "not found") {
                        # Fallback to try mapping as a standalone Host
                        Write-SpectreHost -Message "[yellow]Host Group '$selectedGroupSafe' not found. Trying as a standalone Host instead...[/]"
                        New-SANtricityVolumeMapping -VolumeName $volName -HostName $selectedGroup -ErrorAction Stop | Out-Null
                        $mappingSucceeded = $true
                        Write-SpectreHost -Message "[green]Successfully mapped volume to Host '$selectedGroupSafe'![/]"
                    } else {
                        throw $_
                    }
                }
            } catch {
                $mapErr = $_.ToString().Replace('[', '(').Replace(']', ')')
                Write-SpectreHost -Message "[yellow]Volume created, but failed to map to '$selectedGroupSafe': $mapErr[/]"
            }

            if ($mappingSucceeded) {
                $volNameSafePrompt = $volName.ToString().Replace('[', '[[').Replace(']', ']]')
                Write-SpectreHost -Message ""
                $setupPve = Read-SpectreSelection -Title "Proxmox UI datastore setup: Do you want to automatically scan and configure this new LUN to the PVE Datacenter right now?" -Choices @("Y. Yes, configure fully automated", "N. No, return to menu") -Color Turquoise2
                if ($setupPve -match "^Y") {
                    # Injecting the handoff directly into the New-SanmoxPveStorage automated wizard!
                    New-SanmoxPveStorage -VolumeName $volName
                } else {
                    Write-SpectreHost -Message "[grey]Skipping automated PVE storage initialization.[/]"
                }
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

    $sortedVolumes = @($volumes | Sort-Object name)
    $volumeTable = @()
    for ($i = 0; $i -lt $sortedVolumes.Count; $i++) {
        $volumeTable += [PSCustomObject]@{
            'No' = $i + 1
            'Volume' = $sortedVolumes[$i].name
            'Size(GiB)' = [math]::Round(($sortedVolumes[$i].capacity / 1GB), 2)
        }
    }

    Write-SpectreHost -Message "[cyan]Available volumes (sorted):[/]"
    if (Get-Command -Name Format-SpectreTable -ErrorAction SilentlyContinue) {
        Format-SpectreTable -Data $volumeTable
    } else {
        $volumeTable | Format-Table -AutoSize | Out-String | Write-Host
    }

    $volumeChoices = @("0. Cancel") + @($volumeTable | ForEach-Object { "$($_.No). $($_.Volume) ($($_.'Size(GiB)') GiB)" })
    $volSelection = Read-SpectreSelection -Title "Select SANtricity volume to modify" -Choices $volumeChoices -Color Turquoise2 -PageSize 20 -EnableSearch
    if ($volSelection -match '^0\.') {
        Write-SpectreHost -Message "[cyan]Operation cancelled.[/]"
        return
    }

    $selectedIndex = 0
    if ($volSelection -match '^(\d+)\.') {
        $selectedIndex = [int]$matches[1]
    }
    if ($selectedIndex -lt 1 -or $selectedIndex -gt $sortedVolumes.Count) {
        Write-SpectreHost -Message "[red]Invalid volume selection.[/]"
        return
    }

    $selectedVolume = $sortedVolumes[$selectedIndex - 1]
    $volName = $selectedVolume.name
    $currentSizeGiB = [math]::Round(($selectedVolume.capacity / 1GB), 2)

    $action = Read-SpectreSelection -Title "What would you like to modify?" -Choices @(
        "1. Resize Volume",
        "2. Cache & Media Scan Options",
        "3. Rename Volume",
        "C. Cancel"
    )

    try {
        if ($action -match "^1") {
            # Since Read-SpectreText expects input, we only ask for size if they explicitly chose to resize
            $newSizeStr = Read-SpectreText -Message "Enter new total size (examples: 200, 200Gi, 200GB, 1TB). Current size: $currentSizeGiB GiB"
            
            $parsedResizeSize = Convert-SanmoxVolumeSizeInput -InputText $newSizeStr
            if ($null -eq $parsedResizeSize) {
                Write-SpectreHost -Message "[red]Invalid size format. Use examples like 200, 200Gi, 200GiB, 200GB, 1TB, or 512MB.[/]"
                return
            }

            $newSize = $parsedResizeSize.Size
            $newUnit = $parsedResizeSize.SizeUnit
            $newDisplayUnit = $parsedResizeSize.DisplayUnit

            $unitFactor = switch ($newUnit) {
                'mb' { 1MB }
                'gb' { 1GB }
                'tb' { 1TB }
                default {
                    Write-SpectreHost -Message "[red]Unsupported size unit '$newUnit'. Please use MB, GB, or TB.[/]"
                    return
                }
            }
            $targetSizeBytes = [int64]$newSize * [int64]$unitFactor
            $currentSizeBytes = [int64]$selectedVolume.capacity
            if ($targetSizeBytes -le $currentSizeBytes) {
                Write-SpectreHost -Message "[yellow]Resize cancelled. Target size must be greater than current size ($currentSizeGiB GiB).[/]"
                return
            }

            Write-SpectreHost -Message "[cyan]Resizing volume to $newSize $newDisplayUnit (SANtricity API unit: $newUnit)...[/]"
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
            $selected = Read-SanmoxMultiSelection -Message "Toggle for $volName" -Choices $featureChoices -PreSelected $defaults
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
