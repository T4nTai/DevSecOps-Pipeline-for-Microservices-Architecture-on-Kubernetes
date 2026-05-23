#cloud-config
package_update: true
package_upgrade: false

packages:
  - curl
  - python3
  - apt-transport-https
  - ca-certificates
  - netcat-openbsd
  - openssl

runcmd:
  # =========================================
  # 1. Disable swap
  # =========================================
  - swapoff -a
  - sed -i '/ swap / s/^/#/' /etc/fstab

  # =========================================
  # 2. Kernel modules
  # =========================================
  - modprobe overlay
  - modprobe br_netfilter
  - |
    cat <<EOF > /etc/modules-load.d/k8s.conf
    overlay
    br_netfilter
    EOF

  # =========================================
  # 3. Sysctl
  # =========================================
  - |
    cat <<EOF > /etc/sysctl.d/k8s.conf
    net.bridge.bridge-nf-call-iptables=1
    net.ipv4.ip_forward=1
    EOF
  - sysctl --system

  # =========================================
  # 4. Cài containerd từ Docker repo
  # =========================================
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - |
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  - apt-get update -y
  - apt-get install -y containerd.io

  # =========================================
  # 5. Cấu hình containerd
  # =========================================
  - mkdir -p /etc/containerd
  - containerd config default > /etc/containerd/config.toml
  - sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  - systemctl daemon-reload
  - systemctl enable containerd
  - systemctl restart containerd

  # =========================================
  # 6. iptables legacy
  # =========================================
  - apt-get install -y iptables
  - update-alternatives --set iptables /usr/sbin/iptables-legacy
  - update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

  # =========================================
  # 7. Script refresh bootstrap token
  # Chờ Kubespray xong VÀ kubeadm sẵn sàng
  # =========================================
  - |
    cat <<'SCRIPT' > /usr/local/bin/refresh-bootstrap-token.sh
    #!/bin/bash
    export KUBECONFIG=/etc/kubernetes/admin.conf

    # Bước 1: Chờ Kubespray cài xong (admin.conf xuất hiện)
    until [ -f /etc/kubernetes/admin.conf ]; do
      echo "Waiting for Kubespray to finish (admin.conf not found)..."
      sleep 15
    done
    echo "admin.conf found."

    # Bước 2: Chờ kubeadm có trong PATH
    until command -v kubeadm &>/dev/null; do
      echo "Waiting for kubeadm to be installed..."
      sleep 10
    done
    echo "kubeadm found."

    # Bước 3: Chờ kube-apiserver sẵn sàng
    until kubectl get nodes &>/dev/null 2>&1; do
      echo "Waiting for kube-apiserver to be ready..."
      sleep 10
    done
    echo "kube-apiserver ready. Starting token refresh loop..."

    # Bước 4: Loop tạo token mỗi 12h
    while true; do
      TOKEN=$(kubeadm token create --ttl 24h 2>/dev/null)
      if [ -n "$TOKEN" ]; then
        echo "$TOKEN" > /etc/kubernetes/bootstrap-token
        chmod 600 /etc/kubernetes/bootstrap-token
        echo "Token refreshed: $TOKEN"
      else
        echo "Failed to create token, retrying in 60s..."
        sleep 60
        continue
      fi
      sleep 43200
    done
    SCRIPT
  - chmod +x /usr/local/bin/refresh-bootstrap-token.sh

  # Systemd service cho token refresh
  - |
    cat <<'SERVICE' > /etc/systemd/system/token-refresh.service
    [Unit]
    Description=Kubernetes Bootstrap Token Refresh
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/refresh-bootstrap-token.sh
    Restart=always
    RestartSec=10
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=multi-user.target
    SERVICE

  # =========================================
  # 8. Token server — 2 port song song
  # port 9999: bootstrap token
  # port 9998: CA hash
  # =========================================
  - |
    cat <<'SCRIPT' > /usr/local/bin/token-server.sh
    #!/bin/bash

    serve_token() {
      while true; do
        TOKEN=$(cat /etc/kubernetes/bootstrap-token 2>/dev/null || echo "")
        if [ -n "$TOKEN" ]; then
          echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n$TOKEN" | \
            nc -l -p 9999 -q 1 2>/dev/null
        else
          sleep 5
        fi
      done
    }

    serve_cahash() {
      while true; do
        if [ -f /etc/kubernetes/pki/ca.crt ]; then
          CAHASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt 2>/dev/null | \
                   openssl rsa -pubin -outform der 2>/dev/null | \
                   openssl dgst -sha256 -hex | awk '{print $2}')
          if [ -n "$CAHASH" ]; then
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n$CAHASH" | \
              nc -l -p 9998 -q 1 2>/dev/null
          else
            sleep 5
          fi
        else
          sleep 5
        fi
      done
    }

    serve_token &
    serve_cahash &
    wait
    SCRIPT
  - chmod +x /usr/local/bin/token-server.sh

  # Systemd service cho token server
  - |
    cat <<'SERVICE' > /etc/systemd/system/token-server.service
    [Unit]
    Description=Kubernetes Bootstrap Token Server
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/token-server.sh
    Restart=always
    RestartSec=10
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=multi-user.target
    SERVICE

  # =========================================
  # 9. Enable và start tất cả services
  # =========================================
  - systemctl daemon-reload
  - systemctl enable token-refresh.service
  - systemctl start token-refresh.service
  - systemctl enable token-server.service
  - systemctl start token-server.service

final_message: "Master bootstrap OK"