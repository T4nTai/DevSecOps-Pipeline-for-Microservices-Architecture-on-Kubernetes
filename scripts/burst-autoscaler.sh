#!/usr/bin/env bash
# burst-autoscaler.sh — Tự động start/stop burst worker dựa trên pending pods
#
# Logic:
#   - Cứ mỗi CHECK_INTERVAL giây kiểm tra pod Pending do Insufficient cpu/memory
#   - Nếu có pod Pending → start burst worker
#   - Nếu không có pod Pending và burst worker đã idle IDLE_TIMEOUT giây → stop
#
# Usage:
#   bash scripts/burst-autoscaler.sh            # chạy foreground
#   bash scripts/burst-autoscaler.sh &          # chạy nền
#   bash scripts/burst-autoscaler.sh --dry-run  # chỉ log, không thực thi

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$BASE_DIR/.deploy-state.env"
KUBECONFIG="$BASE_DIR/.kubeconfig"
REGION="ap-southeast-1"

CHECK_INTERVAL="${CHECK_INTERVAL:-60}"   # kiểm tra mỗi 60 giây
IDLE_TIMEOUT="${IDLE_TIMEOUT:-300}"      # stop sau 5 phút không có pending pods
DRY_RUN="${1:-}"

export KUBECONFIG

# ── Màu log ───────────────────────────────────────────────────────────────────
_R="\033[31m" _G="\033[32m" _Y="\033[33m" _C="\033[36m" _X="\033[0m" _B="\033[1m"
ts()      { date '+%H:%M:%S'; }
log_info(){ echo -e "$(ts) ${_C}[AUTO ]${_X} $*"; }
log_ok()  { echo -e "$(ts) ${_G}[OK   ]${_X} $*"; }
log_warn(){ echo -e "$(ts) ${_Y}[WARN ]${_X} $*"; }
log_err() { echo -e "$(ts) ${_R}[ERR  ]${_X} $*"; }

# ── Load state ────────────────────────────────────────────────────────────────
[ -f "$STATE_FILE" ] || { log_err "State file not found. Run step 01 first."; exit 1; }
source "$STATE_FILE"

[ -n "${BURST_WORKER_ID:-}" ] || { log_err "BURST_WORKER_ID not set — burst_worker_count=0 in tfvars."; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
get_ec2_state() {
  aws ec2 describe-instances \
    --instance-ids "$BURST_WORKER_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown"
}

# Trả về số pod đang Pending do thiếu CPU/memory
count_insufficient_pods() {
  kubectl get events \
    --all-namespaces \
    --field-selector reason=FailedScheduling \
    -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('items', [])
count = 0
for e in items:
    msg = e.get('message','') or ''
    if 'Insufficient cpu' in msg or 'Insufficient memory' in msg:
        count += 1
print(count)
" 2>/dev/null || echo "0"
}

# Kiểm tra trực tiếp pod Pending (dự phòng nếu events đã expire)
count_pending_pods() {
  kubectl get pods \
    --all-namespaces \
    --field-selector=status.phase=Pending \
    --no-headers 2>/dev/null \
    | wc -l | tr -d ' '
}

do_start() {
  if [ "$DRY_RUN" = "--dry-run" ]; then
    log_warn "[DRY-RUN] Sẽ chạy: bash scripts/scale-node.sh start"
    return
  fi
  bash "$BASE_DIR/scripts/scale-node.sh" start
}

do_stop() {
  if [ "$DRY_RUN" = "--dry-run" ]; then
    log_warn "[DRY-RUN] Sẽ chạy: bash scripts/scale-node.sh stop"
    return
  fi
  bash "$BASE_DIR/scripts/scale-node.sh" stop
}

# ── Main loop ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${_B}══════════════════════════════════════════════${_X}"
echo -e "${_B}  Burst Worker Autoscaler                     ${_X}"
echo -e "${_B}══════════════════════════════════════════════${_X}"
echo "  Burst Worker:   $BURST_WORKER_ID"
echo "  Check interval: ${CHECK_INTERVAL}s"
echo "  Idle timeout:   ${IDLE_TIMEOUT}s"
[ "$DRY_RUN" = "--dry-run" ] && echo -e "  ${_Y}Mode: DRY-RUN (chỉ log, không thực thi)${_X}"
echo ""

LAST_ACTIVE=0          # timestamp lần cuối có pending pods
BURST_STARTING=false   # đang trong quá trình start (tránh start nhiều lần)

while true; do
  NOW=$(date +%s)
  EC2_STATE=$(get_ec2_state)
  INSUFFICIENT=$(count_insufficient_pods)
  PENDING=$(count_pending_pods)

  # ── Có pod bị thiếu tài nguyên → cần scale up ──────────────────────────────
  if [ "$INSUFFICIENT" -gt 0 ] || [ "$PENDING" -gt 0 ]; then
    LAST_ACTIVE=$NOW

    if [ "$EC2_STATE" = "stopped" ] && [ "$BURST_STARTING" = "false" ]; then
      log_warn "Phát hiện ${INSUFFICIENT} FailedScheduling + ${PENDING} Pending pods"
      log_info "Đang start burst worker..."
      BURST_STARTING=true
      do_start && BURST_STARTING=false || {
        log_err "Start burst worker thất bại"
        BURST_STARTING=false
      }
    elif [ "$EC2_STATE" = "running" ]; then
      log_info "Burst worker đang chạy — ${INSUFFICIENT} scheduling failures, ${PENDING} pending pods"
      BURST_STARTING=false
    elif [ "$EC2_STATE" = "pending" ]; then
      log_info "Burst worker đang khởi động (EC2: pending)..."
    else
      log_info "EC2 state: $EC2_STATE | Pending: $PENDING | Failures: $INSUFFICIENT"
    fi

  # ── Không có pending pods → kiểm tra có nên stop không ────────────────────
  else
    if [ "$EC2_STATE" = "running" ]; then
      IDLE_SECS=$((NOW - LAST_ACTIVE))

      if [ "$LAST_ACTIVE" -eq 0 ]; then
        # Burst worker đang running nhưng autoscaler vừa khởi động
        LAST_ACTIVE=$NOW
        log_info "Burst worker đang chạy — bắt đầu đếm idle time"
      elif [ "$IDLE_SECS" -ge "$IDLE_TIMEOUT" ]; then
        log_info "Không có pending pods trong ${IDLE_SECS}s → stop burst worker"
        do_stop
        LAST_ACTIVE=0
        BURST_STARTING=false
      else
        REMAINING=$((IDLE_TIMEOUT - IDLE_SECS))
        log_info "Burst worker idle ${IDLE_SECS}s — stop sau ${REMAINING}s nữa nếu không có workload"
      fi
    else
      log_info "EC2: $EC2_STATE | Không có pending pods — đang nghỉ"
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
