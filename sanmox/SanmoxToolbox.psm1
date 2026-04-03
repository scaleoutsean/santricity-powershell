function Get-SanmoxStorageMap {
    [CmdletBinding()]
    param()
    
    Write-SpectreHost -Message "[cyan]Generating End-to-End PVE Storage Map (Mappings Report)...[/]"
    try {
        # Relies on the Show-SANtricityMappingsReportFormatted cmdlet which is listed as Stable
        Show-SANtricityMappingsReportFormatted
        
        Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Failed to generate report: $err[/]"
    }
}

function Get-SanmoxPveDevicePaths {
    [CmdletBinding()]
    param()

    Write-SpectreHost -Message "[cyan]Generating configured Host Group disk identifiers and paths...[/]"
    try {
        $mappings = Get-SANtricityMappingsReport

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

            return @(
                $protocols |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
                    Select-Object -Unique
            )
        }

        $joinDisplayValues = {
            param(
                [object[]]$Values,
                [string]$Separator = ', '
            )

            $items = @(
                $Values |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    ForEach-Object { ([string]$_).Trim() } |
                    Select-Object -Unique
            )

            if ($items.Count -eq 0) {
                return ''
            }

            return ($items -join $Separator)
        }

        $configuredHostGroups = @($Global:sanConfig.SanHostGroupName | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($configuredHostGroups.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]No Host Group is configured in sanconfig.json (SanHostGroupName). Skipping path output to avoid showing unrelated hosts.[/]"
            Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }

        if ($configuredHostGroups.Count -gt 0) {
            $allHostGroups = @(Get-SANtricityHostGroup)
            $allHosts = @(Get-SANtricityHost)
            $existingHostGroups = @()
            $existingHostGroupObjects = @()
            foreach ($configuredGroup in $configuredHostGroups) {
                $existing = $allHostGroups | Where-Object { $_.name -eq $configuredGroup } | Select-Object -First 1
                if ($existing) {
                    $existingHostGroups += [string]$existing.name
                    $existingHostGroupObjects += $existing
                }
            }

            $missingGroups = @($configuredHostGroups | Where-Object { $_ -notin $existingHostGroups })
            if ($missingGroups.Count -gt 0) {
                $missingList = ($missingGroups -join ', ')
                Write-SpectreHost -Message "[yellow]Configured Host Group(s) not found on this array: $missingList[/]"
            }

            if ($existingHostGroups.Count -eq 0) {
                Write-SpectreHost -Message "[yellow]No configured Host Group exists on this array. Skipping path output to avoid showing unrelated hosts.[/]"
                Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                return
            }

            $allowedGroups = @($existingHostGroups)
            $groupProtocolByName = @{}
            foreach ($existingGroup in $existingHostGroupObjects) {
                $memberHosts = @($allHosts | Where-Object { $_.clusterRef -eq $existingGroup.id })
                $protocols = @()
                foreach ($memberHost in $memberHosts) {
                    $protocols += @(& $getHostProtocols $memberHost)
                }

                $uniqueProtocols = @($protocols | Select-Object -Unique)
                $resolvedProtocol = if ($uniqueProtocols.Count -eq 0) {
                    'unknown'
                } elseif ($uniqueProtocols.Count -eq 1) {
                    $uniqueProtocols[0]
                } else {
                    $uniqueProtocols -join '+'
                }

                $groupProtocolByName[[string]$existingGroup.name] = $resolvedProtocol
            }

            $mappings = @($mappings | Where-Object {
                $targetLabel = if ($_.PSObject.Properties['targetLabel']) { [string]$_.targetLabel } else { '' }
                $hostGroupLabel = if ($_.PSObject.Properties['hostGroup']) { [string]$_.hostGroup } else { '' }
                ($targetLabel -in $allowedGroups) -or ($hostGroupLabel -in $allowedGroups)
            })

            if ($mappings.Count -eq 0) {
                $groupLabel = if ($allowedGroups.Count -eq 1) { 'Configured Host Group exists' } else { 'Configured Host Groups exist' }
                Write-SpectreHost -Message "[yellow]$groupLabel, but no volumes are currently mapped to it.[/]"
                Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                return
            }

            $resolvedProtocols = @($groupProtocolByName.Values | Select-Object -Unique)
            $nonNvmeProtocols = @($resolvedProtocols | Where-Object { $_ -ne 'nvme' })
            if ($nonNvmeProtocols.Count -gt 0) {
                $protocolList = $nonNvmeProtocols -join ', '
                Write-SpectreHost -Message "[yellow]Detected configured Host Group transport: $protocolList. NVMe /dev/disk/by-id/ paths are shown only for NVMe-capable groups; non-NVMe rows will show transport-specific identifiers and target hints instead.[/]"
            }
        }

        $iscsiTargetName = ''
        $iscsiPortals = ''
        try {
            if (@($groupProtocolByName.Values | Where-Object { $_ -match 'iscsi' }).Count -gt 0) {
                $iscsiSettings = Invoke-SANtricityRequest -Method GET -Path "/iscsi/target-settings" -ErrorAction Stop
                if ($iscsiSettings.nodeName -and -not [string]::IsNullOrWhiteSpace([string]$iscsiSettings.nodeName.iscsiNodeName)) {
                    $iscsiTargetName = [string]$iscsiSettings.nodeName.iscsiNodeName
                }

                $portalValues = foreach ($portal in @($iscsiSettings.portals)) {
                    $ipv4Address = $null
                    if ($portal.ipAddress) {
                        $ipv4Address = $portal.ipAddress.ipv4Address
                    }

                    if (-not [string]::IsNullOrWhiteSpace([string]$ipv4Address)) {
                        if ($null -ne $portal.tcpListenPort) {
                            "$ipv4Address`:$($portal.tcpListenPort)"
                        } else {
                            [string]$ipv4Address
                        }
                    }
                }

                $iscsiPortals = & $joinDisplayValues $portalValues
            }
        } catch {
            Write-Verbose "Could not retrieve iSCSI target settings for identifier hints."
        }

        $fcTargetPorts = ''
        try {
            if (@($groupProtocolByName.Values | Where-Object { $_ -match 'fc|fibre' }).Count -gt 0) {
                $interfaces = Invoke-SANtricityRequest -Method GET -Path "/interfaces" -ErrorAction Stop
                $fcPortValues = foreach ($interface in @($interfaces)) {
                    if ($interface.channelType -ne 'hostside') { continue }
                    if ($null -eq $interface.ioInterfaceTypeData) { continue }
                    if ($interface.ioInterfaceTypeData.interfaceType -notin @('fibre', 'fc')) { continue }

                    $fibre = $interface.ioInterfaceTypeData.fibre
                    foreach ($candidate in @($fibre.wwpn, $fibre.niceAddressId, $fibre.addressId, $fibre.remoteNodeWWN)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                            [string]$candidate
                            break
                        }
                    }
                }

                $fcTargetPorts = & $joinDisplayValues $fcPortValues
            }
        } catch {
            Write-Verbose "Could not retrieve FC target port hints."
        }
        
        $results = foreach ($m in $mappings) {
            $groupName = ''
            if ($m.PSObject.Properties['hostGroup'] -and -not [string]::IsNullOrWhiteSpace([string]$m.hostGroup)) {
                $groupName = [string]$m.hostGroup
            } elseif ($m.PSObject.Properties['targetLabel'] -and -not [string]::IsNullOrWhiteSpace([string]$m.targetLabel)) {
                $groupName = [string]$m.targetLabel
            }

            $transport = if ($groupName -and $groupProtocolByName.ContainsKey($groupName)) {
                [string]$groupProtocolByName[$groupName]
            } else {
                'unknown'
            }

            $euiPath = ''
            $euiValue = ''
            if ($m.PSObject.Properties['volumeEui'] -and -not [string]::IsNullOrWhiteSpace([string]$m.volumeEui)) {
                $euiValue = [string]$m.volumeEui
            } elseif ($m.PSObject.Properties['volumeWwn'] -and -not [string]::IsNullOrWhiteSpace([string]$m.volumeWwn)) {
                # Some arrays expose WWN but not extendedUniqueIdentifier; use it as a best-effort fallback.
                $euiValue = [string]$m.volumeWwn
            }

            if ($transport -eq 'nvme' -and -not [string]::IsNullOrWhiteSpace($euiValue)) {
                $normalizedEui = ($euiValue -replace '^0x', '').Trim().ToLowerInvariant()
                $euiPath = "/dev/disk/by-id/nvme-eui.$normalizedEui"
            }
            
            $altPath = ''
            if ($transport -eq 'nvme' -and $null -ne $m.chassisSerialNumber -and $null -ne $m.lunId) {
                $altPath = "/dev/disk/by-id/nvme-NetApp_E-Series_" + $m.chassisSerialNumber + "_" + $m.lunId
            }

            $volumeWwn = ''
            if ($m.PSObject.Properties['volumeWwn'] -and -not [string]::IsNullOrWhiteSpace([string]$m.volumeWwn)) {
                $volumeWwn = [string]$m.volumeWwn
            }

            $targetHintParts = @()
            if ($transport -match 'iscsi') {
                if ($iscsiTargetName) {
                    $targetHintParts += "IQN $iscsiTargetName"
                }
                if ($iscsiPortals) {
                    $targetHintParts += "Portals $iscsiPortals"
                }
            } elseif ($transport -match 'fc|fibre') {
                if ($fcTargetPorts) {
                    $targetHintParts += "Target Port(s) $fcTargetPorts"
                }
            }

            $targetHint = & $joinDisplayValues $targetHintParts ' | '
            
            [PSCustomObject]@{
                Volume      = $m.mappableObjectName
                Host        = $m.targetLabel
                Transport   = $transport
                Volume_WWN  = $volumeWwn
                Target_Hint = $targetHint
                EUI_Path    = $euiPath
                ALT_Path    = $altPath
            }
        }

        if ($results) {
            if (Get-Command -Name Format-SpectreTable -ErrorAction SilentlyContinue) {
                Format-SpectreTable -Data $results
            } else {
                $results | Format-Table -AutoSize | Out-String | Write-Host
            }
        } else {
            Write-SpectreHost -Message "[yellow]No mapped volumes found for configured Host Group identifier/path output.[/]"
        }

        Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Failed to generate device paths: $err[/]"
    }
}