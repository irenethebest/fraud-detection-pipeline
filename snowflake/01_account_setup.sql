-- ============================================================================
-- 01_account_setup.sql  --  Warehouse, database, schema
-- Run first, in a Snowsight worksheet, as ACCOUNTADMIN.
-- ============================================================================
USE ROLE ACCOUNTADMIN;

-- X-Small warehouse. AUTO_SUSPEND keeps trial credits from draining while idle.
CREATE WAREHOUSE IF NOT EXISTS FRAUD_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60          -- suspend after 60s idle
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS FRAUD_DB;
CREATE SCHEMA   IF NOT EXISTS FRAUD_DB.BRONZE;   -- raw landing, mirrors S3 bronze/

USE WAREHOUSE FRAUD_WH;
USE DATABASE  FRAUD_DB;
USE SCHEMA    BRONZE;
