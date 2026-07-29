# =============================================================================
# refresh_data.ps1  --  Weekly / manual synthetic-data refresh
#
# Regenerates the multi-rail transactions and uploads the bronze layer to S3.
# One script, two ways to run it:
#
#   MANUAL (anytime):
#       powershell -NoProfile -ExecutionPolicy Bypass -File refresh_data.ps1
#     or from the Claude Code prompt:
#       !powershell -NoProfile -ExecutionPolicy Bypass -File refresh_data.ps1
#
#   SCHEDULED (weekly):
#       registered by setup_weekly_task.ps1 (runs this same script)
#
# Optional overrides:
#       -NumPerRail 5000  -Days 30  -FraudRate 0.02
# =============================================================================

param(
    [int]   $NumPerRail = 5000,
    [int]   $Days       = 30,
    [double]$FraudRate  = 0.02
)

$ErrorActionPreference = "Stop"

# --- Config -----------------------------------------------------------------
# Project root is the parent of this scripts/ folder (portable, no hardcoded path).
$ProjectDir = Split-Path $PSScriptRoot -Parent

# Environment-specific values (your bucket) live in a git-ignored config file so
# they never get committed. Copy config.example.ps1 -> config.local.ps1 and edit it.
$ConfigLocal = Join-Path $PSScriptRoot "config.local.ps1"
if (-not (Test-Path $ConfigLocal)) {
    Write-Host "Missing scripts/config.local.ps1 -- copy scripts/config.example.ps1 to it and set `$S3_BUCKET."
    exit 1
}
. $ConfigLocal
$Bucket = $S3_BUCKET

# Find the AWS CLI whether or not it's on PATH.
$Aws = "aws"
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    $Aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
}

# Fresh but reproducible: seed from ISO year+week, so each weekly run differs
# from the last, yet a given week always regenerates identically.
$Seed = ([int](Get-Date -Year (Get-Date).Year -Format yyyy)) * 100 + [int](Get-Date -UFormat %V)

Set-Location $ProjectDir

# --- Logging ----------------------------------------------------------------
$LogDir = Join-Path $ProjectDir "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir ("refresh_{0}.log" -f (Get-Date -Format "yyyy-MM-dd_HHmmss"))
Start-Transcript -Path $LogFile | Out-Null

$stamp = { Get-Date -Format "yyyy-MM-dd HH:mm:ss" }
Write-Host "[$(&$stamp)] refresh_data starting (seed=$Seed, num=$NumPerRail, days=$Days, fraud=$FraudRate)"

try {
    # 1) Generate synthetic transactions -> ./data (local bronze landing)
    Write-Host "[$(&$stamp)] Generating transactions..."
    python src/generate_transactions.py --num-per-rail $NumPerRail --fraud-rate $FraudRate --days $Days --seed $Seed
    if ($LASTEXITCODE -ne 0) { throw "src/generate_transactions.py failed (exit $LASTEXITCODE)" }

    # 2) Upload the bronze layer to S3. --delete makes S3 mirror local exactly,
    #    removing any orphaned date-files so downstream loads don't over-count.
    Write-Host "[$(&$stamp)] Uploading bronze/ to $Bucket ..."
    & $Aws s3 sync ./data/bronze/ $Bucket --delete
    if ($LASTEXITCODE -ne 0) { throw "aws s3 sync failed (exit $LASTEXITCODE)" }

    Write-Host "[$(&$stamp)] DONE. Data regenerated and uploaded to S3."
}
catch {
    Write-Host "[$(&$stamp)] ERROR: $_"
    Stop-Transcript | Out-Null
    exit 1
}

Stop-Transcript | Out-Null
