<#
.SYNOPSIS
Deletes a SANtricity Host.

.DESCRIPTION
Removes a Host definition from the storage array.
Validates dependencies (Mappings) before deletion.

.PARAMETER HostId
The ID (Ref) of the Host to remove.

.PARAMETER HostName
The name of the Host to remove.

.PARAMETER Force
Deletes the Host even if it has active mappings.

.EXAMPLE
Remove-SANtricityHost -HostName "ESX-01"
#>
function Remove-SANtricityHost {
    [CmdletBinding(DefaultParameterSetName="ById", SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory=$true, ParameterSetName="ById", Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias("id", "HostRef")]
        [string]$HostId,

        [Parameter(Mandatory=$true, ParameterSetName="ByName")]
        [string]$HostName,

        [switch]$Force
    )

    process {
        # 1. Resolve Host
        if ($PSCmdlet.ParameterSetName -eq "ByName") {
            Write-Verbose "Resolving Host Name '$HostName'..."
            $hosts = Get-SANtricityHost
            $matched = $hosts | Where-Object { $_.name -eq $HostName -or $_.label -eq $HostName }
            
            if (-not $matched) { throw "Host '$HostName' not found." }
            if ($matched -is [array]) {
                 $exact = $matched | Where-Object { $_.name -eq $HostName }
                 if ($exact -and $exact.Count -eq 1) { $matched = $exact }
                 else { throw "Multiple hosts matched '$HostName'. Please use HostId." }
            }
            $HostId = $matched.id
        }

        # 2. Check for dependencies (Mappings)
        Write-Verbose "Checking for active mappings on Host '$HostId'..."
        $allMappings = Get-SANtricityVolumeMapping
        
        # Check if any mapping targets this specific host
        # API field is 'mapRef' (HostRef) and 'type'='host'
        $activeMappings = $allMappings | Where-Object { ($_.mapRef -eq $HostId -or $_.targetId -eq $HostId) }

        if ($activeMappings) {
            $count = if ($activeMappings -is [array]) { $activeMappings.Count } else { 1 }
            if (-not $Force) {
                $msg = "Host '$HostId' has $count active volume mapping(s). Use -Force to delete anyway."
                $ex = [System.InvalidOperationException]::new($msg)
                $CategoryInfo = [System.Management.Automation.ErrorCategory]::ResourceBusy
                $ErrorRecord = [System.Management.Automation.ErrorRecord]::new($ex, "HostIsMapped", $CategoryInfo, $HostId)
                $PSCmdlet.ThrowTerminatingError($ErrorRecord)
            } else {
                Write-Warning "Deleting Host '$HostId' which has $count active mapping(s)."
            }
        }

        # 3. Execution
        if ($PSCmdlet.ShouldProcess("Host $HostId", "Remove-SANtricityHost")) {
             Invoke-SANtricityRequest -Method DELETE -Path "/hosts/$HostId"
        }
    }
}
