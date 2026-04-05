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
| `Get-SANtricityVolume` | **Stable** | Basic wrapper. |
| `Get-SANtricityStoragePool` | **Stable** | Basic wrapper. |
| `Get-SANtricityHost` | **Stable** | Basic wrapper. |
| `Get-SANtricityHostGroup` | **Stable** | Basic wrapper. |
| `Get-SANtricityVolumeMapping` | **Stable** | Basic wrapper. |
| `Get-SANtricityMappingsReport` | **Stable** | Aggregates data from multiple endpoints. |
| `Show-SANtricityMappingsReportFormatted` | **Stable** | Formats report using PowerShellRich if available. |
| `Get-SANtricityTarget` | **Beta** | Returns Target Name (IQN/NQN), Portals, and mapped volume details. |
| `Get-SANtricityFlashCache` | **Stable** | Shows SANtricity SSD Cache (if available) configuration. |

### Volume Management

| Cmdlet | Status | Notes |
|--------|--------|-------|
| `New-SANtricityVolume` | **Beta** | Includes `-Auto` pool selection logic. Needs integration testing. |
| `Set-SANtricityVolume` | **Beta** | Implements renaming, cache/scan settings, and generic property merging. |
| `Resize-SANtricityVolume` | **Beta** | Implements `/expand` endpoint. |
| `New-SANtricityVolumeMapping` | **Stable** | Implements mapping creation. Auto-detects Clusters and maps to ClusterRef. |
| `Remove-SANtricityVolume` | **Stable** | Checks for mappings before deletion (requires -Force). |
| `Remove-SANtricityVolumeMapping` | **Stable** | Implements removal with volume/target name resolution. |

### Host Management

| Cmdlet | Status | Notes |
|--------|--------|-------|
| `New-SANtricityHost` | **Beta** | Supports auto-port labelling and type inference (tested with iSCSI, NVMe/RoCE). Defaults to Linux (28). |
| `New-SANtricityHostGroup` | **Beta** | Basic wrapper. |
| `Remove-SANtricityHost` | **Beta** | Safe deletion: checks for mappings first. |
| `Remove-SANtricityHostGroup` | **Beta** | Safe deletion: checks for member hosts and mappings first. |

### Interface Management

| Cmdlet | Status | Notes |
|--------|--------|-------|
|`Get-SANtricityInterface` | **Beta** | Gets interface objects. |
|`Get-SANtricityIscsiTargetSetting` | **Beta** | Gets iSCSI target settings. |
|`Get-SANtricityNvmeTargetSetting` | **Beta** | Gets NVMe-oF target settings. |

### Snapshot & Clone Management

| Cmdlet | Status | Notes |
|--------|--------|-------|
| `Get-SANtricitySnapshotGroup` | **Stable** | Gets snapshot groups (single volume). Supports filter by Name/BaseVolume. |
| `New-SANtricitySnapshotGroup` | **Stable** | Creates snapshot groups. |
| `New-SANtricitySnapshot` | **Stable** | Creates instant snapshot. Auto-creates group if `-Force` is used. Supports Consistency Groups. |
| `Get-SANtricitySnapshot` | **Stable** | Lists snapshots. Supports `-Newest`/`-Oldest` sorting. |
| `Get-SANtricitySnapshotVolume` | **Stable** | Lists linked clones. Supports `-Newest`/`-Oldest` sorting. |
| `Remove-SANtricitySnapshot` | **Stable** | Deletes snapshots. Supports `-Oldest` deletion strategy. |
| `Get-SANtricityClone` | **Stable** | Lists clones/views. |
| `New-SANtricityClone` | **Stable** | Creates clone. Defaults to Read-Only (View). |
| `Update-SANtricityClone` | **Stable** | Refreshes clone data from source snapshot (Re-Flash). |
| `Remove-SANtricityClone` | **Stable** | Deletes clone and stops associated views. |
| `New-SANtricityVolumeCopy` | **Stable** | Creates full physical copy. Supports `-OnlineCopy` and `ClearOnCompletion`. |
| `Get-SANtricityVolumeCopy` | **Stable** | Gets copy config or live progress (`-Progress`). |
| `Stop-SANtricityVolumeCopy` | **Stable** | Aborts running copy jobs. |
| `Remove-SANtricityVolumeCopy` | **Stable** | Deletes the volume copy pair relationship (Job). |
| `Get-SANtricityConsistencyGroup` | **Beta** | Lists multi-volume consistency groups. |
| `New-SANtricityConsistencyGroup` | **Beta** | Creates consistency groups with batch member addition. |
| `New-SANtricityConsistencyGroupClone` | **Beta** | Creates consistency group views (linked clones). Aliased to `View`. |
| `Remove-SANtricityConsistencyGroup` | **Beta** | Deletes consistency groups and member snapshot groups. |
| `Get-SANtricitySnapshotSchedule` | **Beta** | Lists snapshot schedules. Accepts pipeline input for easy Group-to-Schedule mapping. |
| `Set-SANtricitySnapshotSchedule` | **Beta** | Sets snapshot schedule to Enable or Disable. Does not aim to create schedules.|

### Pool Management

| Cmdlet | Status | Notes |
|--------|--------|-------|
| `New-SANtricityStoragePool` | **Beta** | Create new storage pool. Targets single shelf arrays. See online help. |
| `Get-SANtricityStoragePool` | **Beta** | Get storage pools. |
| `Set-SANtricityStoragePool` | **Beta** | Set mutable parameters on existing storage pool. |
| `Remove-SANtricityStoragePool` | **Beta** | Checks for volumes and mappings before deletion (requires `-Force`). |

### Diagnostics

| Cmdlet | Status | Notes |
|--------|--------|-------|
| `Get-SANtricityOdxStatus` | **Beta** | Confirms (`$True`) Windows ODX enabled status (factory default: Enabled) |
| `Get-SANtricityLiveStatistics` | **Beta** | Gets live statistics. `-Type`: `controller`, `volume`, `drive`. Omit for aggregate response (includes `systemStats`, `interfaceStats` — these return null when requested individually via `-Type`). |
| `Get-SANtricityFlashCacheStatistics` | **Beta** | Get SSD Cache (Flash Read Cache, "FRC") statistics when FRC available. |
| `Start-SANtricityTranscript` | **Stable** | Starts session logging to a file. |
| `Stop-SANtricityTranscript` | **Stable** | Stops session logging to a file. |

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