#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 06: NGINX Ingress + Sorry Page"

check_state
check_k8s
check_dns
check_helm
export KUBECONFIG="$KUBECONFIG"

LB_ENDPOINT="${LB_IP:-${NLB_DNS:-}}"
check_vars BASTION_IP SSH_KEY
[ -n "$LB_ENDPOINT" ] || { log_error "LB_IP or NLB_DNS not set"; exit 1; }

# ── Sorry Page ────────────────────────────────────────────────────────────────
echo ""
log_info "Deploying Sorry Page..."

kubectl create namespace ingress-nginx 2>/dev/null || true

kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: sorry-page-html
  namespace: ingress-nginx
data:
  index.html: |
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta http-equiv="refresh" content="5">
      <title>Service starting...</title>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
          background: #0f172a; color: #e2e8f0;
          display: flex; align-items: center; justify-content: center; min-height: 100vh;
        }
        .container { text-align: center; padding: 2rem; max-width: 500px; }
        .spinner {
          width: 48px; height: 48px; border: 4px solid #334155;
          border-top-color: #3b82f6; border-radius: 50%;
          animation: spin 1s linear infinite; margin: 0 auto 2rem;
        }
        @keyframes spin { to { transform: rotate(360deg); } }
        h1 { font-size: 1.5rem; margin-bottom: 0.75rem; color: #f1f5f9; }
        p { color: #94a3b8; font-size: 0.95rem; line-height: 1.6; }
        .hint { margin-top: 1.5rem; font-size: 0.8rem; color: #475569; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="spinner"></div>
        <h1>Service is starting</h1>
        <p>This page will reload automatically in 5 seconds.</p>
        <p class="hint">Please wait 1–2 minutes...</p>
      </div>
    </body>
    </html>
YAML

kubectl apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sorry-page
  namespace: ingress-nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sorry-page
  template:
    metadata:
      labels:
        app: sorry-page
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: sorry-page
          image: nginx:alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { cpu: 50m, memory: 32Mi }
      volumes:
        - name: html
          configMap:
            name: sorry-page-html
YAML

kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: sorry-page
  namespace: ingress-nginx
spec:
  selector:
    app: sorry-page
  ports:
    - port: 80
      targetPort: 80
YAML

kubectl rollout status deployment/sorry-page -n ingress-nginx --timeout=60s
log_ok "Sorry Page deployed"

# ── NGINX Ingress ─────────────────────────────────────────────────────────────
echo ""
log_info "Deploying NGINX Ingress..."

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update 2>/dev/null || true

# Values: base (NodePort defaults) + cloud overlay (AWS NLB / Azure LB annotations)
_nginx_flags=(
  -f "$BASE_DIR/tools/base/values/ingress-nginx.yaml"
)
NGINX_OVERLAY="$BASE_DIR/tools/overlays/${CLOUD}/values/ingress-nginx.yaml"
[ -f "$NGINX_OVERLAY" ] && _nginx_flags+=(-f "$NGINX_OVERLAY")

INGRESS_STATUS=$(kubectl get deployment ingress-nginx-controller \
  -n ingress-nginx --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

if [ "$INGRESS_STATUS" = "1/1" ]; then
  log_skip "NGINX Ingress already running — upgrading config..."
  helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx \
    "${_nginx_flags[@]}" \
    --timeout 5m --wait
else
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx --create-namespace \
    "${_nginx_flags[@]}" \
    --timeout 5m --wait
  log_ok "NGINX Ingress deployed"
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
log_info "Verifying NGINX Ingress..."
kubectl get pods -n ingress-nginx

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 "http://$LB_ENDPOINT" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "404" ] || [ "$HTTP_CODE" = "200" ]; then
  log_ok "LB → NGINX working (HTTP $HTTP_CODE)"
else
  log_warn "LB → NGINX not responding (HTTP $HTTP_CODE) — may need a few minutes"
fi

echo ""
log_ok "Ingress endpoint: http://$LB_ENDPOINT"
log_success "STEP 06"
