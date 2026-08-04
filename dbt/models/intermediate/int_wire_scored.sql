-- Intermediate (gold prep): rule-based fraud risk score for WIRE.
--
-- Wire fraud here is Business Email Compromise / Authorized Push Payment (APP):
-- the victim is tricked into sending a wire to a NEW beneficiary, usually flagged
-- URGENT, often INTERNATIONAL, and for an amount far above their normal activity.
-- See int_ach_scored.sql for the scoring philosophy (observable signals only).
with wire as (
    select * from {{ ref('stg_wire') }}
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
    is_new_beneficiary              as is_new_counterparty,
    is_fraud,
    fraud_type,

    -- red-flag rules
    (is_new_beneficiary and urgency_flag)                       as flag_new_benef_urgent,
    (wire_type = 'international')                               as flag_international,
    (coalesce(amount_vs_avg_ratio, 1) > 3)                      as flag_amount_spike,
    (coalesce(beneficiary_account_age_days, 999) < 30)         as flag_young_beneficiary,

    least(100,
          iff(is_new_beneficiary and urgency_flag, 40, 0)            -- classic BEC pattern
        + iff(wire_type = 'international', 20, 0)                    -- cross-border
        + iff(coalesce(amount_vs_avg_ratio, 1) > 3, 20, 0)          -- unusually large
        + iff(coalesce(beneficiary_account_age_days, 999) < 30, 20, 0)
    )                               as risk_score
from wire
