#!/bin/bash
set -Eeuo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# GSP216 - Enhance Application Reliability and Scalability with Internal Load Balancing
# Creates/repairs Tasks 1-3 resources and prepares Task 4 testing.

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || { echo "ERROR: No active Google Cloud project."; exit 1; }

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
This script creates and repairs the lab resources from Tasks 1-3.
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

ZONE1_REGION="$(gcloud compute zones describe "$ZONE1" --format='value(region.basename())')"
ZONE2_REGION="$(gcloud compute zones describe "$ZONE2" --format='value(region.basename())')"
[[ "$ZONE1_REGION" == "$REGION" && "$ZONE2_REGION" == "$REGION" ]] || { echo "ERROR: Both zones must belong to $REGION."; exit 1; }

gcloud compute networks describe "$NETWORK" >/dev/null
gcloud compute networks subnets describe "$SUBNET1" --region="$REGION" >/dev/null
gcloud compute networks subnets describe "$SUBNET2" --region="$REGION" >/dev/null
gcloud config set compute/region "$REGION" >/dev/null
gcloud config set compute/zone "$ZONE1" >/dev/null

exists() { "$@" >/dev/null 2>&1; }

# ------------------------------------------------------------------
# Task 1: Firewall rules
# ------------------------------------------------------------------
echo "[1/4] Configuring firewall rules..."
if exists gcloud compute firewall-rules describe app-allow-http; then
  echo "  ✓ app-allow-http exists"
else
  gcloud compute firewall-rules create app-allow-http --network="$NETWORK" --target-tags="$TAG" --source-ranges=10.10.0.0/16 --allow=tcp:80 --quiet
fi

if exists gcloud compute firewall-rules describe app-allow-health-check; then
  echo "  ✓ app-allow-health-check exists"
else
  gcloud compute firewall-rules create app-allow-health-check --network="$NETWORK" --target-tags="$TAG" --source-ranges=130.211.0.0/22,35.191.0.0/16 --allow=tcp --quiet
fi

# ------------------------------------------------------------------
# Startup script
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
# Task 2: Instance templates. IMPORTANT: validate existing templates;
# do not merely test whether the name exists.
# ------------------------------------------------------------------
template_ok() {
  local tpl="$1" subnet="$2"
  local machine tags subnetwork access_configs
  machine="$(gcloud compute instance-templates describe "$tpl" --format='value(properties.machineType.basename())' 2>/dev/null || true)"
  tags="$(gcloud compute instance-templates describe "$tpl" --format='value(properties.tags.items)' 2>/dev/null || true)"
  subnetwork="$(gcloud compute instance-templates describe "$tpl" --format='value(properties.networkInterfaces[0].subnetwork.basename())' 2>/dev/null || true)"
  access_configs="$(gcloud compute instance-templates describe "$tpl" --format='value(properties.networkInterfaces[0].accessConfigs[].name)' 2>/dev/null || true)"
  [[ "$machine" == "e2-micro" && "$subnetwork" == "$subnet" && " $tags " == *" $TAG "*" && -z "$access_configs" ]]
}

create_template() {
  local tpl="$1" subnet="$2"
  gcloud compute instance-templates create "$tpl" \
    --machine-type=e2-micro \
    --network="$NETWORK" \
    --subnet="$subnet" \
    --no-address \
    --tags="$TAG" \
    --metadata-from-file=startup-script="$STARTUP" \
    --quiet
}

echo "[2/4] Validating instance templates..."

# If a bad template is referenced by a MIG, temporarily move that MIG to a
# disposable valid template before deleting the bad template.
TEMP_TEMPLATE="gsp216-repair-template"
NEED_TEMP=0
for mig in "$MIG1" "$MIG2"; do
  for zone in "$ZONE1" "$ZONE2"; do
    if exists gcloud compute instance-groups managed describe "$mig" --zone="$zone"; then
      ref="$(gcloud compute instance-groups managed describe "$mig" --zone="$zone" --format='value(instanceTemplate.basename())' 2>/dev/null || true)"
      if [[ "$ref" == "$TEMPLATE1" || "$ref" == "$TEMPLATE2" ]]; then NEED_TEMP=1; fi
    fi
  done
done

if [[ "$NEED_TEMP" -eq 1 ]]; then
  if ! template_ok "$TEMP_TEMPLATE" "$SUBNET1"; then
    if exists gcloud compute instance-templates describe "$TEMP_TEMPLATE"; then
      gcloud compute instance-templates delete "$TEMP_TEMPLATE" --quiet || true
    fi
    create_template "$TEMP_TEMPLATE" "$SUBNET1"
  fi
  for mig_zone in "$MIG1|$ZONE1" "$MIG2|$ZONE2"; do
    IFS='|' read -r mig zone <<< "$mig_zone"
    if exists gcloud compute instance-groups managed describe "$mig" --zone="$zone"; then
      ref="$(gcloud compute instance-groups managed describe "$mig" --zone="$zone" --format='value(instanceTemplate.basename())' 2>/dev/null || true)"
      if [[ "$ref" == "$TEMPLATE1" || "$ref" == "$TEMPLATE2" ]]; then
        gcloud compute instance-groups managed set-instance-template "$mig" --zone="$zone" --template="$TEMP_TEMPLATE" --quiet
      fi
    fi
  done
fi

for tpl_subnet in "$TEMPLATE1|$SUBNET1" "$TEMPLATE2|$SUBNET2"; do
  IFS='|' read -r tpl subnet <<< "$tpl_subnet"
  if template_ok "$tpl" "$subnet"; then
    echo "  ✓ $tpl is correctly configured for $subnet"
  else
    echo "  ! $tpl is missing/incorrect; repairing it for $subnet"
    if exists gcloud compute instance-templates describe "$tpl"; then
      gcloud compute instance-templates delete "$tpl" --quiet
    fi
    create_template "$tpl" "$subnet"
    echo "  ✓ $tpl repaired"
  fi
done

# ------------------------------------------------------------------
# Managed instance groups + autoscaling
# ------------------------------------------------------------------
echo "Creating managed instance groups..."
if exists gcloud compute instance-groups managed describe "$MIG1" --zone="$ZONE1"; then
  gcloud compute instance-groups managed set-instance-template "$MIG1" --zone="$ZONE1" --template="$TEMPLATE1" --quiet
else
  gcloud compute instance-groups managed create "$MIG1" --template="$TEMPLATE1" --size=1 --zone="$ZONE1" --quiet
fi

if exists gcloud compute instance-groups managed describe "$MIG2" --zone="$ZONE2"; then
  gcloud compute instance-groups managed set-instance-template "$MIG2" --zone="$ZONE2" --template="$TEMPLATE2" --quiet
else
  gcloud compute instance-groups managed create "$MIG2" --template="$TEMPLATE2" --size=1 --zone="$ZONE2" --quiet
fi

gcloud compute instance-groups managed set-autoscaling "$MIG1" --zone="$ZONE1" --min-num-replicas=1 --max-num-replicas=1 --target-cpu-utilization=0.80 --cool-down-period=45 --quiet
gcloud compute instance-groups managed set-autoscaling "$MIG2" --zone="$ZONE2" --min-num-replicas=1 --max-num-replicas=1 --target-cpu-utilization=0.80 --cool-down-period=45 --quiet

# Replace old MIG instances so the repaired template is actually used.
gcloud compute instance-groups managed rolling-action replace "$MIG1" --zone="$ZONE1" --max-unavailable=1 --quiet || true
gcloud compute instance-groups managed rolling-action replace "$MIG2" --zone="$ZONE2" --max-unavailable=1 --quiet || true

# ------------------------------------------------------------------
# Utility VM
# ------------------------------------------------------------------
echo "Creating utility-vm..."
if exists gcloud compute instances describe "$UTILITY" --zone="$ZONE1"; then
  echo "  ✓ $UTILITY exists"
else
  gcloud compute instances create "$UTILITY" --zone="$ZONE1" --machine-type=e2-micro --network="$NETWORK" --subnet="$SUBNET1" --private-network-ip="$UTILITY_IP" --no-address --quiet
fi

# ------------------------------------------------------------------
# Task 3: Regional internal passthrough Network Load Balancer
# IMPORTANT: internal regional backend services require a REGIONAL health check.
# ------------------------------------------------------------------
echo "[3/4] Configuring Internal Load Balancer..."

if exists gcloud compute health-checks describe "$HEALTH_CHECK" --region="$REGION"; then
  echo "  ✓ Regional health check exists: $HEALTH_CHECK"
else
  # Remove an old global health check with the same name if one exists.
  if exists gcloud compute health-checks describe "$HEALTH_CHECK"; then
    echo "  ! Found old global health check; deleting it"
    gcloud compute health-checks delete "$HEALTH_CHECK" --quiet || true
  fi
  gcloud compute health-checks create tcp "$HEALTH_CHECK" \
    --region="$REGION" \
    --port=80 \
    --check-interval=5s \
    --timeout=5s \
    --healthy-threshold=2 \
    --unhealthy-threshold=2 \
    --quiet
  echo "  ✓ Regional health check created"
fi

if exists gcloud compute backend-services describe "$BACKEND_SERVICE" --region="$REGION"; then
  echo "  ✓ Backend service exists"
else
  gcloud compute backend-services create "$BACKEND_SERVICE" --region="$REGION" --load-balancing-scheme=internal --protocol=TCP --health-checks="$HEALTH_CHECK" --health-checks-region="$REGION" --quiet
fi

add_backend() {
  local mig="$1" zone="$2"
  if gcloud compute backend-services describe "$BACKEND_SERVICE" --region="$REGION" --format='value(backends[].group)' 2>/dev/null | grep -Fq "/instanceGroups/$mig"; then
    echo "  ✓ $mig already attached"
  else
    gcloud compute backend-services add-backend "$BACKEND_SERVICE" --region="$REGION" --instance-group="$mig" --instance-group-zone="$zone" --balancing-mode=connection --quiet
  fi
}
add_backend "$MIG1" "$ZONE1"
add_backend "$MIG2" "$ZONE2"

if exists gcloud compute addresses describe "$ILB_IP_NAME" --region="$REGION"; then
  EXISTING_IP="$(gcloud compute addresses describe "$ILB_IP_NAME" --region="$REGION" --format='value(address)')"
  [[ "$EXISTING_IP" == "$ILB_IP" ]] || { echo "ERROR: $ILB_IP_NAME has $EXISTING_IP, expected $ILB_IP."; exit 1; }
else
  gcloud compute addresses create "$ILB_IP_NAME" --region="$REGION" --subnet="$SUBNET2" --addresses="$ILB_IP" --quiet
fi

if exists gcloud compute forwarding-rules describe "$ILB" --region="$REGION"; then
  echo "  ✓ Forwarding rule exists"
else
  gcloud compute forwarding-rules create "$ILB" --region="$REGION" --load-balancing-scheme=internal --network="$NETWORK" --subnet="$SUBNET2" --address="$ILB_IP_NAME" --ip-protocol=TCP --ports=80 --backend-service="$BACKEND_SERVICE" --quiet
fi

# Delete disposable template only after MIGs point at the final templates.
if exists gcloud compute instance-templates describe "$TEMP_TEMPLATE"; then
  gcloud compute instance-templates delete "$TEMP_TEMPLATE" --quiet || true
fi

echo "[4/4] Waiting for backend VMs..."
for i in {1..36}; do
  RUNNING1="$(gcloud compute instance-groups managed list-instances "$MIG1" --zone="$ZONE1" --format='value(instance,status)' 2>/dev/null | awk '$2=="RUNNING"{c++} END{print c+0}')"
  RUNNING2="$(gcloud compute instance-groups managed list-instances "$MIG2" --zone="$ZONE2" --format='value(instance,status)' 2>/dev/null | awk '$2=="RUNNING"{c++} END{print c+0}')"
  if [[ "$RUNNING1" -ge 1 && "$RUNNING2" -ge 1 ]]; then break; fi
  echo "  Waiting... group1=$RUNNING1 group2=$RUNNING2"
  sleep 10
done

sleep 20
HEALTH="$(gcloud compute backend-services get-health "$BACKEND_SERVICE" --region="$REGION" --format='value(status.healthStatus[].healthState)' 2>/dev/null || true)"
if grep -q "HEALTHY" <<< "$HEALTH"; then
  echo "  ✓ Backend health is HEALTHY"
else
  echo "  WARNING: Backend health is not HEALTHY yet; wait 1-2 minutes and retry the lab check."
fi

echo
echo "============================================================"
echo " GSP216 resources are ready"
echo "============================================================"
echo "ILB: $ILB -> $ILB_IP:80"
echo "Test: gcloud compute ssh $UTILITY --zone=$ZONE1 --command='curl -s http://$ILB_IP'"
echo "Run the curl several times, then click Check my progress."
echo "============================================================"
