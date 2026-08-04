-- Gold: daily fraud scorecard, one row per (partner bank x rail x day).
--
-- WHY per partner bank? This is a BaaS (Banking-as-a-Service) platform: the
-- sponsor bank serves many fintech partners, and fraud tends to concentrate in a
-- few. Slicing by partner_bank_id shows which programs are bleeding.
--
-- Detection-quality metrics compare our risk score (is_flagged) against the true
-- label (is_fraud), the way a fraud team measures an alerting rule:
--   true_positives  = flagged AND actually fraud   (good catches)
--   recall          = TP / all fraud               (% of fraud we caught)
--   precision       = TP / all flagged             (% of alerts that were real)
-- Recall vs precision is the core fraud trade-off: catch more fraud, or send
-- fewer false alarms.
with txns as (
    select * from {{ ref('fct_transactions') }}
)

select
    txn_date,
    partner_bank_id,
    rail_type,

    -- volume
    count(*)                                            as txn_count,
    sum(amount)                                         as total_amount,

    -- fraud (ground truth)
    sum(iff(is_fraud, 1, 0))                            as fraud_count,
    sum(iff(is_fraud, amount, 0))                       as fraud_amount,
    round(sum(iff(is_fraud, 1, 0)) / count(*), 4)      as fraud_rate,

    -- what our score flagged
    sum(iff(is_flagged, 1, 0))                          as flagged_count,

    -- detection quality (score vs. truth)
    sum(iff(is_flagged and is_fraud, 1, 0))            as true_positives,
    round(
        div0(sum(iff(is_flagged and is_fraud, 1, 0)),
             sum(iff(is_fraud, 1, 0))), 4)              as detection_recall,
    round(
        div0(sum(iff(is_flagged and is_fraud, 1, 0)),
             sum(iff(is_flagged, 1, 0))), 4)            as detection_precision
from txns
group by txn_date, partner_bank_id, rail_type
