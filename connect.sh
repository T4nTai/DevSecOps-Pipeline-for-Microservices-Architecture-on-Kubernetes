#!/usr/bin/env bash
# connect.sh — Open SSH tunnels for kubectl, Jenkins, SonarQube, Harbor, ArgoCD, Monitoring
# Usage: ./connect.sh [stop]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_USER="ubuntu"
PID_FILE="/tmp/devsecops-tunnels.pid"

# ── Ports ──────────────────────────────────────────────────────────────────────
LOCAL_K8S_PORT=6443
LOCAL_JENKINS_PORT=8080
LOCAL_SONAR_PORT=9000
LOCAL_HARBOR_PORT=8002
LOCAL_ARGOCD_PORT=8085
LOCAL_GRAFANA_PORT=3000
LOCAL_PROMETHEUS_PORT=9090
LOCAL_ALERTMANAGER_PORT=9093

REMOTE_K8S_PORT=6443
REMOTE_JENKINS_PORT=30080
REMOTE_SONAR_PORT=30900
REMOTE_HARBOR_PORT=30002
REMOTE_ARGOCD_PORT=30085
REMOTE_GRAFANA_PORT=30030
REMOTE_PROMETHEUS_PORT=30090
REMOTE_ALERTMANAGER_PORT=30093

ALL_PORTS=(
  $LOCAL_K8S_PORT
  $LOCAL_JENKINS_PORT
  $LOCAL_SONAR_PORT
  $LOCAL_HARBOR_PORT
  $LOCAL_ARGOCD_PORT
  $LOCAL_GRAFANA_PORT
  $LOCAL_PROMETHEUS_PORT
  $LOCAL_ALERTMANAGER_PORT
)

# ── Kill any process holding our ports ────────────────────────────────────────
kill_port_holders() {
  for port in "${ALL_PORTS[@]}"; do
    # find PID listening on the port (works on Linux/WSL)
    local pid
    pid=$(ss -tlnp "sport = :$port" 2>/dev/null \
      | grep -oP '(?<=pid=)\d+' | head -1 || true)
    if [[ -n "$pid" ]]; then
      echo "  Killing process $pid holding port $port..."
      kill "$pid" 2>/dev/null || true
    fi
  done
  sleep 1
}

stop_tunnels() {
  echo "Stopping tunnels..."

  # Kill via PID file first
  if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
      echo "  Killing tunnel process (PID $PID)..."
      kill "$PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi

  # Also kill any stray SSH processes tunnelling our ports
  pkill -f "ssh.*${LOCAL_K8S_PORT}.*" 2>/dev/null || true

  # Release any remaining port holders
  kill_port_holders

  echo "Tunnels stopped."
  exit 0
}

# ── Handle stop argument ───────────────────────────────────────────────────────
if [[ "${1:-}" == "stop" ]]; then
  stop_tunnels
fi

# ── If ports are busy, stop existing tunnels first ────────────────────────────
PORT_IN_USE=false
for port in "${ALL_PORTS[@]}"; do
  if ss -tlnp "sport = :$port" 2>/dev/null | grep -q LISTEN; then
    PORT_IN_USE=true
    break
  fi
done

if [[ "$PORT_IN_USE" == "true" ]]; then
  echo "Some ports are already in use. Clearing existing tunnels..."
  # Kill via PID file
  if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    kill "$PID" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  # Kill any stray SSH tunnel processes
  pkill -f "ssh.*ExitOnForwardFailure" 2>/dev/null || true
  kill_port_holders
fi

# ── Read IPs from Terraform output ────────────────────────────────────────────
echo "Reading Terraform outputs..."
cd "$TERRAFORM_DIR"

BASTION_IP=$(terraform output -raw bastion_public_ip 2>/dev/null)
CONTROL_PLANE_IP=$(terraform output -raw control_plane_private_ip 2>/dev/null)
WORKER_IP=$(terraform output -json worker_private_ips 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0])")

if [[ -z "$BASTION_IP" || -z "$CONTROL_PLANE_IP" || -z "$WORKER_IP" ]]; then
  echo "ERROR: Could not read Terraform outputs. Run: cd terraform && terraform apply"
  exit 1
fi

echo ""
echo "  Bastion IP      : $BASTION_IP"
echo "  Control Plane IP: $CONTROL_PLANE_IP"
echo "  Worker IP       : $WORKER_IP"
echo ""

# ── Open all tunnels ───────────────────────────────────────────────────────────
echo "Opening SSH tunnels..."

# Use a control socket so we can reliably get and kill the background process
SOCKET_FILE="/tmp/devsecops-ssh.sock"
rm -f "$SOCKET_FILE"

ssh -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -M -S "$SOCKET_FILE" \
  -L "${LOCAL_K8S_PORT}:${CONTROL_PLANE_IP}:${REMOTE_K8S_PORT}" \
  -L "${LOCAL_JENKINS_PORT}:${WORKER_IP}:${REMOTE_JENKINS_PORT}" \
  -L "${LOCAL_SONAR_PORT}:${WORKER_IP}:${REMOTE_SONAR_PORT}" \
  -L "${LOCAL_HARBOR_PORT}:${WORKER_IP}:${REMOTE_HARBOR_PORT}" \
  -L "${LOCAL_ARGOCD_PORT}:${WORKER_IP}:${REMOTE_ARGOCD_PORT}" \
  -L "${LOCAL_GRAFANA_PORT}:${WORKER_IP}:${REMOTE_GRAFANA_PORT}" \
  -L "${LOCAL_PROMETHEUS_PORT}:${WORKER_IP}:${REMOTE_PROMETHEUS_PORT}" \
  -L "${LOCAL_ALERTMANAGER_PORT}:${WORKER_IP}:${REMOTE_ALERTMANAGER_PORT}" \
  "${SSH_USER}@${BASTION_IP}" \
  -N -f

# Find the real background SSH PID via the control socket
SSH_PID=$(ssh -S "$SOCKET_FILE" -O check "${SSH_USER}@${BASTION_IP}" 2>&1 \
  | grep -oP '(?<=pid=)\d+' || true)

# Fallback: find via ss
if [[ -z "$SSH_PID" ]]; then
  SSH_PID=$(ss -tlnp "sport = :${LOCAL_K8S_PORT}" 2>/dev/null \
    | grep -oP '(?<=pid=)\d+' | head -1 || true)
fi

echo "$SSH_PID" > "$PID_FILE"

echo "Tunnels open (PID ${SSH_PID:-unknown})"
echo ""
echo "  kubectl             -> ready  (127.0.0.1:${LOCAL_K8S_PORT})"
echo "  Jenkins             -> http://localhost:${LOCAL_JENKINS_PORT}"
echo "  SonarQube           -> http://localhost:${LOCAL_SONAR_PORT}"
echo "  Harbor              -> http://localhost:${LOCAL_HARBOR_PORT}"
echo "  ArgoCD              -> http://localhost:${LOCAL_ARGOCD_PORT}"
echo "  Grafana             -> http://localhost:${LOCAL_GRAFANA_PORT}"
echo "  Prometheus          -> http://localhost:${LOCAL_PROMETHEUS_PORT}"
echo "  Alertmanager        -> http://localhost:${LOCAL_ALERTMANAGER_PORT}"
echo ""
echo "Run './connect.sh stop' to close tunnels."
