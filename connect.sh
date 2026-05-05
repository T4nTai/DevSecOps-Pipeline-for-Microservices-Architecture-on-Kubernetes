#!/usr/bin/env bash
# connect.sh — SSH tunnel for kubectl access
#
# Usage:
#   ./connect.sh [stop]
#   ./connect.sh --cloud=aws|azure --cluster=tools|apps [stop]
#
# Env vars: CLOUD=aws|azure  CLUSTER=tools|apps  SSH_KEY=path
#
# Services (Jenkins, ArgoCD, Grafana) are accessible via HTTPS subdomains directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse flags ───────────────────────────────────────────────────────────────
ACTION=""
for arg in "$@"; do
  case "$arg" in
    --cloud=*)   CLOUD="${arg#*=}" ;;
    --cluster=*) CLUSTER="${arg#*=}" ;;
    stop)        ACTION="stop" ;;
  esac
done

export CLOUD="${CLOUD:-aws}"
export CLUSTER="${CLUSTER:-tools}"

# ── Per-cloud SSH defaults ────────────────────────────────────────────────────
if [[ "$CLOUD" == "azure" ]]; then
  SSH_USER="${SSH_USER:-azureuser}"
  SSH_KEY="${SSH_KEY:-/tmp/ssh/id_rsa}"
  TF_DIR="$SCRIPT_DIR/terraform/azure/envs/$CLUSTER"
else
  SSH_USER="${SSH_USER:-ubuntu}"
  SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
  TF_DIR="$SCRIPT_DIR/terraform/aws/envs/$CLUSTER"
fi

PID_FILE="/tmp/devsecops-kubectl-${CLOUD}-${CLUSTER}.pid"
SOCKET_FILE="/tmp/devsecops-ssh-${CLOUD}-${CLUSTER}.sock"
LOCAL_K8S_PORT=6443

# ── Helpers ───────────────────────────────────────────────────────────────────
stop_tunnels() {
  echo "Stopping kubectl tunnel (cloud=$CLOUD cluster=$CLUSTER)..."
  if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    kill -0 "$PID" 2>/dev/null && kill "$PID" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  pkill -f "ssh.*${LOCAL_K8S_PORT}.*" 2>/dev/null || true
  local pid
  pid=$(ss -tlnp "sport = :${LOCAL_K8S_PORT}" 2>/dev/null | grep -oP '(?<=pid=)\d+' | head -1 || true)
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  echo "Tunnel stopped."
  exit 0
}

[ "$ACTION" = "stop" ] && stop_tunnels

# ── Clear busy port ───────────────────────────────────────────────────────────
if ss -tlnp "sport = :${LOCAL_K8S_PORT}" 2>/dev/null | grep -q LISTEN; then
  echo "Port ${LOCAL_K8S_PORT} in use — clearing existing tunnel..."
  [[ -f "$PID_FILE" ]] && kill "$(cat "$PID_FILE")" 2>/dev/null || true
  rm -f "$PID_FILE"
  pkill -f "ssh.*ExitOnForwardFailure" 2>/dev/null || true
  pid=$(ss -tlnp "sport = :${LOCAL_K8S_PORT}" 2>/dev/null | grep -oP '(?<=pid=)\d+' | head -1 || true)
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
fi

# ── Read IPs from Terraform outputs ──────────────────────────────────────────
echo "Reading Terraform outputs (cloud=$CLOUD cluster=$CLUSTER)..."

if [ ! -d "$TF_DIR" ]; then
  echo "ERROR: Terraform dir not found: $TF_DIR"
  exit 1
fi

cd "$TF_DIR"

if [[ "$CLOUD" == "azure" ]]; then
  BASTION_IP=$(terraform output -raw bastion_ip 2>/dev/null)
  API_ENDPOINT=$(terraform output -json master_private_ips 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0])")
else
  BASTION_IP=$(terraform output -raw bastion_public_ip 2>/dev/null)
  API_ENDPOINT=$(terraform output -raw control_plane_private_ip 2>/dev/null \
    || terraform output -raw api_nlb_dns 2>/dev/null)
fi

if [[ -z "$BASTION_IP" || -z "$API_ENDPOINT" ]]; then
  echo "ERROR: Could not read Terraform outputs. Run step 01 first."
  exit 1
fi

echo ""
echo "  Cloud:       $CLOUD"
echo "  Cluster:     $CLUSTER"
echo "  Bastion IP:  $BASTION_IP"
echo "  K8s API:     $API_ENDPOINT:6443"
echo ""

# ── Open kubectl tunnel via bastion ──────────────────────────────────────────
echo "Opening kubectl tunnel..."
rm -f "$SOCKET_FILE"

if [[ "$CLOUD" == "azure" ]]; then
  PROXY_OPTS=(-o "ProxyCommand=ssh -i ${SSH_KEY} -W %h:%p -o StrictHostKeyChecking=no ${SSH_USER}@${BASTION_IP}")
else
  PROXY_OPTS=(-J "${SSH_USER}@${BASTION_IP}")
fi

ssh -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -M -S "$SOCKET_FILE" \
  "${PROXY_OPTS[@]}" \
  -L "${LOCAL_K8S_PORT}:${API_ENDPOINT}:6443" \
  "${SSH_USER}@${API_ENDPOINT}" \
  -N -f

SSH_PID=$(ss -tlnp "sport = :${LOCAL_K8S_PORT}" 2>/dev/null \
  | grep -oP '(?<=pid=)\d+' | head -1 || true)
echo "$SSH_PID" > "$PID_FILE"

# ── Patch kubeconfig ──────────────────────────────────────────────────────────
KUBECONFIG_FILE="${KUBECONFIG:-$HOME/.kube/config}"
KUBECONFIG_LOCAL="${SCRIPT_DIR}/.kubeconfig"

for kc in "$KUBECONFIG_LOCAL" "$KUBECONFIG_FILE"; do
  [ -f "$kc" ] || continue
  CURRENT_SERVER=$(kubectl --kubeconfig "$kc" config view --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  if [[ "$CURRENT_SERVER" != "https://127.0.0.1:${LOCAL_K8S_PORT}" ]]; then
    CLUSTER_NAME_K8S=$(kubectl --kubeconfig "$kc" config view --minify \
      -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)
    kubectl config set-cluster "${CLUSTER_NAME_K8S}" \
      --server="https://127.0.0.1:${LOCAL_K8S_PORT}" \
      --kubeconfig "$kc" &>/dev/null
    kubectl config set-cluster "${CLUSTER_NAME_K8S}" \
      --insecure-skip-tls-verify=true \
      --kubeconfig "$kc" &>/dev/null
    echo "  Kubeconfig patched: $kc → https://127.0.0.1:${LOCAL_K8S_PORT}"
  fi
done

echo ""
echo "kubectl tunnel open (PID ${SSH_PID:-unknown})"
echo ""
echo "  kubectl  → ready  (127.0.0.1:${LOCAL_K8S_PORT})"
echo ""
echo "  Services (accessible directly via browser):"
echo "    Jenkins    https://jenkins.${CLUSTER}.votantai.me"
echo "    ArgoCD     https://argocd.${CLUSTER}.votantai.me"
echo "    Grafana    https://grafana.${CLUSTER}.votantai.me"
echo ""
echo "Run './connect.sh --cloud=$CLOUD --cluster=$CLUSTER stop' to close tunnel."
