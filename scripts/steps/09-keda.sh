#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 09: KEDA + HTTP Add-on"

check_state
check_k8s
check_dns
check_helm
export KUBECONFIG="$KUBECONFIG"

KEDA_HTTP_VERSION="0.14.0"

# ── KEDA core ─────────────────────────────────────────────────────────────────
echo ""
log_info "Deploying KEDA..."

helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update 2>/dev/null || true

KEDA_STATUS=$(kubectl get deployment keda-operator -n keda \
  --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

if [ "$KEDA_STATUS" = "1/1" ]; then
  log_skip "KEDA already running"
else
  helm upgrade --install keda kedacore/keda \
    -n keda --create-namespace \
    -f "$BASE_DIR/k8s/keda/values.yaml" \
    --timeout 10m --wait
  log_ok "KEDA deployed on master"
fi

# ── KEDA HTTP Add-on ──────────────────────────────────────────────────────────
echo ""
log_info "Deploying KEDA HTTP Add-on v${KEDA_HTTP_VERSION}..."

HTTP_ADDON_STATUS=$(kubectl get deployment keda-add-ons-http-controller-manager \
  -n keda --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

if [ "$HTTP_ADDON_STATUS" = "1/1" ]; then
  log_skip "KEDA HTTP Add-on already running"
else
  helm upgrade --install keda-add-ons-http kedacore/keda-add-ons-http \
    --version "$KEDA_HTTP_VERSION" -n keda --create-namespace \
    --set interceptor.replicas.min=1 \
    --set interceptor.replicas.max=1 \
    --set scaler.replicas=1 \
    --set interceptor.resources.requests.cpu=50m \
    --set interceptor.resources.requests.memory=64Mi \
    --set interceptor.resources.limits.cpu=200m \
    --set interceptor.resources.limits.memory=128Mi \
    --set scaler.resources.requests.cpu=50m \
    --set scaler.resources.requests.memory=64Mi \
    --set scaler.resources.limits.cpu=200m \
    --set scaler.resources.limits.memory=128Mi \
    --timeout 10m --wait
  log_ok "KEDA HTTP Add-on v${KEDA_HTTP_VERSION} deployed"
fi

# ── Cleanup old ScaledObjects ─────────────────────────────────────────────────
echo ""
log_info "Removing old ScaledObjects..."
kubectl delete scaledobject jenkins-scaledobject -n jenkins 2>/dev/null \
  && log_ok "Jenkins ScaledObject removed" || log_skip "not found"
kubectl delete scaledobject argocd-scaledobject -n argocd 2>/dev/null \
  && log_ok "ArgoCD ScaledObject removed"  || log_skip "not found"

# ── Apply ExternalName Services + HTTPScaledObjects ───────────────────────────
echo ""
log_info "Applying ExternalName Services..."

for ns_name in "jenkins:jenkins" "argocd:argocd"; do
  ns="${ns_name%%:*}"; svc="${ns_name##*:}"
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    kubectl apply -f "$BASE_DIR/k8s/${svc}/keda-interceptor-svc.yaml" 2>/dev/null \
      && log_ok "${svc} ExternalName Service applied" \
      || log_warn "${svc} keda-interceptor-svc.yaml not found (skipping)"
  else
    log_skip "${ns} namespace not found"
  fi
done

echo ""
log_info "Applying HTTPScaledObjects + Ingress..."

if kubectl get statefulset jenkins -n jenkins >/dev/null 2>&1; then
  kubectl apply -f "$BASE_DIR/k8s/jenkins/http-scaledobject.yaml" 2>/dev/null || true
  kubectl apply -f "$BASE_DIR/k8s/jenkins/ingress.yaml" 2>/dev/null || true
  log_ok "Jenkins HTTPScaledObject + Ingress applied"
fi

if kubectl get deployment argocd-server -n argocd >/dev/null 2>&1; then
  kubectl apply -f "$BASE_DIR/k8s/argocd/http-scaledobject.yaml" 2>/dev/null || true
  kubectl apply -f "$BASE_DIR/k8s/argocd/ingress.yaml" 2>/dev/null || true
  log_ok "ArgoCD HTTPScaledObject + Ingress applied"
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
log_info "KEDA pods:"
kubectl get pods -n keda -o wide

log_info "HTTPScaledObjects:"
kubectl get httpscaledobjects --all-namespaces 2>/dev/null || true

FAILED=$(kubectl get pods -n keda --no-headers 2>/dev/null \
  | grep -v "Running\|Completed" | wc -l | tr -d '[:space:]' || echo "0")
[ "${FAILED:-0}" -gt "0" ] && \
  kubectl get pods -n keda --no-headers | grep -v "Running\|Completed" || \
  log_ok "All KEDA pods running"

log_success "STEP 09"
