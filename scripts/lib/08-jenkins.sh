#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 08: Jenkins"

check_state
check_k8s
check_helm
export KUBECONFIG="$KUBECONFIG"

# -- Resolve password ----------------------------------------------------------─
echo ""
log_info "Resolving Jenkins admin password..."
if [ -z "${JENKINS_ADMIN_PASSWORD:-}" ]; then
  log_error "JENKINS_ADMIN_PASSWORD not set"
  log_info  "Add to .env.secret: JENKINS_ADMIN_PASSWORD=\"xxx\""
  exit 1
fi
log_ok "Jenkins password resolved"

# -- Add Helm repo ------------------------------------------------------------─
echo ""
helm repo add jenkins https://charts.jenkins.io 2>/dev/null || true
helm repo update 2>/dev/null || true

# -- Install / Upgrade Jenkins ------------------------------------------------─
echo ""
log_info "Deploying/upgrading Jenkins..."

kubectl wait --for=condition=ready pod -l k8s-app=kube-dns \
  -n kube-system --timeout=60s 2>/dev/null || true

kubectl create namespace jenkins 2>/dev/null || true

# Apply scoped RBAC (not cluster-admin) — k8s manifest, stays in k8s/
kubectl apply -f "$BASE_DIR/k8s/jenkins/rbac.yaml"

# Values: base + cloud storageClass overlay + password/domain
STORAGE_OVERLAY="$BASE_DIR/tools/overlays/${CLOUD}/values/storage.yaml"

_jenkins_flags=(
  -f "$BASE_DIR/tools/base/values/jenkins.yaml"
)
[ -f "$STORAGE_OVERLAY" ] && _jenkins_flags+=(-f "$STORAGE_OVERLAY")
_jenkins_flags+=(
  --set "controller.admin.password=${JENKINS_ADMIN_PASSWORD}"
  --set "controller.jenkinsUrl=https://jenkins.${DOMAIN}"
)

helm upgrade --install jenkins jenkins/jenkins \
  -n jenkins \
  "${_jenkins_flags[@]}" \
  --timeout 10m --wait

log_ok "Jenkins deployed/upgraded"

# -- Harbor credentials secret (dùng cho Kaniko build image) ------------------
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

# -- Ingress ------------------------------------------------------------------─
envsubst < "$BASE_DIR/tools/ingresses/jenkins.yaml" | kubectl apply -f -
log_ok "Jenkins ingress applied"

# -- Verify --------------------------------------------------------------------
echo ""
log_info "Jenkins pods:"
kubectl get pods -n jenkins

echo ""
log_info "Jenkins ingress:"
kubectl get ingress -n jenkins

echo ""
echo "======================================================"
echo "  Jenkins ready"
echo "  https://jenkins.${DOMAIN}"
echo "  Login: admin / [JENKINS_ADMIN_PASSWORD]"
echo "======================================================"

log_success "STEP 08"
