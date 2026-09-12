#!/bin/bash
set -Eeuo pipefail
trap 'echo "ERROR: command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || { echo "ERROR: Set the lab project first: gcloud config set project PROJECT_ID"; exit 1; }

default_region="$(gcloud config get-value compute/region 2>/dev/null || true)"
default_zone="$(gcloud config get-value compute/zone 2>/dev/null || true)"
[[ "$default_region" == "(unset)" ]] && default_region=""
[[ "$default_zone" == "(unset)" ]] && default_zone=""
default_region="${default_region:-us-central1}"
default_zone="${default_zone:-us-central1-a}"

echo "============================================================"
echo " Google Cloud Load Balancing Challenge Lab"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo
read -r -p "Enter Region [$default_region]: " REGION
REGION="${REGION:-$default_region}"
read -r -p "Enter Zone [$default_zone]: " ZONE
ZONE="${ZONE:-$default_zone}"
read -r -p "Enter Debian image family [debian-11]: " IMAGE_FAMILY
IMAGE_FAMILY="${IMAGE_FAMILY:-debian-11}"

IMAGE_PROJECT="debian-cloud"
NETWORK="default"
NETWORK_LB_IP_NAME="network-lb-ip-1"
LEGACY_HEALTH_CHECK="basic-check"
TARGET_POOL="www-pool"
NETWORK_LB_RULE="www-rule"
OLD_NETWORK_LB_RULE="www-pool-forwarding-rule"
FW_NETWORK_LB="www-firewall-network-lb"
TEMPLATE="lb-backend-template"
MIG="lb-backend-group"
FW_HEALTH="fw-allow-health-check"
LB_IP="lb-ipv4-1"
HEALTH_CHECK="http-basic-check"
BACKEND="web-backend-service"
URL_MAP="web-map-http"
HTTP_PROXY="http-lb-proxy"
FORWARDING="http-content-rule"

printf '\nRegion: %s\nZone: %s\nDebian image: %s\n\n' "$REGION" "$ZONE" "$IMAGE_FAMILY"
read -r -p "Continue with these values? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

echo "Validating project, zone, region and Debian image..."
gcloud projects describe "$PROJECT_ID" >/dev/null
gcloud compute zones describe "$ZONE" >/dev/null
gcloud compute regions describe "$REGION" >/dev/null
IMAGE_NAME="$(gcloud compute images list --project="$IMAGE_PROJECT" --filter="family=$IMAGE_FAMILY" --format='value(name)' --limit=1)"
[[ -n "$IMAGE_NAME" ]] || { echo "ERROR: Debian image family '$IMAGE_FAMILY' was not found in '$IMAGE_PROJECT'."; exit 1; }

gcloud config set compute/region "$REGION" >/dev/null
gcloud config set compute/zone "$ZONE" >/dev/null

exists() { "$@" >/dev/null 2>&1; }

ensure_firewall() {
  local name="$1"; shift
  if exists gcloud compute firewall-rules describe "$name"; then
    echo "✓ Firewall exists: $name"
  else
    gcloud compute firewall-rules create "$name" "$@"
  fi
}

# ============================================================
# TASK 1 - web1, web2, web3
# ============================================================
create_web_vm() {
  local name="$1"
  if exists gcloud compute instances describe "$name" --zone="$ZONE"; then
    echo "✓ VM exists: $name"
    return 0
  fi
  gcloud compute instances create "$name" \
    --zone="$ZONE" \
    --network="$NETWORK" \
    --tags=network-lb-tag \
    --machine-type=e2-small \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --metadata=startup-script="#!/bin/bash
apt-get update
apt-get install -y apache2
service apache2 restart
echo '<h3>Web Server: $name</h3>' | tee /var/www/html/index.html"
}
create_web_vm web1
create_web_vm web2
create_web_vm web3

ensure_firewall "$FW_NETWORK_LB" \
  --network="$NETWORK" \
  --target-tags=network-lb-tag \
  --allow=tcp:80

# ============================================================
# TASK 2 - Network Load Balancer
# The challenge expects the legacy target-pool architecture.
# ============================================================
if exists gcloud compute addresses describe "$NETWORK_LB_IP_NAME" --region="$REGION"; then
  echo "✓ Static IP exists: $NETWORK_LB_IP_NAME"
else
  gcloud compute addresses create "$NETWORK_LB_IP_NAME" --region="$REGION"
fi

# Target-pool NLBs require a legacy HTTP health check.
if exists gcloud compute http-health-checks describe "$LEGACY_HEALTH_CHECK"; then
  echo "✓ Legacy health check exists: $LEGACY_HEALTH_CHECK"
else
  gcloud compute http-health-checks create "$LEGACY_HEALTH_CHECK"
fi

if exists gcloud compute target-pools describe "$TARGET_POOL" --region="$REGION"; then
  echo "✓ Target pool exists: $TARGET_POOL"
  CURRENT_HC="$(gcloud compute target-pools describe "$TARGET_POOL" --region="$REGION" --format='value(healthChecks[0].basename())' 2>/dev/null || true)"
  if [[ "$CURRENT_HC" != "$LEGACY_HEALTH_CHECK" ]]; then
    echo "Updating target pool to use legacy health check $LEGACY_HEALTH_CHECK..."
    gcloud compute target-pools set-health-checks "$TARGET_POOL" \
      --region="$REGION" \
      --http-health-check="$LEGACY_HEALTH_CHECK"
  fi
else
  gcloud compute target-pools create "$TARGET_POOL" \
    --region="$REGION" \
    --http-health-check="$LEGACY_HEALTH_CHECK"
fi

for VM in web1 web2 web3; do
  if gcloud compute target-pools describe "$TARGET_POOL" --region="$REGION" --format='value(instances.basename())' | grep -qx "$VM"; then
    echo "✓ $VM already in $TARGET_POOL"
  else
    gcloud compute target-pools add-instances "$TARGET_POOL" \
      --instances="$VM" \
      --instances-zone="$ZONE" \
      --region="$REGION"
  fi
done

# Remove the old forwarding rule created by an earlier version of this script.
if exists gcloud compute forwarding-rules describe "$OLD_NETWORK_LB_RULE" --region="$REGION"; then
  gcloud compute forwarding-rules delete "$OLD_NETWORK_LB_RULE" --region="$REGION" --quiet
fi

# Recreate the exact forwarding rule required by the challenge.
if exists gcloud compute forwarding-rules describe "$NETWORK_LB_RULE" --region="$REGION"; then
  gcloud compute forwarding-rules delete "$NETWORK_LB_RULE" --region="$REGION" --quiet
fi

gcloud compute forwarding-rules create "$NETWORK_LB_RULE" \
  --region="$REGION" \
  --ports=80 \
  --address="$NETWORK_LB_IP_NAME" \
  --target-pool="$TARGET_POOL"

NETWORK_LB_IP="$(gcloud compute addresses describe "$NETWORK_LB_IP_NAME" --region="$REGION" --format='value(address)')"
RULE_IP="$(gcloud compute forwarding-rules describe "$NETWORK_LB_RULE" --region="$REGION" --format='value(IPAddress)')"
RULE_TARGET="$(gcloud compute forwarding-rules describe "$NETWORK_LB_RULE" --region="$REGION" --format='value(target.basename())')"
RULE_PORTS="$(gcloud compute forwarding-rules describe "$NETWORK_LB_RULE" --region="$REGION" --format='value(portRange)')"
RULE_PROTOCOL="$(gcloud compute forwarding-rules describe "$NETWORK_LB_RULE" --region="$REGION" --format='value(IPProtocol)')"
[[ "$RULE_IP" == "$NETWORK_LB_IP" ]] || { echo "ERROR: forwarding rule IP is $RULE_IP, expected $NETWORK_LB_IP"; exit 1; }
[[ "$RULE_TARGET" == "$TARGET_POOL" ]] || { echo "ERROR: forwarding rule target is $RULE_TARGET, expected $TARGET_POOL"; exit 1; }
[[ "$RULE_PORTS" == "80" || "$RULE_PORTS" == "80-80" ]] || { echo "ERROR: forwarding rule port is '$RULE_PORTS', expected 80/80-80"; exit 1; }
[[ "$RULE_PROTOCOL" == "TCP" ]] || { echo "ERROR: forwarding rule protocol is $RULE_PROTOCOL, expected TCP"; exit 1; }

POOL_HC="$(gcloud compute target-pools describe "$TARGET_POOL" --region="$REGION" --format='value(healthChecks[0].basename())')"
[[ "$POOL_HC" == "$LEGACY_HEALTH_CHECK" ]] || { echo "ERROR: target pool health check is '$POOL_HC', expected '$LEGACY_HEALTH_CHECK'"; exit 1; }

echo "✓ TASK 2 VERIFIED"
echo "  Static IP:     $NETWORK_LB_IP_NAME ($NETWORK_LB_IP)"
echo "  Target pool:   $TARGET_POOL"
echo "  Health check:  $LEGACY_HEALTH_CHECK"
echo "  Protocol:      TCP"
echo "  Port:          $RULE_PORTS"

# ============================================================
# TASK 3 - Global HTTP Load Balancer
# ============================================================
if exists gcloud compute instance-templates describe "$TEMPLATE"; then
  echo "✓ Instance template exists: $TEMPLATE"
else
  gcloud compute instance-templates create "$TEMPLATE" \
    --network="$NETWORK" \
    --subnet=default \
    --tags=allow-health-check \
    --machine-type=e2-medium \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install -y apache2
a2ensite default-ssl
a2enmod ssl
vm_hostname="$(curl -fsS -H "Metadata-Flavor:Google" http://metadata.google.internal/computeMetadata/v1/instance/name)"
echo "Page served from: $vm_hostname" | tee /var/www/html/index.html
systemctl restart apache2'
fi

if exists gcloud compute instance-groups managed describe "$MIG" --zone="$ZONE"; then
  echo "✓ Managed instance group exists: $MIG"
else
  gcloud compute instance-groups managed create "$MIG" --template="$TEMPLATE" --size=2 --zone="$ZONE"
fi

gcloud compute instance-groups managed set-named-ports "$MIG" --named-ports=http:80 --zone="$ZONE"

ensure_firewall "$FW_HEALTH" \
  --network="$NETWORK" \
  --action=allow \
  --direction=ingress \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=allow-health-check \
  --rules=tcp:80

if exists gcloud compute addresses describe "$LB_IP" --global; then
  echo "✓ Global IP exists: $LB_IP"
else
  gcloud compute addresses create "$LB_IP" --ip-version=IPV4 --global
fi

if exists gcloud compute health-checks describe "$HEALTH_CHECK"; then
  echo "✓ Health check exists: $HEALTH_CHECK"
else
  gcloud compute health-checks create http "$HEALTH_CHECK" --port=80
fi

if exists gcloud compute backend-services describe "$BACKEND" --global; then
  echo "✓ Backend service exists: $BACKEND"
else
  gcloud compute backend-services create "$BACKEND" --protocol=HTTP --port-name=http --health-checks="$HEALTH_CHECK" --global
fi

BACKENDS="$(gcloud compute backend-services describe "$BACKEND" --global --format='value(backends[].group)' 2>/dev/null || true)"
MIG_URL="https://www.googleapis.com/compute/v1/projects/$PROJECT_ID/zones/$ZONE/instanceGroups/$MIG"
if ! grep -Fq "$MIG_URL" <<< "$BACKENDS"; then
  gcloud compute backend-services add-backend "$BACKEND" --instance-group="$MIG" --instance-group-zone="$ZONE" --global
fi

if ! exists gcloud compute url-maps describe "$URL_MAP"; then
  gcloud compute url-maps create "$URL_MAP" --default-service="$BACKEND"
fi
if ! exists gcloud compute target-http-proxies describe "$HTTP_PROXY"; then
  gcloud compute target-http-proxies create "$HTTP_PROXY" --url-map="$URL_MAP"
fi
if ! exists gcloud compute forwarding-rules describe "$FORWARDING" --global; then
  gcloud compute forwarding-rules create "$FORWARDING" --address="$LB_IP" --global --target-http-proxy="$HTTP_PROXY" --ports=80
fi

GLOBAL_LB_IP="$(gcloud compute addresses describe "$LB_IP" --global --format='value(address)')"

echo
echo "============================================================"
echo " SUCCESS - Challenge Lab resources configured"
echo "============================================================"
echo "Network LB IP:  $NETWORK_LB_IP"
echo "HTTP LB IP:     $GLOBAL_LB_IP"
echo
echo "Test Task 2:"
echo "  while true; do curl -m1 http://$NETWORK_LB_IP; done"
echo
echo "Wait about 30 seconds if the first requests fail, then click Check my progress."
echo "============================================================"