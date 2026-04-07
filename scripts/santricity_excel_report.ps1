#!/usr/bin/env pwsh

# (C) 2026 @scaleoutSean (Github) | MIT License

<#
.SYNOPSIS
Builds an Excel-ready report from SANtricity collector output.

.DESCRIPTION
Consumes a run folder created by scripts/santricity_collector.ps1 and produces:
 - santricity_report.xlsx (if ImportExcel module is available)
 - plus CSV fallback outputs if ImportExcel is not installed

The report computes per-second rates from monotonic counters using SampleTimeUtc
between consecutive points. This avoids assuming fixed client wait intervals.
All users:
Install-Module -Name ImportExcel -Scope CurrentUser
Linux users (additionally):
sudo apt-get install -y --no-install-recommends libgdiplus libc6-dev

#>

[CmdletBinding()]
param(
    [string]$RunDir,
    [string]$OutputFile,
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HomeDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { return $env:HOME }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $env:USERPROFILE }
    return (Get-Location).Path
}

function Get-LatestRunDir {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -Path $Root -PathType Container)) {
        throw "Output root does not exist: $Root"
    }

    $candidate = Get-ChildItem -Path $Root -Directory -Filter 'santricity_run_*' |
        Sort-Object -Property LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        throw "No santricity_run_* folders found under: $Root"
    }

    return $candidate.FullName
}

function Get-Percentile {
    param(
        [Parameter(Mandatory = $true)][double[]]$Values,
        [Parameter(Mandatory = $true)][double]$Percent
    )

    if ($Values.Count -eq 0) { return 0.0 }

    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) { return [double]$sorted[0] }

    $rank = ($Percent / 100.0) * ($sorted.Count - 1)
    $lo = [math]::Floor($rank)
    $hi = [math]::Ceiling($rank)
    if ($lo -eq $hi) {
        return [double]$sorted[$lo]
    }

    $frac = $rank - $lo
    return ([double]$sorted[$lo] * (1.0 - $frac)) + ([double]$sorted[$hi] * $frac)
}

function Parse-MetricsLong {
    param([Parameter(Mandatory = $true)][string]$CsvPath)

    $rows = @()
    foreach ($r in (Import-Csv -Path $CsvPath)) {
        $dto = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$r.SampleTimeUtc, [ref]$dto)) {
            continue
        }

        $iteration = 0
        [void][int]::TryParse([string]$r.Iteration, [ref]$iteration)

        $value = 0.0
        if (-not [double]::TryParse([string]$r.Value, [ref]$value)) {
            continue
        }

        $rows += [PSCustomObject]@{
            SampleTimeUtc = $dto.UtcDateTime
            Iteration     = $iteration
            Section       = [string]$r.Section
            Entity        = [string]$r.Entity
            Metric        = [string]$r.Metric
            Value         = $value
        }
    }

    return ,$rows
}

function Build-RateRows {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    $explicitCounterMetrics = @(
        'totalIopsServiced', 'readIopsTotal', 'writeIopsTotal',
        'totalBytesServiced', 'readBytesTotal', 'writeBytesTotal',
        'readOps', 'writeOps', 'otherOps',
        'readBytes', 'writeBytes', 'prefetchHitBytes', 'prefetchMissBytes',
        'totalBlksEvicted', 'flashCacheReadHitOps', 'flashCacheReadHitBytes',
        'reads', 'writes', 'readBlocks', 'writeBlocks',
        'fullCacheHits', 'partialCacheHits', 'completeCacheMiss',
        'fullCacheHitBlocks', 'partialCacheHitBlocks', 'completeCacheMissBlocks',
        'populateOnReads', 'populateOnReadBlocks', 'populateOnWrites', 'populateOnWriteBlocks',
        'invalidates', 'recycles'
    )

    $explicitGaugeMetrics = @(
        'cacheBlksInUse',
        'availableBytes', 'allocatedBytes', 'populatedCleanBytes', 'populatedDirtyBytes',
        'averageReadOpSize', 'averageWriteOpSize',
        'readPercent', 'writePercent'
    )

    $counterRows = @(
        $Rows | Where-Object {
            $metric = [string]$_.Metric
            ($metric -in $explicitCounterMetrics) -or
            (
                $metric -match '(Total|Serviced)$' -or
                $metric -match '(^|[a-z])(Ops|Bytes|Blocks|Hits|Miss|Misses)$'
            ) -and
            ($metric -notin $explicitGaugeMetrics)
        }
    )

    $rateRows = @()

    foreach ($g in ($counterRows | Group-Object -Property Section, Entity, Metric)) {
        $series = @($g.Group | Sort-Object -Property SampleTimeUtc)
        for ($i = 1; $i -lt $series.Count; $i++) {
            $prev = $series[$i - 1]
            $cur = $series[$i]
            $dt = ($cur.SampleTimeUtc - $prev.SampleTimeUtc).TotalSeconds
            if ($dt -le 0) { continue }

            $delta = $cur.Value - $prev.Value
            # Skip likely counter resets/wrap events.
            if ($delta -lt 0) { continue }

            $rate = $delta / $dt
            $isBytes = $cur.Metric -match 'Bytes'

            $rateRows += [PSCustomObject]@{
                SampleTimeUtc   = $cur.SampleTimeUtc.ToString('o')
                Iteration       = $cur.Iteration
                Section         = $cur.Section
                Entity          = $cur.Entity
                Metric          = $cur.Metric
                IntervalSeconds = [math]::Round($dt, 3)
                Delta           = [math]::Round($delta, 6)
                RatePerSec      = [math]::Round($rate, 6)
                Unit            = if ($isBytes) { 'Bytes/s' } else { 'Ops/s' }
                RateMiBPerSec   = if ($isBytes) { [math]::Round($rate / 1MB, 6) } else { $null }
            }
        }
    }

    return ,$rateRows
}

function Build-GroupedSeriesRows {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Metrics,
        [Parameter(Mandatory = $true)][string]$ValueProperty,
        [string]$Section
    )

    $filtered = @(
        $Rows | Where-Object {
            ($null -eq $Section -or [string]::IsNullOrWhiteSpace($Section) -or [string]$_.Section -eq $Section) -and
            ([string]$_.Metric -in $Metrics) -and
            ($null -ne $_.$ValueProperty)
        }
    )

    if ($filtered.Count -eq 0) { return @() }

    $times = @(
        $filtered |
        Select-Object -ExpandProperty SampleTimeUtc -Unique |
        Sort-Object {
            $dto = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse([string]$_, [ref]$dto)) { $dto.UtcDateTime } else { [DateTime]::MinValue }
        }
    )

    $seriesRows = @()
    foreach ($time in $times) {
        $atTime = @($filtered | Where-Object { [string]$_.SampleTimeUtc -eq [string]$time })
        $obj = [ordered]@{ SampleTimeUtc = [string]$time }
        $hasData = $false

        foreach ($m in $Metrics) {
            $vals = @($atTime | Where-Object { [string]$_.Metric -eq $m } | ForEach-Object { [double]$_.$ValueProperty })
            if ($vals.Count -gt 0) {
                $obj[$m] = [math]::Round((($vals | Measure-Object -Sum).Sum), 6)
                $hasData = $true
            }
            else {
                $obj[$m] = $null
            }
        }

        if ($hasData) {
            $seriesRows += [PSCustomObject]$obj
        }
    }

    return ,$seriesRows
}

function Build-VolumeAvgReqSizeRows {
    param([Parameter(Mandatory = $true)][object[]]$RateRows)

    $vol = @(
        $RateRows | Where-Object {
            $_.Section -eq 'volume' -and
            $_.Metric -in @('readBytes', 'writeBytes', 'readOps', 'writeOps')
        }
    )

    if ($vol.Count -eq 0) { return @() }

    $times = @($vol | Select-Object -ExpandProperty SampleTimeUtc -Unique | Sort-Object)
    $rows = @()

    foreach ($time in $times) {
        $atTime = @($vol | Where-Object { [string]$_.SampleTimeUtc -eq [string]$time })
        $readBytesRate = @($atTime | Where-Object { $_.Metric -eq 'readBytes' } | ForEach-Object { [double]$_.RatePerSec } | Measure-Object -Sum).Sum
        $writeBytesRate = @($atTime | Where-Object { $_.Metric -eq 'writeBytes' } | ForEach-Object { [double]$_.RatePerSec } | Measure-Object -Sum).Sum
        $readOpsRate = @($atTime | Where-Object { $_.Metric -eq 'readOps' } | ForEach-Object { [double]$_.RatePerSec } | Measure-Object -Sum).Sum
        $writeOpsRate = @($atTime | Where-Object { $_.Metric -eq 'writeOps' } | ForEach-Object { [double]$_.RatePerSec } | Measure-Object -Sum).Sum

        $rows += [PSCustomObject]@{
            SampleTimeUtc = [string]$time
            avgReadReqKiB = if ($readOpsRate -gt 0) { [math]::Round(($readBytesRate / $readOpsRate) / 1KB, 4) } else { $null }
            avgWriteReqKiB= if ($writeOpsRate -gt 0) { [math]::Round(($writeBytesRate / $writeOpsRate) / 1KB, 4) } else { $null }
        }
    }

    return ,$rows
}

function Get-ExcelColumnName {
    param([Parameter(Mandatory = $true)][int]$ColumnNumber)

    $name = ''
    $n = $ColumnNumber
    while ($n -gt 0) {
        $n--
        $name = [char](65 + ($n % 26)) + $name
        $n = [math]::Floor($n / 26)
    }

    return $name
}

function Add-ChartSheet {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [AllowNull()][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string[]]$MetricColumns,
        [Parameter(Mandatory = $true)][string]$DataSheet,
        [Parameter(Mandatory = $true)][string]$ViewSheet,
        [Parameter(Mandatory = $true)][string]$TableName,
        [Parameter(Mandatory = $true)][string]$Title
    )

    if ($null -eq $Rows -or $Rows.Count -eq 0) { return }
    if ($Rows.Count -le 1) { return }

    $availableMetrics = @()
    foreach ($metric in $MetricColumns) {
        $hasValues = $null -ne ($Rows | Where-Object { $null -ne $_.$metric } | Select-Object -First 1)
        if ($hasValues) {
            $availableMetrics += $metric
        }
    }

    if ($availableMetrics.Count -eq 0) { return }

    $exportRows = @()
    foreach ($row in $Rows) {
        $obj = [ordered]@{ SampleTimeUtc = [string]$row.SampleTimeUtc }
        foreach ($metric in $availableMetrics) {
            $obj[$metric] = $row.$metric
        }
        $exportRows += [PSCustomObject]$obj
    }

    if ($exportRows.Count -eq 0) { return }

    $exportRows | Export-Excel -Path $OutputPath -WorksheetName $DataSheet -AutoFilter -AutoSize -FreezeTopRow -TableName $TableName -Append

    $end = $exportRows.Count + 1
    $xRange = "$DataSheet!A2:A$end"
    $yRanges = @()
    for ($i = 0; $i -lt $availableMetrics.Count; $i++) {
        $colName = Get-ExcelColumnName -ColumnNumber ($i + 2)
        $yRanges += "$DataSheet!${colName}2:${colName}$end"
    }

    $seriesHeaders = @(for ($i = 0; $i -lt $availableMetrics.Count; $i++) {
        $colName = Get-ExcelColumnName -ColumnNumber ($i + 2)
        "=$DataSheet!${colName}1"
    })

    $chartParams = @{
        Title     = $Title
        ChartType = 'Line'
        XRange    = $xRange
        YRange    = $yRanges
        SeriesHeader = $seriesHeaders
        Width     = 950
        Height    = 360
        Row       = 1
        Column    = 1
    }

    if ($availableMetrics.Count -eq 1) {
        $chartParams['NoLegend'] = $true
    }

    $chart = New-ExcelChartDefinition @chartParams
    @([PSCustomObject]@{ Label = $Title; Value = 'See chart' }) |
        Export-Excel -Path $OutputPath -WorksheetName $ViewSheet -AutoFilter -AutoSize -FreezeTopRow -Append -ExcelChartDefinition $chart
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path -Path (Get-HomeDirectory) -ChildPath 'Documents'
}

if ([string]::IsNullOrWhiteSpace($RunDir)) {
    $RunDir = Get-LatestRunDir -Root $OutputRoot
}

if (-not (Test-Path -Path $RunDir -PathType Container)) {
    throw "RunDir does not exist: $RunDir"
}

$metricsPath = Join-Path -Path $RunDir -ChildPath 'metrics_long.csv'
if (-not (Test-Path -Path $metricsPath -PathType Leaf)) {
    throw "metrics_long.csv not found in run folder: $RunDir"
}

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path -Path $RunDir -ChildPath 'santricity_report.xlsx'
}

$metricsRows = Parse-MetricsLong -CsvPath $metricsPath
if ($metricsRows.Count -eq 0) {
    throw "No numeric metric rows found in metrics_long.csv"
}

$rateRows = Build-RateRows -Rows $metricsRows

$volumeOpsRows = Build-GroupedSeriesRows -Rows $rateRows -Section 'volume' -Metrics @('readOps', 'writeOps', 'otherOps') -ValueProperty 'RatePerSec'
$volumeBytesRows = Build-GroupedSeriesRows -Rows $rateRows -Section 'volume' -Metrics @('readBytes', 'writeBytes', 'prefetchHitBytes', 'prefetchMissBytes') -ValueProperty 'RateMiBPerSec'
$volumeEvictRows = Build-GroupedSeriesRows -Rows $rateRows -Section 'volume' -Metrics @('totalBlksEvicted') -ValueProperty 'RatePerSec'
$volumeFlashHitOpsRows = Build-GroupedSeriesRows -Rows $rateRows -Section 'volume' -Metrics @('flashCacheReadHitOps') -ValueProperty 'RatePerSec'
$volumeFlashHitBytesRows = Build-GroupedSeriesRows -Rows $rateRows -Section 'volume' -Metrics @('flashCacheReadHitBytes') -ValueProperty 'RateMiBPerSec'
$volumeCacheInUseRows = Build-GroupedSeriesRows -Rows $metricsRows -Section 'volume' -Metrics @('cacheBlksInUse') -ValueProperty 'Value'
$volumeAvgReqSizeRows = Build-VolumeAvgReqSizeRows -RateRows $rateRows

$flashGaugeRows = Build-GroupedSeriesRows -Rows $metricsRows -Metrics @('availableBytes', 'allocatedBytes', 'populatedCleanBytes', 'populatedDirtyBytes') -ValueProperty 'Value'
$flashRwRows = Build-GroupedSeriesRows -Rows $rateRows -Metrics @('reads', 'writes') -ValueProperty 'RatePerSec'
$flashHitMissRows = Build-GroupedSeriesRows -Rows $rateRows -Metrics @('fullCacheHits', 'partialCacheHits', 'completeCacheMiss') -ValueProperty 'RatePerSec'
$flashBlocksRows = Build-GroupedSeriesRows -Rows $rateRows -Metrics @('writeBlocks', 'readBlocks', 'fullCacheHitBlocks', 'populateOnWriteBlocks', 'completeCacheMissBlocks', 'populateOnReadBlocks', 'partialCacheHitBlocks') -ValueProperty 'RatePerSec'
$flashLifecycleRows = Build-GroupedSeriesRows -Rows $rateRows -Metrics @('populateOnReads', 'populateOnWrites', 'invalidates', 'recycles') -ValueProperty 'RatePerSec'

$systemRates = @(
    $rateRows | Where-Object {
        $_.Section -eq 'system' -and
        $_.Entity -eq '(aggregate)' -and
        $_.Metric -in @(
            'totalIopsServiced',
            'totalBytesServiced',
            'readIopsTotal',
            'writeIopsTotal',
            'readBytesTotal',
            'writeBytesTotal'
        )
    }
)

$summaryRows = @()
foreach ($grp in ($systemRates | Group-Object -Property Metric)) {
    $rates = @($grp.Group | ForEach-Object { [double]$_.RatePerSec })
    if ($rates.Count -eq 0) { continue }

    $summaryRows += [PSCustomObject]@{
        Metric       = $grp.Name
        Samples      = $rates.Count
        AvgRatePerSec= [math]::Round((($rates | Measure-Object -Average).Average), 4)
        MaxRatePerSec= [math]::Round((($rates | Measure-Object -Maximum).Maximum), 4)
        P95RatePerSec= [math]::Round((Get-Percentile -Values $rates -Percent 95), 4)
        Unit         = if ($grp.Name -match 'Bytes') { 'Bytes/s' } else { 'Ops/s' }
        AvgMiBPerSec = if ($grp.Name -match 'Bytes') { [math]::Round((($rates | Measure-Object -Average).Average / 1MB), 4) } else { $null }
        MaxMiBPerSec = if ($grp.Name -match 'Bytes') { [math]::Round((($rates | Measure-Object -Maximum).Maximum / 1MB), 4) } else { $null }
        P95MiBPerSec = if ($grp.Name -match 'Bytes') { [math]::Round((Get-Percentile -Values $rates -Percent 95) / 1MB, 4) } else { $null }
    }
}

$systemIopsRows = Build-GroupedSeriesRows -Rows $rateRows -Section 'system' -Metrics @('readIopsTotal', 'writeIopsTotal', 'totalIopsServiced') -ValueProperty 'RatePerSec'
$systemMiBpsRows = Build-GroupedSeriesRows -Rows $rateRows -Section 'system' -Metrics @('readBytesTotal', 'writeBytesTotal', 'totalBytesServiced') -ValueProperty 'RateMiBPerSec'

# Always export CSV artifacts as a portable fallback.
$rateCsvPath = Join-Path -Path $RunDir -ChildPath 'rates_per_second.csv'
$summaryCsvPath = Join-Path -Path $RunDir -ChildPath 'report_summary.csv'
$systemCsvPath = Join-Path -Path $RunDir -ChildPath 'system_rates.csv'

$rateRows | Export-Csv -Path $rateCsvPath -NoTypeInformation
$summaryRows | Export-Csv -Path $summaryCsvPath -NoTypeInformation
$systemRates | Export-Csv -Path $systemCsvPath -NoTypeInformation

$importExcelAvailable = $null -ne (Get-Module -ListAvailable -Name ImportExcel | Select-Object -First 1)
if (-not $importExcelAvailable) {
    Write-Host "ImportExcel module not found. CSV report artifacts were generated instead:"
    Write-Host " - $rateCsvPath"
    Write-Host " - $summaryCsvPath"
    Write-Host " - $systemCsvPath"
    Write-Host "Install module with: Install-Module ImportExcel -Scope CurrentUser"
    exit 0
}

Import-Module ImportExcel -ErrorAction Stop

if (Test-Path -Path $OutputFile) {
    Remove-Item -Path $OutputFile -Force
}

$metricsRows | Export-Excel -Path $OutputFile -WorksheetName 'MetricsLong' -AutoFilter -AutoSize -FreezeTopRow -TableName 'MetricsLong'
$rateRows | Export-Excel -Path $OutputFile -WorksheetName 'Rates' -AutoFilter -AutoSize -FreezeTopRow -TableName 'Rates' -Append
$systemRates | Export-Excel -Path $OutputFile -WorksheetName 'SystemRates' -AutoFilter -AutoSize -FreezeTopRow -TableName 'SystemRates' -Append
$summaryRows | Export-Excel -Path $OutputFile -WorksheetName 'Summary' -AutoFilter -AutoSize -FreezeTopRow -TableName 'Summary' -Append

Add-ChartSheet -OutputPath $OutputFile -Rows $systemIopsRows -MetricColumns @('readIopsTotal', 'writeIopsTotal', 'totalIopsServiced') -DataSheet 'Chart_Sys_IOPS' -ViewSheet 'Chart_Sys_IOPS_View' -TableName 'ChartSysIOPS' -Title 'System IOPS/s (Read, Write, Total)'
Add-ChartSheet -OutputPath $OutputFile -Rows $systemMiBpsRows -MetricColumns @('readBytesTotal', 'writeBytesTotal', 'totalBytesServiced') -DataSheet 'Chart_Sys_MiBps' -ViewSheet 'Chart_Sys_MiBps_View' -TableName 'ChartSysMiBps' -Title 'System MiB/s (Read, Write, Total)'

Add-ChartSheet -OutputPath $OutputFile -Rows $volumeOpsRows -MetricColumns @('readOps', 'writeOps', 'otherOps') -DataSheet 'Chart_Vol_Ops' -ViewSheet 'Chart_Vol_Ops_View' -TableName 'ChartVolOps' -Title 'Volume Ops/s (Read, Write, Other)'
Add-ChartSheet -OutputPath $OutputFile -Rows $volumeBytesRows -MetricColumns @('readBytes', 'writeBytes', 'prefetchHitBytes', 'prefetchMissBytes') -DataSheet 'Chart_Vol_Bytes' -ViewSheet 'Chart_Vol_Bytes_View' -TableName 'ChartVolBytes' -Title 'Volume Throughput MiB/s (Read, Write, Prefetch Hit/Miss)'
Add-ChartSheet -OutputPath $OutputFile -Rows $volumeEvictRows -MetricColumns @('totalBlksEvicted') -DataSheet 'Chart_Vol_Evict' -ViewSheet 'Chart_Vol_Evict_View' -TableName 'ChartVolEvict' -Title 'Volume Cache Evictions (Blocks/s)'
Add-ChartSheet -OutputPath $OutputFile -Rows $volumeCacheInUseRows -MetricColumns @('cacheBlksInUse') -DataSheet 'Chart_Vol_CacheUse' -ViewSheet 'Chart_Vol_CacheUse_View' -TableName 'ChartVolCacheUse' -Title 'Volume Cache Blocks In Use'
Add-ChartSheet -OutputPath $OutputFile -Rows $volumeFlashHitOpsRows -MetricColumns @('flashCacheReadHitOps') -DataSheet 'Chart_Vol_FlashOps' -ViewSheet 'Chart_Vol_FlashOps_View' -TableName 'ChartVolFlashOps' -Title 'Volume Flash Cache Read Hit Ops/s'
Add-ChartSheet -OutputPath $OutputFile -Rows $volumeFlashHitBytesRows -MetricColumns @('flashCacheReadHitBytes') -DataSheet 'Chart_Vol_FlashMiB' -ViewSheet 'Chart_Vol_FlashMiB_View' -TableName 'ChartVolFlashMiB' -Title 'Volume Flash Cache Read Hit MiB/s'
Add-ChartSheet -OutputPath $OutputFile -Rows $volumeAvgReqSizeRows -MetricColumns @('avgReadReqKiB', 'avgWriteReqKiB') -DataSheet 'Chart_Vol_AvgReq' -ViewSheet 'Chart_Vol_AvgReq_View' -TableName 'ChartVolAvgReq' -Title 'Volume Avg Request Size (KiB)'

Add-ChartSheet -OutputPath $OutputFile -Rows $flashGaugeRows -MetricColumns @('availableBytes', 'allocatedBytes', 'populatedCleanBytes', 'populatedDirtyBytes') -DataSheet 'Chart_FC_Gauges' -ViewSheet 'Chart_FC_Gauges_View' -TableName 'ChartFCGauges' -Title 'Flash Cache Gauges (Bytes)'
Add-ChartSheet -OutputPath $OutputFile -Rows $flashRwRows -MetricColumns @('reads', 'writes') -DataSheet 'Chart_FC_RW' -ViewSheet 'Chart_FC_RW_View' -TableName 'ChartFCRW' -Title 'Flash Cache Reads/Writes per Second'
Add-ChartSheet -OutputPath $OutputFile -Rows $flashHitMissRows -MetricColumns @('fullCacheHits', 'partialCacheHits', 'completeCacheMiss') -DataSheet 'Chart_FC_HitMiss' -ViewSheet 'Chart_FC_HitMiss_View' -TableName 'ChartFCHitMiss' -Title 'Flash Cache Hit/Miss per Second'
Add-ChartSheet -OutputPath $OutputFile -Rows $flashBlocksRows -MetricColumns @('writeBlocks', 'readBlocks', 'fullCacheHitBlocks', 'populateOnWriteBlocks', 'completeCacheMissBlocks', 'populateOnReadBlocks', 'partialCacheHitBlocks') -DataSheet 'Chart_FC_Blocks' -ViewSheet 'Chart_FC_Blocks_View' -TableName 'ChartFCBlocks' -Title 'Flash Cache Block Counters per Second'
Add-ChartSheet -OutputPath $OutputFile -Rows $flashLifecycleRows -MetricColumns @('populateOnReads', 'populateOnWrites', 'invalidates', 'recycles') -DataSheet 'Chart_FC_Life' -ViewSheet 'Chart_FC_Life_View' -TableName 'ChartFCLife' -Title 'Flash Cache Lifecycle Counters per Second'

Write-Host "Report workbook created: $OutputFile"
Write-Host "CSV artifacts:"
Write-Host " - $rateCsvPath"
Write-Host " - $summaryCsvPath"
Write-Host " - $systemCsvPath"
