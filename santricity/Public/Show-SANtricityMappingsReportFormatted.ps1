
function Show-SANtricityMappingsReportFormatted {
    [CmdletBinding()]
    param()

    $report = Get-SANtricityMappingsReport
    <#
    .SYNOPSIS
    Display a formatted mappings report in the console.

    .DESCRIPTION
    Uses the optional PowerShellRich module to render a rich table when available,
    otherwise falls back to `Format-Table`.

    .EXAMPLE
    Show-SANtricityMappingsReportFormatted
    #>

    if ($report.Count -eq 0) {
        if (Get-Module -Name PowerShellRich) {
            Write-Rich "No mappings found."
        } else {
            Write-Output "No mappings found."
        }
        return
    }

    $cols = @('mappingRef','mappableObjectName','capacity','poolName','poolFreeSpace','targetLabel')
    $rows = foreach ($r in $report) {
        @(
            ($r.mappingRef -as [string]),
            ($r.mappableObjectName -as [string]),
            ($r.capacity -as [string]),
            ($r.poolName -as [string]),
            ($r.poolFreeSpace -as [string]),
            ($r.targetLabel -as [string])
        )
    }

    if (Get-Module -Name PowerShellRich) {
        $table = New-RichTable -Columns $cols -Rows $rows -Title 'SANtricity Mappings' -HeaderStyle 'bold cyan' -BorderStyle 'dim white'
        Write-Rich $table
    } else {
        $report | Format-Table -Property $cols -AutoSize
    }
}
