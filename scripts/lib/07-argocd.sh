#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 07: ArgoCD"

check_state
check_k8s
check_dns
check_helm
export KUBECONFIG="$KUBECONFIG"

LB_ENDPOINT="${LB_IP:-${NLB_DNS:-}}"
check_vars BASTION_IP SSH_KEY
[ -n "$LB_ENDPOINT" ] || { log_error "LB_IP or NLB_DNS not set"; exit 1; }

ARGOCD_CHART_VERSION="9.4.12"

# ── Helper: save secret to vault (cloud-aware) ────────────────────────────────
_save_to_vault() {
  local name="$1" value="$2"
  if [[ "$CLOUD" == "azure" ]] && [ -n "${VAULT_NAME:-}" ]; then
    if az keyvault show --name "$VAULT_NAME" --query name -o tsv >/dev/null 2>&1; then
      az keyvault secret set --vault-name "$VAULT_NAME" \
        --name "$name" --value "$value" --output none 2>/dev/null || true
      log_ok "Saved to Azure KV: $name"
    fi
  elif [[ "$CLOUD" == "aws" ]]; then
    aws ssm put-parameter \
      --name "/${CLUSTER_NAME:-devsecops}/$name" \
      --value "$value" --type SecureString \
      --overwrite 2>/dev/null || true
    log_ok "Saved to AWS SSM: $name"
  fi
}

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update 2>/dev/null || true

_argocd_healthy() {
  local s r rs
  s=$(kubectl get deployment argocd-server -n argocd --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")
  r=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server \
    --no-headers 2>/dev/null | grep " Running " | wc -l | tr -d '[:space:]' || echo "0")
  rs=$(kubectl get secret argocd-redis -n argocd --no-headers 2>/dev/null || echo "")
  [ "$s" = "1/1" ] && [ "${r:-0}" = "1" ] && [ -n "$rs" ]
}

_argocd_cleanup() {
  log_info "Cleaning up ArgoCD..."
  helm uninstall argocd -n argocd 2>/dev/null || true
  kubectl delete namespace argocd --wait=true 2>/dev/null || true
  sleep 15
}

_argocd_ensure_secret() {
  local rs password
  rs=$(kubectl get secret argocd-redis -n argocd --no-headers 2>/dev/null || echo "")
  if [ -z "$rs" ]; then
    password="${ARGOCD_REDIS_PASSWORD:-$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)}"
    kubectl create secret generic argocd-redis --namespace argocd --from-literal=auth="$password"
    update_secret "ARGOCD_REDIS_PASSWORD" "$password"
    _save_to_vault "argocd-redis-password" "$password"
    log_ok "Redis secret created"
  else
    log_skip "Redis secret already exists"
  fi
}

echo ""
log_info "Deploying ArgoCD..."

if _argocd_healthy; then
  log_info "ArgoCD already running — upgrading config..."
  sed \
    -e "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" \
    "$BASE_DIR/k8s/argocd/values.yaml" > /tmp/argocd-values-rendered.yaml
  helm upgrade argocd argo/argo-cd \
    --version "$ARGOCD_CHART_VERSION" -n argocd \
    -f /tmp/argocd-values-rendered.yaml --timeout 5m --wait
  kubectl rollout restart deployment/argocd-server -n argocd
  kubectl rollout status deployment/argocd-server -n argocd --timeout=60s
elif kubectl get namespace argocd >/dev/null 2>&1; then
  log_warn "ArgoCD namespace exists but unhealthy — reinstalling..."
  _argocd_cleanup
fi

if ! _argocd_healthy; then
  kubectl wait --for=condition=ready pod -l k8s-app=kube-dns \
    -n kube-system --timeout=60s 2>/dev/null || true
  kubectl create namespace argocd 2>/dev/null || true
  _argocd_ensure_secret

  ARGOCD_INSTALLED=false
  for attempt in $(seq 1 3); do
    log_info "Attempt $attempt/3..."
    sed \
      -e "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" \
      "$BASE_DIR/k8s/argocd/values.yaml" > /tmp/argocd-values-rendered.yaml
    if helm upgrade --install argocd argo/argo-cd \
      --version "$ARGOCD_CHART_VERSION" -n argocd --create-namespace \
      -f /tmp/argocd-values-rendered.yaml --timeout 15m --wait; then
      sleep 15
      if _argocd_healthy; then
        log_ok "ArgoCD deployed"
        ARGOCD_INSTALLED=true; break
      fi
    fi
    log_warn "Attempt $attempt failed — retrying..."
    _argocd_cleanup
    kubectl create namespace argocd 2>/dev/null || true
    _argocd_ensure_secret
  done
  [ "$ARGOCD_INSTALLED" = false ] && { log_error "ArgoCD install failed after 3 attempts"; exit 1; }
fi
rm -f /tmp/argocd-values-rendered.yaml

envsubst < "$BASE_DIR/k8s/argocd/ingress.yaml" | kubectl apply -f -
log_ok "ArgoCD Ingress applied"

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")
if [ -n "$ARGOCD_PASSWORD" ]; then
  update_secret "ARGOCD_ADMIN_PASSWORD" "$ARGOCD_PASSWORD"
  _save_to_vault "argocd-admin-password" "$ARGOCD_PASSWORD"
fi

echo ""
log_ok "ArgoCD deployed"
log_info "  URL:      http://$LB_ENDPOINT/argocd"
log_info "  Username: admin"
log_info "  Password: ${ARGOCD_PASSWORD:-(see vault/SSM: argocd-admin-password)}"

# ── Apply Online Boutique ApplicationSet ─────────────────────────────────────
echo ""
log_info "Applying Online Boutique ApplicationSet..."
sed \
  -e "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" \
  -e "s|HARBOR_REGISTRY_PLACEHOLDER|harbor.${DOMAIN}|g" \
  "$BASE_DIR/k8s/argocd/apps/online-boutique-appset.yaml" | kubectl apply -f -
log_ok "ApplicationSet applied"

log_success "STEP 07"
