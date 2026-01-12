
function Start-SANtricityTranscript {
    <#
    .SYNOPSIS
    Start a transcript for troubleshooting SANtricity CLI usage.

    .PARAMETER Path
    Optional path for the transcript file. Defaults to the current directory with a timestamped filename.

    .PARAMETER Append
    Append to the file if it already exists (default: true).

    .PARAMETER IncludeInvocationHeader
    Include invocation headers in the transcript (default: true).
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [switch] $Append,
        [switch] $IncludeInvocationHeader
    )

    if ($script:SANtricityTranscriptInfo -and $script:SANtricityTranscriptInfo.Active) {
        Write-Verbose "Transcript already active at $($script:SANtricityTranscriptInfo.Path)"
        return [PSCustomObject]$script:SANtricityTranscriptInfo
    }

    if (-not $Path) {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $Path = Join-Path -Path (Get-Location).Path -ChildPath "santricity_client_${timestamp}.log"
    } elseif (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path -Path (Get-Location).Path -ChildPath $Path
    }

    $Path = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $startParams = @{ LiteralPath = $Path }
    if ($Append.IsPresent) { $startParams['Append'] = $true } else { $startParams['Append'] = $true }
    if ($IncludeInvocationHeader.IsPresent -or -not $PSBoundParameters.ContainsKey('IncludeInvocationHeader')) {
        $startParams['IncludeInvocationHeader'] = $true
    }

    Start-Transcript @startParams | Out-Null

    $info = [ordered]@{ Active = $true ; Path = $Path ; Started = Get-Date }
    $script:SANtricityTranscriptInfo = $info
    return [PSCustomObject]$info
}
