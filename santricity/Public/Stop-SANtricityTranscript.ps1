
function Stop-SANtricityTranscript {
    <#
    .SYNOPSIS
    Stop an active SANtricity transcript if one is running.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:SANtricityTranscriptInfo -or -not $script:SANtricityTranscriptInfo.Active) {
        Write-Verbose 'No SANtricity transcript is currently active.'
        return $false
    }

    try {
        Stop-Transcript | Out-Null
        $script:SANtricityTranscriptInfo = $null
        return $true
    } catch {
        Write-Warning "Failed to stop transcript: $($_.Exception.Message)"
        return $false
    }
}
