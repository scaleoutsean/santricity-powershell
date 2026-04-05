function Get-SanmoxStorageMap {
    [CmdletBinding()]
    param()
    
    Write-SpectreHost -Message "[cyan]Generating End-to-End PVE Storage Map (Mappings Report)...[/]"
    try {
        $report = @(Get-SANtricityMappingsReport)
        if ($report.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]No mappings found.[/]"
            Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }

        $tableData = foreach ($row in $report) {
            $sizeGiB = $null
            if ($row.PSObject.Properties['capacity'] -and $null -ne $row.capacity) {
                $capacityBytes = 0.0
                if ([double]::TryParse([string]$row.capacity, [ref]$capacityBytes) -and $capacityBytes -gt 0) {
                    $sizeGiB = [math]::Round(($capacityBytes / 1GB), 2)
                }
            }

            [PSCustomObject]@{
                Volume       = [string]$row.mappableObjectName
                'Size(GiB)'  = if ($null -ne $sizeGiB) { $sizeGiB } else { '?' }
                Pool         = [string]$row.poolName
                Host         = [string]$row.targetLabel
                'Is Cluster' = [string]$row.isCluster
                LUN          = if ($row.PSObject.Properties['lunId']) { [string]$row.lunId } else { '' }
            }
        }

        $tableData = @($tableData | Sort-Object -Property Volume, Host)
        if (Get-Command -Name Format-SpectreTable -ErrorAction SilentlyContinue) {
            Format-SpectreTable -Data $tableData
        } else {
            $tableData | Format-Table -AutoSize | Out-String | Write-Host
        }
        
        Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Failed to generate report: $err[/]"
    }
}

function Get-SanmoxSystemPerformanceSnapshot {
    [CmdletBinding()]
    param()

    # Counters to delta between the two samples
    $liveProps = @(
        'totalIopsServiced', 'totalBytesServiced',
        'cacheHitsIopsTotal', 'cacheHitsBytesTotal',
        'randomIosTotal', 'randomBytesTotal',
        'readIopsTotal', 'readBytesTotal',
        'writeIopsTotal', 'writeBytesTotal'
    )

    # Extract systemStats from the aggregate /live-statistics response.
    # systemStats only appears (non-null) when no ?type= is specified.
    $extractSystemStats = {
        param($Payload)
        if ($null -eq $Payload) { return @() }
        if ($Payload.PSObject.Properties['systemStats']) {
            $ss = $Payload.systemStats
            if ($null -eq $ss) { return @() }
            if ($ss -is [System.Array]) { return @($ss) }
            return @($ss)
        }
        # Bare array fallback (e.g. if the endpoint shape changes)
        if ($Payload -is [System.Array]) { return @($Payload) }
        return @($Payload)
    }

    Write-SpectreHost -Message "[cyan]Collecting SANtricity system performance snapshot baseline...[/]"

    try {
        $baselinePayload = Get-SANtricityLiveStatistics   # no -Type: aggregate response includes systemStats
        $baselineStats = @(& $extractSystemStats $baselinePayload)
        if ($baselineStats.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]No system live statistics were returned from SANtricity.[/]"
            return
        }

        Write-SpectreHost -Message "[cyan]Waiting 60 seconds to collect counter deltas...[/]"
        Start-Sleep -Seconds 60

        $finalPayload = Get-SANtricityLiveStatistics
        $finalStats = @(& $extractSystemStats $finalPayload)
        if ($finalStats.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]Final system live statistics sample was empty.[/]"
            return
        }

        # systemStats is a single aggregate object; match by position
        $tableData = for ($i = 0; $i -lt $finalStats.Count; $i++) {
            if ($i -ge $baselineStats.Count) { continue }
            $item     = $finalStats[$i]
            $previous = $baselineStats[$i]

            $intervalSeconds = 60
            if ($item.PSObject.Properties['observedTimeInMS'] -and $previous.PSObject.Properties['observedTimeInMS']) {
                $curMs = 0L; $prevMs = 0L
                if ([long]::TryParse([string]$item.observedTimeInMS, [ref]$curMs) -and
                    [long]::TryParse([string]$previous.observedTimeInMS, [ref]$prevMs)) {
                    $intervalSeconds = [math]::Max(1, [math]::Round(($curMs - $prevMs) / 1000, 0))
                }
            }

            # Compute raw counter deltas
            $d = @{}
            foreach ($prop in $liveProps) {
                $cur = 0L; $prev = 0L
                if ($item.PSObject.Properties[$prop] -and $previous.PSObject.Properties[$prop] -and
                    [long]::TryParse([string]$item.$prop, [ref]$cur) -and
                    [long]::TryParse([string]$previous.$prop, [ref]$prev)) {
                    $d[$prop] = $cur - $prev
                } else {
                    $d[$prop] = 0L
                }
            }

            # Derive operator-friendly metrics
            $totalIops = $d['totalIopsServiced']
            [PSCustomObject]@{
                'Int(s)'      = $intervalSeconds
                'IOPS/s'      = [int]($totalIops / $intervalSeconds)
                'MiB/s'       = [math]::Round($d['totalBytesServiced'] / $intervalSeconds / 1MB, 2)
                'Rd IOPS/s'   = [int]($d['readIopsTotal'] / $intervalSeconds)
                'Wr IOPS/s'   = [int]($d['writeIopsTotal'] / $intervalSeconds)
                'Rd MiB/s'    = [math]::Round($d['readBytesTotal'] / $intervalSeconds / 1MB, 2)
                'Wr MiB/s'    = [math]::Round($d['writeBytesTotal'] / $intervalSeconds / 1MB, 2)
                'Cache Hit%'  = if ($totalIops -gt 0) { "$([math]::Round($d['cacheHitsIopsTotal'] * 100.0 / $totalIops, 1))%" } else { 'N/A' }
                'Random%'     = if ($totalIops -gt 0) { "$([math]::Round($d['randomIosTotal'] * 100.0 / $totalIops, 1))%" } else { 'N/A' }
                # keep raw item ref for the info table; excluded from main display by not being PSCustomObject top-level data
                '_item'       = $item
            }
        }

        if ($tableData.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]Unable to calculate system performance deltas from the returned SANtricity samples.[/]"
            return
        }

        # Build a small info table from the final sample (observedTime + arrayWwn)
        $lastItem = $tableData[0].'_item'
        $infoRows = @(
            [PSCustomObject]@{ Property = 'Observed time'; Value = if ($lastItem.PSObject.Properties['observedTime']) { [string]$lastItem.observedTime } else { '(not reported)' } }
            [PSCustomObject]@{ Property = 'Array WWN';     Value = if ($lastItem.PSObject.Properties['arrayWwn'])     { [string]$lastItem.arrayWwn }     else { '(not reported)' } }
        )

        # Strip the helper column before rendering the perf table
        $perfData = $tableData | Select-Object * -ExcludeProperty '_item'

        Write-SpectreHost -Message ""
        Write-SpectreRule -Title "SANtricity System Performance Snapshot (60s delta)" -Alignment Center -Color Blue
        try {
            Format-SpectreTable -Data $infoRows -Color Grey
        } catch {
            $infoRows | Format-Table -HideTableHeaders | Out-String | Write-Host
        }
        try {
            Format-SpectreTable -Data $perfData
        } catch {
            $perfData | Format-Table -AutoSize | Out-String | Write-Host
        }

        Write-SpectreHost -Message ""
        Write-SpectreHost -Message "[grey]Press Enter to return to the main menu...[/]"
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Failed to collect system performance snapshot: $err[/]"
    }
}

function Get-SanmoxPveDevicePaths {
    [CmdletBinding()]
    param()

    Write-SpectreHost -Message "[cyan]Generating configured Host Group/Host disk identifiers and paths...[/]"
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

        $configuredTargets = @($Global:sanConfig.SanHostGroupName | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($configuredTargets.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]No Host Group or Host is configured in sanconfig.json (SanHostGroupName). Skipping path output to avoid showing unrelated hosts.[/]"
            Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }

        $allHostGroups = @(Get-SANtricityHostGroup)
        $allHosts = @(Get-SANtricityHost)
        $allowedTargets = @()
        $targetProtocolByName = @{}
        $resolvedConfigured = @()

        foreach ($configuredTarget in $configuredTargets) {
            $configuredName = [string]$configuredTarget
            $existingGroup = $allHostGroups | Where-Object { $_.name -eq $configuredName -or $_.label -eq $configuredName } | Select-Object -First 1
            if ($existingGroup) {
                $resolvedConfigured += [PSCustomObject]@{ Type = 'Host Group'; Name = $configuredName }

                foreach ($groupAlias in @([string]$existingGroup.name, [string]$existingGroup.label)) {
                    if (-not [string]::IsNullOrWhiteSpace($groupAlias)) {
                        $allowedTargets += $groupAlias
                    }
                }

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

                foreach ($groupAlias in @([string]$existingGroup.name, [string]$existingGroup.label)) {
                    if (-not [string]::IsNullOrWhiteSpace($groupAlias)) {
                        $targetProtocolByName[$groupAlias] = $resolvedProtocol
                    }
                }
                continue
            }

            $existingHost = $allHosts | Where-Object { $_.name -eq $configuredName -or $_.label -eq $configuredName } | Select-Object -First 1
            if ($existingHost) {
                $resolvedConfigured += [PSCustomObject]@{ Type = 'Host'; Name = $configuredName }

                foreach ($hostAlias in @([string]$existingHost.name, [string]$existingHost.label)) {
                    if (-not [string]::IsNullOrWhiteSpace($hostAlias)) {
                        $allowedTargets += $hostAlias
                    }
                }

                $hostProtocols = @(& $getHostProtocols $existingHost)
                $uniqueHostProtocols = @($hostProtocols | Select-Object -Unique)
                $resolvedHostProtocol = if ($uniqueHostProtocols.Count -eq 0) {
                    'unknown'
                } elseif ($uniqueHostProtocols.Count -eq 1) {
                    $uniqueHostProtocols[0]
                } else {
                    $uniqueHostProtocols -join '+'
                }

                foreach ($hostAlias in @([string]$existingHost.name, [string]$existingHost.label)) {
                    if (-not [string]::IsNullOrWhiteSpace($hostAlias)) {
                        $targetProtocolByName[$hostAlias] = $resolvedHostProtocol
                    }
                }
                continue
            }
        }

        $missingConfigured = @($configuredTargets | Where-Object {
            $candidate = [string]$_
            -not ($resolvedConfigured | Where-Object { $_.Name -eq $candidate } | Select-Object -First 1)
        })
        if ($missingConfigured.Count -gt 0) {
            $missingList = ($missingConfigured -join ', ')
            Write-SpectreHost -Message "[yellow]Configured Host Group/Host not found on this array: $missingList[/]"
        }

        $allowedTargets = @($allowedTargets | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        if ($allowedTargets.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]No configured Host Group/Host exists on this array. Skipping path output to avoid showing unrelated mappings.[/]"
            Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }

        $mappings = @($mappings | Where-Object {
            $targetLabel = if ($_.PSObject.Properties['targetLabel']) { [string]$_.targetLabel } else { '' }
            $hostGroupLabel = if ($_.PSObject.Properties['hostGroup']) { [string]$_.hostGroup } else { '' }
            ($targetLabel -in $allowedTargets) -or ($hostGroupLabel -in $allowedTargets)
        })

        if ($mappings.Count -eq 0) {
            Write-SpectreHost -Message "[yellow]Configured Host Group/Host exists, but no volumes are currently mapped to it.[/]"
            Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }

        $resolvedProtocols = @($targetProtocolByName.Values | Select-Object -Unique)
        $nonNvmeProtocols = @($resolvedProtocols | Where-Object { -not ([string]$_ -match 'nvme') })
        if ($nonNvmeProtocols.Count -gt 0) {
            $protocolList = $nonNvmeProtocols -join ', '
            Write-SpectreHost -Message "[yellow]Detected configured Host Group/Host transport: $protocolList. Rows now show transport-specific identifiers (iSCSI by-path, FC target hints, or NVMe by-id as applicable).[/]"
        }

        $iscsiTargetName = ''
        $iscsiPortalValues = @()
        $iscsiPortals = ''
        try {
            if (@($targetProtocolByName.Values | Where-Object { $_ -match 'iscsi' }).Count -gt 0) {
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

                $iscsiPortalValues = @($portalValues)
                $iscsiPortals = & $joinDisplayValues $portalValues
            }
        } catch {
            Write-Verbose "Could not retrieve iSCSI target settings for identifier hints."
        }

        $fcTargetPorts = ''
        try {
            if (@($targetProtocolByName.Values | Where-Object { $_ -match 'fc|fibre' }).Count -gt 0) {
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

        $nvmeTargetName = ''
        try {
            if (@($targetProtocolByName.Values | Where-Object { $_ -match 'nvme' }).Count -gt 0) {
                $nvmeSettings = Get-SANtricityNvmeTargetSetting -ErrorAction Stop
                if ($nvmeSettings.nodeName -and -not [string]::IsNullOrWhiteSpace([string]$nvmeSettings.nodeName.nvmeNodeName)) {
                    $nvmeTargetName = [string]$nvmeSettings.nodeName.nvmeNodeName
                }
            }
        } catch {
            Write-Verbose "Could not retrieve NVMe target settings for identifier hints."
        }
        
        $results = foreach ($m in $mappings) {
            $targetName = ''
            if ($m.PSObject.Properties['hostGroup'] -and -not [string]::IsNullOrWhiteSpace([string]$m.hostGroup)) {
                $targetName = [string]$m.hostGroup
            } elseif ($m.PSObject.Properties['targetLabel'] -and -not [string]::IsNullOrWhiteSpace([string]$m.targetLabel)) {
                $targetName = [string]$m.targetLabel
            }

            $transport = if ($targetName -and $targetProtocolByName.ContainsKey($targetName)) {
                [string]$targetProtocolByName[$targetName]
            } else {
                'unknown'
            }

            $isNvmeTransport = [string]$transport -match 'nvme'
            $isIscsiTransport = [string]$transport -match 'iscsi'
            $isFcTransport = [string]$transport -match 'fc|fibre'

            $euiPath = ''
            $euiValue = ''
            if ($m.PSObject.Properties['volumeEui'] -and -not [string]::IsNullOrWhiteSpace([string]$m.volumeEui)) {
                $euiValue = [string]$m.volumeEui
            } elseif ($m.PSObject.Properties['volumeWwn'] -and -not [string]::IsNullOrWhiteSpace([string]$m.volumeWwn)) {
                # Some arrays expose WWN but not extendedUniqueIdentifier; use it as a best-effort fallback.
                $euiValue = [string]$m.volumeWwn
            }

            if ($isNvmeTransport -and -not [string]::IsNullOrWhiteSpace($euiValue)) {
                $normalizedEui = ($euiValue -replace '^0x', '').Trim().ToLowerInvariant()
                $euiPath = "/dev/disk/by-id/nvme-eui.$normalizedEui"
            }
            
            $altPath = ''
            if ($isNvmeTransport -and $null -ne $m.chassisSerialNumber -and $null -ne $m.lunId) {
                $altPath = "/dev/disk/by-id/nvme-NetApp_E-Series_" + $m.chassisSerialNumber + "_" + $m.lunId
            }

            $volumeWwn = ''
            if ($m.PSObject.Properties['volumeWwn'] -and -not [string]::IsNullOrWhiteSpace([string]$m.volumeWwn)) {
                $volumeWwn = [string]$m.volumeWwn
            }

            $targetHintParts = @()
            if ($isIscsiTransport) {
                if ($iscsiTargetName) {
                    $targetHintParts += "IQN $iscsiTargetName"
                }
                if ($iscsiPortals) {
                    $targetHintParts += "Portals $iscsiPortals"
                }
            } elseif ($isFcTransport) {
                if ($fcTargetPorts) {
                    $targetHintParts += "Target Port(s) $fcTargetPorts"
                }
            } elseif ($isNvmeTransport) {
                if ($nvmeTargetName) {
                    $targetHintParts += "NQN $nvmeTargetName"
                }
            }

            $targetHint = & $joinDisplayValues $targetHintParts ' | '

            $iscsiByPath = ''
            if ($isIscsiTransport -and $iscsiTargetName -and $iscsiPortalValues.Count -gt 0) {
                $lunValue = ''
                if ($m.PSObject.Properties['lunId'] -and -not [string]::IsNullOrWhiteSpace([string]$m.lunId)) {
                    $lunValue = [string]$m.lunId
                } elseif ($m.PSObject.Properties['lun'] -and -not [string]::IsNullOrWhiteSpace([string]$m.lun)) {
                    $lunValue = [string]$m.lun
                } elseif ($m.PSObject.Properties['logicalUnitNumber'] -and -not [string]::IsNullOrWhiteSpace([string]$m.logicalUnitNumber)) {
                    $lunValue = [string]$m.logicalUnitNumber
                }

                if ($lunValue) {
                    $paths = foreach ($portalValue in $iscsiPortalValues) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$portalValue)) {
                            "/dev/disk/by-path/ip-$portalValue-iscsi-$iscsiTargetName-lun-$lunValue"
                        }
                    }
                    $iscsiByPath = & $joinDisplayValues $paths ' | '
                }
            }
            
            [PSCustomObject]@{
                Volume       = $m.mappableObjectName
                Host         = $m.targetLabel
                Transport    = $transport
                WWN          = $volumeWwn
                Hint         = $targetHint
                'iSCSI Path' = $iscsiByPath
                'EUI Path'   = $euiPath
                'Alt Path'   = $altPath
            }
        }

        if ($results) {
            $useRowLayout = @($results | Where-Object {
                ([string]$_.'EUI Path').Length -gt 48 -or
                ([string]$_.'Alt Path').Length -gt 48 -or
                ([string]$_.'iSCSI Path').Length -gt 48 -or
                ([string]$_.Hint).Length -gt 48
            }).Count -gt 0

            if (-not $useRowLayout) {
                if (Get-Command -Name Format-SpectreTable -ErrorAction SilentlyContinue) {
                    Format-SpectreTable -Data $results
                } else {
                    $results | Format-Table -AutoSize | Out-String | Write-Host
                }
            } else {
                $i = 0
                foreach ($result in $results) {
                    $i++
                    $mappingTitle = "Mapping $i"
                    if (-not [string]::IsNullOrWhiteSpace([string]$result.Volume) -or -not [string]::IsNullOrWhiteSpace([string]$result.Host)) {
                        $mappingTitle = "Mapping ${i}: $($result.Volume) -> $($result.Host)"
                    }

                    Write-SpectreRule -Title $mappingTitle -Alignment Left -Color Grey
                    $detailRows = @(
                        [PSCustomObject]@{ Property = 'Volume';     Value = [string]$result.Volume }
                        [PSCustomObject]@{ Property = 'Host';       Value = [string]$result.Host }
                        [PSCustomObject]@{ Property = 'Transport';  Value = [string]$result.Transport }
                        [PSCustomObject]@{ Property = 'WWN';        Value = [string]$result.WWN }
                        [PSCustomObject]@{ Property = 'Hint';       Value = [string]$result.Hint }
                        [PSCustomObject]@{ Property = 'iSCSI Path'; Value = [string]$result.'iSCSI Path' }
                        [PSCustomObject]@{ Property = 'EUI Path';   Value = [string]$result.'EUI Path' }
                        [PSCustomObject]@{ Property = 'Alt Path';   Value = [string]$result.'Alt Path' }
                    )

                    if (Get-Command -Name Format-SpectreTable -ErrorAction SilentlyContinue) {
                        Format-SpectreTable -Data $detailRows -Color Grey
                    } else {
                        $detailRows | Format-Table -AutoSize | Out-String | Write-Host
                    }
                }
            }
        } else {
            Write-SpectreHost -Message "[yellow]No mapped volumes found for configured Host Group/Host identifier/path output.[/]"
        }

        Write-SpectreHost -Message "[grey]Press Enter to continue...[/]"
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        $err = $_.ToString().Replace('[', '(').Replace(']', ')')
        Write-SpectreHost -Message "[red]Failed to generate device paths: $err[/]"
    }
}