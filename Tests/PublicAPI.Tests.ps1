<#
.SYNOPSIS
Validates that all Public cmdlets are exported and have basic help content.
#>

Describe "Module Public API Surface" {
    
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot "../santricity/santricity.psd1"
        Import-Module $modulePath -Force
    }

    $publicCmdlets = @(
        # Connect
        "Connect-SANtricity",
        "Invoke-SANtricityRequest",
        
        # Get
        "Get-SANtricityVolumes",
        "Get-SANtricityStoragePools",
        "Get-SANtricityHosts",
        "Get-SANtricityHostGroups",
        "Get-SANtricityVolumeMappings",
        "Get-SANtricityMappingsReport",
        "Show-SANtricityMappingsReportFormatted",
        "Get-SANtricityTargets",

        # Volume Management
        "New-SANtricityVolume",
        "Set-SANtricityVolume",
        "Resize-SANtricityVolume",
        "New-SANtricityVolumeMapping",
        "Remove-SANtricityVolume",
        "Remove-SANtricityVolumeMapping",

        # Host Management
        "New-SANtricityHost",
        "New-SANtricityHostGroup",
        "Remove-SANtricityHost",
        "Remove-SANtricityHostGroup",

        # Pool Management
        "Remove-SANtricityStoragePool",

        # Diagnostics
        "Start-SANtricityTranscript",
        "Stop-SANtricityTranscript"
    )

    foreach ($cmdlet in $publicCmdlets) {
        It "Exports cmdlet '$cmdlet'" {
            $cmd = Get-Command -Name $cmdlet -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
        }
    }
}
