#!/bin/bash
# STEP 03: Fix kube-proxy, CoreDNS, nodelocaldns
# Azure: forwards to 168.63.129.16 (Azure DNS)
# AWS:   forwards to 169.254.169.253 (AWS VPC DNS)
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 03: Fix DNS + kube-proxy"

check_state
check_vars BASTION_IP SSH_KEY
check_k8s
export KUBECONFIG="$KUBECONFIG"

# Cloud-specific upstream DNS resolver
if [[ "$CLOUD" == "azure" ]]; then
  UPSTREAM_DNS="168.63.129.16"
else
  UPSTREAM_DNS="169.254.169.253"
fi

MASTER_IP="${MASTER_IP:-${CONTROL_PLANE_IP:-}}"
check_vars MASTER_IP

# ── Fix kube-proxy ────────────────────────────────────────────────────────────
echo ""
log_info "Fixing kube-proxy configmap..."

kubectl get configmap kube-proxy -n kube-system -o yaml \
  | sed "s|server: https://127.0.0.1:6443|server: https://$MASTER_IP:6443|g" \
  | sed "s|server: https://localhost:6443|server: https://$MASTER_IP:6443|g" \
  | kubectl apply -f - 2>/dev/null || true

log_info "Restarting kube-proxy one node at a time..."
for node in $(kubectl get nodes --no-headers | awk '{print $1}'); do
  POD=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy \
    --field-selector "spec.nodeName=$node" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$POD" ]; then
    log_info "  Restarting kube-proxy on $node..."
    kubectl delete pod -n kube-system "$POD" 2>/dev/null || true
    sleep 30
  fi
done

kubectl rollout status daemonset/kube-proxy -n kube-system --timeout=120s 2>/dev/null || true
log_ok "kube-proxy fixed"

# ── Wait for nodes to stabilize ───────────────────────────────────────────────
echo ""
log_info "Waiting for nodes to stabilize..."
sleep 30

NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null \
  | grep -v ' Ready ' | awk '{print $1}' || true)
if [ -n "$NOT_READY" ]; then
  log_warn "NotReady nodes found — waiting 60s..."
  sleep 60
  NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null \
    | grep -v ' Ready ' | awk '{print $1}' || true)
  if [ -n "$NOT_READY" ]; then
    log_info "Removing NotReady nodes: $NOT_READY"
    echo "$NOT_READY" | xargs kubectl delete node 2>/dev/null || true
    sleep 10
  fi
fi
log_ok "Nodes stable"

# ── Fix CoreDNS ───────────────────────────────────────────────────────────────
echo ""
log_info "Fixing CoreDNS (upstream: $UPSTREAM_DNS)..."

CURRENT_FORWARD=$(kubectl get configmap coredns -n kube-system \
  -o jsonpath='{.data.Corefile}' | grep "forward" | tr -d ' ' || echo "")

if ! echo "$CURRENT_FORWARD" | grep -q "$UPSTREAM_DNS"; then
  kubectl patch configmap coredns -n kube-system --type merge -p "{
    \"data\": {
      \"Corefile\": \".:53 {\n    errors\n    health {\n        lameduck 5s\n    }\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n      pods insecure\n      fallthrough in-addr.arpa ip6.arpa\n    }\n    prometheus :9153\n    forward . ${UPSTREAM_DNS}\n    cache 30\n    loop\n    reload\n    loadbalance\n}\n\"
    }
  }" 2>/dev/null || true
  log_ok "CoreDNS patched to forward → $UPSTREAM_DNS"
else
  log_skip "CoreDNS already configured correctly"
fi

sleep 10
kubectl rollout restart deployment/coredns -n kube-system

COREDNS_READY=false
for i in $(seq 1 10); do
  if kubectl rollout status deployment/coredns -n kube-system --timeout=30s 2>/dev/null; then
    COREDNS_READY=true; break
  fi
  log_info "CoreDNS retry $i/10..."
  kubectl delete pod -n kube-system -l k8s-app=kube-dns 2>/dev/null || true
  sleep 20
done
[ "$COREDNS_READY" = false ] && log_warn "CoreDNS still not ready — continuing..."
log_ok "CoreDNS done"

# ── Fix nodelocaldns ──────────────────────────────────────────────────────────
echo ""
log_info "Fixing nodelocaldns..."

NODELOCAL_COREFILE=$(kubectl get configmap nodelocaldns -n kube-system \
  -o jsonpath='{.data.Corefile}' 2>/dev/null \
  | sed "s|forward \. /etc/resolv\.conf|forward . ${UPSTREAM_DNS}|g" \
  | sed "s|forward \. 8\.8\.8\.8 8\.8\.4\.4|forward . ${UPSTREAM_DNS}|g" \
  | sed "s|forward \. 8\.8\.8\.8|forward . ${UPSTREAM_DNS}|g" || echo "")

if [ -n "$NODELOCAL_COREFILE" ]; then
  kubectl patch configmap nodelocaldns -n kube-system \
    --type merge \
    -p "{\"data\":{\"Corefile\":$(echo "$NODELOCAL_COREFILE" | jq -Rs .)}}"
  sleep 5
  kubectl rollout restart daemonset/nodelocaldns -n kube-system
  kubectl rollout status daemonset/nodelocaldns -n kube-system --timeout=120s 2>/dev/null || true
  log_ok "nodelocaldns fixed"
else
  log_skip "nodelocaldns configmap not found"
fi

# ── Restart calico-node ───────────────────────────────────────────────────────
echo ""
log_info "Restarting calico-node..."
kubectl rollout restart daemonset/calico-node -n kube-system
kubectl rollout status daemonset/calico-node -n kube-system --timeout=120s 2>/dev/null || true
log_ok "calico-node restarted"

sleep 30

# ── Verify DNS ────────────────────────────────────────────────────────────────
echo ""
log_info "Verifying DNS..."

kubectl delete pod -n kube-system dns-verify --force 2>/dev/null || true
sleep 5

EXTERNAL_CHECK="nslookup github.com"
[[ "$CLOUD" == "azure" ]] && EXTERNAL_CHECK="nslookup login.microsoftonline.com"

kubectl run dns-verify --image=busybox:1.28 \
  --restart=Never -n kube-system \
  -- sh -c "
    echo '=== Internal DNS ==='; nslookup kubernetes.default
    echo '=== External DNS ==='; ${EXTERNAL_CHECK}
    echo 'EXIT:0'
  " 2>/dev/null || true

kubectl wait pod dns-verify -n kube-system \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s 2>/dev/null \
  || kubectl wait pod dns-verify -n kube-system \
  --for=jsonpath='{.status.phase}'=Failed --timeout=60s 2>/dev/null || true

DNS_RESULT=$(kubectl logs -n kube-system dns-verify 2>/dev/null || echo "")
kubectl delete pod -n kube-system dns-verify --force 2>/dev/null || true
echo "$DNS_RESULT"

INTERNAL_OK=false; EXTERNAL_OK=false
echo "$DNS_RESULT" | grep -q "kubernetes.default.svc.cluster.local" && INTERNAL_OK=true
EXTERNAL_HOST="github.com"
[[ "$CLOUD" == "azure" ]] && EXTERNAL_HOST="microsoftonline"
echo "$DNS_RESULT" | grep -q "$EXTERNAL_HOST" && EXTERNAL_OK=true

[ "$INTERNAL_OK" = true ] && log_ok "Internal DNS — OK" || log_error "Internal DNS — FAIL"
[ "$EXTERNAL_OK" = true ] && log_ok "External DNS — OK" || log_error "External DNS — FAIL"

if [ "$INTERNAL_OK" = false ] || [ "$EXTERNAL_OK" = false ]; then
  log_error "DNS verification failed"
  exit 1
fi

log_success "STEP 03"
