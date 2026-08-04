-- Gold: the fraud fact table -- one row per transaction, all four rails unified,
-- each carrying its rail-specific risk_score. This is the analytics grain that
-- BI dashboards and analysts query.
--
-- We union the four scored intermediate models (which already share a common set
-- of columns) and then translate the numeric score into a business-friendly
-- risk_band and an is_flagged decision an ops team could action.
--
-- risk_band thresholds (tune to your alert budget):
--   >= 70  High    (review first)
--   40-69  Medium  (secondary queue)
--   < 40   Low     (monitor)
-- is_flagged = score >= 50  -> the "would we alert on this?" line.
with scored as (
    select transaction_id, rail_type, partner_bank_id, originator_account_id,
           counterparty_id, amount, currency, txn_timestamp,
           is_new_counterparty, risk_score, is_fraud, fraud_type
    from {{ ref('int_ach_scored') }}
    union all
    select transaction_id, rail_type, partner_bank_id, originator_account_id,
           counterparty_id, amount, currency, txn_timestamp,
           is_new_counterparty, risk_score, is_fraud, fraud_type
    from {{ ref('int_wire_scored') }}
    union all
    select transaction_id, rail_type, partner_bank_id, originator_account_id,
           counterparty_id, amount, currency, txn_timestamp,
           is_new_counterparty, risk_score, is_fraud, fraud_type
    from {{ ref('int_rtp_scored') }}
    union all
    select transaction_id, rail_type, partner_bank_id, originator_account_id,
           counterparty_id, amount, currency, txn_timestamp,
           is_new_counterparty, risk_score, is_fraud, fraud_type
    from {{ ref('int_card_scored') }}
)

select
    transaction_id,
    rail_type,
    partner_bank_id,
    originator_account_id,
    counterparty_id,
    amount,
    currency,
    txn_timestamp,
    date(txn_timestamp)             as txn_date,
    is_new_counterparty,
    risk_score,
    case
        when risk_score >= 70 then 'High'
        when risk_score >= 40 then 'Medium'
        else 'Low'
    end                             as risk_band,
    (risk_score >= 50)              as is_flagged,
    is_fraud,                                       -- ground-truth label (validation only)
    fraud_type
from scored
