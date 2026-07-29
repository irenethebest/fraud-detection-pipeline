# =============================================================================
# config.example.ps1  --  Template for environment-specific settings.
#
# SETUP: copy this file to `config.local.ps1` (same folder) and fill in your
# values. `config.local.ps1` is git-ignored, so your real bucket never gets
# committed. refresh_data.ps1 loads it automatically.
#
#     Copy-Item scripts/config.example.ps1 scripts/config.local.ps1
# =============================================================================

# Destination S3 prefix for the bronze layer (include the trailing slash).
$S3_BUCKET = "s3://<your-bucket>/bronze/"
