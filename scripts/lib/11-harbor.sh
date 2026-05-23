#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 11: Harbor"

check_state
check_k8s
check_helm
export KUBECONFIG="$KUBECONFIG"

HARBOR_VERSION="1.14.2"

# ── Resolve password ───────────────────────────────────────────────────────────
echo ""
log_info "Resolving Harbor admin password..."
if [ -z "${HARBOR_ADMIN_PASSWORD:-}" ]; then
  log_error "HARBOR_ADMIN_PASSWORD not set"
  log_info  "Add to .env.secret: HARBOR_ADMIN_PASSWORD=\"xxx\""
  exit 1
fi
log_ok "Harbor password resolved"

# ── Add Helm repo ─────────────────────────────────────────────────────────────
echo ""
log_info "Adding Harbor Helm repo..."
helm repo add harbor https://helm.goharbor.io 2>/dev/null || true
helm repo update 2>/dev/null || true
log_ok "Helm repo ready"

# ── Render values (inject password) ──────────────────────────────────────────
sed \
  -e "s|HARBOR_ADMIN_PASSWORD_PLACEHOLDER|${HARBOR_ADMIN_PASSWORD}|g" \
  -e "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" \
  "$BASE_DIR/k8s/harbor/values.yaml" > /tmp/harbor-values-rendered.yaml

# ── Install / Upgrade Harbor ──────────────────────────────────────────────────
echo ""
HARBOR_STATUS=$(kubectl get deployment harbor-core -n harbor \
  --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

if [ "$HARBOR_STATUS" = "1/1" ]; then
  log_skip "Harbor already running"
else
  log_info "Installing Harbor ${HARBOR_VERSION}..."
  helm upgrade --install harbor harbor/harbor \
    -n harbor --create-namespace \
    --version "$HARBOR_VERSION" \
    -f /tmp/harbor-values-rendered.yaml \
    --timeout 10m --wait
  log_ok "Harbor installed"
fi

rm -f /tmp/harbor-values-rendered.yaml

# ── CoreDNS rewrite: harbor.DOMAIN → harbor-core ClusterIP (hairpin NAT fix) ──
echo ""
log_info "Adding CoreDNS rewrite for Harbor internal resolution..."
if kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -q "rewrite name harbor"; then
  log_skip "CoreDNS harbor rewrite already exists"
else
  CURRENT_COREFILE=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')
  NEW_COREFILE=$(echo "$CURRENT_COREFILE" | sed "/^    errors$/a\\    rewrite name harbor.${DOMAIN} harbor-core.harbor.svc.cluster.local")
  kubectl patch configmap coredns -n kube-system --type merge \
    -p "{\"data\":{\"Corefile\":$(echo "$NEW_COREFILE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}}"
  kubectl rollout restart deployment/coredns -n kube-system
  kubectl rollout status deployment/coredns -n kube-system --timeout=60s 2>/dev/null || true
  log_ok "CoreDNS: harbor.${DOMAIN} → harbor-core.harbor.svc.cluster.local (no hardcoded IP)"
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
log_info "Harbor pods:"
kubectl get pods -n harbor

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Harbor ready"
echo "  https://harbor.${DOMAIN}"
echo "  Login: admin / [HARBOR_ADMIN_PASSWORD]"
echo ""
echo "  Docker login:"
echo "  docker login harbor.${DOMAIN} -u admin -p [HARBOR_ADMIN_PASSWORD]"
echo "══════════════════════════════════════════════════════"

log_success "STEP 11"
