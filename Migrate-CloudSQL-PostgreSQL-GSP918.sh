#!/bin/bash

# GSP918 - Migrate to Cloud SQL for PostgreSQL Using Database Migration Service
# Human-friendly automation for Cloud Shell.
# Covers Tasks 1-4 as far as the Google Cloud CLI permits.
# Lab UI may still be required for Check my progress / waiting for CDC.

set -u

REGION="us-east1"
ZONE="us-east1-d"
VM_NAME="postgresql-vm"
SOURCE_PROFILE="postgres-vm"
DEST_PROFILE="postgresql-cloudsql-dest"
MIGRATION_JOB="vm-to-cloudsql"
DEST_INSTANCE="postgresql-cloudsql"
MIGRATION_USER="migration_admin"
MIGRATION_PASSWORD="${MIGRATION_PASSWORD:-DMS_1s_cool!}"
CLOUDSQL_PASSWORD="${CLOUDSQL_PASSWORD:-supersecret!}"

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  echo "ERROR: No Google Cloud project is configured."
  exit 1
fi

log() { echo; echo "============================================================"; echo "$1"; echo "============================================================"; }

run() {
  echo "+ $*"
  "$@"
}

log "GSP918 | Project: $PROJECT_ID"

log "TASK 0 | Enable required APIs"
run gcloud services enable datamigration.googleapis.com servicenetworking.googleapis.com sqladmin.googleapis.com compute.googleapis.com

log "TASK 1 | Prepare PostgreSQL source VM"

SOURCE_INTERNAL_IP="$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --format='value(networkInterfaces[0].networkIP)')"
if [[ -z "$SOURCE_INTERNAL_IP" ]]; then
  echo "ERROR: Could not find internal IP for $VM_NAME"
  exit 1
fi

echo "Source internal IP: $SOURCE_INTERNAL_IP"

# Install pglogical and configure logical replication on the source VM.
run gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="sudo apt-get update && sudo apt-get install -y postgresql-14-pglogical"

run gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="sudo bash -c 'cat << \"EOF\" >> /etc/postgresql/14/main/postgresql.conf
shared_preload_libraries = '\''pglogical'\''
output_plugin_libraries = '\''pglogical_output'\''
wal_level = logical
max_worker_processes = 10
max_replication_slots = 10
max_wal_senders = 10
listen_addresses = '\''*'\''
EOF
sudo bash -c \"echo 'host all all 0.0.0.0/0 md5' >> /etc/postgresql/14/main/pg_hba.conf\"
sudo bash -c \"echo 'host replication all 0.0.0.0/0 md5' >> /etc/postgresql/14/main/pg_hba.conf\"
sudo systemctl restart postgresql@14-main"

# Create migration user, extensions and privileges.
run gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="sudo -u postgres psql << 'EOF'
CREATE USER $MIGRATION_USER PASSWORD '$MIGRATION_PASSWORD';
ALTER ROLE $MIGRATION_USER WITH REPLICATION;
ALTER DATABASE orders OWNER TO $MIGRATION_USER;
EOF
for db in postgres orders gmemegen_db; do
  sudo -u postgres psql -d \"\$db\" << 'EOF'
CREATE EXTENSION IF NOT EXISTS pglogical;
GRANT USAGE ON SCHEMA pglogical TO $MIGRATION_USER;
GRANT ALL ON SCHEMA pglogical TO $MIGRATION_USER;
GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO $MIGRATION_USER;
GRANT USAGE ON SCHEMA public TO $MIGRATION_USER;
GRANT ALL ON SCHEMA public TO $MIGRATION_USER;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO $MIGRATION_USER;
EOF
done
sudo -u postgres psql -d orders << 'EOF'
ALTER TABLE public.distribution_centers OWNER TO $MIGRATION_USER;
ALTER TABLE public.inventory_items OWNER TO $MIGRATION_USER;
ALTER TABLE public.order_items OWNER TO $MIGRATION_USER;
ALTER TABLE public.products OWNER TO $MIGRATION_USER;
ALTER TABLE public.users OWNER TO $MIGRATION_USER;
EOF"

log "TASK 1 | Verify source PostgreSQL configuration"
run gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="sudo -u postgres psql -c \"SHOW shared_preload_libraries; SHOW wal_level;\""
run gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="for db in postgres orders gmemegen_db; do echo === \$db ===; sudo -u postgres psql -d \"\$db\" -c '\dx pglogical'; done"
run gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="sudo -u postgres psql -d orders -c \"SELECT pg_create_logical_replication_slot('dms_verify_slot', 'pglogical_output'); SELECT pg_drop_replication_slot('dms_verify_slot');\""

log "TASK 2 | Create source connection profile"
if ! gcloud database-migration connection-profiles describe "$SOURCE_PROFILE" --region="$REGION" >/dev/null 2>&1; then
  run gcloud database-migration connection-profiles create postgresql "$SOURCE_PROFILE" \
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

log "TASK 2 | Create destination connection profile"
if ! gcloud database-migration connection-profiles describe "$DEST_PROFILE" --region="$REGION" >/dev/null 2>&1; then
  run gcloud database-migration connection-profiles create postgresql "$DEST_PROFILE" \
    --region="$REGION" \
    --role=DESTINATION \
    --cloudsql-instance="$DEST_INSTANCE" \
    --no-async
else
  echo "Destination connection profile already exists: $DEST_PROFILE"
fi

log "TASK 2 | Create continuous migration job"
if ! gcloud database-migration migration-jobs describe "$MIGRATION_JOB" --region="$REGION" >/dev/null 2>&1; then
  run gcloud database-migration migration-jobs create "$MIGRATION_JOB" \
    --region="$REGION" \
    --display-name="vm-to-cloudsql" \
    --type=CONTINUOUS \
    --source="$SOURCE_PROFILE" \
    --destination="$DEST_PROFILE" \
    --use-postgres-native \
    --postgres-max-additional-subscriptions=10 \
    --all-databases \
    --peer-vpc="projects/$PROJECT_ID/global/networks/default" \
    --no-async
else
  echo "Migration job already exists: $MIGRATION_JOB"
fi

log "TASK 2 | Demote destination and verify migration job"
# DMS requires the existing Cloud SQL destination to be demoted before starting.
JOB_STATE="$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB" --region="$REGION" --format='value(state)' 2>/dev/null || true)"
if [[ "$JOB_STATE" != "RUNNING" && "$JOB_STATE" != "CDC" && "$JOB_STATE" != "COMPLETED" ]]; then
  run gcloud database-migration migration-jobs demote-destination "$MIGRATION_JOB" --region="$REGION"
  sleep 15
  if gcloud database-migration migration-jobs verify "$MIGRATION_JOB" --region="$REGION"; then
    echo "Migration job verification passed."
  else
    echo "WARNING: DMS verify returned a non-zero status. Review the job details before starting."
  fi
fi

log "TASK 2 | Start migration job"
JOB_STATE="$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB" --region="$REGION" --format='value(state)' 2>/dev/null || true)"
if [[ "$JOB_STATE" != "RUNNING" && "$JOB_STATE" != "COMPLETED" ]]; then
  run gcloud database-migration migration-jobs start "$MIGRATION_JOB" --region="$REGION"
fi

log "TASK 2 | Current migration status"
gcloud database-migration migration-jobs describe "$MIGRATION_JOB" --region="$REGION" \
  --format='yaml(name,state,phase,source,destination)'

echo
echo "IMPORTANT: Wait until the migration job phase becomes CDC before Task 3/4."
echo "The lab's Check my progress can then be used for Task 2."

log "TASK 3 | Check migrated databases"
if command -v gcloud >/dev/null 2>&1; then
  echo "Connect to Cloud SQL with:"
  echo "  gcloud sql connect $DEST_INSTANCE --user=postgres --quiet"
  echo
  echo "Then run:"
  echo "  \\c orders;"
  echo "  select * from distribution_centers;"
fi

log "TASK 3 | Test continuous replication"
if command -v psql >/dev/null 2>&1; then
  POSTGRESQL_IP="$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"
  echo "Source public IP: $POSTGRESQL_IP"
  echo "To test the live migration, run:"
  echo "  PGPASSWORD='$MIGRATION_PASSWORD' psql -h $POSTGRESQL_IP -p 5432 -d orders -U $MIGRATION_USER"
  echo "  \\c orders;"
  echo "  insert into distribution_centers values(-80.1918,25.7617,'Miami FL',11);"
  echo "  \\q"
fi

echo
echo "After inserting Miami FL, reconnect to Cloud SQL and run:"
echo "  gcloud sql connect $DEST_INSTANCE --user=postgres --quiet"
echo "  \\c orders;"
echo "  select * from distribution_centers;"
echo "The new Miami FL row should appear after CDC catches up."

log "TASK 4 | Promote Cloud SQL after CDC"
CURRENT_PHASE="$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB" --region="$REGION" --format='value(phase)' 2>/dev/null || true)"
if [[ "$CURRENT_PHASE" == "CDC" ]]; then
  echo "CDC reached. Promoting destination to standalone..."
  run gcloud database-migration migration-jobs promote "$MIGRATION_JOB" --region="$REGION"
else
  echo "Current phase: ${CURRENT_PHASE:-unknown}"
  echo "Do NOT promote yet. Wait until the migration job reaches CDC."
  echo "Then run:"
  echo "  gcloud database-migration migration-jobs promote $MIGRATION_JOB --region=$REGION"
fi

log "GSP918 COMPLETE / NEXT CHECKS"
echo "1. Task 1: Check source preparation."
echo "2. Task 2: Check migration job after it reaches CDC."
echo "3. Task 3: Verify distribution_centers and the Miami FL row."
echo "4. Task 4: Promote when phase is CDC, then Check my progress."
echo
