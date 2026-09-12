#!/bin/bash
set -Eeuo pipefail
trap 'echo "ERROR: command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || { echo "ERROR: Set the lab project first with: gcloud config set project PROJECT_ID"; exit 1; }

DEFAULT_REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"
DEFAULT_ZONE="$(gcloud config get-value compute/zone 2>/dev/null || true)"
[[ "$DEFAULT_REGION" == "(unset)" ]] && DEFAULT_REGION=""
[[ "$DEFAULT_ZONE" == "(unset)" ]] && DEFAULT_ZONE=""
DEFAULT_REGION="${DEFAULT_REGION:-us-central1}"
DEFAULT_ZONE="${DEFAULT_ZONE:-us-central1-a}"

printf '\n============================================================\n'
printf ' GSP216 - Internal Load Balancing Lab\n'
printf '============================================================\n'
printf 'Project: %s\n\n' "$PROJECT_ID"

read -r -p "Enter Region [$DEFAULT_REGION]: " REGION
REGION="${REGION:-$DEFAULT_REGION}"
read -r -p "Enter Zone for subnet-a [$DEFAULT_ZONE]: " ZONE_A
ZONE_A="${ZONE_A:-$DEFAULT_ZONE}"

# Pick a second zone in the same region. The lab requires a different zone for subnet-b.
read -r -p "Enter a different zone in the same region for subnet-b [auto]: " ZONE_B
if [[ -z "$ZONE_B" ]]; then
  ZONE_B="$(gcloud compute zones list --filter="region:($REGION) AND name!=$ZONE_A" --format='value(name)' --limit=1)"
fi
[[ -n "$ZONE_B" ]] || { echo "ERROR: Could not find a second zone in $REGION."; exit 1; }

printf '\nRegion: %s\nZone A: %s\nZone B: %s\n\n' "$REGION" "$ZONE_A" "$ZONE_B"
read -r -p "Continue? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

NETWORK="my-internal-app"
SUBNET_A="subnet-a"
SUBNET_B="subnet-b"
TEMPLATE_1="instance-template-1"
TEMPLATE_2="instance-template-2"
MIG_1="instance-group-1"
MIG_2="instance-group-2"
UTILITY="utility-vm"
ILB="my-ilb"
ILB_IP_NAME="my-ilb-ip"
ILB_IP="10.10.30.5"
HEALTH_CHECK="my-ilb-health-check"
BACKEND_SERVICE="my-ilb-backend-service"

exists() { "$@" >/dev/null 2>&1; }

require_network_and_subnets() {
  exists gcloud compute networks describe "$NETWORK" || {
    echo "ERROR: Required network '$NETWORK' was not found. Start the lab first; Google pre-creates this network." >&2
    exit 1
  }
  exists gcloud compute networks subnets describe "$SUBNET_A" --region="$REGION" || {
    echo "ERROR: Required subnet '$SUBNET_A' was not found in $REGION." >&2
    exit 1
  }
  exists gcloud compute networks subnets describe "$SUBNET_B" --region="$REGION" || {
    echo "ERROR: Required subnet '$SUBNET_B' was not found in $REGION." >&2
    exit 1
  }
}

ensure_firewall() {
  local NAME="$1"; shift
  if exists gcloud compute firewall-rules describe "$NAME"; then
    echo "✓ Firewall exists: $NAME"
  else
    gcloud compute firewall-rules create "$NAME" "$@"
  fi
}

ensure_template() {
  local NAME="$1" SUBNET="$2"
  if exists gcloud compute instance-templates describe "$NAME"; then
    echo "✓ Instance template exists: $NAME"
    return
  fi
  gcloud compute instance-templates create "$NAME" \
    --machine-type=e2-micro \
    --network="$NETWORK" \
    --subnet="$SUBNET" \
    --no-address \
    --tags=lb-backend \
    --image-family=debian-11 \
    --image-project=debian-cloud \
    --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install -y apache2 php libapache2-mod-php curl
cat <<'EOF' > /var/www/html/index.php
<h1>Internal Load Balancing Lab</h1>
<h2>Client IP</h2>
Your IP address : <?php echo $_SERVER["REMOTE_ADDR"]; ?>
<h2>Hostname</h2>
Server Hostname: <?php echo gethostname(); ?>
<h2>Server Location</h2>
Region and Zone: <?php
$ch = curl_init();
curl_setopt($ch, CURLOPT_URL, "http://metadata.google.internal/computeMetadata/v1/instance/zone");
curl_setopt($ch, CURLOPT_HTTPHEADER, array("Metadata-Flavor: Google"));
curl_setopt($ch, CURLOPT_RETURNTRANSFER, 1);
$zone = curl_exec($ch);
$parts = explode("/", $zone);
echo end($parts);
?>
EOF
rm -f /var/www/html/index.html
systemctl enable apache2
systemctl restart apache2'
}

ensure_mig() {
  local NAME="$1" TEMPLATE="$2" ZONE="$3"
  if exists gcloud compute instance-groups managed describe "$NAME" --zone="$ZONE"; then
    echo "✓ Managed instance group exists: $NAME"
  else
    gcloud compute instance-groups managed create "$NAME" \
      --template="$TEMPLATE" \
      --size=1 \
      --zone="$ZONE"
  fi
  gcloud compute instance-groups managed set-autoscaling "$NAME" \
    --zone="$ZONE" \
    --min-num-replicas=1 \
    --max-num-replicas=1 \
    --target-cpu-utilization=0.8 \
    --cool-down-period=45
}

# Validate the lab-provided resources before making changes.
echo "Validating project, region, zones and pre-created network..."
gcloud projects describe "$PROJECT_ID" >/dev/null
gcloud compute regions describe "$REGION" >/dev/null
gcloud compute zones describe "$ZONE_A" >/dev/null
gcloud compute zones describe "$ZONE_B" >/dev/null
gcloud config set compute/region "$REGION" >/dev/null
gcloud config set compute/zone "$ZONE_A" >/dev/null
require_network_and_subnets

# ============================================================
# TASK 1 - Firewall rules
# ============================================================
echo
 echo "[TASK 1] Configuring firewall rules..."
ensure_firewall app-allow-http \
  --network="$NETWORK" \
  --action=allow \
  --direction=INGRESS \
  --target-tags=lb-backend \
  --source-ranges=10.10.0.0/16 \
  --rules=tcp:80

ensure_firewall app-allow-health-check \
  --network="$NETWORK" \
  --action=allow \
  --direction=INGRESS \
  --target-tags=lb-backend \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --rules=tcp

echo "✓ TASK 1 configured"

# ============================================================
# TASK 2 - Templates and managed instance groups
# ============================================================
echo
 echo "[TASK 2] Creating instance templates..."
ensure_template "$TEMPLATE_1" "$SUBNET_A"

if exists gcloud compute instance-templates describe "$TEMPLATE_2"; then
  echo "✓ Instance template exists: $TEMPLATE_2"
else
  gcloud compute instance-templates create "$TEMPLATE_2" \
    --machine-type=e2-micro \
    --network="$NETWORK" \
    --subnet="$SUBNET_B" \
    --no-address \
    --tags=lb-backend \
    --image-family=debian-11 \
    --image-project=debian-cloud \
    --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install -y apache2 php libapache2-mod-php curl
cat <<'EOF' > /var/www/html/index.php
<h1>Internal Load Balancing Lab</h1>
<h2>Client IP</h2>
Your IP address : <?php echo $_SERVER["REMOTE_ADDR"]; ?>
<h2>Hostname</h2>
Server Hostname: <?php echo gethostname(); ?>
<h2>Server Location</h2>
Region and Zone: <?php
$ch = curl_init();
curl_setopt($ch, CURLOPT_URL, "http://metadata.google.internal/computeMetadata/v1/instance/zone");
curl_setopt($ch, CURLOPT_HTTPHEADER, array("Metadata-Flavor: Google"));
curl_setopt($ch, CURLOPT_RETURNTRANSFER, 1);
$zone = curl_exec($ch);
$parts = explode("/", $zone);
echo end($parts);
?>
EOF
rm -f /var/www/html/index.html
systemctl enable apache2
systemctl restart apache2'
fi

ensure_mig "$MIG_1" "$TEMPLATE_1" "$ZONE_A"
ensure_mig "$MIG_2" "$TEMPLATE_2" "$ZONE_B"

echo "✓ TASK 2 configured"

# ============================================================
# Utility VM
# ============================================================
echo
 echo "Creating utility VM..."
if exists gcloud compute instances describe "$UTILITY" --zone="$ZONE_A"; then
  echo "✓ Utility VM exists: $UTILITY"
else
  gcloud compute instances create "$UTILITY" \
    --zone="$ZONE_A" \
    --machine-type=e2-micro \
    --network="$NETWORK" \
    --subnet="$SUBNET_A" \
    --no-address \
    --private-network-ip=10.10.20.50 \
    --image-family=debian-11 \
    --image-project=debian-cloud
fi

# ============================================================
# TASK 3 - Internal passthrough Network Load Balancer
# ============================================================
echo
 echo "[TASK 3] Configuring Internal Load Balancer..."

# Reserve the exact internal IP requested by the lab.
if exists gcloud compute addresses describe "$ILB_IP_NAME" --region="$REGION"; then
  CURRENT_IP="$(gcloud compute addresses describe "$ILB_IP_NAME" --region="$REGION" --format='value(address)')"
  [[ "$CURRENT_IP" == "$ILB_IP" ]] || {
    echo "ERROR: $ILB_IP_NAME exists with $CURRENT_IP, expected $ILB_IP. Delete the conflicting address and rerun." >&2
    exit 1
  }
  echo "✓ Internal IP exists: $ILB_IP_NAME ($CURRENT_IP)"
else
  gcloud compute addresses create "$ILB_IP_NAME" \
    --region="$REGION" \
    --subnet="$SUBNET_B" \
    --addresses="$ILB_IP"
fi

# Regional TCP health check on port 80.
if exists gcloud compute health-checks describe "$HEALTH_CHECK" --region="$REGION"; then
  echo "✓ Health check exists: $HEALTH_CHECK"
else
  gcloud compute health-checks create tcp "$HEALTH_CHECK" \
    --region="$REGION" \
    --port=80
fi

# Regional backend service.
if exists gcloud compute backend-services describe "$BACKEND_SERVICE" --region="$REGION"; then
  echo "✓ Backend service exists: $BACKEND_SERVICE"
else
  gcloud compute backend-services create "$BACKEND_SERVICE" \
    --region="$REGION" \
    --load-balancing-scheme=internal \
    --protocol=tcp \
    --health-checks="$HEALTH_CHECK"
fi

BACKENDS="$(gcloud compute backend-services describe "$BACKEND_SERVICE" --region="$REGION" --format='value(backends[].group)' 2>/dev/null || true)"
MIG1_URL="https://www.googleapis.com/compute/v1/projects/$PROJECT_ID/zones/$ZONE_A/instanceGroups/$MIG_1"
MIG2_URL="https://www.googleapis.com/compute/v1/projects/$PROJECT_ID/zones/$ZONE_B/instanceGroups/$MIG_2"
if ! grep -Fq "$MIG1_URL" <<< "$BACKENDS"; then
  gcloud compute backend-services add-backend "$BACKEND_SERVICE" \
    --region="$REGION" \
    --instance-group="$MIG_1" \
    --instance-group-zone="$ZONE_A"
fi
if ! grep -Fq "$MIG2_URL" <<< "$BACKENDS"; then
  gcloud compute backend-services add-backend "$BACKEND_SERVICE" \
    --region="$REGION" \
    --instance-group="$MIG_2" \
    --instance-group-zone="$ZONE_B"
fi

# Create the forwarding rule. If an old rule exists, verify it rather than hiding errors.
if exists gcloud compute forwarding-rules describe "$ILB" --region="$REGION"; then
  RULE_IP="$(gcloud compute forwarding-rules describe "$ILB" --region="$REGION" --format='value(IPAddress)')"
  RULE_BACKEND="$(gcloud compute forwarding-rules describe "$ILB" --region="$REGION" --format='value(backendService.basename())')"
  [[ "$RULE_IP" == "$ILB_IP" ]] || { echo "ERROR: $ILB forwarding rule uses $RULE_IP, expected $ILB_IP"; exit 1; }
  [[ "$RULE_BACKEND" == "$BACKEND_SERVICE" ]] || { echo "ERROR: $ILB forwarding rule points to $RULE_BACKEND, expected $BACKEND_SERVICE"; exit 1; }
  echo "✓ Forwarding rule exists: $ILB"
else
  gcloud compute forwarding-rules create "$ILB" \
    --region="$REGION" \
    --load-balancing-scheme=internal \
    --network="$NETWORK" \
    --subnet="$SUBNET_B" \
    --address="$ILB_IP_NAME" \
    --ip-protocol=TCP \
    --ports=80 \
    --backend-service="$BACKEND_SERVICE"
fi

echo "✓ TASK 3 configured"

# ============================================================
# TASK 4 - Test
# ============================================================
echo
 echo "[TASK 4] Testing backend readiness..."
sleep 10

READY=0
for i in {1..12}; do
  if gcloud compute health-checks describe "$HEALTH_CHECK" --region="$REGION" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 5
done

if [[ "$READY" -eq 1 ]]; then
  echo "✓ Health check resource is ready."
fi

echo
printf '============================================================\n'
printf ' SUCCESS - GSP216 resources configured\n'
printf '============================================================\n'
printf 'Region:        %s\n' "$REGION"
printf 'Zone A:        %s\n' "$ZONE_A"
printf 'Zone B:        %s\n' "$ZONE_B"
printf 'Internal LB:   %s (%s)\n' "$ILB" "$ILB_IP"
printf 'Backend groups: %s, %s\n' "$MIG_1" "$MIG_2"
printf '\nTo test from utility-vm:\n'
printf '  gcloud compute ssh %s --zone=%s\n' "$UTILITY" "$ZONE_A"
printf '  curl %s\n' "$ILB_IP"
printf '============================================================\n'
printf 'Run "Check my progress" in the lab after the resources become healthy.\n'
