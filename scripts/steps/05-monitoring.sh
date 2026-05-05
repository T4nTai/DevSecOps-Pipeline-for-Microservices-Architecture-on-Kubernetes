#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 05: Prometheus + Grafana"

check_state
check_k8s
check_dns
check_helm
export KUBECONFIG="$KUBECONFIG"

DOMAIN="tools.votantai.me"

# ── Resolve Grafana password ───────────────────────────────────────────────────
echo ""
log_info "Resolving Grafana admin password..."
if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  log_error "GRAFANA_ADMIN_PASSWORD not set"
  log_info  "Add to .env.secret: GRAFANA_ADMIN_PASSWORD=\"xxx\""
  exit 1
fi
log_ok "Grafana password resolved"

# ── Add Helm repo ─────────────────────────────────────────────────────────────
echo ""
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update 2>/dev/null || true

# ── Render values (inject password) ──────────────────────────────────────────
sed \
  -e "s|GRAFANA_ADMIN_PASSWORD_PLACEHOLDER|${GRAFANA_ADMIN_PASSWORD}|g" \
  "$BASE_DIR/k8s/monitoring/values.yaml" > /tmp/monitoring-values-rendered.yaml

# ── Install / Upgrade ─────────────────────────────────────────────────────────
echo ""
MONITORING_STATUS=$(kubectl get deployment prometheus-grafana \
  -n monitoring --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

if [ "$MONITORING_STATUS" = "1/1" ]; then
  log_info "Upgrading Prometheus + Grafana config..."
  helm upgrade prometheus prometheus-community/kube-prometheus-stack \
    -n monitoring \
    -f /tmp/monitoring-values-rendered.yaml \
    --timeout 10m --wait 2>/dev/null || true
  kubectl rollout restart deployment/prometheus-grafana -n monitoring
  kubectl rollout status deployment/prometheus-grafana -n monitoring --timeout=60s
else
  kubectl wait --for=condition=ready pod -l k8s-app=kube-dns \
    -n kube-system --timeout=120s 2>/dev/null || true

  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f /tmp/monitoring-values-rendered.yaml \
    --timeout 10m --wait
  log_ok "Prometheus + Grafana deployed"
fi

rm -f /tmp/monitoring-values-rendered.yaml

# ── Install Loki + Promtail ───────────────────────────────────────────────────
echo ""
log_info "Deploying Loki..."
LOKI_STATUS=$(kubectl get statefulset loki -n monitoring \
  --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")
if [ "$LOKI_STATUS" = "1/1" ]; then
  log_skip "Loki already running"
else
  helm upgrade --install loki grafana/loki \
    -n monitoring --create-namespace \
    -f "$BASE_DIR/k8s/monitoring/loki-values.yaml" \
    --timeout 5m --wait
  log_ok "Loki deployed"
fi

echo ""
log_info "Deploying Promtail..."
PROMTAIL_STATUS=$(kubectl get daemonset promtail -n monitoring \
  --no-headers 2>/dev/null | awk '{print $3}' || echo "0")
if [ "${PROMTAIL_STATUS:-0}" -gt "0" ]; then
  log_skip "Promtail already running"
else
  helm upgrade --install promtail grafana/promtail \
    -n monitoring --create-namespace \
    -f "$BASE_DIR/k8s/monitoring/promtail-values.yaml" \
    --timeout 3m --wait
  log_ok "Promtail deployed"
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
log_info "Monitoring pods:"
kubectl get pods -n monitoring

FAILED=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
  | grep -v "Running\|Completed" | wc -l | tr -d '[:space:]' || echo "0")
[ "${FAILED:-0}" -gt "0" ] && \
  kubectl get pods -n monitoring --no-headers | grep -v "Running\|Completed" || \
  log_ok "All monitoring pods running"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Monitoring ready"
echo "  https://grafana.${DOMAIN}   admin / [GRAFANA_ADMIN_PASSWORD]"
echo "══════════════════════════════════════════════════════"

log_success "STEP 05"
