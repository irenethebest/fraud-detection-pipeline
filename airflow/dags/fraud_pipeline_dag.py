"""
fraud_pipeline_dag.py  --  End-to-end orchestration of the multi-rail fraud pipeline.

WHAT THIS DAG DOES (one automated weekly run):
    1. generate_transactions : create fresh synthetic ACH/Wire/RTP/Card data (local CSVs)
    2. upload_to_s3          : mirror the local bronze/ folder up to S3
    3. load_bronze           : COPY INTO the 4 Snowflake bronze tables from S3
    4. dbt_build             : trigger the dbt Cloud job that builds silver + gold + tests

    generate -> upload -> load -> transform.  Each task only starts once the one
    before it succeeds, so a failure stops the line instead of corrupting downstream data.

WHAT IS AIRFLOW (beginner note):
    Airflow is a *scheduler + orchestrator*. You describe your pipeline as a DAG
    (Directed Acyclic Graph = a set of tasks with a one-way order, no loops). Airflow
    then runs the tasks on a schedule, in the right order, retries failures, and gives
    you a UI showing green/red per task. Think of it as a smart, self-documenting
    cron job that understands dependencies between steps.

    Each step below is a "task", built from an Operator (a prebuilt task type):
      - BashOperator            : run a shell command
      - SQLExecuteQueryOperator : run SQL against a database (here: Snowflake)
      - DbtCloudRunJobOperator  : trigger a job in dbt Cloud

RUNNING THIS (see airflow/README.md):
    This file is portfolio/reference code. To run it for real you'd drop it in an
    Airflow instance's dags/ folder (e.g. via Docker/Astronomer), install the three
    provider packages, and create the three Connections referenced below.
"""
from __future__ import annotations

import pendulum

from airflow import DAG
from airflow.models import Variable
from airflow.providers.standard.operators.bash import BashOperator
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.providers.dbt.cloud.operators.dbt import DbtCloudRunJobOperator

# --- Configuration ----------------------------------------------------------
# In production these come from Airflow Variables/Connections (set in the UI) so
# no environment-specific values are hardcoded in the repo. Defaults keep the DAG
# importable even before the Variables exist.
PROJECT_DIR = Variable.get("fraud_project_dir", default_var="/opt/airflow/project")
S3_BRONZE_URI = Variable.get("fraud_s3_bronze_uri", default_var="s3://REPLACE-ME/bronze/")
DBT_CLOUD_JOB_ID = int(Variable.get("fraud_dbt_cloud_job_id", default_var="0"))

# Airflow Connections (created once in the Airflow UI, credentials stored securely):
AWS_CONN_ID = "aws_default"          # AWS keys for the S3 sync
SNOWFLAKE_CONN_ID = "snowflake_default"  # Snowflake account + FRAUD_WH/FRAUD_DB/role
DBT_CLOUD_CONN_ID = "dbt_cloud_default"  # dbt Cloud API token + account id

# COPY INTO statements (canonical copy lives in snowflake/05_copy_into.sql). The
# Snowflake connection supplies role/warehouse/database/schema, so we only need the
# load commands here. MATCH_BY_COLUMN_NAME loads by header, ON_ERROR CONTINUE keeps
# one bad row from failing the whole file.
COPY_INTO_SQL = [
    """COPY INTO BRONZE.ACH_TRANSACTIONS  FROM @BRONZE.BRONZE_STAGE/ach/
         FILE_FORMAT=(FORMAT_NAME=BRONZE.FF_CSV)
         MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE ON_ERROR='CONTINUE';""",
    """COPY INTO BRONZE.WIRE_TRANSACTIONS FROM @BRONZE.BRONZE_STAGE/wire/
         FILE_FORMAT=(FORMAT_NAME=BRONZE.FF_CSV)
         MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE ON_ERROR='CONTINUE';""",
    """COPY INTO BRONZE.RTP_TRANSACTIONS  FROM @BRONZE.BRONZE_STAGE/rtp/
         FILE_FORMAT=(FORMAT_NAME=BRONZE.FF_CSV)
         MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE ON_ERROR='CONTINUE';""",
    """COPY INTO BRONZE.CARD_TRANSACTIONS FROM @BRONZE.BRONZE_STAGE/card/
         FILE_FORMAT=(FORMAT_NAME=BRONZE.FF_CSV)
         MATCH_BY_COLUMN_NAME=CASE_INSENSITIVE ON_ERROR='CONTINUE';""",
]

# Default settings applied to every task in the DAG.
default_args = {
    "owner": "irene",
    "retries": 2,                                  # transient failures (network) retry twice
    "retry_delay": pendulum.duration(minutes=5),   # wait 5 min between tries
}

with DAG(
    dag_id="fraud_pipeline",
    description="Generate -> S3 -> Snowflake bronze -> dbt Cloud (silver+gold).",
    default_args=default_args,
    start_date=pendulum.datetime(2026, 8, 1, tz="America/Los_Angeles"),  # us-west-2 tz
    schedule="0 9 * * 0",          # cron: 09:00 every Sunday (matches the old weekly task)
    catchup=False,                 # don't back-fill missed runs before today
    tags=["fraud", "dbt", "snowflake"],
) as dag:

    # 1) Generate fresh synthetic data. The seed is derived from the run's ISO
    #    year+week ({{ ... }} is Airflow templating filled in at run time), so each
    #    weekly run differs yet is reproducible -- same idea as the PowerShell script.
    generate_transactions = BashOperator(
        task_id="generate_transactions",
        bash_command=(
            f"cd {PROJECT_DIR} && "
            "python src/generate_transactions.py "
            "--num-per-rail 5000 --fraud-rate 0.02 --days 30 "
            "--seed {{ logical_date.strftime('%G%V') }}"
        ),
    )

    # 2) Mirror local bronze/ up to S3. --delete makes S3 match local exactly,
    #    removing orphaned date-files so the load can't over-count (a bug we hit before).
    upload_to_s3 = BashOperator(
        task_id="upload_to_s3",
        bash_command=(
            f"cd {PROJECT_DIR} && "
            f"aws s3 sync ./data/bronze/ {S3_BRONZE_URI} --delete"
        ),
        # Note: uses AWS creds from the environment / aws_default connection.
    )

    # 3) Load S3 -> Snowflake bronze tables. Runs the 4 COPY INTO statements over
    #    the Snowflake connection (which carries role/warehouse/db/schema).
    load_bronze = SQLExecuteQueryOperator(
        task_id="load_bronze",
        conn_id=SNOWFLAKE_CONN_ID,
        sql=COPY_INTO_SQL,
    )

    # 4) Transform: trigger the dbt Cloud job that runs `dbt build` (silver + gold
    #    models AND all data-quality tests). wait_for_termination lets Airflow block
    #    until dbt finishes so this task's red/green reflects the dbt run's result.
    dbt_build = DbtCloudRunJobOperator(
        task_id="dbt_build",
        dbt_cloud_conn_id=DBT_CLOUD_CONN_ID,
        job_id=DBT_CLOUD_JOB_ID,
        check_interval=30,          # poll dbt Cloud every 30s
        timeout=1800,               # give up after 30 min
        wait_for_termination=True,
    )

    # Define the order. `>>` means "then": each task waits for the previous to succeed.
    generate_transactions >> upload_to_s3 >> load_bronze >> dbt_build
