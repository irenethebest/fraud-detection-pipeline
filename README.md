# Multi-Rail BaaS Fraud Detection Pipeline

An end-to-end fraud-detection data pipeline over synthetic **Banking-as-a-Service (BaaS)**
transactions spanning four payment rails — **ACH, Wire, RTP, and Card** — built on a
modern data stack (**AWS S3 → Snowflake → dbt → Airflow**).

> **The core idea:** most fraud projects apply one generic model to every transaction.
> This one treats each payment rail's fraud as a **fundamentally different problem**,
> because it is — an unauthorized ACH *debit*, a Wire BEC/APP scam, an instant-RTP mule
> cash-out, and card-not-present testing each leave a distinct signature. The pipeline is
> designed around those differences.

![status](https://img.shields.io/badge/status-in%20progress-yellow)
![python](https://img.shields.io/badge/python-3.13-blue)
![stack](https://img.shields.io/badge/stack-S3%20%7C%20Snowflake%20%7C%20dbt%20%7C%20Airflow-informational)

---

## Architecture

```
                          ┌───────────────────────────────┐
                          │            Airflow            │
                          │  orchestrates ingest + dbt     │
                          └───────────────┬───────────────┘
                                  │                 │
┌────────────────┐    ┌──────────────┐   ┌──────────────────┐   ┌────────────────┐
│ Synthetic txns │───▶│  Amazon S3   │──▶│ Snowflake + dbt  │──▶│ Fraud scoring  │
│ ACH/Wire/RTP/  │    │   (bronze)   │   │ (silver + gold)  │   │ rules + alerts │
│ Card           │    │              │   │                  │   │                │
└────────────────┘    └──────────────┘   └──────────────────┘   └────────────────┘
   generate_          raw landing,        standardize +          rail-specific
   transactions.py    partitioned by      feature models         rules → alert
                      rail & date         per rail               queue
```

**ELT, not ETL:** raw CSVs land untouched in an S3 *bronze* layer first; all
transformation happens in-warehouse (Snowflake + dbt). If transform logic changes, the
immutable raw copy can always be reprocessed.

---

## Why fraud differs by rail

| Rail | Settlement | Reversibility | Typical fraud | Signal-rich features |
|---|---|---|---|---|
| **ACH** | 1–2 business days | Reversible (return codes) | Unauthorized **debit** / account takeover (R10/R29), first-party "friendly fraud" (R11), mule **credit**-push | `direction` (debit vs credit), return-code history, unauthorized-return rate, new-payee velocity |
| **Wire** | Same-day, irrevocable | Effectively final | Business Email Compromise (BEC), Authorized Push Payment (APP) fraud | New beneficiary, urgency flag, amount-vs-average ratio, cross-border, beneficiary account age |
| **RTP** | Seconds, irrevocable | No recall window | Real-time account takeover, mule cash-out | New device/IP, new-recipient + large-amount combo, odd-hour timestamp |
| **Card** | Near-instant, ~120-day chargeback | Reversible via chargeback | Card-not-present testing, counterfeit | AVS/CVV mismatch, entry mode, merchant/cardholder country mismatch |

Full domain notes, schema, and build plan: [`docs/project_brief.md`](docs/project_brief.md).

---

## Repository structure

```
.
├── README.md
├── requirements.txt
├── .gitignore
├── src/
│   └── generate_transactions.py   # synthetic multi-rail data generator
├── scripts/
│   ├── refresh_data.ps1           # generate + upload to S3 (manual or scheduled)
│   └── setup_weekly_task.ps1      # register the weekly Windows scheduled task
├── docs/
│   └── project_brief.md           # domain deep-dive, schema, phased build plan
├── dbt/                           # dbt models (silver/gold) — coming next
├── airflow/                       # orchestration DAG — planned
├── data/                          # generated CSVs (git-ignored)
└── logs/                          # refresh run logs (git-ignored)
```

---

## Quickstart

**Prerequisites:** Python 3.13+, and (for the S3 upload) the AWS CLI configured with
`aws configure`.

```bash
# 1. Install dependencies
pip install -r requirements.txt

# 2. Generate synthetic transactions -> ./data
python src/generate_transactions.py --num-per-rail 5000 --fraud-rate 0.02 --days 30
```

This writes, per rail:
- `data/<rail>_transactions.csv` — one flat file per rail
- `data/bronze/<rail>/<date>.csv` — partitioned to mirror an S3 landing zone

### Explore the data (no cloud needed)

```sql
-- DuckDB: query the CSVs directly with SQL
SELECT direction, return_code, COUNT(*)
FROM 'data/ach_transactions.csv'
WHERE is_fraud = 1
GROUP BY 1, 2;
```

### Upload to S3

```bash
aws s3 sync ./data/bronze/ s3://<your-bucket>/bronze/
```

---

## Weekly refresh (automation)

`scripts/refresh_data.ps1` regenerates the data and uploads it to S3 in one step. It can
be run **manually** or on a **weekly schedule**.

```powershell
# Manual run
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/refresh_data.ps1

# One-time: register the weekly Windows scheduled task (Sundays 9:00 AM)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup_weekly_task.ps1
```

Each run uses an ISO year+week seed, so weekly data differs but any given week is
reproducible. Logs are written to `logs/`.

---

## Roadmap

- [x] Synthetic multi-rail data generator with rail-specific fraud typologies
- [x] S3 bronze landing zone + one-step refresh + weekly scheduling
- [x] Snowflake external stage (secure storage integration) + `COPY INTO` from S3
- [ ] dbt: `stg_transactions` (silver) → rail feature models → unified fraud mart (gold)
- [ ] dbt tests on rail-specific enums (return codes, MCC codes, entry modes)
- [ ] Airflow DAG chaining ingest → dbt run → dbt test → scoring
- [ ] Rail-specific fraud scoring rules + reviewable alert queue
- [ ] (Stretch) Rules vs. ML (logistic regression / XGBoost) precision-recall comparison

---

## Note on the data

All data is **synthetic** and generated locally — no real customer or PII data is used.
The `is_fraud` / `fraud_type` columns are ground-truth labels for validating detection
logic; in a real pipeline they would not exist upstream of the detection layer, only
downstream as investigation outcomes.
