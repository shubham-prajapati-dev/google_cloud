#!/bin/bash
set -Eeuo pipefail
trap 'echo "ERROR: command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || { echo "ERROR: Set the lab project first."; exit 1; }
DEFAULT_REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"
DEFAULT_ZONE="$(gcloud config get-value compute/zone 2>/dev/null || true)"
[[ "$DEFAULT_REGION" == "(unset)" ]] && DEFAULT_REGION=""
[[ "$DEFAULT_ZONE" == "(unset)" ]] && DEFAULT_ZONE=""
DEFAULT_REGION="${DEFAULT_REGION:-us-central1}"
DEFAULT_ZONE="${DEFAULT_ZONE:-us-central1-a}"

echo "============================================================"
echo " GSP216 - SQL: BigQuery and Cloud SQL"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo
read -r -p "Enter Region [$DEFAULT_REGION]: " REGION
REGION="${REGION:-$DEFAULT_REGION}"
read -r -p "Enter Lab Zone [$DEFAULT_ZONE]: " ZONE
ZONE="${ZONE:-$DEFAULT_ZONE}"
BQ_LOCATION="US"
BUCKET="$PROJECT_ID"
SQL_INSTANCE="my-demo"
SQL_PASSWORD='ChangeMe1!'
DATASET="gsp216_sql"
START_TABLE="start_station_counts"
END_TABLE="end_station_counts"
START_CSV="start_station_data.csv"
END_CSV="end_station_data.csv"
exists() { "$@" >/dev/null 2>&1; }

printf '\nRegion: %s\nZone: %s\n\n' "$REGION" "$ZONE"
read -r -p "Continue? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

echo "Validating project, region and zone..."
gcloud projects describe "$PROJECT_ID" >/dev/null
gcloud compute regions describe "$REGION" >/dev/null
gcloud compute zones describe "$ZONE" >/dev/null
gcloud config set compute/region "$REGION" >/dev/null
gcloud config set compute/zone "$ZONE" >/dev/null

echo
echo "[BIGQUERY] Running the lab queries..."
if ! exists bq show "${PROJECT_ID}:${DATASET}"; then
  bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$DATASET"
fi
bq query --use_legacy_sql=false --location="$BQ_LOCATION" --replace --destination_table="$PROJECT_ID:$DATASET.$START_TABLE" 'SELECT start_station_name, COUNT(*) AS num FROM `bigquery-public-data.london_bicycles.cycle_hire` GROUP BY start_station_name ORDER BY num DESC'
bq query --use_legacy_sql=false --location="$BQ_LOCATION" --replace --destination_table="$PROJECT_ID:$DATASET.$END_TABLE" 'SELECT end_station_name, COUNT(*) AS num FROM `bigquery-public-data.london_bicycles.cycle_hire` GROUP BY end_station_name ORDER BY num DESC'
echo "✓ BigQuery query results created"

echo
echo "[STORAGE] Creating bucket and exporting CSV files..."
if exists gcloud storage buckets describe "gs://$BUCKET"; then
  echo "✓ Bucket exists: $BUCKET"
else
  gcloud storage buckets create "gs://$BUCKET" --location=US
fi
if exists gcloud storage objects describe "gs://$BUCKET/$START_CSV"; then gcloud storage rm "gs://$BUCKET/$START_CSV" --quiet; fi
if exists gcloud storage objects describe "gs://$BUCKET/$END_CSV"; then gcloud storage rm "gs://$BUCKET/$END_CSV" --quiet; fi
bq extract --location="$BQ_LOCATION" --destination_format=CSV --print_header=true "$PROJECT_ID:$DATASET.$START_TABLE" "gs://$BUCKET/$START_CSV"
bq extract --location="$BQ_LOCATION" --destination_format=CSV --print_header=true "$PROJECT_ID:$DATASET.$END_TABLE" "gs://$BUCKET/$END_CSV"
echo "✓ CSV files exported"

echo
echo "[CLOUD SQL] Creating MySQL instance..."
if exists gcloud sql instances describe "$SQL_INSTANCE"; then
  echo "✓ Cloud SQL instance exists: $SQL_INSTANCE"
else
  gcloud sql instances create "$SQL_INSTANCE" --database-version=MYSQL_8_0 --edition=ENTERPRISE --tier=db-custom-4-16384 --storage-type=SSD --storage-size=100 --availability-type=REGIONAL --zone="$ZONE" --root-password="$SQL_PASSWORD"
fi
for i in {1..36}; do
  STATE="$(gcloud sql instances describe "$SQL_INSTANCE" --format='value(state)')"
  [[ "$STATE" == "RUNNABLE" ]] && break
  echo "Waiting for Cloud SQL instance... state=$STATE"
  sleep 10
done
STATE="$(gcloud sql instances describe "$SQL_INSTANCE" --format='value(state)')"
[[ "$STATE" == "RUNNABLE" ]] || { echo "ERROR: Cloud SQL instance did not become RUNNABLE." >&2; exit 1; }
echo "✓ Cloud SQL instance is RUNNABLE"

echo
echo "[CLOUD SQL] Creating database and tables..."
if gcloud sql databases list --instance="$SQL_INSTANCE" --format='value(name)' | grep -qx 'bike'; then
  echo "✓ Database exists: bike"
else
  gcloud sql databases create bike --instance="$SQL_INSTANCE"
fi
SQL_SA="$(gcloud sql instances describe "$SQL_INSTANCE" --format='value(serviceAccountEmailAddress)')"
[[ -n "$SQL_SA" ]] || { echo "ERROR: Could not determine Cloud SQL service account." >&2; exit 1; }
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member="serviceAccount:$SQL_SA" --role="roles/storage.objectViewer" >/dev/null
export MYSQL_PWD="$SQL_PASSWORD"
gcloud sql connect "$SQL_INSTANCE" --user=root --quiet <<'SQL'
USE bike;
CREATE TABLE IF NOT EXISTS london1 (start_station_name VARCHAR(255), num INT);
CREATE TABLE IF NOT EXISTS london2 (end_station_name VARCHAR(255), num INT);
SQL

echo
echo "[CLOUD SQL] Importing CSV files..."
gcloud sql import csv "gs://$BUCKET/$START_CSV" "$SQL_INSTANCE" --database=bike --table=london1 --quiet
gcloud sql import csv "gs://$BUCKET/$END_CSV" "$SQL_INSTANCE" --database=bike --table=london2 --quiet
echo "✓ CSV files imported"

echo
echo "[CLOUD SQL] Running final lab queries..."
gcloud sql connect "$SQL_INSTANCE" --user=root --quiet <<'SQL'
USE bike;
DELETE FROM london1 WHERE num=0;
DELETE FROM london2 WHERE num=0;
INSERT INTO london1 (start_station_name, num) VALUES ("test destination", 1);
SELECT start_station_name AS top_stations, num FROM london1 WHERE num>100000
UNION
SELECT end_station_name, num FROM london2 WHERE num>100000
ORDER BY top_stations DESC;
SQL
unset MYSQL_PWD

echo
echo "============================================================"
echo " SUCCESS - GSP216 SQL lab configured"
echo "============================================================"
echo "Project:       $PROJECT_ID"
echo "Bucket:        gs://$BUCKET"
echo "Cloud SQL:     $SQL_INSTANCE"
echo "Database:      bike"
echo "Tables:        london1, london2"
echo
echo "Now click 'Check my progress' in the lab."
echo "============================================================"
