#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 11: cert-manager + TLS"

check_state
check_k8s
check_helm
export KUBECONFIG="$KUBECONFIG"

DOMAIN="tools.votantai.me"
CERT_MANAGER_VERSION="v1.14.5"

# ── Install cert-manager ──────────────────────────────────────────────────────
echo ""
log_info "Installing cert-manager ${CERT_MANAGER_VERSION}..."

helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update 2>/dev/null || true

CM_STATUS=$(kubectl get deployment cert-manager -n cert-manager \
  --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

if [ "$CM_STATUS" = "1/1" ]; then
  log_skip "cert-manager already running"
else
  helm upgrade --install cert-manager jetstack/cert-manager \
    -n cert-manager --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    -f "$BASE_DIR/k8s/cert-manager/values.yaml" \
    --timeout 5m --wait
  log_ok "cert-manager installed"
fi

# ── Wait for webhooks to be ready ─────────────────────────────────────────────
echo ""
log_info "Waiting for cert-manager webhooks..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager --timeout=120s
log_ok "cert-manager ready"

# ── ClusterIssuer ─────────────────────────────────────────────────────────────
echo ""
log_info "Applying ClusterIssuer (Let's Encrypt + Route53)..."
kubectl apply -f "$BASE_DIR/k8s/cert-manager/cluster-issuer.yaml"
log_ok "ClusterIssuer applied"

# ── Wildcard Certificate ──────────────────────────────────────────────────────
echo ""
log_info "Requesting wildcard certificate for *.${DOMAIN}..."
kubectl apply -f "$BASE_DIR/k8s/cert-manager/certificate.yaml"

log_info "Waiting for certificate (DNS-01 challenge may take 1-3 minutes)..."
kubectl wait --for=condition=ready certificate/tools-wildcard \
  -n ingress-nginx --timeout=300s
log_ok "Certificate issued: *.${DOMAIN}"

# ── Update ingress rules ──────────────────────────────────────────────────────
echo ""
log_info "Applying updated ingress rules..."

kubectl apply -f "$BASE_DIR/k8s/jenkins/ingress.yaml"
log_ok "Jenkins ingress updated"

kubectl apply -f "$BASE_DIR/k8s/argocd/ingress.yaml"
log_ok "ArgoCD ingress updated"

# Grafana — upgrade helm release với values mới
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f "$BASE_DIR/k8s/monitoring/values.yaml" \
  --reuse-values \
  --timeout 5m
log_ok "Grafana ingress updated"

# ── Update Jenkins jenkinsUrl ─────────────────────────────────────────────────
echo ""
log_info "Updating Jenkins URL to https://jenkins.${DOMAIN}..."

helm upgrade jenkins jenkins/jenkins -n jenkins \
  -f "$BASE_DIR/k8s/jenkins/values.yaml" \
  --timeout 5m
log_ok "Jenkins URL updated"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
log_info "Certificate status:"
kubectl get certificate -n ingress-nginx

echo ""
log_info "Ingress rules:"
kubectl get ingress -A

echo ""
echo "══════════════════════════════════════════════════════"
echo "  TLS setup complete"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  https://jenkins.${DOMAIN}"
echo "  https://argocd.${DOMAIN}"
echo "  https://grafana.${DOMAIN}"
echo "══════════════════════════════════════════════════════"

log_success "STEP 11"
