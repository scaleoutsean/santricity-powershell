@{
    RootModule = 'santricity.psm1'
    ModuleVersion = '0.2.0'
    GUID = 'd7f1b7ef-65c1-4a53-9f3c-9a3e9d1b2cb0'
    Author = 'scaleoutSean'
    CompanyName = 'scaleoutSean'
    Copyright = '(c) 2026 scaleoutSean. All rights reserved.'
    Description = 'Simple SANtricity PowerShell helpers for PowerShell 7.'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('*-SANtricity*','Show-SANtricityMappingsReportFormatted')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            ProjectUri = 'https://github.com/scaleoutsean/santricity-powershell'
        }
    }
}
