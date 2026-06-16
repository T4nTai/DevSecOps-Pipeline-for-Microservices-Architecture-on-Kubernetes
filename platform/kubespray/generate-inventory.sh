#!/bin/bash
# Generate Kubespray inventory.ini from Terraform outputs
# Usage: bash platform/kubespray/generate-inventory.sh [CLOUD=aws] [CLUSTER=tools]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Accept CLOUD/CLUSTER as positional args (KEY=VAL format) or env vars
for arg in "$@"; do
  case "$arg" in
    CLOUD=*)      CLOUD="${arg#*=}" ;;
    CLUSTER=*)    CLUSTER="${arg#*=}" ;;
    BASTION_IP=*) BASTION_IP="${arg#*=}" ;;
  esac
done

CLOUD="${CLOUD:-aws}"
CLUSTER="${CLUSTER:-tools}"
ADMIN_USER="${ADMIN_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# When Kubespray runs inside Docker, the host SSH key is mounted at /root/.ssh/id_rsa.
# The inventory must reference the IN-CONTAINER path, not the host path.
# 02-kubespray.sh mounts: -v "${SSH_KEY}:/root/.ssh/id_rsa:ro"
INVENTORY_KEY_PATH="/root/.ssh/id_rsa"

TF_DIR="${BASE_DIR}/infra/aws/envs/${CLUSTER}"
INVENTORY_FILE="${SCRIPT_DIR}/inventory.ini"

if [ ! -d "$TF_DIR" ]; then
  echo "ERROR: Terraform dir not found: $TF_DIR"
  exit 1
fi

echo "==> Reading Terraform outputs (cloud=$CLOUD cluster=$CLUSTER)..."
cd "$TF_DIR"

terraform init -upgrade=false -input=false > /dev/null 2>&1 || true

# Allow BASTION_IP to be passed from env
if [ -z "${BASTION_IP:-}" ]; then
  BASTION_IP=$(terraform output -raw bastion_public_ip 2>/dev/null) || true
fi
if [ -z "${BASTION_IP:-}" ]; then
  echo "ERROR: bastion_public_ip not found in terraform outputs and BASTION_IP not set"
  exit 1
fi

# Use all_control_plane_private_ips (primary + secondary combined)
ALL_CP_IPS=$(terraform output -json all_control_plane_private_ips 2>/dev/null \
  | tr -d '[]" ' | tr ',' '\n' \
  || terraform output -json control_plane_private_ips | tr -d '[]" ' | tr ',' '\n')
WORKER_IPS=$(terraform output -json worker_private_ips \
  | tr -d '[]" ' | tr ',' '\n')
APPS_WORKER_IPS=$(terraform output -json apps_worker_private_ips 2>/dev/null \
  | tr -d '[]" ' | tr ',' '\n' || echo "")

PROXY_ARGS="ansible_ssh_common_args='-o StrictHostKeyChecking=no -o IdentityFile=/root/.ssh/id_rsa -o ProxyCommand=\"ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no -W %h:%p ${ADMIN_USER}@${BASTION_IP}\"'"

echo "    Bastion: $BASTION_IP"

ALL_SECTION="" CP_SECTION="" ETCD_SECTION="" NODE_SECTION="" APPS_NODE_SECTION=""

IDX=1
while IFS= read -r IP; do
  [[ -z "$IP" ]] && continue
  echo "    Control-plane-${IDX}: $IP"
  ALL_SECTION+="control-plane-${IDX}  ansible_host=${IP}  ip=${IP}  ansible_user=${ADMIN_USER}  ansible_ssh_private_key_file=${INVENTORY_KEY_PATH}  ${PROXY_ARGS}"$'\n'
  CP_SECTION+="control-plane-${IDX}"$'\n'
  ETCD_SECTION+="control-plane-${IDX}"$'\n'
  IDX=$((IDX + 1))
done <<< "$ALL_CP_IPS"

IDX=1
while IFS= read -r IP; do
  [[ -z "$IP" ]] && continue
  echo "    Worker-${IDX}: $IP"
  ALL_SECTION+="worker-${IDX}  ansible_host=${IP}  ip=${IP}  ansible_user=${ADMIN_USER}  ansible_ssh_private_key_file=${INVENTORY_KEY_PATH}  ${PROXY_ARGS}"$'\n'
  NODE_SECTION+="worker-${IDX}"$'\n'
  IDX=$((IDX + 1))
done <<< "$WORKER_IPS"

IDX=1
while IFS= read -r IP; do
  [[ -z "$IP" ]] && continue
  echo "    Apps-worker-${IDX}: $IP"
  ALL_SECTION+="apps-worker-${IDX}  ansible_host=${IP}  ip=${IP}  ansible_user=${ADMIN_USER}  ansible_ssh_private_key_file=${INVENTORY_KEY_PATH}  ${PROXY_ARGS}"$'\n'
  NODE_SECTION+="apps-worker-${IDX}"$'\n'
  APPS_NODE_SECTION+="apps-worker-${IDX}"$'\n'
  IDX=$((IDX + 1))
done <<< "$APPS_WORKER_IPS"

cat > "$INVENTORY_FILE" <<EOF
[all]
${ALL_SECTION}
[kube_control_plane]
${CP_SECTION}
[etcd]
${ETCD_SECTION}
[kube_node]
${NODE_SECTION}
[k8s_cluster:children]
kube_control_plane
kube_node

[apps_workers]
${APPS_NODE_SECTION}
[calico_rr]
EOF

echo "==> inventory.ini written to $INVENTORY_FILE"
echo "    Bastion      : $BASTION_IP"
echo "    CPs          : $(echo "$ALL_CP_IPS" | tr '\n' ' ')"
echo "    Workers      : $(echo "$WORKER_IPS" | tr '\n' ' ')"
echo "    Apps-workers : $(echo "$APPS_WORKER_IPS" | tr '\n' ' ')"
