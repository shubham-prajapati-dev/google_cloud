#!/bin/bash
set -e

REGION="europe-west1"
ZONE="europe-west1-c"
LB_IP="10.132.0.10"

# Set region and zone
gcloud config set compute/region "$REGION"
gcloud config set compute/zone "$ZONE"

# Virtual environment
sudo apt-get install -y virtualenv || true
python3 -m venv venv || true
source venv/bin/activate

# Backend startup script
cat > backend.sh <<'EOF'
#!/bin/bash
sudo chmod -R 777 /usr/local/sbin/
sudo cat << 'PYEOF' > /usr/local/sbin/serveprimes.py
import http.server

def is_prime(a):
    return a != 1 and all(a % i for i in range(2, int(a**0.5) + 1))

class myHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200)
        s.send_header("Content-type", "text/plain")
        s.end_headers()
        s.wfile.write(bytes(str(is_prime(int(s.path[1:]))).encode('utf-8')))

http.server.HTTPServer(("", 80), myHandler).serve_forever()
PYEOF
nohup python3 /usr/local/sbin/serveprimes.py >/dev/null 2>&1 &
EOF

# Instance template
gcloud compute instance-templates create primecalc \
  --metadata-from-file startup-script=backend.sh \
  --no-address --tags backend --machine-type=e2-medium || true

# Backend firewall
gcloud compute firewall-rules create http \
  --network default --allow=tcp:80 \
  --source-ranges 10.132.0.0/20 --target-tags backend || true

# Managed instance group
gcloud compute instance-groups managed create backend \
  --size 3 --template primecalc --zone "$ZONE" || true

# Health check
gcloud compute health-checks create http ilb-health \
  --request-path /2 || true

# Regional internal backend service
gcloud compute backend-services create prime-service \
  --load-balancing-scheme internal --region="$REGION" \
  --protocol tcp --health-checks ilb-health || true

# Add MIG backend
gcloud compute backend-services add-backend prime-service \
  --instance-group backend --instance-group-zone="$ZONE" \
  --region="$REGION" || true

# Internal forwarding rule with the lab's required IP
gcloud compute forwarding-rules create prime-lb \
  --load-balancing-scheme internal \
  --ports 80 --network default \
  --region="$REGION" --address "$LB_IP" \
  --backend-service prime-service || true

echo "============================================================"
echo "Internal Load Balancer created"
echo "Internal LB IP: $LB_IP"
echo "============================================================"

# Test VM
gcloud compute instances create testinstance \
  --machine-type=e2-standard-2 --zone "$ZONE" || true

echo "Test VM created. SSH with:"
echo "gcloud compute ssh testinstance --zone $ZONE"
echo "Then test: curl $LB_IP/2 ; curl $LB_IP/4 ; curl $LB_IP/5"

echo "============================================================"

# Frontend startup script
cat > frontend.sh <<EOF
#!/bin/bash
sudo chmod -R 777 /usr/local/sbin/
sudo cat << 'PYEOF' > /usr/local/sbin/getprimes.py
import urllib.request
from multiprocessing.dummy import Pool as ThreadPool
import http.server
PREFIX="http://$LB_IP/"
def get_url(number):
    return urllib.request.urlopen(PREFIX + str(number)).read().decode('utf-8')
class myHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200)
        s.send_header("Content-type", "text/html")
        s.end_headers()
        i = int(s.path[1:]) if len(s.path) > 1 else 1
        s.wfile.write("<html><body><table>".encode('utf-8'))
        pool = ThreadPool(10)
        results = pool.map(get_url, range(i, i + 100))
        for x in range(0, 100):
            if not (x % 10): s.wfile.write("<tr>".encode('utf-8'))
            if results[x] == "True":
                s.wfile.write("<td bgcolor='#00ff00'>".encode('utf-8'))
            else:
                s.wfile.write("<td bgcolor='#ff0000'>".encode('utf-8'))
            s.wfile.write(str(x + i).encode('utf-8') + "</td> ".encode('utf-8'))
            if not ((x + 1) % 10): s.wfile.write("</tr>".encode('utf-8'))
        s.wfile.write("</table></body></html>".encode('utf-8'))
http.server.HTTPServer(("", 80), myHandler).serve_forever()
PYEOF
nohup python3 /usr/local/sbin/getprimes.py >/dev/null 2>&1 &
EOF

# Public frontend
gcloud compute instances create frontend --zone="$ZONE" \
  --metadata-from-file startup-script=frontend.sh \
  --tags frontend --machine-type=e2-standard-2 || true

# Frontend firewall
gcloud compute firewall-rules create http2 \
  --network default --allow=tcp:80 \
  --source-ranges 0.0.0.0/0 --target-tags frontend || true

FRONTEND_IP=$(gcloud compute instances describe frontend --zone="$ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)

echo "============================================================"
echo "Lab setup complete"
echo "Internal LB IP: $LB_IP"
echo "Frontend External IP: $FRONTEND_IP"
echo "Open http://$FRONTEND_IP in your browser"
echo "============================================================"
