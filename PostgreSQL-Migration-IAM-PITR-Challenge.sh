#!/bin/bash
# PostgreSQL Migration + IAM + PITR Challenge Lab
# Source:  postgres-vm
# Source DB: orders
# Destination: postgres63-yo1ti
# Region: us-east4
#
# This script automates the CLI portions of Tasks 1-4.
# Console-only items are printed clearly when they cannot be completed by gcloud.

set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
REGION="us-east4"
SOURCE_VM="postgres-vm"
SOURCE_DB="orders"
SOURCE_PROFILE="postgres-vm-source"
DEST_INSTANCE="postgres63-yo1ti"
DEST_PROFILE="postgres63-destination"
MIGRATION_JOB="postgres-vm-to-postgres63"
MIGRATION_USER="replication_admin"
MIGRATION_PASSWORD='DMS_1s_cool!'
CLOUDSQL_PASSWORD='supersecret!'
IAM_USER="$(gcloud config get-value account 2>/dev/null)"
VPC_NAME="default"
PITR_CLONE="postgres-orders-pitr"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  echo "ERROR: No active Google Cloud project is configured."
  exit 1
fi

echo "Project: $PROJECT_ID"
echo "Region:  $REGION"

echo

echo "========== TASK 1: PREPARE SOURCE =========="

echo "Enabling required APIs..."
gcloud services enable datamigration.googleapis.com servicenetworking.googleapis.com --project="$PROJECT_ID"

SOURCE_ZONE="$(gcloud compute instances describe "$SOURCE_VM" --format='value(zone.basename())')"
SOURCE_INTERNAL_IP="$(gcloud compute instances describe "$SOURCE_VM" --format='value(networkInterfaces[0].networkIP)')"
SOURCE_EXTERNAL_IP="$(gcloud compute instances describe "$SOURCE_VM" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"

if [[ -z "$SOURCE_ZONE" || -z "$SOURCE_INTERNAL_IP" ]]; then
  echo "ERROR: Could not determine $SOURCE_VM zone/internal IP."
  exit 1
fi

echo "Source zone: $SOURCE_ZONE"
echo "Source internal IP: $SOURCE_INTERNAL_IP"
echo "Source external IP: $SOURCE_EXTERNAL_IP"

echo "Preparing PostgreSQL 14 + pglogical on source VM..."
gcloud compute ssh "$SOURCE_VM" --zone="$SOURCE_ZONE" --quiet --command="sudo bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y postgresql-14-pglogical

PGCONF=/etc/postgresql/14/main/postgresql.conf
PGHBA=/etc/postgresql/14/main/pg_hba.conf

add_conf() {
  local line="$1"
  grep -Fxq "$line" "$PGCONF" || echo "$line" >> "$PGCONF"
}

add_conf "shared_preload_libraries = 'pglogical'"
add_conf "wal_level = logical"
add_conf "max_worker_processes = 10"
add_conf "max_replication_slots = 10"
add_conf "max_wal_senders = 10"
add_conf "listen_addresses = '*'"
add_conf "wal_sender_timeout = 0"

grep -Fxq 'host    all             all             0.0.0.0/0               md5' "$PGHBA" || \
  echo 'host    all             all             0.0.0.0/0               md5' >> "$PGHBA"

grep -Fxq 'host    replication     all             0.0.0.0/0               md5' "$PGHBA" || \
  echo 'host    replication     all             0.0.0.0/0               md5' >> "$PGHBA"

systemctl restart postgresql@14-main

sudo -u postgres psql <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replication_admin') THEN
    CREATE ROLE replication_admin LOGIN PASSWORD 'DMS_1s_cool!';
  ELSE
    ALTER ROLE replication_admin WITH LOGIN PASSWORD 'DMS_1s_cool!';
  END IF;
END
$$;

ALTER ROLE replication_admin WITH REPLICATION;

CREATE DATABASE orders_dummy;
DROP DATABASE orders_dummy;
SQL

for DB in postgres orders; do
  sudo -u postgres psql -d "$DB" -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pglogical;
GRANT USAGE ON SCHEMA public TO replication_admin;
GRANT USAGE ON SCHEMA pglogical TO PUBLIC;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replication_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO replication_admin;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO replication_admin;
SQL
done

# Make sure the migration user owns the migrated database and its application objects.
sudo -u postgres psql -d postgres -c "ALTER DATABASE orders OWNER TO replication_admin;"

sudo -u postgres psql -d orders -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
  t text;
  pk_exists boolean;
  pk_name text;
BEGIN
  FOREACH t IN ARRAY ARRAY['distribution_centers','inventory_items','order_items','products','users'] LOOP
    SELECT EXISTS (
      SELECT 1
      FROM pg_constraint c
      JOIN pg_class r ON r.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = r.relnamespace
      WHERE c.contype = 'p' AND n.nspname = 'public' AND r.relname = t
    ) INTO pk_exists;

    IF NOT pk_exists THEN
      pk_name := t || '_pkey_auto';
      EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I PRIMARY KEY (id)', t, pk_name);
    END IF;
  END LOOP;
END
$$;

ALTER TABLE public.distribution_centers OWNER TO replication_admin;
ALTER TABLE public.inventory_items OWNER TO replication_admin;
ALTER TABLE public.order_items OWNER TO replication_admin;
ALTER TABLE public.products OWNER TO replication_admin;
ALTER TABLE public.users OWNER TO replication_admin;

GRANT USAGE ON SCHEMA public TO replication_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replication_admin;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO replication_admin;
SQL

sudo -u postgres psql -d orders -c "\d distribution_centers" >/dev/null
sudo -u postgres psql -c "SHOW shared_preload_libraries; SHOW wal_level; SHOW max_replication_slots; SHOW max_wal_senders; SHOW max_worker_processes;"
REMOTE_SCRIPT

echo "Source database prepared."

echo

echo "========== TASK 1: CREATE DMS PROFILES/JOB =========="

if ! gcloud database-migration connection-profiles describe "$SOURCE_PROFILE" --region="$REGION" >/dev/null 2>&1; then
  echo "Creating source connection profile..."
  gcloud database-migration connection-profiles create postgresql "$SOURCE_PROFILE" \
    --region="$REGION" \
    --role=SOURCE \
    --host="$SOURCE_INTERNAL_IP" \
    --port=5432 \
    --username="$MIGRATION_USER" \
    --password="$MIGRATION_PASSWORD" \
    --no-async
else
  echo "Source connection profile already exists: $SOURCE_PROFILE"
fi

if ! gcloud database-migration connection-profiles describe "$DEST_PROFILE" --region="$REGION" >/dev/null 2>&1; then
  echo "Creating destination connection profile..."
  gcloud database-migration connection-profiles create postgresql "$DEST_PROFILE" \
    --region="$REGION" \
    --cloudsql-instance="$DEST_INSTANCE" \
    --role=DESTINATION \
    --display-name="$DEST_PROFILE" \
    --no-async
else
  echo "Destination connection profile already exists: $DEST_PROFILE"
fi

if ! gcloud database-migration migration-jobs describe "$MIGRATION_JOB" --region="$REGION" >/dev/null 2>&1; then
  echo "Creating continuous migration job with VPC peering..."
  gcloud database-migration migration-jobs create "$MIGRATION_JOB" \
    --region="$REGION" \
    --display-name="$MIGRATION_JOB" \
    --type=CONTINUOUS \
    --source="$SOURCE_PROFILE" \
    --destination="$DEST_PROFILE" \
    --databases-filter="$SOURCE_DB" \
    --peer-vpc="projects/$PROJECT_ID/global/networks/$VPC_NAME" \
    --no-async
else
  echo "Migration job already exists: $MIGRATION_JOB"
fi

echo "Demoting destination for migration..."
JOB_STATE="$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB" --region="$REGION" --format='value(state)' 2>/dev/null || true)"
if [[ "$JOB_STATE" != "RUNNING" && "$JOB_STATE" != "COMPLETED" && "$JOB_STATE" != "CDC" ]]; then
  gcloud database-migration migration-jobs demote-destination "$MIGRATION_JOB" --region="$REGION" --quiet || true
fi

echo "Verifying migration job configuration..."
gcloud database-migration migration-jobs verify "$MIGRATION_JOB" --region="$REGION" || true

# When a specific database filter is used, fetch source objects before start.
echo "Fetching source objects for orders..."
gcloud database-migration migration-jobs fetch-source-objects "$MIGRATION_JOB" --region="$REGION" || true

# Try to start the job. If the job is already running, leave it untouched.
JOB_STATE="$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB" --region="$REGION" --format='value(state)' 2>/dev/null || true)"
if [[ "$JOB_STATE" != "RUNNING" && "$JOB_STATE" != "COMPLETED" ]]; then
  echo "Starting continuous migration..."
  gcloud database-migration migration-jobs start "$MIGRATION_JOB" --region="$REGION"
fi

echo
echo "Migration job status:"
gcloud database-migration migration-jobs describe "$MIGRATION_JOB" --region="$REGION" --format='yaml(state,phase,error)'

echo
echo "IMPORTANT: Before the job can connect through VPC peering, the lab may require updating pg_hba.conf with the actual Service Networking peering CIDR shown under VPC Network -> VPC connectivity -> VPC network peering -> servicenetworking-googleapis-com -> Effective routes."
echo "If the job test reports a source-connectivity error, add that CIDR to postgres-vm pg_hba.conf and restart PostgreSQL."

echo

echo "========== TASK 2: PROMOTE =========="
echo "When the migration reaches phase CDC, promote with:"
echo "gcloud database-migration migration-jobs promote $MIGRATION_JOB --region=$REGION"
echo "This is intentionally not auto-promoted, so you can confirm CDC/full replication before cutover."

echo

echo "========== TASK 3: CLOUD SQL IAM AUTH =========="

echo "Patching Cloud SQL authorized networks with postgres-vm public IP..."
CURRENT_NETWORKS="$(gcloud sql instances describe "$DEST_INSTANCE" --format='value(settings.ipConfiguration.authorizedNetworks[].value)' 2>/dev/null | paste -sd, - || true)"
if [[ -n "$CURRENT_NETWORKS" ]]; then
  NEW_NETWORKS="${CURRENT_NETWORKS},${SOURCE_EXTERNAL_IP}/32"
else
  NEW_NETWORKS="${SOURCE_EXTERNAL_IP}/32"
fi

gcloud sql instances patch "$DEST_INSTANCE" --authorized-networks="$NEW_NETWORKS" --quiet

echo "Creating Cloud IAM database user: $IAM_USER"
if ! gcloud sql users describe "$IAM_USER" --instance="$DEST_INSTANCE" >/dev/null 2>&1; then
  gcloud sql users create "$IAM_USER" --instance="$DEST_INSTANCE" --type=cloud_iam_user
else
  echo "IAM database user already exists."
fi

echo "NOTE: Run the following after promotion if the instance is still a migration replica:"
echo "  gcloud sql connect $DEST_INSTANCE --user=postgres --quiet"
echo "  \\c orders"
echo "  GRANT SELECT ON distribution_centers TO \"$IAM_USER\";"

echo

echo "========== TASK 4: ENABLE PITR =========="
echo "Enabling automated backups and 1-day PITR retention..."
gcloud sql instances patch "$DEST_INSTANCE" \
  --backup-start-time=02:00 \
  --enable-point-in-time-recovery \
  --retained-transaction-log-days=1 \
  --quiet

echo "PITR configuration:"
gcloud sql instances describe "$DEST_INSTANCE" --format='yaml(settings.backupConfiguration)'

echo
echo "Creating a UTC checkpoint timestamp now. Make your database change AFTER this timestamp."
PITR_TIMESTAMP="$(date -u --rfc-3339=ns | sed -r 's/ /T/; s/\.([0-9]{3}).*/.\1Z/')"
echo "PITR_TIMESTAMP=$PITR_TIMESTAMP"
echo

echo "To perform the lab's PITR test, insert a row into orders.distribution_centers after the timestamp above, then clone with:"
echo "gcloud sql instances clone $DEST_INSTANCE $PITR_CLONE --point-in-time '$PITR_TIMESTAMP'"
echo

echo "========== TASK 4: EXAMPLE DATA CHANGE =========="
DEST_IP="$(gcloud sql instances describe "$DEST_INSTANCE" --format='value(ipAddresses[0].ipAddress)' 2>/dev/null || true)"
if [[ -n "$DEST_IP" ]]; then
  echo "The lab requires a row to be added after PITR_TIMESTAMP. The exact row values are not specified in the supplied lab text, so this script does not invent one."
  echo "Use:\n  gcloud sql connect $DEST_INSTANCE --user=postgres --quiet"
  echo "Then:\n  \\c orders"
  echo "  INSERT INTO distribution_centers VALUES (-80.20,25.78,'PITR Test Center',9999);"
  echo "Then clone to $PITR_CLONE using the timestamp printed above."
fi

echo
echo "========== DONE =========="
echo "CLI setup for Tasks 1-4 is complete as far as the current project state allows."
echo "Confirm the migration reaches CDC, promote the migration, grant IAM SELECT, perform the PITR test, then use Check my progress."
