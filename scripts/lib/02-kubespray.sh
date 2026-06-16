#!/bin/bash
# STEP 02: Kubespray + Kubeconfig
# AWS: ProxyJump ubuntu@bastion, installs EBS CSI + StorageClass
# Azure: ProxyCommand azureuser@bastion, patches cloud ProviderID
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 02: Kubespray + Kubeconfig"

check_state

if [[ "$CLOUD" == "azure" ]]; then
  check_vars BASTION_IP MASTER_IP SSH_KEY
  check_cloud_infra
else
  check_vars BASTION_IP CONTROL_PLANE_IP SSH_KEY
fi

KUBESPRAY_REPO_DIR="${BASE_DIR}/kubespray/kubespray-src"  # large — stays in kubespray/, not moved
KUBESPRAY_VERSION="${KUBESPRAY_VERSION:-release-2.26}"
KUBESPRAY_IMAGE_TAG="${KUBESPRAY_IMAGE_TAG:-v2.26.0}"
K8S_VERSION="${K8S_VERSION:-v1.29.5}"

# Use the official Kubespray Docker image — has Ansible + all deps pre-installed.
# Falls back to local venv if Docker is not available.
USE_DOCKER=false
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  USE_DOCKER=true
fi

# -- Generate or locate inventory ----------------------------------------------
if [[ "$CLOUD" == "aws" ]]; then
  INVENTORY_FILE="${BASE_DIR}/platform/kubespray/inventory.ini"
  log_info "Generating Kubespray inventory from Terraform outputs..."
  bash "${BASE_DIR}/platform/kubespray/generate-inventory.sh" \
    CLOUD=aws CLUSTER="$CLUSTER" SSH_KEY="$SSH_KEY" BASTION_IP="$BASTION_IP"
  [ -f "$INVENTORY_FILE" ] || { log_error "inventory.ini not generated"; exit 1; }
else
  INVENTORY_FILE="${ENV_DIR}/inventory.ini"
  [ -f "$INVENTORY_FILE" ] || { log_error "inventory.ini not found: $INVENTORY_FILE"; exit 1; }
fi

# -- Clone / reuse Kubespray (only needed for local venv fallback) ------------─
echo ""
log_info "Setting up Kubespray ${KUBESPRAY_VERSION}..."

if [ "$USE_DOCKER" = false ]; then
  if [ ! -d "$KUBESPRAY_REPO_DIR" ] || [ ! -f "$KUBESPRAY_REPO_DIR/cluster.yml" ]; then
    rm -rf "$KUBESPRAY_REPO_DIR"
    git clone --depth=1 --branch "$KUBESPRAY_VERSION" \
      https://github.com/kubernetes-sigs/kubespray.git "$KUBESPRAY_REPO_DIR"
    log_ok "Kubespray cloned: $KUBESPRAY_VERSION"
  else
    log_skip "Reusing existing Kubespray at $KUBESPRAY_REPO_DIR"
  fi

  VENV_DIR="${BASE_DIR}/kubespray/.venv"  # venv stays next to kubespray-src
  if [ ! -f "$VENV_DIR/bin/ansible-playbook" ]; then
    log_info "Creating Python venv (Docker not available — fallback)..."
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip wheel --quiet
    "$VENV_DIR/bin/pip" install -r "$KUBESPRAY_REPO_DIR/requirements.txt" \
      --prefer-binary --timeout 100 --quiet
    log_ok "venv ready"
  else
    log_skip "Reusing venv"
  fi
  export PATH="$VENV_DIR/bin:$PATH"
else
  log_ok "Using Kubespray Docker image: quay.io/kubespray/kubespray:${KUBESPRAY_IMAGE_TAG}"
  docker pull "quay.io/kubespray/kubespray:${KUBESPRAY_IMAGE_TAG}" 2>/dev/null || true
fi

# -- Inventory setup ----------------------------------------------------------─
# Docker mode: kubespray-src is NOT cloned on host — use a standalone dir.
# Venv mode:   kubespray-src exists — keep using it (sample group_vars available).
if [ "$USE_DOCKER" = true ]; then
  KUBE_INVENTORY_DIR="${BASE_DIR}/platform/kubespray/inventory-docker"
  mkdir -p "$KUBE_INVENTORY_DIR/group_vars/k8s_cluster" \
           "$KUBE_INVENTORY_DIR/group_vars/all" \
           "$KUBE_INVENTORY_DIR/group_vars/etcd"
  # Copy sample group_vars from Docker image (has all kubespray defaults)
  docker run --rm \
    "quay.io/kubespray/kubespray:${KUBESPRAY_IMAGE_TAG}" \
    tar cf - -C /kubespray inventory/sample/group_vars 2>/dev/null \
    | tar xf - --strip-components=3 -C "$KUBE_INVENTORY_DIR/" 2>/dev/null || true
else
  KUBE_INVENTORY_DIR="$KUBESPRAY_REPO_DIR/inventory/devsecops"
  mkdir -p "$KUBE_INVENTORY_DIR"
  cp -rp "$KUBESPRAY_REPO_DIR/inventory/sample/group_vars" "$KUBE_INVENTORY_DIR/" 2>/dev/null || true
fi
cp "$INVENTORY_FILE" "$KUBE_INVENTORY_DIR/hosts.ini"

# -- Supplementary addresses for TLS SAN --------------------------------------
SUPPLEMENTARY_ADDRESSES=""
if [[ "$CLOUD" == "aws" ]]; then
  CONTROL_PLANE_IPS=$(terraform -chdir="$ENV_DIR" output -json control_plane_private_ips \
    2>/dev/null | jq -r '.[]' || echo "$CONTROL_PLANE_IP")
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    SUPPLEMENTARY_ADDRESSES+="  - ${ip}"$'\n'
  done <<< "$CONTROL_PLANE_IPS"
  [ -n "$NLB_DNS" ] && SUPPLEMENTARY_ADDRESSES+="  - ${NLB_DNS}"$'\n'
  FIRST_CP="$CONTROL_PLANE_IP"
else
  SUPPLEMENTARY_ADDRESSES="  - ${MASTER_IP}"$'\n'
  [ -n "${LB_IP:-}" ] && SUPPLEMENTARY_ADDRESSES+="  - ${LB_IP}"$'\n'
  FIRST_CP="$MASTER_IP"
fi

# -- Cluster vars --------------------------------------------------------------
# Dùng terminator khác nhau để tránh nhầm lẫn với EOF của các heredoc khác
cat > "$KUBE_INVENTORY_DIR/group_vars/k8s_cluster/k8s-cluster.yml" <<KUBECLUSTER
kube_version: ${K8S_VERSION}
kube_network_plugin: calico
kube_service_addresses: 10.96.0.0/12
kube_pods_subnet: 192.168.0.0/16
kube_proxy_mode: ipvs
container_manager: containerd
kubeconfig_localhost: true
kubectl_localhost: true

supplementary_addresses_in_ssl_keys:
${SUPPLEMENTARY_ADDRESSES}
KUBECLUSTER

# Use localhost LB to avoid hairpin issues on both AWS (NLB) and Azure (internal LB)
cat >> "$KUBE_INVENTORY_DIR/group_vars/all/all.yml" <<ALLCONFIG

loadbalancer_apiserver_localhost: true
loadbalancer_apiserver_port: 6443
ALLCONFIG

# -- Wait for bastion SSH ------------------------------------------------------
echo ""
log_info "Waiting for SSH access to bastion..."

SSH_READY=false
SLEEP=5
for i in $(seq 1 40); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes \
      -i "$SSH_KEY" "${ADMIN_USER}@${BASTION_IP}" "echo OK" >/dev/null 2>&1; then
    log_ok "SSH bastion ready"
    SSH_READY=true
    break
  fi
  log_info "Attempt $i/40 — waiting ${SLEEP}s..."
  sleep "$SLEEP"
  SLEEP=$(( SLEEP < 30 ? SLEEP + 5 : 30 ))
done
[ "$SSH_READY" = false ] && { log_error "SSH bastion not reachable"; exit 1; }

# -- Helper: run command on master via bastion --------------------------------─
_ssh_master() {
  if [[ "$CLOUD" == "azure" ]]; then
    ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
      -o ProxyCommand="ssh -i ${SSH_KEY} -W %h:%p -o StrictHostKeyChecking=no ${ADMIN_USER}@${BASTION_IP}" \
      "${ADMIN_USER}@${FIRST_CP}" "$@"
  else
    ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
      -J "${ADMIN_USER}@${BASTION_IP}" \
      "${ADMIN_USER}@${FIRST_CP}" "$@"
  fi
}

# -- Check cluster health (skip Kubespray if already healthy) ------------------
echo ""
log_info "Checking existing cluster health..."

NEED_DEPLOY=true

if _ssh_master "sudo kubectl get nodes --kubeconfig /etc/kubernetes/admin.conf" >/dev/null 2>&1; then
  NOT_READY=$(_ssh_master \
    "sudo kubectl get nodes --kubeconfig /etc/kubernetes/admin.conf --no-headers 2>/dev/null \
     | grep -v ' Ready '" 2>/dev/null || true)
  FAILED_PODS=$(_ssh_master \
    "sudo kubectl get pods -n kube-system --kubeconfig /etc/kubernetes/admin.conf \
     --no-headers 2>/dev/null | grep -v ' Running \| Completed '" 2>/dev/null || true)

  if [ -z "$NOT_READY" ] && [ -z "$FAILED_PODS" ]; then
    log_ok "Cluster healthy — skipping Kubespray"
    NEED_DEPLOY=false
  else
    log_warn "Cluster unhealthy — rerunning Kubespray"
    log_info "  Not ready: ${NOT_READY:-none}"
    log_info "  Failed:    ${FAILED_PODS:-none}"
  fi
fi

# -- Run Kubespray ------------------------------------------------------------─
if [ "$NEED_DEPLOY" = true ]; then
  PLAYBOOK="${KUBESPRAY_PLAYBOOK:-cluster.yml}"

  if [ "$USE_DOCKER" = true ]; then
    echo ""
    log_run "Running Kubespray via Docker — this takes 20–30 minutes..."

    # Install Python on nodes first (tiny — no deps needed)
    docker run --rm \
      -v "${SSH_KEY}:/root/.ssh/id_rsa:ro" \
      -v "${SSH_KEY}.pub:/root/.ssh/id_rsa.pub:ro" \
      -v "${KUBE_INVENTORY_DIR}:/kubespray/inventory/devsecops" \
      -e ANSIBLE_HOST_KEY_CHECKING=False \
      "quay.io/kubespray/kubespray:${KUBESPRAY_IMAGE_TAG}" \
      ansible all \
        -i inventory/devsecops/hosts.ini \
        -u "$ADMIN_USER" \
        -m raw -a "sudo apt-get install -y python3 2>/dev/null || true" \
        --forks 20 --timeout 30 2>/dev/null || true

    docker run --rm \
      -v "${SSH_KEY}:/root/.ssh/id_rsa:ro" \
      -v "${SSH_KEY}.pub:/root/.ssh/id_rsa.pub:ro" \
      -v "${KUBE_INVENTORY_DIR}:/kubespray/inventory/devsecops" \
      -e ANSIBLE_HOST_KEY_CHECKING=False \
      "quay.io/kubespray/kubespray:${KUBESPRAY_IMAGE_TAG}" \
      ansible-playbook \
        -i inventory/devsecops/hosts.ini \
        --private-key /root/.ssh/id_rsa \
        --become \
        --timeout 60 \
        -e ansible_become_method=sudo \
        "$PLAYBOOK" -v
  else
    log_info "Installing Python on all nodes..."
    "$VENV_DIR/bin/ansible" all \
      -i "$KUBE_INVENTORY_DIR/hosts.ini" \
      -u "$ADMIN_USER" --private-key "$SSH_KEY" \
      -m raw -a "sudo apt-get install -y python3 2>/dev/null || true" \
      --forks 20 --timeout 30 2>/dev/null || true

    echo ""
    log_run "Running Kubespray cluster.yml — this takes 20–30 minutes..."

    cd "$KUBESPRAY_REPO_DIR"
    export ANSIBLE_ROLES_PATH="$KUBESPRAY_REPO_DIR/roles"
    export ANSIBLE_COLLECTIONS_PATH="$KUBESPRAY_REPO_DIR/collections"
    export ANSIBLE_HOST_KEY_CHECKING=False

    "$VENV_DIR/bin/ansible-playbook" \
      -i "$KUBE_INVENTORY_DIR/hosts.ini" \
      --private-key "$SSH_KEY" \
      --become \
      --timeout 60 \
      -e 'ansible_become_method=sudo' \
      "$PLAYBOOK" -v

    cd "$BASE_DIR"
  fi
fi

# -- Fetch kubeconfig ----------------------------------------------------------
echo ""
log_info "Fetching kubeconfig from control plane..."
mkdir -p "$(dirname "$KUBECONFIG")"

_ssh_master "sudo cat /etc/kubernetes/admin.conf" > "$KUBECONFIG"
sed -i "s|https://.*:6443|https://127.0.0.1:6443|g" "$KUBECONFIG"
chmod 600 "$KUBECONFIG"

CLUSTER_NAME_K8S=$(kubectl --kubeconfig "$KUBECONFIG" config view \
  --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo "kubernetes")
kubectl config set-cluster "$CLUSTER_NAME_K8S" \
  --insecure-skip-tls-verify=true \
  --kubeconfig "$KUBECONFIG" >/dev/null
export KUBECONFIG="$KUBECONFIG"
log_ok "Kubeconfig saved: $KUBECONFIG"

# -- Open tunnel so subsequent steps can use kubectl --------------------------─
echo ""
log_info "Opening kubectl tunnel..."
pkill -f "L 6443:${FIRST_CP}:6443" 2>/dev/null || true
sleep 2

if [[ "$CLOUD" == "azure" ]]; then
  ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -f -N \
    -L "6443:${FIRST_CP}:6443" \
    -o ProxyCommand="ssh -i ${SSH_KEY} -W %h:%p -o StrictHostKeyChecking=no ${ADMIN_USER}@${BASTION_IP}" \
    "${ADMIN_USER}@${FIRST_CP}" 2>/dev/null &
else
  ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -f -N \
    -L "6443:${FIRST_CP}:6443" \
    -J "${ADMIN_USER}@${BASTION_IP}" \
    "${ADMIN_USER}@${FIRST_CP}" 2>/dev/null &
fi

sleep 5
kubectl get nodes || log_warn "Tunnel not yet ready — continuing"

# -- Azure: patch cloud ProviderID on nodes ------------------------------------
if [[ "$CLOUD" == "azure" ]]; then
  echo ""
  log_info "Patching Azure cloud ProviderID on nodes..."

  NODES=$(kubectl get nodes --no-headers -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  for node in $NODES; do
    CURRENT_PROVIDER=$(kubectl get node "$node" \
      -o jsonpath='{.spec.providerID}' 2>/dev/null || echo "")
    if [ -z "$CURRENT_PROVIDER" ]; then
      VM_ID=$(az vm show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$node" \
        --query "id" -o tsv 2>/dev/null | tr -d '\r' || echo "")
      if [ -n "$VM_ID" ]; then
        kubectl patch node "$node" \
          --type=merge \
          -p "{\"spec\":{\"providerID\":\"azure://${VM_ID}\"}}" 2>/dev/null || true
        log_ok "ProviderID patched: $node"
      fi
    else
      log_skip "ProviderID already set: $node"
    fi
  done
fi

# -- AWS: install EBS CSI driver + StorageClass --------------------------------
if [[ "$CLOUD" == "aws" ]]; then
  echo ""
  log_info "Installing AWS EBS CSI driver..."

  helm repo add aws-ebs-csi-driver \
    https://kubernetes-sigs.github.io/aws-ebs-csi-driver 2>/dev/null || true
  helm repo update 2>/dev/null || true

  helm upgrade --install aws-ebs-csi-driver \
    aws-ebs-csi-driver/aws-ebs-csi-driver \
    --namespace kube-system --wait

  kubectl apply -f - <<YAML
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-sc
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
YAML
  log_ok "EBS CSI driver + StorageClass installed"
fi

# -- Install Helm (if not already) --------------------------------------------─
check_helm

echo ""
log_info "Cluster summary:"
kubectl get nodes
kubectl get pods -n kube-system | grep -v "Running\|Completed" || true

log_success "STEP 02"
