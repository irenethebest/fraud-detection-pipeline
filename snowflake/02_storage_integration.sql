-- ============================================================================
-- 02_storage_integration.sql  --  Secure S3 <-> Snowflake trust (no keys stored)
-- Run as ACCOUNTADMIN, AFTER you've created the AWS IAM role (see snowflake/aws/).
--
-- Flow (because AWS and Snowflake each need a value from the other):
--   1. AWS: create IAM policy + role (trusting your own account for now). Copy the ROLE ARN.
--   2. Here: paste the ROLE ARN below, run CREATE STORAGE INTEGRATION, then DESC.
--   3. AWS: paste the DESC output (IAM_USER_ARN + EXTERNAL_ID) into the role's trust policy.
-- ============================================================================
USE ROLE ACCOUNTADMIN;

CREATE STORAGE INTEGRATION IF NOT EXISTS S3_FRAUD_INT
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<AWS_ACCOUNT_ID>:role/<SNOWFLAKE_ROLE_NAME>'   -- e.g. arn:aws:iam::123456789012:role/snowflake-fraud-role
    STORAGE_ALLOWED_LOCATIONS = ('s3://<S3_BUCKET>/bronze/');

-- Run this, then copy the two highlighted property values back into the AWS
-- IAM role's trust policy (snowflake/aws/iam_role_trust_policy.json):
--     STORAGE_AWS_IAM_USER_ARN   -> the "Principal.AWS" value
--     STORAGE_AWS_EXTERNAL_ID    -> the "sts:ExternalId" value
DESC INTEGRATION S3_FRAUD_INT;
