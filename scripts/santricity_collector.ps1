#!/usr/bin/env pwsh

# (C) 2026 @scaleoutSean (Github) | MIT License

<#!
.SYNOPSIS
Collect SANtricity performance samples into Excel-friendly CSV files.

.DESCRIPTION
Creates one run folder per execution and writes:
 - long-format metrics CSV for pivot charts (metrics_long.csv)
 - section CSVs (system/controller/volume/interface/drive)
 - optional raw CLIXML snapshots for forensic replay

Notes:
 - Uses one aggregate Get-SANtricityLiveStatistics call per iteration to keep timestamps aligned.
 - Delta/rate post-processing should use observedTimeInMS from SANtricity payload.
#>

[CmdletBinding()]
param(
    [PSCredential]$Credential,
    [string]$BaseUrl,
    [string]$OutputRoot,
    [int]$IntervalSeconds,
    [int]$SampleCount,
    [string[]]$Volumes,
    [switch]$NoRawClixml,
    [bool]$SkipCertificateCheck = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-IntOrDefault {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][int]$Default,
        [int]$Min = 1
    )

    $raw = Read-Host -Prompt "$Prompt (default: $Default)"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }

    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed) -or $parsed -lt $Min) {
        Write-Host "Invalid value '$raw'. Using default: $Default"
        return $Default
    }
    return $parsed
}

function Get-HomeDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { return $env:HOME }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $env:USERPROFILE }
    return (Get-Location).Path
}

function Convert-SectionToRows {
    param(
        [object[]]$Items,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][int]$Iteration,
        [Parameter(Mandatory = $true)][DateTime]$SampleTimeUtc
    )

    $rows = @()
    if ($null -eq $Items) { return ,$rows }
    foreach ($item in $Items) {
        if ($null -eq $item) { continue }

        $entity = $null
        # Check section-specific fields first (volumeName for volumes, etc.), then generic fields
        foreach ($key in @('volumeName', 'volumeId', 'controllerRef', 'driveRef', 'name', 'label', 'id')) {
            if ($item.PSObject.Properties[$key]) {
                $candidate = [string]$item.$key
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $entity = $candidate
                    break
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($entity)) { $entity = '(aggregate)' }

        foreach ($prop in $item.PSObject.Properties) {
            $value = $prop.Value
            if ($null -eq $value) { continue }

            # Keep long-format metrics focused on scalar numeric values for charting.
            $num = 0.0
            if ([double]::TryParse([string]$value, [ref]$num)) {
                $rows += [PSCustomObject]@{
                    SampleTimeUtc = $SampleTimeUtc.ToString('o')
                    Iteration     = $Iteration
                    Section       = $Section
                    Entity        = $entity
                    Metric        = [string]$prop.Name
                    Value         = $num
                }
            }
        }
    }

    return ,$rows
}

function Convert-SectionToFlatObjects {
    param(
        [object[]]$Items,
        [Parameter(Mandatory = $true)][int]$Iteration,
        [Parameter(Mandatory = $true)][DateTime]$SampleTimeUtc
    )

    $out = @()
    if ($null -eq $Items) { return ,$out }
    foreach ($item in $Items) {
        if ($null -eq $item) { continue }

        $name = if ($item.PSObject.Properties['volumeName']) { [string]$item.volumeName } elseif ($item.PSObject.Properties['name']) { [string]$item.name } else { '' }
        $label = if ($item.PSObject.Properties['label']) { [string]$item.label } else { '' }
        $id = if ($item.PSObject.Properties['volumeId']) { [string]$item.volumeId } elseif ($item.PSObject.Properties['id']) { [string]$item.id } else { '' }
        $volumeRef = if ($item.PSObject.Properties['volumeRef']) { [string]$item.volumeRef } else { '' }
        $controllerRef = if ($item.PSObject.Properties['controllerRef']) { [string]$item.controllerRef } else { '' }
        $driveRef = if ($item.PSObject.Properties['driveRef']) { [string]$item.driveRef } else { '' }
        $observedTime = if ($item.PSObject.Properties['observedTime']) { [string]$item.observedTime } else { '' }
        $observedTimeInMS = if ($item.PSObject.Properties['observedTimeInMS']) { [string]$item.observedTimeInMS } else { '' }

        $out += [PSCustomObject]@{
            SampleTimeUtc    = $SampleTimeUtc.ToString('o')
            Iteration        = $Iteration
            Name             = $name
            Label            = $label
            Id               = $id
            VolumeRef        = $volumeRef
            ControllerRef    = $controllerRef
            DriveRef         = $driveRef
            ObservedTime     = $observedTime
            ObservedTimeInMS = $observedTimeInMS
            RawJson          = ($item | ConvertTo-Json -Depth 6 -Compress)
        }
    }
    return ,$out
}

function Ensure-Array {
    param([object]$InputObject)
    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [System.Array]) { return @($InputObject) }
    return @($InputObject)
}

function Get-PayloadSection {
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    if ($null -eq $Payload) { return @() }
    if (-not $Payload.PSObject.Properties[$PropertyName]) { return @() }
    return Ensure-Array $Payload.$PropertyName
}

function Export-SectionCsv {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rows
    )

    if ($null -eq $Rows -or $Rows.Count -eq 0) { return }
    $append = Test-Path -Path $Path
    $Rows | Export-Csv -Path $Path -NoTypeInformation -Append:$append
}

function Get-NormalizedVolumeFilter {
    param([string[]]$Names)

    $normalized = @(
        $Names |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Select-Object -Unique
    )

    return ,$normalized
}

function Select-VolumeItems {
    param(
        [object[]]$Items,
        [string[]]$VolumeFilter
    )

    if ($null -eq $Items -or $Items.Count -eq 0) { return @() }
    if ($null -eq $VolumeFilter -or $VolumeFilter.Count -eq 0) { return @($Items) }

    $selected = @()
    foreach ($item in $Items) {
        if ($null -eq $item) { continue }

        $candidates = @()
        # Volume API objects use volumeName, volumeId, volumeRef; also check generic name/label/id
        foreach ($key in @('volumeName', 'volumeId', 'volumeRef', 'name', 'id', 'label')) {
            if ($item.PSObject.Properties[$key]) {
                $value = [string]$item.$key
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $candidates += $value.Trim().ToLowerInvariant()
                }
            }
        }

        if ($null -ne ($candidates | Where-Object { $_ -in $VolumeFilter } | Select-Object -First 1)) {
            $selected += $item
        }
    }

    return ,$selected
}

# Load SANtricity module
try {
    Import-Module -Name ./santricity/santricity.psm1 -Force -ErrorAction Stop
    Write-Host "Successfully imported SANtricity module."
} catch {
    Write-Host "Run this script from repository root where santricity/ folder is located. Failed to import SANtricity module. Error: $_"
    exit 1
}

# Inputs
$credential = $Credential
if ($null -eq $credential) {
    $credential = Get-Credential -Message "Enter SANtricity credentials"
}

$santricityHost = $BaseUrl
if ([string]::IsNullOrWhiteSpace($santricityHost)) {
    $santricityHost = Read-Host -Prompt "Enter SANtricity array base URL (e.g. https://controller1:8443)"
}

if ([string]::IsNullOrWhiteSpace($santricityHost)) {
    Write-Host "Base URL is required."
    exit 1
}

try {
    if ($SkipCertificateCheck) {
        Connect-SANtricity -Credential $credential -BaseUrl $santricityHost -SkipCertificateCheck
    } else {
        Connect-SANtricity -Credential $credential -BaseUrl $santricityHost
    }
    Write-Host "Successfully authenticated with SANtricity API at $santricityHost"
} catch {
    Write-Host "Failed to authenticate with SANtricity API at $santricityHost. Error: $_"
    exit 1
}

$defaultOutputRoot = Join-Path -Path (Get-HomeDirectory) -ChildPath 'Documents'
$outputRoot = $OutputRoot
if ([string]::IsNullOrWhiteSpace($outputRoot)) {
    $outputRoot = Read-Host -Prompt "Enter output directory root for collection runs (default: $defaultOutputRoot)"
}
if ([string]::IsNullOrWhiteSpace($outputRoot)) {
    $outputRoot = $defaultOutputRoot
}
if (-not (Test-Path -Path $outputRoot -PathType Container)) {
    Write-Host "Output directory does not exist. Creating: $outputRoot"
    New-Item -Path $outputRoot -ItemType Directory -Force | Out-Null
}

$intervalSeconds = if ($IntervalSeconds -gt 0) { $IntervalSeconds } else { Read-IntOrDefault -Prompt 'Enter collection interval in seconds; 300 or 600 is suggested' -Default 300 -Min 1 }
$sampleCount = if ($SampleCount -gt 0) { $SampleCount } else { Read-IntOrDefault -Prompt 'Enter number of samples to collect' -Default 12 -Min 1 }

$exportRawClixml = -not $NoRawClixml
if (-not $PSBoundParameters.ContainsKey('NoRawClixml')) {
    $rawChoice = Read-Host -Prompt 'Export raw payload snapshots to CLIXML too? (Y/N, default: Y)'
    $exportRawClixml = $true
    if (-not [string]::IsNullOrWhiteSpace($rawChoice)) {
        $exportRawClixml = @('Y', 'YES') -contains $rawChoice.Trim().ToUpperInvariant()
    }
}

$volumeFilter = Get-NormalizedVolumeFilter -Names $Volumes
if ($volumeFilter.Count -gt 0) {
    Write-Host "Volume filter enabled: $($volumeFilter -join ', ')"
}

# Run folder
$runId = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$runDir = Join-Path -Path $outputRoot -ChildPath "santricity_run_$runId"
$rawDir = Join-Path -Path $runDir -ChildPath 'raw'

New-Item -Path $runDir -ItemType Directory -Force | Out-Null
if ($exportRawClixml) {
    New-Item -Path $rawDir -ItemType Directory -Force | Out-Null
}

# Output files
$paths = @{
    Manifest     = Join-Path $runDir 'manifest.json'
    MetricsLong  = Join-Path $runDir 'metrics_long.csv'
    System       = Join-Path $runDir 'live_system.csv'
    Controller   = Join-Path $runDir 'live_controller.csv'
    Volume       = Join-Path $runDir 'live_volume.csv'
    Interface    = Join-Path $runDir 'live_interface.csv'
    Drive        = Join-Path $runDir 'live_drive.csv'
    FlashCache   = Join-Path $runDir 'live_flashcache.csv'
    Errors       = Join-Path $runDir 'errors.log'
}

$manifest = [ordered]@{
    runId           = $runId
    startedUtc      = (Get-Date).ToUniversalTime().ToString('o')
    baseUrl         = $santricityHost
    intervalSeconds = $intervalSeconds
    sampleCount     = $sampleCount
    volumeFilter    = $volumeFilter
    exportRawClixml = $exportRawClixml
    files           = $paths
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $paths.Manifest

Write-Host "Run folder: $runDir"
Write-Host "Starting collection: $sampleCount sample(s) every $intervalSeconds second(s)..."

$rawLiveSamples = @()

for ($i = 1; $i -le $sampleCount; $i++) {
    $sampleUtc = (Get-Date).ToUniversalTime()
    Write-Host "[$i/$sampleCount] Collecting live statistics at $($sampleUtc.ToString('o'))"

    try {
        $payload = Get-SANtricityLiveStatistics
        if ($exportRawClixml) {
            $rawLiveSamples += [PSCustomObject]@{
                SampleTimeUtc = $sampleUtc.ToString('o')
                Iteration     = $i
                Payload       = $payload
            }
        }

        $sections = @{
            system     = Get-PayloadSection -Payload $payload -PropertyName 'systemStats'
            controller = Get-PayloadSection -Payload $payload -PropertyName 'controllerStats'
            volume     = Get-PayloadSection -Payload $payload -PropertyName 'volumeStats'
            interface  = Get-PayloadSection -Payload $payload -PropertyName 'interfaceStats'
            drive      = Get-PayloadSection -Payload $payload -PropertyName 'driveStats'
        }

        if ($volumeFilter.Count -gt 0) {
            $sections['volume'] = Select-VolumeItems -Items $sections['volume'] -VolumeFilter $volumeFilter
        }

        # Attempt to collect Flash Cache statistics (may not be available on all arrays)
        $flashCacheStats = $null
        try {
            $flashCacheStats = Get-SANtricityFlashCacheStatistics -ErrorAction SilentlyContinue
        } catch {
            Write-Verbose "Flash Cache statistics not available on this array (expected if Flash Cache not installed): $_"
        }

        if ($null -ne $flashCacheStats) {
            $sections['flashCache'] = @($flashCacheStats)
        }

        # Long-format numeric metrics (best for Excel pivots/charts)
        foreach ($sectionName in $sections.Keys) {
            $longRows = Convert-SectionToRows -Items $sections[$sectionName] -Section $sectionName -Iteration $i -SampleTimeUtc $sampleUtc
            Export-SectionCsv -Path $paths.MetricsLong -Rows $longRows
        }

        # Section-specific flat CSVs for direct browsing/filtering
        Export-SectionCsv -Path $paths.System     -Rows (Convert-SectionToFlatObjects -Items $sections['system']     -Iteration $i -SampleTimeUtc $sampleUtc)
        Export-SectionCsv -Path $paths.Controller -Rows (Convert-SectionToFlatObjects -Items $sections['controller'] -Iteration $i -SampleTimeUtc $sampleUtc)
        Export-SectionCsv -Path $paths.Volume     -Rows (Convert-SectionToFlatObjects -Items $sections['volume']     -Iteration $i -SampleTimeUtc $sampleUtc)
        Export-SectionCsv -Path $paths.Interface  -Rows (Convert-SectionToFlatObjects -Items $sections['interface']  -Iteration $i -SampleTimeUtc $sampleUtc)
        Export-SectionCsv -Path $paths.Drive      -Rows (Convert-SectionToFlatObjects -Items $sections['drive']      -Iteration $i -SampleTimeUtc $sampleUtc)
        if ($sections.ContainsKey('flashCache')) {
            Export-SectionCsv -Path $paths.FlashCache -Rows (Convert-SectionToFlatObjects -Items $sections['flashCache'] -Iteration $i -SampleTimeUtc $sampleUtc)
        }
    } catch {
        $msg = "[$((Get-Date).ToString('o'))] Iteration $i failed: $($_.Exception.Message)"
        Write-Host $msg
        Add-Content -Path $paths.Errors -Value $msg
    }

    if ($i -lt $sampleCount) {
        Start-Sleep -Seconds $intervalSeconds
    }
}

if ($exportRawClixml) {
    $rawPath = Join-Path $rawDir 'live_statistics_samples.clixml'
    $rawLiveSamples | Export-Clixml -Path $rawPath
}

$manifest.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $paths.Manifest

Write-Host "Collection finished."
Write-Host "Primary chart input: $($paths.MetricsLong)"
Write-Host "Run manifest: $($paths.Manifest)"
