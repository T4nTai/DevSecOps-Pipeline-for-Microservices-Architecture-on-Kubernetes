#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 15: Argo Rollouts"

check_state
check_k8s
check_helm
export KUBECONFIG="$KUBECONFIG"

# ── Install Argo Rollouts ─────────────────────────────────────────────────────
ROLLOUTS_STATUS=$(kubectl get deployment argo-rollouts -n argo-rollouts \
  --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

if [ "$ROLLOUTS_STATUS" = "1/1" ]; then
  log_skip "Argo Rollouts already running"
else
  log_info "Installing Argo Rollouts..."

  helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
  helm repo update 2>/dev/null || true

  helm upgrade --install argo-rollouts argo/argo-rollouts \
    -n argo-rollouts \
    --create-namespace \
    -f "$BASE_DIR/k8s/argo-rollouts/values.yaml" \
    --timeout 5m --wait

  log_ok "Argo Rollouts installed"
fi

# ── Install kubectl plugin (optional, for local promote/abort) ────────────────
if ! command -v kubectl-argo-rollouts &>/dev/null; then
  log_info "Installing kubectl argo-rollouts plugin..."
  curl -sL https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64 \
    -o /usr/local/bin/kubectl-argo-rollouts
  chmod +x /usr/local/bin/kubectl-argo-rollouts
  log_ok "kubectl argo-rollouts plugin installed"
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
log_info "Argo Rollouts pods:"
kubectl get pods -n argo-rollouts

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Argo Rollouts ready"
echo "  Dashboard: https://rollouts.tools.votantai.me"
echo ""
echo "  Canary commands:"
echo "    kubectl argo rollouts get rollout frontend -n default --watch"
echo "    kubectl argo rollouts promote frontend -n default"
echo "    kubectl argo rollouts abort frontend -n default"
echo "══════════════════════════════════════════════════════"

log_success "STEP 15"
