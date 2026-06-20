#!/usr/bin/env bash
# setup-vault.sh — Initialize Vault, store all secrets, configure AppRole for Jenkins
# Usage: ./k8s/vault/setup-vault.sh
# Run ONCE after deploying Vault. Idempotent — safe to re-run.

set -euo pipefail

# Load DOMAIN from .env if not already set
SCRIPT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -z "${DOMAIN:-}" ] && [ -f "$SCRIPT_ROOT/.env" ]; then
  set -a; source "$SCRIPT_ROOT/.env"; set +a
fi

VAULT_NS="vault"
VAULT_POD="vault-0"
UNSEAL_FILE="$HOME/.vault-unseal-keys"

# ── 1. Check status ───────────────────────────────────────────────────────────
echo "==> Checking Vault status..."
STATUS=$(kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- vault status -format=json 2>/dev/null || true)
INITIALIZED=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin)['initialized'])" 2>/dev/null || echo "False")
SEALED=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])" 2>/dev/null || echo "True")

# ── 2. Initialize ─────────────────────────────────────────────────────────────
if [[ "$INITIALIZED" == "False" ]]; then
  echo "==> Initializing Vault (KMS auto-unseal)..."
  INIT_OUTPUT=$(kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- \
    vault operator init -format=json)
  ROOT_TOKEN=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")
  echo "ROOT_TOKEN=$ROOT_TOKEN" > "$UNSEAL_FILE"
  chmod 600 "$UNSEAL_FILE"
  echo "  Root token saved to $UNSEAL_FILE"
else
  echo "  Vault already initialized."
  if [[ -f "$UNSEAL_FILE" ]]; then
    source "$UNSEAL_FILE"
  elif [[ -n "${ROOT_TOKEN:-}" ]]; then
    echo "  Using ROOT_TOKEN from environment."
  else
    read -rsp "  Enter Vault root token: " ROOT_TOKEN; echo ""
    echo "ROOT_TOKEN=$ROOT_TOKEN" > "$UNSEAL_FILE"
    chmod 600 "$UNSEAL_FILE"
  fi
fi

# ── 3. Wait for unseal (KMS) ──────────────────────────────────────────────────
if [[ "$SEALED" == "True" ]]; then
  echo "  Waiting for KMS auto-unseal..."
  sleep 10
  SEALED=$(kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- \
    vault status -format=json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])" 2>/dev/null || echo "True")
  [[ "$SEALED" == "True" ]] && { echo "ERROR: Vault still sealed."; exit 1; }
fi

# ── 4. Login ──────────────────────────────────────────────────────────────────
echo "==> Logging in..."
kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- vault login "$ROOT_TOKEN" > /dev/null

# ── 5. Enable KV engine ───────────────────────────────────────────────────────
echo "==> Enabling KV secrets engine..."
kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- \
  vault secrets enable -path=secret kv-v2 2>/dev/null || echo "  KV already enabled."

# ── 6. Store all secrets ──────────────────────────────────────────────────────
echo "==> Storing secrets..."

# Prompt for secrets not yet known
read -rp "  GitHub username: " GIT_USER
read -rsp "  GitHub token: " GIT_TOKEN; echo ""
read -rsp "  SonarQube token (generate at https://sonarqube.${DOMAIN:-example.com}): " SONAR_TOKEN; echo ""
read -rsp "  Harbor admin password: " HARBOR_PASSWORD; echo ""
echo "  Gmail App Password (Google Account → Security → 2-Step → App passwords)"
read -rsp "  Gmail App Password (16 chars, leave blank to skip): " GMAIL_APP_PASSWORD; echo ""
GMAIL_FROM="${ALERT_FROM_EMAIL:-}"

kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- \
  vault kv put secret/git \
    username="$GIT_USER" \
    token="$GIT_TOKEN"

kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- \
  vault kv put secret/harbor \
    username="admin" \
    password="$HARBOR_PASSWORD" \
    registry="harbor.${DOMAIN:-example.com}"

kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- \
  vault kv put secret/sonarqube \
    token="$SONAR_TOKEN" \
    url="https://sonarqube.${DOMAIN:-example.com}"

kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- \
  vault kv put secret/sonarqube-db \
    username="sonar" \
    password="sonar"

if [[ -n "${GMAIL_APP_PASSWORD:-}" && -n "${GMAIL_FROM:-}" ]]; then
  kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- \
    vault kv put secret/monitoring/gmail \
      app_password="$GMAIL_APP_PASSWORD" \
      from_address="$GMAIL_FROM"

  # Create K8s secret for AlertManager immediately
  kubectl create secret generic alertmanager-gmail-secret \
    -n monitoring \
    --from-literal=password="$GMAIL_APP_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  Gmail secret stored in Vault and applied to monitoring namespace."
else
  echo "  Skipping Gmail secret (no credentials provided)."
fi

echo "  Secrets stored."

# ── 7. Enable AppRole ─────────────────────────────────────────────────────────
echo "==> Enabling AppRole auth..."
kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- \
  vault auth enable approle 2>/dev/null || echo "  AppRole already enabled."

# ── 8. Jenkins policy ─────────────────────────────────────────────────────────
echo "==> Creating Jenkins policy..."
kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- sh -c '
cat > /tmp/jenkins-policy.hcl << EOF
path "secret/data/git"          { capabilities = ["read"] }
path "secret/data/harbor"       { capabilities = ["read"] }
path "secret/data/sonarqube"    { capabilities = ["read"] }
path "secret/data/sonarqube-db" { capabilities = ["read"] }
EOF
vault policy write jenkins /tmp/jenkins-policy.hcl'

# ── 9. AppRole for Jenkins ────────────────────────────────────────────────────
echo "==> Creating Jenkins AppRole..."
kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- \
  vault write auth/approle/role/jenkins \
    token_policies="jenkins" \
    token_ttl=1h \
    token_max_ttl=4h

ROLE_ID=$(kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- \
  vault read -field=role_id auth/approle/role/jenkins/role-id)
SECRET_ID=$(kubectl exec "$VAULT_POD" -n "$VAULT_NS" -- \
  vault write -field=secret_id -f auth/approle/role/jenkins/secret-id)

# Save AppRole creds locally
cat >> "$UNSEAL_FILE" <<EOF
VAULT_ROLE_ID=$ROLE_ID
VAULT_SECRET_ID=$SECRET_ID
EOF

echo ""
echo "============================================================"
echo " Vault setup complete!"
echo "============================================================"
echo ""
echo " Add these 2 credentials to Jenkins UI:"
echo " Manage Jenkins → Credentials → Global → Add Credential"
echo ""
echo "   Kind: Vault App Role Credential"
echo "   ID:   vault-approle"
echo "   Role ID:   $ROLE_ID"
echo "   Secret ID: $SECRET_ID"
echo ""
echo " Vault UI:    https://vault.${DOMAIN:-example.com}"
echo " Credentials: $UNSEAL_FILE"
echo "============================================================"
