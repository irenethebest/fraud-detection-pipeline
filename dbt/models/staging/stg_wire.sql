-- Silver: cleaned wire transactions.
with source as (
    select * from {{ source('bronze', 'wire_transactions') }}
)

select
    transaction_id,
    rail_type,
    partner_bank_id,
    originator_account_id,
    beneficiary_account_id,
    beneficiary_bank_swift,
    amount,
    currency,
    "TIMESTAMP"                     as txn_timestamp,
    wire_type,                                   -- domestic / international
    is_new_beneficiary,
    urgency_flag,
    amount_vs_avg_ratio,
    beneficiary_account_age_days,
    (is_fraud = 1)                  as is_fraud,
    fraud_type
from source
