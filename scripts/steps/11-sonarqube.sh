#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 11: SonarQube"

check_state
check_k8s
export KUBECONFIG="$KUBECONFIG"

DOMAIN="tools.votantai.me"

# ── Resolve password ───────────────────────────────────────────────────────────
echo ""
log_info "Resolving SonarQube DB password..."
SONAR_DB_PASSWORD="${SONAR_DB_PASSWORD:-sonar}"
log_ok "SonarQube DB password resolved"

# ── Namespace + PVCs ──────────────────────────────────────────────────────────
echo ""
log_info "Applying SonarQube namespace and PVCs..."
kubectl apply -f "$BASE_DIR/k8s/sonarqube/00-namespace.yaml"
kubectl apply -f "$BASE_DIR/k8s/sonarqube/01-pvc.yaml"
log_ok "Namespace and PVCs ready"

# ── DB Secret ─────────────────────────────────────────────────────────────────
echo ""
log_info "Creating SonarQube DB secret..."
kubectl create secret generic sonarqube-db-secret \
  -n sonarqube \
  --from-literal=password="${SONAR_DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
log_ok "DB secret applied"

# ── PostgreSQL ────────────────────────────────────────────────────────────────
echo ""
log_info "Deploying PostgreSQL for SonarQube..."
kubectl apply -f "$BASE_DIR/k8s/sonarqube/02-postgres.yaml"
kubectl rollout status deployment/sonarqube-db -n sonarqube --timeout=120s
log_ok "PostgreSQL ready"

# ── SonarQube ─────────────────────────────────────────────────────────────────
echo ""
log_info "Deploying SonarQube..."
kubectl apply -f "$BASE_DIR/k8s/sonarqube/03-sonarqube.yaml"
log_info "Waiting for SonarQube to start (may take 2-3 minutes)..."
kubectl rollout status deployment/sonarqube -n sonarqube --timeout=300s
log_ok "SonarQube running"

# ── Ingress ───────────────────────────────────────────────────────────────────
echo ""
log_info "Applying SonarQube ingress..."
kubectl apply -f "$BASE_DIR/k8s/sonarqube/ingress.yaml"
log_ok "SonarQube ingress applied"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
log_info "SonarQube pods:"
kubectl get pods -n sonarqube

echo ""
echo "══════════════════════════════════════════════════════"
echo "  SonarQube ready"
echo "  https://sonarqube.${DOMAIN}"
echo "  Default login: admin / admin"
echo "══════════════════════════════════════════════════════"

log_success "STEP 11"
