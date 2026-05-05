#!/usr/bin/env bash
# deploy.sh — Unified DevSecOps deployment pipeline
#
# Usage:
#   bash scripts/deploy.sh --cloud=aws   [--cluster=tools|apps] [--start-from=01]
#   bash scripts/deploy.sh --cloud=azure [--cluster=tools|apps] [--start-from=01]
#
# Steps:
#   01 — Terraform apply + state file
#   02 — Kubespray (provision Kubernetes)
#   03 — DNS fix (kube-proxy, CoreDNS, nodelocaldns)
#   04 — Cluster Autoscaler + metrics-server
#   05 — Prometheus + Grafana
#   06 — NGINX Ingress + Sorry Page
#   07 — ArgoCD
#   08 — Jenkins
#   09 — KEDA + HTTP Add-on
#   10 — cert-manager + TLS (wildcard cert for *.tools.votantai.me)
#   11 — SonarQube (sonarqube.tools.votantai.me)
#   12 — Harbor (harbor.tools.votantai.me)
#   13 — Vault (vault.tools.votantai.me)
#
# Environment variables (alternative to flags):
#   CLOUD=aws|azure   CLUSTER=tools|apps   START_FROM=01

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STEPS_DIR="$BASE_DIR/scripts/steps"
ENV_FILE="$BASE_DIR/.env"
SECRET_FILE="$BASE_DIR/.env.secret"

export BASE_DIR

# ── Parse flags ───────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --cloud=*)       CLOUD="${arg#*=}" ;;
    --cluster=*)     CLUSTER="${arg#*=}" ;;
    --start-from=*)  START_FROM="${arg#*=}" ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "[WARN] Unknown argument: $arg" ;;
  esac
done

export CLOUD="${CLOUD:-aws}"
export CLUSTER="${CLUSTER:-tools}"
START_FROM="${START_FROM:-01}"

# ── Validate ──────────────────────────────────────────────────────────────────
case "$CLOUD" in
  aws|azure) ;;
  *) echo "[ERROR] --cloud must be 'aws' or 'azure'"; exit 1 ;;
esac
case "$CLUSTER" in
  tools|apps) ;;
  *) echo "[ERROR] --cluster must be 'tools' or 'apps'"; exit 1 ;;
esac

# ── Source helpers ────────────────────────────────────────────────────────────
# shellcheck disable=SC1090
source "$STEPS_DIR/00-checks.sh"

# ── Load .env (config) ────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
  log_info "Loading .env..."
  set -a; source "$ENV_FILE"; set +a
fi

# ── Config defaults ───────────────────────────────────────────────────────────
export PROJECT_NAME="${PROJECT_NAME:-devsecops}"
export ENVIRONMENT="$CLUSTER"
export WIREGUARD_PEERS="${WIREGUARD_PEERS:-3}"

if [[ "$CLOUD" == "azure" ]]; then
  export LOCATION="${LOCATION:-koreacentral}"
  export RESOURCE_GROUP="${RESOURCE_GROUP:-${PROJECT_NAME}-${CLUSTER}-rg}"
  export VAULT_NAME="${VAULT_NAME:-${PROJECT_NAME}-${CLUSTER}-kv}"
  export ENV_DIR="${ENV_DIR:-${BASE_DIR}/terraform/azure/envs/${CLUSTER}}"
  export ADMIN_USER="${ADMIN_USER:-azureuser}"
  export SSH_KEY="${SSH_KEY:-/tmp/ssh/id_rsa}"
  export KUBESPRAY_VERSION="${KUBESPRAY_VERSION:-v2.26.0}"
else
  export AWS_REGION="${AWS_REGION:-ap-southeast-1}"
  export ENV_DIR="${ENV_DIR:-${BASE_DIR}/terraform/aws/envs/${CLUSTER}}"
  export ADMIN_USER="${ADMIN_USER:-ubuntu}"
  export SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
  export CLUSTER_NAME="${CLUSTER_NAME:-${PROJECT_NAME}-${CLUSTER}}"
  export KUBESPRAY_VERSION="${KUBESPRAY_VERSION:-release-2.26}"
fi

# ── Load .env.secret (local overrides) ───────────────────────────────────────
if [ -f "$SECRET_FILE" ]; then
  log_info "Loading .env.secret..."
  set -a; source "$SECRET_FILE"; set +a
fi

# ── Write SSH key from env vars ───────────────────────────────────────────────
SSH_DIR="/tmp/ssh"
mkdir -p "$SSH_DIR"

if [ -n "${SSH_PRIVATE_KEY:-}" ] && [ ! -f "$SSH_KEY" ]; then
  echo "$SSH_PRIVATE_KEY" | base64 -d > "$SSH_DIR/id_rsa" 2>/dev/null \
    || printf '%s' "$SSH_PRIVATE_KEY" > "$SSH_DIR/id_rsa"
  chmod 600 "$SSH_DIR/id_rsa"
  export SSH_KEY="$SSH_DIR/id_rsa"
  log_info "SSH_KEY (from env) → $SSH_KEY"
fi

if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
  printf '%s\n' "$SSH_PUBLIC_KEY" > "$SSH_DIR/id_rsa.pub"
  chmod 644 "$SSH_DIR/id_rsa.pub"
  export SSH_PUB_KEY="$SSH_DIR/id_rsa.pub"
fi

# ── Load secrets from vault / SSM ────────────────────────────────────────────
echo ""
# shellcheck disable=SC1090
source "$STEPS_DIR/load-secrets.sh" || true

# ── Step list ─────────────────────────────────────────────────────────────────
STEPS=(
  "01-terraform.sh"
  "02-kubespray.sh"
  "03-dns-fix.sh"
  "04-autoscaler.sh"
  "05-monitoring.sh"
  "06-ingress.sh"
  "07-argocd.sh"
  "08-jenkins.sh"
  "09-keda.sh"
  "10-cert-manager.sh"
  "11-sonarqube.sh"
  "12-harbor.sh"
  "13-vault.sh"
)

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo "  DEVSECOPS DEPLOYMENT PIPELINE"
echo "  Cloud:      $CLOUD"
echo "  Cluster:    $CLUSTER"
echo "  Start from: step $START_FROM"
echo "  Vault/SSM:  ${VAULT_NAME:-${CLUSTER_NAME:-$CLUSTER}}"
echo "  SSH key:    $SSH_KEY"
echo "══════════════════════════════════════════"

# ── Run steps ─────────────────────────────────────────────────────────────────
for STEP in "${STEPS[@]}"; do
  STEP_NUM="${STEP:0:2}"

  if [[ "$STEP_NUM" < "$START_FROM" ]]; then
    log_skip "$STEP"
    # Load state so skipped steps still export their vars
    [ -f "$STATE_FILE" ] && source "$STATE_FILE" || true
    continue
  fi

  echo ""
  log_run "$STEP"

  CLOUD="$CLOUD" CLUSTER="$CLUSTER" bash "$STEPS_DIR/$STEP"

  # Reload state after each step so next step sees updated vars
  [ -f "$STATE_FILE" ] && source "$STATE_FILE" || true
done

echo ""
echo "══════════════════════════════════════════"
echo "  DEPLOYMENT COMPLETE"

if [[ "$CLOUD" == "azure" ]]; then
  LB_ENDPOINT="${LB_IP:-}"
else
  LB_ENDPOINT="${NLB_DNS:-}"
fi

echo ""
echo "  Services:"
if [ -n "${DOMAIN:-}" ]; then
  echo "    Jenkins    https://jenkins.${DOMAIN}"
  echo "    ArgoCD     https://argocd.${DOMAIN}"
  echo "    Grafana    https://grafana.${DOMAIN}"
elif [ -n "${LB_ENDPOINT:-}" ]; then
  echo "    Jenkins    http://$LB_ENDPOINT/jenkins"
  echo "    ArgoCD     http://$LB_ENDPOINT/argocd"
  echo "    Grafana    http://$LB_ENDPOINT/grafana"
fi

echo ""
echo "  Run './connect.sh --cloud=$CLOUD --cluster=$CLUSTER'"
echo "  Then: kubectl get nodes"
echo "══════════════════════════════════════════"
