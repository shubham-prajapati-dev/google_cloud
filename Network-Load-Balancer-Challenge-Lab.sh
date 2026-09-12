#!/bin/bash
set -euo pipefail

# Google Cloud Skills Boost Challenge Lab:
# Create multiple web servers + Network Load Balancer + HTTP Load Balancer
#
# The challenge lab supplies REGION and ZONE dynamically. This script accepts
# them as arguments or uses the current gcloud compute region/zone settings.
# Usage:
#   ./Network-Load-Balancer-Challenge-Lab.sh REGION ZONE
# Example:
#   ./Network-Load-Balancer-Challenge-Lab.sh us-central1 us-central1-a

REGION="${1:-$(gcloud config get-value compute/region 2>/dev/null)}"
ZONE="${2:-$(gcloud config get-value compute/zone 2>/dev/null)}"

if [[ -z "$REGION" || "$REGION" == "(unset)" || -z "$ZONE" || "$ZONE" == "(unset)" ]]; then
  echo "ERROR: Region and Zone are required."
  echo "Usage: $0 REGION ZONE"
  echo "Example: $0 us-central1 us-central1-a"
  exit 1
fi

IMAGE_FAMILY="debian-12"
IMAGE_PROJECT="debian-cloud"

NETWORK_LB_IP_NAME="network-lb-ip-1"
TARGET_POOL="www-pool"
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

run_create() {
  "$@" || {
    echo "Command failed (resource may already exist); continuing..."
    return 0
  }
}

echo "============================================================"
echo "Region: $REGION"
echo "Zone:   $ZONE"
echo "============================================================"

gcloud config set compute/region "$REGION"
gcloud config set compute/zone "$ZONE"

# ------------------------------------------------------------
# TASK 1: Three web servers
# ------------------------------------------------------------
create_web_vm() {
  local name="$1"
  run_create gcloud compute instances create "$name" \
    --zone="$ZONE" \
    --network=default \
    --tags=network-lb-tag \
    --machine-type=e2-small \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --metadata=startup-script="#!/bin/bash
apt-get update
apt-get install apache2 -y
service apache2 restart
echo \"<h3>Web Server: $name</h3>\" | tee /var/www/html/index.html"
}

create_web_vm web1
create_web_vm web2
create_web_vm web3

run_create gcloud compute firewall-rules create "$FW_NETWORK_LB" \
  --network=default \
  --target-tags=network-lb-tag \
  --allow=tcp:80

# ------------------------------------------------------------
# TASK 2: Network Load Balancing service
# ------------------------------------------------------------
run_create gcloud compute addresses create "$NETWORK_LB_IP_NAME" \
  --region="$REGION"

run_create gcloud compute target-pools create "$TARGET_POOL" \
  --region="$REGION"

run_create gcloud compute target-pools add-instances "$TARGET_POOL" \
  --instances=web1,web2,web3 \
  --instances-zone="$ZONE" \
  --region="$REGION"

NETWORK_LB_IP="$(gcloud compute addresses describe "$NETWORK_LB_IP_NAME" \
  --region="$REGION" --format='get(address)')"

echo "Network Load Balancer IP: $NETWORK_LB_IP"

run_create gcloud compute forwarding-rules create "$TARGET_POOL-forwarding-rule" \
  --region="$REGION" \
  --ports=80 \
  --address="$NETWORK_LB_IP_NAME" \
  --target-pool="$TARGET_POOL"

# ------------------------------------------------------------
# TASK 3: HTTP Load Balancer
# ------------------------------------------------------------
run_create gcloud compute instance-templates create "$TEMPLATE" \
  --region="$REGION" \
  --network=default \
  --subnet=default \
  --tags=allow-health-check \
  --machine-type=e2-medium \
  --image-family="$IMAGE_FAMILY" \
  --image-project="$IMAGE_PROJECT" \
  --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install apache2 -y
a2ensite default-ssl
a2enmod ssl
vm_hostname="$(curl -H "Metadata-Flavor:Google" http://169.254.169.254/computeMetadata/v1/instance/name)"
echo "Page served from: $vm_hostname" | tee /var/www/html/index.html
systemctl restart apache2'

run_create gcloud compute instance-groups managed create "$MIG" \
  --template="$TEMPLATE" \
  --size=2 \
  --zone="$ZONE"

run_create gcloud compute firewall-rules create "$FW_HEALTH" \
  --network=default \
  --action=allow \
  --direction=ingress \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=allow-health-check \
  --rules=tcp:80

run_create gcloud compute addresses create "$LB_IP" \
  --ip-version=IPV4 \
  --global

GLOBAL_LB_IP="$(gcloud compute addresses describe "$LB_IP" \
  --global --format='get(address)')"

echo "HTTP Load Balancer IP: $GLOBAL_LB_IP"

run_create gcloud compute health-checks create http "$HEALTH_CHECK" \
  --port=80

run_create gcloud compute backend-services create "$BACKEND" \
  --protocol=HTTP \
  --port-name=http \
  --health-checks="$HEALTH_CHECK" \
  --global

run_create gcloud compute backend-services add-backend "$BACKEND" \
  --instance-group="$MIG" \
  --instance-group-zone="$ZONE" \
  --global

run_create gcloud compute url-maps create "$URL_MAP" \
  --default-service="$BACKEND"

run_create gcloud compute target-http-proxies create "$HTTP_PROXY" \
  --url-map="$URL_MAP"

run_create gcloud compute forwarding-rules create "$FORWARDING" \
  --address="$LB_IP" \
  --global \
  --target-http-proxy="$HTTP_PROXY" \
  --ports=80

echo
printf '%s\n' '============================================================'
printf '%s\n' 'Challenge lab resources created.'
printf '%s\n' "Network LB IP: $NETWORK_LB_IP"
printf '%s\n' "HTTP LB IP:    $GLOBAL_LB_IP"
printf '%s\n' 'Test HTTP LB with:'
printf '%s\n' "curl http://$GLOBAL_LB_IP"
printf '%s\n' '============================================================'
