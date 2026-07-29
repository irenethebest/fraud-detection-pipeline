-- Silver: cleaned ACH transactions.
-- Bronze types are already correct; here we alias the reserved `timestamp`
-- column and cast the 0/1 is_fraud flag to a proper boolean.
with source as (
    select * from {{ source('bronze', 'ach_transactions') }}
)

select
    transaction_id,
    rail_type,
    partner_bank_id,
    originator_account_id,
    beneficiary_account_id,
    direction,                                  -- debit (pull) / credit (push)
    amount,
    currency,
    "TIMESTAMP"                 as txn_timestamp,
    sec_code,
    return_code,
    is_new_payee,
    originator_account_age_days,
    (is_fraud = 1)              as is_fraud,
    fraud_type
from source
