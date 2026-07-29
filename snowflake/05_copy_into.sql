-- ============================================================================
-- 05_copy_into.sql  --  Load S3 bronze CSVs into the bronze tables
-- MATCH_BY_COLUMN_NAME loads by header name, so column order can't bite us.
-- Re-runnable: COPY skips files it has already loaded (load metadata per stage).
-- ============================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FRAUD_WH;
USE DATABASE  FRAUD_DB;
USE SCHEMA    BRONZE;

COPY INTO ACH_TRANSACTIONS
    FROM @BRONZE_STAGE/ach/
    FILE_FORMAT = (FORMAT_NAME = FF_CSV)
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    ON_ERROR = 'CONTINUE';

COPY INTO WIRE_TRANSACTIONS
    FROM @BRONZE_STAGE/wire/
    FILE_FORMAT = (FORMAT_NAME = FF_CSV)
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    ON_ERROR = 'CONTINUE';

COPY INTO RTP_TRANSACTIONS
    FROM @BRONZE_STAGE/rtp/
    FILE_FORMAT = (FORMAT_NAME = FF_CSV)
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    ON_ERROR = 'CONTINUE';

COPY INTO CARD_TRANSACTIONS
    FROM @BRONZE_STAGE/card/
    FILE_FORMAT = (FORMAT_NAME = FF_CSV)
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    ON_ERROR = 'CONTINUE';

-- ---- Validation: row counts + fraud rate should mirror the generator (~2%) ----
SELECT 'ACH'  AS rail, COUNT(*) AS row_count, SUM(is_fraud) AS fraud FROM ACH_TRANSACTIONS
UNION ALL SELECT 'WIRE', COUNT(*), SUM(is_fraud) FROM WIRE_TRANSACTIONS
UNION ALL SELECT 'RTP',  COUNT(*), SUM(is_fraud) FROM RTP_TRANSACTIONS
UNION ALL SELECT 'CARD', COUNT(*), SUM(is_fraud) FROM CARD_TRANSACTIONS;

-- Spot-check ACH direction + return codes came through correctly:
SELECT direction, return_code, COUNT(*)
FROM ACH_TRANSACTIONS
WHERE is_fraud = 1
GROUP BY 1, 2
ORDER BY 1, 2;
