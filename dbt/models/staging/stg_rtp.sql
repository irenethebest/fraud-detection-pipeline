-- Silver: cleaned instant (RTP) transactions.
with source as (
    select * from {{ source('bronze', 'rtp_transactions') }}
)

select
    transaction_id,
    rail_type,
    partner_bank_id,
    originator_account_id,
    beneficiary_account_id,
    amount,
    currency,
    "TIMESTAMP"             as txn_timestamp,
    device_id,
    ip_address,
    is_new_recipient,
    hour_of_day,
    (is_fraud = 1)          as is_fraud,
    fraud_type
from source
