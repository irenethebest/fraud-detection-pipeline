# Project Brief: Multi-Rail BaaS Fraud Detection Pipeline

## Goal

Build an end-to-end fraud detection pipeline using synthetic Banking-as-a-Service
(BaaS) transaction data spanning four payment rails — ACH, Wire, RTP, and Card —
through a real AWS → Snowflake → dbt → Airflow stack. The project is meant to
demonstrate, for fraud-analyst and fintech data-analyst interviews:

- Fluency with the modern data stack (not just Databricks/Spark)
- Domain knowledge of how fraud actually differs by payment rail
- Ability to translate that domain knowledge into rule-based detection logic
  and dbt-modeled features

## Target audience for this project

Fraud analyst roles and fintech/BaaS data analyst roles. The differentiator to
lead with in interviews: most candidates apply one generic fraud model to all
transactions; this project treats each rail's fraud pattern as fundamentally
different, because it is.

---

## Architecture

```
                         ┌───────────────────────────────┐
                         │            Airflow            │
                         │  orchestrates ingestion + dbt  │
                         └───────────────┬───────────────┘
                                 │                 │
                 triggers        │                 │  triggers
                 ingestion       ▼                 ▼  dbt run
┌────────────────┐    ┌──────────────┐   ┌──────────────────┐   ┌────────────────┐
│ Synthetic txns  │───▶│  Amazon S3   │──▶│ Snowflake + dbt  │──▶│ Fraud scoring  │
│ ACH/Wire/RTP/   │    │   (bronze)   │   │  (silver+gold)   │   │ rules + alerts │
│ Card            │    │              │   │                  │   │                │
└────────────────┘    └──────────────┘   └──────────────────┘   └────────────────┘
```

- **Synthetic transactions**: generated locally via `generate_transactions.py`
  (already built — see File Manifest below)
- **S3 (bronze)**: raw landing zone, one prefix per rail, partitioned by date
- **Snowflake + dbt (silver/gold)**: dbt standardizes schema across rails into
  one `stg_transactions` model (silver), then builds rail-specific feature
  models and a unified fraud mart (gold)
- **Fraud scoring**: rail-specific rules (dbt models or a Python post-processing
  step) that flag transactions and produce an alert queue
- **Airflow**: DAG chains ingestion → dbt run → dbt test → scoring

---

## Payment Rail Fraud Characteristics (core domain knowledge to demonstrate)

| Rail | Settlement speed | Reversibility | Typical fraud pattern | Signal-rich features |
|---|---|---|---|---|
| **ACH** | 1–2 business days | Reversible (return codes: R01 NSF, R10/R29 unauthorized, R11 terms-of-auth dispute) | Account takeover via unauthorized **debit** (R10/R29), first-party "friendly fraud" (R11), mule **credit**-push to new payee | `direction` (debit vs credit), return-code history, unauthorized-return rate, new-payee velocity |
| **Wire** | Same-day, often irrevocable | Effectively final once sent | Business email compromise (BEC), authorized-push-payment (APP) fraud, beneficiary mismatch | Beneficiary account age, cross-border flag, amount vs. historical max, urgency/last-minute changes |
| **RTP/FedNow (instant)** | Seconds, irrevocable | No recall window | Real-time account takeover, mule account cash-out, synthetic identity | Device/IP velocity, new-recipient-large-amount combo, time-of-day anomaly |
| **Card (CP)** | Near-instant, chargeback window ~120 days | Reversible via chargeback | Skimming, counterfeit card | Card-present + geolocation mismatch, chip vs. swipe fallback flag |
| **Card (CNP)** | Near-instant, chargeback window ~120 days | Reversible via chargeback | Stolen card-not-present, account testing (small "ping" transactions) | AVS/CVV mismatch, BIN velocity, small-then-large amount escalation |

---

## Data Schema (per rail, as produced by `generate_transactions.py`)

**Common fields (all rails):** `transaction_id`, `rail_type`, `partner_bank_id`,
`originator_account_id`, `amount`, `currency`, `timestamp`, `is_fraud`,
`fraud_type` (ground-truth label for validation only — not a real-world feature)

**ACH-specific:** `beneficiary_account_id`, `direction` (`debit`=pull /
`credit`=push), `sec_code` (PPD/CCD/WEB/TEL), `return_code` (direction-gated
NACHA codes — see below), `is_new_payee`, `originator_account_age_days`

**Wire-specific:** `beneficiary_account_id`, `beneficiary_bank_swift`,
`wire_type`, `is_new_beneficiary`, `urgency_flag`, `amount_vs_avg_ratio`,
`beneficiary_account_age_days`

**RTP-specific:** `beneficiary_account_id`, `device_id`, `ip_address`,
`is_new_recipient`, `hour_of_day`

**Card-specific:** `card_id`, `merchant_id`, `mcc_code`, `entry_mode`,
`is_card_present`, `avs_result`, `cvv_result`, `merchant_country`,
`cardholder_country`

Fraud is injected at ~2% per rail using the patterns in the table above. ACH
fraud is split across three typologies (60% unauthorized debit → `direction=debit`
+ `R10`/`R29` + new payee; 20% friendly fraud → `direction=debit` + `R11`; 20%
mule credit-push → `direction=credit` + new payee + large amount, settles with no
return). RTP fraud rows use a device/IP never seen before on that account plus an
odd-hour timestamp. Return codes are **direction-gated**: NSF (R01) and the
unauthorized family (R10/R11/R29) only appear on debits; R23 only on credits.

---

## File Manifest (already built)

- `src/generate_transactions.py` — synthetic data generator, tested and working.
  Run with: `python src/generate_transactions.py --num-per-rail 5000 --fraud-rate 0.02 --days 30`
  Outputs `./data/{rail}_transactions.csv` and `./data/bronze/{rail}/{date}.csv`
  (already shaped like an S3 landing structure). ACH now models `direction`
  (debit/credit) with three fraud typologies and direction-gated NACHA return codes.
- `scripts/refresh_data.ps1` — one-step "generate + upload to S3" refresh. Run manually
  (`powershell -File scripts/refresh_data.ps1`) or via the weekly scheduled task. Uses an
  ISO year+week seed so each weekly run differs but is reproducible; logs to `./logs/`.
- `scripts/setup_weekly_task.ps1` — registers `refresh_data.ps1` as a Windows Task
  Scheduler job (`FraudPipeline-WeeklyRefresh`, Sundays 9:00 AM). Run once.
  Remove with `Unregister-ScheduledTask -TaskName FraudPipeline-WeeklyRefresh`.

---

## Build Plan

### Phase 1 — AWS setup
- [ ] Create AWS account (Free plan, no card required, ~6 month window)
- [ ] Create S3 bucket, e.g. `<name>-fraud-pipeline`
- [ ] Create prefixes: `bronze/ach/`, `bronze/wire/`, `bronze/rtp/`, `bronze/card/`
- [ ] Upload generated CSVs from `./data/bronze/`

### Phase 2 — dbt setup (no clock, do anytime)
- [ ] `pip install dbt-core dbt-snowflake`
- [ ] `dbt init fraud_pipeline`
- [ ] Build `stg_transactions` model: standardize schema across all 4 rails
      into one common table (amount, timestamp, originator, beneficiary, rail_type)
- [ ] Build rail-specific feature models: `ach_features`, `wire_features`,
      `rtp_features`, `card_features`
- [ ] Add dbt tests: `not_null`/`accepted_values` on rail-specific enums
      (return codes, MCC codes, entry modes)

### Phase 3 — Airflow setup (no clock, do anytime)
- [ ] Run Airflow locally via Docker Compose
- [ ] Build a DAG: generate/land data → COPY INTO Snowflake → `dbt run` →
      `dbt test` → scoring script

### Phase 4 — Snowflake setup (30-day/$400 clock — start once ready to load real data)
- [ ] Sign up at signup.snowflake.com, choose Enterprise edition, AWS as cloud
      provider, region near you
- [ ] Create database `FRAUD_DB` and warehouse `FRAUD_WH` (X-Small)
- [ ] Set up external stage / `COPY INTO` pointing at the S3 bucket
- [ ] Wire dbt's `profiles.yml` to the Snowflake connection

### Phase 5 — Fraud scoring layer
- [ ] Implement rail-specific rules as dbt models or a post-dbt Python script,
      using the feature columns from Phase 2 (e.g. ACH: `direction = 'debit' AND
      is_new_payee AND return_code IN ('R10','R29')`; Wire: `is_new_beneficiary AND urgency_flag AND
      amount_vs_avg_ratio > 4`; RTP: new device + odd hour + large amount;
      Card: `avs_result = 'mismatch' AND entry_mode = 'card_not_present'`)
- [ ] Score each transaction, flag alerts
- [ ] Stretch goal: compare rule-based scoring against a simple logistic
      regression/XGBoost model, and discuss precision/recall tradeoffs

### Phase 6 — (Optional) Dashboard
- [ ] Power BI or Sigma on top of the gold layer: alert volume by rail,
      false-positive rate, fraud $ exposure by rail

---

## Interview Talking Points This Project Generates

- ELT vs. ETL: why raw data lands first, transformation happens in-warehouse
- Rail-specific fraud typologies (domain depth beyond "I built a fraud model")
- Precision/recall tradeoffs in fraud rules (false positives cost customer
  experience; false negatives cost losses)
- dbt testing as a data-quality control — relevant to audit/governance
  conversations in banking
- Why Snowflake+dbt+Airflow vs. an all-in-one Databricks lakehouse — workload
  shape (SQL-heavy BI/analytics vs. ML/streaming) drives the choice, not one
  being objectively better

---

## Success Criteria

- [ ] All 4 rails' data flows from S3 → Snowflake → dbt silver/gold models
- [ ] Airflow DAG runs the full chain end-to-end without manual steps
- [ ] Fraud rules produce a reviewable alert queue with a sane false-positive
      rate against the labeled synthetic fraud
- [ ] Can articulate, out loud, why each rail's rules look the way they do
