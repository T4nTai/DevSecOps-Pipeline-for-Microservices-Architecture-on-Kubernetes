#!/usr/bin/env bash
# verify-containerd.sh — Check and fix containerd config on all worker nodes
# Usage: ./scripts/verify-containerd.sh [check|fix]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_USER="ubuntu"
MODE="${1:-check}"

HARBOR_REGISTRY="10.0.20.209:30002"

BASTION_IP=$(terraform -chdir="$TERRAFORM_DIR" output -raw bastion_public_ip)
WORKER_IPS=$(terraform -chdir="$TERRAFORM_DIR" output -json worker_private_ips \
  | python3 -c "import sys,json; [print(ip) for ip in json.load(sys.stdin)]")

check_worker() {
  local ip=$1
  echo ""
  echo "==> Worker $ip"

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    -J "${SSH_USER}@${BASTION_IP}" "${SSH_USER}@${ip}" bash <<'REMOTE'
      PASS=true

      # Check SystemdCgroup (handles both PascalCase and camelCase)
      if sudo grep -qi "systemdcgroup = true" /etc/containerd/config.toml; then
        echo "  [OK] SystemdCgroup = true"
      else
        echo "  [FAIL] SystemdCgroup is NOT true"
        PASS=false
      fi

      # Check config_path
      if sudo grep -q 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml; then
        echo "  [OK] config_path set"
      else
        echo "  [FAIL] config_path missing or wrong"
        PASS=false
      fi

      # Check hosts.toml
      if [ -f "/etc/containerd/certs.d/10.0.20.209:30002/hosts.toml" ]; then
        echo "  [OK] hosts.toml exists"
      else
        echo "  [FAIL] hosts.toml missing"
        PASS=false
      fi

      # Check containerd running
      if systemctl is-active --quiet containerd; then
        echo "  [OK] containerd running"
      else
        echo "  [FAIL] containerd not running"
        PASS=false
      fi

      # Check kubelet running
      if systemctl is-active --quiet kubelet; then
        echo "  [OK] kubelet running"
      else
        echo "  [FAIL] kubelet not running"
        PASS=false
      fi

      $PASS && echo "  --> All checks passed" || echo "  --> ISSUES FOUND — run with 'fix' to repair"
REMOTE
}

fix_worker() {
  local ip=$1
  echo ""
  echo "==> Fixing worker $ip..."

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    -J "${SSH_USER}@${BASTION_IP}" "${SSH_USER}@${ip}" bash <<REMOTE
      # Fix SystemdCgroup (handles both PascalCase and camelCase)
      sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/I' /etc/containerd/config.toml
      sudo sed -i 's/systemdCgroup = false/systemdCgroup = true/' /etc/containerd/config.toml

      # Fix disabled CRI plugin
      sudo sed -i 's/^disabled_plugins.*cri.*/#&/' /etc/containerd/config.toml

      # Remove mirrors section (conflicts with config_path)
      sudo sed -i '/mirrors/d' /etc/containerd/config.toml

      # Fix config_path
      if ! sudo grep -q 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml; then
        if sudo grep -q 'config_path' /etc/containerd/config.toml; then
          sudo sed -i 's|config_path = ".*"|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml
        else
          sudo sed -i '/\[plugins."io.containerd.grpc.v1.cri".registry\]/a\        config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml
        fi
      fi

      # Fix hosts.toml
      sudo mkdir -p /etc/containerd/certs.d/${HARBOR_REGISTRY}
      sudo tee /etc/containerd/certs.d/${HARBOR_REGISTRY}/hosts.toml <<'EOF'
server = "http://${HARBOR_REGISTRY}"

[host."http://${HARBOR_REGISTRY}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

      sudo systemctl restart containerd
      sudo systemctl restart kubelet
      echo "  --> Done"
REMOTE
}

echo "Bastion: $BASTION_IP"

while IFS= read -r ip; do
  if [[ "$MODE" == "fix" ]]; then
    fix_worker "$ip"
  else
    check_worker "$ip"
  fi
done <<< "$WORKER_IPS"

echo ""
echo "Done. Run 'kubectl get nodes' to verify cluster health."
