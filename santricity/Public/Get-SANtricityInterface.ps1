function Get-SANtricityInterface {
    <#
    .SYNOPSIS
    Retrieves hardware interface details from the SANtricity API.

    .DESCRIPTION
    Returns hardware interfaces (iSCSI, IB, FC, SAS). By default, filters for 'hostside' channels.
    Use the -Summary switch to parse the complex nested output into a flat table.

    .PARAMETER InterfaceType
    Optionally filter by hardware interface type (e.g., ib, iscsi, sas, nvme, fibre, ethernet).
    
    .PARAMETER ChannelType
    Optionally filter by channel side (defaults to 'hostside', can be 'driveside').

    .PARAMETER Summary
    Flattens the output into a PSCustomObject that is easily formattable for the pipeline.
    #>
    [CmdletBinding()]
    param(
        [Alias("Proto")]
        [string]$InterfaceType,

        [string]$ChannelType = 'hostside',

        [switch]$Summary
    )

    $query = @()
    if ($InterfaceType) { $query += "interfaceType=$InterfaceType" }
    if ($ChannelType)   { $query += "channelType=$ChannelType" }
    
    $path = "/interfaces"
    if ($query.Count -gt 0) {
        $path += "?" + ($query -join '&')
    }

    $results = Invoke-SANtricityRequest -Method 'GET' -Path $path

    if (-not $Summary) {
        return $results
    }

    $summaryList = @()
    foreach ($iface in $results) {
        $base = [ordered]@{
            InterfaceRef = $iface.interfaceRef
            Protocol     = $iface.ioInterfaceTypeData.interfaceType
            ChannelType  = $iface.channelType
            AddressId    = $null
            LinkState    = $null
            Speed        = $null
            MTU          = $null
            IPv4Address  = $null
        }

        # InfiniBand (IB) / iSER / NVMe-oF over IB
        if ($iface.ioInterfaceTypeData.ib) {
            $ib = $iface.ioInterfaceTypeData.ib
            $base.AddressId = $ib.addressId
            $base.LinkState = $ib.linkState
            $base.Speed     = $ib.currentSpeed
            $base.MTU       = $ib.maximumTransmissionUnit
        }
        # Ethernet (RoCE / iSCSI over Ethernet / NVMe-oF over RoCE)
        elseif ($iface.ioInterfaceTypeData.ethernet -or ($iface.ioInterfaceTypeData.interfaceType -eq 'ethernet')) {
            $eth = $iface.ioInterfaceTypeData.ethernet
            if ($eth.interfaceData.ethernetData) {
                $ethData = $eth.interfaceData.ethernetData
            } else {
                $ethData = $eth
            }
            $base.AddressId = if ($eth.addressId) { $eth.addressId } else { $ethData.macAddress }
            $base.LinkState = $ethData.linkStatus
            $base.Speed     = $ethData.currentInterfaceSpeed
            $base.MTU       = $ethData.maximumFramePayloadSize
        }
        # iSCSI specific blocks
        elseif ($iface.ioInterfaceTypeData.iscsi) {
            $iscsi = $iface.ioInterfaceTypeData.iscsi
            $ethData = $iscsi.interfaceData.ethernetData
            $base.AddressId = if ($iscsi.iqn) { $iscsi.iqn } else { $iscsi.addressId }
            $base.LinkState = if ($ethData) { $ethData.linkStatus } else { $null }
            $base.Speed     = if ($ethData) { $ethData.currentInterfaceSpeed } else { $null }
            $base.MTU       = if ($ethData) { $ethData.maximumFramePayloadSize } else { $null }
            if ($iscsi.ipv4Data) {
                $base.IPv4Address = $iscsi.ipv4Data.ipv4Address
            }
        }
        # Fibre Channel
        elseif ($iface.ioInterfaceTypeData.fibre) {
            $fc = $iface.ioInterfaceTypeData.fibre
            $base.AddressId = $fc.portName
            $base.LinkState = $fc.linkStatus
            $base.Speed     = $fc.currentInterfaceSpeed
            $base.MTU       = "N/A"
        }

        # Extract IPv4 from underlying commandProtocolPropertiesList
        if ($iface.commandProtocolPropertiesList.commandProtocolProperties) {
            foreach ($prop in $iface.commandProtocolPropertiesList.commandProtocolProperties) {
                # iSER IPv4
                if ($prop.scsiProperties.iserProperties.ipv4Data.ipv4Address) {
                    $base.IPv4Address = $prop.scsiProperties.iserProperties.ipv4Data.ipv4Address
                }
                # iSCSI IPv4 (if not set)
                elseif (-not $base.IPv4Address -and $prop.scsiProperties.iscsiProperties.ipv4Data.ipv4Address) {
                    $base.IPv4Address = $prop.scsiProperties.iscsiProperties.ipv4Data.ipv4Address
                }
                # RoCEv2 IPv4
                elseif ($prop.nvmeProperties.nvmeofProperties.roceV2Properties.ipv4Data.ipv4Address) {
                    $base.IPv4Address = $prop.nvmeProperties.nvmeofProperties.roceV2Properties.ipv4Data.ipv4Address
                }
            }
        }

        $summaryList += [PSCustomObject]$base
    }

    return $summaryList
}
