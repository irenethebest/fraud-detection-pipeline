-- Intermediate (gold prep): rule-based fraud risk score for ACH.
--
-- WHY a rule score? A fraud analyst reasons "new payee + a debit pull + a young
-- account = likely unauthorized debit." We encode that judgement as points so
-- every transaction gets an explainable 0-100 risk_score.
--
-- IMPORTANT: the score is built ONLY from signals you could see at (or shortly
-- after) transaction time -- never from `is_fraud`. That keeps the score honest,
-- so downstream we can measure how well it actually catches the labelled fraud.
--
-- ACH fraud typologies in this data:
--   unauthorized_debit  -> new payee, direction=debit, NACHA return R10/R29
--   friendly_fraud      -> customer disputes their own txn, return R11
--   mule_credit_push    -> new payee, direction=credit, young originator account
with ach as (
    select * from {{ ref('stg_ach') }}
)

select
    -- common columns (shared by every rail, so the marts can union them)
    transaction_id,
    rail_type,
    partner_bank_id,
    originator_account_id,
    beneficiary_account_id          as counterparty_id,
    amount,
    currency,
    txn_timestamp,
    is_new_payee                    as is_new_counterparty,
    is_fraud,
    fraud_type,

    -- individual red-flag rules (kept for drill-down / explainability)
    (is_new_payee and direction = 'debit')                      as flag_new_payee_debit,
    (is_new_payee and direction = 'credit')                     as flag_new_payee_credit_push,
    (coalesce(originator_account_age_days, 999) < 30)           as flag_young_originator,
    (return_code in ('R10', 'R29', 'R11'))                      as flag_dispute_return,

    -- weighted score, capped at 100
    least(100,
          iff(is_new_payee and direction = 'debit', 40, 0)            -- unauthorized debit
        + iff(is_new_payee and direction = 'credit', 30, 0)          -- mule credit push
        + iff(coalesce(originator_account_age_days, 999) < 30, 20, 0)-- fresh account
        + iff(return_code in ('R10', 'R29', 'R11'), 25, 0)           -- disputed/returned
    )                               as risk_score
from ach
