function Invoke-SanmoxPveSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$NodeAddress,

        [Parameter(Mandatory=$true)]
        [string]$Command
    )
    
    $sshCmd = "ssh -o StrictHostKeyChecking=no -o BatchMode=yes root@$NodeAddress '$Command'"
    Write-Verbose "Executing SSH on $($NodeAddress): $Command"
    
    try {
        $result = Invoke-Expression $sshCmd
        return $result
    } catch {
        Write-Warning "SSH execution failed on $NodeAddress : $_"
        throw
    }
}
function New-SanmoxPveStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$VolumeName
    )

    Write-SpectreHost -Message "[cyan]Configuring Proxmox VE Storage...[/]"

    if (-not $Global:pveConnected) {
        Write-SpectreHost -Message "[red]Proxmox VE is not connected. Connect first or exit restricted mode.[/]"
        return
    }

    # Fetch PVE cluster status to check for offline nodes
    $skipCert = if ($null -ne $Global:sanConfig.SkipCertificateCheck) { [bool]$Global:sanConfig.SkipCertificateCheck } else { $false }
    $pveUri = $Global:sanConfig.PveApiUri.TrimEnd('/')
    
    $clusterParams = @{
        Uri = "$pveUri/api2/json/cluster/status"
        Method = "GET"
        Headers = $Global:pveHeaders
        SkipHeaderValidation = $true
    }
    if ($skipCert) { $clusterParams.Add('SkipCertificateCheck', $true) }
    
    try {
        $clusterStatus = Invoke-RestMethod @clusterParams
        $nodes = $clusterStatus.data | Where-Object { $_.type -eq 'node' }
        $offlineNodes = $nodes | Where-Object { $_.online -eq 0 }
        
        if ($offlineNodes) {
            $offlineNames = ($offlineNodes | Select-Object -ExpandProperty name) -join ', '
            Write-SpectreHost -Message "[red]WARNING: One or more PVE nodes are currently offline: $offlineNames.[/]"
            $proceed = Read-SpectreSelection -Title "Do you still want to proceed with Datastore creation?" -Choices @("N. No (Abort)", "Y. Yes (Proceed)")
            if ($proceed -match '^N') {
                Write-SpectreHost -Message "[cyan]Aborted Datastore creation.[/]"
                return
            }
        }
        
    } catch {
        Write-SpectreHost -Message "[yellow]Could not query cluster status to verify node health. Proceeding...[/]"
    }

    $apiParams = @{
        Uri = "$pveUri/api2/json/nodes"
        Method = "GET"
        Headers = $Global:pveHeaders
        SkipHeaderValidation = $true
    }
    if ($skipCert) { $apiParams.Add('SkipCertificateCheck', $true) }
    
    $nodesResponse = Invoke-RestMethod @apiParams
    $pveNodes = $nodesResponse.data.node

    if ($null -eq $pveNodes -or $pveNodes.Count -eq 0) {
        Write-SpectreHost -Message "[red]Failed to retrieve PVE nodes.[/]"
        return
    }
    
    # 1. Handle PVE-side host restriction (defaulting to the whole cluster per your 90/10 design)
    $choices = @("All Nodes (Default)") + $pveNodes
    
    Write-SpectreHost -Message "SANtricity will map the LUN to the cluster Host Group. You can restrict Proxmox-side visibility here."
    $selectedNodes = Read-SpectreMultiSelection -Title "Select PVE hosts for access (Space to select, Enter to finish)" -Choices $choices

    $restrictNodes = $null
    if ($selectedNodes.Count -eq 0 -or $selectedNodes -contains "All Nodes (Default)") {
        Write-SpectreHost -Message "[green]-> Datastore will be configured for the full PVE Cluster.[/]"
    } else {
        $restrictNodes = $selectedNodes -join ","
        Write-SpectreHost -Message "[yellow]-> Datastore restricted locally on PVE to nodes: $restrictNodes (e.g. for Btrfs/ZFS single-node use)[/]"
    }

    # 2. Handle Protocol differences (iSCSI automation vs NVMe-RoCE manual steps)
    $protocolChoices = @(
        "1. iSCSI (Automated API discovery)", 
        "2. NVMe-RoCE (Requires manual OS-level scan)"
    )
    $protocol = Read-SpectreSelection -Title "Select storage protocol used for this mapping" -Choices $protocolChoices -Color Turquoise2

    if ($protocol -match "^1") {
        $portalIP = Read-Host "Enter the SANtricity iSCSI Portal IP Address"
        $scanNode = $pveNodes[0]
        
        Write-SpectreHost -Message "[cyan]Scanning for iSCSI targets on portal $portalIP via node $scanNode...[/]"
        $scanParams = @{
            Uri = "$pveUri/api2/json/nodes/$scanNode/scan/iscsi?portal=$portalIP"
            Method = "GET"
            Headers = $Global:pveHeaders
            SkipHeaderValidation = $true
        }
        if ($skipCert) { $scanParams.Add('SkipCertificateCheck', $true) }
        
        try {
            $scanRes = Invoke-RestMethod @scanParams
            $targets = $scanRes.data.target
            
            if (-not $targets) {
                Write-SpectreHost -Message "[red]No iSCSI targets found on $portalIP.[/]"
                return
            }
            
            $targetSelection = Read-SpectreSelection -Title "Select iSCSI Target to connect" -Choices $targets -Color Turquoise2
            $storageName = Read-Host "Enter the name for the new PVE iSCSI Storage (e.g. sanmox-iscsi)"
            
            $addIscsiParams = @{
                Uri = "$pveUri/api2/json/storage"
                Method = "POST"
                Headers = $Global:pveHeaders
                SkipHeaderValidation = $true
                Body = @{
                    storage = $storageName
                    type = "iscsi"
                    portal = $portalIP
                    target = $targetSelection
                    content = "none"
                }
            }
            if ($restrictNodes) { $addIscsiParams.Body.nodes = $restrictNodes }
            if ($skipCert) { $addIscsiParams.Add('SkipCertificateCheck', $true) }
            
            Invoke-RestMethod @addIscsiParams | Out-Null
            Write-SpectreHost -Message "[green]iSCSI Storage '$storageName' created![/]"
            
            $createLvm = Read-SpectreSelection -Title "Create a shared LVM pool on top of this iSCSI target?" -Choices @("Y. Yes", "N. No")
            if ($createLvm -match "^Y") {
                $lvmName = Read-Host "Enter the LVM Storage Name (e.g. sanmox-lvm)"
                $vgName = Read-Host "Enter the Volume Group name to create (e.g. vg-sanmox)"
                $addLvmParams = @{
                    Uri = "$pveUri/api2/json/storage"
                    Method = "POST"
                    Headers = $Global:pveHeaders
                    SkipHeaderValidation = $true
                    Body = @{
                        storage = $lvmName
                        type = "lvm"
                        base = $storageName
                        vgname = $vgName
                        shared = 1
                        content = "images,rootdir"
                        saferemove = 1
                        'snapshot-as-volume-chain' = 1
                    }
                }
                if ($restrictNodes) { $addLvmParams.Body.nodes = $restrictNodes }
                if ($skipCert) { $addLvmParams.Add('SkipCertificateCheck', $true) }
                
                Invoke-RestMethod @addLvmParams | Out-Null
                Write-SpectreHost -Message "[green]Shared LVM '$lvmName' created on top of '$storageName'![/]"
            }
        } catch {
            $err = $_.ToString().Replace('[', '(').Replace(']', ')')
            Write-SpectreHost -Message "[red]Failed during iSCSI configuration: $err[/]"
        }
    } else {
        Write-SpectreHost -Message ""
        Write-SpectreHost -Message "[cyan]Gathering NVMe interface data from SANtricity...[/]"
        try {
            $interfaces = Invoke-SANtricityRequest -Method GET -Path "/interfaces?channelType=hostside"
            
            $nvmePortals = @()
            foreach ($hw in @($interfaces)) {
                $ethernetData = if ($hw.ioInterfaceTypeData.interfaceType -eq 'ethernet') { $hw.ioInterfaceTypeData.ethernet.interfaceData.ethernetData } else { $null }
                if ($null -eq $ethernetData -or $ethernetData.linkStatus -ne 'up') { continue }
                
                # Dig into the port's protocol features to find NVMe over RoCE v2 IPs
                $protos = if ($hw.commandProtocolPropertiesList.commandProtocolProperties) { @($hw.commandProtocolPropertiesList.commandProtocolProperties) } else { @() }
                foreach ($cp in $protos) {
                    if ($cp.commandProtocol -eq 'nvme' -and $cp.nvmeProperties.commandSet -eq 'nvmeof') {
                        $roce = $cp.nvmeProperties.nvmeofProperties.roceV2Properties
                        if ($roce -and $roce.ipv4Enabled) {
                            $ipv4 = $roce.ipv4Data.ipv4Address
                            if (-not [string]::IsNullOrWhiteSpace($ipv4) -and $ipv4 -ne '0.0.0.0') {
                                $nvmePortals += $ipv4
                            }
                        }
                    }
                }
            }
            $nvmePortals = $nvmePortals | Sort-Object -Unique

            if (-not $nvmePortals) {
                Write-SpectreHost -Message "[red]Warning: No active NVMe over RoCE (IPv4) host portals found (Link Status: Up). Cannot automate nvme connect-all targeting.[/]"
                return
            }

            Write-SpectreHost -Message "[green]Connecting NVMe on all selected PVE hosts persistently (-p)...[/]"
            
            # Use $pveNodes array directly as user context is in $selectedNodes
            $targetNodes = if ($restrictNodes) { $restrictNodes -split "," } else { $pveNodes }
            
            foreach ($node in $targetNodes) {
                Write-SpectreHost -Message "  -> Connecting node: $node"
                foreach ($portal in $nvmePortals) {
                    try {
                        Invoke-SanmoxPveSsh -NodeAddress $node -Command "nvme connect-all -t rdma -a $portal -p" | Out-Null
                    } catch {
                        Write-SpectreHost -Message "[yellow]Warning: SSH command failed on $node for portal $portal. Check node connection.[/]"
                    }
                }
            }

            Write-SpectreHost -Message "[cyan]Sleeping 3 seconds for udev device propagation...[/]"
            Start-Sleep -Seconds 3

        } catch {
            Write-SpectreHost -Message "[red]Failed to connect NVMe array across ssh fabric: $_[/]"
            return
        }

        # Need the volume name to find the EUI
        if (-not $VolumeName) {
            $VolumeName = Read-Host "Enter the exact SANtricity Volume name you mapped to this datastore"
        }
        
        $primaryNode = if ($restrictNodes) { ($restrictNodes -split ",")[0] } else { $pveNodes[0] }
        Write-SpectreHost -Message "[cyan]Locating block device for volume '$VolumeName' on node $primaryNode...[/]"
        
        $hintData = Get-SanmoxPveCliHintData -VolumeName $VolumeName
        $devicePath = $hintData.EuiPath
        
        if (-not $devicePath) {
            Write-SpectreHost -Message "[red]Could not determine NVMe block device path dynamically for $VolumeName.[/]"
            return
        }

        Write-SpectreHost -Message "Located device path: $devicePath"
        $vgName = Read-Host "Enter the VG Name to create [Default: vg_$VolumeName]"
        if ([string]::IsNullOrWhiteSpace($vgName)) {
            $vgName = "vg_$VolumeName"
        }

        # PV/VG Creation via SSH
        Write-SpectreHost -Message "[cyan]Creating Physical Volume & Volume Group ($vgName) on node $primaryNode...[/]"
        try {
            Invoke-SanmoxPveSsh -NodeAddress $primaryNode -Command "pvcreate -y -ff $devicePath" | Out-Null
            Invoke-SanmoxPveSsh -NodeAddress $primaryNode -Command "vgcreate $vgName $devicePath" | Out-Null
            Write-SpectreHost -Message "[green]LVM VG initialized successfully![/]"
        } catch {
            Write-SpectreHost -Message "[red]Failed to run pvcreate/vgcreate: $_[/]"
            Write-SpectreHost -Message "[yellow]If it already exists, you can safely continue. Otherwise abort datastore creation.[/]"
        }

        $lvmName = Read-Host "Enter the Datastore Name [Default: lvm_$VolumeName]"
        if ([string]::IsNullOrWhiteSpace($lvmName)) {
            $lvmName = "lvm_$VolumeName"
        }

        Write-SpectreHost -Message "[cyan]Registering 'santricity_lvm' storage ($lvmName) in Proxmox Datacenter...[/]"
        $addDsParams = @{
            Uri = "$pveUri/api2/json/storage"
            Method = "POST"
            Headers = $Global:pveHeaders
            SkipHeaderValidation = $true
            Body = @{
                storage = $lvmName
                type = "santricity_lvm"
                vgname = $vgName
                'array_serial' = (Invoke-SANtricityRequest -Method GET -Path "/").chassisSerialNumber.Trim()
                shared = 1
                saferemove = 1
                'snapshot-as-volume-chain' = 1
                content = "images,rootdir"
            }
        }
        if ($restrictNodes) { $addDsParams.Body.nodes = $restrictNodes }
        if ($skipCert) { $addDsParams.Add('SkipCertificateCheck', $true) }
        
        try {
            Invoke-RestMethod @addDsParams | Out-Null
            Write-SpectreHost -Message "[green]NVMe Datastore '$lvmName' successfully registered in PVE![/]"
        } catch {
            $err = $_.ToString().Replace('[', '(').Replace(']', ')')
            Write-SpectreHost -Message "[red]Failed to add Datastore API entry: $err[/]"
        }
    }

    Write-SpectreHost -Message "[green]PVE Datastore Script Finished![/]"
}
function Remove-SanmoxPveStorage {
    [CmdletBinding()]
    param()
    
    Write-SpectreHost -Message ""
    Write-SpectreHost -Message "[red]========================= WARNING =========================[/]"
    Write-SpectreHost -Message "[yellow]This action WILL DESTROY the PVE Datastore configuration.[/]"
    Write-SpectreHost -Message "[yellow]Ensure the Datastore is completely empty (no VMs or CTs)![/]"
    Write-SpectreHost -Message "[red]===========================================================[/]"
    Write-SpectreHost -Message ""
    
    if (-not $Global:pveConnected) {
        Write-SpectreHost -Message "[red]Proxmox VE is not connected. Connect first or exit restricted mode.[/]"
        return
    }

    $proceed = Read-SpectreSelection -Title "WARNING: Is the PVE Datastore completely empty?" -Choices @(
        "N. No, cancel this operation so I can clean up Proxmox first",
        "Y. Yes, Proxmox is clean and the Datastore is empty"
    )

    if ($proceed -notmatch '^Y') {
        Write-SpectreHost -Message "[cyan]Operation cancelled. Clean up Proxmox first, then return![/]"
        return
    }

    # Fetch existing storages to let the user select
    $skipCert = if ($null -ne $Global:sanConfig.SkipCertificateCheck) { [bool]$Global:sanConfig.SkipCertificateCheck } else { $false }
    $pveUri = $Global:sanConfig.PveApiUri.TrimEnd('/')
    $apiParams = @{
        Uri = "$pveUri/api2/json/storage"
        Method = "GET"
        Headers = $Global:pveHeaders
        SkipHeaderValidation = $true
    }
    if ($skipCert) { $apiParams.Add('SkipCertificateCheck', $true) }
    
    try {
        $storageResponse = Invoke-RestMethod @apiParams
        $storages = $storageResponse.data | Where-Object { $_.type -in @('iscsi', 'lvm', 'lvmthin') } | Select-Object -ExpandProperty storage
        
        if ($null -eq $storages -or $storages.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]No iSCSI or LVM storages found on PVE.[/]"
            return
        }
        
        $choices = @("C. Cancel") + $storages
        $selectedStorage = Read-SpectreSelection -Title "Select the PVE Storage to remove" -Choices $choices -Color Turquoise2
        
        if ($selectedStorage -match "^C\. Cancel$") {
            Write-SpectreHost -Message "[cyan]Operation cancelled.[/]"
            return
        }
        
        $confirm = Read-SpectreSelection -Title "DESTRUCTIVE ACTION: Are you absolutely sure you want to remove PVE storage '$selectedStorage'?" -Choices @("N. No, cancel", "Y. Yes, remove the storage")
        if ($confirm -match '^Y') {
            Write-SpectreHost -Message "[cyan]Preparing to remove storage... fetching volume group details...[/]"
            try {
                $getParams = @{
                    Uri = "$pveUri/api2/json/storage/$selectedStorage"
                    Method = "GET"
                    Headers = $Global:pveHeaders
                    SkipHeaderValidation = $true
                }
                if ($skipCert) { $getParams.Add('SkipCertificateCheck', $true) }
                $storageDetails = Invoke-RestMethod @getParams
                $vgName = $storageDetails.data.vgname
                $storageType = $storageDetails.data.type
                
                if ($vgName -and ($storageType -eq 'lvm' -or $storageType -eq 'santricity_lvm')) {
                    $primaryNode = $Global:pveNodes[0]
                    Write-SpectreHost -Message "[cyan]Fetching underlying physical devices for VG '$vgName' on node $primaryNode...[/]"
                    
                    $pvList = Invoke-SanmoxPveSsh -NodeAddress $primaryNode -Command "vgs $vgName -o pv_name --noheadings" -ErrorAction SilentlyContinue
                    
                    if ($pvList) {
                        $devices = $pvList -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
                        
                        Write-SpectreHost -Message "[cyan]Removing VG '$vgName' via SSH...[/]"
                        Invoke-SanmoxPveSsh -NodeAddress $primaryNode -Command "vgremove -y $vgName" | Out-Null
                        
                        foreach ($dev in $devices) {
                            Write-SpectreHost -Message "[cyan]Removing PV on '$dev' via SSH...[/]"
                            Invoke-SanmoxPveSsh -NodeAddress $primaryNode -Command "pvremove -y $dev" | Out-Null
                        }
                        Write-SpectreHost -Message "[green]Successfully cleaned up VG and PV![/]"
                    } else {
                        Write-SpectreHost -Message "[yellow]Warning: Could not determine physical volumes for $vgName, or VG not found.[/]"
                    }
                }
            } catch {
                Write-SpectreHost -Message "[yellow]Warning: Failed to fetch storage info or perform LVM cleanup over SSH. Datastore removal will continue...[/]"
            }

            Write-SpectreHost -Message "[cyan]Removing Datastore '$selectedStorage' from PVE via API...[/]"
            $deleteParams = @{
                Uri = "$pveUri/api2/json/storage/$selectedStorage"
                Method = "DELETE"
                Headers = $Global:pveHeaders
                SkipHeaderValidation = $true
            }
            if ($skipCert) { $deleteParams.Add('SkipCertificateCheck', $true) }
            
            Invoke-RestMethod @deleteParams | Out-Null
            Write-SpectreHost -Message "[green]Successfully removed Datastore '$selectedStorage' from PVE![/]"
        } else {
            Write-SpectreHost -Message "[cyan]Deletion cancelled.[/]"
        }
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Failed to fetch or remove PVE storage: $err[/]"
    }
}

function Get-SanmoxStorageDiscoveryInfo {
    [CmdletBinding()]
    param()

    Write-SpectreHost -Message "[cyan]Gathering SANtricity discovery info...[/]"
    
    # 1. Get array serial number
    $sysInfo = Invoke-SANtricityRequest -Method GET -Path "/"
    $sn = $sysInfo.chassisSerialNumber.Trim()

    Write-SpectreHost -Message "[green]Chassis Serial Number:[/] $sn"

    # 2. Get iSCSI Interfaces
    $iscsiInterfaces = Get-SANtricityInterface -Summary -InterfaceType iscsi -ErrorAction SilentlyContinue
    $portals = $iscsiInterfaces | Where-Object { -not [string]::IsNullOrWhiteSpace($_.IPv4Address) -and $_.IPv4Address -ne '0.0.0.0' } | Select-Object -ExpandProperty IPv4Address | Select-Object -Unique

    if ($portals) {
        Write-SpectreHost -Message "[green]iSCSI Portals Found:[/] $($portals -join ', ')"
    } else {
        Write-SpectreHost -Message "[yellow]No active iSCSI portals found.[/]"
    }

    # 3. Output NVMe copy-paste helper
    Write-SpectreHost -Message ""
    Write-SpectreHost -Message "[darkorange]=== NVMe/RoCE Host-Side Discovery Helper ===[/]"
    Write-SpectreHost -Message "Run the following on your PVE nodes to find the device paths for this specific storage array:"
    Write-SpectreHost -Message "[white]nvme list -o json | jq -r '.Devices[] | select(.SerialNumber == `"$sn`") | .DevicePath'[/]"
    Write-SpectreHost -Message ""

    return [PSCustomObject]@{
        ChassisSerialNumber = $sn
        IscsiPortals = $portals
    }
}

function Get-SanmoxPveSantricityLvmDatastores {
    [CmdletBinding()]
    param()

    Write-SpectreRule -Title "SANtricity LVM Datastores (santricity_lvm) :eyes: | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Alignment Center -Color Cyan

    if (-not $Global:pveConnected) {
        Write-SpectreHost -Message "[red]Proxmox VE is not connected. Connect first or exit restricted mode.[/]"
        Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    $skipCert = if ($null -ne $Global:sanConfig.SkipCertificateCheck) { [bool]$Global:sanConfig.SkipCertificateCheck } else { $false }
    $pveUri = $Global:sanConfig.PveApiUri.TrimEnd('/')
    $apiParams = @{
        Uri = "$pveUri/api2/json/storage"
        Method = "GET"
        Headers = $Global:pveHeaders
        SkipHeaderValidation = $true
    }
    if ($skipCert) { $apiParams.Add('SkipCertificateCheck', $true) }
    
    try {
        $storageResponse = Invoke-RestMethod @apiParams
        $storages = @($storageResponse.data | Where-Object { $_.type -eq 'santricity_lvm' })
        
        if ($storages.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]No 'santricity_lvm' storages found in PVE.[/]"
            Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }

        Write-SpectreHost -Message "[cyan]Fetching SANtricity Volumes to cross-reference...[/]"
        $sanVolumes = @(Get-SANtricityVolume -ErrorAction SilentlyContinue)

        $tableData = foreach ($store in $storages) {
            $dsName = $store.storage
            $vgName = $store.vgname
            
            # Heuristic match: Volume might correspond to VG name stripped of "vg_"
            $probableVolName = if ($vgName -match "^vg_(.*)") { $matches[1] } else { $vgName }
            
            $sanVol = $null
            if ($probableVolName) {
                $sanVol = $sanVolumes | Where-Object { $_.name -ieq $probableVolName } | Select-Object -First 1
            }
            if (-not $sanVol -and $vgName) {
                $sanVol = $sanVolumes | Where-Object { $_.name -ieq $vgName } | Select-Object -First 1
            }

            $volId = if ($sanVol) { $sanVol.id } else { "[red]Not Found[/]" }
            $volStatus = if ($sanVol) { $sanVol.status } else { "?" }

            [PSCustomObject]@{
                'PVE Datastore' = $dsName
                'VG Name'       = $vgName
                'SAN Vol Name'  = if ($sanVol) { $sanVol.name } else { $probableVolName }
                'SAN Vol Status'= $volStatus
                'SAN Vol ID'    = $volId
                'Nodes'         = if ($store.nodes) { $store.nodes } else { 'All' }
            }
        }

        if (Get-Command -Name Format-SpectreTable -ErrorAction SilentlyContinue) {
            Format-SpectreTable -Data $tableData
        } else {
            $tableData | Format-Table -AutoSize | Out-String | Write-Host
        }
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Failed to fetch storages from PVE: $err[/]"
    }

    Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
