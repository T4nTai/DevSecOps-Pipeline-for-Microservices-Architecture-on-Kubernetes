#!/usr/bin/env bash
# join-burst-worker.sh — One-time setup: join burst worker to K8s cluster via Kubespray
#
# Run ONCE after terraform apply creates the burst_worker EC2 instance.
# After this script completes, the burst worker is in the cluster and stopped.
# Use scripts/scale-node.sh start/stop for day-to-day lifecycle management.
#
# Usage:
#   bash scripts/join-burst-worker.sh

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$BASE_DIR/.deploy-state.env"
KUBESPRAY_SRC="$BASE_DIR/kubespray/kubespray-src"
VENV_DIR="$BASE_DIR/kubespray/.venv"
KUBE_INVENTORY_DIR="$KUBESPRAY_SRC/inventory/devsecops"
REGION="${REGION:-ap-southeast-1}"

[ -f "$STATE_FILE" ] || { echo "[ERROR] State file not found. Run step 01 first."; exit 1; }
source "$STATE_FILE"
export KUBECONFIG="$BASE_DIR/.kubeconfig"

[ -n "${BURST_WORKER_ID:-}" ] || { echo "[ERROR] BURST_WORKER_ID not set in state. Ensure burst_worker_count=1 in tfvars and re-run step 01."; exit 1; }
[ -n "${BURST_WORKER_IP:-}" ] || { echo "[ERROR] BURST_WORKER_IP not set in state."; exit 1; }
[ -n "${BASTION_IP:-}" ]      || { echo "[ERROR] BASTION_IP not set in state."; exit 1; }

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

echo ""
echo "══════════════════════════════════════════════"
echo "  Join Burst Worker to Kubernetes Cluster"
echo "══════════════════════════════════════════════"
echo "  Burst Worker ID: $BURST_WORKER_ID"
echo "  Burst Worker IP: $BURST_WORKER_IP"
echo "  Bastion:         $BASTION_IP"
echo ""

# ── Ensure burst worker is running ───────────────────────────────────────────
EC2_STATE=$(aws ec2 describe-instances \
  --instance-ids "$BURST_WORKER_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null || echo "unknown")

if [ "$EC2_STATE" != "running" ]; then
  echo "[INFO] Starting burst worker instance..."
  aws ec2 start-instances --instance-ids "$BURST_WORKER_ID" --region "$REGION" > /dev/null
  aws ec2 wait instance-running --instance-ids "$BURST_WORKER_ID" --region "$REGION"
  echo "[OK  ] Instance running — waiting 30s for SSH daemon..."
  sleep 30
fi

# ── Wait for SSH reachability ─────────────────────────────────────────────────
echo "[INFO] Waiting for SSH on burst worker..."
for i in $(seq 1 20); do
  if ssh -i "$SSH_KEY" \
       -o StrictHostKeyChecking=no \
       -o ConnectTimeout=5 \
       -o ProxyJump="ubuntu@${BASTION_IP}" \
       ubuntu@"$BURST_WORKER_IP" true 2>/dev/null; then
    echo "[OK  ] SSH ready"
    break
  fi
  echo "[INFO] Attempt $i/20 — waiting 15s..."
  sleep 15
  if [ "$i" -eq 20 ]; then
    echo "[ERROR] SSH not reachable after 5 minutes"
    exit 1
  fi
done

# ── Update inventories ────────────────────────────────────────────────────────
update_inventory() {
  local inv="$1"
  [ -f "$inv" ] || return

  if grep -q "burst-worker" "$inv" 2>/dev/null; then
    echo "[SKIP] burst-worker already in $inv"
    return
  fi

  # Add to [all] section
  sed -i "/^\[all\]/a burst-worker  ansible_host=${BURST_WORKER_IP}  ip=${BURST_WORKER_IP}  ansible_user=ubuntu  ansible_ssh_private_key_file=${SSH_KEY}  ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyJump=ubuntu@${BASTION_IP}'" "$inv"

  # Add to [kube_node] section
  sed -i "/^\[kube_node\]/a burst-worker" "$inv"

  echo "[OK  ] Updated: $inv"
}

echo "[INFO] Updating Kubespray inventories..."
update_inventory "$BASE_DIR/kubespray/inventory.ini"
update_inventory "$KUBE_INVENTORY_DIR/hosts.ini"

echo ""
cat "$KUBE_INVENTORY_DIR/hosts.ini"

# ── Run Kubespray scale.yml ───────────────────────────────────────────────────
echo ""
echo "[INFO] Running Kubespray scale.yml to join burst-worker..."
echo "       This takes 5-10 minutes..."

cd "$KUBESPRAY_SRC"
export ANSIBLE_ROLES_PATH="$KUBESPRAY_SRC/roles"
export ANSIBLE_COLLECTIONS_PATH="$KUBESPRAY_SRC/collections"
export ANSIBLE_HOST_KEY_CHECKING=False

"$VENV_DIR/bin/ansible-playbook" \
  -i "$KUBE_INVENTORY_DIR/hosts.ini" \
  --private-key "$SSH_KEY" \
  --become \
  --timeout 60 \
  --limit burst-worker \
  -e 'ansible_become_method=sudo' \
  scale.yml \
  2>&1 | tee /tmp/kubespray-scale.log

# ── Verify node joined ────────────────────────────────────────────────────────
echo ""
echo "[INFO] Verifying node joined cluster..."
sleep 30

NODE_NAME=$(kubectl get nodes -o wide --no-headers 2>/dev/null \
  | awk -v ip="$BURST_WORKER_IP" '$6==ip {print $1}')

if [ -z "$NODE_NAME" ]; then
  echo "[ERROR] burst-worker did not join cluster. Check /tmp/kubespray-scale.log"
  exit 1
fi

echo "[OK  ] Node joined: $NODE_NAME"
kubectl get node "$NODE_NAME"

# ── Cordon + stop ─────────────────────────────────────────────────────────────
echo ""
echo "[INFO] Cordoning node..."
kubectl cordon "$NODE_NAME"

echo "[INFO] Stopping burst worker EC2 instance..."
aws ec2 stop-instances --instance-ids "$BURST_WORKER_ID" --region "$REGION" > /dev/null

echo ""
echo "[OK  ] Burst worker joined cluster and stopped."
echo "       Use: bash scripts/scale-node.sh start   # to bring online"
echo "       Use: bash scripts/scale-node.sh stop    # to shut down again"
echo "══════════════════════════════════════════════"
