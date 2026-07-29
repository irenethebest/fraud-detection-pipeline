-- Silver: cleaned card transactions.
with source as (
    select * from {{ source('bronze', 'card_transactions') }}
)

select
    transaction_id,
    rail_type,
    partner_bank_id,
    originator_account_id,
    card_id,
    merchant_id,
    mcc_code,
    amount,
    currency,
    "TIMESTAMP"             as txn_timestamp,
    entry_mode,                                 -- chip / swipe / contactless / card_not_present
    is_card_present,
    avs_result,
    cvv_result,
    merchant_country,
    cardholder_country,
    (is_fraud = 1)          as is_fraud,
    fraud_type
from source
