#!/usr/bin/env pwsh
# -*- coding: utf-8 -*-

# Sanmox is used to configure SANtricity for use with Proxmox VE.
# It sets up SANtricity host groups, volumes, and manages PVE mapping.
#
# License: MIT
# Copyright (c) 2026

param(
    [Parameter(Mandatory = $false)]
    [string]$Config,

    [switch]$ResetCredentials
)

# --- Configuration Paths ---
$scriptDir = if ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { Get-Location }
$defaultConfigFile = Join-Path -Path $scriptDir -ChildPath "sanconfig.json"
$configFile = if ([string]::IsNullOrWhiteSpace($Config)) {
    $defaultConfigFile
} else {
    [System.IO.Path]::GetFullPath($Config)
}
$credFile = Join-Path -Path $HOME -ChildPath ".sanmox_cred.xml"
$pveCredFile = Join-Path -Path $HOME -ChildPath ".sanmox_pve_cred.xml"

# --- Spectre/Dependencies Setup ---
$modules = @('PwshSpectreConsole')
foreach ($module in $modules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Module $module is not installed. Run: Install-Module -Name $module" -ForegroundColor Red
        continue
    }
    Import-Module -Name $module -ErrorAction Stop
}

# Import the core SANtricity module from the parent directory
$santricityModulePath = Join-Path -Path $scriptDir -ChildPath "..\santricity\santricity.psd1"
if (Test-Path -Path $santricityModulePath) {
    Import-Module -Name $santricityModulePath -ErrorAction Stop
} else {
    Write-Host "SANtricity module not found at: $santricityModulePath" -ForegroundColor Yellow
}

if ($ResetCredentials) {
    Write-SpectreHost -Message "[cyan]ResetCredentials switch provided. Removing saved credential files...[/]"
    if (Test-Path -Path $credFile) { Remove-Item -Path $credFile -Force; Write-SpectreHost -Message "Deleted $credFile" }
    if (Test-Path -Path $pveCredFile) { Remove-Item -Path $pveCredFile -Force; Write-SpectreHost -Message "Deleted $pveCredFile" }
}

if (-not [string]::IsNullOrWhiteSpace($Config)) {
    Write-SpectreHost -Message "[cyan]Using config file: $configFile[/]"
}

# --- Interactive Setup & Loading ---
function Initialize-Sanconfig {
    if (Test-Path -Path $configFile) {
        try {
            $Global:sanConfig = Get-Content -Path $configFile -Raw | ConvertFrom-Json
            
            # Validation
            $isValid = $true
            if ([string]::IsNullOrWhiteSpace($Global:sanConfig.SanApiUri) -or $Global:sanConfig.SanApiUri -notmatch "^https?://") { $isValid = $false }
            if ($null -ne $Global:sanConfig.PveApiUri -and $Global:sanConfig.PveApiUri -notmatch "^https?://") { $isValid = $false }
            
            if (-not $isValid) {
                Write-SpectreHost -Message "[red]Loaded configuration at $configFile appears invalid (e.g. malformed URIs).[/]"
                $fix = Read-SpectreSelection -Title "Reset configuration and run setup wizard?" -Choices @("Y. Yes", "N. No, exit")
                if ($fix -match "^Y") {
                    Remove-Item $configFile -Force
                    Initialize-Sanconfig
                    return
                } else {
                    exit 1
                }
            }
            return
        } catch {
            Write-SpectreHost -Message "[red]Failed to parse $configFile. It may be corrupt.[/]"
            $fix = Read-SpectreSelection -Title "Delete configuration and run setup wizard?" -Choices @("Y. Yes", "N. No, exit")
            if ($fix -match "^Y") {
                Remove-Item $configFile -Force
                Initialize-Sanconfig
                return
            } else {
                exit 1
            }
        }
    }

    Write-SpectreHost -Message ""
    Write-SpectreHost -Message "[yellow]Configuration file not found at $configFile.[/]"
    Write-SpectreHost -Message "[yellow]Let's do a quick initial setup![/]"
    Write-SpectreHost -Message ""
    
    $sanUri = Read-Host "Enter SANtricity API URI (e.g. https://controller:8443)"
    $sanUser = Read-Host "Enter SANtricity Username [storage]"
    if ([string]::IsNullOrWhiteSpace($sanUser)) { $sanUser = "storage" }
    
    $sanPool = Read-Host "Enter Default SANtricity Pool Name (e.g. DDP1)"
    $sanHostGroup = Read-Host "Enter SANtricity Host Group for PVE (e.g. pve-cluster-1)"
    
    $pveUri = Read-Host "Enter Proxmox VE API URI (e.g. https://pve:8006)"
    $pveUser = Read-Host "Enter Proxmox VE Username or Token ID (e.g. root@pam!token)"
    
    $skipCertStr = Read-Host "Skip Certificate Verification? (Y/n) [Y]"
    $skipCert = if ($skipCertStr -match '^[Nn]') { $false } else { $true }

    $defaultConfig = @{
        SanApiUri = $sanUri
        SanUser = $sanUser
        SanPoolName = $sanPool
        SanHostGroupName = @($sanHostGroup) # Store as array!
        PveApiUri = $pveUri
        PveUser = $pveUser
        SkipCertificateCheck = $skipCert
    }
    
    $Global:sanConfig = $defaultConfig
    $Global:sanConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $configFile
    Write-SpectreHost -Message "[green]Config saved to $configFile[/]"
    Write-SpectreHost -Message ""
}

Initialize-Sanconfig

$hasPlaintextPveSecret = -not [string]::IsNullOrWhiteSpace([string]$Global:sanConfig.PveSecret)

# --- Module Loader ---
$sanmoxModules = @('SanmoxConnect', 'SanmoxUI', 'SanmoxPve', 'SanmoxVolume', 'SanmoxHostGroup', 'SanmoxToolbox', 'SanmoxStoragePool', 'SanmoxTargetOverview')
foreach ($sanmod in $sanmoxModules) {
    $modulePath = Join-Path -Path $scriptDir -ChildPath "${sanmod}.psm1"
    if (Test-Path -Path $modulePath) {
        Import-Module -Name $modulePath -Force -ErrorAction Stop
    } else {
        Write-Host "Sanmox module not found: ${sanmod}.psm1" -ForegroundColor Yellow
    }
}

if ($hasPlaintextPveSecret) {
    $warningProfileName = [System.IO.Path]::GetFileName($configFile)
    $warningProfileNameSafe = if ($warningProfileName) { $warningProfileName.Replace('[', '[[').Replace(']', ']]') } else { 'sanconfig.json' }
    Write-SpectreHost -Message "[yellow]Warning: plaintext PVE secret detected in profile [white]$warningProfileNameSafe[/] (`PveSecret`). SANmox will use it only if no encrypted PVE credential is already saved. Remove `PveSecret` from the config after migrating it to the secure credential file.[/]"
}

# --- Authentication Handling ---
if (Test-Path -Path $credFile) {
    try {
        $Global:sanPass = Import-Clixml -Path $credFile -ErrorAction Stop
    } catch {
        Write-Host "Failed to load credentials from $credFile. They may be invalid or encrypted for another user/machine." -ForegroundColor Red
        Remove-Item -Path $credFile -Force -ErrorAction SilentlyContinue
    }
}

if (-not $Global:sanPass) {
    $plainValue = Read-Host -AsSecureString "Please enter password for SANtricity user '$($Global:sanConfig.SanUser)' (input hidden)"
    $Global:sanPass = $plainValue
    
    $savePass = Read-Host "Do you want to save this password securely for future sessions? (Y/n)"
    if ($savePass -notmatch '^[Nn]$') {
        $Global:sanPass | Export-Clixml -Path $credFile
        Write-Host "Credentials saved to $credFile" -ForegroundColor Green
    }
}

if (Test-Path -Path $pveCredFile) {
    try {
        $Global:pvePass = Import-Clixml -Path $pveCredFile -ErrorAction Stop
    } catch {
        Write-Host "Failed to load PVE credentials from $pveCredFile." -ForegroundColor Red
        Remove-Item -Path $pveCredFile -Force -ErrorAction SilentlyContinue
    }
}

if (
    -not $Global:pvePass -and
    [string]::IsNullOrWhiteSpace([string]$Global:sanConfig.PveSecret) -and
    -not [string]::IsNullOrWhiteSpace($Global:sanConfig.PveApiUri)
) {
    $plainPvePass = Read-Host -AsSecureString "Please enter password/secret for PVE user '$($Global:sanConfig.PveUser)' (input hidden)"
    $Global:pvePass = $plainPvePass
    
    $savePvePass = Read-Host "Do you want to save this PVE password securely for future sessions? (Y/n)"
    if ($savePvePass -notmatch '^[Nn]$') {
        $Global:pvePass | Export-Clixml -Path $pveCredFile
        Write-Host "PVE Credentials saved to $pveCredFile" -ForegroundColor Green
    }
}

function Test-SanmoxHostObjectUniqueness {
    [CmdletBinding()]
    param()

    if (-not $Global:sanConnected) {
        return $true
    }

    try {
        $hosts = @(Get-SANtricityHost)
        $hostGroups = @(Get-SANtricityHostGroup)
    } catch {
        Write-SpectreHost -Message "[yellow]Could not validate Host/Host Group uniqueness during startup. Continuing.[/]"
        return $true
    }

    $hostKeySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($sanHost in $hosts) {
        foreach ($candidate in @($sanHost.name, $sanHost.label)) {
            $name = ([string]$candidate).Trim()
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                [void]$hostKeySet.Add($name)
            }
        }
    }

    $collisions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($hostGroup in $hostGroups) {
        foreach ($candidate in @($hostGroup.name, $hostGroup.label)) {
            $name = ([string]$candidate).Trim()
            if (-not [string]::IsNullOrWhiteSpace($name) -and $hostKeySet.Contains($name)) {
                [void]$collisions.Add($name)
            }
        }
    }

    if ($collisions.Count -gt 0) {
        $collisionList = @($collisions | Sort-Object) -join ', '
        Write-SpectreHost -Message "[red]Unsafe SANtricity naming collision detected between Host and Host Group objects.[/]"
        Write-SpectreHost -Message "[red]Host and host groups must be unique within each storage system.[/]"
        Write-SpectreHost -Message "[yellow]Conflicting name(s): $collisionList[/]"
        return $false
    }

    return $true
}

# --- Connect ---
Connect-SanmoxEnvironment
if (-not (Test-SanmoxHostObjectUniqueness)) {
    Write-SpectreHost -Message "[red]Startup aborted due to Host/Host Group naming collision. Please rename the conflicting SANtricity objects and retry.[/]"
    exit 1
}

$configProfileName = [System.IO.Path]::GetFileName($configFile)
$configProfileNameSafe = if ($configProfileName) { $configProfileName.Replace('[', '[[').Replace(']', ']]') } else { "sanconfig.json" }
Write-SpectreRule -Title "Sanmox: Console for Proxmox PVE with NetApp SANtricity | Profile: $configProfileNameSafe | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Alignment Center -Color Red
$poolNameSafe = $Global:sanConfig.SanPoolName.ToString().Replace('[', '[[').Replace(']', ']]')
$hostGroupNameSafe = if ($Global:sanConfig.SanHostGroupName) { ($Global:sanConfig.SanHostGroupName -join ', ').Replace('[', '[[').Replace(']', ']]') } else { "None" }
Write-SpectreHost -Message "Welcome to [blue underline]Sanmox[/]. Profile: [green]$configProfileNameSafe[/] | Pinning to Storage Pool: [green]$poolNameSafe[/] | Host Group(s): [green]$hostGroupNameSafe[/]`n"

# --- Main Menu Loop ---
do {
    $mainChoices = @(
        "1. Proxmox-SANtricity toolbox :toolbox:",
        "2. SANtricity Volumes :floppy_disk:",
        "3. SANtricity Host Groups :shield:",
        "4. SANtricity Storage Pools (DDP) :up_down_arrow:",
        "5. Volume Utilization & Target Settings :eyes:",
        "6. Performance tools :bar_chart:",
        "7. First-time setup / Config :gear:",
        "Q. Quit :stop_sign:"
    )
    $MainMenu = Read-SpectreSelection -Title "Select a [Blue]task[/] using :up_down_arrow: or search" -Choices $mainChoices -Color Turquoise2 -PageSize 10 -EnableSearch

    if ($MainMenu -match '^[1-7qQ]\.?' ) {
        $MainMenu = $MainMenu.Substring(0, 1).ToUpper()
    } else {
        Write-SpectreHost -Message "Invalid selection. Please try again."
        continue
    }

    switch ($MainMenu) {
        '1' {
            # --- Toolbox Submenu ---
            $sub = ''
            do {
                Write-SpectreRule -Title "SANtricity-Proxmox Toolbox :toolbox: | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Alignment Center -Color Yellow
                $toolboxChoices = @(
                    "1. [Blue]View[/] SANtricity-backed PVE Datastores and Mappings :eyes:",
                    "2. [Blue]View[/] Configured Host Group/Host Disk Identifiers & Paths :eyes:",
                    "3. [Blue]View[/] E-Series Disks from PVE Host Perspective :desktop_computer:",
                    "4. [Green]Create[/] new [orange3]PVE[/] datastore (iSCSI or NVMe-backed LVM) :new_button:",
                    "5. [Purple_2]Remove[/] [orange3]PVE[/] datastore (WARNING: Datastore must be empty) :litter_in_bin_sign:",
                    "B. Back to [Blue]main menu[/] :house:"
                )
                $sub = Read-SpectreSelection -Title "Pick a [Blue]tool[/]" -Choices $toolboxChoices -Color Turquoise2 -PageSize 10 -EnableSearch
                
                switch ($sub.Substring(0, 1).ToUpper()) {
                    '1' { Get-SanmoxStorageMap }
                    '2' { Get-SanmoxPveDevicePaths }
                    '3' { Get-SanmoxPveHostDiskView }
                    '4' { New-SanmoxPveStorage }
                    '5' { Remove-SanmoxPveStorage }
                    'B' { break }
                }
            } until ($sub.Substring(0,1).ToUpper() -eq 'B')
        }
        '2' {
            # --- Volumes Submenu ---
            $sub = ''
            do {
                Write-SpectreRule -Title "SANtricity Volumes :floppy_disk: | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Alignment Center -Color Yellow
                $poolNameSafe = $Global:sanConfig.SanPoolName.ToString().Replace('[', '[[').Replace(']', ']]')
                $volumeChoices = @(
                    "1. [Blue]View[/] SANtricity volumes in pool [green]$poolNameSafe[/] :eyes:",
                    "2. [Green]Create[/] SANtricity volume (auto-map to pool) :new_button:",
                    "3. [Purple_2]Remove[/] SANtricity volume (WARNING: Must be unmapped from PVE first) :litter_in_bin_sign:",
                    "4. [Green]Edit[/] SANtricity volume properties (resize :red_triangle_pointed_up: / cache / scan)",
                    "B. Back to [Blue]main menu[/] :house:"
                )
                $sub = Read-SpectreSelection -Title "Pick a [blue]volume task[/]" -Choices $volumeChoices -Color Turquoise2 -PageSize 10 -EnableSearch
                
                switch ($sub.Substring(0, 1).ToUpper()) {
                    '1' { Get-SanmoxVolume }
                    '2' { New-SanmoxVolume }
                    '3' { Remove-SanmoxVolume }
                    '4' { Set-SanmoxVolume }
                    'B' { break }
                }
            } until ($sub.Substring(0,1).ToUpper() -eq 'B')
        }
        '3' { Get-SanmoxHostGroup }
        '4' { Get-SanmoxStoragePoolOverview }
        '5' { Get-SanmoxTargetOverview }
        '6' {
            # --- Performance Submenu ---
            $sub = ''
            do {
                Write-SpectreRule -Title "Performance Tools :bar_chart: | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Alignment Center -Color Yellow
                $perfChoices = @(
                    "1. [Blue]Get[/] system performance snapshot (quick) :chart_increasing:",
                    "2. [Blue]Storage[/] Performance Advisor (longer sample) :compass:",
                    "B. Back to [Blue]main menu[/] :house:"
                )
                $sub = Read-SpectreSelection -Title "Pick a [Blue]performance tool[/]" -Choices $perfChoices -Color Turquoise2 -PageSize 10 -EnableSearch

                switch ($sub.Substring(0, 1).ToUpper()) {
                    '1' { Get-SanmoxSystemPerformanceSnapshot }
                    '2' { Get-SanmoxStoragePerformanceAdvisor }
                    'B' { break }
                }
            } until ($sub.Substring(0,1).ToUpper() -eq 'B')
        }
        '7' { Write-SpectreHost -Message "TODO: Settings / Configuration Module" }
        'Q' { Write-SpectreHost -Message "Exiting Sanmox. Have a great day!" }
    }
} until ($MainMenu -eq 'Q')

