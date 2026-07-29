-- ============================================================================
-- 04_create_bronze_tables.sql  --  One raw bronze table per rail
-- Columns mirror src/generate_transactions.py exactly. Rails have different
-- shapes on purpose; dbt will standardize them into one model later (silver).
-- ============================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE FRAUD_DB;
USE SCHEMA   BRONZE;

CREATE OR REPLACE TABLE ACH_TRANSACTIONS (
    transaction_id                STRING,
    rail_type                     STRING,
    partner_bank_id               STRING,
    originator_account_id         STRING,
    beneficiary_account_id        STRING,
    direction                     STRING,          -- debit (pull) / credit (push)
    amount                        NUMBER(14,2),
    currency                      STRING,
    timestamp                     TIMESTAMP_NTZ,
    sec_code                      STRING,          -- PPD/CCD/WEB/TEL
    return_code                   STRING,          -- NACHA return code, NULL if settled
    is_new_payee                  BOOLEAN,
    originator_account_age_days   NUMBER,
    is_fraud                      NUMBER(1,0),
    fraud_type                    STRING
);

CREATE OR REPLACE TABLE WIRE_TRANSACTIONS (
    transaction_id                STRING,
    rail_type                     STRING,
    partner_bank_id               STRING,
    originator_account_id         STRING,
    beneficiary_account_id        STRING,
    beneficiary_bank_swift        STRING,
    amount                        NUMBER(14,2),
    currency                      STRING,
    timestamp                     TIMESTAMP_NTZ,
    wire_type                     STRING,          -- domestic / international
    is_new_beneficiary            BOOLEAN,
    urgency_flag                  BOOLEAN,
    amount_vs_avg_ratio           NUMBER(14,2),
    beneficiary_account_age_days  NUMBER,
    is_fraud                      NUMBER(1,0),
    fraud_type                    STRING
);

CREATE OR REPLACE TABLE RTP_TRANSACTIONS (
    transaction_id                STRING,
    rail_type                     STRING,
    partner_bank_id               STRING,
    originator_account_id         STRING,
    beneficiary_account_id        STRING,
    amount                        NUMBER(14,2),
    currency                      STRING,
    timestamp                     TIMESTAMP_NTZ,
    device_id                     STRING,
    ip_address                    STRING,
    is_new_recipient              BOOLEAN,
    hour_of_day                   NUMBER,
    is_fraud                      NUMBER(1,0),
    fraud_type                    STRING
);

CREATE OR REPLACE TABLE CARD_TRANSACTIONS (
    transaction_id                STRING,
    rail_type                     STRING,
    partner_bank_id               STRING,
    originator_account_id         STRING,
    card_id                       STRING,
    merchant_id                   STRING,
    mcc_code                      NUMBER,
    amount                        NUMBER(14,2),
    currency                      STRING,
    timestamp                     TIMESTAMP_NTZ,
    entry_mode                    STRING,          -- chip/swipe/contactless/card_not_present
    is_card_present               BOOLEAN,
    avs_result                    STRING,
    cvv_result                    STRING,
    merchant_country              STRING,
    cardholder_country            STRING,
    is_fraud                      NUMBER(1,0),
    fraud_type                    STRING
);
