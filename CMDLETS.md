# SANtricity PowerShell Module Cmdlet Status

This document tracks the implementation status of cmdlets in the SANtricity PowerShell module.

## Status Legend

- **Stable**: Functional, basic testing complete.
- **Beta**: Functional, new implementation, needs testing.
- **Stub**: Exists but implementation is missing or incomplete (throws errors).
- **Planned**: Not yet created.

## Core Connectivity (Private/Global)

| Cmdlet | Status | Notes |
|--------|--------|-------|
| `Connect-SANtricity` | **Stable** | Handles Basic/JWT auth, TLS pinning, session management. |
| `Invoke-SANtricityRequest` | **Stable** | Core REST wrapper with failover logic. |

## Public Cmdlets

### Retrieval (Get-)

| Cmdlet | Status | Notes |
|--------|--------|-------|
| `Get-SANtricityVolumes` | **Stable** | Basic wrapper. |
| `Get-SANtricityStoragePools` | **Stable** | Basic wrapper. |
| `Get-SANtricityHosts` | **Stable** | Basic wrapper. |
| `Get-SANtricityHostGroups` | **Stable** | Basic wrapper. |
| `Get-SANtricityVolumeMappings` | **Stable** | Basic wrapper. |
| `Get-SANtricityMappingsReport` | **Stable** | Aggregates data from multiple endpoints. |
| `Show-SANtricityMappingsReportFormatted` | **Stable** | Formats report using PowerShellRich if available. |
| `Get-SANtricityTargets` | **Beta** | Returns Target Name (IQN/NQN), Portals, and mapped volume details. |
| `Get-SANtricitySnapshotGroup` | **Beta** | Gets snapshot groups (repositories). Supports filter by Name/BaseVolume. |
| `New-SANtricitySnapshotGroup` | **Beta** | Creates snapshot groups/repositories (required for first snapshot). |

### Volume Management

| Cmdlet | Status | Notes |
|--------|--------|-------|
| `New-SANtricityVolume` | **Beta** | Includes `-Auto` pool selection logic. Needs integration testing. |
| `Set-SANtricityVolume` | **Beta** | Implements renaming, cache/scan settings, and generic property merging. |
| `Resize-SANtricityVolume` | **Beta** | Implements `/expand` endpoint. |
| `New-SANtricityVolumeMapping` | **Beta** | Implements mapping creation with name resolution. |
| `Remove-SANtricityVolume` | **Beta** | Checks for mappings before deletion (requires -Force). |
| `Remove-SANtricityVolumeMapping` | **Beta** | Implements removal with volume/target name resolution and collision protection. |

### Host Management

| Cmdlet | Status | Notes |
|--------|--------|-------|
| `New-SANtricityHost` | **Beta** | Supports auto-port labelling and type inference (iSCSI/NVMe/FC). |
| `New-SANtricityHostGroup` | **Beta** | Basic wrapper. |
| `Remove-SANtricityHost` | **Beta** | Safe deletion: checks for mappings first. |
| `Remove-SANtricityHostGroup` | **Beta** | Safe deletion: checks for member hosts and mappings first. |

### Pool Management

| Cmdlet | Status | Notes |
|--------|--------|-------|
| `Remove-SANtricityStoragePool` | **Beta** | Checks for volumes and mappings before deletion (requires `-Force`). |

### Diagnostics

| Cmdlet | Status | Notes |
|--------|--------|-------|
| `Get-SANtricityOdxStatus` | **Beta** | Confirms (`$True`) Windows ODX enabled status (factory default) |
| `Start-SANtricityTranscript` | **Stable** | |
| `Stop-SANtricityTranscript` | **Stable** | |

## Future / Planned

None remaining from original plan. More may be added depending on user feedback.

## Development 

SANtricity [ships with Swagger](https://scaleoutsean.github.io/2024/04/26/swagger-files-netapp-eseries-arrays.html) but I find it hard to use it offline.

I use it online to get JSON traces and other information, and then work on that offline.

Alternatively, use core wrapper `Invoke-SANtricityRequest` to work with native PowerShell objects. 

```powershell
$pools = Invoke-SANtricityRequest -Method GET -Path '/storage-pools'
$pools | Export-Clixml -Path '.\references\mock_pools.xml'
```

Offline work:

```powershell
$mockPools = Import-Clixml -Path '.\references\mock_pools.xml'
$mockPools | ForEach-Object {
    # ... process ...
}
```

Similarly, with HAR files:

```powershell
$har = Get-Content .\snapshot-create.har | ConvertFrom-Json
$har.log.entries | 
    Where-Object { $_.request.method -eq 'POST' } | 
    Select-Object -ExpandProperty request | 
    Select-Object url, postData
```