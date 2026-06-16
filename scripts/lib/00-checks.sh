#!/bin/bash
# Shared helpers sourced by every step.
# Exports: BASE_DIR, STATE_FILE, KUBECONFIG, CLOUD, CLUSTER, log_* functions,
#          check_state, check_vars, check_tools, check_helm, check_k8s, check_dns

export BASE_DIR="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export STATE_FILE="${BASE_DIR}/.deploy-state.env"
export SECRET_FILE="${BASE_DIR}/.env.secret"
export KUBECONFIG="${BASE_DIR}/.kubeconfig"

# -- ANSI colors --------------------------------------------------------------─
_C_RESET="\033[0m"; _C_RED="\033[31m"; _C_GREEN="\033[32m"
_C_YELLOW="\033[33m"; _C_CYAN="\033[36m"; _C_GRAY="\033[90m"; _C_BOLD="\033[1m"

log_info()    { echo -e "${_C_CYAN}[INFO ]${_C_RESET} $*"; }
log_ok()      { echo -e "${_C_GREEN}[OK   ]${_C_RESET} $*"; }
log_warn()    { echo -e "${_C_YELLOW}[WARN ]${_C_RESET} $*"; }
log_error()   { echo -e "${_C_RED}[ERROR]${_C_RESET} $*"; }
log_skip()    { echo -e "${_C_GRAY}[SKIP ]${_C_RESET} $*"; }
log_run()     { echo -e "${_C_BOLD}[RUN  ]${_C_RESET} $*"; }

log_step() {
  echo ""
  echo "------------------------------------------"
  echo -e "${_C_BOLD}[STEP ] $1${_C_RESET}"
  echo "        $(date '+%Y-%m-%d %H:%M:%S')"
  echo "------------------------------------------"
}

log_success() {
  echo ""
  echo -e "${_C_GREEN}[DONE ] $1 completed at $(date '+%H:%M:%S')${_C_RESET}"
  echo "------------------------------------------"
}

# -- Cloud / cluster defaults --------------------------------------------------
export CLOUD="${CLOUD:-aws}"
export CLUSTER="${CLUSTER:-tools}"

# Per-cloud SSH user
if [[ "$CLOUD" == "azure" ]]; then
  export ADMIN_USER="${ADMIN_USER:-azureuser}"
else
  export ADMIN_USER="${ADMIN_USER:-ubuntu}"
fi

# -- State helpers ------------------------------------------------------------─
check_state() {
  if [ ! -f "$STATE_FILE" ]; then
    log_error "State file not found: $STATE_FILE"
    log_info  "Run step 01 first: bash scripts/lib/01-terraform.sh"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

check_vars() {
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      log_error "Required variable missing: $var"
      log_info  "Re-run step 01: bash scripts/lib/01-terraform.sh"
      exit 1
    fi
  done
}

update_secret() {
  local key="$1" val="$2"
  [ -z "$key" ] || [ -z "$val" ] && return
  [ -f "$SECRET_FILE" ] || touch "$SECRET_FILE"
  if grep -q "^${key}=" "$SECRET_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$SECRET_FILE"
  else
    echo "${key}=\"${val}\"" >> "$SECRET_FILE"
  fi
}

# -- Tool checks --------------------------------------------------------------─
check_tools() {
  for tool in "$@"; do
    if ! command -v "$tool" &>/dev/null; then
      log_error "Tool not found: $tool"
      exit 1
    fi
  done
}

check_helm() {
  if ! command -v helm &>/dev/null; then
    log_info "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
  log_ok "Helm: $(helm version --short)"
}

# -- Cloud infra checks --------------------------------------------------------
check_cloud_infra() {
  if [[ "$CLOUD" == "azure" ]]; then
    _check_azure_infra
  else
    _check_aws_infra
  fi
}

_check_aws_infra() {
  log_info "Checking AWS infrastructure..."
  [ -f "$STATE_FILE" ] && source "$STATE_FILE" || true
  if ! aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=${CLUSTER_NAME}-control-plane-*" \
                "Name=instance-state-name,Values=running" \
      --query 'Reservations[0].Instances[0].InstanceId' \
      --output text 2>/dev/null | grep -q "^i-"; then
    log_error "No running control-plane instances found for cluster: ${CLUSTER_NAME:-?}"
    exit 1
  fi
  log_ok "AWS infra: control plane running"
}

_check_azure_infra() {
  log_info "Checking Azure infrastructure..."
  [ -f "$STATE_FILE" ] && source "$STATE_FILE" || true
  if ! az group show --name "$RESOURCE_GROUP" --query name -o tsv >/dev/null 2>&1; then
    log_error "Resource group not found: $RESOURCE_GROUP"
    exit 1
  fi
  if ! az vmss show --resource-group "$RESOURCE_GROUP" --name "$VMSS_NAME" \
      --query name -o tsv >/dev/null 2>&1; then
    log_error "VMSS not found: $VMSS_NAME"
    exit 1
  fi
  log_ok "Azure infra: RG=$RESOURCE_GROUP  VMSS=$VMSS_NAME"
}

# -- K8s check + auto-reconnect tunnel ----------------------------------------─
check_k8s() {
  log_info "Checking K8s cluster..."
  [ -f "$STATE_FILE" ] && source "$STATE_FILE" || true

  if [ ! -f "$KUBECONFIG" ]; then
    log_error "Kubeconfig not found: $KUBECONFIG"
    log_info  "Run step 02 first: bash scripts/lib/02-kubespray.sh"
    exit 1
  fi

  export KUBECONFIG="$KUBECONFIG"

  if ! kubectl get nodes >/dev/null 2>&1; then
    log_warn "K8s tunnel lost -- reconnecting..."
    pkill -f "L 6443:${MASTER_IP:-$CONTROL_PLANE_IP}:6443" 2>/dev/null || true
    sleep 2
    _open_k8s_tunnel
    sleep 5
  fi

  if ! kubectl get nodes >/dev/null 2>&1; then
    log_error "K8s cluster not reachable"
    exit 1
  fi

  log_ok "K8s cluster OK"
  kubectl get nodes --no-headers
}

_open_k8s_tunnel() {
  local target_ip="${MASTER_IP:-${CONTROL_PLANE_IP:-}}"
  [ -z "$target_ip" ] && { log_error "No master IP in state"; return 1; }

  if [[ "$CLOUD" == "azure" ]]; then
    ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=30 -f -N \
      -L "6443:${target_ip}:6443" \
      -o ProxyCommand="ssh -i ${SSH_KEY} -W %h:%p -o StrictHostKeyChecking=no ${ADMIN_USER}@${BASTION_IP}" \
      "${ADMIN_USER}@${target_ip}" 2>/dev/null || true
  else
    ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=30 -f -N \
      -L "6443:${target_ip}:6443" \
      -J "${ADMIN_USER}@${BASTION_IP}" \
      "${ADMIN_USER}@${target_ip}" 2>/dev/null || true
  fi
}

check_dns() {
  log_info "Checking CoreDNS..."
  COREDNS_READY=$(kubectl get pods -n kube-system -l k8s-app=kube-dns \
    --no-headers 2>/dev/null | grep -c Running 2>/dev/null || echo "0")
  if [ "${COREDNS_READY:-0}" = "0" ]; then
    log_error "CoreDNS not running"
    exit 1
  fi
  log_ok "CoreDNS: $COREDNS_READY pod(s) running"
}

check_autoscaler() {
  log_info "Checking Cluster Autoscaler..."
  CA_STATUS=$(kubectl get deployment cluster-autoscaler \
    -n kube-system --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")
  if [ "$CA_STATUS" != "1/1" ]; then
    log_error "Cluster Autoscaler not running"
    exit 1
  fi
  log_ok "Cluster Autoscaler: $CA_STATUS"
}
