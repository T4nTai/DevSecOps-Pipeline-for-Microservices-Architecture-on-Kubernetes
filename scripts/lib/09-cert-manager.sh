#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-checks.sh"

log_step "STEP 09: cert-manager + TLS"

check_state
check_k8s
check_helm
export KUBECONFIG="$KUBECONFIG"

CERT_MANAGER_VERSION="v1.14.5"

# ── Load zone info from state ─────────────────────────────────────────────────
ROUTE53_ZONE_ID="${ROUTE53_ZONE_ID:-}"
ROUTE53_NS="${ROUTE53_NS:-}"

# Fallback: read directly from Terraform if state didn't have it
if [ -z "$ROUTE53_ZONE_ID" ] && [ -d "${ENV_DIR:-}" ]; then
  log_info "Reading Route53 zone ID from Terraform outputs..."
  ROUTE53_ZONE_ID=$(cd "$ENV_DIR" && \
    terraform output -raw route53_zone_id 2>/dev/null || echo "")
  ROUTE53_NS=$(cd "$ENV_DIR" && \
    terraform output -json route53_name_servers 2>/dev/null \
    | jq -r '.[]' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")
fi

# ── NS delegation check ───────────────────────────────────────────────────────
# cert-manager's DNS-01 challenge works like this:
#   1. cert-manager writes a TXT record to Route53
#   2. Let's Encrypt queries that TXT record using the domain's PUBLIC nameservers
#   3. If Namecheap still delegates to OLD (or no) Route53 NS, the query fails
#
# This function catches the problem BEFORE wasting 5 minutes on a doomed challenge.
check_ns_delegation() {
  local domain="${DOMAIN:-}"
  [ -z "$domain" ] && return 0

  echo ""
  log_info "Checking NS delegation for ${domain}..."

  # Get NS records from Route53 (ground truth)
  local r53_ns=""
  if [ -n "$ROUTE53_ZONE_ID" ]; then
    r53_ns=$(aws route53 list-resource-record-sets \
      --hosted-zone-id "$ROUTE53_ZONE_ID" \
      --query "ResourceRecordSets[?Type=='NS'].ResourceRecords[*].Value" \
      --output text 2>/dev/null | tr '\t\n' ' ' | tr -s ' ' || true)
  elif [ -n "$ROUTE53_NS" ]; then
    r53_ns=$(echo "$ROUTE53_NS" | tr ',' ' ')
  fi

  if [ -z "$r53_ns" ]; then
    log_warn "Could not determine Route53 NS records — skipping NS check"
    return 0
  fi

  # Query public DNS to see what NS records the world sees for this domain
  local public_ns=""
  public_ns=$(dig +short NS "$domain" @8.8.8.8 2>/dev/null \
    | sort | tr '\n' ' ' | tr -s ' ' || true)

  if [ -z "$public_ns" ]; then
    # dig not available or no response — try nslookup
    public_ns=$(nslookup -type=NS "$domain" 8.8.8.8 2>/dev/null \
      | grep "nameserver" | awk '{print $NF}' \
      | sort | tr '\n' ' ' | tr -s ' ' || true)
  fi

  # Compare: check if any Route53 NS appears in public NS
  local delegation_ok=false
  local first_r53_ns
  first_r53_ns=$(echo "$r53_ns" | awk '{print $1}' | tr -d '.')

  if echo "$public_ns" | grep -qi "$first_r53_ns"; then
    delegation_ok=true
  fi

  if [ "$delegation_ok" = true ]; then
    log_ok "NS delegation confirmed: ${domain} → Route53 ✓"
    return 0
  fi

  # Delegation not confirmed — print clear instructions
  echo ""
  echo "  ┌──────────────────────────────────────────────────────────────────┐"
  echo "  │  ⚠️  NS NOT DELEGATED — cert-manager will FAIL                   │"
  echo "  ├──────────────────────────────────────────────────────────────────┤"
  echo "  │  The domain ${domain} is not yet pointing to Route53.            │"
  echo "  │                                                                  │"
  echo "  │  Go to Namecheap → Domain List → Manage → Nameservers           │"
  echo "  │  Select: Custom DNS, then paste these 4 records:                │"
  echo "  │                                                                  │"
  for ns in $r53_ns; do
    printf "  │    %-64s│\n" "$ns"
  done
  echo "  │                                                                  │"
  echo "  │  Current public NS (what Namecheap has now):                    │"
  if [ -n "$public_ns" ]; then
    for ns in $public_ns; do
      printf "  │    %-64s│\n" "$ns"
    done
  else
    echo "  │    (none found — domain may not be delegated at all)           │"
  fi
  echo "  │                                                                  │"
  echo "  │  After saving: wait 5-30 minutes for propagation, then re-run:  │"
  echo "  │    bash scripts/deploy.sh --cloud=aws --start-from=09           │"
  echo "  └──────────────────────────────────────────────────────────────────┘"
  echo ""

  if [ "${NS_CHECK_STRICT:-false}" = "true" ]; then
    log_error "NS not delegated. Set nameservers in Namecheap and retry step 09."
    exit 1
  else
    log_warn "NS not confirmed — continuing. cert-manager may fail if propagation is incomplete."
    log_warn "Set NS_CHECK_STRICT=true to abort here automatically."
  fi
}

# ── Install cert-manager ──────────────────────────────────────────────────────
echo ""
log_info "Installing cert-manager ${CERT_MANAGER_VERSION}..."

helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update 2>/dev/null || true

CM_STATUS=$(kubectl get deployment cert-manager -n cert-manager \
  --no-headers 2>/dev/null | awk '{print $2}' || echo "0/0")

if [ "$CM_STATUS" = "1/1" ]; then
  log_skip "cert-manager already running"
else
  helm upgrade --install cert-manager jetstack/cert-manager \
    -n cert-manager --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    -f "$BASE_DIR/k8s/cert-manager/values.yaml" \
    --timeout 5m --wait
  log_ok "cert-manager installed"
fi

# ── Wait for webhooks to be ready ─────────────────────────────────────────────
echo ""
log_info "Waiting for cert-manager webhooks..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager --timeout=120s
log_ok "cert-manager ready"

# ── NS check (before wasting time on a challenge that will fail) ──────────────
check_ns_delegation

# ── ClusterIssuer (generated inline with optional hostedZoneID) ───────────────
# hostedZoneID is set when ROUTE53_ZONE_ID is known. This avoids cert-manager
# having to do a Zone discovery lookup, which is slower and occasionally fails
# when multiple zones exist or IAM permissions are marginal.
echo ""
log_info "Applying ClusterIssuer (Let's Encrypt + Route53)..."

if [ -n "${ROUTE53_ZONE_ID:-}" ]; then
  log_info "  Using hostedZoneID: ${ROUTE53_ZONE_ID}"
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - dns01:
          route53:
            region: ${AWS_REGION}
            hostedZoneID: ${ROUTE53_ZONE_ID}
EOF
else
  # Fallback: no zone ID — cert-manager auto-discovers the zone.
  # Slower but still works if IAM stateful role has route53:ListHostedZones.
  log_warn "ROUTE53_ZONE_ID not set — cert-manager will auto-discover the zone"
  envsubst < "$BASE_DIR/k8s/cert-manager/cluster-issuer.yaml" | kubectl apply -f -
fi
log_ok "ClusterIssuer applied"

# ── Wait for ClusterIssuer to become Ready ────────────────────────────────────
echo ""
log_info "Waiting for ClusterIssuer to become Ready..."
for i in $(seq 1 12); do
  ISSUER_READY=$(kubectl get clusterissuer letsencrypt-prod \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "$ISSUER_READY" = "True" ]; then
    log_ok "ClusterIssuer Ready"
    break
  fi
  log_info "  ClusterIssuer not Ready yet (${i}/12) — waiting 10s..."
  if [ "$i" -eq 12 ]; then
    log_warn "ClusterIssuer still not Ready — check IRSA/IAM and route53 permissions:"
    kubectl describe clusterissuer letsencrypt-prod 2>/dev/null | tail -20 || true
  fi
  sleep 10
done

# ── Wildcard Certificate ──────────────────────────────────────────────────────
echo ""
log_info "Requesting wildcard certificate for *.${DOMAIN}..."
envsubst < "$BASE_DIR/k8s/cert-manager/certificate.yaml" | kubectl apply -f -

# ── Wait for certificate — extended timeout for DNS propagation ───────────────
# DNS-01 challenges can take longer than 5 min when:
#   - Route53 propagation is slow (~1 min normal, up to 5 min edge)
#   - Let's Encrypt retries on its side (10-30 min if rate-limited)
#   - NS delegation was very recently set in Namecheap (TTL drain)
# 600s covers the normal case. If it fails here, re-run step 09 after waiting.
echo ""
log_info "Waiting for certificate (DNS-01 via Route53 — up to 10 minutes)..."
log_info "  If this times out, check: kubectl describe certificate/tools-wildcard -n ingress-nginx"

if kubectl wait --for=condition=ready certificate/tools-wildcard \
    -n ingress-nginx --timeout=600s 2>/dev/null; then
  log_ok "Certificate issued: *.${DOMAIN}"
else
  echo ""
  echo "  ┌──────────────────────────────────────────────────────────────────┐"
  echo "  │  Certificate timed out. Possible causes:                        │"
  echo "  │                                                                  │"
  echo "  │  1. NS not delegated yet → wait and re-run step 09              │"
  echo "  │  2. IAM role missing Route53 permissions                        │"
  echo "  │     → check stateful node role has route53:ChangeResourceRecordSets│"
  echo "  │  3. cert-manager pod not on stateful node                       │"
  echo "  │     → check cert-manager pod nodeSelector/tolerations           │"
  echo "  │  4. Let's Encrypt rate limit hit (5 certs/week per domain)      │"
  echo "  │     → wait 1 week or use staging server for testing             │"
  echo "  │                                                                  │"
  echo "  │  Debug commands:                                                 │"
  echo "  │    kubectl describe certificate/tools-wildcard -n ingress-nginx  │"
  echo "  │    kubectl describe certificaterequest -n ingress-nginx          │"
  echo "  │    kubectl describe challenge -n ingress-nginx                   │"
  echo "  │    kubectl logs -n cert-manager -l app=cert-manager -f          │"
  echo "  └──────────────────────────────────────────────────────────────────┘"
  echo ""
  log_warn "Re-run after fixing: bash scripts/deploy.sh --cloud=aws --start-from=09"
  exit 1
fi

# ── Update ingress rules ──────────────────────────────────────────────────────
echo ""
log_info "Applying updated ingress rules..."

envsubst < "$BASE_DIR/k8s/jenkins/ingress.yaml" | kubectl apply -f -
log_ok "Jenkins ingress updated"

envsubst < "$BASE_DIR/k8s/argocd/ingress.yaml" | kubectl apply -f -
log_ok "ArgoCD ingress updated"

# Grafana — upgrade helm release với values mới
sed \
  -e "s|GRAFANA_ADMIN_PASSWORD_PLACEHOLDER|${GRAFANA_ADMIN_PASSWORD:-}|g" \
  -e "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" \
  "$BASE_DIR/k8s/monitoring/values.yaml" > /tmp/monitoring-values-rendered.yaml
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f /tmp/monitoring-values-rendered.yaml \
  --reuse-values \
  --timeout 5m
rm -f /tmp/monitoring-values-rendered.yaml
log_ok "Grafana ingress updated"

# ── Update Jenkins jenkinsUrl ─────────────────────────────────────────────────
echo ""
log_info "Updating Jenkins URL to https://jenkins.${DOMAIN}..."

sed \
  -e "s|JENKINS_ADMIN_PASSWORD_PLACEHOLDER|${JENKINS_ADMIN_PASSWORD:-}|g" \
  -e "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" \
  "$BASE_DIR/k8s/jenkins/values.yaml" > /tmp/jenkins-values-rendered.yaml
helm upgrade jenkins jenkins/jenkins -n jenkins \
  -f /tmp/jenkins-values-rendered.yaml \
  --timeout 5m
rm -f /tmp/jenkins-values-rendered.yaml
log_ok "Jenkins URL updated"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
log_info "Certificate status:"
kubectl get certificate -n ingress-nginx

echo ""
log_info "Ingress rules:"
kubectl get ingress -A

echo ""
echo "══════════════════════════════════════════════════════"
echo "  TLS setup complete"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  https://jenkins.${DOMAIN}"
echo "  https://argocd.${DOMAIN}"
echo "  https://grafana.${DOMAIN}"
echo "  https://vault.${DOMAIN}"
echo "  https://harbor.${DOMAIN}"
echo "  https://sonarqube.${DOMAIN}"
echo "══════════════════════════════════════════════════════"

log_success "STEP 09"
