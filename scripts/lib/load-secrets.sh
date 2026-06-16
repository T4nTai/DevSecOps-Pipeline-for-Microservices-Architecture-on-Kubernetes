#!/bin/bash
# load-secrets.sh — sourced by deploy.sh
# Azure: loads from Key Vault → export env vars
# AWS:   loads from SSM Parameter Store → export env vars
# Falls back gracefully if vault/SSM not available.

if [ -z "${BASE_DIR:-}" ]; then
  BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

SECRETS_LIST="${BASE_DIR}/secrets.list"
CLOUD="${CLOUD:-aws}"

[ -f "$SECRETS_LIST" ] || { echo "[INFO ] secrets.list not found — skipping KV load"; return 0 2>/dev/null || exit 0; }

if [[ "$CLOUD" == "azure" ]]; then
  [ -z "${VAULT_NAME:-}" ] && { echo "[ERROR] VAULT_NAME not set"; return 1 2>/dev/null || exit 1; }

  if ! az keyvault show --name "$VAULT_NAME" --query name -o tsv >/dev/null 2>&1 </dev/null; then
    echo "[INFO ] Azure KV '$VAULT_NAME' not accessible — skipping (expected on first run)"
    return 0 2>/dev/null || exit 0
  fi

  echo "[INFO ] Loading secrets from Azure KV: $VAULT_NAME"
  TMP_EXPORTS=$(mktemp)
  loaded=0; skipped=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line// /}"; [[ -z "$key" ]] && continue
    secret_name=$(echo "$key" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

    val=$(az keyvault secret show --vault-name "$VAULT_NAME" \
      --name "$secret_name" --query value -o tsv 2>/dev/null </dev/null | tr -d '\r' || true)
    val="${val%"${val##*[! ]}"}"
    val="${val#"${val%%[! ]*}"}"

    if [ -z "$val" ]; then
      echo "[SKIP ] $secret_name"; skipped=$((skipped+1)); continue
    fi
    printf 'export %s=%q\n' "$key" "$val" >> "$TMP_EXPORTS"
    echo "[OK   ] $key"; loaded=$((loaded+1))
  done < "$SECRETS_LIST"

  echo "[INFO ] loaded: $loaded | not in KV: $skipped"
  [ -s "$TMP_EXPORTS" ] && source "$TMP_EXPORTS"
  rm -f "$TMP_EXPORTS"

else
  # AWS: load from SSM Parameter Store
  CLUSTER_NAME="${CLUSTER_NAME:-devsecops-${CLUSTER:-tools}}"

  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "[INFO ] AWS credentials not available — skipping SSM load"
    return 0 2>/dev/null || exit 0
  fi

  echo "[INFO ] Loading secrets from AWS SSM (prefix: /${CLUSTER_NAME}/)"
  TMP_EXPORTS=$(mktemp)
  loaded=0; skipped=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line// /}"; [[ -z "$key" ]] && continue
    param_name="/${CLUSTER_NAME}/$(echo "$key" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"

    val=$(aws ssm get-parameter --name "$param_name" \
      --with-decryption --query 'Parameter.Value' --output text 2>/dev/null | tr -d '\r' || true)

    if [ -z "$val" ]; then
      echo "[SKIP ] $param_name"; skipped=$((skipped+1)); continue
    fi
    printf 'export %s=%q\n' "$key" "$val" >> "$TMP_EXPORTS"
    echo "[OK   ] $key → $param_name"; loaded=$((loaded+1))
  done < "$SECRETS_LIST"

  echo "[INFO ] loaded: $loaded | not in SSM: $skipped"
  [ -s "$TMP_EXPORTS" ] && source "$TMP_EXPORTS"
  rm -f "$TMP_EXPORTS"
fi

# -- SSH keys: write to file --------------------------------------------------─
SSH_DIR="/tmp/ssh"
mkdir -p "$SSH_DIR"

if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
  echo "$SSH_PRIVATE_KEY" | base64 -d > "$SSH_DIR/id_rsa" 2>/dev/null \
    || printf '%s' "$SSH_PRIVATE_KEY" > "$SSH_DIR/id_rsa"
  chmod 600 "$SSH_DIR/id_rsa"
  export SSH_KEY="$SSH_DIR/id_rsa"
  echo "[INFO ] SSH_KEY → $SSH_KEY"
fi

if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
  printf '%s\n' "$SSH_PUBLIC_KEY" > "$SSH_DIR/id_rsa.pub"
  chmod 644 "$SSH_DIR/id_rsa.pub"
  export SSH_PUB_KEY="$SSH_DIR/id_rsa.pub"
  echo "[INFO ] SSH_PUB_KEY → $SSH_PUB_KEY"
fi
