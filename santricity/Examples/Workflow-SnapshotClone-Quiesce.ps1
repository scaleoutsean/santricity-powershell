<#
.SYNOPSIS
    Example script demonstrating automated Snapshot Volume (Linked Clone) creation with database quiescing and Webhook notification.

.DESCRIPTION
    This script performs a typical DevTest refresh workflow:
    1. Quiesces a database (mock command).
    2. Takes a storage snapshot (Point-in-Time).
    3. Unquiesces the database immediately.
    4. Creates a writable linked clone (Snapshot Volume) from that snapshot.
    5. Maps the clone to a test host.
    6. Sends a Webhook notification with details.

.NOTES
    This workflow is much faster than Volume Copy because it uses copy-on-write pointers (Linked Clone).
    Ideal for CI/CD pipelines or nightly refresh of dev environments.
#>

# Configuration
$ControllerUrl    = "https://192.168.1.100:8443"
$Creds            = Get-Credential # Prompt for credentials securely
$SourceVolName    = "Production_SQL_Data"
$CloneName        = "Dev_SQL_Clone"
$TestHostName     = "WinServer-Dev-01"
$WebhookUrl       = "https://hooks.slack.com/services/..."

# Helper to send Webhooks
function Send-SlackNotification ($Message) {
    if (-not $WebhookUrl) { return }
    $payload = @{ text = $Message }
    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body ($payload | ConvertTo-Json) -ContentType 'application/json'
    } catch { Write-Warning "Webhook failed: $_" }
}

# 1. Connect
Connect-SANtricity -Url $ControllerUrl -Credential $Creds -IgnoreCertErrors

# 2. Identify Resources
$srcVol = Get-SANtricityVolumes | Where-Object Name -eq $SourceVolName
$hostMatch = Get-SANtricityHosts | Where-Object Name -eq $TestHostName

if (-not $srcVol) { Throw "Source volume '$SourceVolName' not found." }
if (-not $hostMatch) { Throw "Test host '$TestHostName' not found." }

# 3. Application Quiesce (Mock)
Write-Host "Freezing SQL I/O..." -ForegroundColor Yellow
# Invoke-SqlCmd -Query "ALTER DATABASE [MyDb] SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON" ...
Start-Sleep -Seconds 2 # Simulating brief freeze

try {
    # 4. Take Snapshot (Instant)
    Write-Host "Creating Snapshot..." -ForegroundColor Cyan
    # Snapshot Images are timestamp-based and do not have user-assignable names at creation.
    # We use the BaseVolumeId to target the correct group.
    $snap = New-SANtricitySnapshot -BaseVolumeId $srcVol.id -Force

    Write-Host "Snapshot Created. ID: $($snap.id)" -ForegroundColor Green

} finally {
    # 5. Application Unquiesce (Always run this!)
    Write-Host "Thawing SQL I/O..." -ForegroundColor Yellow
    # Invoke-SqlCmd -Query "ALTER DATABASE [MyDb] SET SUSPEND_FOR_SNAPSHOT_BACKUP = OFF" ...
}

# 6. Create Linked Clone (Snapshot Volume)
Write-Host "Creating Writable Clone '$CloneName'..." -ForegroundColor Cyan
# Linked clones are instant. 
# We request ReadWrite access so Devs can modify it without affecting Produciton.
# Note: $snap.id is the snapshot image reference.
$clone = New-SANtricityClone -SnapshotImageId $snap.id -Name $CloneName -AccessMode ReadWrite

if ($clone) {
    Write-Host "Clone Created: $($clone.wwn)" -ForegroundColor Green

    # 7. Map to Test Host
    Write-Host "Mapping '$CloneName' to host '$TestHostName'..."
    New-SANtricityVolumeMapping -VolumeId $clone.id -TargetId $hostMatch.id
    
    # 8. Notify Team
    $msg = ":white_check_mark: *Dev Environment Refreshed!*`n`nNew clone `$CloneName` is mapped to `$TestHostName` based on snapshot ID `$($snap.id)`."
    Send-SlackNotification -Message $msg
} else {
    Write-Error "Failed to create clone."
    Send-SlackNotification -Message ":x: *Clone Creation Failed* for `$SourceVolName`."
}
