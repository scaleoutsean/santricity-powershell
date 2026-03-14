<#
.SYNOPSIS
    Example script demonstrating automated Snapshot Volume (Linked Clone) creation with database quiescing and Webhook notification.

.DESCRIPTION
    This script performs a typical DevTest refresh workflow:
    1. Quiesces a PostgreSQL database (backup mode).
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
$Creds            = Get-Credential -Message "SANtricity Admin Credentials"
$PgCreds          = Get-Credential -Message "PostgreSQL User Credentials"
# $PgPass # supply as .pgpass in user's directory or $env:PGPASSWORD environment variable for security
$SourceVolName    = "Production_PG_Data"
$CloneName        = "Dev_PG_Clone"
$TestHostName     = "Linux-Dev-01"
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
Connect-SANtricity -BaseUrl $ControllerUrl -Credential $Creds -SkipCertificateCheck

# 2. Identify Resources
$srcVol = Get-SANtricityVolume | Where-Object Name -eq $SourceVolName
$hostMatch = Get-SANtricityHost | Where-Object Name -eq $TestHostName

if (-not $srcVol) { Throw "Source volume '$SourceVolName' not found." }
if (-not $hostMatch) { Throw "Test host '$TestHostName' not found." }

# 3. Application Quiesce (PostgreSQL Example)
Write-Host "Freezing PostgreSQL I/O..." -ForegroundColor Yellow

# Configuration (Adjust as needed)
$pgUser = $PgCreds.UserName
$env:PGPASSWORD = $PgCreds.GetNetworkCredential().Password
# $pgDb   = "production_db" 
$label  = "santricity_snap_$(Get-Date -Format 'yyyyMMddHHmm')"

try {
    # 3a. Start Backup Mode (PostgreSQL 15+ Syntax)
    # 'pg_backup_start' prepares for physical backup. 'fast=true' forces an immediate checkpoint.
    # For older versions (9.x-14.x), use: SELECT pg_start_backup('$label', true, false);
    
    $cmdStart = "SELECT pg_backup_start('$label', true);"
    
    Write-Verbose "Executing: $cmdStart"
    # psql -U $pgUser -c "$cmdStart"
    
    Write-Host "PostgreSQL is in backup mode (Mock/Commented for safety)." -ForegroundColor Green
    # To enable: Uncomment the psql line above or implement actual call.
    # Verify execution success before proceeding!

} catch {
    Write-Error "Quiesce failed: $_"
    exit 1
}

try {
    # 4. Take Snapshot (Instant)
    Write-Host "Creating Snapshot..." -ForegroundColor Cyan
    # Snapshot Images are timestamp-based and do not have user-assignable names at creation.
    # We use the BaseVolumeId to target the correct group.
    $snap = New-SANtricitySnapshot -BaseVolumeId $srcVol.id -Force

    Write-Host "Snapshot Created. ID: $($snap.id)" -ForegroundColor Green

} finally {
    # 5. Application Unquiesce (Always run this!)
    Write-Host "Unfreezing PostgreSQL I/O..." -ForegroundColor Yellow

    # 5a. Stop Backup Mode (PostgreSQL 15+ Syntax)
    # 'pg_backup_stop' stops the backup mode and writes label file.
    # For older versions, use pg_stop_backup().
    
    $cmdStop = "SELECT pg_backup_stop(true);"
    
    Write-Verbose "Executing cleanup: $cmdStop"
    # psql -U $pgUser -c "$cmdStop"

    Write-Host "PostgreSQL backup mode stopped (Mock/Commented)." -ForegroundColor Green
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
