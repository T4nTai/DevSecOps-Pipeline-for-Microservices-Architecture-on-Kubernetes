#!/bin/bash
# push-secrets.sh — push .env.secret → Azure KV or AWS SSM
# Usage: CLOUD=aws|azure CLUSTER=tools|apps bash scripts/lib/push-secrets.sh
set -uo pipefail

BASE_DIR="${BASE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
SECRETS_LIST="${BASE_DIR}/secrets.list"
SECRET_FILE="${BASE_DIR}/.env.secret"
CLOUD="${CLOUD:-aws}"
CLUSTER="${CLUSTER:-tools}"

[ -f "$SECRETS_LIST" ] || { echo "[ERROR] secrets.list not found: $SECRETS_LIST"; exit 1; }
[ -f "$SECRET_FILE"  ] || { echo "[INFO ] .env.secret not found — nothing to push"; exit 0; }

set -a; source "$SECRET_FILE"; set +a

pushed=0; skipped=0

if [[ "$CLOUD" == "azure" ]]; then
  [ -z "${VAULT_NAME:-}" ] && { echo "[ERROR] VAULT_NAME not set"; exit 1; }

  echo "[INFO ] Pushing secrets → Azure KV: $VAULT_NAME"

  KV_READY=false
  for i in $(seq 1 6); do
    if az keyvault show --name "$VAULT_NAME" --query name -o tsv >/dev/null 2>&1; then
      KV_READY=true; break
    fi
    echo "[INFO ] Waiting for KV... $i/6"; sleep 10
  done
  [ "$KV_READY" = false ] && { echo "[ERROR] Key Vault not accessible"; exit 1; }

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line// /}"; [[ -z "$key" ]] && continue
    val="${!key:-}"
    val="${val%"${val##*[! ]}"}"; val="${val#"${val%%[! ]*}"}"
    if [ -z "$val" ]; then echo "[SKIP ] $key (empty)"; skipped=$((skipped+1)); continue; fi
    secret_name=$(echo "$key" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    if az keyvault secret set --vault-name "$VAULT_NAME" \
        --name "$secret_name" --value "$val" --output none 2>/dev/null </dev/null; then
      echo "[OK   ] $secret_name"; pushed=$((pushed+1))
    else
      echo "[WARN ] Failed: $secret_name"; skipped=$((skipped+1))
    fi
  done < "$SECRETS_LIST"

else
  CLUSTER_NAME="${CLUSTER_NAME:-devsecops-${CLUSTER}}"
  echo "[INFO ] Pushing secrets → AWS SSM (prefix: /${CLUSTER_NAME}/)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line// /}"; [[ -z "$key" ]] && continue
    val="${!key:-}"
    val="${val%"${val##*[! ]}"}"; val="${val#"${val%%[! ]*}"}"
    if [ -z "$val" ]; then echo "[SKIP ] $key (empty)"; skipped=$((skipped+1)); continue; fi
    param_name="/${CLUSTER_NAME}/$(echo "$key" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
    if aws ssm put-parameter --name "$param_name" \
        --value "$val" --type SecureString --overwrite 2>/dev/null; then
      echo "[OK   ] $param_name"; pushed=$((pushed+1))
    else
      echo "[WARN ] Failed: $param_name"; skipped=$((skipped+1))
    fi
  done < "$SECRETS_LIST"
fi

echo "[INFO ] pushed: $pushed | skipped: $skipped"
