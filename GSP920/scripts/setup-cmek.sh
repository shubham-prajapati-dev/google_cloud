#!/usr/bin/env bash
set -euo pipefail

export PROJECT_ID="$(gcloud config list --format='value(core.project)')"
export KMS_KEYRING_ID="cloud-sql-keyring"
export KMS_KEY_ID="cloud-sql-key"
export CLOUDSQL_INSTANCE="postgres-orders"

export ZONE="$(gcloud compute instances list --filter='NAME=bastion-vm' --format=json | jq -r .[].zone | awk -F '/zones/' '{print $NF}')"
export REGION="${ZONE::-2}"

gcloud beta services identity create \
  --service=sqladmin.googleapis.com \
  --project="$PROJECT_ID"

gcloud kms keyrings create "$KMS_KEYRING_ID" \
  --location="$REGION"

gcloud kms keys create "$KMS_KEY_ID" \
  --location="$REGION" \
  --keyring="$KMS_KEYRING_ID" \
  --purpose=encryption

export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

gcloud kms keys add-iam-policy-binding "$KMS_KEY_ID" \
  --location="$REGION" \
  --keyring="$KMS_KEYRING_ID" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-cloud-sql.iam.gserviceaccount.com" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter

export AUTHORIZED_IP="$(gcloud compute instances describe bastion-vm \
  --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs.natIP)')"
export CLOUD_SHELL_IP="$(curl -s ifconfig.me)"
export KEY_NAME="$(gcloud kms keys describe "$KMS_KEY_ID" \
  --keyring="$KMS_KEYRING_ID" \
  --location="$REGION" \
  --format='value(name)')"

# Supply the active lab password via an environment variable.
: "${ROOT_PASSWORD:?Set ROOT_PASSWORD to the temporary lab password before running this script}"

gcloud sql instances create "$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" \
  --authorized-networks="${AUTHORIZED_IP}/32,${CLOUD_SHELL_IP}/32" \
  --disk-encryption-key="$KEY_NAME" \
  --database-version=POSTGRES_14 \
  --cpu=1 \
  --memory=3840MB \
  --region="$REGION" \
  --root-password="$ROOT_PASSWORD"

echo "CMEK-protected Cloud SQL instance created: $CLOUDSQL_INSTANCE"
