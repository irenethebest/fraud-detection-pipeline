# Airflow orchestration

This folder is a runnable **Astro (Astronomer) Airflow project** that automates the
whole fraud pipeline end to end. It ties together the steps that were previously run
by hand or by a separate Windows scheduled task.

It was scaffolded with the [Astro CLI](https://docs.astronomer.io/astro-cli)
(`astro dev init`) and has been **tested locally with Docker** — the DAG imports
cleanly in Airflow 3 with all provider dependencies resolved.

## The DAG: `dags/fraud_pipeline_dag.py`

One weekly run, four tasks, executed in order (each waits for the previous to succeed):

```
generate_transactions  →  upload_to_s3  →  load_bronze  →  dbt_build
   (Python generator)      (aws s3 sync)   (COPY INTO)     (dbt Cloud job)
```

| Task | Operator | What it does |
|------|----------|--------------|
| `generate_transactions` | `BashOperator` | Runs `src/generate_transactions.py` to create fresh synthetic ACH/Wire/RTP/Card CSVs. Seed = the run's ISO year+week, so runs are fresh but reproducible. |
| `upload_to_s3` | `BashOperator` | `aws s3 sync ./data/bronze/ → S3` with `--delete` so S3 mirrors local exactly. |
| `load_bronze` | `SQLExecuteQueryOperator` | Runs the 4 `COPY INTO` statements (S3 → Snowflake bronze). Canonical SQL: `snowflake/05_copy_into.sql`. |
| `dbt_build` | `DbtCloudRunJobOperator` | Triggers the dbt Cloud job that runs `dbt build` (silver + gold models **and** all tests), and waits for it to finish. |

**Design pattern:** Airflow *orchestrates*; dbt Cloud *transforms*. Airflow doesn't
re-implement dbt — it just triggers the dbt Cloud job via API and reports its result.
This is a common modern setup.

## Run it locally (Docker + Astro CLI)

Prerequisites: **Docker Desktop** (running) and the **Astro CLI**
(`winget install -e --id Astronomer.Astro`).

```bash
cd airflow
astro dev start      # builds the image, boots Airflow in Docker
```

Then open the UI at **http://localhost:8080** (default local login: `admin` / `admin`).
You'll see `fraud_pipeline` in the DAG list; the Graph view shows the four chained tasks.

Useful commands:

| Command | What it does |
|---------|--------------|
| `astro dev start` | Build image + start all containers (scheduler, api-server, triggerer, dag-processor, postgres). |
| `astro dev ps` | Show the running containers and their health. |
| `astro dev run dags list-import-errors` | Run the Airflow CLI *inside* the container — empty output means the DAG parsed with no errors. |
| `astro dev stop` | Stop the containers (frees RAM); `astro dev start` brings them back. |
| `astro dev kill` | Tear everything down, including the metadata DB. |

### Airflow 3 notes

This project runs on **Astro Runtime 3.3 (Airflow 3.x)**. Two things differ from
Airflow 2.x and are already handled in this repo:

- **Basic operators moved into the `standard` provider.** `BashOperator` is imported as
  `from airflow.providers.standard.operators.bash import BashOperator`.
- **Extra providers are pinned in `requirements.txt`** so Docker installs them into the
  image (the base image doesn't bundle these two):
  ```
  apache-airflow-providers-dbt-cloud
  apache-airflow-providers-snowflake
  ```

## What a real end-to-end run also needs

Local `astro dev start` proves the DAG is valid and importable. To actually execute all
four tasks against live systems you additionally need:

**1. Connections** (Airflow UI → Admin → Connections; secrets stay in Airflow, never in git):
- `aws_default` — AWS access key/secret with write access to the S3 bucket
- `snowflake_default` — Snowflake account + user, with role/warehouse (`FRAUD_WH`)/database (`FRAUD_DB`)/schema (`BRONZE`) set as defaults
- `dbt_cloud_default` — dbt Cloud API token + account id

**2. Variables** (Airflow UI → Admin → Variables):
- `fraud_project_dir` — path to the repo inside the Airflow worker (e.g. `/opt/airflow/project`)
- `fraud_s3_bronze_uri` — e.g. `s3://<your-bucket>/bronze/`
- `fraud_dbt_cloud_job_id` — the numeric id of your dbt Cloud "build" job

**3. The repo mounted into the worker** so `src/generate_transactions.py` exists at
`fraud_project_dir` (e.g. via a volume mount in `docker-compose.override.yml`).

For local development you can pre-declare Connections and Variables in
`airflow_settings.yaml` (created by `astro dev init`, git-ignored) instead of clicking
through the UI each time.

## Project structure

```
airflow/
├── dags/
│   └── fraud_pipeline_dag.py   # the pipeline DAG
├── Dockerfile                  # pins the Astro Runtime (Airflow 3.x) image
├── requirements.txt            # extra provider packages (dbt-cloud, snowflake)
├── packages.txt                # OS-level packages (none needed)
├── airflow_settings.yaml       # local Connections/Variables (git-ignored)
├── include/  plugins/  tests/  # Astro scaffold folders
└── README.md                   # this file
```

## Why a DAG instead of the weekly Windows task?

The Windows Task (`scripts/setup_weekly_task.ps1`) only automates steps 1–2 (generate +
upload). Airflow automates **all four** steps as one dependency-aware pipeline, with
retries, logging, and a UI — and it's the tool data teams actually use, so it's the
right thing to demonstrate.
