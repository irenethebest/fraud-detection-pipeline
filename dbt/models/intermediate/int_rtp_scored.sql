-- Intermediate (gold prep): rule-based fraud risk score for RTP (instant payments).
--
-- RTP is irreversible and settles in seconds, so fraud is account-takeover cash-out:
-- a taken-over account pushes funds to a NEW recipient, frequently at odd overnight
-- hours when the real customer is asleep. See int_ach_scored.sql for the philosophy.
with rtp as (
    select * from {{ ref('stg_rtp') }}
)

select
    transaction_id,
    rail_type,
    partner_bank_id,
    originator_account_id,
    beneficiary_account_id          as counterparty_id,
    amount,
    currency,
    txn_timestamp,
    is_new_recipient                as is_new_counterparty,
    is_fraud,
    fraud_type,

    -- red-flag rules
    (is_new_recipient)                                          as flag_new_recipient,
    (hour_of_day < 6 or hour_of_day >= 23)                     as flag_overnight,

    least(100,
          iff(is_new_recipient, 55, 0)                              -- new payee on instant rail
        + iff(hour_of_day < 6 or hour_of_day >= 23, 30, 0)         -- overnight cash-out window
    )                               as risk_score
from rtp
