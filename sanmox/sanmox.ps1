#!/usr/bin/env pwsh
# -*- coding: utf-8 -*-

# Sanmox is used to configure SANtricity for use with Proxmox VE.
# It sets up SANtricity host groups, volumes, and manages PVE mapping.
#
# License: MIT
# Copyright (c) 2026

param(
    [Parameter(Mandatory = $false)]
    [string]$Config
)

# --- Configuration Loading ---
$scriptDir = if ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { Get-Location }
$defaultConfigFile = Join-Path -Path $scriptDir -ChildPath "sanconfig.json"
$configFile = if ([string]::IsNullOrWhiteSpace($Config)) {
    $defaultConfigFile
} else {
    [System.IO.Path]::GetFullPath($Config)
}
$credFile = Join-Path -Path $HOME -ChildPath ".sanmox_cred.xml"
$pveCredFile = Join-Path -Path $HOME -ChildPath ".sanmox_pve_cred.xml"

if (-not [string]::IsNullOrWhiteSpace($Config)) {
    Write-Host "Using config file: $configFile" -ForegroundColor Cyan
}

if (Test-Path -Path $configFile) {
    $Global:sanConfig = Get-Content -Path $configFile -Raw | ConvertFrom-Json
} else {
    Write-Host "Configuration file not found at $configFile. Creating a default one." -ForegroundColor Yellow
    $defaultConfig = @{
        SanApiUri = "https://192.168.1.100:8443"
        SanUser = "rw"
        SanPoolName = "DDP1" # Pin to a primary Storage Pool by default
        SanHostGroupName = @("pve-cluster-1") # Pin to a specific Host Group array
        PveApiUri = "https://192.168.1.194:8006"
        PveUser = "root@pam"
    }
    $Global:sanConfig = $defaultConfig | ConvertTo-Json
    $Global:sanConfig | Set-Content -Path $configFile
    $Global:sanConfig = $defaultConfig
}

# --- Spectre/Dependencies Setup ---
$modules = @('PwshSpectreConsole')
foreach ($module in $modules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Module $module is not installed. You may need to run: Install-Module -Name $module" -ForegroundColor Red
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

# --- Module Loader ---
$sanmoxModules = @('SanmoxConnect', 'SanmoxPve', 'SanmoxVolume', 'SanmoxHostGroup', 'SanmoxToolbox', 'SanmoxStoragePool', 'SanmoxTargetOverview')
foreach ($sanmod in $sanmoxModules) {
    $modulePath = Join-Path -Path $scriptDir -ChildPath "${sanmod}.psm1"
    if (Test-Path -Path $modulePath) {
        Import-Module -Name $modulePath -Force -ErrorAction Stop
    } else {
        Write-Host "Sanmox module not found: ${sanmod}.psm1" -ForegroundColor Yellow
    }
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

if (-not $Global:pvePass -and -not [string]::IsNullOrWhiteSpace($Global:sanConfig.PveApiUri)) {
    $plainPvePass = Read-Host -AsSecureString "Please enter password/secret for PVE user '$($Global:sanConfig.PveUser)' (input hidden)"
    $Global:pvePass = $plainPvePass
    
    $savePvePass = Read-Host "Do you want to save this PVE password securely for future sessions? (Y/n)"
    if ($savePvePass -notmatch '^[Nn]$') {
        $Global:pvePass | Export-Clixml -Path $pveCredFile
        Write-Host "PVE Credentials saved to $pveCredFile" -ForegroundColor Green
    }
}

# --- Connect ---
Connect-SanmoxEnvironment

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
        "6. First-time setup / Config :gear:",
        "Q. Quit :stop_sign:"
    )
    $MainMenu = Read-SpectreSelection -Title "Select a [Blue]task[/] using :up_down_arrow: or search" -Choices $mainChoices -Color Turquoise2 -PageSize 10 -EnableSearch

    if ($MainMenu -match '^[1-6qQ]\.?') {
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
                    "2. [Blue]View[/] Configured Host Group Disk Identifiers & Paths :eyes:",
                    "3. [Green]Create[/] new [orange3]PVE[/] datastore (iSCSI or NVMe-backed LVM) :new_button:",
                    "4. [Purple_2]Remove[/] [orange3]PVE[/] datastore (WARNING: Datastore must be empty) :litter_in_bin_sign:",
                    "B. Back to [Blue]main menu[/] :house:"
                )
                $sub = Read-SpectreSelection -Title "Pick a [Blue]tool[/]" -Choices $toolboxChoices -Color Turquoise2 -PageSize 10 -EnableSearch
                
                switch ($sub.Substring(0, 1).ToUpper()) {
                    '1' { Get-SanmoxStorageMap }
                    '2' { Get-SanmoxPveDevicePaths }
                    '3' { New-SanmoxPveStorage }
                    '4' { Remove-SanmoxPveStorage }
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
        '6' { Write-SpectreHost -Message "TODO: Settings / Configuration Module" }
        'Q' { Write-SpectreHost -Message "Exiting Sanmox. Have a great day!" }
    }
} until ($MainMenu -eq 'Q')
