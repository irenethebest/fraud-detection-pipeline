-- Intermediate (gold prep): rule-based fraud risk score for CARD.
--
-- Card fraud here is card-not-present (CNP) testing/fraud: a stolen card number
-- used online (no physical card), so the address (AVS) and security code (CVV)
-- checks fail, and the merchant is often in a different country than the
-- cardholder. See int_ach_scored.sql for the scoring philosophy.
with card as (
    select * from {{ ref('stg_card') }}
)

select
    transaction_id,
    rail_type,
    partner_bank_id,
    originator_account_id,
    merchant_id                     as counterparty_id,   -- card's "counterparty" is the merchant
    amount,
    currency,
    txn_timestamp,
    null::boolean                   as is_new_counterparty, -- no direct equivalent for cards
    is_fraud,
    fraud_type,

    -- red-flag rules
    (entry_mode = 'card_not_present')                          as flag_card_not_present,
    (avs_result = 'mismatch')                                  as flag_avs_mismatch,
    (cvv_result in ('mismatch', 'not_provided'))               as flag_cvv_fail,
    (merchant_country <> cardholder_country)                   as flag_cross_border,

    least(100,
          iff(entry_mode = 'card_not_present', 40, 0)               -- online / no physical card
        + iff(avs_result = 'mismatch', 25, 0)                       -- billing address fails
        + iff(cvv_result in ('mismatch', 'not_provided'), 25, 0)    -- security code fails
        + iff(merchant_country <> cardholder_country, 10, 0)        -- geography mismatch
    )                               as risk_score
from card
