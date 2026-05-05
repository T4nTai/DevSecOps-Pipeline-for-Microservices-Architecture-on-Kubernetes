#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 08: Jenkins"

check_state
check_k8s
check_helm
export KUBECONFIG="$KUBECONFIG"

DOMAIN="tools.votantai.me"

# ── Resolve password ───────────────────────────────────────────────────────────
echo ""
log_info "Resolving Jenkins admin password..."
if [ -z "${JENKINS_ADMIN_PASSWORD:-}" ]; then
  log_error "JENKINS_ADMIN_PASSWORD not set"
  log_info  "Add to .env.secret: JENKINS_ADMIN_PASSWORD=\"xxx\""
  exit 1
fi
log_ok "Jenkins password resolved"

# ── Add Helm repo ─────────────────────────────────────────────────────────────
echo ""
helm repo add jenkins https://charts.jenkins.io 2>/dev/null || true
helm repo update 2>/dev/null || true

# ── Install / Upgrade Jenkins ─────────────────────────────────────────────────
echo ""
JENKINS_STATUS=$(kubectl get statefulset jenkins -n jenkins \
  --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

if [ "$JENKINS_STATUS" = "1/1" ]; then
  log_skip "Jenkins already running"
else
  log_info "Deploying Jenkins..."

  kubectl wait --for=condition=ready pod -l k8s-app=kube-dns \
    -n kube-system --timeout=60s 2>/dev/null || true

  kubectl create namespace jenkins 2>/dev/null || true

  # Apply scoped RBAC (not cluster-admin)
  kubectl apply -f "$BASE_DIR/k8s/jenkins/rbac.yaml"

  # Render values — inject password
  sed \
    -e "s|JENKINS_ADMIN_PASSWORD_PLACEHOLDER|${JENKINS_ADMIN_PASSWORD}|g" \
    "$BASE_DIR/k8s/jenkins/values.yaml" > /tmp/jenkins-values-rendered.yaml

  helm upgrade --install jenkins jenkins/jenkins \
    -n jenkins \
    -f /tmp/jenkins-values-rendered.yaml \
    --timeout 10m --wait

  rm -f /tmp/jenkins-values-rendered.yaml
  log_ok "Jenkins deployed"
fi

# ── Harbor credentials secret (dùng cho Kaniko build image) ──────────────────
if [ -z "${HARBOR_ADMIN_PASSWORD:-}" ]; then
  log_warn "HARBOR_ADMIN_PASSWORD không set — bỏ qua tạo harbor-credentials secret"
else
  kubectl create secret docker-registry harbor-credentials \
    --namespace jenkins \
    --docker-server="harbor.${DOMAIN}" \
    --docker-username=admin \
    --docker-password="$HARBOR_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  log_ok "harbor-credentials secret applied"
fi

# ── Ingress ───────────────────────────────────────────────────────────────────
kubectl apply -f "$BASE_DIR/k8s/jenkins/ingress.yaml"
log_ok "Jenkins ingress applied"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
log_info "Jenkins pods:"
kubectl get pods -n jenkins

echo ""
log_info "Jenkins ingress:"
kubectl get ingress -n jenkins

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Jenkins ready"
echo "  https://jenkins.${DOMAIN}"
echo "  Login: admin / [JENKINS_ADMIN_PASSWORD]"
echo "══════════════════════════════════════════════════════"

log_success "STEP 08"
