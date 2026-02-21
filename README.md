[![PowerShell Tests](https://github.com/scaleoutsean/santricity-powershell/actions/workflows/powershell.yml/badge.svg)](https://github.com/scaleoutsean/santricity-powershell/actions/workflows/powershell.yml)

SANtricity PowerShell helper
=================================

Minimal PowerShell 7 module providing lightweight helpers to call a SANtricity
REST API and produce a mappings report similar to the Python client (`santricity-client`).

It has been tested with PowerShell 7.5 and 7.6 (Preview 6). It is aimed at Day 1+ operations on DDP (pools) to avoid the complexity of RAID groups.

Usage (PowerShell 7):

```powershell
https://github.com/scaleoutsean/santricity-powershell
cd santricity-powershell
# Optional; if you don't want to install in standard location
# git clone https://github.com/dfinke/PowerShellRich

Import-Module ./santricity/santricity.psd1 -Force
# Optional rich tables (git clone https://github.com/dfinke/PowerShellRich.git)
Import-Module ./PowerShellRich/PowerShellRich.psd1 -ErrorAction SilentlyContinue

# For testing/lab (skips certificate validation):
$conn = Connect-SANtricity -BaseUrl 'https://controller_b:8443' -Username 'admin' -Password 'secret' -VerifySsl:$false -Verbose

# For production with controller or CA pinning (legacy pipeline implied when using -TrustedCertificate):
$conn = Connect-SANtricity -BaseUrl 'https://controller_b:8443' -Username 'admin' -Password 'secret' -TrustedCertificate '/path/to/controller-or-ca-chain.pem' -Verbose

Get-SANtricityVolumes -Verbose
Get-SANtricityVolumes -Size "100GB"

Get-SANtricityMappingsReport | Format-Table -AutoSize
Get-SANtricityMappingsReport -Host "ha_group_.*"
Get-SANtricityMappingsReport -Volume "db_vol_.*"

Show-SANtricityMappingsReportFormatted -Host "server1"

Get-SANtricityVolumeMappings -Type cluster

Get-SANtricityStoragePools -RaidLevel "raidDiskPool"
Get-SANtricityStoragePools -Name "Pool_A"

Get-SANtricityMappingsReport -Volume "vcenter1_" | Format-Table

Get-Command -Module santricity
```

> **TLS note:** provide `-TrustedCertificate /path/chain.pem` with either a controller certificate or a custom CA bundle to enable pinned TLS. The module automatically routes requests through the legacy HttpClient pipeline in that case, so you only need `-VerifySsl:$false` for quick lab testing.

You may create a transcript (if you need one) with `-Create Transcript -TranscriptPath ts.txt`.

Some cmdlets do not behave exactly the same as the SANtricity API - we tend to err on the safe side. For example, SANtricity and SMcli [delete member hosts](https://docs.netapp.com/us-en/e-series-cli/commands-a-z/delete-hostgroup.html#context) when a group is deleted. We aim to prevent such disorderly entity removal by returning an error, but the user can override such safeguards with `-Force`. See [CMDLETS](./CMDLETS.md) and online help for more.

## Acknowledgements

SANtricity, E-Series belong to NetApp and PowerShell to Microsoft.

This repository is not associated with either.
