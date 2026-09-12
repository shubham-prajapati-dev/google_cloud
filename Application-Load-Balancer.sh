#!/bin/bash
set -e

REGION="europe-west4"
ZONE="europe-west4-a"

echo "==> Setting default region and zone..."
gcloud config set compute/region "$REGION"
gcloud config set compute/zone "$ZONE"

echo "==> Creating web server www1..."
gcloud compute instances create www1 --zone="$ZONE" --tags=network-lb-tag --machine-type=e2-small --image-family=debian-12 --image-project=debian-cloud --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install apache2 -y
service apache2 restart
echo "<h3>Web Server: www1</h3>" | tee /var/www/html/index.html' || true

echo "==> Creating web server www2..."
gcloud compute instances create www2 --zone="$ZONE" --tags=network-lb-tag --machine-type=e2-small --image-family=debian-12 --image-project=debian-cloud --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install apache2 -y
service apache2 restart
echo "<h3>Web Server: www2</h3>" | tee /var/www/html/index.html' || true

echo "==> Creating web server www3..."
gcloud compute instances create www3 --zone="$ZONE" --tags=network-lb-tag --machine-type=e2-small --image-family=debian-12 --image-project=debian-cloud --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install apache2 -y
service apache2 restart
echo "<h3>Web Server: www3</h3>" | tee /var/www/html/index.html' || true

echo "==> Creating HTTP firewall rule..."
gcloud compute firewall-rules create www-firewall-network-lb --target-tags network-lb-tag --allow tcp:80 || true

echo "==> Creating instance template..."
gcloud compute instance-templates create lb-backend-template --region="$REGION" --network=default --subnet=default --tags=allow-health-check --machine-type=e2-medium --image-family=debian-12 --image-project=debian-cloud --metadata=startup-script='#!/bin/bash
apt-get update
apt-get install apache2 -y
a2ensite default-ssl
a2enmod ssl
vm_hostname="$(curl -H "Metadata-Flavor:Google" http://169.254.169.254/computeMetadata/v1/instance/name)"
echo "Page served from: $vm_hostname" | tee /var/www/html/index.html
systemctl restart apache2' || true

echo "==> Creating managed instance group..."
gcloud compute instance-groups managed create lb-backend-group --template=lb-backend-template --size=2 --zone="$ZONE" || true

echo "==> Creating health-check firewall rule..."
gcloud compute firewall-rules create fw-allow-health-check --network=default --action=allow --direction=ingress --source-ranges=130.211.0.0/22,35.191.0.0/16 --target-tags=allow-health-check --rules=tcp:80 || true

echo "==> Reserving global load balancer IP..."
gcloud compute addresses create lb-ipv4-1 --ip-version=IPV4 --global || true
LB_IP="$(gcloud compute addresses describe lb-ipv4-1 --format='get(address)' --global)"
echo "==> Load Balancer IP: $LB_IP"

echo "==> Creating health check..."
gcloud compute health-checks create http http-basic-check --port 80 || true

echo "==> Creating backend service..."
gcloud compute backend-services create web-backend-service --protocol=HTTP --port-name=http --health-checks=http-basic-check --global || true

echo "==> Adding managed instance group to backend..."
gcloud compute backend-services add-backend web-backend-service --instance-group=lb-backend-group --instance-group-zone="$ZONE" --global || true

echo "==> Creating URL map..."
gcloud compute url-maps create web-map-http --default-service web-backend-service || true

echo "==> Creating HTTP proxy..."
gcloud compute target-http-proxies create http-lb-proxy --url-map web-map-http || true

echo "==> Creating global forwarding rule..."
gcloud compute forwarding-rules create http-content-rule --address=lb-ipv4-1 --global --target-http-proxy=http-lb-proxy --ports=80 || true

echo
echo "============================================================"
echo "Application Load Balancer setup complete."
echo "Load Balancer IP: $LB_IP"
echo "Test with:"
echo "  curl http://$LB_IP"
echo "============================================================"
