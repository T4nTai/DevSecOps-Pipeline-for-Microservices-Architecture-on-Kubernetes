#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 05: Prometheus + Grafana"

check_state
check_k8s
check_dns
check_helm
export KUBECONFIG="$KUBECONFIG"

# -- Resolve Grafana password --------------------------------------------------─
echo ""
log_info "Resolving Grafana admin password..."
if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  log_error "GRAFANA_ADMIN_PASSWORD not set"
  log_info  "Add to .env.secret: GRAFANA_ADMIN_PASSWORD=\"xxx\""
  exit 1
fi
log_ok "Grafana password resolved"

# -- Add Helm repos ------------------------------------------------------------
echo ""
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update 2>/dev/null || true

# -- Values: base + cloud overlay (storageClass) + domain/password ------------─
BASE_VALUES="$BASE_DIR/tools/base/values/monitoring.yaml"
OVERLAY_VALUES="$BASE_DIR/tools/overlays/${CLOUD}/values/storage.yaml"

# Domain + password injected via temp file (nested keys don't work well with --set)
cat > /tmp/grafana-domain.yaml <<GVALS
grafana:
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
  ingress:
    hosts:
      - "grafana.${DOMAIN}"
    tls:
      - hosts:
          - "grafana.${DOMAIN}"
        secretName: tools-wildcard-tls
  grafana.ini:
    server:
      root_url: "https://grafana.${DOMAIN}"
GVALS

_monitoring_flags() {
  local flags=(-f "$BASE_VALUES")
  [ -f "$OVERLAY_VALUES" ] && flags+=(-f "$OVERLAY_VALUES")
  flags+=(-f /tmp/grafana-domain.yaml)
  echo "${flags[@]}"
}

# -- Install / Upgrade kube-prometheus-stack ----------------------------------─
echo ""
MONITORING_STATUS=$(kubectl get deployment prometheus-grafana \
  -n monitoring --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

if [ "$MONITORING_STATUS" = "1/1" ]; then
  log_info "Upgrading Prometheus + Grafana config..."
  # shellcheck disable=SC2046
  helm upgrade prometheus prometheus-community/kube-prometheus-stack \
    -n monitoring \
    $(_monitoring_flags) \
    --timeout 10m --wait 2>/dev/null || true
  kubectl rollout restart deployment/prometheus-grafana -n monitoring
  kubectl rollout status deployment/prometheus-grafana -n monitoring --timeout=60s
else
  kubectl wait --for=condition=ready pod -l k8s-app=kube-dns \
    -n kube-system --timeout=120s 2>/dev/null || true

  # shellcheck disable=SC2046
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    $(_monitoring_flags) \
    --timeout 10m --wait
  log_ok "Prometheus + Grafana deployed"
fi

rm -f /tmp/grafana-domain.yaml

# -- Install Loki --------------------------------------------------------------
echo ""
log_info "Deploying Loki..."
LOKI_STATUS=$(kubectl get statefulset loki -n monitoring \
  --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")
if [ "$LOKI_STATUS" = "1/1" ]; then
  log_skip "Loki already running"
else
  _loki_flags=(-f "$BASE_DIR/tools/base/values/loki.yaml")
  [ -f "$OVERLAY_VALUES" ] && _loki_flags+=(-f "$OVERLAY_VALUES")
  helm upgrade --install loki grafana/loki \
    -n monitoring --create-namespace \
    "${_loki_flags[@]}" \
    --timeout 5m --wait
  log_ok "Loki deployed"
fi

# -- Install Promtail ----------------------------------------------------------
echo ""
log_info "Deploying Promtail..."
PROMTAIL_STATUS=$(kubectl get daemonset promtail -n monitoring \
  --no-headers 2>/dev/null | awk '{print $3}' || echo "0")
if [ "${PROMTAIL_STATUS:-0}" -gt "0" ]; then
  log_skip "Promtail already running"
else
  helm upgrade --install promtail grafana/promtail \
    -n monitoring --create-namespace \
    -f "$BASE_DIR/tools/base/values/promtail.yaml" \
    --timeout 3m --wait
  log_ok "Promtail deployed"
fi

# -- Apply PrometheusRule + AlertmanagerConfig ---------------------------------
echo ""
log_info "Applying NetworkPolicy for monitoring namespace..."
kubectl apply -f "$BASE_DIR/tools/monitoring/network-policy.yaml"
log_ok "NetworkPolicy applied"

log_info "Applying alert rules..."
kubectl apply -f "$BASE_DIR/tools/monitoring/prometheus-rules.yaml"
log_ok "PrometheusRule applied"

log_info "Applying AlertManager Gmail config..."
if [ -z "${ALERT_TO_EMAIL:-}" ] || [ -z "${ALERT_FROM_EMAIL:-}" ]; then
  log_warn "ALERT_TO_EMAIL or ALERT_FROM_EMAIL not set — skipping AlertmanagerConfig"
  log_warn "Add to .env.secret and re-run: bash scripts/deploy.sh --cloud=${CLOUD} --start-from=05"
else
  envsubst '${ALERT_TO_EMAIL} ${ALERT_FROM_EMAIL}' \
    < "$BASE_DIR/tools/monitoring/alertmanager-gmail.yaml" \
    | kubectl apply -f -
  log_ok "AlertmanagerConfig applied (to: ${ALERT_TO_EMAIL}, from: ${ALERT_FROM_EMAIL})"
  log_warn "Gmail App Password secret will be created when running k8s/vault/setup-vault.sh (after step 12)"
fi

# -- Verify --------------------------------------------------------------------
echo ""
log_info "Monitoring pods:"
kubectl get pods -n monitoring

FAILED=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
  | grep -v "Running\|Completed" | wc -l | tr -d '[:space:]' || echo "0")
[ "${FAILED:-0}" -gt "0" ] && \
  kubectl get pods -n monitoring --no-headers | grep -v "Running\|Completed" || \
  log_ok "All monitoring pods running"

echo ""
echo "======================================================"
echo "  Monitoring ready"
echo "  https://grafana.${DOMAIN}   admin / [GRAFANA_ADMIN_PASSWORD]"
echo "======================================================"

log_success "STEP 05"
