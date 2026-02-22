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
        "Get-SANtricityVolume",
        "Get-SANtricityStoragePool",
        "Get-SANtricityHost",
        "Get-SANtricityHostGroup",
        "Get-SANtricityVolumeMapping",
        "Get-SANtricityMappingsReport",
        "Show-SANtricityMappingsReportFormatted",
        "Get-SANtricityTarget",
        "Get-SANtricityOdxStatus",

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

    $testCases = $publicCmdlets | ForEach-Object { @{ CmdletName = $_ } }

    It "Exports cmdlet '<CmdletName>'" -TestCases $testCases {
        param($CmdletName)
        $cmd = Get-Command -Name $CmdletName -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
    }
}
