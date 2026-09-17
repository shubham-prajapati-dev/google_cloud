#!/bin/bash

# GSP919 - Cloud SQL for PostgreSQL with GKE
# Automates the Cloud Shell steps from Tasks 1-4.
# Task 4's final psql verification still needs the Cloud SQL console's
# "Open Cloud Shell" connection command because the lab supplies that command dynamically.

set -e

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
ZONE="us-east1-d"
REGION="us-east1"
CLOUDSQL_SERVICE_ACCOUNT="cloudsql-service-account"
REPO="gmemegen"
APP_DIR="$HOME/gmemegen"

if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  echo "ERROR: No Google Cloud project is configured. Start the lab and run gcloud auth/config first."
  exit 1
fi

echo "==> Using project: $PROJECT_ID"
gcloud config set compute/zone "$ZONE"
gcloud config set compute/region "$REGION"

# -----------------------------------------------------------------------------
# Task 1: Enable APIs and create Cloud SQL service account
# -----------------------------------------------------------------------------
echo "==> Task 1: Enabling Artifact Registry API..."
gcloud services enable artifactregistry.googleapis.com

echo "==> Task 1: Creating Cloud SQL service account..."
if ! gcloud iam service-accounts describe \
  "$CLOUDSQL_SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$CLOUDSQL_SERVICE_ACCOUNT" --project="$PROJECT_ID"
fi

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$CLOUDSQL_SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/cloudsql.admin" >/dev/null

KEY_FILE="$HOME/$CLOUDSQL_SERVICE_ACCOUNT.json"
if [ ! -f "$KEY_FILE" ]; then
  gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$CLOUDSQL_SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
    --project="$PROJECT_ID"
else
  echo "==> Service-account key already exists: $KEY_FILE"
fi

# -----------------------------------------------------------------------------
# Task 2: Create GKE cluster and Kubernetes secrets
# -----------------------------------------------------------------------------
echo "==> Task 2: Creating GKE cluster..."
if ! gcloud container clusters describe postgres-cluster --zone="$ZONE" >/dev/null 2>&1; then
  gcloud container clusters create postgres-cluster \
    --zone="$ZONE" \
    --num-nodes=2
else
  echo "==> GKE cluster postgres-cluster already exists."
fi

gcloud container clusters get-credentials postgres-cluster --zone="$ZONE" --project="$PROJECT_ID"

echo "==> Task 2: Creating Kubernetes secrets..."
if ! kubectl get secret cloudsql-instance-credentials >/dev/null 2>&1; then
  kubectl create secret generic cloudsql-instance-credentials \
    --from-file=credentials.json="$KEY_FILE"
else
  echo "==> cloudsql-instance-credentials already exists."
fi

if ! kubectl get secret cloudsql-db-credentials >/dev/null 2>&1; then
  kubectl create secret generic cloudsql-db-credentials \
    --from-literal=username=postgres \
    --from-literal=password='supersecret!' \
    --from-literal=dbname=gmemegen_db
else
  echo "==> cloudsql-db-credentials already exists."
fi

# -----------------------------------------------------------------------------
# Build and push the application image
# -----------------------------------------------------------------------------
echo "==> Downloading gMemegen application..."
if [ ! -d "$APP_DIR" ]; then
  gcloud storage cp -r gs://spls/gsp919/gmemegen "$HOME/"
fi
cd "$APP_DIR"

echo "==> Configuring Docker authentication..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

echo "==> Creating Artifact Registry repository if needed..."
if ! gcloud artifacts repositories describe "$REPO" --location="$REGION" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$REPO" \
    --repository-format=docker \
    --location="$REGION"
fi

echo "==> Building application image..."
docker build -t "${REGION}-docker.pkg.dev/${PROJECT_ID}/gmemegen/gmemegen-app:v1" .

echo "==> Pushing application image..."
docker push "${REGION}-docker.pkg.dev/${PROJECT_ID}/gmemegen/gmemegen-app:v1"

# -----------------------------------------------------------------------------
# Configure and deploy the Kubernetes manifest
# -----------------------------------------------------------------------------
echo "==> Configuring gmemegen_deployment.yaml..."
DEPLOYMENT_FILE="$APP_DIR/gmemegen_deployment.yaml"

if [ ! -f "$DEPLOYMENT_FILE" ]; then
  echo "ERROR: $DEPLOYMENT_FILE was not found."
  exit 1
fi

# Replace the placeholders required by the lab. This preserves the rest of
# Google's supplied manifest instead of rebuilding it from scratch.
sed -i \
  -e "s#\${REGION}#${REGION}#g" \
  -e "s#\${PROJECT_ID}#${PROJECT_ID}#g" \
  "$DEPLOYMENT_FILE"

# The supplied manifest contains the Cloud SQL connection name. Make sure the
# expected lab instance/region is used if the placeholder form is present.
sed -i "s#PROJECT_ID:REGION:CLOUD_SQL_INSTANCE_ID#${PROJECT_ID}:${REGION}:postgres-gmemegen#g" "$DEPLOYMENT_FILE"

# The lab expects the deployment to be created from this manifest.
echo "==> Deploying gMemegen application..."
kubectl create -f "$DEPLOYMENT_FILE" 2>/dev/null || kubectl apply -f "$DEPLOYMENT_FILE"

echo "==> Waiting for gMemegen pod to become ready..."
kubectl rollout status deployment/gmemegen --timeout=180s || true
kubectl get pods

# -----------------------------------------------------------------------------
# Task 3: Expose application through a LoadBalancer
# -----------------------------------------------------------------------------
echo "==> Task 3: Creating LoadBalancer service..."
if ! kubectl get service gmemegen >/dev/null 2>&1; then
  kubectl expose deployment gmemegen \
    --type="LoadBalancer" \
    --port 80 \
    --target-port 8080
else
  echo "==> LoadBalancer service gmemegen already exists."
fi

echo "==> Waiting for external LoadBalancer IP..."
for i in {1..30}; do
  LOAD_BALANCER_IP="$(kubectl get svc gmemegen -o=jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [ -n "$LOAD_BALANCER_IP" ]; then
    break
  fi
  sleep 10
done

if [ -n "$LOAD_BALANCER_IP" ]; then
  echo "=============================================="
  echo "gMemegen Load Balancer: http://$LOAD_BALANCER_IP"
  echo "=============================================="
else
  echo "Load Balancer IP is not ready yet. Run:"
  echo "kubectl describe service gmemegen"
fi

# Show application activity, as requested by the lab.
echo "==> Current gMemegen pod logs:"
POD_NAME="$(kubectl get pods --output=json | jq -r '.items[0].metadata.name' 2>/dev/null || true)"
if [ -n "$POD_NAME" ] && [ "$POD_NAME" != "null" ]; then
  kubectl logs "$POD_NAME" gmemegen 2>/dev/null | grep "INFO" || true
fi

cat <<'EOF'

============================================================
GSP919 automation reached the final verification stage.

Task 4 manual verification:
1. Google Cloud Console -> Databases -> SQL.
2. Open the postgres-gmemegen instance.
3. In Overview, click "Open Cloud Shell" under "Connect to this instance".
4. Run the auto-populated command.
5. Password: supersecret!
6. At postgres=> run: \c gmemegen_db
7. Password: supersecret!
8. At gmemegen_db=> run: select * from meme;
9. Create at least one meme in the gMemegen web app first so the table
   contains data.
============================================================
EOF
