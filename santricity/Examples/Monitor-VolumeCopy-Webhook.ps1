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
    You should first understand Volume Copy https://docs.netapp.com/us-en/e-series-cli/commands-a-z/create-volumecopy.html#context.    
    Adjust the $WebhookUrl and volume names before running. 
    Get-SANtricityVolumeCopy -Progress is used to retrieve real-time progress updates.
    
#>

# Configuration
$ControllerUrl = "https://192.168.1.100:8443"
$User          = "admin"
$Pass          = "" # error: GH013: Repository rule violations found for refs/heads/master (sigh...)
$SourceVolName = "Production_DB_Data"
$TargetVolName = "DevTest_DB_Data"
$WebhookUrl    = "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX"

# 1. Connect
Write-Host "Connecting to array..." -ForegroundColor Cyan
Connect-SANtricity -BaseUrl $ControllerUrl -User $User -Password $Pass -SkipCertificateCheck

# 2. Get Volume IDs
Write-Host "Resolving volumes..." -ForegroundColor Cyan
$srcVol = Get-SANtricityVolume | Where-Object Name -eq $SourceVolName
$dstVol = Get-SANtricityVolume | Where-Object Name -eq $TargetVolName

if (-not $srcVol -or -not $dstVol) {
    Write-Error "Could not find source or target volume."
    exit
}

# 3. Start Volume Copy
Write-Host "Starting Volume Copy from '$SourceVolName' to '$TargetVolName'..." -ForegroundColor Green
# Using -OnlineCopy to keep source available/writable during copy
# Using -RepositoryPercentage 5 to override default 20% if we want to save space
$job = New-SANtricityVolumeCopy -SourceVolumeId $srcVol.id -TargetVolumeId $dstVol.id -CopyPriority Priority3 -OnlineCopy -RepositoryPercentage 5

if (-not $job.volcopyRef) {
    Write-Error "Failed to start copy job or parse response."
    return
}
$copyJobId = $job.volcopyRef
Write-Host "Copy Job Started. ID: $copyJobId" -ForegroundColor Cyan

# 4. Monitor Progress
Write-Host "Monitoring copy progress..." -ForegroundColor Yellow

do {
    Start-Sleep -Seconds 5
    
    # Check PRIMARY STATUS from persistent endpoint first
    try {
        $statusJob = Get-SANtricityVolumeCopy -VolumeCopyId $copyJobId -ErrorAction Stop
        
        if ($statusJob.status -eq 'complete') {
            Write-Host "`nCopy Job Complete (Status: $($statusJob.status))" -ForegroundColor Green
            break
        }
        
        if ($statusJob.status -eq 'failed' -or $statusJob.status -eq 'halted') {
            Write-Error "`nCopy Job Failed or Halted! Status: $($statusJob.status)"
            return
        }
    } catch {
        # If specific ID fetch fails, it might be truly gone or network glitch.
        Write-Warning "Could not retrieve job status. Retrying..."
        continue
    }

    # Retrieve PROGRESS from control endpoint (transient)
    # Use generic list because transient jobs might disappear from list
    $progressJobs = Get-SANtricityVolumeCopy -Progress
    $ourProgress = $progressJobs | Where-Object { $_.volumeCopyId -eq $copyJobId } 

    if ($ourProgress) {
        $pct = $ourProgress.percentComplete
        $timeLeft = $ourProgress.timeToCompletion
        
        # Check for the misleading "-1" percentComplete which can indicate done/starting
        if ($pct -eq -1) { $pct = "Pending/Done" }
        
        Write-Host "Copy Progress: $pct% (Time Remaining: $timeLeft min)   " -NoNewline -ForegroundColor Gray
        Write-Host "`r" -NoNewline
    }
} while ($true)

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
