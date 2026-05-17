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

    # Fetch PVE nodes from the Proxmox API
    $skipCert = if ($null -ne $Global:sanConfig.SkipCertificateCheck) { [bool]$Global:sanConfig.SkipCertificateCheck } else { $false }
    $pveUri = $Global:sanConfig.PveApiUri.TrimEnd('/')
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
        Write-SpectreHost -Message "[darkorange]NOTICE: Proxmox VE API does not currently support `pvesm scan nvmeroce`.[/]"
        Write-SpectreHost -Message "[darkorange]Please SSH into the target PVE node(s) and run `nvme discover` / `nvme connect` manually.[/]"
        Write-SpectreHost -Message ""
        
        $pause = Read-SpectreSelection -Title "Have you completed the manual NVMe-RoCE scan on the hosts?" -Choices @("Y. Yes, continue to add datastore", "N. No, abort for now")
        if ($pause -match "^Y") {
            Write-SpectreHost -Message "[cyan]Configuring NVMe-backed Datastore on PVE Datacenter...[/]"
            
            $vgName = Read-Host "Enter the exact Volume Group (VG) name you created on the SANtricity disk (e.g. vg_sanmox03)"
            if ([string]::IsNullOrWhiteSpace($vgName)) {
                $vgName = "vg_sanmox_nvme"
            }
            
            # Derive the datastore name gracefully 
            $storageName = if ($vgName -match "^vg_(.*)") { "lvm_$($matches[1])" } else { "lvm_$vgName" }
            
            Write-SpectreHost -Message "[cyan]Verifying if VG '$vgName' is visible to PVE...[/]"
            $vgExists = $false
            try {
                $scanNode = $pveNodes[0]
                $vgCheckParams = @{
                    Uri = "$pveUri/api2/json/nodes/$scanNode/scan/lvm"
                    Method = "GET"
                    Headers = $Global:pveHeaders
                    SkipHeaderValidation = $true
                }
                if ($skipCert) { $vgCheckParams.Add('SkipCertificateCheck', $true) }
                $vgRes = Invoke-RestMethod @vgCheckParams -ErrorAction Stop
                
                if ($vgRes.data.vg -contains $vgName) {
                    $vgExists = $true
                    Write-SpectreHost -Message "[green]Successfully located Volume Group '$vgName'![/]"
                } else {
                    Write-SpectreHost -Message "[yellow]Warning: Could not strictly verify VG '$vgName' via API. Ensure it is mapped correctly![/]"
                }
            } catch {
                Write-SpectreHost -Message "[yellow]Failed to query LVM subsystem. Proceeding with caution...[/]"
            }

            Write-SpectreHost -Message "[cyan]Verifying if datastore '$storageName' already exists...[/]"
            $exists = $false
            try {
                $checkParams = @{
                    Uri = "$pveUri/api2/json/storage/$storageName"
                    Method = "GET"
                    Headers = $Global:pveHeaders
                    SkipHeaderValidation = $true
                }
                if ($skipCert) { $checkParams.Add('SkipCertificateCheck', $true) }
                Invoke-RestMethod @checkParams -ErrorAction Stop | Out-Null
                $exists = $true
                Write-SpectreHost -Message "[yellow]Datastore '$storageName' already exists. Skipping creation.[/]"
            } catch {
                # 404 or related failure means it doesn't exist yet, we can proceed
            }
            
            if (-not $exists) {
                Write-SpectreHost -Message "[cyan]Creating Datastore '$storageName' backed by Volume Group '$vgName'...[/]"
                $storageParams = @{
                    Uri = "$pveUri/api2/json/storage"
                    Method = "POST"
                    Headers = $Global:pveHeaders
                    SkipHeaderValidation = $true
                    Body = @{
                        storage = $storageName
                        type = "lvm"
                        vgname = $vgName
                        shared = 1
                        content = "images,rootdir"
                        saferemove = 1
                        'snapshot-as-volume-chain' = 1
                    }
                }
                if ($restrictNodes) {
                    $storageParams.Body.nodes = $restrictNodes
                }
                if ($skipCert) { $storageParams.Add('SkipCertificateCheck', $true) }
                
                try {
                    Invoke-RestMethod @storageParams | Out-Null
                    
                    # Read back status
                    $verifyConfig = @{
                        Uri = "$pveUri/api2/json/storage/$storageName"
                        Method = "GET"
                        Headers = $Global:pveHeaders
                        SkipHeaderValidation = $true
                    }
                    if ($skipCert) { $verifyConfig.Add('SkipCertificateCheck', $true) }
                    
                    try {
                        Invoke-RestMethod @verifyConfig -ErrorAction Stop | Out-Null
                        Write-SpectreHost -Message "[green]PVE LVM Datastore '$storageName' successfully created and linked to VG '$vgName'![/]"
                    } catch {
                        Write-SpectreHost -Message "[yellow]API POST succeeded, but datastore validation failed. Check PVE directly.[/]"
                    }
                } catch {
                    $err = $_.ToString().Replace('[', '(').Replace(']', ')')
                    Write-SpectreHost -Message "[red]Failed to create PVE LVM Datastore: $err[/]"
                    return
                }
            }
        } else {
            Write-SpectreHost -Message "[red]Aborted PVE datastore configuration.[/]"
            return
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
