#!/usr/bin/env bash
# scale-node.sh — Start/stop burst worker node
#
# Usage:
#   bash scripts/scale-node.sh start   # start instance + wait for K8s Ready
#   bash scripts/scale-node.sh stop    # drain + stop instance
#   bash scripts/scale-node.sh status  # show current state

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$BASE_DIR/.deploy-state.env"
KUBECONFIG="$BASE_DIR/.kubeconfig"
REGION="ap-southeast-1"

# -- Load state ----------------------------------------------------------------
[ -f "$STATE_FILE" ] || { echo "[ERROR] State file not found. Run step 01 first."; exit 1; }
source "$STATE_FILE"
export KUBECONFIG

[ -n "${BURST_WORKER_ID:-}" ] || { echo "[ERROR] BURST_WORKER_ID not set — burst_worker_count=0 in tfvars."; exit 1; }

# -- Helpers ------------------------------------------------------------------─
get_instance_state() {
  aws ec2 describe-instances \
    --instance-ids "$BURST_WORKER_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown"
}

get_node_name() {
  kubectl get nodes -o wide --no-headers 2>/dev/null \
    | awk -v ip="$BURST_WORKER_IP" '$6==ip {print $1}'
}

# -- Status --------------------------------------------------------------------
cmd_status() {
  EC2_STATE=$(get_instance_state)
  NODE_NAME=$(get_node_name || echo "")
  NODE_STATUS=$(kubectl get node "$NODE_NAME" --no-headers 2>/dev/null | awk '{print $2}' || echo "unknown")

  echo ""
  echo "======================================"
  echo "  Burst Worker Status"
  echo "======================================"
  echo "  Instance ID: $BURST_WORKER_ID"
  echo "  Private IP:  ${BURST_WORKER_IP:-unknown}"
  echo "  EC2 state:   $EC2_STATE"
  echo "  K8s node:    ${NODE_NAME:-not found}"
  echo "  K8s status:  $NODE_STATUS"
  echo "======================================"
}

# -- Start --------------------------------------------------------------------─
cmd_start() {
  EC2_STATE=$(get_instance_state)

  if [ "$EC2_STATE" = "running" ]; then
    echo "[SKIP] Burst worker already running"
    NODE_NAME=$(get_node_name || echo "")
    [ -n "$NODE_NAME" ] && kubectl uncordon "$NODE_NAME" 2>/dev/null || true
    return 0
  fi

  echo "[INFO] Starting burst worker: $BURST_WORKER_ID ..."
  aws ec2 start-instances --instance-ids "$BURST_WORKER_ID" --region "$REGION" > /dev/null

  echo "[INFO] Waiting for EC2 instance to be running..."
  aws ec2 wait instance-running --instance-ids "$BURST_WORKER_ID" --region "$REGION"
  echo "[OK  ] Instance running"

  echo "[INFO] Waiting for K8s node to join cluster (up to 3 minutes)..."
  TIMEOUT=180
  ELAPSED=0
  NODE_NAME=""
  NODE_READY=""
  while [ $ELAPSED -lt $TIMEOUT ]; do
    NODE_NAME=$(get_node_name || echo "")
    if [ -n "$NODE_NAME" ]; then
      NODE_READY=$(kubectl get node "$NODE_NAME" --no-headers 2>/dev/null | awk '{print $2}')
      if [ "$NODE_READY" = "Ready" ]; then
        break
      fi
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    echo "[INFO] Waiting... ${ELAPSED}s"
  done

  if [ -z "$NODE_NAME" ] || [ "$NODE_READY" != "Ready" ]; then
    echo "[ERROR] Node not ready after ${TIMEOUT}s. Check kubelet on burst worker."
    exit 1
  fi

  echo "[INFO] Uncordoning node: $NODE_NAME"
  kubectl uncordon "$NODE_NAME" 2>/dev/null || true

  echo ""
  echo "[OK  ] Burst worker ready: $NODE_NAME"
}

# -- Stop ----------------------------------------------------------------------
cmd_stop() {
  EC2_STATE=$(get_instance_state)

  if [ "$EC2_STATE" = "stopped" ]; then
    echo "[SKIP] Burst worker already stopped"
    return 0
  fi

  NODE_NAME=$(get_node_name || echo "")

  if [ -n "$NODE_NAME" ]; then
    echo "[INFO] Draining node: $NODE_NAME ..."
    kubectl drain "$NODE_NAME" \
      --ignore-daemonsets \
      --delete-emptydir-data \
      --timeout=120s \
      --force 2>/dev/null || true

    echo "[INFO] Cordoning node..."
    kubectl cordon "$NODE_NAME" 2>/dev/null || true
  else
    echo "[WARN] K8s node not found — skipping drain"
  fi

  echo "[INFO] Stopping instance: $BURST_WORKER_ID ..."
  aws ec2 stop-instances --instance-ids "$BURST_WORKER_ID" --region "$REGION" > /dev/null
  echo "[OK  ] Burst worker stopped. (EBS preserved)"
}

# -- Main ----------------------------------------------------------------------
ACTION="${1:-status}"
case "$ACTION" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *)
    echo "Usage: $0 start|stop|status"
    exit 1
    ;;
esac
