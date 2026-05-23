#!/bin/bash
# STEP 01: Terraform apply + read outputs into state file
# Supports --cloud=aws|azure and --cluster=tools|apps
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 01: Terraform"

if [[ "$CLOUD" == "azure" ]]; then
  _required_tools=(terraform jq az git python3 kubectl)
else
  _required_tools=(terraform jq aws git python3 kubectl)
fi
check_tools "${_required_tools[@]}"
check_helm

# ── Locate env dir ────────────────────────────────────────────────────────────
if [[ "$CLOUD" == "azure" ]]; then
  ENV_DIR="${ENV_DIR:-${BASE_DIR}/infra/azure/envs/${CLUSTER}}"
else
  ENV_DIR="${ENV_DIR:-${BASE_DIR}/infra/aws/envs/${CLUSTER}}"
fi
export ENV_DIR

if [ ! -d "$ENV_DIR" ]; then
  log_error "Terraform env dir not found: $ENV_DIR"
  exit 1
fi

# ── SSH key setup ─────────────────────────────────────────────────────────────
if [[ "$CLOUD" == "azure" ]]; then
  SSH_KEY="${SSH_KEY:-/tmp/ssh/id_rsa}"
  SSH_PUB_KEY_PATH="${SSH_PUB_KEY:-/tmp/ssh/id_rsa.pub}"

  if [ -n "${SSH_PRIVATE_KEY:-}" ] && [ ! -f "$SSH_KEY" ]; then
    mkdir -p /tmp/ssh
    echo "$SSH_PRIVATE_KEY" | base64 -d > "$SSH_KEY" 2>/dev/null \
      || printf '%s' "$SSH_PRIVATE_KEY" > "$SSH_KEY"
    chmod 600 "$SSH_KEY"
  fi
  if [ -n "${SSH_PUBLIC_KEY:-}" ] && [ ! -f "$SSH_PUB_KEY_PATH" ]; then
    mkdir -p /tmp/ssh
    printf '%s\n' "$SSH_PUBLIC_KEY" > "$SSH_PUB_KEY_PATH"
    chmod 644 "$SSH_PUB_KEY_PATH"
  fi
else
  SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
  SSH_PUB_KEY_PATH="${SSH_KEY}.pub"
fi

export SSH_KEY
[ -f "$SSH_KEY" ] || { log_error "SSH key not found: $SSH_KEY"; exit 1; }
chmod 600 "$SSH_KEY"
log_ok "SSH_KEY: $SSH_KEY"

# ── Render tfvars if env vars present ────────────────────────────────────────
if [[ "$CLOUD" == "azure" ]]; then
  if [ -n "${SSH_PUBLIC_KEY:-}" ] || [ -n "${ALLOWED_SSH_IP:-}" ]; then
    log_info "Rendering terraform.tfvars from env vars..."
    cat > "$ENV_DIR/terraform.tfvars" <<TFVARS
project_name         = "${PROJECT_NAME:-devsecops}"
environment          = "${CLUSTER}"
location             = "${LOCATION:-koreacentral}"
ssh_public_key       = "${SSH_PUB_KEY_PATH}"
ssh_private_key_path = "${SSH_KEY}"
allowed_ssh_ip       = "${ALLOWED_SSH_IP:-*}"
worker_image_id      = "${WORKER_IMAGE_ID:-}"
TFVARS
    log_ok "terraform.tfvars rendered"
  fi
fi

# ── Terraform init + apply ────────────────────────────────────────────────────
cd "$ENV_DIR"
log_run "Terraform init..."

if [[ "$CLOUD" == "azure" ]]; then
  BACKEND_CONF="${ENV_DIR}/backend.conf"
  [ -f "$BACKEND_CONF" ] || { log_error "backend.conf not found: $BACKEND_CONF"; exit 1; }
  terraform init -upgrade=false -backend-config="$BACKEND_CONF"
else
  terraform init -upgrade=false
fi

# ── Route53 zone: import if exists (AWS only) ─────────────────────────────────
# If the zone already exists in AWS but not in Terraform state (e.g. after a
# terraform destroy that skipped the zone due to prevent_destroy, or a manual
# import), we import it so terraform apply reuses it instead of creating new.
# This keeps NS records stable — no need to update Namecheap on every redeploy.
if [[ "$CLOUD" == "aws" ]] && [ -n "${DOMAIN:-}" ]; then
  log_info "Checking for existing Route53 zone: ${DOMAIN}..."

  EXISTING_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "${DOMAIN}." \
    --query "HostedZones[?Name=='${DOMAIN}.'].Id" \
    --output text 2>/dev/null \
    | sed 's|/hostedzone/||' | tr -d '[:space:]' || true)

  if [ -n "$EXISTING_ZONE_ID" ] && [ "$EXISTING_ZONE_ID" != "None" ]; then
    # Check if already tracked in Terraform state
    if terraform state show "module.route53[0].aws_route53_zone.this" \
        > /dev/null 2>&1; then
      log_skip "Route53 zone already in state: $EXISTING_ZONE_ID"
    else
      log_info "Importing existing zone $EXISTING_ZONE_ID into Terraform state..."
      terraform import "module.route53[0].aws_route53_zone.this" \
        "$EXISTING_ZONE_ID" && log_ok "Zone imported: $EXISTING_ZONE_ID" \
        || log_warn "Zone import failed — terraform apply will attempt to create"
    fi
  else
    log_info "No existing Route53 zone found — terraform apply will create one"
    log_warn "After apply: copy the NS records from output and set them in Namecheap"
    log_warn "cert-manager (step 09) will wait for NS delegation before issuing cert"
  fi
fi

log_run "Terraform apply..."
terraform apply -auto-approve -parallelism=20

# ── Read outputs into state file ──────────────────────────────────────────────
echo ""
log_info "Reading outputs..."

if [[ "$CLOUD" == "azure" ]]; then
  BASTION_IP=$(terraform output -raw bastion_ip)
  MASTER_IP=$(terraform output -json master_private_ips | jq -r '.[0]')
  LB_IP=$(terraform output -raw lb_public_ip 2>/dev/null || echo "")
  VMSS_NAME=$(terraform output -raw worker_vmss_name)
  VMSS_SPOT_NAME=$(terraform output -raw worker_vmss_spot_name 2>/dev/null \
    || echo "${VMSS_NAME}-spot")
  RESOURCE_GROUP=$(terraform output -raw resource_group)
  VAULT_NAME=$(terraform output -raw keyvault_name 2>/dev/null \
    || echo "${PROJECT_NAME:-devsecops}-${CLUSTER}-kv")
  SUBSCRIPTION_ID=$(az account show --query id -o tsv | tr -d '\r')
  TENANT_ID=$(az account show --query tenantId -o tsv | tr -d '\r')

  log_info "  Bastion:   $BASTION_IP"
  log_info "  Master:    $MASTER_IP"
  log_info "  LB IP:     $LB_IP"
  log_info "  VMSS:      $VMSS_NAME"
  log_info "  VMSS Spot: $VMSS_SPOT_NAME"
  log_info "  RG:        $RESOURCE_GROUP"
  log_info "  Vault:     $VAULT_NAME"

  # Clear old bastion SSH host keys
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$BASTION_IP" 2>/dev/null || true
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$MASTER_IP"  2>/dev/null || true

  # Check for Spot bastion eviction
  echo ""
  log_info "Checking bastion VM status..."
  BASTION_NAME=$(az vm list \
    --resource-group "$RESOURCE_GROUP" \
    --query "[?tags.role=='bastion'].name" \
    -o tsv 2>/dev/null | tr -d '\r' || echo "")

  if [ -z "$BASTION_NAME" ]; then
    log_warn "Bastion VM not found in RG — may be evicted"
    BASTION_STATE=""
  else
    BASTION_STATE=$(az vm show \
      --resource-group "$RESOURCE_GROUP" \
      --name "$BASTION_NAME" \
      --query "provisioningState" -o tsv 2>/dev/null | tr -d '\r' || echo "")
  fi

  if [ -z "$BASTION_STATE" ] || [ "$BASTION_STATE" = "Deallocated" ]; then
    log_warn "Bastion evicted (Spot) — recreating..."
    cd "$ENV_DIR"
    terraform apply -auto-approve \
      -target=module.compute.azurerm_linux_virtual_machine.bastion \
      -target=module.compute.azurerm_public_ip.bastion_ip \
      -target=module.compute.azurerm_network_interface.bastion_nic
    BASTION_IP=$(terraform output -raw bastion_ip)
    log_ok "Bastion recreated: $BASTION_IP"
  else
    log_ok "Bastion: $BASTION_STATE"
  fi

  cd "$BASE_DIR"

  # Service Principal for Cluster Autoscaler
  echo ""
  log_info "Checking Service Principal..."
  SP_NAME="${SP_NAME:-cluster-autoscaler-sp-${PROJECT_NAME:-devsecops}}"

  if [ -n "${SP_CLIENT_ID:-}" ] && [ -n "${SP_CLIENT_SECRET:-}" ]; then
    log_skip "SP credentials already set"
  else
    SP_EXISTS=$(az ad sp list --display-name "$SP_NAME" \
      --query "[0].appId" -o tsv 2>/dev/null || echo "")

    if [ -n "$SP_EXISTS" ]; then
      log_skip "SP exists: $SP_EXISTS"
      SP_CLIENT_ID="$SP_EXISTS"
      SP_CLIENT_SECRET="${SP_CLIENT_SECRET:-}"
    else
      log_info "Creating SP: $SP_NAME..."
      SP_JSON=$(az ad sp create-for-rbac \
        --name "$SP_NAME" \
        --role "Contributor" \
        --scopes "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}" \
        --output json 2>/dev/null)
      SP_CLIENT_ID=$(echo "$SP_JSON" | jq -r '.appId')
      SP_CLIENT_SECRET=$(echo "$SP_JSON" | jq -r '.password')
      log_ok "SP created: $SP_CLIENT_ID"
      update_secret "SP_CLIENT_ID" "$SP_CLIENT_ID"
      update_secret "SP_CLIENT_SECRET" "$SP_CLIENT_SECRET"
    fi
  fi

  # Tag VMSS for Cluster Autoscaler discovery
  for vmss in "$VMSS_NAME" "$VMSS_SPOT_NAME"; do
    [ -z "$vmss" ] && continue
    az vmss update \
      --resource-group "$RESOURCE_GROUP" \
      --name "$vmss" \
      --set "tags.k8s\.io/cluster-autoscaler/enabled=true" \
           "tags.k8s\.io/cluster-autoscaler/${PROJECT_NAME:-devsecops}-${CLUSTER}=owned" \
      --output none 2>/dev/null || true
  done
  log_ok "VMSS tags applied"

  # Write state
  cat > "$STATE_FILE" <<STATE
CLOUD="${CLOUD}"
CLUSTER="${CLUSTER}"
BASTION_IP="${BASTION_IP}"
MASTER_IP="${MASTER_IP}"
LB_IP="${LB_IP}"
VMSS_NAME="${VMSS_NAME}"
VMSS_SPOT_NAME="${VMSS_SPOT_NAME}"
RESOURCE_GROUP="${RESOURCE_GROUP}"
VAULT_NAME="${VAULT_NAME}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID}"
TENANT_ID="${TENANT_ID}"
SP_NAME="${SP_NAME}"
SP_CLIENT_ID="${SP_CLIENT_ID:-}"
SP_CLIENT_SECRET="${SP_CLIENT_SECRET:-}"
SSH_KEY="${SSH_KEY}"
PROJECT_NAME="${PROJECT_NAME:-devsecops}"
ENVIRONMENT="${CLUSTER}"
ENV_DIR="${ENV_DIR}"
STATE
  log_ok "State written: $STATE_FILE"

else
  # ── AWS ──────────────────────────────────────────────────────────────────────
  CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null \
    || grep 'cluster_name' "${ENV_DIR}/terraform.tfvars" | head -1 \
    | sed 's/.*= *"\(.*\)"/\1/')
  BASTION_IP=$(terraform output -raw bastion_public_ip 2>/dev/null || echo "")
  CONTROL_PLANE_IP=$(terraform output -raw control_plane_private_ip)
  CONTROL_PLANE_IPS=$(terraform output -json control_plane_private_ips | jq -r '.[]')
  WORKER_IPS=$(terraform output -json worker_private_ips | jq -r '.[]')
  NLB_DNS=$(terraform output -raw api_nlb_dns 2>/dev/null || echo "")
  SPOT_ASG_NAME=$(terraform output -raw spot_asg_name 2>/dev/null || echo "")
  BURST_WORKER_ID=$(terraform output -raw burst_worker_id 2>/dev/null || echo "")
  BURST_WORKER_IP=$(terraform output -raw burst_worker_private_ip 2>/dev/null || echo "")
  ROUTE53_ZONE_ID=$(terraform output -raw route53_zone_id 2>/dev/null || echo "")
  ROUTE53_NS=$(terraform output -json route53_name_servers 2>/dev/null \
    | jq -r '.[]' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")

  if [ -n "$ROUTE53_ZONE_ID" ]; then
    log_ok "Route53 zone: $ROUTE53_ZONE_ID"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │  NAMECHEAP ACTION REQUIRED (first deploy only)              │"
    echo "  │  Set these NS records for ${DOMAIN:-your-domain}:           │"
    echo "  │                                                             │"
    IFS=',' read -ra NS_ARR <<< "$ROUTE53_NS"
    for ns in "${NS_ARR[@]}"; do
      printf "  │    %-55s │\n" "$ns"
    done
    echo "  │                                                             │"
    echo "  │  Step 09 will check delegation before running cert-manager  │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""
  fi

  log_info "  Cluster:         $CLUSTER_NAME"
  log_info "  Bastion IP:      ${BASTION_IP:-none}"
  log_info "  Control Plane:   $CONTROL_PLANE_IP"
  log_info "  NLB DNS:         ${NLB_DNS:-none}"
  log_info "  Spot ASG:        ${SPOT_ASG_NAME:-none}"

  # Clear old SSH host keys
  [ -n "$BASTION_IP" ] && ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$BASTION_IP" 2>/dev/null || true
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$CONTROL_PLANE_IP" 2>/dev/null || true

  cat > "$STATE_FILE" <<STATE
CLOUD="${CLOUD}"
CLUSTER="${CLUSTER}"
CLUSTER_NAME="${CLUSTER_NAME}"
BASTION_IP="${BASTION_IP}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP}"
NLB_DNS="${NLB_DNS}"
SPOT_ASG_NAME="${SPOT_ASG_NAME}"
BURST_WORKER_ID="${BURST_WORKER_ID}"
BURST_WORKER_IP="${BURST_WORKER_IP}"
ROUTE53_ZONE_ID="${ROUTE53_ZONE_ID}"
ROUTE53_NS="${ROUTE53_NS}"
SSH_KEY="${SSH_KEY}"
ENV_DIR="${ENV_DIR}"
STATE
  log_ok "State written: $STATE_FILE"
fi

log_success "STEP 01"
