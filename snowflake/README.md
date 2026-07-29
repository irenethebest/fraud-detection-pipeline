# Snowflake load layer (S3 bronze → Snowflake bronze)

Loads the S3 `bronze/` CSVs into Snowflake using a **storage integration** — the
secure, key-less pattern where Snowflake assumes a scoped read-only IAM role
instead of storing AWS credentials.

## Files (run the SQL in order, in a Snowsight worksheet as `ACCOUNTADMIN`)

| File | Purpose |
|---|---|
| `01_account_setup.sql` | Warehouse `FRAUD_WH`, database `FRAUD_DB`, schema `BRONZE` |
| `02_storage_integration.sql` | Create the storage integration; `DESC` it for the trust values |
| `03_stage_and_format.sql` | CSV file format + external stage over `s3://.../bronze/` |
| `04_create_bronze_tables.sql` | One raw table per rail (ACH/Wire/RTP/Card) |
| `05_copy_into.sql` | `COPY INTO` from the stage + validation queries |
| `aws/iam_policy_s3_read.json` | S3 read-only permission policy (paste in AWS) |
| `aws/iam_role_trust_policy.json` | Role trust policy (paste in AWS after the `DESC`) |

## Why the AWS ↔ Snowflake back-and-forth?

Each side needs an identifier from the other, so the setup interleaves:

1. **AWS — create the role.** IAM → Policies → create a policy from
   `aws/iam_policy_s3_read.json`. Then IAM → Roles → create a role, trusted entity
   = **your own AWS account** as a placeholder, attach that policy,
   name it e.g. `snowflake-fraud-role`. Copy its **Role ARN**.
2. **Snowflake — create integration.** Paste the Role ARN into
   `02_storage_integration.sql`, run it, then run `DESC INTEGRATION S3_FRAUD_INT;`
   Copy `STORAGE_AWS_IAM_USER_ARN` and `STORAGE_AWS_EXTERNAL_ID`.
3. **AWS — finish the trust.** Edit the role's **Trust relationships** → paste both
   values in using `aws/iam_role_trust_policy.json` as the template. Save.
4. **Snowflake — stage + load.** Run `03` (then `LIST @BRONZE_STAGE;` should show
   your files), `04`, and `05`. Validation at the end should show ~5,000 rows/rail
   and ~2% fraud.

If `LIST @BRONZE_STAGE;` errors with an access/permission message, the trust
policy values (step 3) aren't right yet — that's the usual culprit.

## Configuration (placeholders to fill in)

These files are committed with `<PLACEHOLDERS>` instead of real identifiers, so the
repo publishes nothing account-specific. Substitute your own values when you run them:

| Placeholder | Where to get it |
|---|---|
| `<S3_BUCKET>` | your S3 bucket name |
| `<AWS_ACCOUNT_ID>` | your 12-digit AWS account ID |
| `<SNOWFLAKE_ROLE_NAME>` | the IAM role you create (e.g. `snowflake-fraud-role`) |
| `<STORAGE_AWS_IAM_USER_ARN>` | from `DESC INTEGRATION S3_FRAUD_INT;` |
| `<STORAGE_AWS_EXTERNAL_ID>` | from `DESC INTEGRATION S3_FRAUD_INT;` |

None of these are secrets (no access keys), but they're environment-specific, so they
stay out of version control as a matter of good hygiene.

## Security note

The role grants **read-only** access to only the `bronze/` prefix, and no AWS keys
are stored in Snowflake. This is the production-standard approach: Snowflake assumes a
scoped IAM role rather than holding any long-lived credentials.
