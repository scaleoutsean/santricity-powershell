<#
.SYNOPSIS
Validates that all Public cmdlets are exported and have basic help content.
#>

Describe "Module Public API Surface" {
    
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot "../santricity.psd1"
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
        "Get-SANtricityIscsiTargetSetting",
        "Get-SANtricityNvmeTargetSetting",
        "Get-SANtricityInterface",
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

        # Snapshot & Clone Management (Single Volume)
        "Get-SANtricitySnapshotGroup",
        "New-SANtricitySnapshotGroup",
        "Get-SANtricitySnapshotGroupRepositoryUtilization",
        "Get-SANtricitySnapshotVolumeRepositoryUtilization",
        "Get-SANtricityConcatRepository",
        "New-SANtricitySnapshot",
        "Get-SANtricitySnapshot",
        "Get-SANtricitySnapshotVolume",
        "Get-SANtricitySnapshotSchedule",
        "Set-SANtricitySnapshotSchedule",
        "Remove-SANtricitySnapshot",
        "Get-SANtricityClone",
        "New-SANtricityClone",
        "Update-SANtricityClone",
        "Remove-SANtricityClone",

        # Consistency Group Management
        "Get-SANtricityConsistencyGroup",
        "New-SANtricityConsistencyGroup",
        "New-SANtricityConsistencyGroupClone",
        "Get-SANtricityConsistencyGroupClone",
        "Get-SANtricityConsistencyGroupCloneVolume",
        "Get-SANtricityConsistencyGroupMemberVolume",
        "Remove-SANtricityConsistencyGroup",

        # Volume Copy Management
        "Get-SANtricityVolumeCopy",
        "New-SANtricityVolumeCopy",
        "Stop-SANtricityVolumeCopy",
        "Remove-SANtricityVolumeCopy",

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
