#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 12: Vault"

check_state
check_k8s
check_helm
export KUBECONFIG="$KUBECONFIG"

VAULT_VERSION="0.28.1"

# ── Add Helm repo ─────────────────────────────────────────────────────────────
echo ""
log_info "Adding HashiCorp Helm repo..."
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update 2>/dev/null || true
log_ok "Helm repo ready"

# ── Install / Upgrade Vault ───────────────────────────────────────────────────
echo ""
VAULT_STATUS=$(kubectl get statefulset vault -n vault \
  --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

if [ "$VAULT_STATUS" = "1/1" ]; then
  log_skip "Vault already running"
else
  log_info "Installing Vault ${VAULT_VERSION}..."
  sed \
    -e "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" \
    -e "s|AWS_REGION_PLACEHOLDER|${AWS_REGION}|g" \
    "$BASE_DIR/k8s/vault/values.yaml" > /tmp/vault-values-rendered.yaml
  helm upgrade --install vault hashicorp/vault \
    -n vault --create-namespace \
    --version "$VAULT_VERSION" \
    -f /tmp/vault-values-rendered.yaml \
    --timeout 5m --wait
  rm -f /tmp/vault-values-rendered.yaml
  log_ok "Vault installed"
fi

# ── Wait for vault-0 pod ──────────────────────────────────────────────────────
echo ""
log_info "Waiting for vault-0 pod..."
kubectl wait --for=condition=ready pod/vault-0 -n vault --timeout=120s 2>/dev/null || \
  log_info "vault-0 may need initialization — check status below"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
log_info "Vault pods:"
kubectl get pods -n vault

echo ""
log_info "Vault ingress:"
kubectl get ingress -n vault

echo ""
VAULT_INIT=$(kubectl exec vault-0 -n vault -- vault status -format=json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('initialized:', d['initialized'], '| sealed:', d['sealed'])" \
  2>/dev/null || echo "unable to check status")

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Vault ready"
echo "  https://vault.${DOMAIN}"
echo "  Status: $VAULT_INIT"
echo ""
echo "  If first install — run setup:"
echo "  bash k8s/vault/setup-vault.sh"
echo "══════════════════════════════════════════════════════"

log_success "STEP 12"
