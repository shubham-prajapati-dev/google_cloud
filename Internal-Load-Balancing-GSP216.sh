#!/bin/bash
set -Eeuo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || { echo "ERROR: No active Google Cloud project."; exit 1; }

REGION="asia-south1"
ZONE1="asia-south1-a"
ZONE2="asia-south1-b"
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

echo "============================================================"
echo " GSP216 - Internal Load Balancing"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Zone 1: $ZONE1"
echo "Zone 2: $ZONE2"
echo ""

gcloud compute networks describe "$NETWORK" >/dev/null
gcloud compute networks subnets describe "$SUBNET1" --region="$REGION" >/dev/null
gcloud compute networks subnets describe "$SUBNET2" --region="$REGION" >/dev/null

gcloud config set compute/region "$REGION" >/dev/null
gcloud config set compute/zone "$ZONE1" >/dev/null

echo "[1/4] Cleaning stale lab resources..."
gcloud compute forwarding-rules delete "$ILB" --region="$REGION" --quiet 2>/dev/null || true
gcloud compute backend-services delete "$BACKEND_SERVICE" --region="$REGION" --quiet 2>/dev/null || true
gcloud compute health-checks delete "$HEALTH_CHECK" --region="$REGION" --quiet 2>/dev/null || true
gcloud compute health-checks delete "$HEALTH_CHECK" --quiet 2>/dev/null || true
gcloud compute addresses delete "$ILB_IP_NAME" --region="$REGION" --quiet 2>/dev/null || true
gcloud compute instance-groups managed delete "$MIG1" --zone="$ZONE1" --quiet 2>/dev/null || true
gcloud compute instance-groups managed delete "$MIG2" --zone="$ZONE2" --quiet 2>/dev/null || true
gcloud compute instances delete "$UTILITY" --zone="$ZONE1" --quiet 2>/dev/null || true
gcloud compute instance-templates delete "$TEMPLATE1" --quiet 2>/dev/null || true
gcloud compute instance-templates delete "$TEMPLATE2" --quiet 2>/dev/null || true

sleep 5

echo "[2/4] Configuring firewall rules..."
gcloud compute firewall-rules describe app-allow-http >/dev/null 2>&1 || \
gcloud compute firewall-rules create app-allow-http \
  --network="$NETWORK" \
  --target-tags="$TAG" \
  --source-ranges=10.10.0.0/16 \
  --allow=tcp:80 \
  --quiet

gcloud compute firewall-rules describe app-allow-health-check >/dev/null 2>&1 || \
gcloud compute firewall-rules create app-allow-health-check \
  --network="$NETWORK" \
  --target-tags="$TAG" \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --allow=tcp \
  --quiet

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

echo "[3/4] Creating instance templates and managed instance groups..."
gcloud compute instance-templates create "$TEMPLATE1" \
  --machine-type=e2-micro \
  --network="$NETWORK" \
  --subnet="$SUBNET1" \
  --no-address \
  --tags="$TAG" \
  --metadata-from-file=startup-script="$STARTUP" \
  --quiet

gcloud compute instance-templates create "$TEMPLATE2" \
  --machine-type=e2-micro \
  --network="$NETWORK" \
  --subnet="$SUBNET2" \
  --no-address \
  --tags="$TAG" \
  --metadata-from-file=startup-script="$STARTUP" \
  --quiet

gcloud compute instance-groups managed create "$MIG1" \
  --template="$TEMPLATE1" \
  --size=1 \
  --zone="$ZONE1" \
  --quiet

gcloud compute instance-groups managed create "$MIG2" \
  --template="$TEMPLATE2" \
  --size=1 \
  --zone="$ZONE2" \
  --quiet

gcloud compute instance-groups managed set-autoscaling "$MIG1" \
  --zone="$ZONE1" \
  --min-num-replicas=1 \
  --max-num-replicas=1 \
  --target-cpu-utilization=0.80 \
  --cool-down-period=45 \
  --quiet

gcloud compute instance-groups managed set-autoscaling "$MIG2" \
  --zone="$ZONE2" \
  --min-num-replicas=1 \
  --max-num-replicas=1 \
  --target-cpu-utilization=0.80 \
  --cool-down-period=45 \
  --quiet

gcloud compute instances create "$UTILITY" \
  --zone="$ZONE1" \
  --machine-type=e2-micro \
  --network="$NETWORK" \
  --subnet="$SUBNET1" \
  --private-network-ip="$UTILITY_IP" \
  --no-address \
  --quiet

echo "[4/4] Creating internal load balancer..."
gcloud compute health-checks create tcp "$HEALTH_CHECK" \
  --region="$REGION" \
  --port=80 \
  --check-interval=5s \
  --timeout=5s \
  --healthy-threshold=2 \
  --unhealthy-threshold=2 \
  --quiet

gcloud compute backend-services create "$BACKEND_SERVICE" \
  --region="$REGION" \
  --load-balancing-scheme=internal \
  --protocol=TCP \
  --health-checks="$HEALTH_CHECK" \
  --health-checks-region="$REGION" \
  --quiet

gcloud compute backend-services add-backend "$BACKEND_SERVICE" \
  --region="$REGION" \
  --instance-group="$MIG1" \
  --instance-group-zone="$ZONE1" \
  --balancing-mode=connection \
  --quiet

gcloud compute backend-services add-backend "$BACKEND_SERVICE" \
  --region="$REGION" \
  --instance-group="$MIG2" \
  --instance-group-zone="$ZONE2" \
  --balancing-mode=connection \
  --quiet

gcloud compute addresses create "$ILB_IP_NAME" \
  --region="$REGION" \
  --subnet="$SUBNET2" \
  --addresses="$ILB_IP" \
  --quiet

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

echo ""
echo "Waiting 60 seconds for backend VMs to initialize..."
sleep 60

echo ""
echo "============================================================"
echo " GSP216 resources created"
echo "============================================================"
echo "ILB address: $ILB_IP:80"
echo "Utility VM:  $UTILITY ($UTILITY_IP)"
echo ""
echo "Test with:"
echo "gcloud compute ssh $UTILITY --zone=$ZONE1 --command='curl -s http://$ILB_IP'"
echo ""
echo "Run the curl several times, then click Check my progress."
echo "============================================================"
