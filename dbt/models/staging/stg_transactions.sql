-- Silver keystone: all four rails standardized into ONE common schema.
-- This is the model that lets you analyze fraud across rails on equal footing.
-- Rail-specific columns stay in their per-rail staging models; here we keep only
-- the fields every rail shares, mapping each rail's "counterparty" and
-- "new-counterparty" signal onto common column names.
with ach as (
    select
        transaction_id, rail_type, partner_bank_id, originator_account_id,
        beneficiary_account_id           as counterparty_id,
        amount, currency, txn_timestamp,
        is_new_payee                     as is_new_counterparty,
        is_fraud, fraud_type
    from {{ ref('stg_ach') }}
),

wire as (
    select
        transaction_id, rail_type, partner_bank_id, originator_account_id,
        beneficiary_account_id           as counterparty_id,
        amount, currency, txn_timestamp,
        is_new_beneficiary               as is_new_counterparty,
        is_fraud, fraud_type
    from {{ ref('stg_wire') }}
),

rtp as (
    select
        transaction_id, rail_type, partner_bank_id, originator_account_id,
        beneficiary_account_id           as counterparty_id,
        amount, currency, txn_timestamp,
        is_new_recipient                 as is_new_counterparty,
        is_fraud, fraud_type
    from {{ ref('stg_rtp') }}
),

card as (
    select
        transaction_id, rail_type, partner_bank_id, originator_account_id,
        merchant_id                      as counterparty_id,   -- card's "counterparty" is the merchant
        amount, currency, txn_timestamp,
        null::boolean                    as is_new_counterparty, -- no direct equivalent for cards
        is_fraud, fraud_type
    from {{ ref('stg_card') }}
)

select * from ach
union all select * from wire
union all select * from rtp
union all select * from card
