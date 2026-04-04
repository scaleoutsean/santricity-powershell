[![PowerShell Tests](https://github.com/scaleoutsean/santricity-powershell/actions/workflows/powershell.yml/badge.svg)](https://github.com/scaleoutsean/santricity-powershell/actions/workflows/powershell.yml)

# SANtricity PowerShell helper

Minimal PowerShell 7 module providing lightweight helpers to call a SANtricity
REST API and produce a mappings report similar to the Python client (`santricity-client`).

It has been tested with PowerShell 7.5 and 7.6. It is aimed at Day 1+ operations on DDP (pools) to avoid the complexity of RAID groups.

If you're looking for SANmox, see under `./sanmox`.

## Usage

```powershell
git clone https://github.com/scaleoutsean/santricity-powershell
cd santricity-powershell
# Optional; if you don't want to install in standard location
# git clone https://github.com/dfinke/PowerShellRich

Import-Module ./santricity/santricity.psd1 -Force
# Optional rich tables (git clone https://github.com/dfinke/PowerShellRich.git)
Import-Module ./PowerShellRich/PowerShellRich.psd1 -ErrorAction SilentlyContinue

# For testing/lab (skips certificate validation):
$conn = Connect-SANtricity -BaseUrl 'https://controller_b:8443' -Username 'admin' -Password 'secret' -SkipCertificateCheck -Verbose

# For production with controller or CA pinning (legacy pipeline implied when using -TrustedCertificate):
$conn = Connect-SANtricity -BaseUrl 'https://controller_b:8443' -Username 'admin' -Password 'secret' -TrustedCertificate '/path/to/controller-or-ca-chain.pem' -Verbose

# Get volumes
$vols = Get-SANtricityVolume
# Get and remove "repo" volumes orphaned by Snapshot (Consistency) Group deletion. Verify before confirming!
Get-SANtricityVolume -Orphans | Remove-SANtricityVolume
# Use metadata values (from SANtricity CSI, or own)
$vols[0].metadata['pvc_name'] # Metadata is parsed into a hashtable for easy access
Get-SANtricityVolume -Verbose
# Get 100GB volumes
Get-SANtricityVolume -Size "100GB"
Get-SANtricityVolume -SizeMin "50GiB" -SizeMax "200GiB"
# Get volumes with a specific metadata key (inserted by SANtricity CSI or your own app)
Get-SANtricityVolume -MetadataKey 'pvc_name'
# Get volumes with a specific metadata key and value
Get-SANtricityVolume -MetadataKey 'fstype' -MetadataValue 'xfs'
# Get volumes where any metadata value matches 'default'
Get-SANtricityVolume -MetadataValue 'default'
Get-SANtricityVolume -MetadataKey pvc_namespace -MetadataValue postgres
# Accessing metadata on the result
$vol = Get-SANtricityVolume -Name 'my-vol'
Write-Host "PVC Name: $($vol.metadata['pvc_name'])"

# Get volume-to-host mappings
Get-SANtricityMappingsReport | Format-Table -AutoSize
Get-SANtricityMappingsReport -Host "ha_group_.*"
Get-SANtricityMappingsReport -Volume "db_vol_.*"
Show-SANtricityMappingsReportFormatted -Host "server1"
Get-SANtricityVolumeMapping -Type cluster

# Get storage pool(s) 
Get-SANtricityStoragePool -RaidLevel "raidDiskPool"
Get-SANtricityStoragePool -Name "Pool_A"
# Set storage pool with one line
Set-SANtricityStoragePool -Name pool1 -PriorityBackground lowest -PriorityDegraded high -PriorityCritical highest -ThresholdWarning 75 -ThresholdCritical 90

# Create report for vCenter volumes
Get-SANtricityMappingsReport -Volume "vcenter1_" | Format-Table
# Create report for assembly of deterministic disk device paths
Get-SANtricityMappingsReport | Select-Object -First 2 chassisSerialNumber, poolName, mappableObjectName, lunId, volumeId, volumeEui, volumeWwn, targetLabel, isCluster | Format-Table -AutoSize

# Get host-side (or other, if you want) interfaces 
Get-SANtricityInterface -Summary | Format-Table -AutoSize

# Get commands
Get-Command -Module santricity
```

> **TLS note:** provide `-TrustedCertificate /path/chain.pem` with either a controller certificate or a custom CA bundle to enable pinned TLS. The module automatically routes requests through the legacy HttpClient pipeline in that case, so you only need `-VerifySsl:$false` for quick lab testing.

You may create a transcript (if you need one) with `-Create Transcript -TranscriptPath ts.txt`.

## Implementation notes

Some cmdlets do not behave exactly the same as the SANtricity API - we tend to err on the safe side.

For example, SANtricity and SMcli [delete member hosts](https://docs.netapp.com/us-en/e-series-cli/commands-a-z/delete-hostgroup.html#context) when a group is deleted. We aim to prevent such disorderly entity removal by returning an error, but the user can override such safeguards with `-Force`. See [CMDLETS](./CMDLETS.md) and online help for more.

Another noteworthy difference is **volume mapping**. When mapping to a host that belongs to a host group, we map the volume to the host group and show a warning. The reason is a volume can't be mapped to only one host from a cluster.

## Acknowledgements

SANtricity, E-Series belong to NetApp and PowerShell to Microsoft.

This repository is not associated with either.
