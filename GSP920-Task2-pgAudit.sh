#!/bin/bash
# GSP920 - Task 2: Enable/configure pgAudit and run all 3 SELECT queries
# Cloud Console steps still required:
#   IAM & Admin -> Audit Logs -> Cloud SQL -> enable Admin read, Data read, Data write -> Save
#
# This script is safe to re-run for the main setup steps.

set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
CLOUDSQL_INSTANCE="postgres-orders"
SOURCE_BUCKET="gs://spls/gsp920"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  echo "ERROR: No active Google Cloud project is configured."
  exit 1
fi

command -v gcloud >/dev/null || { echo "ERROR: gcloud not found."; exit 1; }
command -v psql >/dev/null || { echo "ERROR: psql not found."; exit 1; }

if ! gcloud sql instances describe "$CLOUDSQL_INSTANCE" >/dev/null 2>&1; then
  echo "ERROR: Cloud SQL instance '$CLOUDSQL_INSTANCE' does not exist."
  exit 1
fi

echo "[1/8] Enabling pgAudit flags..."
gcloud sql instances patch "$CLOUDSQL_INSTANCE" \
  --database-flags=cloudsql.enable_pgaudit=on,pgaudit.log=all

echo "[2/8] Restarting Cloud SQL instance..."
gcloud sql instances restart "$CLOUDSQL_INSTANCE"

echo "Waiting for Cloud SQL instance to become RUNNABLE..."
until [[ "$(gcloud sql instances describe "$CLOUDSQL_INSTANCE" --format='value(state)')" == "RUNNABLE" ]]; do
  sleep 10
done

echo "Cloud SQL instance is RUNNABLE."

echo "[3/8] Getting Cloud SQL IP..."
POSTGRESQL_IP="$(gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --format='value(ipAddresses[0].ipAddress)')"
echo "Cloud SQL IP: $POSTGRESQL_IP"

export PGPASSWORD='supersecret!'

if ! gcloud sql databases describe orders --instance="$CLOUDSQL_INSTANCE" >/dev/null 2>&1; then
  echo "[4/8] Creating orders database..."
  gcloud sql databases create orders --instance="$CLOUDSQL_INSTANCE"
else
  echo "[4/8] orders database already exists."
fi

echo "[5/8] Creating/enabling pgAudit configuration..."
psql "sslmode=disable user=postgres hostaddr=${POSTGRESQL_IP}" -d orders <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgaudit;
ALTER DATABASE orders SET pgaudit.log = 'read,write';
SQL

echo "[6/8] Downloading lab data and population script..."
gcloud storage cp "${SOURCE_BUCKET}/create_orders_db.sql" .
gcloud storage cp "${SOURCE_BUCKET}/DDL/distribution_centers_data.csv" .
gcloud storage cp "${SOURCE_BUCKET}/DDL/inventory_items_data.csv" .
gcloud storage cp "${SOURCE_BUCKET}/DDL/order_items_data.csv" .
gcloud storage cp "${SOURCE_BUCKET}/DDL/products_data.csv" .
gcloud storage cp "${SOURCE_BUCKET}/DDL/users_data.csv" .

echo "Populating orders database..."
psql "sslmode=disable user=postgres hostaddr=${POSTGRESQL_IP}" \
  -d postgres \
  -f create_orders_db.sql

echo "[7/8] Configuring relation-level auditing and running all 3 SELECT queries..."
psql "sslmode=disable user=postgres hostaddr=${POSTGRESQL_IP}" -d orders <<'SQL'
CREATE ROLE auditor WITH NOLOGIN;
ALTER DATABASE orders SET pgaudit.role = 'auditor';
GRANT SELECT ON order_items TO auditor;

-- Query 1: Summary of orders by users
SELECT
    users.id AS users_id,
    users.first_name AS users_first_name,
    users.last_name AS users_last_name,
    COUNT(DISTINCT order_items.order_id) AS order_items_order_count,
    COALESCE(SUM(order_items.sale_price), 0) AS order_items_total_revenue
FROM order_items
LEFT JOIN users ON order_items.user_id = users.id
GROUP BY 1, 2, 3
ORDER BY 4 DESC
LIMIT 500;

-- Query 2: Summary by individual product
SELECT
    products.id AS products_id,
    products.name AS products_name,
    products.sku AS products_sku,
    products.cost AS products_cost,
    products.retail_price AS products_retail_price,
    products.distribution_center_id AS products_distribution_center_id,
    COUNT(DISTINCT order_items.order_id) AS order_items_order_count,
    COALESCE(SUM(order_items.sale_price), 0) AS order_items_total_revenue
FROM order_items
LEFT JOIN inventory_items ON order_items.inventory_item_id = inventory_items.id
LEFT JOIN products ON inventory_items.product_id = products.id
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY 7 DESC
LIMIT 500;

-- Query 3: Orders by distribution center
SELECT
    order_items.order_id AS order_id,
    distribution_centers.id AS distribution_centers_id,
    distribution_centers.name AS distribution_centers_name,
    distribution_centers.latitude AS distribution_centers_latitude,
    distribution_centers.longitude AS distribution_centers_longitude
FROM order_items
LEFT JOIN inventory_items ON order_items.inventory_item_id = inventory_items.id
LEFT JOIN products ON inventory_items.product_id = products.id
LEFT JOIN distribution_centers ON products.distribution_center_id = distribution_centers.id
GROUP BY 1, 2, 3, 4, 5
ORDER BY 2
LIMIT 500;
SQL

unset PGPASSWORD

echo "[8/8] Setup and queries completed."
echo

echo "NEXT: In Cloud Console enable Cloud SQL Data Access audit logs:"
echo "  IAM & Admin -> Audit Logs -> Cloud SQL -> Admin read + Data read + Data write -> Save"
echo

echo "Then verify pgAudit entries from Cloud Shell with:"
echo "gcloud logging read \"resource.type=cloudsql_database AND logName=projects/${PROJECT_ID}/logs/cloudaudit.googleapis.com%2Fdata_access AND protoPayload.request.@type=type.googleapis.com/google.cloud.sql.audit.v1.PgAuditEntry\" --project=${PROJECT_ID} --limit=20 --format='table(timestamp,protoPayload.request.@type)'"
