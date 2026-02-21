<#
.SYNOPSIS
    Example script demonstrating automated Volume Copy with progress monitoring and Webhook notification.

.DESCRIPTION
    This script performs the following actions:
    1. Connects to a SANtricity array.
    2. Identifies a Source and Target volume (by name).
    3. Initiates a Volume Copy (Full Physical Copy).
    4. Monitors the copy progress in a loop.
    5. Sends a Webhook notification (e.g., to Slack, Discord, or Teams) upon completion.

.NOTES
    Adjust the $WebhookUrl and volume names before running.
#>

# Configuration
$ControllerUrl = "https://192.168.1.100:8443"
$User          = "admin"
$Pass          = "admin"
$SourceVolName = "Production_DB_Data"
$TargetVolName = "DevTest_DB_Data"
$WebhookUrl    = "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX"

# 1. Connect
Write-Host "Connecting to array..." -ForegroundColor Cyan
Connect-SANtricity -Url $ControllerUrl -User $User -Password $Pass -IgnoreCertErrors

# 2. Get Volume IDs
Write-Host "Resolving volumes..." -ForegroundColor Cyan
$srcVol = Get-SANtricityVolumes | Where-Object Name -eq $SourceVolName
$dstVol = Get-SANtricityVolumes | Where-Object Name -eq $TargetVolName

if (-not $srcVol -or -not $dstVol) {
    Write-Error "Could not find source or target volume."
    exit
}

# 3. Start Volume Copy
Write-Host "Starting Volume Copy from '$SourceVolName' to '$TargetVolName'..." -ForegroundColor Green
# Using -OnlineCopy to keep source available/writable during copy
# Using -RepositoryPercentage 5 to override default 20% if we want to save space
New-SANtricityVolumeCopy -SourceVolumeId $srcVol.id -TargetVolumeId $dstVol.id -CopyPriority Priority3 -OnlineCopy -RepositoryPercentage 5

# 4. Monitor Progress
Write-Host "Monitoring copy progress..." -ForegroundColor Yellow
$jobId = $null

do {
    Start-Sleep -Seconds 10
    
    # Retrieve active copy jobs with progress
    $jobs = Get-SANtricityVolumeCopy -Progress
    
    # Filter for our specific pair
    $ourJob = $jobs | Where-Object { $_.volcopyRef -eq $dstVol.id -or $_.targetVolume -eq $dstVol.id } 

    if ($ourJob) {
        $pct = $ourJob.percentComplete
        $timeLeft = $ourJob.timeToCompletion
        Write-Host "Copy Progress: $pct% (Time Remaining: $timeLeft min)" -NoNewline -ForegroundColor Gray
        Write-Host "`r" -NoNewline
        
        $jobId = $ourJob.volumeCopyId # Capture for reference
        
        # Check if complete (API might return 100% or remove the job when done)
        if ($pct -eq 100) { break }
    }
    else {
        # Job not found usually means it finished or hasn't started yet.
        # If we saw it before, it's finished.
        if ($jobId) {
            Write-Host "`nJob no longer reported active. Assuming completion." -ForegroundColor Green
            break
        }
    }

} while ($true)

# 5. Send Webhook Notification
Write-Host "Copy Complete. Sending Webhook..." -ForegroundColor Cyan
$payload = @{
    text = "Volume Copy Complete: $SourceVolName -> $TargetVolName"
    blocks = @(
        @{
            type = "section"
            text = @{
                type = "mrkdwn"
                text = "*Volume Copy Finished*`nSource: $SourceVolName`nTarget: $TargetVolName`nArray: $ControllerUrl"
            }
        }
    )
}

try {
    Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body ($payload | ConvertTo-Json -Depth 4) -ContentType 'application/json'
    Write-Host "Webhook sent successfully." -ForegroundColor Green
}
catch {
    Write-Warning "Failed to send webhook: $_"
}

# Optional: Add downstream logic here (e.g. Mount DB, Start Services)
# Insert-Your-Code-Here
