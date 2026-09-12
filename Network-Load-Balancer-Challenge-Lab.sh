#!/bin/bash
set -euo pipefail

# Google Cloud Skills Boost Challenge Lab
# Interactive setup: asks for Region, Zone, and Debian image family.

echo "============================================================"
echo " Google Cloud Load Balancing Challenge Lab"
echo "============================================================"

default_region="$(gcloud config get-value compute/region 2>/dev/null || true)"
default_zone="$(gcloud config get-value compute/zone 2>/dev/null || true)"

[[ "$default_region" == "(unset)" ]] && default_region=""
[[ "$default_zone" == "(unset)" ]] && default_zone=""

default_region="${default_region:-us-central1}"
default_zone="${default_zone:-us-central1-a}"

read -r -p "Enter Region [$default_region]: " REGION
REGION="${REGION:-$default_region}"

read -r -p "Enter Zone [$default_zone]: " ZONE
ZONE="${ZONE:-$default_zone}"

read -r -p "Enter Debian image family [debian-12]: " IMAGE_FAMILY
IMAGE_FAMILY="${IMAGE_FAMILY:-debian-12}"

IMAGE_PROJECT="debian-cloud"
NETWORK="default"

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
  if "$@"; then
    return 0
  fi
  echo "Resource/command may already exist; continuing..."
  return 0
}

echo
printf '%s\n' "Region: $REGION"
printf '%s\n' "Zone:   $ZONE"
printf '%s\n' "Image:  $IMAGE_FAMILY ($IMAGE_PROJECT)"
printf '%s\n' "Network: $NETWORK"
echo
read -r -p "Continue with these values? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

gcloud config set compute/region "$REGION"
gcloud config set compute/zone "$ZONE"

# TASK 1: Three web servers
create_web_vm() {
  local name="$1"
  run_create gcloud compute instances create "$name" \
    --zone="$ZONE" \
    --network="$NETWORK" \
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
  --network="$NETWORK" \
  --target-tags=network-lb-tag \
  --allow=tcp:80

# TASK 2: Network Load Balancer
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

# TASK 3: HTTP Load Balancer
run_create gcloud compute instance-templates create "$TEMPLATE" \
  --region="$REGION" \
  --network="$NETWORK" \
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
  --network="$NETWORK" \
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
echo "============================================================"
echo " Challenge Lab setup complete"
echo "============================================================"
echo "Region:              $REGION"
echo "Zone:                $ZONE"
echo "Network LB IP:       $NETWORK_LB_IP"
echo "HTTP Load Balancer:  $GLOBAL_LB_IP"
echo
 echo "Test HTTP Load Balancer:"
echo "  curl http://$GLOBAL_LB_IP"
echo
 echo "If the lab asks for progress checks, click Check my progress"
echo "after each task."
echo "============================================================"
