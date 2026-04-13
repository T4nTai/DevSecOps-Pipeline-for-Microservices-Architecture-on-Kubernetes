#!/usr/bin/env bash
# install-tools.sh — Install Harbor, ArgoCD, Prometheus, Grafana, Loki, Promtail
# Run this after the cluster is up and kubectl is connected
# Usage: ./k8s/install-tools.sh [harbor|argocd|monitoring|all]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
TARGET="${1:-all}"

check_kubectl() {
  if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: kubectl cannot reach the cluster. Run ./connect.sh first."
    exit 1
  fi
}

get_worker_ip() {
  terraform -chdir="$TERRAFORM_DIR" output -json worker_private_ips 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0])"
}

install_harbor() {
  echo "==> Installing Harbor..."

  WORKER_IP=$(get_worker_ip)
  if [[ -z "$WORKER_IP" ]]; then
    echo "ERROR: Could not get worker IP from Terraform. Run: cd terraform && terraform apply"
    exit 1
  fi

  echo "  Worker private IP: $WORKER_IP"

  helm repo add harbor https://helm.goharbor.io
  helm repo update

  kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install harbor harbor/harbor \
    --namespace harbor \
    --values "$SCRIPT_DIR/harbor/values.yaml" \
    --set externalURL="http://${WORKER_IP}:30002" \
    --wait --timeout 10m

  echo ""
  echo "Harbor installed."
  echo "  Browser (via tunnel) : http://localhost:8002"
  echo "  Inside cluster       : http://${WORKER_IP}:30002"
  echo "  Username             : admin"
  echo "  Password             : Harbor12345"
  echo ""
  echo "Create imagePullSecret for pods to pull images:"
  echo "  kubectl create secret docker-registry harbor-credentials \\"
  echo "    --docker-server=${WORKER_IP}:30002 \\"
  echo "    --docker-username=admin \\"
  echo "    --docker-password=Harbor12345 \\"
  echo "    --namespace=default"
  echo ""
}

install_argocd() {
  echo "==> Installing ArgoCD..."

  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update

  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --values "$SCRIPT_DIR/argocd/values.yaml" \
    --wait --timeout 5m

  echo ""
  echo "ArgoCD installed."
  echo "  UI      : http://localhost:8085  (after ./connect.sh)"
  echo "  Username: admin"
  ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)
  echo "  Password: $ARGOCD_PASS"
  echo ""
}

install_monitoring() {
  echo "==> Installing Prometheus + Grafana (kube-prometheus-stack)..."

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo add grafana https://grafana.github.io/helm-charts
  helm repo update

  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --values "$SCRIPT_DIR/monitoring/kube-prometheus-stack-values.yaml" \
    --wait --timeout 10m

  echo "==> Installing Loki..."
  helm upgrade --install loki grafana/loki \
    --namespace monitoring \
    --values "$SCRIPT_DIR/monitoring/loki-values.yaml" \
    --wait --timeout 5m

  echo "==> Installing Promtail..."
  helm upgrade --install promtail grafana/promtail \
    --namespace monitoring \
    --values "$SCRIPT_DIR/monitoring/promtail-values.yaml" \
    --wait --timeout 3m

  GRAFANA_PASS=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana \
    -o jsonpath="{.data.admin-password}" | base64 -d 2>/dev/null || echo "admin")

  echo ""
  echo "Monitoring stack installed."
  echo "  Grafana      : http://localhost:3000  (after ./connect.sh)"
  echo "  Username     : admin"
  echo "  Password     : $GRAFANA_PASS"
  echo "  Prometheus   : http://localhost:9090"
  echo "  Alertmanager : http://localhost:9093"
  echo "  Loki         : internal only (http://loki.monitoring:3100)"
  echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────
check_kubectl

case "$TARGET" in
  harbor)
    install_harbor
    ;;
  argocd)
    install_argocd
    ;;
  monitoring)
    install_monitoring
    ;;
  all)
    install_harbor
    install_argocd
    install_monitoring
    ;;
  *)
    echo "Usage: $0 [harbor|argocd|monitoring|all]"
    exit 1
    ;;
esac

echo "Done."
echo ""
echo "Access via ./connect.sh tunnels:"
echo "  Harbor       : http://localhost:8002"
echo "  Jenkins      : http://localhost:8080"
echo "  SonarQube    : http://localhost:9000"
echo "  ArgoCD       : http://localhost:8085"
echo "  Grafana      : http://localhost:3000"
echo "  Prometheus   : http://localhost:9090"
echo "  Alertmanager : http://localhost:9093"
