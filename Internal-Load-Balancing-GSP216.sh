#!/bin/bash
set -Eeuo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# GSP216 - Enhance Application Reliability and Scalability with Internal Load Balancing
# Automates Tasks 1-3 and prepares the environment for Task 4 verification.
# No inline --metadata is used; startup script is supplied with --metadata-from-file.

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || {
  echo "ERROR: No active Google Cloud project. Run: gcloud config set project PROJECT_ID"
  exit 1
}

DEFAULT_REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"
[[ "$DEFAULT_REGION" == "(unset)" ]] && DEFAULT_REGION=""
DEFAULT_REGION="${DEFAULT_REGION:-asia-south1}"
DEFAULT_ZONE1="${DEFAULT_ZONE1:-asia-south1-a}"
DEFAULT_ZONE2="asia-south1-b"

NETWORK="my-internal-app"
SUBNET1="subnet-a"
SUBNET2="subnet-b"
TAG="lb-backend"
TEMPLATE1="instance-template-1"
TEMPLATE2="instance-template-2"
MIG1="instance-group-1"
MIG2="instance-group-2"
HEALTH_CHECK="my-ilb-health-check"
BACKEND_SERVICE="my-ilb-backend"
ILB="my-ilb"
ILB_IP_NAME="my-ilb-ip"
ILB_IP="10.10.30.5"
UTILITY="utility-vm"
UTILITY_IP="10.10.20.50"

cat <<'BANNER'
============================================================
 GSP216 - Internal Load Balancing
============================================================
This script automates the lab resources from Tasks 1-3.
============================================================
BANNER

echo "Project: $PROJECT_ID"
read -r -p "Region [$DEFAULT_REGION]: " REGION
REGION="${REGION:-$DEFAULT_REGION}"
read -r -p "Zone for instance-group-1 [$DEFAULT_ZONE1]: " ZONE1
ZONE1="${ZONE1:-$DEFAULT_ZONE1}"
read -r -p "Different zone for instance-group-2 [$DEFAULT_ZONE2]: " ZONE2
ZONE2="${ZONE2:-$DEFAULT_ZONE2}"

[[ "$ZONE1" != "$ZONE2" ]] || { echo "ERROR: Zone 1 and Zone 2 must be different."; exit 1; }

case "$REGION" in
  asia-south1) ;;
  *) echo "WARNING: The lab guide specifies region asia-south1; you entered $REGION." ;;
esac

ZONE1_REGION="$(gcloud compute zones describe "$ZONE1" --format='value(region.basename())')"
ZONE2_REGION="$(gcloud compute zones describe "$ZONE2" --format='value(region.basename())')"
[[ "$ZONE1_REGION" == "$REGION" && "$ZONE2_REGION" == "$REGION" ]] || {
  echo "ERROR: Both zones must belong to $REGION."; exit 1;
}

gcloud compute networks describe "$NETWORK" >/dev/null
gcloud compute networks subnets describe "$SUBNET1" --region="$REGION" >/dev/null
gcloud compute networks subnets describe "$SUBNET2" --region="$REGION" >/dev/null

gcloud config set compute/region "$REGION" >/dev/null
gcloud config set compute/zone "$ZONE1" >/dev/null

exists() { "$@" >/dev/null 2>&1; }

# ------------------------------------------------------------------
# Task 1: Firewall rules
# ------------------------------------------------------------------
echo
echo "[1/4] Configuring firewall rules..."

if exists gcloud compute firewall-rules describe app-allow-http; then
  echo "  ✓ app-allow-http already exists"
else
  gcloud compute firewall-rules create app-allow-http \
    --network="$NETWORK" \
    --target-tags="$TAG" \
    --source-ranges=10.10.0.0/16 \
    --allow=tcp:80 \
    --quiet
  echo "  ✓ app-allow-http created"
fi

if exists gcloud compute firewall-rules describe app-allow-health-check; then
  echo "  ✓ app-allow-health-check already exists"
else
  gcloud compute firewall-rules create app-allow-health-check \
    --network="$NETWORK" \
    --target-tags="$TAG" \
    --source-ranges=130.211.0.0/22,35.191.0.0/16 \
    --allow=tcp \
    --quiet
  echo "  ✓ app-allow-health-check created"
fi

# ------------------------------------------------------------------
# Startup script for both instance templates.
# ------------------------------------------------------------------
STARTUP="$(mktemp)"
trap 'rm -f "$STARTUP"' EXIT
cat > "$STARTUP" <<'STARTUP_EOF'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apache2 php libapache2-mod-php
cat > /var/www/html/index.php <<'PHP_EOF'
<h1>Internal Load Balancing Lab</h1>
<h2>Client IP</h2>
Your IP address : <?php echo $_SERVER['REMOTE_ADDR']; ?>
<h2>Hostname</h2>
Server Hostname: <?php echo gethostname(); ?>
<h2>Server Location</h2>
Region and Zone: <?php
  $ch = curl_init();
  curl_setopt($ch, CURLOPT_URL, "http://metadata.google.internal/computeMetadata/v1/instance/zone");
  curl_setopt($ch, CURLOPT_HTTPHEADER, array('Metadata-Flavor: Google'));
  curl_setopt($ch, CURLOPT_RETURNTRANSFER, 1);
  $zone = curl_exec($ch);
  $parts = explode('/', $zone);
  echo end($parts);
?>
PHP_EOF
rm -f /var/www/html/index.html
systemctl enable apache2
systemctl restart apache2
STARTUP_EOF

# ------------------------------------------------------------------
# Task 2: Instance templates
# ------------------------------------------------------------------
echo
echo "[2/4] Creating instance templates..."

if exists gcloud compute instance-templates describe "$TEMPLATE1"; then
  echo "  ✓ $TEMPLATE1 already exists"
else
  gcloud compute instance-templates create "$TEMPLATE1" \
    --machine-type=e2-micro \
    --network="$NETWORK" \
    --subnet="$SUBNET1" \
    --no-address \
    --tags="$TAG" \
    --metadata-from-file=startup-script="$STARTUP" \
    --quiet
  echo "  ✓ $TEMPLATE1 created for $SUBNET1"
fi

if exists gcloud compute instance-templates describe "$TEMPLATE2"; then
  echo "  ✓ $TEMPLATE2 already exists"
else
  gcloud compute instance-templates create "$TEMPLATE2" \
    --machine-type=e2-micro \
    --network="$NETWORK" \
    --subnet="$SUBNET2" \
    --no-address \
    --tags="$TAG" \
    --metadata-from-file=startup-script="$STARTUP" \
    --quiet
  echo "  ✓ $TEMPLATE2 created for $SUBNET2"
fi

# ------------------------------------------------------------------
# Task 2: Managed instance groups + autoscaling
# ------------------------------------------------------------------
echo
echo "Creating managed instance groups..."

if exists gcloud compute instance-groups managed describe "$MIG1" --zone="$ZONE1"; then
  echo "  ✓ $MIG1 already exists in $ZONE1"
else
  gcloud compute instance-groups managed create "$MIG1" \
    --template="$TEMPLATE1" \
    --size=1 \
    --zone="$ZONE1" \
    --quiet
  echo "  ✓ $MIG1 created"
fi

if exists gcloud compute instance-groups managed describe "$MIG2" --zone="$ZONE2"; then
  echo "  ✓ $MIG2 already exists in $ZONE2"
else
  gcloud compute instance-groups managed create "$MIG2" \
    --template="$TEMPLATE2" \
    --size=1 \
    --zone="$ZONE2" \
    --quiet
  echo "  ✓ $MIG2 created"
fi

if exists gcloud compute instance-groups managed describe "$MIG1" --zone="$ZONE1" --format='value(autoscaler)'; then
  :
fi
if exists gcloud compute autoscalers describe "$MIG1" --zone="$ZONE1"; then
  echo "  ✓ Autoscaler for $MIG1 already exists"
else
  gcloud compute instance-groups managed set-autoscaling "$MIG1" \
    --zone="$ZONE1" \
    --min-num-replicas=1 \
    --max-num-replicas=1 \
    --target-cpu-utilization=0.80 \
    --cool-down-period=45 \
    --quiet
  echo "  ✓ Autoscaling configured for $MIG1"
fi

if exists gcloud compute autoscalers describe "$MIG2" --zone="$ZONE2"; then
  echo "  ✓ Autoscaler for $MIG2 already exists"
else
  gcloud compute instance-groups managed set-autoscaling "$MIG2" \
    --zone="$ZONE2" \
    --min-num-replicas=1 \
    --max-num-replicas=1 \
    --target-cpu-utilization=0.80 \
    --cool-down-period=45 \
    --quiet
  echo "  ✓ Autoscaling configured for $MIG2"
fi

# ------------------------------------------------------------------
# Utility VM used by Task 2/4 for private curl testing.
# ------------------------------------------------------------------
echo
echo "Creating utility-vm..."
if exists gcloud compute instances describe "$UTILITY" --zone="$ZONE1"; then
  echo "  ✓ $UTILITY already exists"
else
  gcloud compute instances create "$UTILITY" \
    --zone="$ZONE1" \
    --machine-type=e2-micro \
    --network="$NETWORK" \
    --subnet="$SUBNET1" \
    --private-network-ip="$UTILITY_IP" \
    --no-address \
    --quiet
  echo "  ✓ $UTILITY created with $UTILITY_IP"
fi

# ------------------------------------------------------------------
# Task 3: Internal passthrough Network Load Balancer
# ------------------------------------------------------------------
echo
echo "[3/4] Configuring Internal Load Balancer..."

if exists gcloud compute health-checks describe "$HEALTH_CHECK"; then
  echo "  ✓ Health check exists: $HEALTH_CHECK"
else
  gcloud compute health-checks create tcp "$HEALTH_CHECK" \
    --port=80 \
    --check-interval=5s \
    --timeout=5s \
    --healthy-threshold=2 \
    --unhealthy-threshold=2 \
    --quiet
  echo "  ✓ Health check created"
fi

if exists gcloud compute backend-services describe "$BACKEND_SERVICE" --region="$REGION"; then
  echo "  ✓ Backend service exists: $BACKEND_SERVICE"
else
  gcloud compute backend-services create "$BACKEND_SERVICE" \
    --region="$REGION" \
    --load-balancing-scheme=internal \
    --protocol=TCP \
    --health-checks="$HEALTH_CHECK" \
    --health-checks-region="$REGION" \
    --quiet
  echo "  ✓ Regional backend service created"
fi

add_backend() {
  local mig="$1" zone="$2"
  if gcloud compute backend-services describe "$BACKEND_SERVICE" --region="$REGION" \
      --format='value(backends[].group)' | grep -Fq "/instanceGroups/$mig"; then
    echo "  ✓ $mig already attached"
  else
    gcloud compute backend-services add-backend "$BACKEND_SERVICE" \
      --region="$REGION" \
      --instance-group="$mig" \
      --instance-group-zone="$zone" \
      --balancing-mode=connection \
      --quiet
    echo "  ✓ $mig attached to backend service"
  fi
}
add_backend "$MIG1" "$ZONE1"
add_backend "$MIG2" "$ZONE2"

if exists gcloud compute addresses describe "$ILB_IP_NAME" --region="$REGION"; then
  EXISTING_IP="$(gcloud compute addresses describe "$ILB_IP_NAME" --region="$REGION" --format='value(address)')"
  [[ "$EXISTING_IP" == "$ILB_IP" ]] || {
    echo "ERROR: $ILB_IP_NAME already exists with IP $EXISTING_IP, expected $ILB_IP."; exit 1;
  }
  echo "  ✓ Reserved internal IP $ILB_IP"
else
  gcloud compute addresses create "$ILB_IP_NAME" \
    --region="$REGION" \
    --subnet="$SUBNET2" \
    --addresses="$ILB_IP" \
    --quiet
  echo "  ✓ Reserved $ILB_IP on $SUBNET2"
fi

if exists gcloud compute forwarding-rules describe "$ILB" --region="$REGION"; then
  echo "  ✓ Forwarding rule exists: $ILB"
else
  gcloud compute forwarding-rules create "$ILB" \
    --region="$REGION" \
    --load-balancing-scheme=internal \
    --network="$NETWORK" \
    --subnet="$SUBNET2" \
    --address="$ILB_IP_NAME" \
    --ip-protocol=TCP \
    --ports=80 \
    --backend-service="$BACKEND_SERVICE" \
    --quiet
  echo "  ✓ Internal Load Balancer created at $ILB_IP:80"
fi

# ------------------------------------------------------------------
# Wait for instances and health before testing.
# ------------------------------------------------------------------
echo
echo "[4/4] Waiting for backend VMs and ILB health..."
for i in {1..30}; do
  RUNNING1="$(gcloud compute instance-groups managed list-instances "$MIG1" --zone="$ZONE1" --format='value(instance,status)' 2>/dev/null | awk '$2=="RUNNING"{c++} END{print c+0}')"
  RUNNING2="$(gcloud compute instance-groups managed list-instances "$MIG2" --zone="$ZONE2" --format='value(instance,status)' 2>/dev/null | awk '$2=="RUNNING"{c++} END{print c+0}')"
  if [[ "$RUNNING1" -ge 1 && "$RUNNING2" -ge 1 ]]; then
    break
  fi
  echo "  Waiting for backends... group1=$RUNNING1 group2=$RUNNING2"
  sleep 10
done

sleep 15

BACKENDS="$(gcloud compute backend-services get-health "$BACKEND_SERVICE" --region="$REGION" --format='value(status.healthStatus[].healthState)' 2>/dev/null || true)"
if grep -q "HEALTHY" <<< "$BACKENDS"; then
  echo "  ✓ At least one backend is HEALTHY"
else
  echo "  WARNING: Health check has not reported HEALTHY yet. Give the VMs another 1-2 minutes."
fi

echo
echo "============================================================"
echo " SUCCESS - GSP216 Internal Load Balancing resources created"
echo "============================================================"
echo "Region:           $REGION"
echo "Zone 1:           $ZONE1"
echo "Zone 2:           $ZONE2"
echo "Templates:        $TEMPLATE1, $TEMPLATE2"
echo "MIGs:             $MIG1, $MIG2"
echo "Utility VM:       $UTILITY ($UTILITY_IP)"
echo "Health check:     $HEALTH_CHECK"
echo "Backend service:  $BACKEND_SERVICE"
echo "ILB:              $ILB"
echo "ILB address:      $ILB_IP:80"
echo
echo "Task 4 test from utility-vm:"
echo "  gcloud compute ssh $UTILITY --zone=$ZONE1 --command='curl -s http://$ILB_IP'"
echo
echo "Run the curl command a few times and check that responses come from both backend zones."
echo "Then click 'Check my progress' in the lab."
echo "============================================================"
