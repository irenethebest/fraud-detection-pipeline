-- ============================================================================
-- 03_stage_and_format.sql  --  File format + external stage over S3 bronze/
-- Run as ACCOUNTADMIN AFTER the IAM role trust policy has the DESC values.
-- ============================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE FRAUD_DB;
USE SCHEMA   BRONZE;

-- CSVs have a header row; PARSE_HEADER lets us load by column NAME (order-proof).
CREATE FILE FORMAT IF NOT EXISTS FF_CSV
    TYPE = 'CSV'
    PARSE_HEADER = TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL')
    EMPTY_FIELD_AS_NULL = TRUE
    TRIM_SPACE = TRUE;

-- External stage = a pointer to the S3 bronze/ prefix, using the secure integration.
CREATE STAGE IF NOT EXISTS BRONZE_STAGE
    STORAGE_INTEGRATION = S3_FRAUD_INT
    URL = 's3://<S3_BUCKET>/bronze/'
    FILE_FORMAT = FF_CSV;

-- Sanity check: this should list your CSVs. If it errors, the IAM trust isn't
-- wired up yet -- recheck the trust policy values from DESC INTEGRATION.
LIST @BRONZE_STAGE;
