#!/bin/bash
# STEP 14: Deploy Burst Worker Autoscaler (CronJob)
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 14: Burst Autoscaler"
check_state
check_k8s

[ -n "${BURST_WORKER_ID:-}" ] || { log_error "BURST_WORKER_ID không có trong state. Cần burst_worker_count=1 trong tfvars."; exit 1; }
[ -n "${BURST_WORKER_IP:-}" ] || { log_error "BURST_WORKER_IP không có trong state."; exit 1; }

AUTOSCALER_DIR="$BASE_DIR/k8s/burst-autoscaler"

# Image alpine/k8s có sẵn cả kubectl + aws cli — không cần build
log_info "Dùng image: alpine/k8s:1.29.12"

# ── Apply RBAC ────────────────────────────────────────────────────────────────
log_info "Apply RBAC..."
kubectl apply -f "$AUTOSCALER_DIR/rbac.yaml"

# ── ConfigMap chứa BURST_WORKER_ID + IP (đọc từ state) ───────────────────────
log_info "Tạo ConfigMap burst-autoscaler-config..."
kubectl create configmap burst-autoscaler-config \
  --namespace kube-system \
  --from-literal=burst_worker_id="$BURST_WORKER_ID" \
  --from-literal=burst_worker_ip="$BURST_WORKER_IP" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── ConfigMap state (lưu idle tracking) ──────────────────────────────────────
log_info "Tạo state ConfigMap..."
kubectl apply -f "$AUTOSCALER_DIR/state-configmap.yaml"

# ── ConfigMap chứa script ─────────────────────────────────────────────────────
log_info "Apply script ConfigMap..."
kubectl apply -f "$AUTOSCALER_DIR/configmap.yaml"

# ── CronJob ───────────────────────────────────────────────────────────────────
log_info "Apply CronJob..."
kubectl apply -f "$AUTOSCALER_DIR/cronjob.yaml"

log_ok "Burst autoscaler deployed"
echo ""
echo "  Kiểm tra: kubectl get cronjob burst-autoscaler -n kube-system"
echo "  Xem log:  kubectl logs -n kube-system -l job-name --tail=50"
echo "  State:    kubectl get configmap burst-autoscaler-state -n kube-system -o yaml"

log_success "STEP 14"
