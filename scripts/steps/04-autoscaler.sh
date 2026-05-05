#!/bin/bash
# STEP 04: Cluster Autoscaler + metrics-server
# Azure: SP-based credentials, VMSS scaling
# AWS:   IAM role (node instance profile), ASG scaling
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 04: Cluster Autoscaler + metrics-server"

check_state
check_k8s
check_dns
export KUBECONFIG="$KUBECONFIG"

if [[ "$CLOUD" == "azure" ]]; then
  check_vars BASTION_IP MASTER_IP SP_CLIENT_ID SP_CLIENT_SECRET \
    SUBSCRIPTION_ID TENANT_ID VMSS_NAME VMSS_SPOT_NAME RESOURCE_GROUP SSH_KEY
fi

# ── Cluster Autoscaler ────────────────────────────────────────────────────────
echo ""
log_info "Deploying Cluster Autoscaler..."

CA_MANIFEST="$BASE_DIR/k8s/cluster-autoscaler/deployment.yaml"
CA_RBAC="$BASE_DIR/k8s/cluster-autoscaler/rbac.yaml"

if [[ "$CLOUD" == "azure" ]]; then
  CA_SECRET_MANIFEST="$BASE_DIR/k8s/cluster-autoscaler/secret.yaml"

  [ -f "$CA_MANIFEST" ]         || { log_error "Missing: $CA_MANIFEST";         exit 1; }
  [ -f "$CA_RBAC" ]             || { log_error "Missing: $CA_RBAC";             exit 1; }
  [ -f "$CA_SECRET_MANIFEST" ]  || { log_error "Missing: $CA_SECRET_MANIFEST";  exit 1; }

  CA_DESIRED_IMAGE=$(grep "image:" "$CA_MANIFEST" | awk '{print $2}' | tr -d ' ')
  CA_CURRENT_IMAGE=$(kubectl get deployment cluster-autoscaler -n kube-system \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
  CA_STATUS=$(kubectl get deployment cluster-autoscaler -n kube-system \
    --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

  if [ "$CA_STATUS" = "1/1" ] && [ "$CA_CURRENT_IMAGE" = "$CA_DESIRED_IMAGE" ]; then
    log_skip "Cluster Autoscaler already running with correct image"
  else
    sed \
      -e "s|<subscription-id>|$SUBSCRIPTION_ID|g" \
      -e "s|<tenant-id>|$TENANT_ID|g" \
      -e "s|<sp-client-id>|$SP_CLIENT_ID|g" \
      -e "s|<sp-client-secret>|$SP_CLIENT_SECRET|g" \
      -e "s|<resource-group>|$RESOURCE_GROUP|g" \
      -e "s|<project-name>-<environment>|${PROJECT_NAME:-devsecops}-${CLUSTER}|g" \
      "$CA_SECRET_MANIFEST" > /tmp/ca-secret-rendered.yaml

    sed \
      -e "s|.*-worker-vmss-spot.*|          - --nodes=0:2:${VMSS_SPOT_NAME}|g" \
      -e "s|.*-worker-vmss[^-].*|          - --nodes=1:5:${VMSS_NAME}|g" \
      "$CA_MANIFEST" > /tmp/ca-deployment-rendered.yaml

    kubectl apply -f "$CA_RBAC"
    kubectl apply -f /tmp/ca-secret-rendered.yaml
    kubectl apply -f /tmp/ca-deployment-rendered.yaml
    rm -f /tmp/ca-secret-rendered.yaml /tmp/ca-deployment-rendered.yaml

    kubectl rollout restart deployment/cluster-autoscaler -n kube-system
    kubectl rollout status deployment/cluster-autoscaler -n kube-system --timeout=300s
    log_ok "Cluster Autoscaler deployed (Azure)"
  fi

else
  # AWS: IAM role already has autoscaling permissions via iam module
  # Deploy using auto-discovery tags applied by Terraform
  CLUSTER_NAME="${CLUSTER_NAME:-devsecops-${CLUSTER}}"

  CA_STATUS=$(kubectl get deployment cluster-autoscaler -n kube-system \
    --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

  if [ "$CA_STATUS" = "1/1" ]; then
    log_skip "Cluster Autoscaler already running"
  else
    CA_VERSION="v1.29.0"
    helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>/dev/null || true
    helm repo update 2>/dev/null || true

    helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
      --namespace kube-system \
      --set autoDiscovery.clusterName="$CLUSTER_NAME" \
      --set awsRegion="${AWS_REGION:-ap-southeast-1}" \
      --set image.tag="$CA_VERSION" \
      --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="" \
      --set extraArgs.balance-similar-node-groups=true \
      --set extraArgs.skip-nodes-with-local-storage=false \
      --wait

    log_ok "Cluster Autoscaler deployed (AWS)"
  fi
fi

# ── metrics-server ────────────────────────────────────────────────────────────
echo ""
log_info "Deploying metrics-server..."

MS_STATUS=$(kubectl get deployment metrics-server -n kube-system \
  --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

if [ "$MS_STATUS" = "1/1" ]; then
  log_skip "metrics-server already running"
else
  kubectl apply -f \
    https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  sleep 5

  kubectl patch deployment metrics-server -n kube-system \
    --type='json' \
    -p='[
      {"op":"add","path":"/spec/template/spec/containers/0/args/-",
       "value":"--kubelet-insecure-tls"},
      {"op":"add","path":"/spec/template/spec/tolerations",
       "value":[{"key":"node-role.kubernetes.io/control-plane",
       "operator":"Exists","effect":"NoSchedule"}]}
    ]'

  kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
  log_ok "metrics-server deployed"
fi

log_success "STEP 04"
