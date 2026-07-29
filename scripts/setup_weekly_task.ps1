# =============================================================================
# setup_weekly_task.ps1  --  Register the weekly data-refresh in Task Scheduler
#
# Run this ONCE to schedule refresh_data.ps1 to run every week automatically.
# From the Claude Code prompt:
#     !powershell -NoProfile -ExecutionPolicy Bypass -File setup_weekly_task.ps1
#
# To change the day/time, edit $DayOfWeek / $At below and re-run.
# To remove it later:
#     Unregister-ScheduledTask -TaskName "FraudPipeline-WeeklyRefresh" -Confirm:$false
# =============================================================================

$TaskName   = "FraudPipeline-WeeklyRefresh"
$ProjectDir = "C:\Users\Irene\Claude\Projects\Code_fraud_usecase"
$Script     = Join-Path $ProjectDir "scripts\refresh_data.ps1"
$DayOfWeek  = "Sunday"     # when the weekly run fires
$At         = "9:00AM"

# The action: run refresh_data.ps1 with PowerShell, no profile, bypassing policy.
$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Script`"" `
    -WorkingDirectory $ProjectDir

# The trigger: weekly, on the chosen day/time.
$Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $At

# If the machine was off/asleep at the scheduled time, run as soon as it can.
$Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun

# Runs as the current user, only when logged on (no stored password needed).
Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -Description "Weekly regenerate synthetic multi-rail transactions and upload bronze/ to S3." `
    -Force

Write-Host ""
Write-Host "Registered scheduled task '$TaskName': every $DayOfWeek at $At."
Write-Host "Verify:  Get-ScheduledTask -TaskName '$TaskName'"
Write-Host "Run now: Start-ScheduledTask -TaskName '$TaskName'"
