# GSP920 — Securing Cloud SQL for PostgreSQL

Hands-on Google Cloud lab covering **Customer-Managed Encryption Keys (CMEK)**, **pgAudit**, and **Cloud SQL IAM database authentication** for PostgreSQL.

> Based on the GSP920 lab instructions supplied for this project. The lab guide was manually updated and tested on August 3, 2026.

## Objectives

- Configure CMEK encryption for a new Cloud SQL for PostgreSQL instance.
- Enable and configure pgAudit for database activity logging.
- Enable Cloud SQL IAM database authentication.
- Grant an IAM database user fine-grained access to a PostgreSQL table.
- Verify audit logs and database permissions.

## Architecture / Flow

```text
Google Cloud Project
        |
        +--> Cloud KMS
        |      +--> Key Ring
        |           +--> Cloud SQL Encryption Key
        |
        +--> Cloud SQL for PostgreSQL
               |
               +--> CMEK encryption at rest
               +--> pgAudit
               +--> Cloud IAM authentication
               |
               +--> orders database
                      +--> order_items
                      +--> users

Cloud Logging <--- pgAudit / Data Access Audit Logs
```

## Prerequisites

- A temporary Google Cloud Skills Boost / Qwiklabs lab project.
- Chrome or another modern browser.
- Cloud Shell access.
- Permission to create Cloud KMS and Cloud SQL resources in the lab project.

Use the **temporary lab account only**. Do not place lab credentials, access tokens, private keys, or other secrets in Git.

## Task 1 — Create Cloud SQL with CMEK

### 1. Create the Cloud SQL service identity

```bash
export PROJECT_ID=$(gcloud config list --format='value(core.project)')

gcloud beta services identity create \
  --service=sqladmin.googleapis.com \
  --project="$PROJECT_ID"
```

### 2. Create a KMS key ring

The lab derives the region from the `bastion-vm` zone.

```bash
export KMS_KEYRING_ID=cloud-sql-keyring
export ZONE=$(gcloud compute instances list --filter="NAME=bastion-vm" --format=json | jq -r .[].zone | awk -F "/zones/" '{print $NF}')
export REGION=${ZONE::-2}

gcloud kms keyrings create "$KMS_KEYRING_ID" \
  --location="$REGION"
```

### 3. Create the CMEK key

```bash
export KMS_KEY_ID=cloud-sql-key

gcloud kms keys create "$KMS_KEY_ID" \
  --location="$REGION" \
  --keyring="$KMS_KEYRING_ID" \
  --purpose=encryption
```

### 4. Grant Cloud SQL permission to use the key

```bash
export PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" \
  --format='value(projectNumber)')

gcloud kms keys add-iam-policy-binding "$KMS_KEY_ID" \
  --location="$REGION" \
  --keyring="$KMS_KEYRING_ID" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-cloud-sql.iam.gserviceaccount.com" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter
```

### 5. Allow the lab hosts and create Cloud SQL

```bash
export AUTHORIZED_IP=$(gcloud compute instances describe bastion-vm \
  --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs.natIP)')

echo "Authorized IP: $AUTHORIZED_IP"

export CLOUD_SHELL_IP=$(curl -s ifconfig.me)
echo "Cloud Shell IP: $CLOUD_SHELL_IP"
```

Build the key resource name:

```bash
export KEY_NAME=$(gcloud kms keys describe "$KMS_KEY_ID" \
  --keyring="$KMS_KEYRING_ID" \
  --location="$REGION" \
  --format='value(name)')
```

Create the instance:

```bash
export CLOUDSQL_INSTANCE=postgres-orders

gcloud sql instances create "$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" \
  --authorized-networks="${AUTHORIZED_IP}/32,${CLOUD_SHELL_IP}/32" \
  --disk-encryption-key="$KEY_NAME" \
  --database-version=POSTGRES_14 \
  --cpu=1 \
  --memory=3840MB \
  --region="$REGION" \
  --root-password='REPLACE_WITH_LAB_PASSWORD'
```

Replace the placeholder with the password provided by the active lab. **Do not commit the real password.**

## Task 2 — Enable and configure pgAudit

### 1. Enable pgAudit flags

```bash
gcloud sql instances patch "$CLOUDSQL_INSTANCE" \
  --database-flags cloudsql.enable_pgaudit=on,pgaudit.log=all
```

Restart the instance from Cloud Console after the patch completes.

### 2. Create the `orders` database

Connect to Cloud SQL using the built-in `postgres` administrator and run:

```sql
CREATE DATABASE orders;
\c orders
```

Then enable pgAudit for reads and writes:

```sql
CREATE EXTENSION pgaudit;
ALTER DATABASE orders SET pgaudit.log = 'read,write';
```

### 3. Enable Cloud SQL Data Access audit logs

In **IAM & Admin → Audit Logs**:

1. Filter for **Cloud SQL**.
2. Enable **Admin read**.
3. Enable **Data read**.
4. Enable **Data write**.
5. Save the configuration.

### 4. Populate the database

The lab downloads the supplied SQL and CSV files from the lab bucket:

```bash
export SOURCE_BUCKET=gs://spls/gsp920

gcloud storage cp "${SOURCE_BUCKET}/create_orders_db.sql" .
gcloud storage cp "${SOURCE_BUCKET}/DDL/distribution_centers_data.csv" .
gcloud storage cp "${SOURCE_BUCKET}/DDL/inventory_items_data.csv" .
gcloud storage cp "${SOURCE_BUCKET}/DDL/order_items_data.csv" .
gcloud storage cp "${SOURCE_BUCKET}/DDL/products_data.csv" .
gcloud storage cp "${SOURCE_BUCKET}/DDL/users_data.csv" .
```

Populate the database:

```bash
export POSTGRESQL_IP=$(gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --format='value(ipAddresses[0].ipAddress)')

export PGPASSWORD='REPLACE_WITH_LAB_PASSWORD'

psql "sslmode=disable user=postgres hostaddr=${POSTGRESQL_IP}" \
  -c "\\i create_orders_db.sql"
```

### 5. Configure relation-specific auditing

Inside the `orders` database:

```sql
CREATE ROLE auditor WITH NOLOGIN;
ALTER DATABASE orders SET pgaudit.role = 'auditor';
GRANT SELECT ON order_items TO auditor;
```

Run the lab-provided reporting queries and then exit `psql`:

```text
\q
```

### 6. View pgAudit logs

Open **Logging → Logs Explorer** and query:

```text
resource.type="cloudsql_database"
logName="projects/PROJECT_ID/logs/cloudaudit.googleapis.com%2Fdata_access"
protoPayload.request.@type="type.googleapis.com/google.cloud.sql.audit.v1.PgAuditEntry"
```

Replace `PROJECT_ID` with the current lab project ID. Inspect the returned entries to see the recorded SQL activity.

## Task 3 — Configure Cloud SQL IAM authentication

### 1. Test IAM authentication before configuration

```bash
export USERNAME=$(gcloud config list --format='value(core.account)')
export PGPASSWORD=$(gcloud auth print-access-token)

psql --host="$POSTGRESQL_IP" "$USERNAME" --dbname=orders
```

This initial connection is expected to fail because the IAM database user has not yet been created.

### 2. Add the IAM database user

In Cloud Console:

1. Open **Cloud SQL**.
2. Select `postgres-orders`.
3. Open **Users**.
4. Click **Add user account**.
5. Select **Cloud IAM**.
6. Enter the lab student principal shown in the active lab session.
7. Add the user.

The instance configuration should then show the IAM authentication setting.

### 3. Grant table-level access

Connect as the built-in `postgres` administrator, switch to `orders`, and run:

```sql
\c orders
GRANT ALL PRIVILEGES ON TABLE order_items TO "IAM_USER_EMAIL";
\q
```

Replace `IAM_USER_EMAIL` with the actual IAM database username from the active lab session.

### 4. Test with the IAM user

```bash
export PGPASSWORD=$(gcloud auth print-access-token)
psql --host="$POSTGRESQL_IP" "$USERNAME" --dbname=orders
```

Test permitted access:

```sql
SELECT COUNT(*) FROM order_items;
```

The lab verifies that this succeeds.

Test a table that was not granted:

```sql
SELECT COUNT(*) FROM users;
```

The lab verifies that this returns a permission-denied error.

## Security Notes

- CMEK protects Cloud SQL data at rest with a key you control in Cloud KMS.
- pgAudit provides fine-grained database activity logging.
- Cloud SQL IAM authentication uses short-lived OAuth 2.0 access tokens instead of a traditional database password for IAM users.
- Table privileges should be granted according to least privilege.
- Never commit temporary lab passwords or OAuth access tokens.

## What I Learned

- How Cloud SQL uses a KMS key for customer-managed encryption.
- How PostgreSQL auditing can be enabled and scoped with pgAudit.
- How Cloud Logging exposes Cloud SQL data-access audit entries.
- How IAM identities can authenticate to PostgreSQL and receive database-level permissions.
- How to verify permission boundaries by querying an authorized and an unauthorized table.

## Lab Source

This project documents the supplied **GSP920** Google Cloud self-paced lab: securing Cloud SQL for PostgreSQL using CMEK, pgAudit, and IAM database authentication.

The source lab states that the work is performed in a real temporary cloud environment and that the lab credentials should be used instead of a personal Google Cloud account. 
